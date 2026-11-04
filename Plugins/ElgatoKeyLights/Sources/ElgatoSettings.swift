import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the platform's keys (`pollingRate`, the power-on
// defaults, the durations, `useIP`) and `addresses`, the lights Bonjour does not reach; each light's Plugin Accessory
// Settings (`powerOnBehavior`, `powerOnBrightness`, `powerOnTemperature`) sit in `_accessories` by its MAC, the
// platform's keys of the same names being their plugin-wide defaults. The Homebridge plugin's `devices` list still loads
// and is read where `_accessories` says nothing; `canonicalSettings` moves it there.
extension ElgatoKeyLightsPlugin {
    /// A light's own Plugin Accessory Settings (the schema's `accessorySchema`); nil takes the platform's.
    struct LightSettings: Decodable, Sendable, Equatable {
        /// 1 restores the last settings, 2 the defaults; 0 or nil is the platform's.
        var powerOnBehavior: Int?
        var powerOnBrightness: Int?
        /// Kelvin; 0 keeps the light's own.
        var powerOnTemperature: Int?
    }

    /// Every light is a light: the one Device Kind.
    static let lightKind = "light"

    public func deviceKind(of deviceID: String) async -> String? { Self.lightKind }

    /// A light's settings: its Accessory Settings, then its entry in the Homebridge-shaped `devices`.
    func lightSettings(mac: String) -> LightSettings {
        let own = context.accessorySettings(for: mac).decode(LightSettings.self) ?? LightSettings()
        let legacy = deviceConfiguration(mac: mac)
        let behavior = (own.powerOnBehavior ?? legacy?.powerOnBehavior).flatMap { $0 == 0 ? nil : $0 }
        return LightSettings(
            powerOnBehavior: behavior, powerOnBrightness: own.powerOnBrightness ?? legacy?.powerOnBrightness,
            powerOnTemperature: own.powerOnTemperature ?? legacy?.powerOnTemperature)
    }

    /// Where a light added by address answers (Add by address writes them in its Accessory Settings).
    struct LightAddress: Decodable, Sendable, Equatable {
        var host: String?
        var port: Int?
    }

    /// The lights reached at an address: `addresses`, then each light whose Accessory Settings give a `host` (Add by
    /// address), keyed by its MAC; a light in both is reached at the one `addresses` gives.
    var configuredAddresses: [Configuration.Address] {
        let listed = configuration.addresses ?? []
        let macs = Set(listed.compactMap { $0.mac.flatMap(MACAddress.canonical) })
        let added = context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { mac, settings -> Configuration.Address? in
            guard let address = settings.decode(LightAddress.self), let host = address.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  let mac = MACAddress.canonical(mac), !macs.contains(mac) else { return nil }
            return Configuration.Address(host: host, port: address.port, mac: mac)
        }
        return listed + added
    }

    /// Excluded in its Accessory Settings, or `enabled: false` in `devices`.
    func isLeftOut(_ mac: String) -> Bool {
        context.isExcluded(mac) || deviceConfiguration(mac: mac)?.enabled == false
    }

    /// The block with `devices` moved into `_accessories` (by MAC: `enabled: false` as Excluded, `displayName` as the
    /// Name, the power-on settings as they are, `powerOnBehavior: 0` dropped as the platform's) and `addresses` (each
    /// entry's `ip` or `host`, `port` and MAC). An entry without a MAC stays in `devices`; the MACs the plugin learned
    /// from lights in `addresses` without one are written beside them.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        Self.canonical(block, learned: learnedMACs)
    }

    /// `learned`: the MAC each address answered with, by `host:port`.
    static func canonical(_ block: JSONValue, learned: [String: String] = [:]) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        var addresses = fields["addresses"]?.arrayValue ?? []
        var left: [JSONValue] = []
        func hasAddress(of mac: String) -> Bool {
            addresses.contains { $0["mac"]?.stringValue.flatMap(MACAddress.canonical) == mac }
        }
        for item in fields["devices"]?.arrayValue ?? [] {
            guard let device = item.objectValue, let mac = device["mac"]?.stringValue.flatMap(MACAddress.canonical) else {
                left.append(item)
                continue
            }
            var entry = entries[mac]?.objectValue ?? [:]
            if device["enabled"]?.boolValue == false, entry["excluded"] == nil { entry["excluded"] = true }
            if let name = device["displayName"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty, entry["name"] == nil {
                entry["name"] = .string(name)
            }
            if let behavior = device["powerOnBehavior"]?.intValue, behavior != 0, entry["powerOnBehavior"] == nil {
                entry["powerOnBehavior"] = .number(Double(behavior))
            }
            for key in ["powerOnBrightness", "powerOnTemperature"] where entry[key] == nil {
                if let value = device[key]?.intValue { entry[key] = .number(Double(value)) }
            }
            if !entry.isEmpty { entries[mac] = .object(entry) }
            let host = [device["ip"], device["host"]].compactMap { $0?.stringValue?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            if let host, !hasAddress(of: mac) {
                var address: [String: JSONValue] = ["host": .string(host), "mac": .string(mac)]
                if let port = device["port"]?.intValue, port != KeyLightClient.defaultPort { address["port"] = .number(Double(port)) }
                addresses.append(.object(address))
            }
        }
        addresses = addresses.map { item in
            guard var address = item.objectValue, address["mac"] == nil, let host = address["host"]?.stringValue,
                  let mac = learned[addressKey(host: host, port: address["port"]?.intValue)] else { return item }
            address["mac"] = .string(mac)
            return .object(address)
        }
        if fields["devices"] != nil {
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        }
        if !addresses.isEmpty { fields["addresses"] = .array(addresses) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }

    /// `host:port`, the key of a light in `addresses`.
    static func addressKey(host: String, port: Int?) -> String {
        "\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(port ?? KeyLightClient.defaultPort)"
    }
}
