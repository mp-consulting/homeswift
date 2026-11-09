import Foundation
import HomeswiftPlugin

// Power On (GLOSSARY.md, the bridge's `PowerOn.swift`): what a Zigbee light does when its power comes back, as
// Zigbee2MQTT exposes it: `power_on_behavior` (off, on, toggle, previous) and, on lights that keep one,
// `color_temp_startup`, the white it comes back in (in mired; 65535 its last). The bridge's Natural Light is `previous`
// at the white it gives; Custom is `on` at a white. Zigbee2MQTT sets neither a brightness to come back at.
extension Zigbee2MQTTPlugin {
    static let powerOnKeys = ["power_on_behavior", "color_temp_startup"]
    /// `color_temp_startup`'s "its last white".
    static let previousWhite = 65535

    /// A light's power-on exposes: its `power_on_behavior` values, and its `color_temp_startup` range in mired.
    private func powerOnExposes(_ accessoryID: String) -> (device: DeviceAccessory, behaviours: [String], startup: ClosedRange<Int>?)? {
        guard let device = devices[AccessoryNaming.deviceID(of: accessoryID, platform: Self.platform)] else { return nil }
        func all(_ exposes: [Expose]) -> [Expose] { exposes.flatMap { [$0] + all($0.features ?? []) } }
        let exposes = all(device.entry.definition?.exposes ?? [])
        guard let behaviour = exposes.first(where: { $0.property == "power_on_behavior" && $0.isEnum && $0.isSettable }) else { return nil }
        let startup = exposes.first { $0.property == "color_temp_startup" && $0.isNumericRange && $0.isSettable }
            .flatMap { expose in expose.valueMin.flatMap { low in expose.valueMax.map { Int(low)...Int($0) } } }
        return (device, behaviour.valueStrings, startup)
    }

    public func powerOnSupport(of accessoryID: String) async -> PowerOnSupport? {
        guard let (_, values, startup) = powerOnExposes(accessoryID) else { return nil }
        var behaviours: [PowerOn.Behaviour] = []
        if values.contains("previous"), startup != nil { behaviours.append(.natural) }
        if values.contains("on") { behaviours.append(.lastOn) }
        if values.contains("previous") { behaviours.append(.powerLoss) }
        if values.contains("off") { behaviours.append(.off) }
        if values.contains("on"), startup != nil { behaviours.append(.custom) }
        guard !behaviours.isEmpty else { return nil }
        return PowerOnSupport(behaviours: behaviours, brightness: false, mirek: startup)
    }

    public func powerOn(of accessoryID: String) async throws -> PowerOn? {
        guard let (device, _, startup) = powerOnExposes(accessoryID) else { return nil }
        guard let behaviour = device.powerOnState["power_on_behavior"]?.stringValue else {
            // Not in its state yet (many lights report it only when asked): asked now, for the next read.
            publisher?.get(device.entry.commandTopic, startup == nil ? ["power_on_behavior"] : Self.powerOnKeys)
            return nil
        }
        let white = device.powerOnState["color_temp_startup"]?.intValue.flatMap { $0 == Self.previousWhite || $0 <= 0 ? nil : PowerOn.kelvin(mirek: $0) }
        switch behaviour {
        case "off": return PowerOn(.off)
        case "previous": return PowerOn(.powerLoss, temperature: white)
        case "on": return white.map { PowerOn(.custom, temperature: $0) } ?? PowerOn(.lastOn)
        default: return nil
        }
    }

    public func setPowerOn(_ value: PowerOn, of accessoryID: String) async throws {
        guard let (device, _, startup) = powerOnExposes(accessoryID), let publisher else { throw PowerOnError("This Zigbee light has no power-on behaviour") }
        let white: JSONValue? = startup.map { range in
            .number(Double(value.mirek.map { min(range.upperBound, max(range.lowerBound, $0)) } ?? Self.previousWhite))
        }
        let behaviour: String = switch value.behaviour {
        case .off: "off"
        case .lastOn, .custom: "on"
        case .powerLoss, .natural: "previous"
        case .default: throw PowerOnError("A Zigbee light has no default of its own to come back in")
        }
        var change: [String: JSONValue] = ["power_on_behavior": .string(behaviour)]
        if value.behaviour != .off, let white { change["color_temp_startup"] = white }
        publisher.set(device.entry.commandTopic, change)
        // What its next state will say, kept now so the sheet shows it at once.
        for (key, entry) in change { device.powerOnState[key] = entry }
    }
}
