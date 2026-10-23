import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// LG's AC operation modes (`airState.opMode`).
enum ACOpMode {
    nonisolated static let cool = 0.0
    nonisolated static let fan = 2.0
    nonisolated static let heat = 4.0
    nonisolated static let airClean = 5.0
    nonisolated static let auto = 6.0
    /// What the plugin uses when the mode is unknown.
    nonisolated static let undefined = -1.0
}

/// Wind strengths: 2 (low) to 6 (high) by steps of one, 8 automatic.
enum ACFan {
    nonisolated static let auto = 8
    nonisolated static let low = 2
    nonisolated static let high = 6
    nonisolated static let speeds = [2, 3, 4, 5, 6]
    nonisolated static let defaultPercent = 50

    /// A HomeKit percentage (0 to 100) as a wind strength, clamped; 0 is the lowest speed.
    nonisolated static func windStrength(percent: Double) -> Int {
        let p = percent.isFinite ? max(0, min(100, percent)) : 0
        let strength = Int((p / 100 * Double(high - low) + Double(low)).rounded(.toNearestOrAwayFromZero))
        return max(low, min(high, strength))
    }

    /// A wind strength as a percentage (1 to 100); automatic and unknown values are 50.
    nonisolated static func percent(windStrength: JSONValue?) -> Int {
        let number = JS.number(windStrength)
        if number.isNaN || number == Double(auto) || number < Double(low) || number > Double(high) { return defaultPercent }
        let percent = Int(((number - Double(low)) / Double(high - low) * 100).rounded(.toNearestOrAwayFromZero))
        return percent == 0 ? 1 : percent
    }
}

/// LG reports and takes temperatures in Celsius (0.5° steps) even when its unit is Fahrenheit; HomeKit works in
/// Celsius. In Fahrenheit the model's `TempCelToFah` / `TempFahToCel` tables round-trip values so HomeKit
/// shows the whole °F the unit shows; without the tables, the arithmetic.
struct TemperatureConverter: Sendable {
    let isFahrenheit: Bool
    let deviceModel: DeviceModel?

    nonisolated static func cToF(_ celsius: Double) -> Double { (celsius * 9 / 5 + 32).rounded(.toNearestOrAwayFromZero) }
    nonisolated static func fToC(_ fahrenheit: Double) -> Double { ((fahrenheit - 32) * 5 / 9 * 100).rounded(.toNearestOrAwayFromZero) / 100 }
    nonisolated static func roundToHalf(_ value: Double) -> Double { (value * 2).rounded(.toNearestOrAwayFromZero) / 2 }

    private func lookup(_ key: String, _ value: Double) -> Double? {
        guard let mapped = deviceModel?.lookupMonitorValue(key, JS.format(value)), JS.string(mapped) != "" else { return nil }
        let number = JS.number(mapped)
        return number.isNaN ? nil : number
    }

    /// HomeKit Celsius to the device's value.
    func fromHomeKit(_ celsius: Double) -> Double {
        guard isFahrenheit, !celsius.isNaN else { return celsius }
        let fahrenheit = Self.cToF(celsius)
        return lookup("TempFahToCel", fahrenheit) ?? Self.roundToHalf(Self.fToC(fahrenheit))
    }

    /// The device's value to HomeKit Celsius, snapped to the whole °F the device shows.
    func toHomeKit(_ value: Double) -> Double {
        guard isFahrenheit, !value.isNaN else { return value }
        return Self.fToC(lookup("TempCelToFah", value) ?? Self.cToF(value))
    }
}

/// A view of an AC's flat snapshot (`airState.operation`…).
struct ACStatus {
    let data: [String: JSONValue]
    let deviceModel: DeviceModel
    let converter: TemperatureConverter

    init(data: [String: JSONValue], deviceModel: DeviceModel, temperatureUnit: String?) {
        self.data = data
        self.deviceModel = deviceModel
        converter = TemperatureConverter(isFahrenheit: (temperatureUnit ?? "").lowercased() == "f", deviceModel: deviceModel)
    }

    /// The mode as a number, nil when missing (JavaScript compares it strictly).
    var opMode: Double? { data["airState.opMode"]?.doubleValue }
    var isPowerOn: Bool { JS.truthy(data["airState.operation"]) }

    var currentRelativeHumidity: Double {
        let humidity = JS.parseInt(data["airState.humidity.current"])
        return humidity > 100 ? humidity / 10 : humidity
    }

    var currentTemperature: Double { converter.toHomeKit(JS.number(data["airState.tempState.current"])) }
    var targetTemperature: Double { converter.toHomeKit(JS.number(data["airState.tempState.target"])) }
    var targetTemperatureLG: Double { JS.number(data["airState.tempState.target"]) }

    struct AirQuality: Equatable {
        var isOn: Bool
        var overall: Double
        var pm2: Double
        var pm10: Double
    }

    var airQuality: AirQuality? {
        guard data["airState.quality.overall"] != nil || data["airState.quality.PM2"] != nil || data["airState.quality.PM10"] != nil else { return nil }
        return AirQuality(
            isOn: isPowerOn || JS.truthy(data["airState.quality.sensorMon"]), overall: JS.parseInt(data["airState.quality.overall"]),
            pm2: JS.parseInt(data["airState.quality.PM2"]), pm10: JS.parseInt(data["airState.quality.PM10"]))
    }

    var windStrength: Int { ACFan.percent(windStrength: data["airState.windStrength"]) }
    var isWindStrengthAuto: Bool { JS.number(data["airState.windStrength"]) == Double(ACFan.auto) }

    var isSwingOn: Bool {
        let vertical = JS.number(data["airState.wDir.vStep"])
        let horizontal = JS.number(data["airState.wDir.hStep"])
        return (((vertical.isNaN ? 0 : vertical) / 100).rounded(.down) + ((horizontal.isNaN ? 0 : horizontal) / 100).rounded(.down)) != 0
    }

    var isLightOn: Bool { JS.truthy(data["airState.lightingState.displayControl"]) }

    var currentConsumption: Double {
        let consumption = JS.number(data["airState.energy.onCurrent"])
        return consumption.isNaN ? 0 : consumption / 100
    }

    /// `AWHP` (air-to-water heat pump) or `RAC`.
    var type: String { deviceModel.data["Info"]?["modelType"].flatMap { JS.truthy($0) ? JS.string($0) : nil } ?? "RAC" }

    struct Range: Equatable {
        var min: Double
        var max: Double
        var step: Double
    }

    /// The temperature range from the model's limit enums, else `airState.tempState.limitMin`, else
    /// `airState.tempState.target`; nil when the model has neither.
    func temperatureRange(_ limits: (ModelValue?, ModelValue?)) -> Range? {
        var range = Range(min: 0, max: 0, step: 0.01)
        if let low = limits.0, let high = limits.1 {
            let lows = low.options.values.compactMap(\.doubleValue).filter { $0 != 0 }
            let highs = high.options.values.compactMap(\.doubleValue).filter { $0 != 0 }
            if let minimum = lows.min() { range.min = minimum }
            if let maximum = highs.max() { range.max = maximum }
        }
        if range.min != 0, range.max != 0 { return range }
        // Then `airState.tempState.limitMin`, then `airState.tempState.target`, as the Homebridge plugin falls through.
        if case .range(let min?, let max?, let step)? = deviceModel.value("airState.tempState.limitMin"), min != 0, max != 0 {
            return Range(min: min, max: max, step: step)
        }
        guard let target = deviceModel.value("airState.tempState.target") else { return nil }
        if case .range(let min, let max, let step) = target { return Range(min: min ?? .nan, max: max ?? .nan, step: step) }
        // Not a range: JavaScript reads undefined bounds, so the HomeKit defaults apply.
        return Range(min: .nan, max: .nan, step: .nan)
    }

    func heatingLimits() -> (ModelValue?, ModelValue?) {
        type == "AWHP"
            ? (deviceModel.value("support.airState.tempState.waterTempHeatMin"), deviceModel.value("support.airState.tempState.waterTempHeatMax"))
            : (deviceModel.value("support.heatLowLimit"), deviceModel.value("support.heatHighLimit"))
    }

    func coolingLimits() -> (ModelValue?, ModelValue?) {
        type == "AWHP"
            ? (deviceModel.value("support.airState.tempState.waterTempCoolMin"), deviceModel.value("support.airState.tempState.waterTempCoolMax"))
            : (deviceModel.value("support.coolLowLimit"), deviceModel.value("support.coolHighLimit"))
    }
}

/// An air conditioner (or heat pump): a HeaterCooler with fan speed, swing and an Eve energy counter, and the
/// optional sensors, light, fan, mode switches (jet, quiet, energy save, air purify) and op-mode buttons the
/// options and the model allow. A command every minute keeps the unit pushing its temperature.
class AirConditioner: BaseDevice {
    nonisolated static let homeKitTemperatureMin = 10.0
    nonisolated static let homeKitTemperatureMax = 38.0
    nonisolated static let monitorTimeoutValue = "70"
    nonisolated static let jetModeModels = ["RAC_056905"]
    nonisolated static let quietModeModels = ["WINF_056905"]
    nonisolated static let energySaveModeModels = ["WINF_056905", "RAC_056905"]

    var service: Service!
    var serviceAirQuality: Service?
    var serviceSensor: Service?
    var serviceHumiditySensor: Service?
    var serviceLight: Service?
    var serviceFanV2: Service?
    var serviceJetMode: Service?
    var serviceQuietMode: Service?
    var serviceEnergySaveMode: Service?
    var serviceAirClean: Service?
    var serviceLabelButtons: Service?
    var buttonServices: [(service: Service, opMode: Double)] = []
    /// The last target state HomeKit chose, restored when a button is switched off.
    var currentTargetState = 2.0
    private var monitorTask: Task<Void, Never>?

    struct ModeSwitch {
        var dataKey: String
        var label: String
        /// Allowed only while on and cooling.
        var requireCool: Bool
        var service: Service?
        var enabled: Bool
    }

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let name = device.name

        service = addService(.heaterCooler, name: name, optional: heaterCoolerCharacteristics() + [.swingMode],
            extra: [Characteristic(.totalConsumption)])
        configureHeaterCooler()

        if config.flag("ac_air_quality"), status.airQuality != nil {
            serviceAirQuality = addService(.airQualitySensor, name: "Air Quality", optional: [.pm2_5Density, .pm10Density])
        }
        if config.flag("ac_temperature_sensor") {
            let sensor = addService(.temperatureSensor, name: "Temperature Sensor", optional: [.statusActive])
            sensor.set(.statusActive, false)
            sensor.linked = [service]
            serviceSensor = sensor
        }
        if config.flag("ac_humidity_sensor") {
            let sensor = addService(.humiditySensor, name: "Humidity Sensor", optional: [.statusActive])
            sensor.set(.statusActive, false)
            sensor.linked = [service]
            serviceHumiditySensor = sensor
        }
        if config.flag("ac_led_control") {
            let light = addService(.lightbulb, name: "Light")
            light.characteristic(.on).onSet { [weak self] value in try await self?.setLight(value) }
            light.set(.on, false)
            light.linked = [service]
            serviceLight = light
        }
        if config.flag("ac_fan_control") { createFanService() }

        if config.flag("ac_jet_control"), isJetModeEnabled {
            serviceJetMode = modeSwitchService("Jet Mode", configuredName: "\(name) Jet Mode") { [weak self] value in try await self?.setJetModeActive(value) }
        }
        if Self.quietModeModels.contains(device.model) {
            serviceQuietMode = modeSwitchService("Quiet mode", configuredName: "Quiet mode") { [weak self] value in try await self?.setQuietModeActive(value) }
        }
        if Self.energySaveModeModels.contains(device.model), config.flag("ac_energy_save") {
            serviceEnergySaveMode = modeSwitchService("Energy save", configuredName: "\(name) Energy save") { [weak self] value in try await self?.setEnergySaveActive(value) }
        }
        if hasModelFeature("airClean"), config.flag("ac_air_clean") {
            serviceAirClean = modeSwitchService("Air Purify", configuredName: "\(name) Air Purify") { [weak self] value in try await self?.setAirCleanActive(value) }
        }
        setupButtons()
        startMonitor()
    }

    var status: ACStatus { ACStatus(data: device.snapshot, deviceModel: device.deviceModel, temperatureUnit: config.string("ac_temperature_unit")) }

    // MARK: Building

    /// The HeaterCooler's target states `ac_mode` allows and the threshold ranges of the model.
    func heaterCoolerCharacteristics() -> [CharacteristicType] {
        let status = status
        let validStates: [String: [Int]] = ["BOTH": [0, 1, 2], "COOLING": [2], "HEATING": [1]]
        var types: [CharacteristicType] = []
        if let valid = config.mode("ac_mode").flatMap({ validStates[$0] }) { types.append(CharacteristicType.targetHeaterCoolerState.valid(valid)) }
        if let heat = status.temperatureRange(status.heatingLimits()) {
            types.append(temperatureProps(.heatingThresholdTemperature, status: status, range: heat))
        } else {
            types.append(.heatingThresholdTemperature)
        }
        if let cool = status.temperatureRange(status.coolingLimits()) {
            types.append(temperatureProps(.coolingThresholdTemperature, status: status, range: cool))
        } else {
            types.append(.coolingThresholdTemperature)
        }
        types.append(CharacteristicType.rotationSpeed.props(min: 0, max: 100, step: 1))
        return types
    }

    private func temperatureProps(_ type: CharacteristicType, status: ACStatus, range: ACStatus.Range) -> CharacteristicType {
        let low = status.converter.toHomeKit(range.min)
        let high = status.converter.toHomeKit(range.max)
        let minimum = max(Self.homeKitTemperatureMin, low.isNaN || low == 0 ? Self.homeKitTemperatureMin : low)
        let maximum = min(Self.homeKitTemperatureMax, high.isNaN || high == 0 ? Self.homeKitTemperatureMax : high)
        return type.props(min: minimum, max: maximum, step: range.step.isNaN || range.step == 0 ? 0.01 : range.step)
    }

    func configureHeaterCooler() {
        service.set(.name, device.name)
        service.characteristic(.active).onSet { [weak self] value in try await self?.setActive(value) }
        if let mode = config.mode("ac_mode"), ["BOTH", "COOLING", "HEATING"].contains(mode) {
            service.set(.targetHeaterCoolerState, mode == "HEATING" ? 1 : 2)
        }
        service.characteristic(.targetHeaterCoolerState).onSet { [weak self] value in try await self?.setTargetState(value) }
        let current = status.currentTemperature
        if !current.isNaN, current != 0 { service.set(.currentTemperature, current) }
        service.characteristic(.coolingThresholdTemperature).onSet { [weak self] value in try await self?.setTargetTemperature(value) }
        service.characteristic(.heatingThresholdTemperature).onSet { [weak self] value in try await self?.setTargetTemperature(value) }
        if !config.flag("ac_fan_control") {
            service.characteristic(.rotationSpeed).onSet { [weak self] value in try await self?.setFanSpeed(value) }
        }
        service.characteristic(.swingMode).onSet { [weak self] value in try await self?.setSwingMode(value) }
    }

    private func modeSwitchService(_ name: String, configuredName: String, _ handler: @escaping @ThinQActor @Sendable (HAPValue) async throws -> Void) -> Service {
        let service = addService(.switch, name: name)
        service.set(.configuredName, configuredName)
        service.characteristic(.on).onSet(handler)
        return service
    }

    func createFanService() {
        let name = "\(device.name) Fan"
        let fan = addService(.fanv2, name: name, optional: [
            CharacteristicType.currentFanState.valid([0, 2]), .targetFanState, CharacteristicType.rotationSpeed.props(min: 0, max: 100, step: 1), .swingMode,
        ])
        fan.linked = [service]
        fan.characteristic(.active).onGet { [weak self] in .int(self?.status.isPowerOn == true ? 1 : 0) }
            .onSet { [weak self] value in
                guard let self else { return }
                // Not switchable from the Home app: back to the real state.
                if status.isPowerOn == Normalize.boolean(value) { return }
                after(.milliseconds(100)) { [weak self] in
                    guard let self, let fan = serviceFanV2 else { return }
                    fan.set(.active, status.isPowerOn ? 1 : 0)
                    fan.set(.rotationSpeed, status.windStrength)
                }
            }
        fan.set(.active, 0)
        fan.characteristic(.currentFanState).onGet { [weak self] in .int(self?.status.isPowerOn == true ? 2 : 0) }
        fan.set(.currentFanState, 0)
        fan.characteristic(.targetFanState).onSet { [weak self] value in try await self?.setFanState(value) }
        fan.characteristic(.rotationSpeed).onSet { [weak self] value in try await self?.setFanSpeed(value) }
        fan.characteristic(.swingMode).onSet { [weak self] value in try await self?.setSwingMode(value) }
        fan.set(.swingMode, status.isSwingOn ? 1 : 0)
        serviceFanV2 = fan
    }

    /// `ac_buttons`: a switch per button, grouped under a service label, on while the unit is in its mode.
    func setupButtons() {
        let buttons = config.acButtons
        guard !buttons.isEmpty else { return }
        let label = addService(.serviceLabel, name: "Buttons", subtype: "Buttons", configuredName: false)
        serviceLabelButtons = label
        for button in buttons {
            let opMode = Double(button.opMode)
            let service = addService(.switch, name: button.name, subtype: button.name)
            service.characteristic(.on).onGet { [weak self] in .bool(self?.status.opMode == opMode) }
                .onSet { [weak self] value in try await self?.handleButtonOpMode(value, opMode: opMode) }
            buttonServices.append((service, opMode))
        }
        label.linked = buttonServices.map(\.service)
    }

    // MARK: Monitoring

    /// `airState.mon.timeout` every minute so the unit keeps pushing temperatures; skipped while it is off
    /// (LG answers 400 / 9006 then) and for models that do not take it.
    func startMonitor() {
        stopMonitor()
        guard !(DeviceRegistry.acModelFeatures["noMonitorTimeout"] ?? []).contains(where: { device.model.contains($0) }) else { return }
        monitorTask = Task { @ThinQActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                guard device.online, status.isPowerOn else { continue }
                do {
                    _ = try await thinq.deviceControl(device.id, values: ["dataKey": "airState.mon.timeout", "dataValue": .string(Self.monitorTimeoutValue)],
                        command: "Set", ctrlKey: "allEventEnable", ctrlPath: "control", quiet: true)
                } catch {
                    logger.debug("Error sending monitor timeout command: \(error)")
                }
            }
        }
    }

    func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    override func destroy() {
        stopMonitor()
        super.destroy()
    }

    // MARK: State

    func setSnapshotValues(_ values: [String: JSONValue]) {
        var snapshot = device.snapshot
        for (key, value) in values { snapshot[key] = value }
        device.snapshot = snapshot
    }

    /// A command that must be accepted: a failure or a refusal is a communication failure for HomeKit.
    func sendCommand(_ payload: [String: JSONValue], label: String, command: String = "Set", ctrlKey: String? = nil) async throws {
        try await sendAccepted(payload, command: command, ctrlKey: ctrlKey ?? "basicCtrl",
            failed: { logger.error("[\(device.name)] Error setting \(label): \($0)") },
            refused: { logger.warning("[\(device.name)] Device did not accept \(label) command") })
    }

    var isJetModeEnabled: Bool { Self.jetModeModels.contains(device.model) }

    var modeSwitches: [ModeSwitch] {
        let model = device.model
        return [
            ModeSwitch(dataKey: "airState.wMode.jet", label: "jet mode", requireCool: true, service: serviceJetMode, enabled: isJetModeEnabled),
            ModeSwitch(dataKey: "airState.miscFuncState.silentAWHP", label: "quiet mode", requireCool: true, service: serviceQuietMode,
                enabled: Self.quietModeModels.contains(model)),
            ModeSwitch(dataKey: "airState.powerSave.basic", label: "energy save mode", requireCool: true, service: serviceEnergySaveMode,
                enabled: Self.energySaveModeModels.contains(model) && config.flag("ac_energy_save")),
            ModeSwitch(dataKey: "airState.wMode.airClean", label: "air clean mode", requireCool: true, service: serviceAirClean,
                enabled: hasModelFeature("airClean") && config.flag("ac_air_clean")),
            ModeSwitch(dataKey: "airState.lightingState.displayControl", label: "light", requireCool: false, service: serviceLight,
                enabled: config.flag("ac_led_control")),
        ]
    }

    func modeSwitch(_ dataKey: String) -> ModeSwitch { modeSwitches.first { $0.dataKey == dataKey }! }

    func updateModeSwitch(_ modeSwitch: ModeSwitch) {
        guard let service = modeSwitch.service, modeSwitch.enabled else { return }
        service.set(.on, JS.truthy(device.snapshot[modeSwitch.dataKey]))
    }

    func setModeSwitch(_ modeSwitch: ModeSwitch, _ value: HAPValue) async throws {
        let status = status
        guard status.isPowerOn, !modeSwitch.requireCool || status.opMode == ACOpMode.cool else {
            logger.debug("\(modeSwitch.label) is not supported in the current state. Power: \(status.isPowerOn), Mode: \(status.opMode.map { JS.format($0) } ?? "undefined")")
            let dataKey = modeSwitch.dataKey
            after(.milliseconds(100)) { [weak self] in
                guard let self else { return }
                updateModeSwitch(self.modeSwitch(dataKey))
            }
            return
        }
        let dataValue: JSONValue = .number(Normalize.boolean(value) ? 1 : 0)
        try await sendCommand(["dataKey": .string(modeSwitch.dataKey), "dataValue": dataValue], label: modeSwitch.label)
        setSnapshotValues([modeSwitch.dataKey: dataValue])
        updateModeSwitch(self.modeSwitch(modeSwitch.dataKey))
    }

    func setEnergySaveActive(_ value: HAPValue) async throws { try await setModeSwitch(modeSwitch("airState.powerSave.basic"), value) }
    func setAirCleanActive(_ value: HAPValue) async throws { try await setModeSwitch(modeSwitch("airState.wMode.airClean"), value) }
    func setQuietModeActive(_ value: HAPValue) async throws { try await setModeSwitch(modeSwitch("airState.miscFuncState.silentAWHP"), value) }
    func setJetModeActive(_ value: HAPValue) async throws { try await setModeSwitch(modeSwitch("airState.wMode.jet"), value) }
    func setLight(_ value: HAPValue) async throws { try await setModeSwitch(modeSwitch("airState.lightingState.displayControl"), value) }

    /// AUTO or MANUAL (high).
    func setFanState(_ value: HAPValue) async throws {
        guard status.isPowerOn else {
            logger.debug("Power is off, cannot set fan state")
            return
        }
        let isAuto = Normalize.number(value).map { $0 == 1 } ?? Normalize.boolean(value)
        let windStrength = isAuto ? ACFan.auto : ACFan.high
        try await sendCommand(["dataKey": "airState.windStrength", "dataValue": .number(Double(windStrength))], label: "fan state")
        setSnapshotValues(["airState.windStrength": .number(Double(windStrength))])
        updateAccessoryFanStateCharacteristics()
        updateAccessoryFanV2Characteristic()
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        updateAccessoryActiveCharacteristic()
        updateAccessoryCurrentTemperatureCharacteristic()
        updateAccessoryStateCharacteristics()
        updateAccessoryTemperatureCharacteristics()
        updateAccessoryFanStateCharacteristics()
        updateAccessoryTotalConsumptionCharacteristic()
        updateAccessoryAirQualityCharacteristic()
        updateAccessoryTemperatureSensorCharacteristic()
        updateAccessoryHumiditySensorCharacteristic()
        updateAccessoryFanV2Characteristic()
        for modeSwitch in modeSwitches { updateModeSwitch(modeSwitch) }
    }

    func updateAccessoryActiveCharacteristic() {
        service.set(.active, status.isPowerOn ? 1 : 0)
    }

    func updateAccessoryCurrentTemperatureCharacteristic() {
        service.set(.currentTemperature, status.currentTemperature)
    }

    /// Current and target states from power and mode; AUTO (or unknown) compares the temperatures.
    func updateAccessoryStateCharacteristics() {
        let status = status
        let setState = { (current: Int, target: Int) in
            self.service.set(.currentHeaterCoolerState, current)
            self.service.set(.targetHeaterCoolerState, target)
        }
        if !status.isPowerOn {
            service.set(.currentHeaterCoolerState, 0)
        } else if status.opMode == ACOpMode.cool {
            setState(3, 2)
        } else if status.opMode == ACOpMode.heat {
            setState(2, 1)
        } else if let mode = status.opMode, mode == ACOpMode.auto || mode == ACOpMode.undefined {
            if status.currentTemperature < status.targetTemperature { setState(2, 1) } else { setState(3, 2) }
        }
    }

    /// The threshold of the current state takes the target temperature, clamped to its range.
    func updateAccessoryTemperatureCharacteristics() {
        let temperature = status.targetTemperature
        let state = service.value(.currentHeaterCoolerState)?.intValue
        func update(_ type: CharacteristicType) {
            guard let characteristic = service[type] else { return }
            let clamped = max(characteristic.type.minValue ?? Self.homeKitTemperatureMin, min(characteristic.type.maxValue ?? Self.homeKitTemperatureMax, temperature))
            service.set(type, clamped)
        }
        if state == 2 { update(.heatingThresholdTemperature) }
        if state == 3 { update(.coolingThresholdTemperature) }
    }

    func updateAccessoryFanStateCharacteristics() {
        service.set(.rotationSpeed, status.windStrength)
        service.set(.swingMode, status.isSwingOn ? 1 : 0)
    }

    func updateAccessoryTotalConsumptionCharacteristic() {
        service.set(.totalConsumption, status.currentConsumption)
    }

    func updateAccessoryAirQualityCharacteristic() {
        guard config.flag("ac_air_quality"), let serviceAirQuality, let quality = status.airQuality, quality.isOn else { return }
        serviceAirQuality.set(.airQuality, quality.overall)
        if quality.pm2 != 0, !quality.pm2.isNaN { serviceAirQuality.set(.pm2_5Density, quality.pm2) }
        if quality.pm10 != 0, !quality.pm10.isNaN { serviceAirQuality.set(.pm10Density, quality.pm10) }
    }

    func updateAccessoryTemperatureSensorCharacteristic() {
        guard config.flag("ac_temperature_sensor"), let serviceSensor else { return }
        serviceSensor.set(.currentTemperature, status.currentTemperature)
        serviceSensor.set(.statusActive, status.isPowerOn)
    }

    func updateAccessoryHumiditySensorCharacteristic() {
        guard config.flag("ac_humidity_sensor"), let serviceHumiditySensor else { return }
        serviceHumiditySensor.set(.currentRelativeHumidity, status.currentRelativeHumidity)
        serviceHumiditySensor.set(.statusActive, status.isPowerOn)
    }

    func updateAccessoryFanV2Characteristic() {
        guard config.flag("ac_fan_control"), let fan = serviceFanV2 else { return }
        let status = status
        fan.set(.active, status.isPowerOn ? 1 : 0)
        if status.isWindStrengthAuto {
            fan.set(.targetFanState, 1)
        } else {
            fan.set(.targetFanState, 0)
            fan.set(.rotationSpeed, status.windStrength)
        }
        fan.set(.swingMode, status.isSwingOn ? 1 : 0)
    }

    // MARK: Commands

    /// HomeKit's target state as LG's mode.
    func setTargetState(_ value: HAPValue) async throws {
        logger.debug("Set target AC mode = \(value)")
        guard let target = Normalize.number(value) else { return }
        currentTargetState = target
        let modes: [Double: Double] = [0: ACOpMode.auto, 1: ACOpMode.heat, 2: ACOpMode.cool]
        guard let opMode = modes[target] ?? status.opMode, opMode != status.opMode else { return }
        guard try await setOpMode(opMode) else { throw Self.communicationFailure() }
        setSnapshotValues(["airState.opMode": .number(opMode)])
    }

    func setActive(_ value: HAPValue) async throws {
        let isOn = Normalize.boolean(value)
        logger.debug("Set power on = \(isOn ? 1 : 0)  current status = \(status.isPowerOn)")
        if status.isPowerOn == isOn {
            logger.debug("Power state already matches incoming value; skipping deviceControl.")
            return
        }
        try await sendCommand(["dataKey": "airState.operation", "dataValue": .number(isOn ? 1 : 0)], label: "active state", command: "Operation")
        setSnapshotValues(["airState.operation": .number(isOn ? 1 : 0)])
        updateAccessoryActiveCharacteristic()
    }

    func setTargetTemperature(_ value: HAPValue) async throws {
        let status = status
        guard status.isPowerOn else {
            logger.error("Power is off, cannot set target temperature")
            return
        }
        guard let celsius = Normalize.number(value) else {
            logger.error("Invalid temperature value: \(value)")
            return
        }
        let temperature = status.converter.fromHomeKit(celsius)
        guard !temperature.isNaN else {
            logger.error("Converted temperature is not a valid number: \(temperature)")
            return
        }
        if temperature == status.targetTemperatureLG {
            logger.debug("Target temperature is identical to current setting; skipping.")
            return
        }
        try await sendCommand(["dataKey": "airState.tempState.target", "dataValue": .number(temperature)], label: "target temperature")
        setSnapshotValues(["airState.tempState.target": .number(temperature)])
        updateAccessoryTemperatureCharacteristics()
    }

    func setFanSpeed(_ value: HAPValue) async throws {
        guard status.isPowerOn, let percent = Normalize.number(value) else { return }
        let windStrength = ACFan.windStrength(percent: percent)
        logger.debug("Set fan speed = \(JS.format(percent))% -> windStrength = \(windStrength)")
        try await sendCommand(["dataKey": "airState.windStrength", "dataValue": .number(Double(windStrength))], label: "fan speed")
        setSnapshotValues(["airState.windStrength": .number(Double(windStrength))])
    }

    /// Swing on or off along the axes `ac_swing_mode` names; the direction itself is not controllable.
    func setSwingMode(_ value: HAPValue) async throws {
        guard status.isPowerOn else {
            logger.debug("Power is off, cannot set swing mode")
            return
        }
        let swing: JSONValue = Normalize.boolean(value) ? "100" : "0"
        switch config.mode("ac_swing_mode") {
        case "BOTH":
            try await sendCommand([
                "dataKey": .null, "dataValue": .null, "dataSetList": ["airState.wDir.vStep": swing, "airState.wDir.hStep": swing], "dataGetList": .null,
            ], label: "swing mode", ctrlKey: "favoriteCtrl")
            setSnapshotValues(["airState.wDir.vStep": swing, "airState.wDir.hStep": swing])
        case "VERTICAL":
            try await sendCommand(["dataKey": "airState.wDir.vStep", "dataValue": swing], label: "swing mode")
            setSnapshotValues(["airState.wDir.vStep": swing])
        case "HORIZONTAL":
            try await sendCommand(["dataKey": "airState.wDir.hStep", "dataValue": swing], label: "swing mode")
            setSnapshotValues(["airState.wDir.hStep": swing])
        default:
            break
        }
        updateAccessoryFanStateCharacteristics()
        updateAccessoryFanV2Characteristic()
    }

    /// False (and logged) when the mode was not set.
    func setOpMode(_ opMode: Double) async throws -> Bool {
        do {
            return try await thinq.deviceControl(device.id, values: ["dataKey": "airState.opMode", "dataValue": .number(opMode)])
        } catch {
            logger.error("Error setting operation mode: \(error)")
            return false
        }
    }

    /// On: the button's mode. Off: back to COOL and the target state HomeKit last chose.
    func handleButtonOpMode(_ value: HAPValue, opMode: Double) async throws {
        if Normalize.boolean(value) {
            if status.opMode != opMode {
                guard try await setOpMode(opMode) else { throw Self.communicationFailure() }
                setSnapshotValues(["airState.opMode": .number(opMode)])
            }
        } else {
            guard try await setOpMode(ACOpMode.cool) else { throw Self.communicationFailure() }
            setSnapshotValues(["airState.opMode": .number(ACOpMode.cool)])
            try await setTargetState(.double(currentTargetState))
        }
    }
}

/// `setTimeout` on the ThinQ actor, not cancellable.
@ThinQActor
func after(_ delay: Duration, _ action: @escaping @ThinQActor () -> Void) {
    Task { @ThinQActor in
        try? await Task.sleep(for: delay)
        action()
    }
}
