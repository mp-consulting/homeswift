import Foundation
import HomeswiftAI
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Setting is `waitTimeUpdate`, the account being Setup's, in the
// vault (a Homebridge block's `username` and `password` still load, and move there); each device's Plugin Accessory
// Settings (`host`, `type`, `updateInterval`, `timeout`) sit in `_accessories` by its Device Id, its display name as the
// Core `name`. The Homebridge plugin's `devices` list still loads, and `canonicalSettings` moves it there: an entry's
// Device Id is its host and name run together, as it was, so the accessory keeps its identity when it moves, and a
// rename afterwards keeps it too.
extension TapoPlugin {
    /// A device's kind is its `type`: `plug`, `powerPlug`, `light`, `whiteLight`, `colorLight`, or `camera` for either camera.
    public func deviceKind(of deviceID: String) async -> String? {
        configuredDevices().first { $0.deviceID == deviceID }.map { TapoCameraKind(type: $0.device.type) != nil ? "camera" : TapoKind(type: $0.device.type).rawValue }
    }

    /// The block with each `devices` entry that has a host moved into `_accessories` under its Device Id (its name as
    /// the Name, its `host`, `type`, `updateInterval` and `timeout` as they are, an entry's own values winning). One
    /// without a host, or a second one with the same Device Id, stays in `devices`.
    ///
    /// The block's `username` and `password` (a Homebridge block's account) move into the vault once the block is written
    /// (`whenSettingsWritten`), unless Setup kept an account there already; the block is answered without them.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block)
        guard var fields = canonical.objectValue, fields["username"] != nil || fields["password"] != nil else { return canonical }
        let kept = context.credentials(as: TapoCredentials.self).map { !$0.username.isEmpty && !$0.password.isEmpty } ?? false
        if !kept {
            // The block may only name the password (a `vault:` reference, a sealed copy): the running configuration has it.
            guard let username = configuration.username, !username.isEmpty, let password = configuration.password, !password.isEmpty else {
                return canonical
            }
            let context = context, credentials = TapoCredentials(username: username, password: password)
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        fields.removeValue(forKey: "username")
        fields.removeValue(forKey: "password")
        return .object(fields)
    }

    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return block }
        var entries = AccessoryEntries(fields)
        var moved = Set<String>()
        var left: [JSONValue] = []
        for item in list {
            guard let device = try? item.decode(Configuration.Device.self), let deviceID = device.deviceID, moved.insert(deviceID).inserted,
                  let values = item.objectValue else {
                left.append(item)
                continue
            }
            if let name = device.trimmedName { entries.setIfAbsent("name", .string(name), on: deviceID) }
            for key in Self.deviceKeys {
                if let value = values[key], !value.isNull { entries.setIfAbsent(key, value, on: deviceID) }
            }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return .object(fields)
    }

    /// A device's keys, in `devices` and in `_accessories`.
    static let deviceKeys = ["host", "type", "updateInterval", "timeout", "resolution", "motion", "cloudId", "standalone"]
}
