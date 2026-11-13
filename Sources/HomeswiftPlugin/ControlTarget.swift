import Foundation
import Homeswift

/// What a Control's target or Power Switch names (GLOSSARY.md, "Control"): an accessory, or one of its Functions,
/// `<accessory id>#<key>` with the key Separate Functions gives it (docs/adr/0011-a-control-names-a-function.md), and what
/// the bridge drives there: a shutter, a light, or an Appliance's On, Active or target state. A remote drives whatever is
/// attached to it, locks, garage doors and alarms included (docs/adr/0012-a-remote-drives-what-it-is-given.md).
public struct ControlTarget: Sendable {
    /// The accessory found, or the device whose Function it names.
    public let accessory: Accessory
    /// The Function's key; nil for the whole accessory.
    public let function: String?
    /// What it drives from: the Function's services, or all of the accessory's.
    public let services: [Service]

    public init(accessory: Accessory, function: String? = nil, services: [Service]? = nil) {
        self.accessory = accessory
        self.function = function
        self.services = services ?? accessory.services
    }

    /// The target `reference` names, or nil when it is not on the bridge (a plugin starting, a device gone): an accessory
    /// by its id, else the Function after the last `#` of the accessory before it, when it has one of that key (an id with
    /// a `#` of its own still names the whole accessory). A separated accessory's Functions are its device's.
    public static func resolve(_ reference: String, find: (String) -> Accessory?) -> ControlTarget? {
        if let whole = find(reference) { return ControlTarget(accessory: whole) }
        guard let mark = reference.lastIndex(of: "#") else { return nil }
        let key = String(reference[reference.index(after: mark)...])
        guard !key.isEmpty, let found = find(String(reference[..<mark])) else { return nil }
        let device = found.separatedFrom ?? found
        guard let function = Separation.functions(of: device).first(where: { $0.key == key }) else { return nil }
        return ControlTarget(accessory: device, function: key, services: function.services)
    }

    /// How a Control names a Function of an accessory.
    public static func reference(_ accessoryID: String, function: String?) -> String {
        function.map { "\(accessoryID)#\($0)" } ?? accessoryID
    }

    /// What kind of target it is: a shutter, a light, an Appliance, or nil for one with nothing a Control drives (a sensor,
    /// a thermostat).
    public var kind: RemoteControl.TargetKind? {
        if covering != nil { return .shutter }
        if light != nil { return .light }
        return applianceSwitches.isEmpty ? nil : .appliance
    }

    /// What moves to a position: a shutter, a blind, a door, a window.
    public var covering: Service? {
        services.first { Self.coverings.contains($0.type) && $0[.targetPosition] != nil }
    }

    /// The light it dims, the one with a Brightness first, and its On.
    public var light: (service: Service, on: Characteristic)? {
        guard let service = services.first(where: { $0.type == .lightbulb && $0[.brightness] != nil }) ?? services.first(where: { $0.type == .lightbulb }),
              let on = service[.on] else { return nil }
        return (service, on)
    }

    /// What it turns on and off as an Appliance: a Function's own; for a whole accessory, all of its switches and outlets
    /// when it is made only of them, else its primary one's (an air purifier's, not its child lock's), else its first that
    /// is no switch (a lock's, not its auto-lock switch).
    public var applianceSwitches: [ApplianceSwitch] {
        let drivable = services.compactMap(Self.applianceSwitch(of:))
        guard function == nil, !drivable.allSatisfy({ Self.isSwitch($0.service) }) else { return drivable }
        return (drivable.first { $0.service.isPrimary } ?? drivable.first { !Self.isSwitch($0.service) }).map { [$0] } ?? []
    }

    /// The switch or outlet it powers lights with as a Power Switch: its first.
    public var powerService: Service? {
        services.first(where: Self.isSwitch)
    }

    /// The On it powers lights with as a Power Switch.
    public var powerSwitch: Characteristic? {
        powerService?[.on]
    }

    /// Whether it drives a door or something its plugin marks a security control (a lock's, a garage door's or an
    /// alarm's target state, a door strike): the Assistant asks the user before attaching one to a remote.
    public var isSecurity: Bool {
        services.contains { $0.type == .door || $0.characteristics.contains(where: \.isSecurityControl) }
    }

    /// Whether what it turns on and off opens rather than switches on: a garage door, a lock (its "on" is unlocked).
    public var opens: Bool {
        let switches = applianceSwitches
        return !switches.isEmpty && switches.allSatisfy(\.opens)
    }

    /// The Appliances a Control turns on and off (GLOSSARY.md, "Appliance"), by the characteristic it writes.
    static let onAppliances: [ServiceType] = [.switch, .outlet, .fan]
    static let activeAppliances: [ServiceType] = [
        .fanv2, .airPurifier, .television, .heaterCooler, .humidifierDehumidifier, .valve, .faucet, .irrigationSystem,
    ]
    /// What moves to a position, as a shutter does.
    static let coverings: [ServiceType] = [.windowCovering, .door, .window]

    static func isSwitch(_ service: Service) -> Bool { service.type == .switch || service.type == .outlet }

    /// What an Appliance's service is turned on and off with: an On, an Active, or a garage door's, a lock's or an alarm's
    /// target state.
    static func applianceSwitch(of service: Service) -> ApplianceSwitch? {
        let written: CharacteristicType? =
            onAppliances.contains(service.type) ? .on
            : activeAppliances.contains(service.type) ? .active
            : service.type == .garageDoorOpener ? .targetDoorState
            : service.type == .lockMechanism ? .lockTargetState
            : service.type == .securitySystem ? .securitySystemTargetState
            : nil
        guard let written, let characteristic = service[written] else { return nil }
        return ApplianceSwitch(service: service, characteristic: characteristic)
    }
}

/// What an Appliance is turned on and off with (GLOSSARY.md, "Appliance"): its service and the characteristic written.
/// "On" is what Apple Home lights a tile for: on, active, a garage door open, a lock unlocked, an alarm armed.
public struct ApplianceSwitch: Sendable {
    public let service: Service
    public let characteristic: Characteristic

    /// Whether it is on. A garage door, a lock and an alarm are read from their current state, which follows a change
    /// made outside HomeKit (a wall button, a key) where the target may not; from the target when the current state says
    /// nothing (a door stopped half way, a lock jammed).
    public var isOn: Bool {
        let target = characteristic.value.intValue
        switch service.type {
        case .garageDoorOpener:
            // Current Door State: 0 open, 1 closed, 2 opening, 3 closing, 4 stopped.
            switch service[.currentDoorState]?.value.intValue {
            case 0, 2: return true
            case 1, 3: return false
            default: return target == 0
            }
        case .lockMechanism:
            // Lock Current State: 0 unsecured, 1 secured, 2 jammed, 3 unknown.
            switch service[.lockCurrentState]?.value.intValue {
            case 0: return true
            case 1: return false
            default: return target == 0
            }
        case .securitySystem:
            // 0 to 2 armed, 3 disarmed, 4 triggered (armed).
            return (service[.securitySystemCurrentState]?.value.intValue ?? target).map { $0 != 3 } ?? false
        default:
            return characteristic.type.uuid == CharacteristicType.active.uuid ? target == 1 : characteristic.value.boolValue == true
        }
    }

    /// Whether its "on" is open: a garage door's, a lock's (unlocked).
    public var opens: Bool {
        service.type == .garageDoorOpener || service.type == .lockMechanism
    }

    /// The value that turns it on or off: a garage door opens (0) or closes (1), a lock unlocks (0) or locks (1), an alarm
    /// arms Away (1) or disarms (3).
    public func value(_ on: Bool) -> HAPValue {
        if opens { return .int(on ? 0 : 1) }
        if service.type == .securitySystem { return .int(on ? 1 : 3) }
        return characteristic.type.uuid == CharacteristicType.active.uuid ? .int(on ? 1 : 0) : .bool(on)
    }
}
