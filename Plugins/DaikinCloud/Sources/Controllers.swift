import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// What the HomeKit side needs from the plugin: the settings, the log, and the refresh after a write.
struct ServiceContext: Sendable {
    var settings: DaikinSettings
    var logger: Logger
    /// Schedules the (debounced) poll that catches the cache up with the cloud after a write.
    var forceUpdate: @Sendable () -> Void = {}

    /// Runs a write from HomeKit: on success the refresh is scheduled; on failure a warning is logged and the
    /// Home app gets "No Response" instead of a stale success.
    @discardableResult
    func write<T: Sendable>(_ label: String, refresh: Bool = true, _ operation: () async throws -> T) async throws -> T {
        let result: T
        do {
            result = try await operation()
        } catch {
            logger.warning("\(label): write failed: \(message(of: error))")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        if refresh { forceUpdate() }
        return result
    }
}

/// `Math.round`: halves go up, also below zero.
func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

/// Sets a characteristic within the range it declares, so HomeKit never gets a value its props refuse.
func setClamped(_ characteristic: Characteristic, _ value: Double) {
    var value = value
    if let min = characteristic.type.minValue { value = max(min, value) }
    if let max = characteristic.type.maxValue { value = min(max, value) }
    characteristic.value = .double(value)
}

/// Fan speed between the unit's small scale (1 to 5, or 1 to 3) and HomeKit's 0-100 % slider: 5 of 5 is
/// 100 %, 1 of 5 is 20 %, and a step of 100 / max gives positions that round-trip.
enum FanSpeed {
    static let defaultMax = 5.0

    static func fanMax(_ maxValue: Double?) -> Double {
        guard let maxValue, maxValue > 0 else { return defaultMax }
        return maxValue
    }

    /// The slider step, in %, for one step of the unit.
    static func percentStep(_ maxValue: Double?) -> Double { 100 / fanMax(maxValue) }

    static func percent(speed: Double, maxValue: Double?) -> Double {
        min(100, max(0, jsRound(speed / fanMax(maxValue) * 100)))
    }

    static func deviceSpeed(percent: Double, minValue: Double?, maxValue: Double?) -> Double {
        let lowest = (minValue ?? 0) > 0 ? minValue! : 1
        let highest = fanMax(maxValue)
        return max(lowest, min(highest, jsRound(percent / 100 * highest)))
    }

    /// What a RotationSpeed write does: nothing (with the reason), or the writes to make.
    enum Plan: Equatable {
        case skip(String)
        case write(deviceSpeed: Double, writes: [(path: String, value: JSONValue)])

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            switch (lhs, rhs) {
            case (.skip(let a), .skip(let b)): a == b
            case (.write(let a, let x), .write(let b, let y)): a == b && x.map(\.path) == y.map(\.path) && x.map(\.value) == y.map(\.value)
            default: false
            }
        }
    }
}

/// Reads the fixed fan speed of an operation mode and plans RotationSpeed writes.
struct FanSpeedController: Sendable {
    let device: DaikinCloudDevice
    let managementPointID: String

    var operationMode: String { device.operationMode(managementPointID, default: "") }

    func fixed(_ mode: String? = nil) -> DataPoint {
        device.data(managementPointID, "fanControl", DataPaths.fanSpeedFixed(mode ?? operationMode))
    }

    /// The fixed speed as a percentage, only while the unit is in `fixed` fan mode: in auto or quiet the stored
    /// fixed value is not the actual speed, and HomeKit may replay a cached value as a write.
    func percentIfFixed(_ mode: String? = nil) -> Double? {
        let mode = mode ?? operationMode
        guard device.data(managementPointID, "fanControl", DataPaths.fanSpeedCurrentMode(mode)).string == Daikin.FanSpeedMode.fixed.rawValue else { return nil }
        let fixed = fixed(mode)
        return fixed.number.map { FanSpeed.percent(speed: $0, maxValue: fixed.maxValue) }
    }

    func plan(percent: Double) -> FanSpeed.Plan {
        let mode = operationMode
        // A mode without a fixed speed: PATCHing a missing path is a 422 ("No Response" in HomeKit).
        let fixed = fixed(mode)
        guard fixed.value != nil else { return .skip("operationMode \(mode) does not support fixed fan speed") }
        let speed = FanSpeed.deviceSpeed(percent: percent, minValue: fixed.minValue, maxValue: fixed.maxValue)
        let currentModePath = DataPaths.fanSpeedCurrentMode(mode)
        let currentMode = device.data(managementPointID, "fanControl", currentModePath)
        // In auto or quiet, the stored fixed speed coming back is HomeKit replaying its cache (when another
        // characteristic of the service changes), not a person moving the slider.
        if let current = currentMode.value, current != .string(Daikin.FanSpeedMode.fixed.rawValue), JSONValue.number(speed) == fixed.value {
            let name = current.stringValue ?? current.text()
            return .skip("device is in \"\(name)\" mode and speed \(DaikinSettings.jsNumber(speed)) already matches the stored fixed value. "
                + "This is likely a HomeKit cache replay, not a user fan-speed change.")
        }
        var writes: [(path: String, value: JSONValue)] = []
        // Switch to fixed only when needed and allowed: some modes (dry on some units) allow auto only.
        if currentMode.string != Daikin.FanSpeedMode.fixed.rawValue, (currentMode.values ?? []).contains(Daikin.FanSpeedMode.fixed.rawValue) {
            writes.append((currentModePath, .string(Daikin.FanSpeedMode.fixed.rawValue)))
        }
        writes.append((DataPaths.fanSpeedFixed(mode), .number(speed)))
        return .write(deviceSpeed: speed, writes: writes)
    }
}

/// The swing (fan direction) of the current operation mode, shared by the HeaterCooler's SwingMode, the
/// separate Fan and the Oscillation switch, so all three agree on what swinging means.
struct SwingController: Sendable {
    let device: DaikinCloudDevice
    let managementPointID: String

    /// Horizontal first: the order the Homebridge plugin writes them in.
    static let axes: [DataPaths.FanAxis] = [.horizontal, .vertical]

    private var operationMode: String { device.operationMode(managementPointID) }

    /// An axis's swing, nil when the axis does not exist in this mode.
    func axisValue(_ axis: DataPaths.FanAxis) -> String? {
        guard let value = device.data(managementPointID, "fanControl", DataPaths.fanDirection(operationMode, axis)).value else { return nil }
        return value.stringValue ?? DaikinSettings.display(value)
    }

    var isSupported: Bool { axisValue(.vertical) != nil || axisValue(.horizontal) != nil }

    /// Off only when an axis that exists is stopped.
    var isSwinging: Bool { Self.axes.allSatisfy { axisValue($0) != Daikin.stop } }

    /// The axes not in the requested state yet.
    func axesToWrite(_ enabled: Bool) -> [DataPaths.FanAxis] {
        let target = enabled ? Daikin.swing : Daikin.stop
        return Self.axes.filter { axis in axisValue(axis).map { $0 != target } ?? false }
    }

    func set(_ enabled: Bool) async throws {
        let target = enabled ? Daikin.swing : Daikin.stop
        let mode = operationMode
        for axis in axesToWrite(enabled) {
            try await device.setData(managementPointID, "fanControl", .string(target), path: DataPaths.fanDirection(mode, axis))
        }
    }
}

enum ThresholdKind: String, Sendable {
    case heating, cooling
    var operationMode: String { rawValue }
}

/// Which temperatureControl setpoint (room temperature, leaving water offset or temperature) an operation
/// mode uses, from the setpoint mode, then the control mode, then the operation mode. Units without a
/// setpoint mode (air conditioners) go by the control mode alone.
struct SetpointResolver: Sendable {
    let device: DaikinCloudDevice
    let managementPointID: String

    var controlMode: String {
        // Only Althermas have a control mode; others work on the room temperature.
        guard let value = device.data(managementPointID, "controlMode").value, DaikinSettings.isTruthy(value) else { return Daikin.ControlMode.roomTemperature.rawValue }
        return value.stringValue ?? DaikinSettings.display(value)
    }

    var setpointMode: String? {
        guard let value = device.data(managementPointID, "setpointMode").value, DaikinSettings.isTruthy(value) else { return nil }
        return value.stringValue ?? DaikinSettings.display(value)
    }

    func setpoint(_ operationMode: String) throws -> String {
        let control = controlMode
        let leavingWater = control == Daikin.ControlMode.leavingWaterTemperature.rawValue
        let room = Daikin.Setpoint.roomTemperature.rawValue
        let offset = Daikin.Setpoint.leavingWaterOffset.rawValue
        let temperature = Daikin.Setpoint.leavingWaterTemperature.rawValue
        guard let mode = setpointMode else { return leavingWater ? offset : room }
        switch Daikin.SetpointMode(rawValue: mode) {
        case .fixed: return leavingWater ? temperature : room
        case .weatherDependent: return leavingWater ? offset : room
        case .weatherDependentHeatingFixedCooling:
            if control == Daikin.ControlMode.roomTemperature.rawValue { return room }
            if leavingWater, operationMode == Daikin.OperationMode.heating.rawValue { return offset }
            if leavingWater, operationMode == Daikin.OperationMode.cooling.rawValue { return temperature }
        case nil: break
        }
        throw DaikinError("Could not determine the TemperatureControlSetpoint for operationMode: \(operationMode), setpointMode: \(mode), controlMode: \(control), deviceId: \(device.id)")
    }

    func path(_ operationMode: String) throws -> String { DataPaths.setpoint(operationMode, try setpoint(operationMode)) }

    func read(_ operationMode: String) -> DataPoint {
        guard let path = try? path(operationMode) else { return .missing }
        return device.data(managementPointID, "temperatureControl", path)
    }
}

/// Keeps Daikin's single auto setpoint at the middle of HomeKit's heating/cooling range.
///
/// HomeKit writes both thresholds of a range change in one request, and the handlers run at once: the sync
/// runs once, after the last threshold write in flight settles, with the final values of both.
actor AutoSetpointSync {
    let device: DaikinCloudDevice
    let managementPointID: String
    let logger: Logger
    let name: String
    private var inFlight = 0
    private var pending: [ThresholdKind: Double] = [:]

    init(device: DaikinCloudDevice, managementPointID: String, logger: Logger, name: String) {
        self.device = device
        self.managementPointID = managementPointID
        self.logger = logger
        self.name = name
    }

    private var resolver: SetpointResolver { SetpointResolver(device: device, managementPointID: managementPointID) }

    /// Runs a threshold write, then syncs once no other is in flight; rethrows the write's error.
    func writeThreshold(_ kind: ThresholdKind, _ value: Double, _ write: @Sendable () async throws -> Void) async throws {
        inFlight += 1
        pending[kind] = value
        var failure: (any Error)?
        do {
            try await write()
        } catch {
            failure = error
            if pending[kind] == value { pending[kind] = nil }
        }
        inFlight -= 1
        if inFlight == 0, !pending.isEmpty {
            let overrides = pending
            pending = [:]
            await sync(overrides)
        }
        if let failure { throw failure }
    }

    /// Best effort: the threshold write already succeeded, and a missed sync only leaves the Daikin app
    /// with a stale auto setpoint. Nothing happens when the unit has no auto setpoint.
    func sync(_ overrides: [ThresholdKind: Double] = [:]) async {
        do {
            let autoPath = try resolver.path(Daikin.OperationMode.auto.rawValue)
            let auto = device.data(managementPointID, "temperatureControl", autoPath)
            guard auto.value != nil else { return }
            guard let heating = overrides[.heating] ?? resolver.read(Daikin.OperationMode.heating.rawValue).number,
                let cooling = overrides[.cooling] ?? resolver.read(Daikin.OperationMode.cooling.rawValue).number
            else { return }
            // The middle, to the nearest 0.5°: the thresholds' step and Daikin's.
            var midpoint = jsRound(heating + cooling) / 2
            if let min = auto.minValue { midpoint = max(min, midpoint) }
            if let max = auto.maxValue { midpoint = min(max, midpoint) }
            if let current = auto.number, abs(current - midpoint) < 0.01 { return }
            logger.debug("[\(name)] SYNC AutoSetpoint, heating=\(DaikinSettings.jsNumber(heating)) cooling=\(DaikinSettings.jsNumber(cooling)) → auto=\(DaikinSettings.jsNumber(midpoint))")
            try await device.setData(managementPointID, "temperatureControl", .number(midpoint), path: autoPath)
        } catch {
            logger.debug("[\(name)] AutoSetpoint sync skipped: \(message(of: error))")
        }
    }
}
