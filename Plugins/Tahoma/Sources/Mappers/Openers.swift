import Foundation
import Homeswift
import HomeswiftAI

/// `GarageDoor`, `Generic/CyclicGeneric`, `Generic/RTSGeneric4T` (docs/clean-room/Tahoma.md 5.5): a Garage Door Opener
/// whose Target Door State is a security control.
class GarageDoorMapper: Mapper, @unchecked Sendable {
    override class var expectedStates: [String] { ["core:OpenClosedPartialState", "core:OpenClosedUnknownState", "core:OpenClosedState"] }
    override class var category: AccessoryCategory { .garageDoorOpener }
    override class var kind: String { "garageDoor" }

    private(set) var door: Service!

    var cyclic: Bool { options.cyclic || device.has("cycle") }

    override func build() throws -> [Service] {
        let door = Service(.garageDoorOpener, name: label, isPrimary: true)
        door.characteristic(.obstructionDetected).value = false
        if stateless {
            door.characteristic(.currentDoorState).value = .int(HAP.doorClosed)
            door.characteristic(.targetDoorState).value = .int(HAP.doorClosed)
        }
        door.characteristic(.targetDoorState).securityControl().onWrite { [weak self] value in
            try await self?.writeDoor(value.intValue ?? HAP.doorClosed)
        }
        self.door = door
        return [door]
    }

    func writeDoor(_ target: Int) async throws {
        let previous = door.characteristic(.targetDoorState).value
        let command = device.has("cycle") ? "cycle" : (target == HAP.doorClosed ? "close" : "open")
        try await execute([OverkizCommand(command)]) { [weak self] update in
            guard let self else { return }
            switch update.state {
            case .inProgress:
                door.characteristic(.currentDoorState).value = .int(target == HAP.doorOpen ? HAP.doorOpening : HAP.doorClosing)
            case .completed:
                if stateless {
                    show(target == HAP.doorClosed ? "closed" : "open")
                    if cyclic { schedule("cycle", after: scaled(options.cycleDuration)) { [weak self] in self?.show("closed") } }
                } else if cyclic {
                    let url = device.deviceURL, refresh = environment.refreshDevice
                    schedule("refresh", after: scaled(60)) { await refresh(url) }
                }
            case .failed, .timedOut:
                // Back to the target before the write, whichever it was (the Homebridge plugin skipped OPEN, 10.10).
                door.characteristic(.targetDoorState).value = previous
            default:
                break
            }
        }
    }

    /// An open/closed state as HomeKit shows it; `unknown` changes nothing.
    func show(_ value: String) {
        switch value {
        case "open":
            door.characteristic(.currentDoorState).value = .int(HAP.doorOpen)
            door.characteristic(.targetDoorState).value = .int(HAP.doorOpen)
        case "partial":
            door.characteristic(.currentDoorState).value = .int(HAP.doorStopped)
            door.characteristic(.targetDoorState).value = .int(HAP.doorOpen)
        case "closed":
            door.characteristic(.currentDoorState).value = .int(HAP.doorClosed)
            door.characteristic(.targetDoorState).value = .int(HAP.doorClosed)
        default:
            break
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        for name in GarageDoorMapper.expectedStates { if let value = states[name]?.stringValue { show(value) } }
    }
}

/// `Gate` (5.6): the garage door, with a pedestrian opening on a Lock Mechanism (subtype `pedestrian`).
final class GateMapper: GarageDoorMapper, @unchecked Sendable {
    /// The Homebridge plugin read a gate's state from `core:OpenClosedPedestrianState` only, so a gate reporting just
    /// `core:OpenClosedState` was stateless there; it is read here too (10.10).
    override class var expectedStates: [String] { ["core:OpenClosedPedestrianState", "core:OpenClosedState"] }
    override class var kind: String { "gate" }

    private(set) var pedestrian: Service?

    var pedestrianCommand: String? { ["setPedestrianPosition", "partialPosition", "my"].first(where: device.has) }

    override func build() throws -> [Service] {
        var services = try super.build()
        guard pedestrianCommand != nil || options.pedestrianDuration > 0 else { return services }
        let lock = Service(.lockMechanism, name: "Pedestrian", subtype: "pedestrian")
        if stateless {
            lock.characteristic(.lockCurrentState).value = .int(HAP.secured)
            lock.characteristic(.lockTargetState).value = .int(HAP.secured)
        }
        lock.characteristic(.lockTargetState).securityControl().onWrite { [weak self] value in
            try await self?.writePedestrian(value.intValue ?? HAP.secured)
        }
        pedestrian = lock
        services.append(lock)
        return services
    }

    func writePedestrian(_ target: Int) async throws {
        let command: String
        if target == HAP.unsecured, let pedestrianCommand { command = pedestrianCommand } else { command = target == HAP.unsecured ? "open" : "close" }
        let timed = stateless && pedestrianCommand == nil && options.pedestrianDuration > 0
        try await execute([OverkizCommand(command)]) { [weak self] update in
            guard let self else { return }
            switch update.state {
            case .inProgress where timed:
                let milliseconds = options.pedestrianDuration * 1000
                logger.info("[\(label)] Will stop movement in \(Int(milliseconds)) millisec")
                let execID = update.execID
                schedule("stop", after: scaled(options.pedestrianDuration)) { [weak self] in await self?.stopMovement(execID: execID) }
            case .completed where stateless:
                showPedestrian(target == HAP.secured ? "closed" : "pedestrian")
                if cyclic { schedule("cycle", after: scaled(options.cycleDuration)) { [weak self] in self?.showPedestrian("closed") } }
            default:
                break
            }
        }
    }

    func showPedestrian(_ value: String) {
        switch value {
        case "open", "unknown":
            door.characteristic(.currentDoorState).value = .int(HAP.doorOpen)
            door.characteristic(.targetDoorState).value = .int(HAP.doorOpen)
            pedestrian?.characteristic(.lockCurrentState).value = .int(HAP.lockUnknown)
            pedestrian?.characteristic(.lockTargetState).value = .int(HAP.unsecured)
        case "pedestrian", "partial":
            door.characteristic(.currentDoorState).value = .int(HAP.doorStopped)
            door.characteristic(.targetDoorState).value = .int(HAP.doorOpen)
            pedestrian?.characteristic(.lockCurrentState).value = .int(HAP.unsecured)
            pedestrian?.characteristic(.lockTargetState).value = .int(HAP.unsecured)
        case "closed":
            show("closed")
            pedestrian?.characteristic(.lockCurrentState).value = .int(HAP.secured)
            pedestrian?.characteristic(.lockTargetState).value = .int(HAP.secured)
        default:
            break
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let value = states["core:OpenClosedPedestrianState"]?.stringValue {
            showPedestrian(value)
        } else if !hasState("core:OpenClosedPedestrianState"), let value = states["core:OpenClosedState"]?.stringValue {
            show(value)
        }
    }
}

// MARK: - Locks and alarms (5.8)

/// `DoorLock`: a Lock Mechanism.
final class DoorLockMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .doorLock }
    override class var kind: String { "lock" }
    private var lock: Service!

    override func build() throws -> [Service] {
        let lock = Service(.lockMechanism, name: label, isPrimary: true)
        lock.characteristic(.lockTargetState).securityControl().onWrite { [weak self] value in
            guard let self else { return }
            let target = value.intValue ?? HAP.secured
            try await execute([OverkizCommand("setLockedUnlocked", .string(target == HAP.secured ? "locked" : "unlocked"))]) { [weak self] update in
                guard let self else { return }
                switch update.state {
                case .completed where stateless: self.lock.characteristic(.lockCurrentState).value = .int(target)
                case .failed, .timedOut: self.lock.characteristic(.lockTargetState).value = self.lock.characteristic(.lockCurrentState).value
                default: break
                }
            }
        }
        self.lock = lock
        return [lock]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let value = states["core:LockedUnlockedState"]?.stringValue else { return }
        let current = value == "locked" ? HAP.secured : HAP.unsecured
        lock.characteristic(.lockCurrentState).value = .int(current)
        if isIdle { lock.characteristic(.lockTargetState).value = .int(current) }
    }
}

/// `Alarm` and its MyFox and TSK variants: a Security System whose target is a security control.
class AlarmMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .securitySystem }
    override class var kind: String { "alarm" }
    private(set) var system: Service!

    override func build() throws -> [Service] {
        let system = Service(.securitySystem, name: label, isPrimary: true)
        system.characteristic(.securitySystemTargetState).securityControl().onWrite { [weak self] value in
            try await self?.writeTarget(value.intValue ?? HAP.stay)
        }
        self.system = system
        return [system]
    }

    func commands(for target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.night: [OverkizCommand("alarmZoneOn", .string(options.nightZones))]
        case HAP.away: [OverkizCommand("alarmOn")]
        case HAP.disarm: [OverkizCommand("alarmOff")]
        default: [OverkizCommand("alarmZoneOn", .string(options.stayZones))]
        }
    }

    func writeTarget(_ target: Int) async throws {
        try await execute(commands(for: target)) { [weak self] update in
            guard let self else { return }
            switch update.state {
            case .completed where stateless:
                system.characteristic(.securitySystemCurrentState).value = .int(target)
            case .failed, .timedOut:
                let current = system.characteristic(.securitySystemCurrentState).value
                if current.intValue != HAP.triggered { system.characteristic(.securitySystemTargetState).value = current }
            default:
                break
            }
        }
    }

    /// Current and target together; a target of nil leaves it (triggered).
    func show(current: Int, target: Int?) {
        system.characteristic(.securitySystemCurrentState).value = .int(current)
        if let target { system.characteristic(.securitySystemTargetState).value = .int(target) }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let zones = states["core:ActiveZonesState"]?.scalarText else { return }
        if zones == options.stayZones { show(current: HAP.stay, target: HAP.stay) }
        else if zones == "A,B,C" { show(current: HAP.away, target: HAP.away) }
        else if zones == options.nightZones { show(current: HAP.night, target: HAP.night) }
        else if zones == "triggered" { show(current: HAP.triggered, target: nil) }
        else { show(current: HAP.disarm, target: HAP.disarm) }
    }
}

/// `Alarm/MyFoxAlarmController`. Stay has no command of its own there; it arms partially, as Night does (the Homebridge
/// plugin sent nothing and failed the write, 10.10).
final class MyFoxAlarmMapper: AlarmMapper, @unchecked Sendable {
    override func commands(for target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.away: [OverkizCommand("arm")]
        case HAP.disarm: [OverkizCommand("disarm")]
        default: [OverkizCommand("partial")]
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let status = states["myfox:AlarmStatusState"]?.stringValue else { return }
        switch status {
        case "armed": show(current: HAP.away, target: HAP.away)
        case "partial": show(current: HAP.night, target: HAP.night)
        default: show(current: HAP.disarm, target: HAP.disarm)
        }
    }
}

/// `Alarm/TSKAlarmController`.
final class TSKAlarmMapper: AlarmMapper, @unchecked Sendable {
    override func commands(for target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.night: [OverkizCommand("alarmPartial2")]
        case HAP.away: [OverkizCommand("alarmOn")]
        case HAP.disarm: [OverkizCommand("alarmOff")]
        default: [OverkizCommand("alarmPartial1")]
        }
    }

    static func mode(_ value: String) -> Int {
        switch value {
        case "partial1", "zone1": HAP.stay
        case "total": HAP.away
        case "partial2", "zone2": HAP.night
        default: HAP.disarm
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let current = states["internal:CurrentAlarmModeState"]?.stringValue {
            system.characteristic(.securitySystemCurrentState).value = .int(Self.mode(current))
        }
        if let target = states["internal:TargetAlarmModeState"]?.stringValue {
            system.characteristic(.securitySystemTargetState).value = .int(Self.mode(target))
        }
    }
}
