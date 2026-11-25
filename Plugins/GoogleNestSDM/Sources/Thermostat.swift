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

    /// SDM's mode as a Climate Mode: HEATCOOL is auto, OFF is the power.
    static func climateMode(_ mode: String) -> ClimateMode? {
        ["HEAT": .heat, "COOL": .cool, "HEATCOOL": .auto][mode]
    }

    static func sdmMode(_ mode: ClimateMode) -> String {
        switch mode {
        case .heat: "HEAT"
        case .cool: "COOL"
        case .auto: "HEATCOOL"
        }
    }

    /// The Climate Modes `availableModes` lists; all three when it lists none.
    var climateModes: Set<ClimateMode> {
        let modes = Set(availableModes.compactMap(Self.climateMode))
        return modes.isEmpty ? [.heat, .cool, .auto] : modes
    }

    var canTurnOff: Bool { availableModes.isEmpty || availableModes.contains("OFF") }

    var isOn: Bool { mode != nil && mode != "OFF" }

    /// What the thermostat is set to and does, for the controller. Eco is an Other Mode, its range eco's own; the
    /// heat-to and cool-to are SDM's heatCelsius and coolCelsius, one used in heat or cool and both in HEATCOOL.
    var report: ClimateReport {
        let action: ClimateAction? = switch hvac {
        case "HEATING": .heating
        case "COOLING": .cooling
        case "OFF": .idle
        default: nil
        }
        return ClimateReport(power: isOn, mode: ecoOn ? nil : mode.flatMap(Self.climateMode), action: action, current: ambient,
                             heating: ecoOn ? ecoHeat : heat, cooling: ecoOn ? ecoCool : cool)
    }

    var displayUnits: Int? {
        switch scale {
        case "CELSIUS": 0
        case "FAHRENHEIT": 1
        default: nil
        }
    }

    /// The props "configure" sets (section 5.1): the ranges by scale and eco, the modes by available modes.
    struct Props: Sendable, Equatable {
        var settableMin: Double
        var settableMax: Double
        var readableMin: Double
        var readableMax: Double
        var modes: Set<ClimateMode>
        var canTurnOff: Bool
    }

    var props: Props {
        // To a tenth: HomeKit steps by 0.1 from the minimum, so -17.778 would show 19.8 °C as 19.822.
        func celsius(_ fahrenheit: Double) -> Double { ((fahrenheit - 32) / 1.8 * 10).rounded() / 10 }
        var props = fahrenheit
            ? Props(settableMin: celsius(50), settableMax: celsius(90), readableMin: celsius(0), readableMax: celsius(160),
                    modes: climateModes, canTurnOff: canTurnOff)
            : Props(settableMin: 9, settableMax: 32, readableMin: -20, readableMax: 60, modes: climateModes, canTurnOff: canTurnOff)
        if ecoOn { props.settableMin = fahrenheit ? celsius(40) : 4.5 }
        return props
    }
}

/// A thermostat's accessory, and its fan's when `showFan` is on: the traits HomeKit reads, the commands its writes send.
final class NestThermostat: @unchecked Sendable {
    let accessory: Accessory
    let fanAccessory: Accessory?
    let props: ThermostatState.Props
    let climate: ClimateController
    private var service: Service { climate.service }
    private let eco: Characteristic
    private let fan: Service?
    private let cache: NIOLockedValueBox<SDMDevice>
    private let send: Commander
    private let options: NestOptions
    private let log: Logger

    /// The Eco characteristic (section 5.1): its UUID is the Homebridge plugin's, so its iid stays.
    static let ecoType = CharacteristicType(
        name: "Eco", uuid: HAPUUID("F66DE49D-792E-44A6-99C8-5E3576328BA1"), format: .bool, permissions: [.pairedRead, .pairedWrite, .events])

    /// A slider sends one command, not one per step of the drag (the thermostat allows 5 a minute): the controller
    /// gathers what is written within this window into one command (the default of `Dependencies.climateWindow`).
    static let writeWindow = Duration.milliseconds(600)

    static func accessoryID(_ device: SDMDevice) -> String { GoogleNestSDMPlugin.accessoryID(deviceID: device.name) }
    static func fanAccessoryID(_ device: SDMDevice) -> String { GoogleNestSDMPlugin.accessoryID(deviceID: "\(device.name) Fan") }

    /// `stale` runs on HomeKit's reads, so a cache older than a day is fetched again in the background.
    init(device: SDMDevice, options: NestOptions, window: Duration = writeWindow, send: @escaping Commander, log: Logger,
         stale: @escaping @Sendable () -> Void) {
        let state = ThermostatState(device)
        props = state.props
        let props = props
        cache = NIOLockedValueBox(device)
        self.send = send
        self.options = options
        self.log = log
        // Google refuses setpoints while the thermostat is off: they wait for the next mode.
        let capabilities = ClimateCapabilities(
            modes: props.modes, setpoints: .separate(autoSetpoint: false), range: props.settableMin...props.settableMax,
            step: 0.1, canTurnOff: props.canTurnOff, whileOff: .holds)
        let apply = NIOLockedValueBox<(@Sendable (ClimateCommand) async throws -> Void)?>(nil)
        climate = ClimateController(
            .thermostat, name: device.displayName, isPrimary: true, capabilities: capabilities,
            optional: [.currentRelativeHumidity, .currentTemperature.with(minValue: props.readableMin, maxValue: props.readableMax)],
            window: window) { command in try await apply.withLockedValue { $0 }?(command) }
        eco = climate.service.characteristic(adding: Self.ecoType)
        let name = device.displayName
        accessory = Accessory(
            id: Self.accessoryID(device), name: name, manufacturer: "Google Nest", model: "Thermostat", serialNumber: device.shortID,
            category: .thermostat, services: [climate.service], onIdentify: { [log] in log.info("\(name) identified!") })
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
        apply.withLockedValue { $0 = { [weak self] command in try await self?.applyClimate(command) } }
        // A thermostat built in eco shows the mode beneath it, which eco leaves as it was.
        if state.ecoOn, let mode = state.mode.flatMap(ThermostatState.climateMode) {
            var beneath = state.report
            beneath.mode = mode
            climate.update(beneath)
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

    /// Shows the cached traits: the climate through the controller, the rest here. A value outside the props is brought
    /// into them, as HomeKit would refuse it.
    func show() {
        let state = state
        climate.update(state.report)
        if let humidity = state.humidity { service.characteristic(.currentRelativeHumidity).value = .double(min(max(humidity, 0), 100)) }
        if let units = state.displayUnits { service.characteristic(.temperatureDisplayUnits).value = .int(units) }
        eco.value = .bool(state.ecoMode == "MANUAL_ECO")
        fan?.characteristic(.on).value = .bool(state.fanOn)
    }

    private func bindHandlers(stale: @escaping @Sendable () -> Void) {
        service.characteristic(.currentTemperature).onRead { [weak self] in
            stale()
            return self?.service.characteristic(.currentTemperature).value ?? .null
        }
        eco.onWrite { [weak self] value in
            guard let self else { return }
            let mode = value.boolValue == true ? "MANUAL_ECO" : "OFF"
            try await command("ThermostatEco.SetMode", ["mode": .string(mode)])
            show()
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

    /// Sends what HomeKit asked in Google's commands: Off or the mode first, then the setpoint the mode uses (SetHeat in
    /// HEAT, SetCool in COOL, SetRange with both ends in HEATCOOL, the other end from the cache when one moved).
    /// Google takes no setpoint in eco, and a mode uses only its own: a command whose setpoints are all of that kind is
    /// refused after its power and mode are sent (the Homebridge plugin refused them too).
    func applyClimate(_ command: ClimateCommand) async throws {
        let state = state
        let setpoints = command.target != nil || command.heating != nil || command.cooling != nil
        if command.power == false { try await self.command("ThermostatMode.SetMode", ["mode": "OFF"]) }
        var mode = state.mode
        // A turn-on carries the mode chosen.
        if let wanted = command.mode {
            let sdm = ThermostatState.sdmMode(wanted)
            guard state.availableModes.isEmpty || state.availableModes.contains(sdm) else {
                log.error("\(accessory.name): the thermostat does not have the mode \(sdm)")
                throw HAPStatusError(.invalidValueInRequest, reason: "The thermostat does not have this mode")
            }
            try await self.command("ThermostatMode.SetMode", ["mode": .string(sdm)])
            mode = sdm
        }
        if state.ecoOn, setpoints { throw refusedAfter(command, "Set the temperatures with eco off") }
        switch mode {
        case "HEAT":
            if let heat = command.heating {
                try await self.command("ThermostatTemperatureSetpoint.SetHeat", ["heatCelsius": .number(heat)])
            } else if command.cooling != nil {
                throw refusedAfter(command, "Set the cool-to temperature in COOL or HEATCOOL")
            }
        case "COOL":
            if let cool = command.cooling {
                try await self.command("ThermostatTemperatureSetpoint.SetCool", ["coolCelsius": .number(cool)])
            } else if command.heating != nil {
                throw refusedAfter(command, "Set the heat-to temperature in HEAT or HEATCOOL")
            }
        case "HEATCOOL":
            guard command.heating != nil || command.cooling != nil else { break }
            var range: [String: JSONValue] = [:]
            if let heat = command.heating ?? state.heat { range["heatCelsius"] = .number(heat) }
            if let cool = command.cooling ?? state.cool { range["coolCelsius"] = .number(cool) }
            try await self.command("ThermostatTemperatureSetpoint.SetRange", range)
        default:
            break
        }
        show()
    }

    /// Refuses a command's setpoints, its power and mode sent: shown first, so the controller puts the tile back to them.
    private func refusedAfter(_ command: ClimateCommand, _ reason: String) -> HAPStatusError {
        if command.power != nil || command.mode != nil {
            show()
            // Eco names no mode: the one sent shows as the mode beneath it.
            let state = state
            if state.ecoOn, let mode = command.mode {
                var beneath = state.report
                beneath.mode = mode
                climate.update(beneath)
            }
        }
        return refused(reason)
    }

    private func refused(_ reason: String) -> HAPStatusError {
        log.error("\(accessory.name): \(reason)")
        return HAPStatusError(.notAllowedInCurrentState, reason: reason)
    }

    /// Sends the command; on success its effect goes in the cache at once (the trait event that follows says the same).
    /// A command that fails is No Response in the Home app, not a success as in the Homebridge plugin.
    /// `update` is the traits the command changes: by default its parameters, on the trait it is named after.
    private func command(_ name: String, _ params: [String: JSONValue], update: [String: JSONValue]? = nil) async throws {
        let resource = cache.withLockedValue { $0.name }
        do {
            _ = try await send(resource, name, params)
        } catch {
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        let changed = update ?? [String(name.prefix { $0 != "." }): .object(params)]
        cache.withLockedValue { $0.apply(Dictionary(uniqueKeysWithValues: changed.map { ("sdm.devices.traits.\($0.key)", $0.value) })) }
    }
}
