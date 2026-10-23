import Foundation
import Homeswift
import HomeswiftPlugin

/// Ceiling fans (iFan03/04, UIID 34): speed 0-4 as 25 % steps, the fan on outlet 1, and its light (outlet 0)
/// as a Lightbulb unless `hideLight`.
final class FanAccessory: BaseAccessory {
    static let maxSpeed = 4.0
    private var lightService: Service?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .fan
        let entry = platform.configuration.fan(record.deviceID)
        service = addService(
            .fanv2, optional: [CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 100 / Self.maxSpeed)], primary: true)
        onRead(service.characteristic(.active), "Active") { [weak self] in
            guard let self else { return nil }
            if self.deviceParams.switches != nil { return .int(self.deviceParams.outletSwitch(1) == "on" ? 1 : 0) }
            return .int((self.deviceParams["speed"]?.jsNumber ?? 0) > 0 ? 1 : 0)
        }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        onRead(service.characteristic(.rotationSpeed), "RotationSpeed") { [weak self] in
            guard let self else { return nil }
            return .double((self.deviceParams["speed"]?.jsNumber ?? 0) / Self.maxSpeed * 100)
        }
        onWrite(service.characteristic(.rotationSpeed)) { [weak self] value in try await self?.setRotationSpeed(value) }
        let hasLight = deviceParams.switches?.contains { $0["outlet"]?.jsNumber == 0 } ?? false
        if hasLight, entry?.hideLight != true {
            let light = addService(.lightbulb, name: "\(record.displayName) Light", subtype: "light")
            lightService = light
            onRead(light.characteristic(.on), "Light On") { [weak self] in
                guard let self else { return nil }
                return .bool(self.deviceParams.switches != nil && self.deviceParams.outletSwitch(0) == "on")
            }
            onWrite(light.characteristic(.on)) { [weak self] value in try await self?.setLight(value) }
        }
        applyInitialState()
    }

    /// The `switches` array with one outlet changed.
    private func switchesSetting(_ outlet: Int, on: Bool) -> [JSONValue] {
        (deviceParams.switches ?? []).map { entry in
            guard var object = entry.objectValue, entry["outlet"]?.jsNumber == Double(outlet) else { return entry }
            object["switch"] = onOff(on)
            return .object(object)
        }
    }

    private func setActive(_ value: HAPValue) async throws {
        try await handleSet("Active", value) {
            let on = value.intValue == 1
            if deviceParams.switches != nil { return await sendCommand(["switches": .array(switchesSetting(1, on: on))]) }
            return await sendCommand(["speed": .number(on ? 1 : 0)])
        }
    }

    private func setRotationSpeed(_ value: HAPValue) async throws {
        try await handleSet("RotationSpeed", value) {
            let speed = clamp(jsRound((value.doubleValue ?? 0) / 100 * Self.maxSpeed), 0, Self.maxSpeed)
            return await sendCommand(["speed": .number(speed)])
        }
    }

    private func setLight(_ value: HAPValue) async throws {
        try await handleSet("Light On", value) {
            guard deviceParams.switches != nil else { return false }
            return await sendCommand(["switches": .array(switchesSetting(0, on: value.boolValue == true))])
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        var active: Int?
        if let fan = params.switches?.first(where: { $0["outlet"]?.jsNumber == 1 }) {
            active = fan["switch"] == "on" ? 1 : 0
        } else if params.switches == nil, let speed = params["speed"]?.jsNumber {
            active = speed > 0 ? 1 : 0
        }
        if let active { update(service.characteristic(.active), active) }
        if let speed = params["speed"]?.jsNumber { update(service.characteristic(.rotationSpeed), speed / Self.maxSpeed * 100) }
        if let lightService, params.switches != nil {
            lightService.characteristic(.on).value = .bool(params.outletSwitch(0) == "on")
        }
        logDebug("State updated: Active=\(active.map(String.init) ?? "unchanged"), Speed=\(params["speed"]?.jsString ?? "unchanged")")
    }
}

/// A thermostat (UIID 127): off or heat, a target of 5-45 °C in half degrees, the current temperature with
/// `tempOffset`; shares its temperature with heater and cooler simulations.
final class ThermostatAccessory: BaseAccessory {
    let tempOffset: Double
    private var cacheTemp = DeviceLimits.defaultTemperature

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        tempOffset = platform.configuration.thermostat(record.deviceID)?.tempOffset ?? 0
        super.init(platform: platform, record: record, box: box)
        category = .thermostat
        service = addService(
            .thermostat,
            optional: [
                CharacteristicType.currentTemperature.with(minStep: 0.1),
                CharacteristicType.targetHeatingCoolingState.with(minValue: 0, maxValue: 1, validValues: [0, 1]),
            ],
            // An extra, so the target starts at the new minimum until the device reports one.
            extra: [
                Characteristic(
                    .targetTemperature.with(
                        minValue: DeviceLimits.thermostatTemperature.lowerBound, maxValue: DeviceLimits.thermostatTemperature.upperBound,
                        minStep: DeviceLimits.thermostatStep))
            ],
            primary: true)
        onRead(service.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in
            guard let self else { return nil }
            var temperature = DeviceValueParser.temperature(self.deviceParams, default: self.cacheTemp)
            if self.tempOffset != 0 { temperature += self.tempOffset }
            self.cacheTemp = temperature
            return .double(clamp(temperature, DeviceLimits.temperature))
        }
        onWrite(service.characteristic(.targetHeatingCoolingState)) { [weak self] value in try await self?.setHeatingState(value) }
        onWrite(service.characteristic(.targetTemperature)) { [weak self] value in try await self?.setTargetTemperature(value) }
        applyInitialState()
    }

    private func setHeatingState(_ value: HAPValue) async throws {
        try await handleSet("TargetHeatingCoolingState", value) {
            let state = value.intValue == 1 ? "on" : "off"
            // TH10/16 need deviceType and mainSwitch.
            let success = await sendCommand(["switch": .string(state), "mainSwitch": .string(state), "deviceType": "normal"])
            if success { logInfo("Set heating state: \(state)") }
            return success
        }
    }

    private func setTargetTemperature(_ value: HAPValue) async throws {
        try await handleSet("TargetTemperature", value) {
            let target = clamp(value.doubleValue ?? 0, DeviceLimits.thermostatTemperature)
            let success = await sendCommand(["targetTemp": .number(target), "tempScale": "c"])
            if success { logInfo("Set target temperature: \(target.jsDescription)°C") }
            return success
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if params["temperature"] != nil || params["currentTemperature"] != nil {
            var temperature = DeviceValueParser.temperature(deviceParams, default: cacheTemp)
            if tempOffset != 0 { temperature += tempOffset }
            temperature = clamp(temperature, DeviceLimits.temperature)
            update(service.characteristic(.currentTemperature), temperature)
            logDebug("Current temperature updated: \(temperature.jsDescription)°C")
            platform.setDeviceTemperature(deviceID, temperature)
        }
        if let target = params["targetTemp"]?.jsParseFloat {
            let clamped = clamp(target, DeviceLimits.thermostatTemperature)
            update(service.characteristic(.targetTemperature), clamped)
            logDebug("Target temperature updated: \(clamped.jsDescription)°C")
        }
        if let state = params["switch"] {
            let value = state == "on" ? 1 : 0
            update(service.characteristic(.targetHeatingCoolingState), value)
            update(service.characteristic(.currentHeatingCoolingState), value)
            logDebug("Heating state updated: \(state.jsString ?? "")")
        }
        if let workState = params["workState"] {
            // 1 heating, 2 auto.
            let current = workState.jsNumber == 1 ? 1 : 0
            update(service.characteristic(.currentHeatingCoolingState), current)
            logDebug("Work state updated: \(workState.jsString ?? "") (current state: \(current))")
        }
    }
}

/// A temperature and humidity sensor (TH10/TH16, UIID 15, 181) without a simulation, with `tempOffset` and
/// `humidityOffset`; shares its temperature with heater and cooler simulations.
final class THSensorAccessory: BaseAccessory {
    let entry: EWeLinkPlugin.Configuration.ThermostatDevice?
    private var humidityService: Service?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        entry = platform.configuration.thermostat(record.deviceID)
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        service = addService(.temperatureSensor, name: "\(record.displayName) Temperature", primary: true)
        onRead(service.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in
            guard let self else { return nil }
            return .double(self.applyTemperatureOffset(DeviceValueParser.temperature(self.deviceParams), offset: self.entry?.tempOffset ?? 0))
        }
        if deviceParams["currentHumidity"] != nil || deviceParams["humidity"] != nil {
            let humidity = addService(.humiditySensor, name: "\(record.displayName) Humidity")
            humidityService = humidity
            onRead(humidity.characteristic(.currentRelativeHumidity), "CurrentRelativeHumidity") { [weak self] in
                guard let self else { return nil }
                return .double(self.applyHumidityOffset(DeviceValueParser.humidity(self.deviceParams), offset: self.entry?.humidityOffset ?? 0))
            }
        }
        applyInitialState()
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let temperature = applyTemperatureOffset(DeviceValueParser.temperature(deviceParams), offset: entry?.tempOffset ?? 0)
        update(service.characteristic(.currentTemperature), temperature)
        logDebug("Temperature updated: \(temperature.jsDescription)°C")
        platform.setDeviceTemperature(deviceID, temperature)
        if let humidityService {
            let humidity = applyHumidityOffset(DeviceValueParser.humidity(deviceParams), offset: entry?.humidityOffset ?? 0)
            update(humidityService.characteristic(.currentRelativeHumidity), humidity)
            logDebug("Humidity updated: \(humidity.jsDescription)%")
        }
    }
}

/// Air conditioners (UIID 151) as a HeaterCooler: power, auto/heat/cool, a target of 16-32 °C, the indoor
/// temperature (with `offset` and `offsetFactor`), and the fan speed in 25 % steps.
final class AirConditionerAccessory: BaseAccessory {
    static let targetRange = 16.0...32.0
    private var cacheMode = "cool"
    private var cacheTargetTemp = 24.0
    private var cacheCurrentTemp = 20.0
    private var cacheWindSpeed = DeviceLimits.AirConditionerWind.medium
    let tempOffset: Double
    let tempOffsetFactor: Double?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let entry = platform.configuration.single(record.deviceID)
        tempOffset = entry?.offset ?? 0
        tempOffsetFactor = entry?.offsetFactor
        super.init(platform: platform, record: record, box: box)
        category = .airConditioner
        let range = Self.targetRange
        service = addService(
            .heaterCooler,
            optional: [
                CharacteristicType.currentTemperature.with(minStep: 0.1),
                CharacteristicType.targetHeaterCoolerState.with(minValue: 0, maxValue: 2, validValues: [0, 1, 2]),
                CharacteristicType.coolingThresholdTemperature.with(minValue: range.lowerBound, maxValue: range.upperBound, minStep: 1),
                CharacteristicType.heatingThresholdTemperature.with(minValue: range.lowerBound, maxValue: range.upperBound, minStep: 1),
                CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 25),
            ],
            primary: true)
        onRead(service.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in self.map { .double($0.cacheCurrentTemp) } }
        onRead(service.characteristic(.active), "Active") { [weak self] in self?.service.characteristic(.active).value }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        onRead(service.characteristic(.targetHeaterCoolerState), "TargetHeaterCoolerState") { [weak self] in self.map { .int(Self.targetState($0.cacheMode)) } }
        onWrite(service.characteristic(.targetHeaterCoolerState)) { [weak self] value in try await self?.setMode(value) }
        onReadAlways(service.characteristic(.currentHeaterCoolerState)) { [weak self] in .int(self?.currentStateValue ?? 0) }
        onRead(service.characteristic(.coolingThresholdTemperature), "TargetTemperature") { [weak self] in self.map { .double($0.cacheTargetTemp) } }
        onWrite(service.characteristic(.coolingThresholdTemperature)) { [weak self] value in try await self?.setTarget(value, mode: "cool") }
        onRead(service.characteristic(.heatingThresholdTemperature), "TargetTemperature") { [weak self] in self.map { .double($0.cacheTargetTemp) } }
        onWrite(service.characteristic(.heatingThresholdTemperature)) { [weak self] value in try await self?.setTarget(value, mode: "heat") }
        onRead(service.characteristic(.rotationSpeed), "RotationSpeed") { [weak self] in self.map { .double(Self.rotationSpeed($0.cacheWindSpeed)) } }
        onWrite(service.characteristic(.rotationSpeed)) { [weak self] value in try await self?.setRotationSpeed(value) }
        apply(deviceParams, initial: true)
    }

    static func targetState(_ mode: String) -> Int { mode == "auto" ? 0 : mode == "heat" ? 1 : 2 }

    static func rotationSpeed(_ wind: Int) -> Double {
        switch wind {
        case DeviceLimits.AirConditionerWind.off: DeviceLimits.AirConditionerRotation.off
        case DeviceLimits.AirConditionerWind.low: DeviceLimits.AirConditionerRotation.low
        case DeviceLimits.AirConditionerWind.high: DeviceLimits.AirConditionerRotation.high
        default: DeviceLimits.AirConditionerRotation.medium
        }
    }

    private var isActive: Bool { service.characteristic(.active).value.intValue == 1 }

    private var currentStateValue: Int {
        guard isActive else { return 0 }
        return cacheMode == "heat" ? 2 : cacheMode == "cool" ? 3 : 1
    }

    private func updateCurrentState() { update(service.characteristic(.currentHeaterCoolerState), currentStateValue) }

    private func clampTarget(_ value: JSONValue) -> Double {
        guard let temperature = value.jsNumber else { return cacheTargetTemp }
        return clamp(temperature, Self.targetRange)
    }

    private func setActive(_ value: HAPValue) async throws {
        let state = value.intValue == 1 ? "on" : "off"
        guard state != (isActive ? "on" : "off") else { return }
        logInfo("Setting power state to \(state)")
        guard await sendCommand(["power": .string(state)]) else { throw communicationError }
        // HomeKit stores the written value after this returns; the current state follows it.
        let active = state == "on"
        let mode = cacheMode
        update(service.characteristic(.currentHeaterCoolerState), active ? (mode == "heat" ? 2 : mode == "cool" ? 3 : 1) : 0)
    }

    private func setMode(_ value: HAPValue) async throws {
        let modes = [0: "auto", 1: "heat", 2: "cool"]
        guard let mode = value.intValue.flatMap({ modes[$0] }), mode != cacheMode else { return }
        logInfo("Setting mode to \(mode)")
        guard await sendCommand(["mode": .string(mode)]) else { throw communicationError }
        cacheMode = mode
        updateCurrentState()
    }

    private func setTarget(_ value: HAPValue, mode: String) async throws {
        let temperature = value.doubleValue ?? cacheTargetTemp
        guard cacheMode == mode || cacheMode == "auto", temperature != cacheTargetTemp else { return }
        logInfo("Setting target temperature to \(temperature.jsDescription)°C")
        guard await sendCommand(["temperature": .number(temperature)]) else { throw communicationError }
        cacheTargetTemp = temperature
        update(service.characteristic(.coolingThresholdTemperature), temperature)
        update(service.characteristic(.heatingThresholdTemperature), temperature)
    }

    private func setRotationSpeed(_ value: HAPValue) async throws {
        let speed = value.doubleValue ?? 0
        let wind =
            speed == DeviceLimits.AirConditionerRotation.off ? DeviceLimits.AirConditionerWind.off
            : speed <= DeviceLimits.AirConditionerRotation.lowThreshold ? DeviceLimits.AirConditionerWind.low
            : speed <= DeviceLimits.AirConditionerRotation.highThreshold ? DeviceLimits.AirConditionerWind.medium : DeviceLimits.AirConditionerWind.high
        guard wind != cacheWindSpeed else { return }
        logInfo("Setting fan speed to \(speed.jsDescription)%")
        guard await sendCommand(["wind_speed": .number(Double(wind))]) else { throw communicationError }
        cacheWindSpeed = wind
    }

    private func apply(_ params: DeviceParams, initial: Bool) {
        if let power = params["power"] {
            update(service.characteristic(.active), power == "on" ? 1 : 0)
            updateCurrentState()
            if !initial { logDebug("Power state updated to \(power.jsString ?? "")") }
        }
        if let mode = params["mode"]?.jsString {
            cacheMode = mode
            update(service.characteristic(.targetHeaterCoolerState), Self.targetState(mode))
            updateCurrentState()
            if !initial { logDebug("Mode updated to \(mode)") }
        }
        if let temperature = params["temperature"] {
            cacheTargetTemp = clampTarget(temperature)
            update(service.characteristic(.coolingThresholdTemperature), cacheTargetTemp)
            update(service.characteristic(.heatingThresholdTemperature), cacheTargetTemp)
            if !initial { logDebug("Target temperature updated to \(cacheTargetTemp.jsDescription)°C") }
        }
        if let indoor = params["indoor_temperature"] {
            cacheCurrentTemp = applyTemperatureOffset(indoor.jsNumber ?? .nan, offset: tempOffset, factor: tempOffsetFactor)
            update(service.characteristic(.currentTemperature), cacheCurrentTemp)
            if !initial {
                logDebug("Current temperature updated to \(cacheCurrentTemp.jsDescription)°C")
                platform.setDeviceTemperature(deviceID, cacheCurrentTemp)
            }
        }
        if let wind = params["wind_speed"]?.jsNumber {
            cacheWindSpeed = Int(wind)
            update(service.characteristic(.rotationSpeed), Self.rotationSpeed(cacheWindSpeed))
            if !initial { logDebug("Wind speed updated to \(Self.rotationSpeed(cacheWindSpeed).jsDescription)%") }
        }
        if initial { updateCurrentState() }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        apply(params, initial: false)
    }
}

/// Humidifiers (UIID 19) as a fan: on/off, and the three modes as 33, 66 and 99 % speed.
final class HumidifierAccessory: BaseAccessory {
    private var cacheState = "off"
    private var cacheMode = 1
    private static let labels = [1: "low", 2: "medium", 3: "high"]

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .humidifier
        // The device reports no humidity: a fan controls it.
        service = addService(.fan, optional: [CharacteristicType.rotationSpeed.with(minStep: 33)], primary: true)
        onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.cacheState == "on") }
        onWrite(service.characteristic(.on)) { [weak self] value in try await self?.setOn(value) }
        onRead(service.characteristic(.rotationSpeed), "RotationSpeed") { [weak self] in
            guard let self else { return nil }
            return .int(self.cacheState == "on" ? self.cacheMode * 33 : 0)
        }
        onWrite(service.characteristic(.rotationSpeed)) { [weak self] value in try await self?.setRotationSpeed(value) }
        if let state = deviceParams["switch"]?.jsString {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
        }
        if let mode = deviceParams["state"]?.jsNumber {
            cacheMode = Int(mode)
            update(service.characteristic(.rotationSpeed), cacheState == "on" ? cacheMode * 33 : 0)
        }
    }

    private func setOn(_ value: HAPValue) async throws {
        let state = value.boolValue == true ? "on" : "off"
        guard state != cacheState else { return }
        logInfo("Setting state to \(state)")
        var params: DeviceParams = ["switch": .string(state)]
        if state == "on" { params["state"] = .number(Double(cacheMode)) }
        guard await sendCommand(params) else { throw communicationError }
        cacheState = state
        if state == "off" { update(service.characteristic(.rotationSpeed), 0) }
    }

    private func setRotationSpeed(_ value: HAPValue) async throws {
        // Sliding sends many values: only the last one goes out.
        guard await debounceLatest("rotationSpeed", Double(Timing.stateInitDelay)) else { return }
        let speed = value.doubleValue ?? 0
        let state = speed >= 1 ? "on" : "off"
        var mode = cacheMode
        if speed > 0 {
            mode = speed <= 33 ? 1 : speed <= 66 ? 2 : 3
            if mode == cacheMode, state == cacheState { return }
        }
        logInfo("Setting mode to \(speed.jsDescription)% (\(Self.labels[mode] ?? ""))")
        var params: DeviceParams = ["switch": .string(state)]
        if speed > 0 { params["state"] = .number(Double(mode)) }
        guard await sendCommand(params) else { throw communicationError }
        if state != cacheState {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
        }
        if speed == 0 {
            // The slider goes back to the mode, the fan staying off.
            setTrackedTimeout(Double(Timing.positionCleanup)) { [weak self] in
                guard let self else { return }
                self.update(self.service.characteristic(.rotationSpeed), self.cacheMode * 33)
            }
            return
        }
        cacheMode = mode
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let state = params["switch"]?.jsString, state != cacheState {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
            logDebug("State updated to \(cacheState)")
            if cacheState != "on" { update(service.characteristic(.rotationSpeed), 0) }
        }
        if let modeNumber = params["state"]?.jsNumber, Int(modeNumber) != cacheMode {
            cacheMode = Int(modeNumber)
            if cacheState == "on" {
                update(service.characteristic(.rotationSpeed), cacheMode * 33)
                logDebug("Mode updated to \(Self.labels[cacheMode] ?? "\(cacheMode)")")
            }
        }
    }
}

/// Aroma diffusers (UIID 25): the mist as a fan (50 or 100 %), the light as a colour lightbulb. Updates are
/// ignored for five seconds after a change from HomeKit, so the device's echo does not undo it.
final class DiffuserAccessory: BaseAccessory {
    private var fanService: Service!
    private var lightService: Service!
    private var cacheState = "off"
    private var cacheSpeed = DeviceLimits.DiffuserSpeed.low
    private var cacheLight = 0
    private var cacheBright = 100.0
    private var cacheHue = 0.0
    private var cacheR = 255.0, cacheG = 255.0, cacheB = 255.0
    private var updatesSuppressed = false

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .fan
        fanService = addService(.fan, name: "Diffuser", subtype: "diffuser", optional: [CharacteristicType.rotationSpeed.with(minStep: 50)], primary: true)
        lightService = addService(.lightbulb, name: "Light", subtype: "light", optional: [.brightness, .hue, .saturation])
        service = fanService
        onRead(fanService.characteristic(.on), "Diffuser On") { [weak self] in .bool(self?.cacheState == "on") }
        onWrite(fanService.characteristic(.on)) { [weak self] value in try await self?.setDiffuserOn(value) }
        onRead(fanService.characteristic(.rotationSpeed), "Diffuser Speed") { [weak self] in self.map { .double($0.cacheSpeed) } }
        onWrite(fanService.characteristic(.rotationSpeed)) { [weak self] value in try await self?.setDiffuserSpeed(value) }
        onRead(lightService.characteristic(.on), "Light On") { [weak self] in .bool(self?.cacheLight == 1) }
        onWrite(lightService.characteristic(.on)) { [weak self] value in try await self?.setLightOn(value) }
        onRead(lightService.characteristic(.brightness), "Light Brightness") { [weak self] in self.map { .double($0.cacheBright) } }
        onWrite(lightService.characteristic(.brightness)) { [weak self] value in try await self?.setBrightness(value) }
        onRead(lightService.characteristic(.hue), "Light Hue") { [weak self] in self.map { .double($0.cacheHue) } }
        onWrite(lightService.characteristic(.hue)) { [weak self] value in try await self?.setHue(value) }
        onReadAlways(lightService.characteristic(.saturation)) { .int(100) }

        if let state = deviceParams["switch"]?.jsString {
            cacheState = state
            fanService.characteristic(.on).value = .bool(cacheState == "on")
        }
        if let state = deviceParams["state"]?.jsNumber {
            cacheSpeed = state * DeviceLimits.DiffuserSpeed.low
            update(fanService.characteristic(.rotationSpeed), cacheSpeed)
        }
        if let light = deviceParams["lightswitch"]?.jsNumber {
            cacheLight = Int(light)
            lightService.characteristic(.on).value = .bool(cacheLight == 1)
        }
        if let bright = deviceParams["lightbright"]?.jsNumber {
            cacheBright = bright
            update(lightService.characteristic(.brightness), cacheBright)
        }
        if let red = deviceParams["lightRcolor"]?.jsNumber {
            cacheR = red
            cacheG = deviceParams["lightGcolor"]?.jsNumber ?? 0
            cacheB = deviceParams["lightBcolor"]?.jsNumber ?? 0
            cacheHue = Double(EWeLinkColor.rgbToHS(cacheR, cacheG, cacheB).h)
            update(lightService.characteristic(.hue), cacheHue)
            update(lightService.characteristic(.saturation), 100)
        }
    }

    /// Ignores updates for a while; the latest change decides when they count again.
    private func suppressUpdates() {
        updatesSuppressed = true
        let isLatest = claimLatest("suppressUpdates")
        setTrackedTimeout(Double(Timing.autoOffDelay)) { [weak self] in
            if isLatest() { self?.updatesSuppressed = false }
        }
    }

    private func setDiffuserOn(_ value: HAPValue) async throws {
        let state = value.boolValue == true ? "on" : "off"
        guard state != cacheState else { return }
        logInfo("Setting diffuser to \(state)")
        suppressUpdates()
        guard await sendCommand(["switch": .string(state)]) else { throw communicationError }
        cacheState = state
    }

    private func setDiffuserSpeed(_ value: HAPValue) async throws {
        let requested = value.doubleValue ?? 0
        // Off goes through the switch.
        guard requested != 0 else { return }
        let speed = requested <= DeviceLimits.DiffuserSpeed.low ? DeviceLimits.DiffuserSpeed.low : DeviceLimits.DiffuserSpeed.high
        guard speed != cacheSpeed, await debounceLatest("speed", Double(Timing.commandDelay)) else { return }
        logInfo("Setting diffuser speed to \(speed.jsDescription)%")
        suppressUpdates()
        guard await sendCommand(["state": .number(speed / DeviceLimits.DiffuserSpeed.low)]) else { throw communicationError }
        cacheSpeed = speed
    }

    private func setLightOn(_ value: HAPValue) async throws {
        let light = value.boolValue == true ? 1 : 0
        guard light != cacheLight else { return }
        logInfo("Setting light to \(light == 1 ? "on" : "off")")
        suppressUpdates()
        guard await sendCommand(["lightswitch": .number(Double(light))]) else { throw communicationError }
        cacheLight = light
    }

    private func setBrightness(_ value: HAPValue) async throws {
        let bright = value.doubleValue ?? 0
        guard bright != cacheBright, await debounceLatest("brightness", Double(Timing.stateInitDelay)) else { return }
        logInfo("Setting light brightness to \(bright.jsDescription)%")
        suppressUpdates()
        guard await sendCommand(["lightbright": .number(bright)]) else { throw communicationError }
        cacheBright = bright
    }

    private func setHue(_ value: HAPValue) async throws {
        let hue = value.doubleValue ?? 0
        guard cacheState == "on", hue != cacheHue, await debounceLatest("colour", Double(Timing.colorDebounce)) else { return }
        let saturation = lightService.characteristic(.saturation).value.doubleValue ?? 100
        let rgb = EWeLinkColor.hsToRGB(hue, saturation)
        logInfo("Setting light color to RGB(\(rgb.r), \(rgb.g), \(rgb.b))")
        suppressUpdates()
        guard await sendCommand(["lightRcolor": .number(Double(rgb.r)), "lightGcolor": .number(Double(rgb.g)), "lightBcolor": .number(Double(rgb.b))]) else {
            throw communicationError
        }
        cacheHue = hue
        cacheR = Double(rgb.r)
        cacheG = Double(rgb.g)
        cacheB = Double(rgb.b)
    }

    override func updateState(_ params: DeviceParams) {
        guard !updatesSuppressed else { return }
        mergeDeviceParams(params)
        if let state = params["switch"]?.jsString, state != cacheState {
            cacheState = state
            fanService.characteristic(.on).value = .bool(cacheState == "on")
            logDebug("Diffuser state updated to \(cacheState)")
            if cacheState == "on", params["state"] == nil { update(fanService.characteristic(.rotationSpeed), cacheSpeed) }
        }
        if let state = params["state"]?.jsNumber {
            let speed = state * DeviceLimits.DiffuserSpeed.low
            if speed != cacheSpeed {
                cacheSpeed = speed
                update(fanService.characteristic(.rotationSpeed), cacheSpeed)
                logDebug("Diffuser speed updated to \(cacheSpeed.jsDescription)%")
            }
        }
        if let light = params["lightswitch"]?.jsNumber, Int(light) != cacheLight {
            cacheLight = Int(light)
            lightService.characteristic(.on).value = .bool(cacheLight == 1)
            logDebug("Light state updated to \(cacheLight == 1 ? "on" : "off")")
        }
        if let bright = params["lightbright"]?.jsNumber, bright != cacheBright {
            cacheBright = bright
            update(lightService.characteristic(.brightness), cacheBright)
            logDebug("Light brightness updated to \(cacheBright.jsDescription)%")
        }
        if let red = params["lightRcolor"]?.jsNumber {
            let green = params["lightGcolor"]?.jsNumber ?? 0, blue = params["lightBcolor"]?.jsNumber ?? 0
            if red != cacheR || green != cacheG || blue != cacheB {
                cacheR = red
                cacheG = green
                cacheB = blue
                cacheHue = Double(EWeLinkColor.rgbToHS(red, green, blue).h)
                update(lightService.characteristic(.hue), cacheHue)
                update(lightService.characteristic(.saturation), 100)
                logDebug("Light color updated to RGB(\(Int(red)), \(Int(green)), \(Int(blue)))")
            }
        }
    }
}

/// NSPanel (UIID 133) and NSPanel Pro (195, 228): the temperature (with `offset`, `offsetFactor`), and for the
/// NSPanel its two relays as switches.
final class PanelAccessory: BaseAccessory {
    let isPro: Bool
    let tempOffset: Double
    let tempOffsetFactor: Double?
    private var channel1: Service?
    private var channel2: Service?
    private var cacheTemp = 20.0
    private var cacheState1 = "off", cacheState2 = "off"

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        isPro = DeviceCatalog.isNSPanelPro(box.device.uiid)
        let entry = platform.configuration.single(record.deviceID)
        tempOffset = entry?.offset ?? 0
        tempOffsetFactor = entry?.offsetFactor
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        service = addService(.temperatureSensor, optional: [CharacteristicType.currentTemperature.with(minStep: 0.1)], primary: true)
        onRead(service.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in self.map { .double($0.cacheTemp) } }
        if !isPro {
            let first = addService(.switch, name: "Channel 1", subtype: "channel1")
            let second = addService(.switch, name: "Channel 2", subtype: "channel2")
            channel1 = first
            channel2 = second
            onRead(first.characteristic(.on), "Channel 1 State") { [weak self] in .bool(self?.cacheState1 == "on") }
            onWrite(first.characteristic(.on)) { [weak self] value in try await self?.setChannel(1, value) }
            onRead(second.characteristic(.on), "Channel 2 State") { [weak self] in .bool(self?.cacheState2 == "on") }
            onWrite(second.characteristic(.on)) { [weak self] value in try await self?.setChannel(2, value) }
        }
        if DeviceValueParser.hasTemperature(deviceParams) {
            cacheTemp = applyTemperatureOffset(DeviceValueParser.temperature(deviceParams), offset: tempOffset, factor: tempOffsetFactor)
            update(service.characteristic(.currentTemperature), cacheTemp)
        }
        if !isPro {
            for entry in deviceParams.switches ?? [] {
                let state = entry["switch"]?.jsString ?? "off"
                if entry["outlet"]?.jsNumber == 0 {
                    cacheState1 = state
                    channel1?.characteristic(.on).value = .bool(state == "on")
                } else if entry["outlet"]?.jsNumber == 1 {
                    cacheState2 = state
                    channel2?.characteristic(.on).value = .bool(state == "on")
                }
            }
        }
    }

    private func setChannel(_ channel: Int, _ value: HAPValue) async throws {
        let state = value.boolValue == true ? "on" : "off"
        guard state != (channel == 1 ? cacheState1 : cacheState2) else { return }
        logInfo("Setting channel \(channel) to \(state)")
        guard await sendCommand(["switches": [["outlet": .number(Double(channel - 1)), "switch": .string(state)]]]) else { throw communicationError }
        if channel == 1 { cacheState1 = state } else { cacheState2 = state }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if DeviceValueParser.hasTemperature(params) {
            let temperature = applyTemperatureOffset(DeviceValueParser.temperature(params), offset: tempOffset, factor: tempOffsetFactor)
            if temperature != cacheTemp {
                cacheTemp = temperature
                update(service.characteristic(.currentTemperature), cacheTemp)
                logDebug("Temperature updated to \(cacheTemp.jsDescription)°C")
                platform.setDeviceTemperature(deviceID, cacheTemp)
            }
        }
        guard !isPro else { return }
        for entry in params.switches ?? [] {
            let state = entry["switch"]?.jsString ?? "off"
            if entry["outlet"]?.jsNumber == 0, state != cacheState1 {
                cacheState1 = state
                channel1?.characteristic(.on).value = .bool(state == "on")
                logDebug("Channel 1 updated to \(state)")
            } else if entry["outlet"]?.jsNumber == 1, state != cacheState2 {
                cacheState2 = state
                channel2?.characteristic(.on).value = .bool(state == "on")
                logDebug("Channel 2 updated to \(state)")
            }
        }
    }
}
