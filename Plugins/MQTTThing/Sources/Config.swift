import Foundation
import Homeswift
import HomeswiftPlugin

/// One accessory block, or one entry of a `custom` block over its block (section 5.33), read as JSON: the plugin reads
/// a hundred keys by name, as the Homebridge plugin does, rather than declaring them.
struct Config: Sendable {
    var values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    subscript(key: String) -> JSONValue? {
        let value = values[key]
        return value == .null ? nil : value
    }

    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let text)?: text
        case .number?, .bool?: self[key].map(JS.text)
        default: nil
        }
    }

    func flag(_ key: String) -> Bool { JS.truthy(self[key]) }
    func number(_ key: String) -> Double? { self[key]?.doubleValue ?? string(key).flatMap(Double.init) }
    /// An integer option, as the Homebridge plugin applies min/max keys "when integers".
    func integer(_ key: String) -> Int? {
        guard case .number(let number)? = self[key], number.rounded() == number, abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    func milliseconds(_ key: String) -> Duration? {
        guard let value = number(key), value > 0 else { return nil }
        return .milliseconds(Int(value))
    }

    var name: String { string("name") ?? "MQTT Thing" }
    /// The block's `type` as written (the Model).
    var rawType: String { string("type") ?? "" }
    /// The type without what follows its first `-` (`lightbulb-RGB` is `lightbulb`), except `irrigationSystem`.
    var type: String {
        let raw = rawType
        if raw == "irrigationSystem" { return raw }
        return String(raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    var topics: [String: JSONValue] { self["topics"]?.objectValue ?? [:] }
    var hasTopics: Bool { self["topics"]?.objectValue != nil }
    func has(_ topic: String) -> Bool { topics[topic].map { $0 != .null } ?? false }
    func hasAny(_ topics: String...) -> Bool { topics.contains(where: has) }
    func serviceName(_ key: String, _ fallback: String) -> String { self["serviceNames"]?[key]?.stringValue ?? fallback }
    var subtype: String? { string("subtype") }

    /// The block with an entry of a custom block laid over it: a shallow merge, the entry's `topics` replacing the block's.
    func overlaid(with entry: [String: JSONValue]) -> Config {
        var merged = values
        for (key, value) in entry { merged[key] = value }
        merged.removeValue(forKey: "services")
        return Config(merged)
    }
}

/// A topic as configured: a string, or an object with `topic` and `apply`; a get topic may end in a JSONPath query.
struct TopicSpec: Sendable, Equatable {
    var topic: String
    /// The query after the topic's `$` (get topics only).
    var path: [JSONPath.Step]?
    /// The topic object has JavaScript to run, which Homeswift cannot.
    var hasApply: Bool

    init?(_ value: JSONValue?, get: Bool) {
        var text: String
        switch value {
        case .string(let string)?: text = string
            hasApply = false
        case .object(let object)?:
            guard let string = object["topic"]?.stringValue else { return nil }
            text = string
            hasApply = object["apply"].map { $0 != .null } ?? false
        default: return nil
        }
        path = nil
        if get, let dollar = text.dropFirst().firstIndex(of: "$") {
            // A query that does not parse finds nothing: its messages are dropped.
            path = JSONPath.parse(String(text[dollar...])) ?? [.key("\u{0}")]
            text = String(text[..<dollar])
        }
        guard !text.isEmpty else { return nil }
        topic = text
    }
}
