import Foundation
import HomeswiftPlugin

extension LGThinQPlugin {
    /// The platform block of `homebridge-lg-thinq`, key for key. Everything is optional, as in Homebridge; the
    /// plugin applies the defaults and logs what is missing.
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// `account` or `token`. The plugin uses the refresh token when there is one, else the username and password.
        public var auth_mode: String?
        public var username: String?
        public var password: String?
        public var refresh_token: String?
        public var country: String?
        public var language: String?
        /// Adds the account's ThinQ v1 devices, which are polled.
        public var thinq1: Bool?
        /// Seconds between ThinQ v1 polls; 5 when absent, as in the Homebridge plugin.
        public var refresh_interval: Double?
        /// The devices to add; empty or absent adds all of them.
        public var devices: [DeviceConfiguration]?

        public init(
            name: String? = nil, auth_mode: String? = nil, username: String? = nil, password: String? = nil, refresh_token: String? = nil,
            country: String? = nil, language: String? = nil, thinq1: Bool? = nil, refresh_interval: Double? = nil, devices: [DeviceConfiguration]? = nil
        ) {
            self.name = name
            self.auth_mode = auth_mode
            self.username = username
            self.password = password
            self.refresh_token = refresh_token
            self.country = country
            self.language = language
            self.thinq1 = thinq1
            self.refresh_interval = refresh_interval
            self.devices = devices
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.lenientString(.name)
            auth_mode = container.lenientString(.auth_mode)
            username = container.lenientString(.username)
            password = container.lenientString(.password)
            refresh_token = container.lenientString(.refresh_token)
            country = container.lenientString(.country)
            language = container.lenientString(.language)
            thinq1 = container.lenientBool(.thinq1)
            refresh_interval = container.lenientNumber(.refresh_interval)
            devices = container.lenientArray(.devices)
        }

        enum CodingKeys: String, CodingKey {
            case name, auth_mode, username, password, refresh_token, country, language, thinq1, refresh_interval, devices
        }
    }

    /// One device's block: its id, and the options of its type. The block is kept whole (`raw`) so options are
    /// read as the Homebridge plugin reads them, merged over the type's defaults.
    public struct DeviceConfiguration: Decodable, Sendable {
        public var raw: [String: JSONValue]

        public var id: String? { raw["id"].map { JS.string($0) } }
        public var name: String? { raw["name"]?.stringValue }

        public init(_ raw: [String: JSONValue]) {
            self.raw = raw
        }

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder).objectValue ?? [:]
        }
    }
}

/// A device's options over its type's defaults, read the Homebridge plugin's way (JavaScript truthiness for
/// switches, strings for modes).
struct DeviceSettings: Sendable {
    var values: [String: JSONValue]

    init(type: String, block: [String: JSONValue]?) {
        values = DeviceRegistry.defaults(type).merging(block ?? [:]) { $1 }
    }

    subscript(key: String) -> JSONValue? { values[key] }

    func flag(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        if case .string(let string) = value { return !["", "false", "0", "no", "off"].contains(string.lowercased()) }
        return JS.truthy(value)
    }

    func string(_ key: String) -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        return JS.string(value)
    }

    /// A mode (`ac_mode`, `ac_swing_mode`) in upper case: the Homebridge plugin's documentation writes "both" and "vertical",
    /// which its comparisons with "BOTH" and "VERTICAL" silently ignored.
    func mode(_ key: String) -> String? { string(key)?.uppercased() }

    var name: String? { values["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var serialNumber: String? { values["serial_number"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    /// `ac_buttons`: switches that select an operation mode.
    var acButtons: [(name: String, opMode: Int)] {
        (values["ac_buttons"]?.arrayValue ?? []).compactMap { button in
            guard let name = button["name"]?.stringValue, !name.isEmpty else { return nil }
            return (name, JS.int(button["op_mode"]))
        }
    }
}

extension KeyedDecodingContainer {
    /// A string, or a number written where a string was expected.
    func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return JS.format(number) }
        return nil
    }

    /// A boolean, or `1`/`0`, `"true"`/`"false"`.
    func lenientBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number != 0 }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return ["true", "1", "yes", "on"].contains(string.lowercased()) }
        return nil
    }

    /// A number, or a numeric string.
    func lenientNumber(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            let number = JS.number(string)
            return number.isNaN ? nil : number
        }
        return nil
    }

    func lenientArray<T: Decodable>(_ key: Key) -> [T]? {
        try? decodeIfPresent([T].self, forKey: key)
    }
}
