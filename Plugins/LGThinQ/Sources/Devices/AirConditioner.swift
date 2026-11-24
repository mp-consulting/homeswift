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

    /// The unit's power draw now, in watts (`airState.energy.onCurrent`); nil when the snapshot has none. A power
    /// reading, not an energy counter: it falls back to zero when the unit stops.
    var power: Double? {
        let watts = JS.number(data["airState.energy.onCurrent"])
        return watts.isNaN ? nil : max(watts, 0)
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
    var climate: ClimateController!
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
    /// The last Climate Mode HomeKit chose, restored when a button is switched off.
    var lastClimateMode = ClimateMode.cool
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

        // Its power as Current Consumption (watts), which the bridge follows as the unit's Meter. Never Total
        // Consumption: the bridge reads that as a kWh counter, and onCurrent is a power that rises and falls.
        var extra = [Characteristic(.configuredName, value: .string(name))]
        if reportsPower { extra.append(Characteristic(EveCharacteristic.currentConsumption)) }
        climate = ClimateController(.heaterCooler, name: name, subtype: name, capabilities: climateCapabilities(),
                                    optional: climateCharacteristics() + [.swingMode], extra: extra) { [weak self] command in
            try await self?.applyClimate(command)
        }
        service = append(climate.service)
        for axis in supportedSwingAxes {
            service.characteristic(adding: axis.characteristic).onSet { [weak self] value in
                try await self?.setSwingAxis(axis, enabled: Normalize.boolean(value))
            }
        }
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

    /// What the unit can do: the modes `ac_mode` allows, the model's heating and cooling ranges, and setpoints held
    /// while it is off (LG refuses them then). One target behind both thresholds.
    func climateCapabilities() -> ClimateCapabilities {
        let modes: [String: Set<ClimateMode>] = ["BOTH": [.auto, .heat, .cool], "COOLING": [.cool], "HEATING": [.heat]]
        let heating = climateRange(status.heatingLimits())
        let cooling = climateRange(status.coolingLimits())
        return ClimateCapabilities(modes: config.mode("ac_mode").flatMap { modes[$0] } ?? [.auto, .heat, .cool], setpoints: .single,
                                   heatingRange: heating.range, coolingRange: cooling.range, step: heating.step ?? cooling.step ?? 0.5, whileOff: .holds)
    }

    /// A model range in HomeKit's Celsius, within HomeKit's bounds; its step when the model has one.
    func climateRange(_ limits: (ModelValue?, ModelValue?)) -> (range: ClosedRange<Double>, step: Double?) {
        let fallback = Self.homeKitTemperatureMin...Self.homeKitTemperatureMax
        guard let range = status.temperatureRange(limits) else { return (fallback, nil) }
        let low = status.converter.toHomeKit(range.min)
        let high = status.converter.toHomeKit(range.max)
        let minimum = max(Self.homeKitTemperatureMin, low.isNaN || low == 0 ? Self.homeKitTemperatureMin : low)
        let maximum = min(Self.homeKitTemperatureMax, high.isNaN || high == 0 ? Self.homeKitTemperatureMax : high)
        let step = range.step.isNaN || range.step <= 0 || range.step < 0.5 ? nil : range.step
        return (minimum <= maximum ? minimum...maximum : fallback, step)
    }

    /// The unit's own characteristics on the Heater Cooler: its fan speed.
    func climateCharacteristics() -> [CharacteristicType] {
        [CharacteristicType.rotationSpeed.props(min: 0, max: 100, step: 1)]
    }

    func configureHeaterCooler() {
        service.set(.name, device.name)
        climate.update(climateReport())
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
        climate.update(climateReport())
        updateAccessoryFanStateCharacteristics()
        updateAccessoryCurrentConsumptionCharacteristic()
        updateAccessoryAirQualityCharacteristic()
        updateAccessoryTemperatureSensorCharacteristic()
        updateAccessoryHumiditySensorCharacteristic()
        updateAccessoryFanV2Characteristic()
        for modeSwitch in modeSwitches { updateModeSwitch(modeSwitch) }
    }

    /// The unit's state for the controller: dry, fan, air clean and unknown modes are Other Modes.
    func climateReport() -> ClimateReport {
        let status = status
        let modes: [Double: ClimateMode] = [ACOpMode.cool: .cool, ACOpMode.heat: .heat, ACOpMode.auto: .auto]
        let current = status.currentTemperature, target = status.targetTemperature
        return ClimateReport(power: status.isPowerOn, mode: status.opMode.flatMap { modes[$0] },
                             current: current.isNaN || current == 0 ? nil : current, target: target.isNaN ? nil : target)
    }

    static func swingKey(_ axis: ClimateSwing) -> String {
        axis == .vertical ? "airState.wDir.vStep" : "airState.wDir.hStep"
    }

    /// The model's key for an axis's step, whose "0" stops it and "100" swings it (ThinQ1 names it otherwise).
    func swingModelKey(_ axis: ClimateSwing) -> String { Self.swingKey(axis) }

    /// Whether the device reports an axis yet (ThinQ1's status always holds both).
    func reportsSwing(_ axis: ClimateSwing) -> Bool { device.snapshot[Self.swingKey(axis)] != nil }

    /// Sends an axis's step.
    func sendSwing(_ axis: ClimateSwing, _ value: JSONValue) async throws {
        try await sendCommand(["dataKey": .string(Self.swingKey(axis)), "dataValue": value], label: "\(axis.rawValue) swing")
    }

    var supportedSwingAxes: [ClimateSwing] {
        ClimateSwing.allCases.filter { axis in
            let options = device.deviceModel.value(swingModelKey(axis))?.options ?? [:]
            return options["0"] != nil && options["100"] != nil && reportsSwing(axis)
        }
    }

    func setSwingAxis(_ axis: ClimateSwing, enabled: Bool) async throws {
        // Ignored while off, as Swing Mode is: show the device's state again rather than the value written.
        guard supportedSwingAxes.contains(axis), status.isPowerOn else { updateAccessoryCharacteristic(device); return }
        let value: JSONValue = enabled ? "100" : "0"
        try await sendSwing(axis, value)
        setSnapshotValues([Self.swingKey(axis): value])
        updateAccessoryCharacteristic(device)
    }

    func updateAccessoryFanStateCharacteristics() {
        for axis in ClimateSwing.allCases {
            service[axis.characteristic]?.value = .bool(JS.number(device.snapshot[Self.swingKey(axis)]) >= 100)
        }
        service.set(.rotationSpeed, status.windStrength)
        service.set(.swingMode, status.isSwingOn ? 1 : 0)
    }

    /// Whether the unit reports its power: ThinQ2 units do; ThinQ1 ones have no reading (`AirConditionerV1`).
    var reportsPower: Bool { true }

    func updateAccessoryCurrentConsumptionCharacteristic() {
        guard reportsPower, let watts = status.power else { return }
        service.set(EveCharacteristic.currentConsumption, watts)
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

    /// Sends what HomeKit asked: the power first, as LG takes no setpoint while off, then the mode, then the target.
    func applyClimate(_ command: ClimateCommand) async throws {
        if let power = command.power { try await sendPower(power) }
        if let mode = command.mode {
            lastClimateMode = mode
            let opModes: [ClimateMode: Double] = [.auto: ACOpMode.auto, .heat: ACOpMode.heat, .cool: ACOpMode.cool]
            if let opMode = opModes[mode], opMode != status.opMode {
                guard try await setOpMode(opMode) else { throw Self.communicationFailure() }
                setSnapshotValues(["airState.opMode": .number(opMode)])
            }
        }
        if let target = command.target { try await sendTarget(target) }
        updateAccessoryCharacteristic(device)
    }

    func sendPower(_ isOn: Bool) async throws {
        logger.debug("Set power on = \(isOn ? 1 : 0)  current status = \(status.isPowerOn)")
        try await sendCommand(["dataKey": "airState.operation", "dataValue": .number(isOn ? 1 : 0)], label: "active state", command: "Operation")
        setSnapshotValues(["airState.operation": .number(isOn ? 1 : 0)])
    }

    /// A target in HomeKit's Celsius.
    func sendTarget(_ celsius: Double) async throws {
        let temperature = status.converter.fromHomeKit(celsius)
        guard !temperature.isNaN else {
            logger.error("Converted temperature is not a valid number: \(temperature)")
            return
        }
        try await sendCommand(["dataKey": "airState.tempState.target", "dataValue": .number(temperature)], label: "target temperature")
        setSnapshotValues(["airState.tempState.target": .number(temperature)])
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

    /// On: the button's mode. Off: back to the Climate Mode HomeKit last chose (cool before it chose one).
    func handleButtonOpMode(_ value: HAPValue, opMode: Double) async throws {
        if Normalize.boolean(value) {
            if status.opMode != opMode {
                guard try await setOpMode(opMode) else { throw Self.communicationFailure() }
                setSnapshotValues(["airState.opMode": .number(opMode)])
            }
        } else {
            let opModes: [ClimateMode: Double] = [.auto: ACOpMode.auto, .heat: ACOpMode.heat, .cool: ACOpMode.cool]
            let opMode = opModes[lastClimateMode] ?? ACOpMode.cool
            guard try await setOpMode(opMode) else { throw Self.communicationFailure() }
            setSnapshotValues(["airState.opMode": .number(opMode)])
            updateAccessoryCharacteristic(device)
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
