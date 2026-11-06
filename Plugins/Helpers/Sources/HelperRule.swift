import Foundation
import Homeswift
import HomeswiftPlugin

/// One characteristic of another accessory that a Helper reads: the accessory's id (`<platform>:<Device Id>`, stable across
/// restarts) and the characteristic's iid, which stays the same for that accessory (`aid/service/subtype/char` keys).
/// Written `<accessory id>#<iid>` in the Helper's Accessory Settings.
struct SourceRef: Sendable, Hashable, CustomStringConvertible {
    var accessoryID: String
    var iid: Int

    init(accessoryID: String, iid: Int) {
        self.accessoryID = accessoryID
        self.iid = iid
    }

    init?(_ text: String) {
        guard let mark = text.lastIndex(of: "#"), let iid = Int(text[text.index(after: mark)...]), iid > 0 else { return nil }
        let accessoryID = String(text[..<mark])
        guard !accessoryID.isEmpty else { return nil }
        self.init(accessoryID: accessoryID, iid: iid)
    }

    var description: String { "\(accessoryID)#\(iid)" }
}

/// What a Combine Helper measures: the characteristic its sources have and the sensor it is published as.
enum Measure: String, Sendable, CaseIterable {
    case temperature, humidity, lightLevel, power

    /// The characteristic its sources carry and the Helper shows.
    var characteristic: CharacteristicType {
        switch self {
        case .temperature: .currentTemperature
        case .humidity: .currentRelativeHumidity
        case .lightLevel: .currentAmbientLightLevel
        case .power: EveCharacteristic.currentConsumption
        }
    }

    /// The sensor it is published as. HomeKit has no power sensor: power is a light sensor whose level is the watts, with
    /// Eve's Current Consumption beside it, as the APsystems ECU's solar power is.
    var service: ServiceType {
        switch self {
        case .temperature: .temperatureSensor
        case .humidity: .humiditySensor
        case .lightLevel, .power: .lightSensor
        }
    }

    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .lightLevel: "Light level"
        case .power: "Power"
        }
    }
}

/// How a Combine Helper makes one value of its sources'.
enum Function: String, Sendable, CaseIterable {
    case min, max, average

    func apply(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        switch self {
        case .min: return values.min()
        case .max: return values.max()
        case .average: return values.reduce(0, +) / Double(values.count)
        }
    }

    var title: String {
        switch self {
        case .min: "Lowest"
        case .max: "Highest"
        case .average: "Average"
        }
    }
}

/// A Helper's rule, read from its Accessory Settings (GLOSSARY.md, "Helper"). Its kind is its Device Kind.
enum HelperRule: Sendable, Equatable {
    /// On when the source goes above `on` (or below, `above` false), off again once it is back past `off`: the gap between
    /// them (hysteresis) keeps a reading hovering at the line from turning it on and off.
    case threshold(source: SourceRef, above: Bool, on: Double, off: Double)
    /// The lowest, highest or average of several sources of one measure.
    case combine(measure: Measure, function: Function, sources: [SourceRef])
    /// On while the source has been at `state` for `minutes` or longer.
    case stays(source: SourceRef, state: Double, minutes: Double)

    enum Kind: String, Sendable, CaseIterable {
        case threshold, combine, stays

        var title: String {
            switch self {
            case .threshold: "Threshold"
            case .combine: "Combine"
            case .stays: "Stays"
            }
        }

        var detail: String {
            switch self {
            case .threshold: "On when a reading goes above or below a value"
            case .combine: "The lowest, highest or average of several sensors"
            case .stays: "On when something stays in a state for a while"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .threshold: .threshold
        case .combine: .combine
        case .stays: .stays
        }
    }

    var sources: [SourceRef] {
        switch self {
        case .threshold(let source, _, _, _), .stays(let source, _, _): [source]
        case .combine(_, _, let sources): sources
        }
    }

    /// The rule of a Helper's Accessory Settings; throws what is wrong, for its log line.
    init(settings: [String: JSONValue]) throws {
        guard let kind = settings["rule"]?.stringValue.flatMap(Kind.init(rawValue:)) else { throw RuleError("has no rule (threshold, combine or stays)") }
        func source(_ key: String = "source") throws -> SourceRef {
            guard let source = settings[key]?.stringValue.flatMap(SourceRef.init) else { throw RuleError("has no source") }
            return source
        }
        func number(_ key: String) -> Double? { settings[key]?.doubleValue ?? settings[key]?.stringValue.flatMap(Self.number) }
        switch kind {
        case .threshold:
            guard let on = number("on") else { throw RuleError("has no on value") }
            let above = settings["direction"]?.stringValue != "below"
            let off = number("off") ?? on
            try Self.checkHysteresis(above: above, on: on, off: off)
            self = .threshold(source: try source(), above: above, on: on, off: off)
        case .combine:
            guard let measure = settings["measure"]?.stringValue.flatMap(Measure.init(rawValue:)) else { throw RuleError("has no measure") }
            let function = settings["function"]?.stringValue.flatMap(Function.init(rawValue:)) ?? .average
            let sources = (settings["sources"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(SourceRef.init) }
            guard !sources.isEmpty else { throw RuleError("has no sources") }
            self = .combine(measure: measure, function: function, sources: sources)
        case .stays:
            guard let state = number("state") else { throw RuleError("has no state") }
            guard let minutes = number("minutes"), minutes >= 0 else { throw RuleError("has no duration") }
            self = .stays(source: try source(), state: state, minutes: minutes)
        }
    }

    /// A number as a person types it: a comma for the decimal point taken too.
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }

    /// The off value must be on the far side of the on value, or the Helper would never turn off.
    static func checkHysteresis(above: Bool, on: Double, off: Double) throws {
        if above, off > on { throw RuleError("turns off above where it turns on: the off value must be at most the on value") }
        if !above, off < on { throw RuleError("turns off below where it turns on: the off value must be at least the on value") }
    }

    /// The Threshold's next state from a reading: on past `on`, off past `off`, else as it was.
    static func threshold(was: Bool, value: Double, above: Bool, on: Double, off: Double) -> Bool {
        if above {
            if value > on { return true }
            if value < off { return false }
        } else {
            if value < on { return true }
            if value > off { return false }
        }
        return was
    }
}

struct RuleError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
