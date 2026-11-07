import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"; docs/clean-room/XiaomiMiot.md section 2.4): the Plugin Settings are `micloud`
// (its region, timeout and forceMiCloud), `pollingInterval`, `pm25Breakpoints` and `co2AbnormalThreshold`; each device's
// options are its Accessory Settings in `_accessories` by its did. A homebridge-miot block loads as it is;
// `canonicalSettings` moves its `devices[]` there, the tokens and the account's password into the vault.
extension XiaomiMiotPlugin {
    /// The keys of a `devices[]` entry that are Plugin Accessory Settings, moved under the same name.
    static let accessoryKeys: Set<String> = [
        "ip", "model", "pollingInterval", "propertyChunkSize", "deviceEnabled", "micloud", "customAccessory", "onlyMainService",
        "buzzerControl", "ledControl", "childLockControl", "modeControl", "screenControl", "fanLevelControl", "swingControl", "moveControl",
        "ioniserControl", "offDelayControl", "heaterControl", "heatLevelControl", "motorControl", "horizontalAngleButtons", "verticalAngleButtons",
        "showTemperature", "suppressAutoServiceCreation", "pm25Breakpoints", "co2AbnormalThreshold", "foodAmount",
        "actionButtons", "methodButtons", "propertyControl", "propertyMonitor",
    ]

    /// The block's keys read and ignored, dropped (2.1).
    static let droppedKeys: Set<String> = ["nameLanguage", "fans"]

    /// A value the runtime resolves rather than a typed secret.
    static func isReference(_ text: String) -> Bool {
        ["enc:", "vault:", "env:", "file:"].contains { text.hasPrefix($0) }
    }

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let result = Self.canonical(block, learnedDIDs: learnedDIDs, learnedAddresses: learnedAddresses)
        // The tokens and the password as the running configuration has them, resolved, where the block holds a reference.
        let running = Dictionary(configuration.devices.compactMap { entry -> (String, String)? in
            guard let did = DeviceOptions(entry.objectValue ?? [:]).deviceID ?? entry["ip"]?.stringValue.flatMap({ learnedDIDs[$0] }),
                  let token = entry["token"]?.stringValue else { return nil }
            return (did, token)
        }) { first, _ in first }
        var tokens: [(String, String)] = []
        for (did, written) in result.tokens {
            let token = Self.isReference(written) ? running[did] : written
            guard let token, let parsed = MiioToken(hex: token) else { continue }
            if context.credentials(for: did)?["token"]?.stringValue != parsed.hex { tokens.append((did, parsed.hex)) }
        }
        var account: (username: String?, password: String?)?
        if result.username != nil || result.password != nil {
            let password = result.password.map { Self.isReference($0) ? configuration.micloud["password"]?.stringValue : $0 } ?? nil
            account = (result.username, password)
        }
        if !tokens.isEmpty || account != nil {
            let context = context, tokens = tokens, account = account
            await context.whenSettingsWritten {
                for (did, token) in tokens {
                    var credentials = context.credentials(for: did)?.objectValue ?? [:]
                    credentials["token"] = .string(token)
                    try context.saveCredentials(.object(credentials), for: did)
                }
                if let account {
                    var credentials = context.credentials()?.objectValue ?? [:]
                    if let username = account.username { credentials["username"] = .string(username) }
                    if let password = account.password { credentials["password"] = .string(password) }
                    try context.saveCredentials(.object(credentials))
                }
            }
        }
        return result.block
    }

    /// The block in its canonical shape, with the tokens (by did) and the account's sign-in taken out of it.
    static func canonical(_ block: JSONValue, learnedDIDs: [String: String] = [:], learnedAddresses: [String: String] = [:])
        -> (block: JSONValue, tokens: [(String, String)], username: String?, password: String?) {
        guard var fields = block.objectValue else { return (block, [], nil, nil) }
        var entries = AccessoryEntries(fields)
        var tokens: [(String, String)] = []
        var username: String?, password: String?
        if var micloud = fields["micloud"]?.objectValue {
            username = micloud.removeValue(forKey: "username")?.stringValue
            password = micloud.removeValue(forKey: "password")?.stringValue
            micloud.removeValue(forKey: "useCachedSession")
            micloud.removeValue(forKey: "unencryptedRequests")
            if micloud.isEmpty { fields.removeValue(forKey: "micloud") } else { fields["micloud"] = .object(micloud) }
        }
        for key in droppedKeys { fields.removeValue(forKey: key) }
        if let list = fields["devices"]?.arrayValue {
            var left: [JSONValue] = []
            for item in list {
                guard let device = item.objectValue else { continue }
                let options = DeviceOptions(device)
                guard let did = options.deviceID ?? options.ip.flatMap({ learnedDIDs[$0] }) else {
                    left.append(item)
                    continue
                }
                if let name = options.name { entries.setIfAbsent("name", .string(name), on: did) }
                for (key, value) in device where accessoryKeys.contains(key) && !value.isNull {
                    entries.setIfAbsent(key, value, on: did)
                }
                if let token = device["token"]?.stringValue, !token.isEmpty { tokens.append((did, token)) }
            }
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        }
        entries.write(into: &fields)
        // An address the plugin saw the device at replaces the one written.
        if var accessories = fields["_accessories"]?.objectValue {
            for (did, address) in learnedAddresses {
                guard var entry = accessories[did]?.objectValue, entry["ip"]?.stringValue != address else { continue }
                entry["ip"] = .string(address)
                accessories[did] = .object(entry)
            }
            fields["_accessories"] = .object(accessories)
        }
        return (.object(fields), tokens, username, password)
    }
}
