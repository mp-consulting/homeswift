import Foundation
import Homeswift
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are homebridge-z2m's (`mqtt`, `log`, `defaults`,
// `exclude_grouped_devices`, `experimental`), the broker's password excepted: Setup keeps it in the vault, and a pasted
// block's `mqtt.password` still loads and moves there. Each device's options (`devices` entries) are its Plugin Accessory
// Settings, in `_accessories` by Device Id (the IEEE address, or `group-<id>`); `canonicalSettings` moves an entry there
// once Zigbee2MQTT's lists say which device its `id` names, `exclude: true` as the Core Excluded.
extension Zigbee2MQTTPlugin {
    /// The keys of a `devices` entry that are Plugin Accessory Settings.
    static let accessoryKeys = [
        "ignore_availability", "ignore_z2m_online", "excluded_keys", "included_keys", "excluded_endpoints", "values", "converters", "experimental", "exposes",
    ]

    /// `light`, `switch`, `cover`, `lock`, `thermostat`, `remote`, `sensor`, or `group`.
    public func deviceKind(of deviceID: String) async -> String? {
        devices[deviceID].map(Self.kind)
    }

    static func kind(_ device: DeviceAccessory) -> String {
        if device.entry.isGroup { return "group" }
        switch Self.category(device.handlers) {
        case .lightbulb: return "light"
        case .switch, .outlet: return "switch"
        case .windowCovering: return "cover"
        case .doorLock: return "lock"
        case .thermostat: return "thermostat"
        case .programmableSwitch: return "remote"
        default: return "sensor"
        }
    }

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var canonical = Self.canonical(block, lists: knownLists)
        guard var fields = canonical.objectValue, var mqtt = fields["mqtt"]?.objectValue, let written = mqtt["password"]?.stringValue,
              let server = mqtt["server"]?.stringValue else { return canonical }
        // The password as written, or, when the block names it by reference or seals it, the running configuration's value.
        let isReference = SecretReference(written) != nil || SecretBox.isSealed(written)
        guard let password = isReference ? settings?.mqtt.password : written, !password.isEmpty else { return canonical }
        let context = context, login = BrokerLogin(server: server, user: mqtt["user"]?.stringValue, password: password)
        await context.whenSettingsWritten { try context.saveCredentials(login) }
        mqtt.removeValue(forKey: "password")
        fields["mqtt"] = .object(mqtt)
        canonical = .object(fields)
        return canonical
    }

    /// The `devices` entries whose `id` names one device or group of Zigbee2MQTT's lists, moved into `_accessories`
    /// (an entry's own values there winning); the others, and one that includes a grouped device (`exclude: false`,
    /// which Excluded cannot say), stay.
    static func canonical(_ block: JSONValue, lists: (devices: [DeviceEntry], groups: [JSONValue])?) -> JSONValue {
        guard let lists, var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return block }
        var byID: [String: String] = [:]
        for device in lists.devices {
            for id in device.optionIDs { byID[id.lowercased()] = byID[id.lowercased()] ?? device.deviceID }
        }
        for group in lists.groups {
            guard let id = group["id"]?.intValue else { continue }
            for name in [group["friendly_name"]?.stringValue, String(id)].compactMap({ $0 }) { byID[name.lowercased()] = byID[name.lowercased()] ?? "group-\(id)" }
        }
        var entries = AccessoryEntries(fields)
        var moved = Set<String>()
        var left: [JSONValue] = []
        for item in list {
            guard let values = item.objectValue, let id = values["id"]?.stringValue, let deviceID = byID[id.lowercased()],
                  values["exclude"] != .bool(false) else {
                left.append(item)
                continue
            }
            // Only the first entry for a device ever applied: a later one would apply once the first moved.
            guard moved.insert(deviceID).inserted else { continue }
            if values["exclude"] == .bool(true) { entries.exclude(deviceID) }
            for key in accessoryKeys {
                if let value = values[key], !value.isNull { entries.setIfAbsent(key, value, on: deviceID) }
            }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return .object(fields)
    }
}
