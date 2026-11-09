import Foundation
import HomeswiftAI
import Logging

/// What a person sets for one device of a plugin instance (GLOSSARY.md, "Accessory Settings"), kept in the block's
/// `_accessories` by Device Id (docs/adr/0001-canonical-accessory-settings.md):
///
/// ```json
/// { "platform": "PhilipsHue", "_accessories": { "00:17:88:01:02:03:04:05-0b": { "excluded": true }, "abc": { "offset": 1.5 } } }
/// ```
///
/// `name`, `room`, `hidden`, `notInHome`, `excluded`, `parts` and `energyRoles` are the Core Accessory Settings
/// (docs/adr/0003-room-and-visibility-in-accessory-settings.md); the other keys are the plugin's own (Plugin Accessory
/// Settings), which it declares in its config.schema.json's `accessorySchema` and reads with `decode`. `name`, `room`,
/// `hidden`, `notInHome` and `energyRoles` apply live: they leave the plugin's JSON (`HomeswiftConfiguration.decode` takes them out of its
/// block), so a change to them never reloads it; its context's Accessory Settings have their current values.
///
/// A device's own accessory is keyed by its Device Id; another accessory of the device by its Accessory Id without the
/// platform (`<deviceID>:<more>`), so each of them has its own Name, room, Hidden and Not in Home.
public struct AccessorySettings: Sendable, Equatable {
    /// Excluded: the device is never made into an accessory.
    public var excluded: Bool
    /// The name the person gave it, in place of the device's own.
    public var name: String?
    /// Its Room; empty for none, even when the controller it mirrors suggests one (`Accessory.suggestedRoom`).
    public var room: String?
    /// Hidden: published to HomeKit, but left off the web UI's wall.
    public var hidden: Bool
    /// Not in Home: on the bridge and the wall, but left out of Apple Home.
    public var notInHome: Bool
    /// The parts a person included or left out (`DevicePart`), by the plugin's id: `{ "SideDoor": false }`.
    public var parts: [String: Bool]
    /// The plugin's own settings for it.
    public var plugin: [String: JSONValue]
    /// The Energy Role a person gave each of its Meters, by the Meter's key: a role, or none (`.some(nil)`) where its
    /// plugin suggested one. A Meter left out has its plugin's suggestion (docs/adr/0004-meters-and-consumption-history.md).
    public var energyRoles: [String: EnergyRole?]
    /// Separate Functions: each of its Functions an accessory of its own (`Separation`), applied by the runtime.
    public var separateFunctions: Bool

    /// A Remote's Controls (`RemoteControl`), run by the bridge.
    public var controls: [RemoteControl] = []
    /// Natural Light (`PowerOn.swift`): a light that can have it does, unless a person gave it one of its device's own
    /// Power On (false).
    public var naturalLight = true

    public static let coreKeys: Set<String> = ["excluded", "name", "room", "hidden", "notInHome", "parts", "energyRoles", "separateFunctions", "controls", "naturalLight"]
    /// The Core Accessory Settings that apply without reloading the plugin: they never reach it.
    public static let liveKeys: Set<String> = ["name", "room", "hidden", "notInHome", "energyRoles", "separateFunctions", "controls", "naturalLight"]
    /// What `energyRoles` holds for a Meter: a power role's name, or `none`.
    public static let energyRoleChoices = ["solar", "home", "grid", "battery", "none"]

    /// `energyRoles` as config.json has it: `{ "<meter>": "grid" | "none" }`, anything else left out.
    public static func energyRoles(from json: JSONValue?) -> [String: EnergyRole?] {
        var roles: [String: EnergyRole?] = [:]
        for (meter, value) in json?.objectValue ?? [:] {
            guard let text = value.stringValue else { continue }
            if text == "none" { roles[meter] = .some(nil) } else if let role = EnergyRole(rawValue: text), role.isPower { roles[meter] = role }
        }
        return roles
    }

    public init(
        excluded: Bool = false, name: String? = nil, parts: [String: Bool] = [:], plugin: [String: JSONValue] = [:],
        room: String? = nil, hidden: Bool = false, notInHome: Bool = false, energyRoles: [String: EnergyRole?] = [:],
        separateFunctions: Bool = false
    ) {
        self.energyRoles = energyRoles
        self.separateFunctions = separateFunctions
        self.excluded = excluded
        self.name = name
        self.room = room
        self.hidden = hidden
        self.notInHome = notInHome
        self.parts = parts
        self.plugin = plugin
    }

    public init(json: JSONValue) {
        let fields = json.objectValue ?? [:]
        excluded = fields["excluded"]?.boolValue ?? false
        name = fields["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        room = fields["room"]?.stringValue
        hidden = fields["hidden"]?.boolValue ?? false
        notInHome = fields["notInHome"]?.boolValue ?? false
        parts = (fields["parts"]?.objectValue ?? [:]).compactMapValues(\.boolValue)
        energyRoles = Self.energyRoles(from: fields["energyRoles"])
        separateFunctions = fields["separateFunctions"]?.boolValue ?? false
        controls = RemoteControl.readable(from: fields["controls"])
        naturalLight = fields["naturalLight"]?.boolValue ?? true
        plugin = fields.filter { !Self.coreKeys.contains($0.key) }
    }

    public var json: JSONValue {
        var fields = plugin
        if excluded { fields["excluded"] = true }
        if let name { fields["name"] = .string(name) }
        if let room { fields["room"] = .string(room) }
        if hidden { fields["hidden"] = true }
        if notInHome { fields["notInHome"] = true }
        if !parts.isEmpty { fields["parts"] = .object(parts.mapValues(JSONValue.bool)) }
        if !energyRoles.isEmpty { fields["energyRoles"] = .object(energyRoles.mapValues { .string($0?.rawValue ?? "none") }) }
        if separateFunctions { fields["separateFunctions"] = true }
        if !controls.isEmpty { fields["controls"] = RemoteControl.json(controls) }
        if !naturalLight { fields["naturalLight"] = false }
        return .object(fields)
    }

    /// The plugin's settings as its own type; nil when they do not decode.
    public func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        try? JSONValue.object(plugin).decode(T.self)
    }

    /// An entry of the plugin's own configuration type for the device: its plugin settings, its name under `name`, and
    /// `fields` on top (its Device Id under the plugin's key, what its credentials hold). nil when it does not decode.
    public func decode<T: Decodable>(_ type: T.Type, adding fields: [String: JSONValue]) -> T? {
        var all = plugin
        if let name { all["name"] = .string(name) }
        all.merge(fields) { $1 }
        return try? JSONValue.object(all).decode(T.self)
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

    /// Whether the accessory `id` belongs to an Excluded device (`deviceID(ofAccessory:)`), with one look at the settings and
    /// none when no device is Excluded: the runtime asks on every `add`.
    public func isExcluded(accessoryID id: String) -> Bool {
        let prefix = "\(platform):"
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        let own = ownDeviceID?(String(rest))
        return accessorySettingsBox.withLockedValue { settings in
            settings.contains { $0.value.excluded && ($0.key == own || Self.isChild(rest, of: $0.key)) }
        }
    }

    /// The Device Ids of the Excluded devices.
    public var excludedDeviceIDs: Set<String> {
        Set(accessorySettingsBox.withLockedValue { $0.filter(\.value.excluded).keys })
    }

    /// The device an accessory id belongs to among those with Accessory Settings: `<platform>:<deviceID>`, or one of the
    /// device's accessories `<platform>:<deviceID>:<more>` or `<platform>:<deviceID>.<more>`. nil for an id of another
    /// form or a device with none. A plugin whose accessories take other forms names their device itself
    /// (`HomeswiftPlugin.deviceID(ofAccessory:)`).
    public func deviceID(ofAccessory id: String) -> String? {
        let prefix = "\(platform):"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        let own = ownDeviceID?(String(rest))
        return accessorySettingsBox.withLockedValue { settings in
            if settings[String(rest)] != nil { return String(rest) }
            if let own, settings[own] != nil { return own }
            // The longest Device Id the rest starts with, a colon or a dot after it: Device Ids may hold colons (a MAC).
            return settings.keys.filter { Self.isChild(rest, of: $0) }.max { $0.count < $1.count }
        }
    }

    /// Whether an accessory id's part after `<platform>:` is a device's own accessory or one of its others.
    static func isChild(_ rest: Substring, of deviceID: String) -> Bool {
        rest == deviceID || rest.hasPrefix("\(deviceID):") || rest.hasPrefix("\(deviceID).")
    }

    /// Whether `id` is the accessory of the device `deviceID`, or one of its others (`deviceID(ofAccessory:)`'s forms).
    public func isAccessory(_ id: String, of deviceID: String) -> Bool {
        let prefix = "\(platform):"
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        return Self.isChild(rest, of: deviceID) || ownDeviceID?(String(rest)) == deviceID
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
        try? credentials(for: deviceID, legacyFile: legacyFile)?.decode(T.self)
    }

    /// Which of these devices (nil for the account) have credentials, from one read of the vault that does not count as
    /// a use: what Setup shows as Authorized.
    public func haveCredentials(_ deviceIDs: [String?]) -> Set<String?> {
        // The names only: nothing is opened.
        let names = Set((try? CredentialVault(storage: vaultStorage).names()) ?? [])
        return Set(deviceIDs.filter { names.contains(credentialsFile(for: $0).entryName) })
    }

    /// The devices set up through Setup: those with Accessory Settings and credentials in the vault, by Device Id, Excluded
    /// ones left out. A plugin that runs them beside a Homebridge-shaped list (`devices`) makes its entries from these
    /// (`AccessorySettings.decode(_:adding:)`).
    public func setUpDevices<Credentials: Decodable>(credentials type: Credentials.Type) -> [(deviceID: String, settings: AccessorySettings, credentials: Credentials)] {
        let candidates = allAccessorySettings.filter { !$0.value.excluded }.sorted { $0.key < $1.key }
        let authorized = haveCredentials(candidates.map(\.key))
        return candidates.compactMap { deviceID, settings in
            guard authorized.contains(deviceID), let credentials = credentials(for: deviceID, as: Credentials.self) else { return nil }
            return (deviceID, settings, credentials)
        }
    }

    /// Replaces them: a refreshed token. The bridge saves an Authorization's own when it is done.
    public func saveCredentials(_ credentials: JSONValue, for deviceID: String? = nil) throws {
        try credentialsFile(for: deviceID).save(credentials)
        // New credentials for the account have not been refused yet.
        if deviceID == nil { accountAccepted() }
    }

    public func saveCredentials<T: Encodable>(_ credentials: T, for deviceID: String? = nil) throws {
        try saveCredentials(JSONValue(encoding: credentials), for: deviceID)
    }

    /// Drops them: the device or the account Needs Authorization again.
    public func removeCredentials(for deviceID: String? = nil) {
        credentialsFile(for: deviceID).remove()
        // Gone, they are not set up rather than refused.
        if deviceID == nil { accountAccepted() }
    }

    /// Says the account refused its credentials (a password changed, a token revoked or expired for good): the plugin's
    /// card and settings show that it Needs Authorization, with Setup to set it up again, until the account's Setup is done
    /// again, new credentials are saved (a refreshed token) or removed, or `accountAccepted()`. `reason`, in English, is for the log,
    /// never a secret. Not for a cloud that does not answer: that is no refusal.
    public func accountRefused(_ reason: String? = nil) {
        let first = accountRefusalBox.withLockedValue { refusal in
            defer { refusal = reason ?? "the account refused its credentials" }
            return refusal == nil
        }
        if first { logger.warning("The account refused its credentials\(reason.map { ": \($0)" } ?? ""): set it up again") }
    }

    /// Says the account took its credentials again, after `accountRefused(_:)`.
    public func accountAccepted() {
        accountRefusalBox.withLockedValue { $0 = nil }
    }

    /// Why the account refused its credentials, when the plugin said it did (`accountRefused(_:)`).
    public var accountRefusal: String? { accountRefusalBox.withLockedValue { $0 } }

    /// `plugin.<instance>.account`, or `plugin.<instance>.device-<deviceID>`.
    func credentialsFile(for deviceID: String?, legacyFile: String? = nil) -> SecretFile<JSONValue> {
        let file = deviceID.map { "device-\($0)" } ?? "account"
        return SecretFile(
            vault: CredentialVault(storage: vaultStorage), entryName: SecretFile<JSONValue>.entryName(instance: key, file: file),
            owner: "\(platform)/\(name)", legacyFile: legacyFile.map(storageFile))
    }
}
