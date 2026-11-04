import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Sends an SDM command to a device and answers its `results`; throws `NestError` (logged by the plugin).
typealias Commander = @Sendable (_ device: String, _ command: String, _ params: [String: JSONValue]) async throws -> JSONValue

/// What HomeKit sees of a thermostat's traits (section 5.1), in HomeKit's units (°C), read from the cached traits.
struct ThermostatState: Sendable, Equatable {
    var mode: String?
    var availableModes: [String]
    /// nil when the device has no ThermostatEco trait: eco then counts as on, as the Homebridge plugin reads it.
    var ecoMode: String?
    var ecoHeat: Double?
    var ecoCool: Double?
    var hvac: String?
    var heat: Double?
    var cool: Double?
    var ambient: Double?
    var humidity: Double?
    var scale: String?
    var fanOn: Bool

    init(_ device: SDMDevice) {
        func number(_ value: JSONValue?) -> Double? { value?.doubleValue.flatMap { $0 == 0 ? nil : $0 } }
        mode = device.trait("ThermostatMode")?["mode"]?.stringValue
        availableModes = device.trait("ThermostatMode")?["availableModes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let eco = device.trait("ThermostatEco")
        ecoMode = eco?["mode"]?.stringValue
        ecoHeat = number(eco?["heatCelsius"])
        ecoCool = number(eco?["coolCelsius"])
        hvac = device.trait("ThermostatHvac")?["status"]?.stringValue
        heat = number(device.trait("ThermostatTemperatureSetpoint")?["heatCelsius"])
        cool = number(device.trait("ThermostatTemperatureSetpoint")?["coolCelsius"])
        ambient = number(device.trait("Temperature")?["ambientTemperatureCelsius"])
        humidity = number(device.trait("Humidity")?["ambientHumidityPercent"])
        scale = device.trait("Settings")?["temperatureScale"]?.stringValue
        fanOn = device.trait("Fan")?["timerMode"]?.stringValue == "ON"
    }

    var ecoOn: Bool { ecoMode != "OFF" }
    var fahrenheit: Bool { scale == "FAHRENHEIT" }

    static func homeKitMode(_ mode: String) -> Int? {
        ["HEAT": 1, "COOL": 2, "HEATCOOL": 3, "OFF": 0][mode]
    }

    static func sdmMode(_ value: Int) -> String {
        [1: "HEAT", 2: "COOL", 3: "HEATCOOL"][value] ?? "OFF"
    }

    var currentHeatingCooling: Int? {
        switch hvac {
        case "HEATING": 1
        case "COOLING": 2
        case "OFF": 0
        default: nil
        }
    }

    /// OFF in eco, else the mode.
    var targetHeatingCooling: Int? { ecoOn ? 0 : mode.flatMap(Self.homeKitMode) }

    /// The setpoint of HEAT or COOL with eco off.
    var targetTemperature: Double? {
        guard !ecoOn else { return nil }
        switch mode {
        case "HEAT": return heat
        case "COOL": return cool
        default: return nil
        }
    }

    /// The setpoints in HEAT, COOL or HEATCOOL, nothing when off.
    private var range: (heat: Double?, cool: Double?)? {
        guard ["HEAT", "COOL", "HEATCOOL"].contains(mode ?? "") else { return nil }
        return (heat, cool)
    }

    /// In eco, eco's own range (as an eco event shows it); else by mode, the other end half a degree away in heat or cool.
    var heatingThreshold: Double? {
        if ecoOn { return ecoHeat }
        guard let range else { return nil }
        switch mode {
        case "HEAT", "HEATCOOL": return range.heat
        case "COOL": return range.cool.map { $0 + 0.5 }
        default: return nil
        }
    }

    var coolingThreshold: Double? {
        if ecoOn { return ecoCool }
        guard let range else { return nil }
        switch mode {
        case "COOL", "HEATCOOL": return range.cool
        case "HEAT": return range.heat.map { $0 - 0.5 }
        default: return nil
        }
    }

    var displayUnits: Int? {
        switch scale {
        case "CELSIUS": 0
        case "FAHRENHEIT": 1
        default: nil
        }
    }

    var canSetTargetTemperature: Bool { !ecoOn && (mode == "HEAT" || mode == "COOL") }
    var canSetThresholds: Bool { !ecoOn && mode == "HEATCOOL" }

    /// The props "configure" sets (section 5.1): the ranges by scale and eco, the target states by available modes.
    struct Props: Sendable, Equatable {
        var settableMin: Double
        var settableMax: Double
        var readableMin: Double
        var readableMax: Double
        /// nil in eco: HAP's own.
        var validModes: [Int]?
    }

    var props: Props {
        // To a tenth: HomeKit steps by 0.1 from the minimum, so -17.778 would show 19.8 °C as 19.822.
        func celsius(_ fahrenheit: Double) -> Double { ((fahrenheit - 32) / 1.8 * 10).rounded() / 10 }
        var props = fahrenheit
            ? Props(settableMin: celsius(50), settableMax: celsius(90), readableMin: celsius(0), readableMax: celsius(160))
            : Props(settableMin: 9, settableMax: 32, readableMin: -20, readableMax: 60)
        if ecoOn {
            props.settableMin = fahrenheit ? celsius(40) : 4.5
        } else {
            let modes = availableModes.compactMap(Self.homeKitMode)
            props.validModes = modes.isEmpty ? nil : modes
        }
        return props
    }
}

/// A thermostat's accessory, and its fan's when `showFan` is on: the traits HomeKit reads, the commands its writes send.
final class NestThermostat: @unchecked Sendable {
    let accessory: Accessory
    let fanAccessory: Accessory?
    let props: ThermostatState.Props
    private let service: Service
    private let eco: Characteristic
    private let fan: Service?
    private let cache: NIOLockedValueBox<SDMDevice>
    private let send: Commander
    private let options: NestOptions
    private let log: Logger
    /// A slider sends one command, not one per step of the drag (the thermostat allows 5 a minute).
    private let setpoints = LatestCallGuard(delay: .milliseconds(600))

    /// The Eco characteristic (section 5.1): its UUID is the Homebridge plugin's, so its iid stays.
    static let ecoType = CharacteristicType(
        name: "Eco", uuid: HAPUUID("F66DE49D-792E-44A6-99C8-5E3576328BA1"), format: .bool, permissions: [.pairedRead, .pairedWrite, .events])

    static func accessoryID(_ device: SDMDevice) -> String { GoogleNestSDMPlugin.accessoryID(deviceID: device.name) }
    static func fanAccessoryID(_ device: SDMDevice) -> String { GoogleNestSDMPlugin.accessoryID(deviceID: "\(device.name) Fan") }

    /// `stale` runs on HomeKit's reads, so a cache older than a day is fetched again in the background.
    init(device: SDMDevice, options: NestOptions, send: @escaping Commander, log: Logger, stale: @escaping @Sendable () -> Void) {
        let state = ThermostatState(device)
        props = state.props
        let props = props
        let temperature = { (type: CharacteristicType) in type.with(minValue: props.settableMin, maxValue: props.settableMax) }
        service = Service(.thermostat, name: device.displayName, optional: [
            .currentRelativeHumidity, temperature(.targetTemperature), temperature(.heatingThresholdTemperature), temperature(.coolingThresholdTemperature),
            .currentTemperature.with(minValue: props.readableMin, maxValue: props.readableMax),
            .targetHeatingCoolingState.with(validValues: props.validModes),
        ], isPrimary: true)
        eco = service.characteristic(adding: Self.ecoType)
        cache = NIOLockedValueBox(device)
        self.send = send
        self.options = options
        self.log = log
        let name = device.displayName
        accessory = Accessory(
            id: Self.accessoryID(device), name: name, manufacturer: "Google Nest", model: "Thermostat", serialNumber: device.shortID,
            category: .thermostat, services: [service], onIdentify: { [log] in log.info("\(name) identified!") })
        if options.showFan {
            let fan = Service(.fan, name: "\(name) Fan", isPrimary: true)
            self.fan = fan
            fanAccessory = Accessory(
                id: Self.fanAccessoryID(device), name: "\(name) Fan", manufacturer: "Google Nest", model: "Thermostat Fan",
                serialNumber: "\(device.shortID)-fan", category: .fan, services: [fan], onIdentify: { [log] in log.info("fan identified!") })
        } else {
            fan = nil
            fanAccessory = nil
        }
        bindHandlers(stale: stale)
        show()
    }

    var device: SDMDevice { cache.withLockedValue { $0 } }
    var state: ThermostatState { ThermostatState(device) }

    /// Puts the traits of a trait event in the cache and shows them; true when the props change (another scale, eco on or
    /// off, other modes), which needs the accessory built again.
    func apply(_ traits: [String: JSONValue]) -> Bool {
        cache.withLockedValue { $0.apply(traits) }
        show()
        return state.props != props
    }

    func replace(_ fetched: SDMDevice) -> Bool {
        cache.withLockedValue { $0 = fetched }
        show()
        return state.props != props
    }

    /// Sets each characteristic the state has a value for; HomeKit hears of those that changed. A value outside the props
    /// is brought into them, as HomeKit would refuse it.
    func show() {
        let state = state
        func set(_ type: CharacteristicType, _ value: Double?, min: Double, max: Double) {
            guard let value else { return }
            service.characteristic(type).value = .double(Swift.min(Swift.max(value, min), max))
        }
        if let value = state.currentHeatingCooling { service.characteristic(.currentHeatingCoolingState).value = .int(value) }
        if let value = state.targetHeatingCooling { service.characteristic(.targetHeatingCoolingState).value = .int(value) }
        set(.currentTemperature, state.ambient, min: props.readableMin, max: props.readableMax)
        set(.currentRelativeHumidity, state.humidity, min: 0, max: 100)
        set(.targetTemperature, state.targetTemperature, min: props.settableMin, max: props.settableMax)
        set(.heatingThresholdTemperature, state.heatingThreshold, min: props.settableMin, max: props.settableMax)
        set(.coolingThresholdTemperature, state.coolingThreshold, min: props.settableMin, max: props.settableMax)
        if let units = state.displayUnits { service.characteristic(.temperatureDisplayUnits).value = .int(units) }
        eco.value = .bool(state.ecoMode == "MANUAL_ECO")
        fan?.characteristic(.on).value = .bool(state.fanOn)
    }

    private func bindHandlers(stale: @escaping @Sendable () -> Void) {
        service.characteristic(.currentTemperature).onRead { [weak self] in
            stale()
            return self?.service.characteristic(.currentTemperature).value ?? .null
        }
        service.characteristic(.targetHeatingCoolingState).onWrite { [weak self] value in
            guard let self else { return }
            let mode = ThermostatState.sdmMode(value.intValue ?? 0)
            guard state.availableModes.contains(mode) else {
                log.error("\(accessory.name): the thermostat does not have the mode \(mode)")
                throw HAPStatusError(.invalidValueInRequest, reason: "The thermostat does not have this mode")
            }
            try await command("ThermostatMode.SetMode", ["mode": .string(mode)], update: ["ThermostatMode": ["mode": .string(mode)]])
        }
        service.characteristic(.targetTemperature).onWrite { [weak self] value in
            guard let self, let celsius = value.doubleValue else { return }
            let state = state
            guard state.canSetTargetTemperature else { throw refused("Set the target temperature in heat or cool, with eco off") }
            guard await setpoints("target") else { return }
            if state.mode == "HEAT" {
                try await command("ThermostatTemperatureSetpoint.SetHeat", ["heatCelsius": .number(celsius)], update: ["ThermostatTemperatureSetpoint": ["heatCelsius": .number(celsius)]])
            } else {
                try await command("ThermostatTemperatureSetpoint.SetCool", ["coolCelsius": .number(celsius)], update: ["ThermostatTemperatureSetpoint": ["coolCelsius": .number(celsius)]])
            }
        }
        for (type, key) in [(CharacteristicType.heatingThresholdTemperature, "heatCelsius"), (.coolingThresholdTemperature, "coolCelsius")] {
            service.characteristic(type).onWrite { [weak self] value in
                guard let self, let celsius = value.doubleValue else { return }
                let state = state
                guard state.canSetThresholds else { throw refused("Set the thresholds in auto, with eco off") }
                guard await setpoints("range") else { return }
                // The other end of the range is the one cached (or just written: the slider's other handle).
                let current = self.state
                var range: [String: JSONValue] = [:]
                if let heat = current.heat { range["heatCelsius"] = .number(heat) }
                if let cool = current.cool { range["coolCelsius"] = .number(cool) }
                range[key] = .number(celsius)
                try await command("ThermostatTemperatureSetpoint.SetRange", range, update: ["ThermostatTemperatureSetpoint": .object(range)])
            }
        }
        eco.onWrite { [weak self] value in
            guard let self else { return }
            let mode = value.boolValue == true ? "MANUAL_ECO" : "OFF"
            try await command("ThermostatEco.SetMode", ["mode": .string(mode)], update: ["ThermostatEco": ["mode": .string(mode)]])
        }
        fan?.characteristic(.on).onWrite { [weak self] value in
            guard let self else { return }
            guard let on = value.boolValue else { throw HAPStatusError(.invalidValueInRequest) }
            guard let duration = options.fanDuration else {
                log.error("\(accessory.name): fanDuration must be between 1 and 43200 seconds")
                throw HAPStatusError(.invalidValueInRequest, reason: "fanDuration must be between 1 and 43200 seconds")
            }
            // Google's timer: a duration with ON only (the Homebridge plugin sends one with OFF too, "undefineds" when unset).
            var params: [String: JSONValue] = ["timerMode": .string(on ? "ON" : "OFF")]
            if on { params["duration"] = .string("\(duration)s") }
            try await command("Fan.SetTimer", params, update: ["Fan": ["timerMode": .string(on ? "ON" : "OFF")]])
        }
    }

    private func refused(_ reason: String) -> HAPStatusError {
        log.error("\(accessory.name): \(reason)")
        return HAPStatusError(.notAllowedInCurrentState, reason: reason)
    }

    /// Sends the command; on success its effect goes in the cache at once (the trait event that follows says the same).
    /// A command that fails is No Response in the Home app, not a success as in the Homebridge plugin.
    private func command(_ name: String, _ params: [String: JSONValue], update: [String: JSONValue]) async throws {
        let resource = cache.withLockedValue { $0.name }
        do {
            _ = try await send(resource, name, params)
        } catch {
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        cache.withLockedValue { $0.apply(Dictionary(uniqueKeysWithValues: update.map { ("sdm.devices.traits.\($0.key)", $0.value) })) }
    }
}
