import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `hubs` (each hub's `host` and `name`; its token is in
// the vault), `transitionMs` and `scenes`. Each device (its id, or its product's for a group of parts), and each scene
// (its id on the hub), has its Accessory Settings in `_accessories`, Excluded among them; there are no Plugin Accessory
// Settings. A hub's scenes stay switches on one accessory, `Dirigera:scenes:<host>`, whose id never changes: an Excluded
// scene has no switch there. The Homebridge-shaped `excludeDevices` and `excludeScenes` (names or ids) and a hub's
// `token` still load; `canonicalSettings` moves them.
extension DirigeraPlugin {
    /// A device's Device Kind as the schema and the editor name it.
    static func kind(of kind: DirigeraDevice.Kind) -> String {
        switch kind {
        case .light: "light"
        case .outlet: "outlet"
        case .contact, .motion, .lightSensor, .environment, .leak: "sensor"
        case .blinds: "blinds"
        case .airPurifier: "airPurifier"
        case .controller: "controller"
        }
    }

    static let sceneKind = "scene"

    public func deviceKind(of deviceID: String) async -> String? {
        for hub in hubs.values {
            if hub.scenes.contains(where: { $0.id == deviceID }) { return Self.sceneKind }
            if let device = hub.devices[deviceID], device.isStandalone { return Self.kind(of: device.kind) }
            if let group = Self.groups(of: hub.devices.values).first(where: { $0.id == deviceID }) { return Self.kind(of: group.devices[0].kind) }
        }
        return nil
    }

    /// Left out by `excludeScenes`, by name or id.
    func excludedBySettings(_ scene: DirigeraScene) -> Bool {
        excludedScenes.contains(scene.name.lowercased()) || excludedScenes.contains(scene.id.lowercased())
    }

    /// The block in its canonical shape, from what the hubs gave at their last read: `excludeDevices` and `excludeScenes`
    /// as Excluded devices and scenes (a part's name or id excludes its product), the Excluded scenes accessory of a hub
    /// (`scenes:<host>`, before each scene was a device of its own) as each of its scenes Excluded, and each hub's
    /// `token` dropped once the vault holds the hub's: one only config.json holds moves there once the block is written
    /// (`whenSettingsWritten`), the block answered as if it had.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        // The block may only name a token (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        stored = store.load() ?? stored
        var moving: [String: String] = [:]
        for hub in configuration.hubs ?? [] {
            let host = hub.host.trimmingCharacters(in: .whitespaces)
            if stored[host]?.token == nil, let token = hub.token?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
                moving[host] = token
            }
        }
        if !moving.isEmpty {
            let store = store, moving = moving
            await context.whenSettingsWritten { [weak self] in
                // What the vault has by then (a fingerprint the trust saved, a token Setup kept) is kept.
                var hubs = store.load() ?? [:]
                for (host, token) in moving where hubs[host]?.token == nil { hubs[host, default: StoredHub()].token = token }
                try store.save(hubs)
                await self?.reloadStored()
            }
        }
        let known = hubs.mapValues { (devices: Array($0.devices.values), scenes: $0.scenes) }
        let vaultHas = Set(stored.filter { $0.value.token != nil }.keys).union(moving.keys)
        return Self.canonical(block, hubs: known, vaultHas: vaultHas)
    }

    /// The hubs as the vault keeps them now.
    func reloadStored() {
        stored = store.load() ?? stored
    }

    /// `hubs`: each hub's devices and scenes by host; `vaultHas`: the hosts whose token the vault keeps.
    static func canonical(
        _ block: JSONValue, hubs: [String: (devices: [DirigeraDevice], scenes: [DirigeraScene])], vaultHas: Set<String>
    ) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        func exclude(_ id: String) {
            var entry = entries[id]?.objectValue ?? [:]
            if entry["excluded"] == nil { entry["excluded"] = true }
            entries[id] = .object(entry)
        }
        let devices = hubs.values.flatMap(\.devices)
        let scenes = hubs.values.flatMap(\.scenes)
        if !devices.isEmpty, let list = fields["excludeDevices"]?.arrayValue {
            let groups = groups(of: devices)
            var left: [JSONValue] = []
            for value in list {
                let name = value.stringValue?.lowercased() ?? ""
                func matches(_ device: DirigeraDevice) -> Bool { device.name.lowercased() == name || device.id.lowercased() == name }
                var found = Set(devices.filter { $0.isStandalone && matches($0) }.map(\.id))
                for group in groups where group.id.lowercased() == name || group.devices.contains(where: matches) { found.insert(group.id) }
                if found.isEmpty { left.append(value) } else { found.forEach(exclude) }
            }
            if left.isEmpty { fields.removeValue(forKey: "excludeDevices") } else { fields["excludeDevices"] = .array(left) }
        }
        if !scenes.isEmpty, let list = fields["excludeScenes"]?.arrayValue {
            var left: [JSONValue] = []
            for value in list {
                let name = value.stringValue?.lowercased() ?? ""
                let found = scenes.filter { $0.name.lowercased() == name || $0.id.lowercased() == name }
                if found.isEmpty { left.append(value) } else { found.map(\.id).forEach(exclude) }
            }
            if left.isEmpty { fields.removeValue(forKey: "excludeScenes") } else { fields["excludeScenes"] = .array(left) }
        }
        // A hub's whole scenes accessory Excluded: each of its scenes is, and the accessory keeps its other settings.
        for (host, hub) in hubs where hub.scenes.contains(where: \.isRunnable) {
            let key = "scenes:\(host)"
            guard var entry = entries[key]?.objectValue, entry["excluded"]?.boolValue == true else { continue }
            hub.scenes.filter(\.isRunnable).map(\.id).forEach(exclude)
            entry.removeValue(forKey: "excluded")
            if entry.isEmpty { entries.removeValue(forKey: key) } else { entries[key] = .object(entry) }
        }
        if let list = fields["hubs"]?.arrayValue {
            fields["hubs"] = .array(list.map { item in
                guard var hub = item.objectValue, hub["token"] != nil, let host = hub["host"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                      vaultHas.contains(host) else { return item }
                hub.removeValue(forKey: "token")
                return .object(hub)
            })
        }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
