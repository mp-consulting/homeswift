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
        let canonical = Self.canonical(block, devices: devices, scenarios: scenarios)
        guard var fields = canonical.objectValue, fields["user"] != nil || fields["password"] != nil else { return canonical }
        if context.credentials(as: TahomaAccount.self) == nil {
            guard let account else { return canonical }
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(account) }
        }
        fields.removeValue(forKey: "user")
        fields.removeValue(forKey: "password")
        return .object(fields)
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
