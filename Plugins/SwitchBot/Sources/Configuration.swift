import Foundation
import HomeswiftPlugin

extension SwitchBotPlugin {
    /// The block of `@switchbot/homebridge-switchbot`, in its 4.x shape (`credentials`, `options`) or its 5.x one
    /// (`openApiToken`, `openApiSecret`, `devices` at the top); 5.x's keys win, as 5.x reads them.
    public struct Configuration: Decodable, Sendable {
        public struct Credentials: Decodable, Sendable {
            public var token: String?
            public var secret: String?
        }

        public var name: String?
        public var credentials: Credentials?
        /// 4.x's options, read leniently (numbers may be written as text).
        public var options: JSONValue?
        // 5.x
        public var openApiToken: String?
        public var openApiSecret: String?
        public var devices: [JSONValue]?
        public var openApiRefreshRate: Double?
        public var dailyApiLimit: Int?
        public var dailyApiReserveForCommands: Int?
        public var dailyApiResetLocalMidnight: Bool?
        public var co2AbnormalThreshold: Double?
        public var writeDebounceMs: Double?
        /// 5.x: `false` turns Bluetooth off for every device.
        public var enableBLE: Bool?
        /// 5.x: a connected status read of the devices on Bluetooth every `blePollIntervalMs` (10 minutes, at least 1).
        public var blePollingEnabled: Bool?
        public var blePollIntervalMs: Double?

        var token: String? { (openApiToken?.nonEmpty) ?? credentials?.token?.nonEmpty }
        var secret: String? { (openApiSecret?.nonEmpty) ?? credentials?.secret?.nonEmpty }

        var platformOptions: DeviceOptions { DeviceOptions(options?.objectValue ?? [:]) }

        /// The Homebridge-shaped list of devices: 4.x's `options.devices`, else 5.x's `devices` (its `botDisplay` read
        /// as `type`, `enabled: false` as `hide_device`).
        var deviceEntries: [DeviceOptions]? {
            if let list = options?["devices"]?.arrayValue { return list.compactMap(\.objectValue).map(DeviceOptions.init) }
            guard let list = devices else { return nil }
            return list.compactMap(\.objectValue).map { entry in
                var values = entry
                if values["type"] == nil, let display = values["botDisplay"] { values["type"] = display }
                if values["enabled"]?.boolValue == false { values["hide_device"] = true }
                return DeviceOptions(values)
            }
        }

        var remoteEntries: [DeviceOptions]? { options?["irdevices"]?.arrayValue.map { $0.compactMap(\.objectValue).map(DeviceOptions.init) } }

        /// `options.deviceConfig[type]` (or `irdeviceConfig`).
        func typeOptions(_ type: String, remote: Bool) -> [String: JSONValue] {
            options?[remote ? "irdeviceConfig" : "deviceConfig"]?[type]?.objectValue ?? [:]
        }

        var refreshRate: Double {
            let platform = platformOptions.number("refreshRate") ?? openApiRefreshRate.flatMap { $0 > 0 ? $0 : nil }
            return platform ?? 300
        }

        var webhookURL: URL? {
            platformOptions.string("webhookURL").flatMap(URL.init(string:)).flatMap { $0.host == nil ? nil : $0 }
        }

        var base: URL {
            guard let host = platformOptions.string("hostname"), let url = URL(string: host), url.host != nil else { return OpenAPI.defaultBase }
            return url
        }

        /// Seconds between two writes merged into one command: `pushRate` of 4.x, else 5.x's `writeDebounceMs`, 0.1 by
        /// default.
        var debounceSeconds: Double {
            platformOptions.number("pushRate") ?? max(writeDebounceMs ?? 100, 0) / 1000
        }
    }
}

/// A device's options, merged as 4.x merges them (§2.5): the cloud's entry, then `deviceConfig[type]`, then its entry
/// of `devices`, then its Accessory Settings. Values are read leniently: a number may be text, a flag `"true"`.
struct DeviceOptions: Sendable, Equatable {
    var values: [String: JSONValue]

    init(_ values: [String: JSONValue] = [:]) { self.values = values }

    /// These options with `other`'s laid over them.
    func merged(_ other: [String: JSONValue]) -> DeviceOptions {
        DeviceOptions(values.merging(other) { _, new in new })
    }

    subscript(key: String) -> JSONValue? { values[key].flatMap { $0.isNull ? nil : $0 } }

    func string(_ keys: String...) -> String? {
        for key in keys {
            switch self[key] {
            case .string(let text) where !text.trimmingCharacters(in: .whitespaces).isEmpty: return text.trimmingCharacters(in: .whitespaces)
            case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
            default: continue
            }
        }
        return nil
    }

    func number(_ keys: String...) -> Double? {
        for key in keys {
            if case .bool = self[key] { continue }
            if let value = self[key].flatMap(HomeswiftSwitchBot.number) { return value }
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let flag): flag
        case .string(let text): ["true", "1", "yes", "on"].contains(text.lowercased()) ? true : ["false", "0", "no", "off"].contains(text.lowercased()) ? false : nil
        case .number(let number): number != 0
        default: nil
        }
    }

    func flag(_ key: String) -> Bool { bool(key) ?? false }

    var deviceID: String? { string("deviceId") }
}

extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}

/// Device ids as 4.x compares them: letters and digits only, upper case.
func normalizedID(_ id: String) -> String {
    String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).uppercased()
}
