import Foundation
import HomeswiftPlugin

/// A value definition of a model: what a key of the device's state holds.
enum ModelValue: Sendable, Equatable {
    /// Option key to label (a string, sometimes a number).
    case enumeration(options: [String: JSONValue])
    case range(min: Double?, max: Double?, step: Double)
    /// Start bit to its values.
    case bit(options: [String: JSONValue])
    case reference(JSONValue?)
    case stringComment(String)

    var options: [String: JSONValue] {
        switch self {
        case .enumeration(let options), .bit(let options): options
        default: [:]
        }
    }
}

/// A device's model JSON (from `modelJsonUri`): its value definitions, the ThinQ1 monitoring protocol and
/// labels. ThinQ2 models list `Value`; older ones `MonitoringValue` with value mappings.
struct DeviceModel: Sendable {
    let data: JSONValue

    init(_ data: JSONValue) {
        self.data = data
    }

    var monitoringValue: [String: JSONValue]? { data["MonitoringValue"]?.objectValue }

    /// The definition of a key, following a ThinQ2 model's `Monitoring.protocol` mapping (an object, or a list
    /// of `superSet` entries) when the key is not a value name itself.
    func value(_ name: String) -> ModelValue? {
        guard let values = data["Value"]?.objectValue else { return nil }
        var definition = values[name]
        if definition == nil, data["Monitoring"]?["type"]?.stringValue == "THINQ2", let monitoringProtocol = data["Monitoring"]?["protocol"] {
            if let mapping = monitoringProtocol.objectValue, let mapped = mapping[name] {
                definition = values[JS.string(mapped)]
            } else if let entries = monitoringProtocol.arrayValue, let entry = entries.first(where: { $0["superSet"]?.stringValue == name }) {
                definition = values[JS.string(entry["value"])]
            }
        }
        guard let definition else { return nil }
        let type = (definition["type"].flatMap { JS.truthy($0) ? $0 : nil } ?? definition["data_type"]).map { JS.string($0) } ?? "undefined"
        let option = definition["option"].flatMap { JS.truthy($0) ? $0 : nil }
        switch type.lowercased() {
        case "enum":
            return .enumeration(options: (option ?? definition["value_mapping"])?.objectValue ?? [:])
        case "range":
            let limits = option ?? definition["value_validation"]
            let step = limits?["step"].map { JS.number($0) }
            return .range(min: limits?["min"]?.doubleValue, max: limits?["max"]?.doubleValue, step: step.flatMap { $0.isNaN || $0 == 0 ? nil : $0 } ?? 1)
        case "bit":
            var bits: [String: JSONValue] = [:]
            for value in (definition["option"]?.objectValue ?? [:]).values {
                bits[JS.string(value["startbit"])] = value["values"] ?? .null
            }
            return .bit(options: bits)
        case "reference":
            guard let reference = definition["option"]?[0] else { return .reference(nil) }
            return .reference(data[JS.string(reference)])
        case "string":
            return definition["_comment"]?.stringValue.map { .stringComment($0) }
        default:
            return nil
        }
    }

    /// A key's default value.
    func defaultValue(_ name: String) -> JSONValue? {
        data["Value"]?[name]?["default"]
    }

    /// The option key whose label is `label`.
    func enumValue(_ key: String, _ label: String) -> String? {
        guard case .enumeration(let options)? = value(key) else { return nil }
        return JS.keys(options).first { options[$0]?.stringValue == label }
    }

    /// The label of an option key.
    func enumName(_ key: String, _ value: String) -> JSONValue? {
        guard case .enumeration(let options)? = self.value(key), let label = options[value], JS.truthy(label) else { return nil }
        return label
    }

    func monitoringValueMapping(_ key: String) -> [String: JSONValue]? {
        guard let monitoring = monitoringValue, let entry = monitoring[key] else { return nil }
        return entry["valueMapping"]?.objectValue
    }

    /// The label of a monitored value: from `Value` when the model has it, else `MonitoringValue`.
    func lookupMonitorValue(_ key: String, _ name: String) -> JSONValue? {
        if data["Value"] != nil { return enumName(key, name) }
        guard let mapping = monitoringValueMapping(key), let entry = mapping[name] else { return nil }
        return entry["label"].flatMap { JS.truthy($0) ? $0 : nil }
    }

    func lookupMonitorValue2(_ key: String, _ name: String, _ fallback: String) -> JSONValue {
        lookupMonitorValue(key, name) ?? .string(fallback)
    }

    /// The monitored value whose label is `label`.
    func lookupMonitorName(_ key: String, _ label: String) -> String? {
        if data["Value"] != nil { return enumValue(key, label) }
        guard let mapping = monitoringValue?[key]?["valueMapping"]?.objectValue else { return nil }
        return JS.keys(mapping).first { mapping[$0]?["label"]?.stringValue == label }
    }

    /// Decodes ThinQ1 monitoring data: by the byte layout of `Monitoring.protocol` for binary devices,
    /// as JSON otherwise. `nil` data (nothing reported yet) decodes as JavaScript decodes `{}`.
    func decodeMonitor(_ monitorData: Data?) -> [String: JSONValue] {
        switch data["Monitoring"]?["type"]?.stringValue {
        case "BINARY(BYTE)": return decodeMonitorBinary(monitorData, length: 8)
        case "BINARY(HEX)": return decodeMonitorBinary(monitorData, length: 16)
        default:
            guard let monitorData, let decoded = try? JSONValue(data: monitorData) else { return [:] }
            return decoded.objectValue ?? [:]
        }
    }

    /// Each protocol entry is `startByte`/`length` bytes, big-endian, as a string; a byte past the end makes
    /// the value null, as JavaScript's NaN did.
    private func decodeMonitorBinary(_ monitorData: Data?, length: Int) -> [String: JSONValue] {
        var decoded: [String: JSONValue] = [:]
        let bytes = monitorData.map(Array.init) ?? []
        for item in data["Monitoring"]?["protocol"]?.arrayValue ?? [] {
            let key = JS.string(item["value"])
            let start = Int(JS.number(item["startByte"]))
            let count = Int(JS.number(item["length"]))
            var value = 0.0
            guard count > 0 else { continue }
            for index in start..<(start + count) {
                let byte = index >= 0 && index < bytes.count ? Double(bytes[index]) : .nan
                value = JS.shiftLeft(value, length) + byte
                decoded[key] = value.isNaN ? .null : .string(JS.format(value))
            }
        }
        return decoded
    }
}
