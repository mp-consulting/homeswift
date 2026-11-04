import Foundation
import HomeswiftAI
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
/// and pairing. A block with `"_paused": true` keeps its accessories in HomeKit, showing No Response, while its
/// plugin does not run, so nothing reaches the devices or their cloud. `_accessories` holds Accessory Settings by Device
/// Id (`AccessorySettings`): its `name`s rename accessories, in HomeKit too (`AccessoryNaming`), `room` and `hidden` place
/// them on the web UI's wall, and `notInHome` keeps them out of HomeKit (the web UI, the MCP server and Matter still have
/// them); those four apply without reloading the plugin. `_hiddenFromHomeKit`, a list of accessory ids, is the older
/// form of `notInHome`: read, and moved into `_accessories` by the next write of the block's settings.
/// `bridge.roomSync` is Room Sync (GLOSSARY.md), which needs no restart. `accessories` blocks (Homebridge's accessory
/// plugins) run in the block of their platform, in its `accessories` list (`adoptAccessoryBlocks`), when its plugin runs
/// them (`HomeswiftPlugin.runsAccessoryBlocks`).
public struct HomeswiftConfiguration: Sendable {
    public struct Bridge: Codable, Sendable, Equatable {
        public var name: String
        public var username: String?
        public var port: Int?
        public var pin: String?
        public var manufacturer: String?
        public var model: String?
        public var firmwareRevision: String?
        /// Homebridge's mDNS advertiser: `ciao` is the built-in responder; `bonjour-hap`, `avahi` and
        /// `resolved` are the system's dns_sd, which falls back to the built-in responder when unavailable.
        public var advertiser: String?
        /// The interfaces (names or IPv4 addresses) the built-in responder advertises on; a string or a list.
        public var bind: [String]?

        public init(
            name: String = "Homeswift", username: String? = nil, port: Int? = nil, pin: String? = nil,
            manufacturer: String? = nil, model: String? = nil, firmwareRevision: String? = nil,
            advertiser: String? = nil, bind: [String]? = nil
        ) {
            self.name = name
            self.username = username
            self.port = port
            self.pin = pin
            self.manufacturer = manufacturer
            self.model = model
            self.firmwareRevision = firmwareRevision
            self.advertiser = advertiser
            self.bind = bind
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
            advertiser = try container.decodeIfPresent(String.self, forKey: .advertiser)
            if let one = try? container.decodeIfPresent(String.self, forKey: .bind) {
                bind = [one]
            } else {
                bind = try container.decodeIfPresent([String].self, forKey: .bind)
            }
        }

        /// The advertiser `advertiser` names; nil for a name Homeswift does not know.
        public var advertiserChoice: HAPServer.Options.Advertiser? {
            switch advertiser?.lowercased() {
            case nil, "bonjour-hap", "bonjour", "avahi", "resolved": .system
            case "ciao": .builtIn
            default: nil
            }
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

        /// As a bridge of its own, named after the block when it has no name.
        public func bridge(named fallback: String) -> Bridge {
            Bridge(name: name ?? fallback, username: username, port: port, pin: pin, manufacturer: manufacturer, model: model, firmwareRevision: firmwareRevision)
        }
    }

    /// One platform block.
    public struct Platform: Sendable {
        public var platform: String
        /// The block's `name`, or the platform when it has none.
        public var name: String
        public var childBridge: ChildBridge?
        /// `_paused`: the plugin does not run; its accessories stay, unavailable.
        public var paused: Bool
        /// The ids of its accessories kept out of HomeKit (`HAPServer.setHiddenFromHomeKit`): Not in Home in
        /// `_accessories` (`<platform>:<key>`), and the legacy `_hiddenFromHomeKit` list. They stay in the web UI, the MCP
        /// server and Matter. Not in `json`: changing it does not reload the plugin.
        public var hiddenFromHomeKit: [String] = []
        /// The names given in `_accessories`, by Device Id (`AccessoryNaming`): the runtime renames the accessories, in
        /// HomeKit too. Not in `json`: a rename does not reload the plugin.
        public var accessoryNames: [String: String] = [:]
        /// The rooms given in `_accessories`, by key; empty for an accessory put in no room. Not in `json`.
        public var accessoryRooms: [String: String] = [:]
        /// The keys of `_accessories` that are Hidden: off the web UI's wall. Not in `json`.
        public var hiddenOnWall: Set<String> = []
        /// `_accessories`: Accessory Settings by Device Id (`AccessorySettings`), without the live ones (`liveKeys`), which
        /// are the properties above. In `json` too: a change reloads the plugin.
        public var accessorySettings: [String: AccessorySettings] = [:]
        /// The whole block as JSON, what the plugin's `Configuration` is decoded from.
        public var json: Data
        /// How many of config.json's top-level `accessories` blocks it runs, appended to its own `accessories` list
        /// (`adoptAccessoryBlocks`); 0 for a block that only holds its own. Not in config.json's `platforms`.
        public var accessoryBlocks = 0

        public init(platform: String, name: String? = nil, childBridge: ChildBridge? = nil, paused: Bool = false, json: Data? = nil) {
            self.platform = platform
            self.name = name ?? platform
            self.childBridge = childBridge
            self.paused = paused
            self.json = json ?? Data("{\"platform\":\(jsonQuoted(platform)),\"name\":\(jsonQuoted(name ?? platform))}".utf8)
            accessorySettings = AccessorySettings.all(in: (try? JSONValue(data: self.json)) ?? .null)
        }

        /// A block from a dictionary, for building configurations in code and tests.
        public init(platform: String, name: String? = nil, childBridge: ChildBridge? = nil, paused: Bool = false, settings: [String: Any]) throws {
            var block = settings
            block["platform"] = platform
            block["name"] = name ?? platform
            if paused { block["_paused"] = true }
            // As config.json's blocks are read: the live Accessory Settings out of the plugin's JSON.
            self = try HomeswiftConfiguration.platform(from: block, index: 0)
            if let childBridge { self.childBridge = childBridge }
        }

    }

    public var bridge: Bridge
    public var platforms: [Platform]
    /// Platform names of blocks to skip (Homebridge lists package names here; Homeswift matches platforms).
    public var disabledPlugins: [String]
    /// How many `accessories` blocks (Homebridge's accessory plugins) the file has. Each runs in the block of its
    /// platform (`adoptAccessoryBlocks`), whose plugin must run accessory blocks (`HomeswiftPlugin.runsAccessoryBlocks`).
    public var accessoryBlockCount: Int
    /// `bridge.roomSync`, Room Sync (GLOSSARY.md); nil when the bridge block does not say. Not part of `bridge`: changing
    /// it needs no restart.
    public var roomSync: Bool?

    public init(bridge: Bridge = Bridge(), platforms: [Platform] = [], disabledPlugins: [String] = []) {
        self.bridge = bridge
        self.platforms = platforms
        self.disabledPlugins = disabledPlugins
        accessoryBlockCount = 0
    }

    public static func load(from url: URL) throws -> HomeswiftConfiguration {
        try decode(Data(contentsOf: url))
    }

    /// The first block of a platform, decoded: for the blocks the runtime reads itself (the Assistant, the web UI).
    public func block(for platform: String) throws -> JSONValue? {
        try platforms.first { $0.platform == platform }.map { try JSONValue(data: $0.json) }
    }

    /// The checks the runtime makes before starting: setup codes and device IDs of the bridge and of every
    /// child bridge are well formed. Throws a `ConfigurationError` naming the first bad value.
    public func validate() throws {
        func check(pin: String?, username: String?) throws {
            if let pin, SetupCode(pin) == nil { throw ConfigurationError.invalidSetupCode(pin) }
            if let username, !Self.isDeviceID(username) { throw ConfigurationError.invalidUsername(username) }
        }
        try check(pin: bridge.pin, username: bridge.username)
        for platform in platforms {
            if let child = platform.childBridge { try check(pin: child.pin, username: child.username) }
        }
    }

    /// Six hex octets, `0E:1A:2B:3C:4D:5E`.
    public static func isDeviceID(_ string: String) -> Bool {
        let octets = string.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    /// One block of `platforms` (at `index`, for the errors' keys) as the runtime runs it: its live Accessory Settings
    /// (`AccessorySettings.liveKeys`) taken out of the plugin's JSON into the properties that hold them, so changing them
    /// does not reload it. A device whose entry holds only those still has Accessory Settings (the defaults), so the plugin
    /// sees the device.
    static func platform(from block: [String: Any], index: Int) throws -> Platform {
        let decoder = JSONDecoder()
        guard let platform = block["platform"] as? String, !platform.isEmpty else {
            throw ConfigurationError.invalidValue(key: "platforms[\(index)].platform", expected: "a platform name")
        }
        let name = (block["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var childBridge: ChildBridge?
        if let child = block["_bridge"] {
            guard child is [String: Any] else { throw ConfigurationError.invalidValue(key: "platforms[\(index)]._bridge", expected: "an object") }
            childBridge = try decoder.decode(ChildBridge.self, from: JSONSerialization.data(withJSONObject: child))
        }
        if let paused = block["_paused"], !(paused is Bool) {
            throw ConfigurationError.invalidValue(key: "platforms[\(index)]._paused", expected: "true or false")
        }
        var hidden: [String] = []
        if let list = block["_hiddenFromHomeKit"] {
            guard let ids = list as? [String] else {
                throw ConfigurationError.invalidValue(key: "platforms[\(index)]._hiddenFromHomeKit", expected: "an array of accessory ids")
            }
            hidden = ids
        }
        var names: [String: String] = [:]
        var rooms: [String: String] = [:]
        var hiddenOnWall: Set<String> = []
        // The devices whose entry holds live settings only: out of the plugin's JSON (a rename reloads nothing), but still
        // among its Accessory Settings (`context.allAccessorySettings`), as a device set up with a Name only.
        var liveOnly: Set<String> = []
        var kept = block.filter { $0.key != "_hiddenFromHomeKit" }
        if let settings = block["_accessories"] {
            guard let byDevice = settings as? [String: Any], byDevice.values.allSatisfy({ $0 is [String: Any] }) else {
                throw ConfigurationError.invalidValue(key: "platforms[\(index)]._accessories", expected: "an object of Accessory Settings by Device Id")
            }
            // The live settings leave the plugin's JSON, so changing them does not reload it; the others are its own.
            var others: [String: Any] = [:]
            for case let (deviceID, fields as [String: Any]) in byDevice {
                let at = "platforms[\(index)]._accessories.\(deviceID)"
                if let given = fields["name"] {
                    guard let text = given as? String else { throw ConfigurationError.invalidValue(key: "\(at).name", expected: "a name") }
                    if let name = AccessoryNaming.cleaned(text) { names[deviceID] = name }
                }
                if let given = fields["room"] {
                    guard let text = given as? String else { throw ConfigurationError.invalidValue(key: "\(at).room", expected: "a room's name") }
                    rooms[deviceID] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for key in ["hidden", "notInHome"] {
                    guard let given = fields[key] else { continue }
                    guard let flag = given as? Bool else { throw ConfigurationError.invalidValue(key: "\(at).\(key)", expected: "true or false") }
                    if flag, key == "hidden" { hiddenOnWall.insert(deviceID) }
                    if flag, key == "notInHome", !hidden.contains("\(platform):\(deviceID)") { hidden.append("\(platform):\(deviceID)") }
                }
                let rest = fields.filter { !AccessorySettings.liveKeys.contains($0.key) }
                if rest.isEmpty { liveOnly.insert(deviceID) } else { others[deviceID] = rest }
            }
            kept["_accessories"] = others.isEmpty ? nil : others
        }
        let json = try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
        var entry = Platform(platform: platform, name: name, childBridge: childBridge, paused: block["_paused"] as? Bool == true, json: json)
        entry.hiddenFromHomeKit = hidden
        entry.accessoryNames = names
        entry.accessoryRooms = rooms
        entry.hiddenOnWall = hiddenOnWall
        // The live settings as they are now, for a plugin that reads them (a device's Name for its own list): they
        // changed without reloading it, so the runtime keeps its context's copy in step (`PluginHost.apply`).
        for deviceID in liveOnly where entry.accessorySettings[deviceID] == nil { entry.accessorySettings[deviceID] = AccessorySettings() }
        for (deviceID, name) in names { entry.accessorySettings[deviceID]?.name = name }
        for (deviceID, room) in rooms { entry.accessorySettings[deviceID]?.room = room }
        for deviceID in hiddenOnWall { entry.accessorySettings[deviceID]?.hidden = true }
        for id in hidden where id.hasPrefix("\(platform):") { entry.accessorySettings[String(id.dropFirst(platform.count + 1))]?.notInHome = true }
        return entry
    }

    /// What a block's plugin reads of it (`Platform.json`): the block without its live Accessory Settings and its
    /// `_hiddenFromHomeKit`. Two blocks with the same answer run their plugin alike, so a write from one to the other
    /// reloads nothing. nil when the block does not decode.
    public static func pluginJSON(of block: JSONValue) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: block.encoded()) as? [String: Any] else { return nil }
        return try? platform(from: object, index: 0).json
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
            if let sync = (bridge as? [String: Any])?["roomSync"] {
                guard let on = sync as? Bool else { throw ConfigurationError.invalidValue(key: "bridge.roomSync", expected: "true or false") }
                configuration.roomSync = on
            }
        }
        var blocks: [[String: Any]] = []
        if let platforms = root["platforms"] {
            guard let list = platforms as? [Any] else { throw ConfigurationError.invalidValue(key: "platforms", expected: "an array") }
            for (index, block) in list.enumerated() {
                guard let block = block as? [String: Any] else {
                    throw ConfigurationError.invalidValue(key: "platforms[\(index)]", expected: "an object")
                }
                blocks.append(block)
            }
        }
        var adopted: [Int: Int] = [:]
        if let accessories = root["accessories"] {
            guard let list = accessories as? [Any] else { throw ConfigurationError.invalidValue(key: "accessories", expected: "an array") }
            configuration.accessoryBlockCount = list.count
            adopted = try adoptAccessoryBlocks(list, into: &blocks)
        }
        for (index, block) in blocks.enumerated() {
            var entry = try platform(from: block, index: index)
            entry.accessoryBlocks = adopted[index] ?? 0
            configuration.platforms.append(entry)
        }
        if let disabled = root["disabledPlugins"] {
            guard let names = disabled as? [String] else { throw ConfigurationError.invalidValue(key: "disabledPlugins", expected: "an array of names") }
            configuration.disabledPlugins = names
        }
        return configuration
    }

    /// The platform that runs the accessory blocks whose `accessory` is `name`: the name itself, or the part after the
    /// package in Homebridge's qualified form (`homebridge-mqttthing.mqttthing` is `mqttthing`). nil for an empty name.
    public static func accessoryPlatform(_ name: String) -> String? {
        let platform = name.split(separator: ".").last.map(String.init) ?? ""
        return platform.isEmpty ? nil : platform
    }

    /// Homebridge's accessory blocks (config.json's top-level `accessories`), each appended to the `accessories` list
    /// of the block of its platform (`accessoryPlatform`): the first one with the same child bridge (`_bridge.username`,
    /// or none), else a new block named after the platform, or after its `_bridge`, so the blocks sharing a child bridge
    /// run in one instance. Returns how many each block (by index) took in.
    static func adoptAccessoryBlocks(_ list: [Any], into blocks: inout [[String: Any]]) throws -> [Int: Int] {
        var adopted: [Int: Int] = [:]
        for (index, item) in list.enumerated() {
            guard let block = item as? [String: Any] else { throw ConfigurationError.invalidValue(key: "accessories[\(index)]", expected: "an object") }
            guard let accessory = block["accessory"] as? String, let platform = accessoryPlatform(accessory) else {
                throw ConfigurationError.invalidValue(key: "accessories[\(index)].accessory", expected: "an accessory name")
            }
            if let child = block["_bridge"], !(child is [String: Any]) {
                throw ConfigurationError.invalidValue(key: "accessories[\(index)]._bridge", expected: "an object")
            }
            let child = block["_bridge"] as? [String: Any]
            let username = child?["username"] as? String
            let target = blocks.firstIndex { candidate in
                candidate["platform"] as? String == platform && (candidate["_bridge"] as? [String: Any])?["username"] as? String == username
            }
            if let target {
                var existing = blocks[target]["accessories"] as? [Any] ?? []
                existing.append(block)
                blocks[target]["accessories"] = existing
                adopted[target, default: 0] += 1
            } else {
                let name = (child?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username.map { "\(platform) \($0)" } ?? platform
                var created: [String: Any] = ["platform": platform, "name": name, "accessories": [block]]
                if let child { created["_bridge"] = child }
                blocks.append(created)
                adopted[blocks.count - 1] = 1
            }
        }
        return adopted
    }

    /// A config.json for the first launch: a bridge with a random username and pin, and no platforms.
    public static func makeDefault(name: String = "Homeswift") -> Data {
        let username = "0E:" + (0..<5).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        let text = """
            {
              "bridge": {
                "name": \(jsonQuoted(name)),
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

/// `string` as a JSON string literal, quotes included.
private func jsonQuoted(_ string: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [string]).dropFirst().dropLast(), as: UTF8.self)
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
        // The value is not printed: a setup code is never logged, and this text reaches the log at startup.
        case .invalidSetupCode: "config.json: the bridge's setup code is not valid (eight digits as XXX-XX-XXX, not trivial)"
        case .invalidUsername(let username): "config.json: \"\(username)\" is not a valid username (six hex octets, XX:XX:XX:XX:XX:XX)"
        }
    }
}
