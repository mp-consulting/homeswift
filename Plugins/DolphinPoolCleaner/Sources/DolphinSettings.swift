import Foundation
import Homeswift
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `iotRegion` and `pollingInterval`; each robot's
// Accessory Settings sit in `_accessories` by its serial number (its Device Id): its Name, and its Plugin Accessory
// Settings `cleaningMode`, `enableTemperature` and `enableFilterStatus`. The account's credentials (the email and the
// refresh token Setup gives, or a Homebridge block's password) are in the vault. The Homebridge plugin's `devices` list,
// and its `email`, `password` and `refreshToken`, still load and are read where the canonical places say nothing;
// `canonicalSettings` moves them.
extension DolphinPoolCleanerPlugin {
    /// Every robot is a pool robot: the one Device Kind.
    static let robotKind = "robot"

    public func deviceKind(of deviceID: String) async -> String? { Self.robotKind }

    /// A robot's settings: its Accessory Settings, then its entry in the Homebridge-shaped `devices`, key by key. Its
    /// Name is not here: it applies without the plugin, which reads only a Homebridge entry's `name`.
    func robotSettings(serialNumber: String) -> Configuration.Device? {
        let own = context.accessorySettings(for: serialNumber).decode(Configuration.Device.self)
        let legacy = configuration.device(serialNumber: serialNumber)
        guard own != nil || legacy != nil else { return nil }
        return Configuration.Device(
            serialNumber: serialNumber, name: legacy?.name,
            cleaningMode: own?.cleaningMode.nonEmpty ?? legacy?.cleaningMode,
            enableTemperature: own?.enableTemperature ?? legacy?.enableTemperature,
            enableFilterStatus: own?.enableFilterStatus ?? legacy?.enableFilterStatus)
    }

    /// The account's sign-in, from one read of the vault: the email, password and refresh token Setup (or
    /// `canonicalSettings`) kept there, else a Homebridge block's.
    func accountSettings() -> AccountSettings {
        let held = context.credentials()
        func kept(_ key: String) -> String? { held?[key]?.stringValue.nonEmpty }
        return AccountSettings(
            email: kept("email") ?? configuration.email.nonEmpty, password: kept("password") ?? configuration.password.nonEmpty,
            refreshToken: kept("refreshToken") ?? configuration.refreshToken, iotRegion: configuration.iotRegion)
    }

    /// The account's email: the one Setup kept in the vault, else a Homebridge block's.
    var accountEmail: String? { accountSettings().email }

    /// The account's keys of a block and the vault's fields they go in.
    static let credentialKeys = ["email", "password", "refreshToken"]

    /// The block in its canonical shape (`canonical`), its account's keys (`email`, `password`, `refreshToken`) moved into
    /// the vault once the block is written (`whenSettingsWritten`), where the vault has none of its own: a refresh token
    /// Setup kept stays, and with it the block's password goes unused.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block)
        guard var fields = canonical.objectValue, Self.credentialKeys.contains(where: { fields[$0] != nil }) else { return canonical }
        // The block may only name a secret (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        let resolved = ["email": configuration.email, "password": configuration.password, "refreshToken": configuration.refreshToken]
        let held = context.credentials()?.objectValue ?? [:]
        var moved = held
        for key in Self.credentialKeys where held[key]?.stringValue.nonEmpty == nil && fields[key] != nil {
            if let value = resolved[key].flatMap({ $0 }).nonEmpty { moved[key] = .string(value) }
        }
        if moved != held {
            let context = context, credentials = JSONValue.object(moved)
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        for key in Self.credentialKeys where moved[key]?.stringValue.nonEmpty != nil { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    /// The Plugin Accessory Settings of a robot, as `accessorySchema` declares them.
    static let robotKeys = ["cleaningMode", "enableTemperature", "enableFilterStatus"]

    /// The block with `devices` moved into `_accessories` by serial number: `name` as the Name, `cleaningMode` (`regular`
    /// as `all`), `enableTemperature` and `enableFilterStatus` as they are (booleans and numbers written as strings read as
    /// Homebridge reads them), `deviceType` and `robotImageUrl` (the wizard's, for display) dropped. What `_accessories`
    /// has already stays; an entry without a serial number stays in `devices`. The account's keys (`email`, `password`,
    /// `refreshToken`) are `canonicalSettings`'s.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, let devices = fields["devices"]?.arrayValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        var left: [JSONValue] = []
        for item in devices {
            guard let device = try? JSONDecoder().decode(Configuration.Device.self, from: item.encoded()),
                  let serial = device.serialNumber?.trimmingCharacters(in: .whitespaces), !serial.isEmpty else {
                left.append(item)
                continue
            }
            var entry = entries[serial]?.objectValue ?? [:]
            if let name = device.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, entry["name"] == nil { entry["name"] = .string(name) }
            if let mode = device.cleaningMode.nonEmpty, entry["cleaningMode"] == nil { entry["cleaningMode"] = .string(mode == "regular" ? "all" : mode) }
            if let on = device.enableTemperature, entry["enableTemperature"] == nil { entry["enableTemperature"] = .bool(on) }
            if let on = device.enableFilterStatus, entry["enableFilterStatus"] == nil { entry["enableFilterStatus"] = .bool(on) }
            if !entry.isEmpty { entries[serial] = .object(entry) }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
