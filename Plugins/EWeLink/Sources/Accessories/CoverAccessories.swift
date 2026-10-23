import Foundation
import Homeswift
import HomeswiftPlugin

enum PositionState: Int {
    case decreasing = 0, increasing = 1, stopped = 2
}

/// Motorised curtains and blinds with position feedback (UIID 11, 67, 91, 258, and a DUALR3 in motor mode).
/// The catalog names the position parameters; UIID 11's `setclose` is inverted (0 is open), and fully open or
/// closed is `switch` on or off. Setting a target near the position while moving stops the motor.
final class CurtainAccessory: BaseAccessory {
    static let positionUpdateThreshold = 5.0
    static let positionDebounce = 1000.0

    private var currentPosition = 0.0
    private var targetPosition = 0.0
    private var positionState = PositionState.stopped
    private var lastReportedPosition = 0.0
    private var debounceTimer: Int?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .windowCovering
        service = addService(.windowCovering, primary: true)
        onRead(service.characteristic(.currentPosition), "CurrentPosition") { [weak self] in self.map { .int(Int($0.currentPosition)) } }
        onRead(service.characteristic(.targetPosition), "TargetPosition") { [weak self] in self.map { .int(Int($0.targetPosition)) } }
        onWrite(service.characteristic(.targetPosition)) { [weak self] value in try await self?.setTargetPosition(value) }
        onReadAlways(service.characteristic(.positionState)) { [weak self] in .int(self?.positionState.rawValue ?? 2) }
        initializeFromParams()
        // Fresh state once the WebSocket is up, one curtain after the other.
        let delay = Double(Timing.curtainQueryDelay + platform.curtainStaggerDelay())
        setTrackedTimeout(delay) { [weak self] in
            Task { await self?.refreshState() }
        }
    }

    private func refreshState() async {
        logDebug("Refreshing state - Current: \(Int(currentPosition))%, Target: \(Int(targetPosition))%")
        _ = await platform.queryDeviceState(deviceID)
        _ = await trackedSleep(Double(Timing.stateInitDelay))
        logDebug("State refreshed - Current: \(Int(currentPosition))%, Target: \(Int(targetPosition))%")
    }

    private func position(_ value: JSONValue, inverted: Bool) -> Double {
        let raw = clamp(value.jsNumber ?? 0, 0, 100)
        return inverted ? 100 - raw : raw
    }

    private func initializeFromParams() {
        if let config = DeviceCatalog.position(uiid) {
            if let raw = deviceParams[config.current] { currentPosition = position(raw, inverted: config.inverted) }
            if let raw = deviceParams[config.target], config.target != config.current {
                targetPosition = position(raw, inverted: config.inverted)
            } else {
                targetPosition = currentPosition
            }
        }
        update(service.characteristic(.currentPosition), currentPosition)
        update(service.characteristic(.targetPosition), targetPosition)
        update(service.characteristic(.positionState), positionState.rawValue)
        logDebug("Curtain initialized at position \(Int(currentPosition))%")
    }

    private func setTargetPosition(_ value: HAPValue) async throws {
        let newTarget = clamp(value.doubleValue ?? 0, 0, 100)
        let motorTurn = DeviceCatalog.motorTurnParam(uiid)
        // Tapping near the position while moving means stop.
        if positionState != .stopped, abs(newTarget - currentPosition) <= 5 {
            logInfo("Stop requested (target \(Int(newTarget))% near current \(Int(currentPosition))%)")
            try await sendStopCommand()
            return
        }
        if newTarget == currentPosition {
            logDebug("Already at position \(Int(newTarget))%, skipping command")
            targetPosition = newTarget
            return
        }
        let previousTarget = targetPosition, previousState = positionState
        targetPosition = newTarget
        logInfo("Setting position to \(Int(newTarget))% (from \(Int(currentPosition))%)")
        positionState = newTarget > currentPosition ? .increasing : .decreasing
        update(service.characteristic(.positionState), positionState.rawValue)

        var params: DeviceParams = [:]
        if let config = DeviceCatalog.position(uiid) {
            let deviceValue = config.inverted ? 100 - newTarget : newTarget
            // UIID 11 opens and closes fully with the switch.
            if config.inverted, newTarget == 0 || newTarget == 100 {
                params["switch"] = onOff(newTarget == 100)
            } else {
                params[config.target] = .number(deviceValue)
            }
            if let motorTurn {
                params[motorTurn] = newTarget > currentPosition ? 1 : newTarget < currentPosition ? 2 : 0
            }
        } else {
            params["location"] = .number(newTarget)
        }
        logDebug("Sending curtain command (UIID \(uiid)): \(JSONValue.object(params).text())")
        guard await sendCommand(params) else {
            // No phantom movement in HomeKit.
            targetPosition = previousTarget
            positionState = previousState
            update(service.characteristic(.positionState), previousState.rawValue)
            revertCharacteristicLater(service.characteristic(.targetPosition), .int(Int(previousTarget)))
            throw communicationError
        }
    }

    private func sendStopCommand() async throws {
        var params: DeviceParams = [:]
        if let motorTurn = DeviceCatalog.motorTurnParam(uiid) {
            params[motorTurn] = 0
        } else {
            params["switch"] = "off"
        }
        logDebug("Sending stop command (UIID \(uiid)): \(JSONValue.object(params).text())")
        guard await sendCommand(params) else {
            revertCharacteristicLater(service.characteristic(.targetPosition), .int(Int(targetPosition)))
            throw communicationError
        }
        targetPosition = currentPosition
        positionState = .stopped
        update(service.characteristic(.targetPosition), targetPosition)
        update(service.characteristic(.positionState), positionState.rawValue)
    }

    private func stop() {
        targetPosition = currentPosition
        positionState = .stopped
        update(service.characteristic(.targetPosition), targetPosition)
        update(service.characteristic(.positionState), positionState.rawValue)
        logDebug("Curtain stopped")
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        guard let config = DeviceCatalog.position(uiid) else {
            logDebug("No position config for UIID \(uiid)")
            return
        }
        var positionUpdated = false
        let wasMoving = positionState != .stopped
        if let raw = params[config.current] {
            let newPosition = position(raw, inverted: config.inverted)
            let oldPosition = currentPosition
            currentPosition = newPosition
            // HomeKit hears about big steps and the arrival; small steps are debounced.
            let change = abs(newPosition - lastReportedPosition)
            if change >= Self.positionUpdateThreshold || newPosition == targetPosition {
                clearTrackedTimeout(debounceTimer)
                debounceTimer = nil
                update(service.characteristic(.currentPosition), currentPosition)
                lastReportedPosition = newPosition
                if oldPosition != newPosition { logDebug("Position update: \(Int(oldPosition))% → \(Int(newPosition))%") }
            } else if change > 0, debounceTimer == nil {
                debounceTimer = setTrackedTimeout(Self.positionDebounce) { [weak self] in
                    guard let self else { return }
                    self.debounceTimer = nil
                    self.update(self.service.characteristic(.currentPosition), self.currentPosition)
                    self.lastReportedPosition = self.currentPosition
                }
            }
            positionUpdated = true
        }
        if config.target != config.current {
            if let raw = params[config.target] {
                targetPosition = position(raw, inverted: config.inverted)
                update(service.characteristic(.targetPosition), targetPosition)
                logDebug("Target position synced to \(Int(targetPosition))%")
                positionUpdated = true
            }
        } else if positionUpdated {
            targetPosition = currentPosition
            positionState = .stopped
            update(service.characteristic(.targetPosition), targetPosition)
            logDebug("Position synced to \(Int(currentPosition))%")
        }
        if positionUpdated {
            let previousState = positionState
            positionState = targetPosition == currentPosition ? .stopped : targetPosition > currentPosition ? .increasing : .decreasing
            update(service.characteristic(.positionState), positionState.rawValue)
            if wasMoving, positionState == .stopped, previousState != .stopped {
                logInfo("Reached target position: \(Int(currentPosition))%")
            }
        }
        if params["motorTurn"]?.jsNumber == 0, params["motorTurn"]?.doubleValue != nil, wasMoving {
            positionState = .stopped
            targetPosition = currentPosition
            update(service.characteristic(.targetPosition), targetPosition)
            update(service.characteristic(.positionState), positionState.rawValue)
            logInfo("Movement stopped at \(Int(currentPosition))%")
        }
        if params["switch"] == "off" { stop() }
    }
}

/// A motor with position feedback (`currLocation`) and a target (`location`), turned with `motorTurn`.
final class MotorAccessory: BaseAccessory {
    private var currentPosition = 0.0
    private var targetPosition = 0.0
    private var positionState = PositionState.stopped

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .windowCovering
        service = addService(.windowCovering, primary: true)
        onRead(service.characteristic(.currentPosition), "CurrentPosition") { [weak self] in self.map { .int(Int($0.currentPosition)) } }
        onRead(service.characteristic(.targetPosition), "TargetPosition") { [weak self] in self.map { .int(Int($0.targetPosition)) } }
        onWrite(service.characteristic(.targetPosition)) { [weak self] value in try await self?.setTargetPosition(value) }
        onReadAlways(service.characteristic(.positionState)) { [weak self] in .int(self?.positionState.rawValue ?? 2) }
        if let current = deviceParams["currLocation"]?.jsNumber { currentPosition = clamp(current, 0, 100) }
        targetPosition = deviceParams["location"]?.jsNumber.map { clamp($0, 0, 100) } ?? currentPosition
        update(service.characteristic(.currentPosition), currentPosition)
        update(service.characteristic(.targetPosition), targetPosition)
        update(service.characteristic(.positionState), positionState.rawValue)
        logDebug("Motor initialized at position \(Int(currentPosition))%")
    }

    private func setTargetPosition(_ value: HAPValue) async throws {
        let newTarget = clamp(value.doubleValue ?? 0, 0, 100)
        if newTarget == currentPosition {
            targetPosition = newTarget
            return
        }
        targetPosition = newTarget
        logInfo("Setting motor position to \(Int(newTarget))%")
        positionState = newTarget > currentPosition ? .increasing : .decreasing
        update(service.characteristic(.positionState), positionState.rawValue)
        let turn = newTarget > currentPosition ? 1 : newTarget < currentPosition ? 2 : 0
        guard await sendCommand(["location": .number(newTarget), "motorTurn": .number(Double(turn))]) else { throw communicationError }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let raw = params["currLocation"]?.jsNumber {
            let position = clamp(raw, 0, 100)
            if position != currentPosition {
                currentPosition = position
                update(service.characteristic(.currentPosition), currentPosition)
                logDebug("Current position updated to \(Int(currentPosition))%")
            }
        }
        if let raw = params["location"]?.jsNumber {
            let target = clamp(raw, 0, 100)
            if target != targetPosition {
                targetPosition = target
                update(service.characteristic(.targetPosition), targetPosition)
                logDebug("Target position updated to \(Int(targetPosition))%")
            }
        }
        positionState = targetPosition == currentPosition ? .stopped : targetPosition > currentPosition ? .increasing : .decreasing
        update(service.characteristic(.positionState), positionState.rawValue)
    }
}

/// A garage door on a momentary switch: on, then off after half a second; the door is assumed open or
/// closed ten seconds later (there is no sensor). Also the `garage` and `gate` simulations.
final class GarageAccessory: BaseAccessory {
    private var currentState = 1
    private var targetState = 1
    private var movementTimer: Int?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .garageDoorOpener
        service = addService(.garageDoorOpener, primary: true)
        onRead(service.characteristic(.currentDoorState), "CurrentDoorState") { [weak self] in self.map { .int($0.currentState) } }
        onRead(service.characteristic(.targetDoorState), "TargetDoorState") { [weak self] in self.map { .int($0.targetState) } }
        onWrite(service.characteristic(.targetDoorState)) { [weak self] value in try await self?.setTargetDoorState(value) }
        onRead(service.characteristic(.obstructionDetected), "ObstructionDetected") { .bool(false) }
        applyInitialState()
    }

    private func setTargetDoorState(_ value: HAPValue) async throws {
        let requested = value.intValue ?? 1
        try await handleSet("TargetDoorState", value) {
            let previousTarget = targetState, previousCurrent = currentState
            let opening = requested == 0
            targetState = requested
            currentState = opening ? 2 : 3
            update(service.characteristic(.currentDoorState), currentState)
            // Most openers take a momentary switch.
            guard await sendCommand(["switch": "on"]) else {
                targetState = previousTarget
                currentState = previousCurrent
                update(service.characteristic(.currentDoorState), previousCurrent)
                revertCharacteristicLater(service.characteristic(.targetDoorState), .int(previousTarget))
                return false
            }
            setTrackedTimeout(Double(Timing.stateInitDelay)) { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    if !(await self.sendCommand(["switch": "off"])) { self.logError("Failed to release garage door switch") }
                }
            }
            clearTrackedTimeout(movementTimer)
            movementTimer = setTrackedTimeout(Double(Timing.garageOperation)) { [weak self] in
                guard let self else { return }
                self.movementTimer = nil
                self.currentState = opening ? 0 : 1
                self.update(self.service.characteristic(.currentDoorState), self.currentState)
            }
            return true
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        // The state would need a sensor; the switch only pulses.
        update(service.characteristic(.currentDoorState), currentState)
        update(service.characteristic(.targetDoorState), targetState)
        logDebug("Door state updated: \(currentState)")
    }
}
