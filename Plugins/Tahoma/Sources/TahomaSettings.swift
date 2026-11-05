import Foundation
import HomeswiftAI
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are homebridge-tahoma's (`service`, `pollingPeriod`,
// `refreshPeriod`, `exposeScenarios`, `exclude`, `devicesConfig`…), the account being Setup's, in the vault. A device's
// own options (`reverse`, `movementDuration`, `stayZones`…) are Plugin Accessory Settings in `_accessories` by its
// deviceURL. `devicesConfig` entries keyed by a device (its label, deviceURL or the Homebridge accessory's UUID) and
// `exclude` entries naming a device or a scenario move there; entries keyed by a uiClass, a widget or a protocol stay,
// since they are for every device of that kind.
extension TahomaPlugin {
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block, devices: devices, scenarios: listedScenarios)
        guard var fields = canonical.objectValue, fields["user"] != nil || fields["password"] != nil else { return canonical }
        let kept = context.credentials(as: TahomaAccount.self)
        // A user and password typed into the block are the account from now on; one it only names (sealed, a `vault:`
        // reference) is the running configuration's, resolved.
        if let moving = Self.typedAccount(fields, service: account?.service) ?? (kept == nil ? account : nil) {
            if moving != kept {
                let context = context
                await context.whenSettingsWritten { try context.saveCredentials(moving) }
            }
        } else if kept == nil {
            return canonical
        }
        fields.removeValue(forKey: "user")
        fields.removeValue(forKey: "password")
        return .object(fields)
    }

    /// The block's own `user` and `password`, when both are there as typed (neither sealed nor a reference).
    static func typedAccount(_ fields: [String: JSONValue], service: String?) -> TahomaAccount? {
        guard let user = fields["user"]?.stringValue?.trimmingCharacters(in: .whitespaces), !user.isEmpty,
              let password = fields["password"]?.stringValue, !password.isEmpty, !SecretBox.isSealed(password), SecretReference(password) == nil
        else { return nil }
        return TahomaAccount(service: fields["service"]?.stringValue ?? service ?? OverkizService.somfyEurope.rawValue, user: user, password: password)
    }

    static func canonical(_ block: JSONValue, devices: [OverkizDevice], scenarios: [OverkizScenario]) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = AccessoryEntries(fields)
        let resolve = { (key: String) -> [String] in
            devices.filter { $0.label == key || $0.deviceURL == key || $0.legacyUUID == key.lowercased() }.map(\.deviceURL)
        }
        if let list = fields["devicesConfig"]?.arrayValue {
            var left: [JSONValue] = []
            for item in list {
                guard let values = item.objectValue, let key = values["key"]?.scalarText else {
                    left.append(item)
                    continue
                }
                let targets = resolve(key)
                guard !targets.isEmpty else {
                    left.append(item)
                    continue
                }
                for deviceID in targets {
                    for name in DeviceOptions.keys {
                        guard var value = values[name], !value.isNull else { continue }
                        if name == "lowSpeed", value.boolValue != nil { value = value.boolValue == true ? "always" : "" }
                        entries.setIfAbsent(name, value, on: deviceID)
                    }
                }
            }
            if left.isEmpty { fields.removeValue(forKey: "devicesConfig") } else { fields["devicesConfig"] = .array(left) }
        }
        entries.excludeList("exclude", in: &fields) { name in
            resolve(name) + scenarios.filter { $0.label == name }.map { scenarioDeviceID(oid: $0.oid) }
        }
        entries.write(into: &fields)
        return .object(fields)
    }
}
