import Foundation
import Homeswift
import HomeswiftPlugin

/// A single-mode climate controller (heater, cooler, humidifier, dehumidifier) that switches a relay so a
/// reading reaches a target. With hysteresis h and `runWhen: below`: run under target − h, stop at the
/// target, keep the state in between; `above` mirrors it. A command that fails leaves the state as it was:
/// writes from HomeKit report "No Response", background decisions retry on the next reading. A heater's or
/// cooler's Heater Cooler is a `ClimateController`; a humidifier's service is the accessory's own.
class ThresholdControllerAccessory: BaseAccessory {
    enum Kind: Sendable { case heat, cool, humidify, dehumidify }

    struct Mode {
        var kind: Kind
        var name: String
        var activity: String
        var unit: String
        var runsBelow: Bool
        var serviceType: ServiceType
        var reading: CharacteristicType
        var targetState: CharacteristicType
        var targetStateValue: Int
        var currentState: CharacteristicType
        var runningCurrentState: Int
        var threshold: CharacteristicType

        init(_ kind: Kind) {
            self.kind = kind
            switch kind {
            case .heat, .cool:
                let heat = kind == .heat
                name = heat ? "Heater" : "Cooler"
                activity = heat ? "Heating" : "Cooling"
                unit = "°C"
                runsBelow = heat
                serviceType = .heaterCooler
                reading = .currentTemperature
                targetState = .targetHeaterCoolerState
                targetStateValue = heat ? 1 : 2
                currentState = .currentHeaterCoolerState
                runningCurrentState = heat ? 2 : 3
                threshold = heat ? .heatingThresholdTemperature : .coolingThresholdTemperature
            case .humidify, .dehumidify:
                let humidify = kind == .humidify
                name = humidify ? "Humidifier" : "Dehumidifier"
                activity = humidify ? "Humidifying" : "Dehumidifying"
                unit = "%"
                runsBelow = humidify
                serviceType = .humidifierDehumidifier
                reading = .currentRelativeHumidity
                targetState = .targetHumidifierDehumidifierState
                targetStateValue = humidify ? 1 : 2
                currentState = .currentHumidifierDehumidifierState
                runningCurrentState = humidify ? 2 : 3
                threshold = humidify ? .relativeHumidityHumidifierThreshold : .relativeHumidityDehumidifierThreshold
            }
        }
    }

    let mode: Mode
    var cacheActive = false
    var cacheRunning = false
    var cacheReading = 0.0
    var cacheTarget: Double
    var hysteresis = 0.0
    private var evaluation: Task<Void, Never>?
    /// A heater's or cooler's Heater Cooler; nil for a humidifier or dehumidifier.
    private var climate: ClimateController?

    /// `overrides` adjust the reading and threshold (steps, bounds); `cacheType` resets the saved target when
    /// the simulation changes.
    init(
        platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, mode: Mode, defaultTarget: Double, cacheType: String? = nil,
        overrides: [CharacteristicType] = []
    ) {
        self.mode = mode
        cacheTarget = defaultTarget
        super.init(platform: platform, record: record, box: box)
        category = mode.serviceType.uuid == ServiceType.heaterCooler.uuid ? (mode.runsBelow ? .heater : .airConditioner) : (mode.runsBelow ? .humidifier : .dehumidifier)
        if (contextValue("cacheTarget")?.jsNumber ?? 0) == 0 { setContext("cacheTarget", .number(defaultTarget)) }
        if let cacheType, contextValue("cacheType")?.stringValue != cacheType {
            setContext("cacheType", .string(cacheType))
            setContext("cacheTarget", .number(defaultTarget))
        }
        cacheTarget = contextValue("cacheTarget")?.jsNumber ?? defaultTarget
        if mode.kind == .heat || mode.kind == .cool {
            makeClimateService(overrides: overrides)
            return
        }
        let value = mode.targetStateValue
        service = addService(
            mode.serviceType,
            optional: [mode.threshold, mode.targetState.with(minValue: Double(value), maxValue: Double(value), validValues: [value])] + overrides,
            primary: true)
        onRead(service.characteristic(mode.reading), "Reading") { [weak self] in self.map { .double($0.cacheReading) } }
        cacheReading = service.characteristic(mode.reading).value.doubleValue ?? 0
        onRead(service.characteristic(.active), "Active") { [weak self] in .int(self?.cacheActive == true ? 1 : 0) }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        service.characteristic(mode.targetState).value = .int(value)
        onReadAlways(service.characteristic(mode.targetState)) { .int(value) }
        onRead(service.characteristic(mode.currentState), "CurrentState") { [weak self] in self.map { .int($0.currentStateValue) } }
        update(service.characteristic(mode.threshold), cacheTarget)
        onWrite(service.characteristic(mode.threshold)) { [weak self] value in try await self?.setTarget(value) }
        cacheActive = service.characteristic(.active).value.intValue == 1
        cacheRunning = cacheActive && service.characteristic(mode.currentState).value.intValue == mode.runningCurrentState
    }

    /// The Heater Cooler of a heater (heat only) or a cooler (cool only), its range the threshold override's, else
    /// the threshold's own; power and running start from the cached service.
    private func makeClimateService(overrides: [CharacteristicType]) {
        let threshold = overrides.first { $0.uuid == mode.threshold.uuid } ?? mode.threshold
        let range = (threshold.minValue ?? 10)...(threshold.maxValue ?? 30)
        let capabilities = ClimateCapabilities(modes: [mode.kind == .heat ? .heat : .cool], range: range, step: threshold.minStep ?? 0.5)
        let climate = ClimateController(.heaterCooler, isPrimary: true, capabilities: capabilities,
                                        optional: overrides.filter { $0.uuid != mode.threshold.uuid }) { [weak self] command in
            try await self?.applyClimate(command)
        }
        self.climate = climate
        service = addService(climate)
        onReadChecked(climate)
        cacheReading = service.characteristic(mode.reading).value.doubleValue ?? 0
        cacheActive = service.characteristic(.active).value.intValue == 1
        cacheRunning = cacheActive && service.characteristic(mode.currentState).value.intValue == mode.runningCurrentState
        publishState()
    }

    /// The simulation's state for the controller.
    private func climateReport() -> ClimateReport {
        let action: ClimateAction = cacheActive && cacheRunning ? (mode.kind == .heat ? .heating : .cooling) : .idle
        return ClimateReport(power: cacheActive, mode: mode.kind == .heat ? .heat : .cool, action: action, current: cacheReading, target: cacheTarget)
    }

    /// What HomeKit asked of a heater or cooler: its power, then its target.
    private func applyClimate(_ command: ClimateCommand) async throws {
        if let power = command.power { try await setActive(.int(power ? 1 : 0)) }
        if let target = command.target { try await setTarget(.double(target)) }
        publishState()
    }

    /// The parameters that switch the relay.
    func runParams(_ run: Bool) -> DeviceParams { [:] }

    var currentStateValue: Int {
        guard cacheActive else { return 0 }
        return cacheRunning ? mode.runningCurrentState : 1
    }

    func publishState() {
        if let climate { return climate.update(climateReport()) }
        update(service.characteristic(.active), cacheActive ? 1 : 0)
        update(service.characteristic(mode.currentState), currentStateValue)
    }

    /// Whether the relay should run, `running` deciding inside the hysteresis band.
    func shouldRun(_ running: Bool) -> Bool {
        if mode.runsBelow {
            if cacheReading < cacheTarget - hysteresis { return true }
            if cacheReading >= cacheTarget { return false }
        } else {
            if cacheReading > cacheTarget + hysteresis { return true }
            if cacheReading <= cacheTarget { return false }
        }
        return running
    }

    /// A new reading; every report re-evaluates, so a failed command is retried.
    func setReading(_ value: Double) {
        if value != cacheReading {
            cacheReading = value
            if climate != nil { publishState() } else { update(service.characteristic(mode.reading), value) }
            logDebug("Reading: \(value.jsDescription)\(mode.unit)")
        }
        evaluate()
    }

    private func setActive(_ value: HAPValue) async throws {
        let active = value.intValue == 1
        logDebug("SET Active: \(value)")
        let run = active ? shouldRun(cacheActive && cacheRunning) : false
        if run != cacheRunning { try await sendCommandOrThrow(runParams(run)) }
        if active != cacheActive { logDebug("\(mode.name) state: \(active ? "on" : "off")") }
        if run != cacheRunning { logDebug("\(mode.activity): \(run ? "on" : "off")") }
        cacheActive = active
        cacheRunning = run
        publishState()
    }

    private func setTarget(_ value: HAPValue) async throws {
        let target = value.doubleValue ?? cacheTarget
        guard target != cacheTarget else { return }
        cacheTarget = target
        setContext("cacheTarget", .number(target))
        logDebug("Target: \(target.jsDescription)\(mode.unit)")
        await evaluate().value
    }

    /// Re-evaluates in the background, one evaluation after the other.
    @discardableResult
    func evaluate() -> Task<Void, Never> {
        let previous = evaluation
        let task = Task { [weak self] in
            await previous?.value
            await self?.runEvaluation()
        }
        evaluation = task
        return task
    }

    private func runEvaluation() async {
        guard cacheActive, !isDestroyed else { return }
        let run = shouldRun(cacheRunning)
        guard run != cacheRunning else { return }
        guard await sendCommand(runParams(run)) else {
            logError("Failed to turn \(mode.activity.lowercased()) \(run ? "on" : "off"), will retry on next update")
            return
        }
        cacheRunning = run
        logDebug("\(mode.activity): \(run ? "on" : "off")")
        publishState()
    }
}

/// `heater` and `cooler` simulations of a switch, following the temperature of another device (`tempSource`)
/// from the platform's temperature cache, polled every two minutes.
final class SwitchClimateAccessory: ThresholdControllerAccessory {
    let channel = 0
    let temperatureSource: String?

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, kind: Kind) {
        temperatureSource = platform.configuration.single(record.deviceID)?.tempSource ?? platform.configuration.multi(record.deviceID)?.tempSource
        let mode = Mode(kind)
        super.init(
            platform: platform, record: record, box: box, mode: mode, defaultTarget: 20, cacheType: kind == .heat ? "heater" : "cooler",
            overrides: [CharacteristicType.currentTemperature.with(minStep: 0.1), mode.threshold.with(minStep: 0.5)])
        setupPollingInterval { [weak self] in self?.updateTemperature() }
        applyInitialState()
    }

    override func runParams(_ run: Bool) -> DeviceParams { SwitchHelper.switchParams(deviceParams, channel: channel, on: run) }

    private func updateTemperature() {
        guard let temperatureSource, let temperature = platform.deviceTemperature(temperatureSource) else { return }
        setReading(temperature)
    }

    /// While active, the relay's state is what runs.
    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if cacheActive, params["switch"] != nil || params["switches"] != nil {
            cacheRunning = SwitchHelper.currentState(deviceParams, channel: channel)
        }
        publishState()
    }
}

/// The TH10/TH16 simulations (`heater`, `cooler`, `humidifier`, `dehumidifier` in `thDevices`): the relay
/// follows the sensor's own temperature or humidity, the other reading on a second sensor (no humidity on a
/// DS18B20 probe). Heating starts 0.5 °C under the target by default (`targetTempThreshold`), cooling exactly
/// at it; `minTarget`, `maxTarget` (10-30 °C) bound the target.
final class THClimateAccessory: ThresholdControllerAccessory {
    let entry: EWeLinkPlugin.Configuration.ThermostatDevice?
    let controlsTemperature: Bool
    private var sensorService: Service?
    private var cacheSecondary: Double?

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, kind: Kind) {
        let entry = platform.configuration.thermostat(record.deviceID)
        self.entry = entry
        controlsTemperature = kind == .heat || kind == .cool
        let mode = Mode(kind)
        var overrides: [CharacteristicType] = []
        if kind == .heat || kind == .cool {
            let minTarget = (entry?.minTarget).flatMap { $0 == 0 ? nil : $0 } ?? 10
            let maxTarget = max((entry?.maxTarget).flatMap { $0 == 0 ? nil : $0 } ?? 30, minTarget + 1)
            overrides = [CharacteristicType.currentTemperature.with(minStep: 0.1), mode.threshold.with(minValue: minTarget, maxValue: maxTarget, minStep: 0.5)]
        }
        super.init(platform: platform, record: record, box: box, mode: mode, defaultTarget: controlsTemperature ? 20 : 50, overrides: overrides)
        if controlsTemperature {
            hysteresis = entry?.targetTempThreshold ?? (kind == .heat ? 0.5 : 0)
            if box.device.model != "DS18B20" {
                let sensor = addService(.humiditySensor, name: "\(record.displayName) Humidity", subtype: "humidity")
                sensorService = sensor
                onRead(sensor.characteristic(.currentRelativeHumidity), "CurrentRelativeHumidity") { [weak self] in .double(self?.cacheSecondary ?? 0) }
            }
        } else {
            let sensor = addService(.temperatureSensor, name: "\(record.displayName) Temperature", subtype: "temp")
            sensorService = sensor
            onRead(sensor.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in .double(self?.cacheSecondary ?? 0) }
            cacheSecondary = sensor.characteristic(.currentTemperature).value.doubleValue
        }
        if platform.configuration.connectionMode != .lan { setupUIActivePolling() }
        applyInitialState()
    }

    override func runParams(_ run: Bool) -> DeviceParams {
        let state = onOff(run)
        return ["deviceType": "normal", "mainSwitch": state, "switch": state]
    }

    /// With `offsetFactor` set the reading is multiplied by `tempOffset`, as the Homebridge plugin does.
    private func readTemperature() -> Double {
        let offset = entry?.tempOffset ?? 0
        let temperature = DeviceValueParser.temperature(deviceParams)
        return entry?.offsetFactor != nil ? temperature * offset : temperature + offset
    }

    private func readHumidity() -> Double {
        let offset = entry?.humidityOffset ?? 0
        let humidity = DeviceValueParser.humidity(deviceParams)
        return clamp(jsRound(entry?.humidityOffsetFactor != nil ? humidity * offset : humidity + offset), 0, 100)
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let hasTemperature = params["currentTemperature"] != nil && params["currentTemperature"] != "unavailable"
        let hasHumidity = params["currentHumidity"] != nil && params["currentHumidity"] != "unavailable"
        let hasReading = controlsTemperature ? hasTemperature : hasHumidity
        let hasSecondary = controlsTemperature ? hasHumidity : hasTemperature
        if hasSecondary, let sensorService {
            let value = controlsTemperature ? readHumidity() : readTemperature()
            if value != cacheSecondary {
                cacheSecondary = value
                update(sensorService.characteristic(controlsTemperature ? .currentRelativeHumidity : .currentTemperature), value)
                logDebug(controlsTemperature ? "Humidity: \(value.jsDescription)%" : "Temperature: \(value.jsDescription)°C")
            }
        }
        if hasReading { setReading(controlsTemperature ? readTemperature() : readHumidity()) }
    }
}

/// The TH10/TH16 `thermostat` simulation: off or auto (heat while under the target), or off, heat and cool
/// with `showHeatCool`; the relay follows the sensor's temperature. Its Thermostat is a `ClimateController`, its
/// power, mode and target the simulation's own, kept across restarts.
final class THThermostatAccessory: BaseAccessory {
    let entry: EWeLinkPlugin.Configuration.ThermostatDevice?
    let tempOffset: Double
    let tempOffsetFactor: Bool
    let humidityOffset: Double
    let humidityOffsetFactor: Bool
    let minTarget: Double
    let maxTarget: Double
    let showHeatCool: Bool
    private var climate: ClimateController!
    private var cacheTemp = 0.0
    private var cacheHumidity: Double?
    private var cacheTarget = 20.0
    private var isOn = false
    private var mode = ClimateMode.auto
    /// The relay as last switched, nil before the simulation knows.
    private var relayOn: Bool?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let entry = platform.configuration.thermostat(record.deviceID)
        self.entry = entry
        tempOffset = entry?.tempOffset ?? 0
        tempOffsetFactor = entry?.offsetFactor != nil
        humidityOffset = entry?.humidityOffset ?? 0
        humidityOffsetFactor = entry?.humidityOffsetFactor != nil
        minTarget = (entry?.minTarget).flatMap { $0 == 0 ? nil : $0 } ?? 10
        maxTarget = max((entry?.maxTarget).flatMap { $0 == 0 ? nil : $0 } ?? 30, minTarget + 1)
        showHeatCool = entry?.showHeatCool ?? false
        super.init(platform: platform, record: record, box: box)
        category = .thermostat
        if (contextValue("cacheTarget")?.jsNumber ?? 0) == 0 { setContext("cacheTarget", 20) }
        cacheTarget = clamp(contextValue("cacheTarget")?.jsNumber ?? 20, minTarget, maxTarget)
        // A change of showHeatCool turns it off (its modes change).
        let previousHeatCool = contextValue("showHeatCool")?.boolValue ?? false
        let reset = previousHeatCool != showHeatCool
        setContext("showHeatCool", .bool(showHeatCool))

        let hasHumidity = box.device.model != "DS18B20"
        let capabilities = ClimateCapabilities(modes: showHeatCool ? [.heat, .cool] : [.auto], range: minTarget...maxTarget, step: 0.5)
        climate = ClimateController(
            .thermostat, isPrimary: true, capabilities: capabilities,
            optional: (hasHumidity ? [.currentRelativeHumidity] : []) + [CharacteristicType.currentTemperature.with(minStep: 0.1)]
        ) { [weak self] command in try await self?.applyClimate(command) }
        service = addService(climate)
        onReadChecked(climate)
        cacheTemp = service.characteristic(.currentTemperature).value.doubleValue ?? 0
        let state = reset ? 0 : service.characteristic(.targetHeatingCoolingState).value.intValue ?? 0
        isOn = state != 0
        mode = showHeatCool ? (state == 2 ? .cool : .heat) : .auto
        relayOn = deviceParams["switch"].map { $0 == "on" }
        if platform.configuration.connectionMode != .lan { setupUIActivePolling() }
        applyInitialState()
        climate.update(climateReport())
    }

    private func relay(_ on: Bool) -> DeviceParams {
        ["deviceType": "normal", "mainSwitch": onOff(on), "switch": onOff(on)]
    }

    /// The simulation's state for the controller: heating or cooling while the relay runs.
    private func climateReport() -> ClimateReport {
        let action: ClimateAction = isOn && relayOn == true ? (mode == .cool ? .cooling : .heating) : .idle
        return ClimateReport(power: isOn, mode: mode, action: action, current: cacheTemp, target: cacheTarget)
    }

    /// What HomeKit asked: the new power, mode and target, kept only once the relay follows them.
    private func applyClimate(_ command: ClimateCommand) async throws {
        let before = (isOn, mode, cacheTarget)
        if let power = command.power { isOn = power }
        if let mode = command.mode { self.mode = mode }
        if let target = command.target { cacheTarget = target }
        guard await regulate() else {
            (isOn, mode, cacheTarget) = before
            climate.update(climateReport())
            throw communicationError
        }
        if command.power != nil { logDebug("Thermostat state: \(isOn ? "on" : "off")") }
        if let target = command.target {
            setContext("cacheTarget", .number(target))
            logDebug("Target temperature: \(target.jsDescription)°C")
        }
        climate.update(climateReport())
    }

    /// Switches the relay to what the power, mode, target and room ask: off while off, heating under the target in
    /// heat and auto, cooling over it in cool. False when the command failed.
    @discardableResult
    private func regulate() async -> Bool {
        let run = isOn && (mode == .cool ? cacheTemp > cacheTarget : cacheTemp < cacheTarget)
        guard run != relayOn else { return true }
        guard await sendCommand(relay(run)) else { return false }
        relayOn = run
        logDebug("\(mode == .cool ? "Cooling" : "Heating"): \(onOff(run).jsString ?? "")")
        climate.update(climateReport())
        return true
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let raw = params["currentTemperature"], raw != "unavailable" {
            var temperature = DeviceValueParser.temperature(deviceParams)
            temperature = tempOffsetFactor ? temperature * tempOffset : temperature + tempOffset
            if temperature != cacheTemp {
                cacheTemp = temperature
                logDebug("Temperature: \(cacheTemp.jsDescription)°C")
            }
            climate.update(climateReport())
            // Every report re-evaluates, so a failed command is retried.
            Task { [weak self] in
                guard let self, !(await self.regulate()) else { return }
                self.logError("Failed to update thermostat state, will retry on next update")
            }
        }
        if let raw = params["currentHumidity"], raw != "unavailable" {
            var humidity = DeviceValueParser.humidity(deviceParams)
            humidity = humidityOffsetFactor ? humidity * humidityOffset : humidity + humidityOffset
            humidity = max(min(jsRound(humidity), 100), 0)
            if humidity != cacheHumidity {
                cacheHumidity = humidity
                if let characteristic = service[.currentRelativeHumidity] { update(characteristic, humidity) }
                logDebug("Humidity: \(humidity.jsDescription)%")
            }
        }
    }
}
