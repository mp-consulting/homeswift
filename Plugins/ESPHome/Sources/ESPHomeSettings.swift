import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the platform's keys (`discover`, `discoveryTimeout`,
// `retryAfter`, `blacklist`, `debug`) and `devices`, the devices by address; each device's Plugin Accessory Settings
// (`host`, `port`, `retryAfter`) sit in `_accessories` by its MAC, its encryption key or password in the vault (Setup's
// credentials). A `devices` entry moves there once the plugin has learned which MAC answers at its address; one it has
// not reached stays where it is.
extension ESPHomePlugin {
    /// A device's own Plugin Accessory Settings (the schema's `accessorySchema`).
    struct DeviceSettings: Decodable, Sendable, Equatable {
        var host: String?
        var port: Int?
        /// Milliseconds; the platform's `retryAfter` by default.
        var retryAfter: Int?
    }

    /// Every device is of one kind: its entities are its accessories.
    static let deviceKind = "device"

    public func deviceKind(of deviceID: String) async -> String? { Self.deviceKind }

    /// The block with each `devices` entry whose address answered with a MAC moved into `_accessories` under it (`host`,
    /// `port` and `retryAfter`, an entry's own values winning). Its `password` and `encryptionKey` move into the vault
    /// once the block is written (`whenSettingsWritten`), unless the vault has the device's already; the block is
    /// answered without them.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let (canonical, moved) = Self.canonical(block, learned: learnedMACs)
        let context = context
        for (mac, credentials) in moved where !credentials.isEmpty && context.credentials(for: mac, as: ESPHomeCredentials.self) == nil {
            await context.whenSettingsWritten { try context.saveCredentials(credentials, for: mac) }
        }
        return canonical
    }

    /// `learned`: the MAC each `host:port` answered with. Answers the block and the credentials of each entry moved.
    static func canonical(_ block: JSONValue, learned: [String: String]) -> (JSONValue, [String: ESPHomeCredentials]) {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return (block, [:]) }
        var entries = AccessoryEntries(fields)
        var moved: [String: ESPHomeCredentials] = [:]
        var left: [JSONValue] = []
        for item in list {
            guard let device = try? item.decode(Configuration.Device.self), let host = device.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  let mac = learned[hostKey(host, device.port ?? ESPHomeEndpoint.defaultPort)], moved[mac] == nil else {
                left.append(item)
                continue
            }
            entries.setIfAbsent("host", .string(host), on: mac)
            if let port = device.port, port != ESPHomeEndpoint.defaultPort { entries.setIfAbsent("port", .number(Double(port)), on: mac) }
            if let retry = device.retryAfter { entries.setIfAbsent("retryAfter", .number(Double(retry)), on: mac) }
            moved[mac] = ESPHomeCredentials(encryptionKey: device.encryptionKey?.nonEmpty, password: device.password?.nonEmpty)
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return (.object(fields), moved)
    }
}
