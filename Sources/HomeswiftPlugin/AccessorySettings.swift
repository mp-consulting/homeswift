import Foundation
import HomeswiftAI

/// What a person sets for one device of a plugin instance (GLOSSARY.md, "Accessory Settings"), kept in the block's
/// `_accessories` by Device Id (docs/adr/0001-canonical-accessory-settings.md):
///
/// ```json
/// { "platform": "PhilipsHue", "_accessories": { "00:17:88:01:02:03:04:05-0b": { "excluded": true }, "abc": { "offset": 1.5 } } }
/// ```
///
/// `excluded` and `name` are the Core Accessory Settings; the other keys are the plugin's own (Plugin Accessory
/// Settings), which it declares in its config.schema.json and reads with `decode`.
public struct AccessorySettings: Sendable, Equatable {
    /// Excluded: the device is never made into an accessory.
    public var excluded: Bool
    /// The name the person gave it, in place of the device's own.
    public var name: String?
    /// The plugin's own settings for it.
    public var plugin: [String: JSONValue]

    public static let coreKeys: Set<String> = ["excluded", "name"]

    public init(excluded: Bool = false, name: String? = nil, plugin: [String: JSONValue] = [:]) {
        self.excluded = excluded
        self.name = name
        self.plugin = plugin
    }

    public init(json: JSONValue) {
        let fields = json.objectValue ?? [:]
        excluded = fields["excluded"]?.boolValue ?? false
        name = fields["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        plugin = fields.filter { !Self.coreKeys.contains($0.key) }
    }

    public var json: JSONValue {
        var fields = plugin
        if excluded { fields["excluded"] = true }
        if let name { fields["name"] = .string(name) }
        return .object(fields)
    }

    /// The plugin's settings as its own type; nil when they do not decode.
    public func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        guard let data = try? JSONValue.object(plugin).encoded() else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A block's `_accessories`, by Device Id; entries that are not objects are left out.
    public static func all(in block: JSONValue) -> [String: AccessorySettings] {
        var settings: [String: AccessorySettings] = [:]
        for (deviceID, value) in block["_accessories"]?.objectValue ?? [:] where value.objectValue != nil {
            settings[deviceID] = AccessorySettings(json: value)
        }
        return settings
    }
}

extension PluginContext {
    /// The Accessory Settings of one device, as the plugin was launched; a device with none has the defaults. A change
    /// reloads the plugin.
    public func accessorySettings(for deviceID: String) -> AccessorySettings {
        accessorySettingsBox.withLockedValue { $0[deviceID] } ?? AccessorySettings()
    }

    /// Every device with Accessory Settings, by Device Id.
    public var allAccessorySettings: [String: AccessorySettings] { accessorySettingsBox.withLockedValue { $0 } }

    /// Whether the device is Excluded: the plugin should not poll it, and the runtime never adds its accessories.
    public func isExcluded(_ deviceID: String) -> Bool {
        accessorySettingsBox.withLockedValue { $0[deviceID]?.excluded } ?? false
    }

    /// The Device Ids of the Excluded devices.
    public var excludedDeviceIDs: Set<String> {
        Set(accessorySettingsBox.withLockedValue { $0.filter(\.value.excluded).keys })
    }

    /// The device an accessory id belongs to among those with Accessory Settings: `<platform>:<deviceID>`, or one of the
    /// device's accessories `<platform>:<deviceID>:<more>`. nil for an id of another form or a device with none.
    public func deviceID(ofAccessory id: String) -> String? {
        let prefix = "\(platform):"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        return accessorySettingsBox.withLockedValue { settings in
            if settings[String(rest)] != nil { return String(rest) }
            // The longest Device Id the rest starts with, a colon after it: Device Ids may hold colons (a MAC).
            return settings.keys.filter { rest.hasPrefix("\($0):") }.max { $0.count < $1.count }
        }
    }

    /// The accessory id of a device: `<platform>:<deviceID>`.
    public func accessoryID(of deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// What an Authorization gave for the account (no `deviceID`) or a device, from the vault; nil when there is none.
    /// Their being there is what Setup reads as Authorized: keep none for an account or a device not authorized yet.
    /// `legacyFile`, a file of the plugin's storage directory it kept them in before, moves into the vault when read.
    public func credentials(for deviceID: String? = nil, legacyFile: String? = nil) -> JSONValue? {
        credentialsFile(for: deviceID, legacyFile: legacyFile).load()
    }

    /// The credentials as the plugin's own type.
    public func credentials<T: Decodable>(for deviceID: String? = nil, as type: T.Type, legacyFile: String? = nil) -> T? {
        guard let json = credentials(for: deviceID, legacyFile: legacyFile), let data = try? json.encoded() else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Replaces them: a refreshed token. The bridge saves an Authorization's own when it is done.
    public func saveCredentials(_ credentials: JSONValue, for deviceID: String? = nil) throws {
        try credentialsFile(for: deviceID).save(credentials)
    }

    public func saveCredentials<T: Encodable>(_ credentials: T, for deviceID: String? = nil) throws {
        try saveCredentials(JSONValue(data: JSONEncoder().encode(credentials)), for: deviceID)
    }

    /// Drops them: the device or the account Needs Authorization again.
    public func removeCredentials(for deviceID: String? = nil) {
        credentialsFile(for: deviceID).remove()
    }

    /// `plugin.<instance>.account`, or `plugin.<instance>.device-<deviceID>`.
    func credentialsFile(for deviceID: String?, legacyFile: String? = nil) -> SecretFile<JSONValue> {
        let file = deviceID.map { "device-\($0)" } ?? "account"
        return SecretFile(
            vault: CredentialVault(storage: vaultStorage), entryName: SecretFile<JSONValue>.entryName(instance: key, file: file),
            owner: "\(platform)/\(name)", legacyFile: legacyFile.map(storageFile))
    }
}
