import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the route, the app's email, the developer account's
// region, `importHistory` and `pollingInterval`; the developer keys and the app's password are the account's credentials,
// in the vault (EcoFlowSetup.swift). Each device is a Discovered Device by its serial number, of the Device Kind of its
// model (`stream`, `home`, `portable`, `powerBank`), its Plugin Accessory Settings the charge and discharge limits
// (`chargeLimit`, `dischargeLimit`, EcoFlowPlugin.applyLimits): its Name is a Core Accessory Setting. A block's `devices` (serial numbers with names), `accessKey`, `secretKey` and `password` still load;
// `canonicalSettings` moves them.
extension EcoFlowPlugin {
    public func deviceKind(of deviceID: String) async -> String? {
        (latest.first { $0.id == deviceID }?.model ?? EcoFlowModel.model(serial: deviceID))?.kind.rawValue
    }

    /// The block in its canonical shape: the keys and the password it holds moved into the vault (the running
    /// configuration's, resolved, kept there once the block is written without them; the vault's own win), and `devices`
    /// as each device's Name.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let stored = context.credentials(as: AccountCredentials.self)
        var kept = stored ?? AccountCredentials()
        if !kept.hasKeys, block["accessKey"] != nil || block["secretKey"] != nil,
           let accessKey = configuration.accessKey, !accessKey.isEmpty, let secretKey = configuration.secretKey, !secretKey.isEmpty {
            kept.accessKey = accessKey
            kept.secretKey = secretKey
        }
        if !kept.hasPassword, block["password"] != nil, let password = configuration.password, !password.isEmpty {
            kept.password = password
        }
        if kept != (stored ?? AccountCredentials()) {
            let context = context
            let credentials = kept
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        return Self.canonical(block, vaultHasKeys: kept.hasKeys, vaultHasPassword: kept.hasPassword)
    }

    /// `vaultHasKeys`, `vaultHasPassword`: what the vault keeps (or will once the block is written), whose copies in the
    /// block go.
    static func canonical(_ block: JSONValue, vaultHasKeys: Bool, vaultHasPassword: Bool) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        if vaultHasKeys {
            fields.removeValue(forKey: "accessKey")
            fields.removeValue(forKey: "secretKey")
        }
        if vaultHasPassword { fields.removeValue(forKey: "password") }
        if let list = fields["devices"]?.arrayValue {
            var entries = fields["_accessories"]?.objectValue ?? [:]
            var left: [JSONValue] = []
            for item in list {
                guard let id = item["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { left.append(item); continue }
                // The account lists its devices: an entry is only its name.
                if let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    var entry = entries[id]?.objectValue ?? [:]
                    if entry["name"] == nil { entry["name"] = .string(name) }
                    entries[id] = .object(entry)
                }
            }
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
            if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        }
        return .object(fields)
    }
}
