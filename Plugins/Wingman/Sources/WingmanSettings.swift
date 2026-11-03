import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `homes`, `refreshMinutes` and `devices` (Wingmen by
// address, for Setup to pair, when Bonjour does not reach them). Three Device Kinds have Accessory Settings in
// `_accessories`: a Wingman (`wingman`, by its id: its `host` and `port`, its token in the vault), a mirrored accessory
// (`mirroredAccessory`, by its HomeKit id, the id its accessory goes by after `Wingman:`) and a bridge of Apple Home
// (`bridge`, `bridge:<its name>`), whose accessories its Excluded leaves out. The Homebridge-shaped `exclude` (names or
// HomeKit ids), `excludeBridges` (names) and a `devices` entry of a Wingman paired before Setup still load;
// `canonicalSettings` moves them.
extension WingmanPlugin {
    static let wingmanKind = "wingman"
    static let mirroredKind = "mirroredAccessory"
    static let bridgeKind = "bridge"

    /// A bridge of Apple Home's Device Id: `bridge:<name>`, the only thing Apple Home tells of it.
    static func bridgeID(_ name: String) -> String { "bridge:\(name)" }

    /// Left out by `exclude`, by HomeKit id or name, or `excludeBridges`, by its bridge's name.
    nonisolated func isExcludedBySettings(_ accessory: WingmanAPI.Accessory) -> Bool {
        if let exclude = configuration.exclude, exclude.contains(where: { $0 == accessory.id || $0.caseInsensitiveCompare(accessory.name) == .orderedSame }) { return true }
        if let bridge = accessory.bridge, let names = configuration.excludeBridges, names.contains(where: { $0.caseInsensitiveCompare(bridge.name) == .orderedSame }) {
            return true
        }
        return false
    }

    /// Every accessory the paired Wingmen's last reads gave, Excluded ones included.
    func candidates() async -> [WingmanAPI.Accessory] {
        var all: [String: WingmanAPI.Accessory] = [:]
        for link in links.values {
            for accessory in await link.candidates ?? [] { all[accessory.id] = accessory }
        }
        return all.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The mirrored accessories and the bridges, as Discovered Devices: set up unless a Homebridge-shaped list leaves them out.
    func mirroredDevices() async -> [DiscoveredDevice] {
        let accessories = await candidates()
        var devices = accessories.map { accessory in
            DiscoveredDevice(
                deviceID: accessory.id, name: accessory.name, model: accessory.model ?? accessory.manufacturer, isSetUp: !isExcludedBySettings(accessory),
                excludedBySettings: isExcludedBySettings(accessory), kind: Self.mirroredKind)
        }
        var bridges: [String: String] = [:]
        for accessory in accessories { if let bridge = accessory.bridge { bridges[bridge.name.lowercased()] = bridges[bridge.name.lowercased()] ?? bridge.name } }
        for name in bridges.values.sorted() {
            let left = configuration.excludeBridges?.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false
            devices.append(DiscoveredDevice(deviceID: Self.bridgeID(name), name: name, model: "Apple Home bridge", isSetUp: !left, excludedBySettings: left, kind: Self.bridgeKind))
        }
        return devices
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if deviceID.hasPrefix("bridge:") { return Self.bridgeKind }
        if running.contains(where: { $0.id == deviceID }) || configuration.devices?.contains(where: { $0.id == deviceID }) == true
            || context.accessorySettings(for: deviceID).plugin["host"] != nil {
            return Self.wingmanKind
        }
        return await candidates().contains { $0.id == deviceID } ? Self.mirroredKind : nil
    }

    /// The block in its canonical shape, from what the paired Wingmen's last reads gave: `exclude` as Excluded mirrored
    /// accessories (a name each accessory of that name), `excludeBridges` as Excluded bridges, and each `devices` entry of
    /// a Wingman whose token the vault keeps as its Accessory Settings (its name, host and port).
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var accessories = await candidates()
        // A name moves once every Wingman has read its homes: one not read yet may mirror an accessory of that name too.
        for link in links.values where await link.candidates == nil {
            accessories = []
            break
        }
        let ids = (block["devices"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.filter { !$0.isEmpty }
        let paired = Set(context.haveCredentials(ids.map(Optional.some)).compactMap(\.self))
        return Self.canonical(block, accessories: accessories.map { ($0.id, $0.name) }, bridges: accessories.compactMap(\.bridge?.name), paired: paired)
    }

    /// `accessories`: the mirrored accessories' HomeKit ids and names; `bridges`: Apple Home's bridges' names; `paired`:
    /// the Wingmen whose token and certificate the vault keeps.
    static func canonical(_ block: JSONValue, accessories: [(id: String, name: String)], bridges: [String], paired: Set<String>) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = AccessoryEntries(fields)
        entries.excludeList("exclude", in: &fields) { text in
            accessories.filter { $0.id == text || $0.name.caseInsensitiveCompare(text) == .orderedSame }.map(\.id)
        }
        entries.excludeList("excludeBridges", in: &fields) { name in
            let text = name.trimmingCharacters(in: .whitespaces)
            // The bridge's own spelling when a Wingman has seen it; the list's otherwise, matched in any case.
            return text.isEmpty ? [] : [bridgeID(bridges.first { $0.caseInsensitiveCompare(text) == .orderedSame } ?? text)]
        }
        if let list = fields["devices"]?.arrayValue {
            var left: [JSONValue] = []
            for item in list {
                guard let device = item.objectValue, let id = device["id"]?.stringValue, !id.isEmpty, paired.contains(id) else {
                    left.append(item)
                    continue
                }
                var entry = entries.entries[id]?.objectValue ?? [:]
                if entry["name"] == nil, let name = device["name"]?.stringValue, !name.isEmpty { entry["name"] = .string(name) }
                if entry["host"] == nil, let host = device["host"]?.stringValue, !host.isEmpty { entry["host"] = .string(host) }
                if entry["port"] == nil, let port = device["port"]?.intValue, port != defaultPort { entry["port"] = .number(Double(port)) }
                entries.entries[id] = .object(entry)
            }
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        }
        entries.write(into: &fields)
        return .object(fields)
    }
}
