import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the platform's keys (`pollingRate`, the durations,
// `useIP`) and `addresses`, the lights Bonjour does not reach; a light's Plugin Accessory Settings are its address (Add by
// address). What a light does when its power comes on is the bridge's Power On (`powerOn`, `setPowerOn`), kept by the
// light: the power-on keys the plugin once applied at each start (`powerOnBehavior`, `powerOnBrightness`,
// `powerOnTemperature`, plugin-wide and per light) are legacy, dropped by `canonicalSettings`. The Homebridge plugin's
// `devices` list still loads; `canonicalSettings` moves it to `_accessories` and `addresses`.
extension ElgatoKeyLightsPlugin {
    /// Every light is a light: the one Device Kind.
    static let lightKind = "light"

    public func deviceKind(of deviceID: String) async -> String? { Self.lightKind }

    /// The lights reached at an address: `addresses`, and each light whose Accessory Settings give a `host` (Add by
    /// address), keyed by its MAC. A light in both is reached where Add by address last found it, its entry of `addresses`
    /// left aside.
    var configuredAddresses: [Configuration.Address] {
        let added = context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { mac, settings -> Configuration.Address? in
            guard let address = settings.decode(Configuration.Address.self), case let host = address.host.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  let mac = MACAddress.canonical(mac) else { return nil }
            return Configuration.Address(host: host, port: address.port, mac: mac)
        }
        let macs = Set(added.compactMap(\.mac))
        let listed = (configuration.addresses ?? []).filter { $0.mac.flatMap(MACAddress.canonical).map { !macs.contains($0) } ?? true }
        return listed + added
    }

    /// Excluded in its Accessory Settings, or `enabled: false` in `devices`.
    func isLeftOut(_ mac: String) -> Bool {
        context.isExcluded(mac) || deviceConfiguration(mac: mac)?.enabled == false
    }

    /// The block with `devices` moved into `_accessories` (by MAC: `enabled: false` as Excluded, `displayName` as the
    /// Name) and `addresses` (each
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
        // The legacy power-on keys, the light's own Power On now: plugin-wide and in each light's entry.
        for key in legacyPowerOnKeys { fields.removeValue(forKey: key) }
        entries = entries.mapValues { entry in
            guard var object = entry.objectValue else { return entry }
            for key in legacyPowerOnKeys { object.removeValue(forKey: key) }
            return .object(object)
        }.filter { $0.value.objectValue?.isEmpty != true }
        if fields["devices"] != nil {
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        }
        if !addresses.isEmpty { fields["addresses"] = .array(addresses) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) } else { fields.removeValue(forKey: "_accessories") }
        return .object(fields)
    }

    static let legacyPowerOnKeys = ["powerOnBehavior", "powerOnBrightness", "powerOnTemperature"]

    /// `host:port`, the key of a light in `addresses`.
    static func addressKey(host: String, port: Int?) -> String {
        "\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(port ?? KeyLightClient.defaultPort)"
    }
}
