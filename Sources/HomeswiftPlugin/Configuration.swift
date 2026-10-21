import Foundation
import Homeswift

/// config.json, in Homebridge's shape so a platform block written for a Homebridge plugin can be pasted in:
///
/// ```json
/// {
///   "bridge": { "name": "Homeswift", "username": "0E:1A:2B:3C:4D:5E", "pin": "031-45-154", "port": 51826 },
///   "platforms": [
///     { "platform": "ElgatoKeyLights", "name": "Elgato Key Lights" },
///     { "platform": "Other", "name": "Other", "_bridge": { "username": "0E:1A:2B:3C:4D:5F" } }
///   ]
/// }
/// ```
///
/// `bridge.username` is the HAP device ID and `bridge.pin` the setup code; both are optional here (Homeswift
/// generates and keeps them). A block with `_bridge` runs as a child bridge: its own HAP server, identity
/// and pairing. `accessories` blocks (Homebridge's accessory plugins) are not supported.
public struct HomeswiftConfiguration: Sendable {
    public struct Bridge: Codable, Sendable, Equatable {
        public var name: String
        public var username: String?
        public var port: Int?
        public var pin: String?
        public var manufacturer: String?
        public var model: String?
        public var firmwareRevision: String?

        public init(
            name: String = "Homeswift", username: String? = nil, port: Int? = nil, pin: String? = nil,
            manufacturer: String? = nil, model: String? = nil, firmwareRevision: String? = nil
        ) {
            self.name = name
            self.username = username
            self.port = port
            self.pin = pin
            self.manufacturer = manufacturer
            self.model = model
            self.firmwareRevision = firmwareRevision
        }

        enum CodingKeys: String, CodingKey {
            case name, username, port, pin, manufacturer, model, firmwareRevision
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Homeswift"
            username = try container.decodeIfPresent(String.self, forKey: .username)
            port = try container.decodeIfPresent(Int.self, forKey: .port)
            pin = try container.decodeIfPresent(String.self, forKey: .pin)
            manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            firmwareRevision = try container.decodeIfPresent(String.self, forKey: .firmwareRevision)
        }
    }

    /// The `_bridge` key of a platform block: run the plugin on its own HAP server.
    public struct ChildBridge: Codable, Sendable, Equatable {
        public var name: String?
        public var username: String?
        public var port: Int?
        public var pin: String?
        public var manufacturer: String?
        public var model: String?
        public var firmwareRevision: String?

        public init(name: String? = nil, username: String? = nil, port: Int? = nil, pin: String? = nil) {
            self.name = name
            self.username = username
            self.port = port
            self.pin = pin
        }
    }

    /// One platform block.
    public struct Platform: Sendable {
        public var platform: String
        /// The block's `name`, or the platform when it has none.
        public var name: String
        public var childBridge: ChildBridge?
        /// The whole block as JSON, what the plugin's `Configuration` is decoded from.
        public var json: Data

        public init(platform: String, name: String? = nil, childBridge: ChildBridge? = nil, json: Data? = nil) {
            self.platform = platform
            self.name = name ?? platform
            self.childBridge = childBridge
            self.json = json ?? Data("{\"platform\":\(Self.quote(platform)),\"name\":\(Self.quote(name ?? platform))}".utf8)
        }

        /// A block from a dictionary, for building configurations in code and tests.
        public init(platform: String, name: String? = nil, childBridge: ChildBridge? = nil, settings: [String: Any]) throws {
            var block = settings
            block["platform"] = platform
            block["name"] = name ?? platform
            let json = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
            self.init(platform: platform, name: name, childBridge: childBridge, json: json)
        }

        private static func quote(_ string: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: [string]).dropFirst().dropLast(), as: UTF8.self)
        }
    }

    public var bridge: Bridge
    public var platforms: [Platform]
    /// Platform names of blocks to skip (Homebridge lists package names here; Homeswift matches platforms).
    public var disabledPlugins: [String]
    /// How many `accessories` blocks the file has. They are not supported; the runtime warns.
    public var accessoryBlockCount: Int

    public init(bridge: Bridge = Bridge(), platforms: [Platform] = [], disabledPlugins: [String] = []) {
        self.bridge = bridge
        self.platforms = platforms
        self.disabledPlugins = disabledPlugins
        accessoryBlockCount = 0
    }

    public static func load(from url: URL) throws -> HomeswiftConfiguration {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> HomeswiftConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.notAnObject
        }
        let decoder = JSONDecoder()
        var configuration = HomeswiftConfiguration()
        if let bridge = root["bridge"] {
            guard bridge is [String: Any] else { throw ConfigurationError.invalidValue(key: "bridge", expected: "an object") }
            configuration.bridge = try decoder.decode(Bridge.self, from: JSONSerialization.data(withJSONObject: bridge))
        }
        if let platforms = root["platforms"] {
            guard let blocks = platforms as? [Any] else { throw ConfigurationError.invalidValue(key: "platforms", expected: "an array") }
            for (index, block) in blocks.enumerated() {
                guard let block = block as? [String: Any] else {
                    throw ConfigurationError.invalidValue(key: "platforms[\(index)]", expected: "an object")
                }
                guard let platform = block["platform"] as? String, !platform.isEmpty else {
                    throw ConfigurationError.invalidValue(key: "platforms[\(index)].platform", expected: "a platform name")
                }
                let name = (block["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var childBridge: ChildBridge?
                if let child = block["_bridge"] {
                    guard child is [String: Any] else { throw ConfigurationError.invalidValue(key: "platforms[\(index)]._bridge", expected: "an object") }
                    childBridge = try decoder.decode(ChildBridge.self, from: JSONSerialization.data(withJSONObject: child))
                }
                let json = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
                configuration.platforms.append(Platform(platform: platform, name: name, childBridge: childBridge, json: json))
            }
        }
        if let disabled = root["disabledPlugins"] {
            guard let names = disabled as? [String] else { throw ConfigurationError.invalidValue(key: "disabledPlugins", expected: "an array of names") }
            configuration.disabledPlugins = names
        }
        configuration.accessoryBlockCount = (root["accessories"] as? [Any])?.count ?? 0
        return configuration
    }

    /// A config.json for the first launch: a bridge with a random username and pin, and no platforms.
    public static func makeDefault(name: String = "Homeswift") -> Data {
        let username = "0E:" + (0..<5).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        let text = """
            {
              "bridge": {
                "name": \(Platform.quoteForDefault(name)),
                "username": "\(username)",
                "pin": "\(SetupCode.random().rawValue)"
              },
              "accessories": [],
              "platforms": []
            }

            """
        return Data(text.utf8)
    }
}

extension HomeswiftConfiguration.Platform {
    fileprivate static func quoteForDefault(_ string: String) -> String { quote(string) }
}

public enum ConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case notAnObject
    case invalidValue(key: String, expected: String)
    case invalidSetupCode(String)
    case invalidUsername(String)

    public var description: String {
        switch self {
        case .notAnObject: "config.json must be a JSON object"
        case .invalidValue(let key, let expected): "config.json: \"\(key)\" must be \(expected)"
        case .invalidSetupCode(let pin): "config.json: \"\(pin)\" is not a valid setup code (eight digits as XXX-XX-XXX, not trivial)"
        case .invalidUsername(let username): "config.json: \"\(username)\" is not a valid username (six hex octets, XX:XX:XX:XX:XX:XX)"
        }
    }
}
