import Foundation
import Homeswift
import HomeswiftPlugin

/// A cover with no position feedback, positioned by time: the position is estimated from the configured
/// full-travel times (`operationTime`, `operationTimeDown`, 120 s by default). Setting a target starts the
/// motor and returns at once; a timer stops it when the target is (estimated to be) reached. The position
/// survives restarts; a movement does not (its timer is gone), so it starts stopped.
class TimedCoverAccessory: BaseAccessory {
    struct Spec {
        var serviceType: ServiceType
        /// For the logs: "blind", "RF door"...
        var label: String
    }

    let spec: Spec
    private var dsPerPercentUp = Timing.defaultOperationSeconds * 10 / 100
    private var dsPerPercentDown = Timing.defaultOperationSeconds * 10 / 100
    private var moveTimer: Int?
    /// An RF motor takes a new direction directly; a switch motor is stopped first.
    var stopBeforeRetarget = true

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, spec: Spec, extra: [Characteristic] = []) {
        self.spec = spec
        super.init(platform: platform, record: record, box: box)
        category = spec.serviceType.uuid == ServiceType.door.uuid ? .door : spec.serviceType.uuid == ServiceType.window.uuid ? .window : .windowCovering
        if contextValue("cacheCurrentPosition") == nil {
            setContext("cacheCurrentPosition", 0)
            setContext("cacheTargetPosition", 0)
        }
        setContext("cachePositionState", .number(Double(PositionState.stopped.rawValue)))
        service = addService(spec.serviceType, extra: extra, primary: true)
        update(service.characteristic(.currentPosition), currentPosition)
        update(service.characteristic(.targetPosition), targetPosition)
        update(service.characteristic(.positionState), PositionState.stopped.rawValue)
        onWrite(service.characteristic(.targetPosition)) { [weak self] value in try await self?.setTargetPosition(value) }
        if platform.configuration.disableNoResponse != true {
            onRead(service.characteristic(.currentPosition), "CurrentPosition") { [weak self] in self.map { .int($0.currentPosition.clampedInt) } }
            onRead(service.characteristic(.targetPosition), "TargetPosition") { [weak self] in self.map { .int($0.targetPosition.clampedInt) } }
        }
    }

    /// Starts the motor; true when the device took the command.
    func startMove(_ up: Bool) async -> Bool { false }

    func stopMove() async -> Bool { false }

    func setOperationTimes(up: Double, down: Double) {
        dsPerPercentUp = up * 10 / 100
        dsPerPercentDown = down * 10 / 100
        logInfo("Initialized as \(spec.label) (operation time: \(up.jsDescription)s up, \(down.jsDescription)s down)")
    }

    var currentPosition: Double { contextValue("cacheCurrentPosition")?.jsNumber ?? 0 }
    var targetPosition: Double { contextValue("cacheTargetPosition")?.jsNumber ?? 0 }
    private var positionState: PositionState {
        PositionState(rawValue: (contextValue("cachePositionState")?.jsNumber ?? 2).clampedInt) ?? .stopped
    }

    /// Deciseconds, the unit of `cacheLastStartTime`.
    private func nowDs() -> Double { (platform.clock.nowMilliseconds / 100).rounded(.down) }

    /// Where the movement in progress has got to.
    private func estimatePosition(_ state: PositionState) -> Double {
        let elapsed = max(0, nowDs() - (contextValue("cacheLastStartTime")?.jsNumber ?? 0))
        let start = currentPosition, target = targetPosition
        if state == .decreasing {
            return clamp(start - (elapsed / dsPerPercentDown).rounded(.down), min(target, start), 100)
        }
        return clamp(start + (elapsed / dsPerPercentUp).rounded(.down), 0, max(target, start))
    }

    private func setPositionState(_ state: PositionState) {
        setContext("cachePositionState", .number(Double(state.rawValue)))
        update(service.characteristic(.positionState), state.rawValue)
    }

    private func setCurrentPosition(_ position: Double) {
        setContext("cacheCurrentPosition", .number(position))
        update(service.characteristic(.currentPosition), position)
    }

    private func failSet(_ message: String) -> HAPStatusError {
        logError(message)
        revertCharacteristicLater(service.characteristic(.targetPosition), .int(targetPosition.clampedInt), after: Double(Timing.positionCleanup))
        return communicationError
    }

    private func setTargetPosition(_ value: HAPValue) async throws {
        let target = value.doubleValue ?? 0
        let previousState = positionState
        let wasMoving = previousState != .stopped
        if !wasMoving, target == currentPosition { return }
        var position = currentPosition
        var stopped = !wasMoving
        if wasMoving {
            // Work out where the cover is, and supersede the pending stop.
            clearTrackedTimeout(moveTimer)
            moveTimer = nil
            position = estimatePosition(previousState)
            setCurrentPosition(position)
            setContext("cacheLastStartTime", .number(nowDs()))
            if stopBeforeRetarget || target == position {
                if !(await stopMove()) {
                    // Still moving towards the previous target: let it finish.
                    scheduleStop(up: previousState == .increasing, target: targetPosition, from: position)
                    throw failSet("Failed to stop \(spec.label)")
                }
                stopped = true
                setPositionState(.stopped)
            }
        }
        if target == position {
            setContext("cacheTargetPosition", .number(target))
            if !stopped { setPositionState(.stopped) }
            return
        }
        let up = target > position
        let ds = jsRound(abs(target - position) * (up ? dsPerPercentUp : dsPerPercentDown))
        logDebug("Moving from \(position.clampedInt)% to \(target.clampedInt)% - \(up ? "up" : "down") for \((ds / 10).jsDescription)s")
        if !(await startMove(up)) {
            if !stopped { scheduleStop(up: previousState == .increasing, target: targetPosition, from: position) }
            throw failSet("Failed to set \(spec.label) position")
        }
        setContext("cacheTargetPosition", .number(target))
        setContext("cacheLastStartTime", .number(nowDs()))
        setPositionState(up ? .increasing : .decreasing)
        scheduleStop(up: up, target: target, from: position, delay: ds * 100)
    }

    private func scheduleStop(up: Bool, target: Double, from: Double, delay: Double? = nil) {
        let milliseconds = delay ?? abs(target - from) * (up ? dsPerPercentUp : dsPerPercentDown) * 100
        clearTrackedTimeout(moveTimer)
        moveTimer = setTrackedTimeout(milliseconds) { [weak self] in
            guard let self else { return }
            self.moveTimer = nil
            Task { await self.finishMove(target) }
        }
    }

    private func finishMove(_ target: Double) async {
        if !(await stopMove()) { logError("Failed to stop \(spec.label) at \(target.clampedInt)%") }
        // Destroyed, or a new target came while the stop was in flight.
        guard !isDestroyed, moveTimer == nil else { return }
        setPositionState(.stopped)
        setCurrentPosition(target)
        logInfo("\(spec.label.prefix(1).uppercased() + spec.label.dropFirst()) position set to \(target.clampedInt)%")
    }
}

/// A cover on a two-channel switch: channel 0 drives it up, channel 1 down. A DUALR3 reports the motor's
/// power, summed over both channels.
final class SwitchCoverAccessory: TimedCoverAccessory {
    static let outletUp = 0, outletDown = 1
    let powerReadings: Bool

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, spec: Spec) {
        powerReadings = DeviceCatalog.isDualR3(box.device.uiid)
        super.init(platform: platform, record: record, box: box, spec: spec, extra: powerReadings ? Self.powerCharacteristics(full: true) : [])
        let entry = platform.configuration.multi(record.deviceID)
        let up = (entry?.operationTime).flatMap { $0 == 0 ? nil : $0 } ?? Timing.defaultOperationSeconds
        let down = (entry?.operationTimeDown).flatMap { $0 == 0 ? nil : $0 } ?? up
        if powerReadings, platform.configuration.connectionMode != .lan {
            setupPollingInterval { [weak self] in
                guard let self, self.isOnline else { return }
                await self.requestUIActiveUpdate(outlet: Self.outletUp)
            }
        }
        setOperationTimes(up: up, down: down)
    }

    override func startMove(_ up: Bool) async -> Bool {
        await sendCommand(["switches": [["switch": "on", "outlet": .number(Double(up ? Self.outletUp : Self.outletDown))]]])
    }

    override func stopMove() async -> Bool {
        await sendCommand(["switches": [["switch": "off", "outlet": .number(Double(Self.outletUp))], ["switch": "off", "outlet": .number(Double(Self.outletDown))]]])
    }

    /// The motor runs on either channel: power and current are the sum of both.
    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        guard powerReadings else { return }
        let all = deviceParams
        func sum(_ key: String) -> Double? {
            guard params["\(key)_00"] != nil || params["\(key)_01"] != nil else { return nil }
            return (all["\(key)_00"]?.jsNumber ?? 0) + (all["\(key)_01"]?.jsNumber ?? 0)
        }
        var combined: DeviceParams = [:]
        if let power = sum("actPow") { combined["actPow_00"] = .number(power) }
        if let current = sum("current") { combined["current_00"] = .number(current) }
        if let voltage = params["voltage_00"] ?? params["voltage_01"] { combined["voltage_00"] = voltage }
        updateDualR3PowerReadings(service, combined)
    }
}

/// A cover on an RF remote: the bridge transmits its open, stop and close buttons.
final class RFCoverAccessory: TimedCoverAccessory {
    let openChannel: Int
    let stopChannel: Int
    let closeChannel: Int

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox, spec: Spec) {
        let channels = (record.buttons ?? []).map { Int($0.channel) ?? 0 }
        openChannel = channels[safe: 0] ?? 0
        stopChannel = channels[safe: 1] ?? 0
        closeChannel = channels[safe: 2] ?? 0
        super.init(platform: platform, record: record, box: box, spec: spec)
        stopBeforeRetarget = false
        // The sub-device's settings are in rfDevices[bridge].subdevices, by label.
        let entry = platform.configuration.rf(box.device.deviceid)?.subdevices?.first { $0.label == record.name }
        let up = (entry?.operationTime).flatMap { $0 == 0 ? nil : $0 } ?? Timing.defaultOperationSeconds
        let down = (entry?.operationTimeDown).flatMap { $0 == 0 ? nil : $0 } ?? up
        setOperationTimes(up: up, down: down)
    }

    private func transmit(_ channel: Int) async -> Bool { await sendCommand(["cmd": "transmit", "rfChl": .number(Double(channel))]) }
    override func startMove(_ up: Bool) async -> Bool { await transmit(up ? openChannel : closeChannel) }
    override func stopMove() async -> Bool { await transmit(stopChannel) }

    /// RF covers receive no state.
    override func updateState(_ params: DeviceParams) {}
}
