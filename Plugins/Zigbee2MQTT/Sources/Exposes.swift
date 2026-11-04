import Foundation
import HomeswiftPlugin

/// One entry of a Zigbee2MQTT device's `exposes` (4.2): what it reports and what it accepts.
struct Expose: Codable, Sendable, Equatable {
    var type: String?
    var name: String?
    var property: String?
    var endpoint: String?
    var access: Int?
    var unit: String?
    var values: [JSONValue]?
    var valueOn: JSONValue?
    var valueOff: JSONValue?
    var valueMin: Double?
    var valueMax: Double?
    var valueStep: Double?
    var features: [Expose]?

    enum CodingKeys: String, CodingKey {
        case type, name, property, endpoint, access, unit, values, features
        case valueOn = "value_on", valueOff = "value_off", valueMin = "value_min", valueMax = "value_max", valueStep = "value_step"
    }

    init(type: String? = nil, name: String? = nil, property: String? = nil, endpoint: String? = nil, access: Int? = nil, values: [JSONValue]? = nil,
         valueOn: JSONValue? = nil, valueOff: JSONValue? = nil, valueMin: Double? = nil, valueMax: Double? = nil, valueStep: Double? = nil, features: [Expose]? = nil) {
        self.type = type
        self.name = name
        self.property = property
        self.endpoint = endpoint
        self.access = access
        self.values = values
        self.valueOn = valueOn
        self.valueOff = valueOff
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.valueStep = valueStep
        self.features = features
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            switch try? container.decodeIfPresent(JSONValue.self, forKey: key) {
            case .string(let value)?: value
            case .number(let value)?: JSONValue.number(value).text()
            default: nil
            }
        }
        type = string(.type)
        name = string(.name)
        property = string(.property)
        endpoint = string(.endpoint)
        unit = string(.unit)
        access = (try? container.decodeIfPresent(JSONValue.self, forKey: .access))?.intValue
        values = try? container.decodeIfPresent([JSONValue].self, forKey: .values)
        valueOn = (try? container.decodeIfPresent(JSONValue.self, forKey: .valueOn))?.nonNull
        valueOff = (try? container.decodeIfPresent(JSONValue.self, forKey: .valueOff))?.nonNull
        valueMin = (try? container.decodeIfPresent(JSONValue.self, forKey: .valueMin))?.doubleValue
        valueMax = (try? container.decodeIfPresent(JSONValue.self, forKey: .valueMax))?.doubleValue
        valueStep = (try? container.decodeIfPresent(JSONValue.self, forKey: .valueStep))?.doubleValue
        features = try? container.decodeIfPresent([Expose].self, forKey: .features)
    }

    static let published = 1, settable = 2, gettable = 4

    var hasProperty: Bool { name != nil && property != nil && access != nil }
    var isPublished: Bool { (access ?? 0) & Self.published != 0 }
    var isSettable: Bool { (access ?? 0) & Self.settable != 0 }
    var isGettable: Bool { (access ?? 0) & Self.gettable != 0 }
    var isNumericRange: Bool { hasProperty && type == "numeric" && valueMin != nil && valueMax != nil }
    var isBinary: Bool { hasProperty && type == "binary" && valueOn != nil && valueOff != nil }
    var isEnum: Bool { hasProperty && type == "enum" && !(values ?? []).isEmpty }
    /// A range HomeKit may set and the device reports.
    var isSettableRange: Bool { isNumericRange && isPublished && isSettable }
    /// The enum's values as text.
    var valueStrings: [String] { (values ?? []).map { $0.stringValue ?? $0.text() } }

    /// The feature with this name among those that have a property.
    func feature(_ name: String) -> Expose? { features?.first { $0.name == name && $0.hasProperty } }

    /// An entry `devices[].exposes` may hold (2.7).
    static func isValidEntry(_ value: JSONValue) -> Bool {
        guard let object = value.objectValue, let type = object["type"], !type.isNull else { return false }
        if ["name", "property", "access", "endpoint", "values"].contains(where: { object[$0] != nil }) { return true }
        if object["value_on"] != nil, object["value_off"] != nil { return true }
        if object["value_min"] != nil, object["value_max"] != nil { return true }
        return object["features"]?.arrayValue != nil
    }

    // MARK: Equality and intersection (11.1, 11.2)

    /// The same entry for the group computation (11.2).
    func matches(_ other: Expose) -> Bool {
        guard type == other.type, name == other.name, property == other.property, access == other.access, endpoint == other.endpoint,
              valueMin == other.valueMin, valueMax == other.valueMax, valueOff == other.valueOff, valueOn == other.valueOn else { return false }
        let mine = values ?? [], theirs = other.values ?? []
        guard mine.count == theirs.count, mine.allSatisfy(theirs.contains) else { return false }
        switch (features, other.features) {
        case (nil, nil): return true
        case (let a?, let b?): return Self.collectionsMatch(a, b)
        default: return false
        }
    }

    static func collectionsMatch(_ a: [Expose], _ b: [Expose]) -> Bool {
        a.count == b.count && a.allSatisfy { entry in b.contains { entry.matches($0) } }
    }

    /// Without endpoints, a property taken from its name where it had one (`state_l1` is `state`), duplicates dropped.
    static func normalized(_ list: [Expose]) -> [Expose] {
        // A feature without an endpoint of its own has its parent's (7.1).
        func strip(_ entry: Expose, inherited: Bool) -> Expose {
            var entry = entry
            let hadEndpoint = entry.endpoint != nil || inherited
            if hadEndpoint, entry.property != nil, let name = entry.name { entry.property = name }
            entry.endpoint = nil
            entry.features = entry.features?.map { strip($0, inherited: hadEndpoint) }
            return entry
        }
        var result: [Expose] = []
        for entry in list.map({ strip($0, inherited: false) }) where !result.contains(where: { $0.matches(entry) }) { result.append(entry) }
        return result
    }

    /// What two members both expose, in the first one's order.
    static func intersection(_ first: [Expose], _ second: [Expose]) -> [Expose] {
        let a = normalized(first), b = normalized(second)
        return mergeAll(a, b)
    }

    private static func mergeAll(_ a: [Expose], _ b: [Expose]) -> [Expose] {
        a.compactMap { entry in
            b.first { $0.name == entry.name && $0.property == entry.property && $0.type == entry.type }.flatMap { entry.merged(with: $0) }
        }
    }

    /// The two entries in one, or nil when they cannot be (different on and off values, no enum value in common).
    func merged(with other: Expose) -> Expose? {
        var result = Expose(type: type, name: name, property: property)
        result.endpoint = endpoint == other.endpoint ? endpoint : nil
        result.access = access == other.access ? access : nil
        result.unit = unit == other.unit ? unit : nil
        result.valueStep = valueStep == other.valueStep ? valueStep : nil
        result.valueOn = valueOn == other.valueOn ? valueOn : nil
        result.valueOff = valueOff == other.valueOff ? valueOff : nil
        if type == "numeric" {
            result.valueMin = [valueMin, other.valueMin].compactMap { $0 }.max()
            result.valueMax = [valueMax, other.valueMax].compactMap { $0 }.min()
        } else {
            result.valueMin = valueMin == other.valueMin ? valueMin : nil
            result.valueMax = valueMax == other.valueMax ? valueMax : nil
        }
        if type == "binary", valueOn != other.valueOn || valueOff != other.valueOff { return nil }
        if type == "enum" {
            let common = (values ?? []).filter { (other.values ?? []).contains($0) }
            if common.isEmpty { return nil }
            result.values = common
        } else if values != nil, values == other.values {
            result.values = values
        }
        if let mine = features, let theirs = other.features { result.features = Self.mergeAll(mine, theirs) }
        return result
    }
}

// MARK: Filtering (7)

extension DeviceOptions {
    /// The exposes with the excluded keys and endpoints taken out, the endpoints inherited and the enum values filtered.
    func filter(_ exposes: [Expose], parentEndpoint: String? = nil) -> [Expose] {
        exposes.compactMap { entry -> Expose? in
            if let property = entry.property, excludedKeys.contains(property), !includedKeys.contains(property) { return nil }
            if !excludedEndpoints.isEmpty, excludedEndpoints.contains(entry.endpoint ?? "") { return nil }
            var entry = entry
            if entry.endpoint == nil { entry.endpoint = parentEndpoint }
            if let features = entry.features { entry.features = filter(features, parentEndpoint: entry.endpoint) }
            if let values = entry.values, !values.isEmpty, let property = entry.property, let rule = self.values.first(where: { $0.property == property }) {
                entry.values = values.filter { value in
                    let text = value.stringValue ?? value.text()
                    if !rule.include.isEmpty, !rule.include.contains(where: { Self.pattern($0, matches: text) }) { return false }
                    if !rule.exclude.isEmpty, rule.exclude.contains(where: { Self.pattern($0, matches: text) }) { return false }
                    return true
                }
            }
            return entry
        }
    }

    /// `*suffix`, `prefix*` or an exact value; an empty pattern never matches (7.3).
    static func pattern(_ pattern: String, matches value: String) -> Bool {
        if pattern.isEmpty { return false }
        if pattern.count >= 2, pattern.hasPrefix("*") { return value.hasSuffix(pattern.dropFirst()) }
        if pattern.count >= 2, pattern.hasSuffix("*") { return value.hasPrefix(pattern.dropLast()) }
        return value == pattern
    }
}
