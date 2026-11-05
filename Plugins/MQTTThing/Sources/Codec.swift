import Foundation
import HomeswiftPlugin
import Logging

/// A JSON object that keeps its keys in the order they were set, as the `json` codec writes them (section 8.3).
indirect enum OrderedJSON: Sendable, Equatable {
    case value(JSONValue)
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool { lhs.text() == rhs.text() }

    /// A configured object (`fixed`); config.json's own order is not kept by the time it is read, so its keys come sorted.
    init(_ value: JSONValue) {
        if let object = value.objectValue {
            self = .object(object.keys.sorted().map { ($0, OrderedJSON(object[$0] ?? .null)) })
        } else {
            self = .value(value)
        }
    }

    /// Sets `value` at the dotted path, making the objects on the way.
    mutating func set(_ path: [String], to value: JSONValue) {
        guard let key = path.first else {
            self = .value(value)
            return
        }
        var entries: [(key: String, value: OrderedJSON)] = if case .object(let existing) = self { existing } else { [] }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value.set(Array(path.dropFirst()), to: value)
        } else {
            var child = OrderedJSON.object([])
            child.set(Array(path.dropFirst()), to: value)
            entries.append((key, child))
        }
        self = .object(entries)
    }

    func text() -> String {
        switch self {
        case .value(let value): value.text()
        case .object(let entries): "{" + entries.map { JSONValue.string($0.key).text() + ":" + $0.value.text() }.joined(separator: ",") + "}"
        }
    }
}

/// `jsonCodec` (section 8.3).
struct JSONCodecSettings: Sendable {
    var properties: [String: [String]]
    var fixed: JSONValue?
    var fixedByTopic: [String: JSONValue]
    var retain: Bool
    var diag: Bool
    /// Off when the block names another codec, which is JavaScript.
    init?(_ config: Config, logger: Logger) {
        guard let name = config.string("codec"), !name.isEmpty else { return nil }
        guard name == "json" || name == "json.js" else {
            logger.warning("\(config.name): the codec \(name) is JavaScript, which Homeswift does not run; continuing without a codec (only the built-in json codec is supported)")
            return nil
        }
        guard let settings = config["jsonCodec"]?.objectValue else {
            logger.warning("\(config.name): add jsonCodec object to configuration")
            properties = [:]
            fixed = nil
            fixedByTopic = [:]
            retain = false
            diag = false
            return
        }
        var paths: [String: [String]] = [:]
        for (property, path) in settings["properties"]?.objectValue ?? [:] {
            if let text = path.stringValue, !text.isEmpty { paths[property] = text.split(separator: ".").map(String.init) }
        }
        properties = paths
        fixed = settings["fixed"]
        fixedByTopic = settings["fixedByTopic"]?.objectValue ?? [:]
        retain = settings["retain"]?.boolValue ?? false
        diag = settings["diag"]?.boolValue ?? false
    }

    static let delay: Duration = .milliseconds(50)
}

extension Thing {
    /// The value at the property's path in a JSON payload; nil drops the message.
    func codecDecode(_ codec: JSONCodecSettings, property: String, message: JSONValue) -> JSONValue? {
        guard let path = codec.properties[property] else {
            if codec.diag || logMqtt { logger.info("json codec: no path for property \(property); message dropped") }
            return nil
        }
        let json: JSONValue? = if case .string(let text) = message { try? JSONValue(string: text) } else { message }
        var value = json
        for key in path { value = value?[key] }
        if codec.diag { logger.info("json codec: decode \(property) = \(value.map(JS.text) ?? "nothing")") }
        guard let value, value != .null else { return nil }
        return value
    }

    /// Sets the property in the topic's pending message, published 50 ms after the last change.
    func codecEncode(_ codec: JSONCodecSettings, topic: String, property: String, value: JSONValue) {
        guard let path = codec.properties[property] else {
            if codec.diag || logMqtt { logger.info("json codec: no path for property \(property); nothing published") }
            return
        }
        var message = codecPending[topic] ?? codecRetained[topic] ?? OrderedJSON(codec.fixedByTopic[topic] ?? codec.fixed ?? .object([:]))
        message.set(path, to: value)
        codecPending[topic] = message
        after("codec-\(topic)", dependencies.codecDelay, scaled: false) {
            guard let pending = self.codecPending.removeValue(forKey: topic) else { return }
            if codec.retain { self.codecRetained[topic] = pending }
            if codec.diag { self.logger.info("json codec: encode \(topic) = \(pending.text())") }
            self.publish(topic: topic, payload: pending.text())
        }
    }
}
