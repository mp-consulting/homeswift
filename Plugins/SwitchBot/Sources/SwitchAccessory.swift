import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The service a Bot or a Relay Switch shows itself as (`type`), each with the characteristic HomeKit writes and the
/// values of on and off.
enum ControlKind: String, CaseIterable {
    case `switch`, outlet, garagedoor, door, window, windowcovering, lock, faucet, fan, stateful

    /// `type` compared without case (4.x compares it exactly and falls back on a type that matches nothing); `switch`
    /// by default, as 5.x.
    init(type: String?, fallback: ControlKind = .switch) {
        self = type.flatMap { ControlKind(rawValue: $0.lowercased()) } ?? fallback
    }

    var serviceType: ServiceType {
        switch self {
        case .switch: .switch
        case .outlet: .outlet
        case .garagedoor: .garageDoorOpener
        case .door: .door
        case .window: .window
        case .windowcovering: .windowCovering
        case .lock: .lockMechanism
        case .faucet: .faucet
        case .fan: .fanv2
        case .stateful: .statefulProgrammableSwitch
        }
    }

    var written: CharacteristicType {
        switch self {
        case .switch, .outlet: .on
        case .garagedoor: .targetDoorState
        case .door, .window, .windowcovering: .targetPosition
        case .lock: .lockTargetState
        case .faucet, .fan: .active
        case .stateful: .programmableSwitchOutputState
        }
    }

    var category: AccessoryCategory {
        switch self {
        case .switch, .stateful: .switch
        case .outlet: .outlet
        case .garagedoor: .garageDoorOpener
        case .door: .door
        case .window: .window
        case .windowcovering: .windowCovering
        case .lock: .doorLock
        case .faucet: .faucet
        case .fan: .fan
        }
    }

    /// Whether a written value asks for on: anything but the off value.
    func isOn(_ value: HAPValue) -> Bool {
        switch self {
        case .switch, .outlet: value.boolValue ?? false
        case .garagedoor: value.intValue != 1
        case .lock: value.intValue != 1
        default: (value.intValue ?? (value.boolValue == true ? 1 : 0)) != 0
        }
    }

    func show(_ on: Bool, on service: Service) {
        switch self {
        case .switch, .outlet: service.characteristic(.on).value = .bool(on)
        case .garagedoor:
            service.characteristic(.currentDoorState).value = .int(on ? 0 : 1)
            service.characteristic(.targetDoorState).value = .int(on ? 0 : 1)
        case .door, .window, .windowcovering:
            service.characteristic(.currentPosition).value = .int(on ? 100 : 0)
            service.characteristic(.targetPosition).value = .int(on ? 100 : 0)
            service.characteristic(.positionState).value = .int(2)
        case .lock:
            service.characteristic(.lockCurrentState).value = .int(on ? 0 : 1)
            service.characteristic(.lockTargetState).value = .int(on ? 0 : 1)
        case .faucet, .fan: service.characteristic(.active).value = .int(on ? 1 : 0)
        case .stateful:
            service.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
            service.characteristic(.programmableSwitchOutputState).value = .int(on ? 1 : 0)
        }
    }
}

/// Bot, Relay Switch 1 and 1PM, Plug and Plug Mini: one control service, `turnOn`/`turnOff`, and a Bot's `press`.
final class SwitchAccessory: DeviceAccessory, @unchecked Sendable {
    let kind: ControlKind
    let control: Service
    let battery: Service?
    let family: Family
    /// A Bot's mode: `switch`, `press` or `multipress` (a webhook's `deviceMode` changes it).
    private var mode: String
    private var target = false
    private var reported: Bool?
    private var presses = 0

    override var category: AccessoryCategory { kind.category }

    init(info: DeviceInfo, family: Family, link: DeviceLink, debounce: Duration, logger: Logger) {
        self.family = family
        kind = family == .plug ? .outlet : ControlKind(type: info.options.string("type"))
        mode = family == .bot ? (info.options.string("mode")?.lowercased() ?? "switch") : "switch"
        control = Service(kind.serviceType, name: info.name, isPrimary: true)
        battery = family == .bot ? Self.batteryService(info.name) : nil
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([control, battery])
        if !["switch", "press", "multipress"].contains(mode) {
            logger.error("\(info.type) \(info.name): mode \(mode) is not switch, press or multipress; using switch")
            mode = "switch"
        }
        kind.show(false, on: control)
        let kind = kind
        // What opens a door, a window or a lock is confirmed on the bridge's own surfaces (garage doors and locks are by default).
        if [.door, .window, .windowcovering].contains(kind) { control.characteristic(kind.written).securityControl() }
        control.characteristic(kind.written).onWrite { [weak self] value in
            try await self?.write { self?.record(kind.isOn(value)) }
        }
    }

    private func record(_ on: Bool) {
        target = on
        if on, mode == "multipress" { presses += 1 }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        if family == .bot, let deviceMode = status["deviceMode"]?.stringValue {
            switch deviceMode {
            case "pressMode": lock.withLock { mode = "press" }
            case "switchMode": lock.withLock { mode = "switch" }
            default: break
            }
        }
        let on: Bool?
        switch family {
        case .relay: on = status["switchStatus"].flatMap(number).map { $0 != 0 }
        default: on = (status["power"] ?? status["powerState"])?.stringValue.map { $0.lowercased() == "on" }
        }
        if var on {
            let pressMode = lock.withLock { mode != "switch" }
            if pressMode { on = false }
            lock.withLock {
                reported = on
                target = on
            }
            kind.show(on, on: control)
        }
        showBattery(status, on: battery)
    }

    override func showOffline() { kind.show(false, on: control) }

    override func push() async throws {
        let (on, previous, mode, presses) = lock.withLock { () -> (Bool, Bool?, String, Int) in
            defer { self.presses = 0 }
            return (target, reported, self.mode, self.presses)
        }
        let allowPush = options.flag("allowPush")
        guard allowPush || on != previous || mode != "switch" else { return }
        if mode != "switch" {
            guard on || mode == "press" && allowPush else { return }
            let count = mode == "multipress" ? max(presses, 1) : 1
            try await repeated(Array(repeating: Command(command: "press"), count: count))
            // A press returns the control to off.
            lock.withLock { target = false }
            kind.show(false, on: control)
            return
        }
        if try await repeated([Command(command: on ? "turnOn" : "turnOff")]) { lock.withLock { reported = on } }
    }

    /// The commands, sent `doublePress` times `pushRatePress` seconds apart (a Bot's options).
    private func repeated(_ commands: [Command]) async throws -> Bool {
        let times = family == .bot ? max(Int(saturating: options.number("doublePress") ?? 1) ?? 1, 1) : 1
        var accepted = true
        for time in 0..<min(times, 10) {
            if time > 0 { try await Task.sleep(for: .seconds(max(options.number("pushRatePress") ?? 15, 0))) }
            accepted = try await send(commands) && accepted
        }
        return accepted
    }
}
