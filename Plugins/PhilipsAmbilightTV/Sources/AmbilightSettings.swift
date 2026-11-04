import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the one Plugin Setting besides the block's name is `devices`, the TVs Setup
// finds by address (a name, an `ip`, maybe a `mac`) where Bonjour does not reach them. Each TV paired is a device of the
// Device Kind `tv` whose Accessory Settings sit in `_accessories` by its MAC (its Device Id): its Name, Excluded, its
// address and its options (`pollingInterval`, the remote's keys, `inputs`, `customApps`, `customButtons`,
// `stateSensors`, `sources`…, the Homebridge plugin's names), declared in the schema's `accessorySchema`. Its keys
// (`username`, `password`, `certFingerprint`) are in the vault under its MAC. A Homebridge block, whose `devices` hold
// the paired TVs with their keys and options, still loads, read where the canonical places say nothing;
// `canonicalSettings` moves it. The accessory and its server keep their id, `PhilipsAmbilightTV:<MAC>`.
extension PhilipsAmbilightTVPlugin {
    /// Every device is a TV.
    static let tvKind = "tv"

    public func deviceKind(of deviceID: String) async -> String? { Self.tvKind }

    /// A TV's Plugin Accessory Settings, as `accessorySchema` declares them: an entry of `devices`' options, by the same
    /// names.
    static let accessoryKeys = [
        "ip", "pollingInterval", "wakeOnLanEnabled", "ambilightMode", "ambilightOnStart", "infoButtonKey", "backButtonKey", "playPauseButtonKey",
        "inputs", "sourceSwitches", "ambilightHueSwitch", "customApps", "customButtons", "stateSensors", "sources",
    ]

    /// `entry` with a TV's Accessory Settings over it, key by key, and its Name; the entry as it was when they do not
    /// decode.
    static func overlay(_ settings: AccessorySettings, on entry: Configuration.Device) -> Configuration.Device {
        var fields = (try? JSONValue(encoding: entry).objectValue) ?? [:]
        for key in accessoryKeys { if let value = settings.plugin[key], !value.isNull { fields[key] = value } }
        if let name = settings.name { fields["name"] = .string(name) }
        return (try? JSONValue.object(fields).decode(Configuration.Device.self)) ?? entry
    }

    /// The block in its canonical shape (`canonical`), each moved TV's keys kept in the vault under its MAC once the
    /// block is written (`whenSettingsWritten`), where the vault has none of its own.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        // The block may only name a secret (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        let resolved = Dictionary((configuration.devices ?? []).compactMap { entry -> (String, TVCredentials)? in
            guard let mac = entry.mac.flatMap(MACAddress.canonical), let username = entry.username?.nonEmpty, let password = entry.password?.nonEmpty else { return nil }
            return (mac, TVCredentials(username: username, password: password, certFingerprint: entry.certFingerprint?.nonEmpty))
        }) { first, _ in first }
        // The TVs the vault has keys for, from one look at it that does not count as a use.
        var candidates = Set((block["_accessories"]?.objectValue ?? [:]).keys.compactMap(MACAddress.canonical))
        for entry in block["devices"]?.arrayValue ?? [] { if let mac = entry["mac"]?.stringValue.flatMap(MACAddress.canonical) { candidates.insert(mac) } }
        let paired = Set(context.haveCredentials(candidates.sorted()).compactMap { $0 })
        let (canonical, keys) = Self.canonical(block, hasKeys: { paired.contains($0) }) { mac, written in
            resolved[mac] ?? (Self.isReference(written.username) || Self.isReference(written.password) ? nil : written)
        }
        if !keys.isEmpty {
            let context = context
            await context.whenSettingsWritten {
                for (mac, credentials) in keys.sorted(by: { $0.key < $1.key }) { try context.saveCredentials(credentials, for: mac) }
            }
        }
        return canonical
    }

    /// A value the runtime resolves rather than a secret itself.
    static func isReference(_ value: String) -> Bool {
        ["vault:", "enc:", "env:", "file:"].contains { value.hasPrefix($0) }
    }

    /// The block with the paired TVs of `devices` moved into `_accessories` by MAC (uppercase, colon-separated, as their
    /// accessories' ids): `name` as the Name, the options (`accessoryKeys`) as they are, the keys answered to be kept in the
    /// vault, as `credentials` reads them, where `hasKeys` says the vault has none. A TV is paired when its entry has keys
    /// or the vault has its MAC's; an entry with only an address that Setup paired since (an `_accessories` entry of a
    /// paired TV has its `ip`) goes into that TV's. What `_accessories` has already stays. The others stay in `devices`:
    /// TVs to pair, by address, and entries whose MAC is not one or whose keys `credentials` cannot read.
    static func canonical(
        _ block: JSONValue, hasKeys: (String) -> Bool, credentials: (_ mac: String, _ written: TVCredentials) -> TVCredentials?
    ) -> (block: JSONValue, keys: [String: TVCredentials]) {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return (block, [:]) }
        var accessories = fields["_accessories"]?.objectValue ?? [:]
        // The paired TVs' addresses, to find an address-only entry's TV.
        var pairedAt: [String: String] = [:]
        for (mac, settings) in accessories where hasKeys(mac) {
            if let ip = settings["ip"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty { pairedAt[ip] = mac }
        }
        var left: [JSONValue] = []
        var keys: [String: TVCredentials] = [:]
        for item in list {
            guard let entry = item.objectValue else {
                left.append(item)
                continue
            }
            let text = { (key: String) in entry[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
            let written = text("username").flatMap { username in
                text("password").map { TVCredentials(username: username, password: $0, certFingerprint: text("certFingerprint")) }
            }
            let mac: String
            if let given = text("mac") {
                guard let canonical = MACAddress.canonical(given) else {
                    left.append(item)
                    continue
                }
                mac = canonical
            } else if written == nil, let ip = text("ip"), let found = pairedAt[ip] {
                mac = found
            } else {
                left.append(item)
                continue
            }
            if !hasKeys(mac) {
                guard let written, let readable = credentials(mac, written) else {
                    // A TV to pair, or keys that cannot be read: as it is.
                    left.append(item)
                    continue
                }
                keys[mac] = readable
            }
            let key = accessories.keys.first { MACAddress.canonical($0) == mac } ?? mac
            var settings = accessories[key]?.objectValue ?? [:]
            for name in accessoryKeys { if let value = entry[name], !value.isNull, settings[name] == nil { settings[name] = value } }
            if let name = text("name"), settings["name"] == nil { settings["name"] = .string(name) }
            accessories[key] = .object(settings)
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        if !accessories.isEmpty { fields["_accessories"] = .object(accessories) }
        return (.object(fields), keys)
    }
}
