import Foundation
import Homeswift
import HomeswiftPlugin

/// Power monitoring of one channel of a switch used by a simulation.
struct ChannelPower {
    var enabled: Bool
    var fullReadings: Bool
    var isDualR3: Bool
    /// `00`, `01`: the DUALR3 parameter suffix of the channel.
    var suffix: String
    /// The outlet of a DUALR3's `uiActive` requests.
    var uiActiveOutlet: Int?

    init(uiid: Int, channel: Int) {
        isDualR3 = DeviceCatalog.isDualR3(uiid)
        enabled = DeviceCatalog.hasPowerMonitoring(uiid)
        fullReadings = DeviceCatalog.hasFullPowerReadings(uiid)
        suffix = DeviceLimits.channelSuffix(channel)
        uiActiveOutlet = isDualR3 ? channel : nil
    }
}

extension EWeLinkPlugin.Configuration {
    /// A device's `singleDevices` entry, else its `multiDevices` entry, as simulations read them.
    func simulationSettings(_ deviceID: String) -> (type: String?, sensorType: String?, disableTimer: Bool) {
        if let entry = single(deviceID) { return (entry.type, entry.sensorType, entry.disableTimer ?? false) }
        if let entry = multi(deviceID) { return (entry.type, entry.sensorType, entry.disableTimer ?? false) }
        return (nil, nil, false)
    }
}

/// The `lock` simulation: the switch on is unlocked, off is locked.
final class LockAccessory: BaseAccessory {
    let channel = 0
    let lockType: String
    private var currentState = 1
    private var targetState = 1

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        lockType = platform.configuration.simulationSettings(record.deviceID).type ?? "lock"
        super.init(platform: platform, record: record, box: box)
        category = .doorLock
        let on = SwitchHelper.currentState(deviceParams, channel: channel)
        currentState = on ? 0 : 1
        targetState = on ? 0 : 1
        service = addService(.lockMechanism, primary: true)
        onRead(service.characteristic(.lockCurrentState), "LockCurrentState") { [weak self] in self.map { .int($0.currentState) } }
        onRead(service.characteristic(.lockTargetState), "LockTargetState") { [weak self] in self.map { .int($0.targetState) } }
        onWrite(service.characteristic(.lockTargetState)) { [weak self] value in try await self?.setTarget(value) }
        applyInitialState()
    }

    private func setTarget(_ value: HAPValue) async throws {
        let target = value.intValue ?? 1
        try await handleSet("LockTargetState", value) {
            let unlock = target == 0
            guard await sendCommand(SwitchHelper.switchParams(deviceParams, channel: channel, on: unlock)) else {
                revertCharacteristicLater(service.characteristic(.lockTargetState), .int(targetState))
                return false
            }
            targetState = target
            currentState = unlock ? 0 : 1
            update(service.characteristic(.lockCurrentState), currentState)
            logDebug("Lock state: \(unlock ? "UNLOCKED" : "LOCKED")")
            return true
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = SwitchHelper.currentState(deviceParams, channel: channel)
        currentState = on ? 0 : 1
        targetState = on ? 0 : 1
        update(service.characteristic(.lockCurrentState), currentState)
        update(service.characteristic(.lockTargetState), targetState)
        logDebug("Lock state updated: \(on ? "UNLOCKED" : "LOCKED")")
    }
}

/// The `valve` simulation: a generic valve that turns itself off after its duration (unless `disableTimer`),
/// counting down in HomeKit, with Eve power characteristics when the device has them.
///
/// The Home app draws a running valve's countdown from SetDuration and the moment it saw Active, which it
/// forgets when reopened; the remaining time is mirrored onto SetDuration while the valve runs, and the
/// configured duration (kept across restarts) comes back when it stops.
final class ValveAccessory: BaseAccessory {
    let channel = 0
    let disableTimer: Bool
    let powerReadings: Bool
    let fullPowerReadings: Bool
    private var timer: Int?
    private var tick: Int?
    private var startedAt: Double?
    private var runDuration: Double?
    private var userSetDuration = Double(Timing.valveDefaultSeconds)

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let uiid = box.device.uiid
        fullPowerReadings = DeviceCatalog.hasFullPowerReadings(uiid)
        powerReadings = DeviceCatalog.hasPowerMonitoring(uiid) || DeviceValueParser.hasPowerReadings(box.params)
        disableTimer = platform.configuration.simulationSettings(record.deviceID).disableTimer
        super.init(platform: platform, record: record, box: box)
        category = .sprinkler
        service = addService(
            .valve, optional: disableTimer ? [] : [.setDuration, .remainingDuration],
            extra: powerReadings ? Self.powerCharacteristics(full: fullPowerReadings) : [], primary: true)
        service.characteristic(.valveType).value = 1
        onRead(service.characteristic(.active), "Active") { [weak self] in self.map { .int($0.isOn ? 1 : 0) } }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        onRead(service.characteristic(.inUse), "InUse") { [weak self] in self.map { .int($0.isOn ? 1 : 0) } }
        if !disableTimer {
            if let saved = contextValue("valveSetDuration")?.jsNumber, saved > 0 { userSetDuration = saved }
            update(service.characteristic(.setDuration), userSetDuration)
            // Without a read handler the Home app would get the full duration back and restart its countdown.
            onRead(service.characteristic(.remainingDuration), "RemainingDuration") { [weak self] in self.map { .int($0.remaining) } }
            onWrite(service.characteristic(.setDuration)) { [weak self] value in self?.setDuration(value) }
        }
        applyInitialState()
    }

    private var isOn: Bool { SwitchHelper.currentState(deviceParams, channel: channel) }

    private func setActive(_ value: HAPValue) async throws {
        try await handleSet("Active", value) {
            let on = value.intValue == 1
            guard await sendCommand(SwitchHelper.switchParams(deviceParams, channel: channel, on: on)) else { return false }
            update(service.characteristic(.inUse), on ? 1 : 0)
            if on, !disableTimer {
                startTimer(userSetDuration)
            } else {
                clearTimer()
                if !disableTimer { update(service.characteristic(.remainingDuration), 0) }
            }
            return true
        }
    }

    private func setDuration(_ value: HAPValue) {
        let duration = value.doubleValue ?? 0
        guard duration > 0 else { return }
        userSetDuration = duration
        setContext("valveSetDuration", .number(duration))
        if service.characteristic(.active).value.intValue == 1 {
            startTimer(duration)
            logDebug("Valve duration updated to \(duration.jsDescription)s while active")
        }
    }

    private func startTimer(_ duration: Double) {
        clearTimerHandles()
        startedAt = platform.clock.nowMilliseconds
        runDuration = duration
        update(service.characteristic(.remainingDuration), duration)
        timer = setTrackedTimeout(duration * 1000) { [weak self] in
            guard let self else { return }
            Task { try? await self.service.characteristic(.active).write(.int(0)) }
        }
        tick = setTrackedInterval(1000) { [weak self] in
            guard let self else { return }
            let remaining = self.remaining
            self.update(self.service.characteristic(.remainingDuration), remaining)
            self.update(self.service.characteristic(.setDuration), remaining)
        }
    }

    /// Clears the timer and puts the configured duration back on the slider.
    private func clearTimer() {
        clearTimerHandles()
        startedAt = nil
        runDuration = nil
        if !disableTimer { update(service.characteristic(.setDuration), userSetDuration) }
    }

    private func clearTimerHandles() {
        clearTrackedTimeout(timer)
        timer = nil
        clearTrackedInterval(tick)
        tick = nil
    }

    private var remaining: Int {
        guard let startedAt, let runDuration else { return 0 }
        let elapsed = (platform.clock.nowMilliseconds - startedAt) / 1000
        return max(0, jsRound(runDuration - elapsed)).clampedInt
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = isOn
        update(service.characteristic(.active), on ? 1 : 0)
        update(service.characteristic(.inUse), on ? 1 : 0)
        // Switched off elsewhere: no countdown left.
        if !on, !disableTimer, timer != nil {
            clearTimer()
            update(service.characteristic(.remainingDuration), 0)
        }
        if powerReadings { updateDualR3PowerReadings(service, params, suffix: DeviceLimits.channelSuffix(channel), fullReadings: fullPowerReadings) }
        logDebug("Valve state updated: \(on ? "ACTIVE" : "INACTIVE")")
    }
}

/// The `tap` simulation, and Zigbee water valves (SWV-BSP): a faucet-type valve with an auto-off timer
/// (unless `disableTimer`).
final class TapAccessory: BaseAccessory {
    let channel = 0
    let disableTimer: Bool
    private var timer: Int?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        disableTimer = platform.configuration.simulationSettings(record.deviceID).disableTimer
        super.init(platform: platform, record: record, box: box)
        category = .faucet
        service = addService(.valve, optional: disableTimer ? [] : [.setDuration, .remainingDuration], primary: true)
        service.characteristic(.valveType).value = 3
        onRead(service.characteristic(.active), "Active") { [weak self] in self.map { .int($0.isOn ? 1 : 0) } }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        onRead(service.characteristic(.inUse), "InUse") { [weak self] in self.map { .int($0.isOn ? 1 : 0) } }
        if !disableTimer {
            update(service.characteristic(.setDuration), Timing.valveDefaultSeconds)
            onWrite(service.characteristic(.setDuration)) { [weak self] value in self?.setDuration(value) }
        }
        applyInitialState()
    }

    private var isOn: Bool { SwitchHelper.currentState(deviceParams, channel: channel) }

    private func setActive(_ value: HAPValue) async throws {
        try await handleSet("Active", value) {
            let on = value.intValue == 1
            guard await sendCommand(SwitchHelper.switchParams(deviceParams, channel: channel, on: on)) else { return false }
            update(service.characteristic(.inUse), on ? 1 : 0)
            if on, !disableTimer {
                let set = service.characteristic(.setDuration).value.doubleValue ?? 0
                let duration = set == 0 ? Double(Timing.valveDefaultSeconds) : set
                update(service.characteristic(.remainingDuration), duration)
                startTimer(duration)
            } else {
                clearTrackedTimeout(timer)
                timer = nil
                if !disableTimer { update(service.characteristic(.remainingDuration), 0) }
            }
            return true
        }
    }

    private func setDuration(_ value: HAPValue) {
        let duration = value.doubleValue ?? 0
        guard service.characteristic(.active).value.intValue == 1 else { return }
        update(service.characteristic(.remainingDuration), duration)
        startTimer(duration)
        logDebug("Tap duration updated to \(duration.jsDescription)s while active")
    }

    private func startTimer(_ duration: Double) {
        clearTrackedTimeout(timer)
        timer = setTrackedTimeout(duration * 1000) { [weak self] in
            guard let self else { return }
            self.timer = nil
            Task { try? await self.service.characteristic(.active).write(.int(0)) }
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = isOn
        update(service.characteristic(.active), on ? 1 : 0)
        update(service.characteristic(.inUse), on ? 1 : 0)
        logDebug("Tap state updated: \(on ? "ACTIVE" : "INACTIVE")")
    }
}

/// The `sensor` simulation: the switch's state as a sensor of `sensorType` (motion by default; contact, leak
/// or water, smoke or fire, co, co2, occupancy). Motion and contact sensors count their last activation for
/// Eve. Power readings when the device has them.
final class SimulatedSensorAccessory: BaseAccessory {
    let channel = 0
    let sensorType: String
    let useLastActivation: Bool
    let power: ChannelPower
    private var sensorCharacteristic: Characteristic!
    private let eveInitialTime: Double

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let catalog = ChannelPower(uiid: box.device.uiid, channel: channel)
        if catalog.enabled {
            power = catalog
        } else {
            var detected = catalog
            let suffix = catalog.suffix
            detected.enabled = ["power", "voltage", "current", "actPow_\(suffix)", "voltage_\(suffix)", "current_\(suffix)"].contains { box.params[$0] != nil }
            detected.fullReadings = false
            detected.isDualR3 = false
            detected.uiActiveOutlet = nil
            power = detected
        }
        eveInitialTime = (platform.clock.nowMilliseconds / 1000).rounded(.down)
        let type = platform.configuration.single(record.deviceID)?.sensorType ?? platform.configuration.multi(record.deviceID)?.sensorType
        sensorType = type?.nonEmpty ?? "motion"
        useLastActivation = !["water", "leak", "fire", "smoke", "co", "co2", "occupancy"].contains(sensorType)
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        let (serviceType, characteristicType) = Self.kind(sensorType)
        var extra: [Characteristic] = []
        if useLastActivation { extra.append(Characteristic(EveCharacteristic.lastActivation)) }
        if power.enabled { extra += Self.powerCharacteristics(full: power.fullReadings) }
        service = addService(serviceType, extra: extra, primary: true)
        sensorCharacteristic = service.characteristic(characteristicType)
        onRead(sensorCharacteristic, "SensorState") { [weak self] in self?.sensorCharacteristic.value }
        if power.enabled {
            logDebug("Power monitoring enabled (full readings: \(power.fullReadings))")
            if !power.isDualR3 || platform.configuration.connectionMode != .lan {
                let outlet = power.uiActiveOutlet
                setupPollingInterval { [weak self] in
                    guard let self, self.isOnline else { return }
                    await self.requestUIActiveUpdate(outlet: outlet)
                }
            }
        }
        applyInitialState()
        logDebug("Sensor initialized (type: \(sensorType))")
    }

    static func kind(_ type: String) -> (ServiceType, CharacteristicType) {
        switch type {
        case "water", "leak": (.leakSensor, .leakDetected)
        case "fire", "smoke": (.smokeSensor, .smokeDetected)
        case "co": (.carbonMonoxideSensor, .carbonMonoxideDetected)
        case "co2": (.carbonDioxideSensor, .carbonDioxideDetected)
        case "contact": (.contactSensor, .contactSensorState)
        case "occupancy": (.occupancySensor, .occupancyDetected)
        default: (.motionSensor, .motionDetected)
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = SwitchHelper.currentState(deviceParams, channel: channel)
        let detected = on ? 1 : 0
        if sensorCharacteristic.value.intValue != detected {
            update(sensorCharacteristic, detected)
            if useLastActivation, detected == 1, let last = service[EveCharacteristic.lastActivation] {
                update(last, (platform.clock.nowMilliseconds / 1000).rounded(.down) - eveInitialTime)
            }
            logDebug("Sensor state updated: \(on ? "DETECTED" : "CLEAR")")
        }
        if power.enabled { updateDualR3PowerReadings(service, params, suffix: power.suffix, fullReadings: power.fullReadings) }
    }
}

/// The `sensor_leak` simulation: a DW2 contact sensor (UIID 102, 154) as a leak sensor; the contact open
/// (`switch` off) is a leak. Battery low under `lowBattThreshold` (25 %).
final class SensorLeakAccessory: BaseAccessory {
    let lowBatteryThreshold: Double
    private var batteryService: Service!
    private var cacheBattery = 100.0
    private let eveInitialTime: Double

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let threshold = platform.configuration.single(record.deviceID)?.lowBattThreshold ?? 0
        lowBatteryThreshold = threshold == 0 ? 25 : min(threshold, 100)
        eveInitialTime = (platform.clock.nowMilliseconds / 1000).rounded(.down)
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        service = addService(.leakSensor, extra: [Characteristic(EveCharacteristic.lastActivation)], primary: true)
        onRead(service.characteristic(.leakDetected), "LeakDetected") { [weak self] in self?.service.characteristic(.leakDetected).value }
        batteryService = addService(.battery, optional: [.batteryLevel])
        applyInitialState()
        logDebug("Leak sensor initialized (low battery threshold: \(lowBatteryThreshold.jsDescription)%)")
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let raw = params["battery"]?.jsNumber {
            if DeviceCatalog.batteryType(uiid) == .voltage {
                cacheBattery = jsRound((min(max(raw, 2), 3) - 2) * 100)
            } else {
                cacheBattery = raw
            }
            update(batteryService.characteristic(.batteryLevel), cacheBattery)
            update(batteryService.characteristic(.statusLowBattery), cacheBattery < lowBatteryThreshold ? 1 : 0)
            logDebug("Battery updated: \(cacheBattery.jsDescription)%")
        }
        if let state = params["switch"] {
            // The DW2 is inverted here: switch on is dry, off is a leak.
            let leak = state == "on" ? 0 : 1
            if service.characteristic(.leakDetected).value.intValue != leak {
                update(service.characteristic(.leakDetected), leak)
                if leak == 1, let last = service[EveCharacteristic.lastActivation] {
                    update(last, (platform.clock.nowMilliseconds / 1000).rounded(.down) - eveInitialTime)
                }
                logDebug("Leak sensor state updated: \(leak == 1 ? "LEAK DETECTED" : "NO LEAK")")
            }
        }
    }
}

/// The `p_button` simulation: the switch turning on is a single press.
final class ProgrammableButtonAccessory: BaseAccessory {
    let channel = 0
    let power: ChannelPower
    private var inUse = false

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        power = ChannelPower(uiid: box.device.uiid, channel: channel)
        super.init(platform: platform, record: record, box: box)
        category = .programmableSwitch
        service = addService(
            .statelessProgrammableSwitch, optional: [CharacteristicType.programmableSwitchEvent.with(minValue: 0, maxValue: 0, validValues: [0])],
            extra: power.enabled ? Self.powerCharacteristics(full: power.fullReadings) : [], primary: true)
        if power.enabled, !power.isDualR3 || platform.configuration.connectionMode != .lan { setupUIActivePolling(outlet: power.uiActiveOutlet) }
        onRead(service.characteristic(.programmableSwitchEvent), "ProgrammableSwitchEvent") { [weak self] in self?.service.characteristic(.programmableSwitchEvent).value }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if !inUse, SwitchHelper.currentState(deviceParams, channel: channel) {
            inUse = true
            setTrackedTimeout(Double(Timing.positionCleanup)) { [weak self] in self?.inUse = false }
            service.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
            logInfo("Button pressed")
        }
        if power.enabled { updateDualR3PowerReadings(service, params, suffix: power.suffix, fullReadings: power.fullReadings) }
    }
}

/// The `doorbell` simulation: the switch turning on rings.
final class DoorbellAccessory: BaseAccessory {
    let channel = 0
    private var inUse = false

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .videoDoorbell
        service = addService(.doorbell, primary: true)
        onRead(service.characteristic(.programmableSwitchEvent), "ProgrammableSwitchEvent") { [weak self] in self?.service.characteristic(.programmableSwitchEvent).value }
        // A DUALR3 reports fresh state only while uiActive is requested.
        if DeviceCatalog.isDualR3(box.device.uiid), platform.configuration.connectionMode != .lan { setupUIActivePolling(outlet: channel) }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        guard !inUse, SwitchHelper.currentState(deviceParams, channel: channel) else { return }
        inUse = true
        setTrackedTimeout(Double(Timing.positionCleanup)) { [weak self] in self?.inUse = false }
        service.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
        logInfo("Doorbell pressed")
    }
}

/// The `fan` simulation of a dimmer (UIID 36, 44, 57): on/off and the brightness as the speed, in steps of
/// `brightnessStep`; `deviceModel: offlineAsOff` shows it off while offline.
final class LightFanAccessory: BaseAccessory {
    let brightnessStep: Double
    let offlineAsOff: Bool
    private var cacheState = "off"
    private var cacheSpeed = 0.0

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let entry = platform.configuration.light(record.deviceID)
        let step = entry?.brightnessStep ?? 0
        brightnessStep = min(step == 0 ? 1 : step, 100)
        offlineAsOff = entry?.deviceModel == "offlineAsOff"
        super.init(platform: platform, record: record, box: box)
        category = .fan
        service = addService(.fan, optional: [CharacteristicType.rotationSpeed.with(minStep: brightnessStep)], primary: true)
        onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.cacheState == "on") }
        onWrite(service.characteristic(.on)) { [weak self] value in try await self?.setOn(value) }
        onRead(service.characteristic(.rotationSpeed), "RotationSpeed") { [weak self] in self.map { .double($0.cacheSpeed) } }
        onWrite(service.characteristic(.rotationSpeed)) { [weak self] value in try await self?.setSpeed(value) }
        let switchParam = DeviceCatalog.switchParamName(uiid)
        cacheState = deviceParams[switchParam] == "on" ? "on" : "off"
        if let brightness = DeviceCatalog.brightness(uiid) {
            let raw = deviceParams[brightness.param].flatMap { $0.jsNumber == 0 || $0.isNull ? nil : $0 } ?? .number(Double(brightness.min))
            cacheSpeed = Double(DeviceCatalog.normalizeBrightness(uiid, Double(raw.jsParseInt ?? 0)))
        }
        service.characteristic(.on).value = .bool(cacheState == "on")
        update(service.characteristic(.rotationSpeed), cacheSpeed)
    }

    private func setOn(_ value: HAPValue) async throws {
        try await handleSet("On", value) {
            let state = value.boolValue == true ? "on" : "off"
            guard state != cacheState else { return true }
            guard await sendCommand([DeviceCatalog.switchParamName(uiid): .string(state)]) else {
                revertCharacteristicLater(service.characteristic(.on), .bool(cacheState == "on"))
                return false
            }
            cacheState = state
            logInfo("Fan: \(cacheState)")
            return true
        }
    }

    private func setSpeed(_ value: HAPValue) async throws {
        let speed = value.doubleValue ?? 0
        guard speed != cacheSpeed, await debounceLatest("speed", Double(Timing.stateInitDelay)) else { return }
        try await handleSet("RotationSpeed", value) {
            guard let brightness = DeviceCatalog.brightness(uiid) else { return false }
            let deviceValue = DeviceCatalog.denormalizeBrightness(uiid, speed)
            var params: DeviceParams = [brightness.param: brightness.asString ? .string(String(deviceValue)) : .number(Double(deviceValue))]
            if brightness.requiresMode { params["mode"] = 0 }
            guard await sendCommand(params) else {
                revertCharacteristicLater(service.characteristic(.rotationSpeed), .double(cacheSpeed))
                return false
            }
            cacheSpeed = speed
            logInfo("Fan speed: \(cacheSpeed.jsDescription)%")
            return true
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let value = params[DeviceCatalog.switchParamName(uiid)] {
            let state = value == "on" ? "on" : "off"
            if state != cacheState {
                cacheState = state
                service.characteristic(.on).value = .bool(cacheState == "on")
                logDebug("Fan state updated: \(cacheState)")
            }
        }
        if let brightness = DeviceCatalog.brightness(uiid), let raw = params[brightness.param] {
            let speed = Double(DeviceCatalog.normalizeBrightness(uiid, Double(raw.jsParseInt ?? 0)))
            if speed != cacheSpeed {
                cacheSpeed = speed
                update(service.characteristic(.rotationSpeed), cacheSpeed)
                logDebug("Fan speed updated: \(cacheSpeed.jsDescription)%")
            }
        }
        if offlineAsOff, !isOnline, cacheState != "off" {
            service.characteristic(.on).value = false
            cacheState = "off"
            logInfo("Fan offline, showing as off")
        }
    }
}

/// The `purifier` simulation: the switch as an air purifier, always in auto.
final class PurifierAccessory: BaseAccessory {
    let channel = 0
    let power: ChannelPower
    private var cacheState = "off"

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        power = ChannelPower(uiid: box.device.uiid, channel: channel)
        super.init(platform: platform, record: record, box: box)
        category = .airPurifier
        service = addService(
            .airPurifier, optional: [CharacteristicType.targetAirPurifierState.with(minValue: 1, maxValue: 1, validValues: [1])],
            extra: power.enabled ? Self.powerCharacteristics(full: power.fullReadings) : [], primary: true)
        if power.enabled, !power.isDualR3 || platform.configuration.connectionMode != .lan { setupUIActivePolling(outlet: power.uiActiveOutlet) }
        onRead(service.characteristic(.active), "Active") { [weak self] in .int(self?.cacheState == "on" ? 1 : 0) }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        service.characteristic(.targetAirPurifierState).value = 1
        onReadAlways(service.characteristic(.targetAirPurifierState)) { .int(1) }
        onRead(service.characteristic(.currentAirPurifierState), "CurrentAirPurifierState") { [weak self] in .int(self?.cacheState == "on" ? 2 : 0) }
        cacheState = service.characteristic(.active).value.intValue == 1 ? "on" : "off"
        applyInitialState()
    }

    private func setActive(_ value: HAPValue) async throws {
        try await handleSet("Active", value) {
            let on = value.intValue == 1
            guard await sendCommand(SwitchHelper.switchParams(deviceParams, channel: channel, on: on)) else {
                revertCharacteristicLater(service.characteristic(.active), .int(cacheState == "on" ? 1 : 0))
                return false
            }
            cacheState = on ? "on" : "off"
            update(service.characteristic(.currentAirPurifierState), on ? 2 : 0)
            logDebug("Purifier: \(cacheState)")
            return true
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = SwitchHelper.currentState(deviceParams, channel: channel)
        if on != (cacheState == "on") {
            cacheState = on ? "on" : "off"
            update(service.characteristic(.active), on ? 1 : 0)
            update(service.characteristic(.currentAirPurifierState), on ? 2 : 0)
            logDebug("Purifier state updated: \(cacheState)")
        }
        if power.enabled { updateDualR3PowerReadings(service, params, suffix: power.suffix, fullReadings: power.fullReadings) }
    }
}

/// The `tv` simulation: the switch as a television (an AV receiver, a streaming box), on the bridge as the
/// Homebridge plugin has it.
final class TVAccessory: BaseAccessory {
    let channel = 0
    let power: ChannelPower
    private var cacheState = "off"

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        power = ChannelPower(uiid: box.device.uiid, channel: channel)
        super.init(platform: platform, record: record, box: box)
        category = .television
        service = addService(.television, extra: power.enabled ? Self.powerCharacteristics(full: power.fullReadings) : [], primary: true)
        service.characteristic(.configuredName).value = .string(record.displayName)
        service.characteristic(.sleepDiscoveryMode).value = 1
        if power.enabled, !power.isDualR3 || platform.configuration.connectionMode != .lan { setupUIActivePolling(outlet: power.uiActiveOutlet) }
        onRead(service.characteristic(.active), "Active") { [weak self] in .int(self?.cacheState == "on" ? 1 : 0) }
        onWrite(service.characteristic(.active)) { [weak self] value in try await self?.setActive(value) }
        cacheState = service.characteristic(.active).value.intValue == 1 ? "on" : "off"
        applyInitialState()
    }

    private func setActive(_ value: HAPValue) async throws {
        try await handleSet("Active", value) {
            let on = value.intValue == 1
            guard await sendCommand(SwitchHelper.switchParams(deviceParams, channel: channel, on: on)) else {
                revertCharacteristicLater(service.characteristic(.active), .int(cacheState == "on" ? 1 : 0))
                return false
            }
            cacheState = on ? "on" : "off"
            logDebug("TV: \(cacheState)")
            return true
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let on = SwitchHelper.currentState(deviceParams, channel: channel)
        if on != (cacheState == "on") {
            cacheState = on ? "on" : "off"
            update(service.characteristic(.active), on ? 1 : 0)
            logDebug("TV state updated: \(cacheState)")
        }
        if power.enabled { updateDualR3PowerReadings(service, params, suffix: power.suffix, fullReadings: power.fullReadings) }
    }
}
