import Foundation
import HomeswiftPlugin

extension GoveePlugin {
    /// The platform block of `@mp-consulting/homebridge-govee`, key for key. Read as leniently as the Homebridge
    /// plugin did: numbers may be strings, booleans anything truthy, every array may be missing, and a device
    /// entry keeps every key it has (the light slots and scene lists are read by the lights themselves).
    public struct Configuration: Decodable, Sendable {
        public var raw: JSONValue

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder)
            guard raw.objectValue != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "the Govee block must be an object"))
            }
        }

        public init(_ raw: JSONValue) { self.raw = raw }

        public var name: String? { raw["name"]?.stringValue }
        public var username: String? { raw["username"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        public var password: String? { raw["password"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        /// The one-time email code of Govee's new-device check.
        public var code: String? { raw["code"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) } }
        public var ignoreMatter: Bool { Self.truthy(raw["ignoreMatter"]) }
        public var disableDeviceLogging: Bool { Self.truthy(raw["disableDeviceLogging"]) }
        /// Debug lines at the info level, as the Homebridge plugin's `debug` did.
        public var debug: Bool { Self.truthy(raw["debug"]) }
        public var awsDisable: Bool { Self.truthy(raw["awsDisable"]) }
        public var bleDisable: Bool { Self.truthy(raw["bleDisable"]) }
        public var lanDisable: Bool { Self.truthy(raw["lanDisable"]) }
        public var colourSafeMode: Bool { Self.truthy(raw["colourSafeMode"]) }

        /// Seconds; 30 at least.
        var httpRefreshTime: Int { number("httpRefreshTime", minimum: GoveeConstants.Minimums.httpRefreshTime, default: GoveeConstants.Defaults.httpRefreshTime) }
        /// Seconds; 60 at least.
        var bleRefreshTime: Int { number("bleRefreshTime", minimum: GoveeConstants.Minimums.bleRefreshTime, default: GoveeConstants.Defaults.bleRefreshTime) }
        /// Milliseconds from 500, or seconds from 5 (older configurations).
        var bleControlInterval: Int {
            number("bleControlInterval", minimum: GoveeConstants.Minimums.bleControlInterval, default: GoveeConstants.Defaults.bleControlInterval)
        }
        var lanRefreshTime: Int { number("lanRefreshTime", minimum: GoveeConstants.Minimums.lanRefreshTime, default: GoveeConstants.Defaults.lanRefreshTime) }
        var lanScanInterval: Int { number("lanScanInterval", minimum: GoveeConstants.Minimums.lanScanInterval, default: GoveeConstants.Defaults.lanScanInterval) }

        /// The interval between two BLE commands.
        var bleQueueInterval: Duration {
            let value = bleControlInterval
            return value >= 500 ? .milliseconds(value) : .seconds(value)
        }

        /// A numeric option; values below the minimum (which the log mentions) and junk give the default.
        func number(_ key: String, minimum: Int, default fallback: Int) -> Int {
            guard let value = Self.integer(raw[key]), value >= minimum else { return fallback }
            return value
        }

        /// The numeric options set below their minimum, for a warning at start.
        var belowMinimum: [(key: String, value: Int, minimum: Int)] {
            let minimums: [(String, Int)] = [
                ("bleControlInterval", GoveeConstants.Minimums.bleControlInterval), ("bleRefreshTime", GoveeConstants.Minimums.bleRefreshTime),
                ("httpRefreshTime", GoveeConstants.Minimums.httpRefreshTime), ("lanRefreshTime", GoveeConstants.Minimums.lanRefreshTime),
                ("lanScanInterval", GoveeConstants.Minimums.lanScanInterval),
            ]
            return minimums.compactMap { key, minimum in
                guard let value = Self.integer(raw[key]), value < minimum else { return nil }
                return (key, value, minimum)
            }
        }

        /// Every device entry of every `…Devices` array, keyed by its device id (upper case).
        var devices: [String: DeviceSettings] {
            var result: [String: DeviceSettings] = [:]
            for key in DeviceConfigKey.allCases {
                for entry in raw[key.rawValue]?.arrayValue ?? [] {
                    guard let id = entry["deviceId"].flatMap(Self.string), !id.isEmpty else { continue }
                    let parsed = Govee.parseDeviceId(id)
                    result[parsed] = DeviceSettings(raw: entry, list: key)
                }
            }
            return result
        }

        // MARK: Lenient values

        /// JavaScript's `!!value`, except that the strings "false" and "0" are false.
        static func truthy(_ value: JSONValue?) -> Bool {
            switch value {
            case .bool(let bool)?: bool
            case .number(let number)?: number != 0 && !number.isNaN
            case .string(let string)?: !string.isEmpty && string.lowercased() != "false" && string != "0"
            case .array?, .object?: true
            default: false
            }
        }

        /// `parseInt(String(value), 10)`.
        static func integer(_ value: JSONValue?) -> Int? {
            switch value {
            case .number(let number)?: number.isFinite ? Int(number.rounded(.towardZero)) : nil
            case .string(let string)?: Govee.parseInt(string)
            default: nil
            }
        }

        static func string(_ value: JSONValue) -> String? {
            value.stringValue ?? value.doubleValue.map(DeviceUpdate.format)
        }
    }
}

/// One device's entry of config.json, whatever array it is in.
struct DeviceSettings: Sendable, Equatable {
    var raw: JSONValue
    var list: DeviceConfigKey?

    init(raw: JSONValue = .object([:]), list: DeviceConfigKey? = nil) {
        self.raw = raw
        self.list = list
    }

    subscript(key: String) -> JSONValue? { raw[key] }

    func bool(_ key: String) -> Bool { GoveePlugin.Configuration.truthy(raw[key]) }
    func int(_ key: String) -> Int? { GoveePlugin.Configuration.integer(raw[key]) }
    func string(_ key: String) -> String? { raw[key].flatMap(GoveePlugin.Configuration.string).flatMap { $0.isEmpty ? nil : $0 } }

    var label: String? { string("label")?.trimmingCharacters(in: .whitespaces).nonEmpty }
    var ignoreDevice: Bool { bool("ignoreDevice") }
    var showAs: String { string("showAs") ?? GoveeConstants.Defaults.showAs }
    var customIPAddress: String? { string("customIPAddress")?.trimmingCharacters(in: .whitespaces).nonEmpty }
    var customAddress: String? { string("customAddress")?.trimmingCharacters(in: .whitespaces).nonEmpty }
    var temperatureSource: String? { string("temperatureSource").map(Govee.parseDeviceId).flatMap(\.nonEmpty) }

    /// 1 to 100: below 20% the battery is low, by default.
    var lowBattThreshold: Int {
        guard let value = int("lowBattThreshold"), value != 0 else { return GoveeConstants.Defaults.lowBattThreshold }
        return min(value, 100)
    }

    var commandOptions: TransportCommands.Options {
        TransportCommands.Options(awsBrightnessNoScale: bool("awsBrightnessNoScale"), awsColourMode: string("awsColourMode") ?? GoveeConstants.Defaults.awsColourMode)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
