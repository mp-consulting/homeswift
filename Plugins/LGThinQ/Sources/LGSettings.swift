import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (`auth_mode`, `country`, `language`,
// `thinq1`, `refresh_interval`); each appliance's Accessory Settings sit in `_accessories` by LG's device id (its Device
// Id): its Name, Excluded, and its Plugin Accessory Settings, which the schema's `accessorySchema` declares by Device
// Kind (LG's type name: `AC`, `WASHER`, `REFRIGERATOR`…). The account's refresh token (and its email) are Setup's, in
// the vault. The Homebridge plugin's `devices` list (an allow list: an appliance it leaves out is not added) and its
// `username`, `password` and `refresh_token` still load, read where the canonical places say nothing;
// `canonicalSettings` moves them.
extension LGThinQPlugin {
    /// The Plugin Accessory Settings, as `accessorySchema` declares them: every type's options and `serial_number`.
    static let accessoryKeys: Set<String> = Set(DeviceRegistry.descriptors.values.flatMap(\.defaults.keys)).union(["serial_number"])

    /// The options that are modes or units, written in upper case (`DeviceSettings.mode`).
    static let upperCaseKeys: Set<String> = ["ac_mode", "ac_swing_mode", "ac_temperature_unit"]

    /// An appliance's options: its Accessory Settings over its Homebridge entry's (`devices`), key by key.
    static func deviceOptions(legacy: [String: JSONValue]?, own: [String: JSONValue]) -> [String: JSONValue] {
        (legacy ?? [:]).merging(own.filter { accessoryKeys.contains($0.key) && !$0.value.isNull }) { $1 }
    }

    /// LG's type name of the appliance (`AC`, `WASHER`, `DISHWASHER`…): from the running platform, else its Homebridge
    /// entry's `type`.
    public func deviceKind(of deviceID: String) async -> String? {
        if let type = await platformInstance?.type(of: deviceID) { return type }
        return configuration.devices?.first { $0.id == deviceID }?.raw["type"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The account's keys of a block, which the vault holds once Setup or `canonicalSettings` moved them.
    static let accountKeys = ["username", "password", "refresh_token"]

    /// The block in its canonical shape (`canonical`, with the appliances the running platform knows), the account's
    /// keys moved into the vault once the block is written (`whenSettingsWritten`): with a refresh token to keep (the
    /// vault's, the block's, or the one a password sign-in got), `username`, `password` and `refresh_token` go. A block
    /// whose password has not signed in yet keeps them.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block, devices: await platformInstance?.knownDevices)
        guard var fields = canonical.objectValue, Self.accountKeys.contains(where: { fields[$0] != nil }) else { return canonical }
        let stored = context.credentials(as: StoredToken.self)
        // The block may only name a secret (a `vault:` reference, a sealed copy): the running configuration has it
        // resolved, the vault's token in place of the block's (`withStoredToken`).
        var token = stored?.refreshToken.nonEmpty ?? configuration.refresh_token?.nonEmpty
        if token == nil { token = await platformInstance?.signedInRefreshToken }
        guard let token else { return canonical }
        let login = StoredToken(refreshToken: token, username: stored?.username?.nonEmpty ?? configuration.username?.nonEmpty)
        if login != stored {
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(login) }
        }
        for key in Self.accountKeys { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    /// The block with `devices` moved into `_accessories` by device id: each entry's options (`accessoryKeys`, booleans
    /// read as the plugin reads them, modes in upper case, `ac_buttons` without unnamed ones), its `name` as the Name
    /// where it is not LG's own, `type` dropped (the Device Kind is LG's). The list was an allow list: with entries,
    /// every appliance of `devices` (the account's, as LG last listed them whole) it leaves out becomes Excluded. What
    /// `_accessories` has already stays. Without `devices` known, a list with entries stays as it is; an empty one goes.
    static func canonical(_ block: JSONValue, devices known: [KnownDevice]?) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["devices"] else { return block }
        let entries = list.arrayValue ?? []
        guard !entries.isEmpty else {
            fields.removeValue(forKey: "devices")
            return .object(fields)
        }
        guard let known else { return block }
        let names = Dictionary(known.map { ($0.id, $0.name) }) { first, _ in first }
        var accessories = fields["_accessories"]?.objectValue ?? [:]
        var listed = Set<String>()
        for item in entries {
            // An entry without an id matched no appliance: it goes with the list.
            guard let device = item.objectValue, let raw = device["id"], !raw.isNull, case let id = JS.string(raw), !id.isEmpty else { continue }
            listed.insert(id)
            var entry = accessories[id]?.objectValue ?? [:]
            for (key, value) in Self.options(of: device) where entry[key] == nil { entry[key] = value }
            if let name = device["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != names[id], entry["name"] == nil {
                entry["name"] = .string(name)
            }
            if !entry.isEmpty { accessories[id] = .object(entry) }
        }
        for device in known where device.supported && !listed.contains(device.id) {
            var entry = accessories[device.id]?.objectValue ?? [:]
            if entry["excluded"] == nil { entry["excluded"] = true }
            accessories[device.id] = .object(entry)
        }
        fields.removeValue(forKey: "devices")
        if !accessories.isEmpty { fields["_accessories"] = .object(accessories) }
        return .object(fields)
    }

    /// A Homebridge entry's options as Plugin Accessory Settings, typed.
    static func options(of device: [String: JSONValue]) -> [String: JSONValue] {
        let read = DeviceSettings(values: device)
        var options: [String: JSONValue] = [:]
        for key in accessoryKeys {
            guard let value = device[key], !value.isNull else { continue }
            switch key {
            case "serial_number":
                if let serial = read.serialNumber { options[key] = .string(serial) }
            case "ac_buttons":
                let buttons = read.acButtons.map { JSONValue.object(["name": .string($0.name), "op_mode": .number(Double($0.opMode))]) }
                if !buttons.isEmpty { options[key] = .array(buttons) }
            case _ where upperCaseKeys.contains(key):
                if let mode = read.mode(key), !mode.isEmpty { options[key] = .string(mode) }
            default:
                options[key] = .bool(read.flag(key))
            }
        }
        return options
    }
}

/// An appliance of the account as LG last listed it: its id, LG's name and type, and whether Homeswift has an
/// accessory for it.
struct KnownDevice: Sendable, Equatable {
    var id: String
    var name: String
    var type: String
    var supported: Bool
}
