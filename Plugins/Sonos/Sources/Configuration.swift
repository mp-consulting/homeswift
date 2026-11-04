import Foundation
import HomeswiftPlugin

extension SonosPlugin {
    /// The block of `homebridge-zp`, read as leniently as it reads it: a wrong type or an unknown choice is a warning
    /// and the default; integers are clamped to their range; booleans take `true`/`yes`/`on`/`1` and their opposites,
    /// integers a number or a decimal (or `0x`, `0o`, `0b`) string.
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        public var alarms: Bool?
        public var brightness: Bool?
        public var excludeAirPlay: Bool?
        public var heartrate: Int?
        public var leds: Bool?
        public var maxFavourites: Int?
        public var mdns: Bool?
        public var port: Int?
        public var resetTimeout: Int?
        public var service: String?
        public var speakers: Bool?
        public var subscriptionTimeout: Int?
        public var timeout: Int?
        public var tv: Bool?
        public var tvIdPrefix: String?
        /// What could not be read, for the log at start.
        public var warnings: [String] = []

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, alarms, brightness, excludeAirPlay, heartrate, leds, maxFavourites, mdns, port, resetTimeout, service
            case speakers, subscriptionTimeout, timeout, tv, tvIdPrefix
        }

        public init() {}

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var warnings: [String] = []
            func value(_ key: CodingKeys) -> JSONValue? {
                guard let value = try? container.decodeIfPresent(JSONValue.self, forKey: key), !value.isNull else { return nil }
                return value
            }
            func bool(_ key: CodingKeys) -> Bool? {
                guard let raw = value(key) else { return nil }
                if let parsed = Self.bool(raw) { return parsed }
                warnings.append("config.json: \(key.rawValue): not a boolean, ignored")
                return nil
            }
            func int(_ key: CodingKeys) -> Int? {
                guard let raw = value(key) else { return nil }
                if let parsed = Self.int(raw) { return parsed }
                warnings.append("config.json: \(key.rawValue): not an integer, ignored")
                return nil
            }
            func string(_ key: CodingKeys) -> String? {
                guard let raw = value(key) else { return nil }
                if let parsed = raw.stringValue { return parsed }
                warnings.append("config.json: \(key.rawValue): not a string, ignored")
                return nil
            }
            name = string(.name)
            alarms = bool(.alarms)
            brightness = bool(.brightness)
            excludeAirPlay = bool(.excludeAirPlay)
            heartrate = int(.heartrate)
            leds = bool(.leds)
            maxFavourites = int(.maxFavourites)
            mdns = bool(.mdns)
            port = int(.port)
            resetTimeout = int(.resetTimeout)
            service = string(.service)
            if let service, !Settings.ServiceKind.allCases.map(\.rawValue).contains(service) {
                warnings.append("config.json: service: \"\(service)\": not one of switch, light, speaker, fan; ignored")
                self.service = nil
            }
            speakers = bool(.speakers)
            subscriptionTimeout = int(.subscriptionTimeout)
            timeout = int(.timeout)
            tv = bool(.tv)
            tvIdPrefix = string(.tvIdPrefix)
            if tvIdPrefix?.isEmpty == true {
                warnings.append("config.json: tvIdPrefix: empty, ignored")
                tvIdPrefix = nil
            }
            self.warnings = warnings
        }

        static func bool(_ value: JSONValue) -> Bool? {
            if let bool = value.boolValue { return bool }
            if let number = value.doubleValue { return number == 1 ? true : number == 0 ? false : nil }
            switch value.stringValue?.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        }

        static func int(_ value: JSONValue) -> Int? {
            if let int = value.saturatingIntValue { return int }
            guard var text = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            var sign = 1
            if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
            let parsed: Int? =
                text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16)
                : text.hasPrefix("0o") ? Int(text.dropFirst(2), radix: 8)
                : text.hasPrefix("0b") ? Int(text.dropFirst(2), radix: 2) : Int(text)
            return parsed.map { $0 * sign }
        }
    }

    /// The configuration with its defaults applied and its integers clamped: what the plugin runs on.
    struct Settings: Sendable, Equatable {
        /// The HAP type of the Sonos and Speakers services.
        enum ServiceKind: String, Sendable, CaseIterable {
            case `switch`, light, speaker, fan
        }

        var alarms = false
        /// Volume as Brightness on a Switch or Speaker service.
        var brightness = false
        var excludeAirPlay = false
        /// Seconds between polls of the LED and button lock; nil reads them on each HomeKit read.
        var heartrate: Int?
        var leds = false
        var maxFavourites = 96
        var mdns = true
        var port = 0
        /// Milliseconds after which momentary characteristics and refused writes are put back.
        var resetTimeout = 500
        var service = ServiceKind.switch
        var speakers = false
        /// Seconds a GENA subscription lasts before it is renewed.
        var subscriptionTimeout = 30 * 60
        /// Seconds an HTTP request to a player may take, and the wait for a subscription's first event.
        var timeout = 15
        var tv = false
        var tvIdPrefix = "TV"
        var warnings: [String] = []

        init() {}

        init(_ configuration: Configuration) {
            warnings = configuration.warnings
            func clamped(_ value: Int?, _ range: ClosedRange<Int>, _ key: String) -> Int? {
                guard let value else { return nil }
                let result = min(max(value, range.lowerBound), range.upperBound)
                if result != value { warnings.append("config.json: \(key): \(value): clamped to \(result)") }
                return result
            }
            alarms = configuration.alarms ?? false
            brightness = configuration.brightness ?? false
            excludeAirPlay = configuration.excludeAirPlay ?? false
            heartrate = clamped(configuration.heartrate, 1...60, "heartrate")
            leds = configuration.leds ?? false
            maxFavourites = clamped(configuration.maxFavourites, 16...96, "maxFavourites") ?? 96
            mdns = configuration.mdns ?? true
            // A port below 1025 is the system's: one the OS chooses instead.
            port = clamped(configuration.port, 0...65535, "port").map { $0 <= 1024 ? 0 : $0 } ?? 0
            // Milliseconds, without the Homebridge plugin's 60 ms cap (its default of 500 was outside its own range).
            resetTimeout = clamped(configuration.resetTimeout, 1...60000, "resetTimeout") ?? 500
            service = configuration.service.flatMap(ServiceKind.init(rawValue:)) ?? .switch
            speakers = configuration.speakers ?? false
            subscriptionTimeout = (clamped(configuration.subscriptionTimeout, 1...1440, "subscriptionTimeout") ?? 30) * 60
            timeout = clamped(configuration.timeout, 1...60, "timeout") ?? 15
            tv = configuration.tv ?? false
            tvIdPrefix = configuration.tvIdPrefix ?? "TV"
            if brightness, service == .light || service == .fan {
                warnings.append("config.json: ignoring brightness for service \(service.rawValue)")
                brightness = false
            }
        }

        /// `resetTimeout`, times the tests' scale.
        func reset(timeScale: Double) -> Duration { .milliseconds(Double(resetTimeout) * timeScale) }
    }
}
