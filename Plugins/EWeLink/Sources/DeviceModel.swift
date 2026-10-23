import Foundation
import HomeswiftPlugin

/// A device's state as eWeLink reports it (`params`): any JSON, keyed by parameter name.
typealias DeviceParams = [String: JSONValue]

/// A device from the eWeLink cloud, kept as the JSON the API sent so nothing is lost when it is cached or
/// shown; the accessors read the fields the plugin uses.
struct EWeLinkDevice: Sendable, Equatable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        raw = object
    }

    var deviceid: String { raw["deviceid"]?.jsString ?? "" }
    var name: String {
        get { raw["name"]?.jsString ?? deviceid }
        set { raw["name"] = .string(newValue) }
    }
    var extra: [String: JSONValue] { raw["extra"]?.objectValue ?? [:] }
    /// The eWeLink model type; 0 when missing.
    var uiid: Int { extra["uiid"]?.jsNumber.map { Int($0) } ?? 0 }
    var model: String? { extra["model"]?.stringValue }
    var brandName: String? { raw["brandName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var productModel: String? { raw["productModel"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var apikey: String { raw["apikey"]?.stringValue ?? "" }
    var devicekey: String { raw["devicekey"]?.stringValue ?? "" }
    var localtype: Int? { raw["localtype"]?.jsNumber.map { Int($0) } }
    var ip: String? { raw["ip"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var port: Int? { raw["port"]?.jsNumber.map { Int($0) }.flatMap { $0 == 0 ? nil : $0 } }
    var firmware: String? { params["fwVersion"]?.stringValue }

    /// `true` unless the cloud said otherwise.
    var online: Bool {
        get { raw["online"]?.boolValue ?? true }
        set { raw["online"] = .bool(newValue) }
    }

    var params: DeviceParams {
        get { raw["params"]?.objectValue ?? [:] }
        set { raw["params"] = .object(newValue) }
    }

    /// The RF remotes and sensors an RF Bridge learned (`tags.zyx_info`).
    var rfDevices: [RFDeviceInfo] {
        (raw["tags"]?["zyx_info"]?.arrayValue ?? []).compactMap(RFDeviceInfo.init)
    }

    var json: JSONValue { .object(raw) }
}

/// One remote or sensor learned by an RF Bridge.
struct RFDeviceInfo: Sendable, Equatable {
    var name: String
    /// `1`-`4` buttons, `5` curtain, `6` motion sensor, `7` contact sensor.
    var remoteType: String
    /// Channel number to button name, in the order the bridge lists them.
    var buttons: [(channel: String, name: String)]

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        name = object["name"]?.jsString ?? "RF Device"
        remoteType = object["remote_type"]?.jsString ?? ""
        // `buttonName` is a list of one-key objects: [{"0": "Button 1"}, {"1": "Button 2"}].
        var buttons: [(String, String)] = []
        for entry in object["buttonName"]?.arrayValue ?? [] {
            for (channel, label) in (entry.objectValue ?? [:]).sorted(by: { $0.key.jsKeyOrder < $1.key.jsKeyOrder }) {
                if let index = buttons.firstIndex(where: { $0.0 == channel }) {
                    buttons[index] = (channel, label.jsString ?? channel)
                } else {
                    buttons.append((channel, label.jsString ?? channel))
                }
            }
        }
        // JavaScript objects list integer keys in ascending order, whatever order they were added in.
        self.buttons = buttons.sorted { $0.0.jsKeyOrder < $1.0.jsKeyOrder }
    }

    static func == (lhs: RFDeviceInfo, rhs: RFDeviceInfo) -> Bool {
        lhs.name == rhs.name && lhs.remoteType == rhs.remoteType && lhs.buttons.map(\.channel) == rhs.buttons.map(\.channel)
            && lhs.buttons.map(\.name) == rhs.buttons.map(\.name)
    }
}

extension String {
    /// The order JavaScript gives an object's keys: integer keys first, ascending; others after.
    var jsKeyOrder: Int { Int(self).map { $0 >= 0 ? $0 : Int.max } ?? Int.max }
}

// MARK: JavaScript's conversions

extension JSONValue {
    /// `String(value)` for scalars.
    var jsString: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.jsDescription
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array, .object: nil
        }
    }

    /// `parseFloat(String(value))`: the leading number of the text, nil for NaN.
    var jsParseFloat: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Self.leadingNumber(value, allowFraction: true)
        default: nil
        }
    }

    /// `parseInt(String(value), 10)`, nil for NaN.
    var jsParseInt: Int? {
        switch self {
        case .number(let value): value.isFinite ? Int(value.rounded(.towardZero)) : nil
        case .string(let value): Self.leadingNumber(value, allowFraction: false).map { Int($0) }
        default: nil
        }
    }

    /// `Number(value)`, nil for NaN.
    var jsNumber: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .null: return 0
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            return Double(trimmed)
        case .array, .object: return nil
        }
    }

    private static func leadingNumber(_ text: String, allowFraction: Bool) -> Double? {
        let scalars = Array(text.drop { $0.isWhitespace }.unicodeScalars)
        var end = 0
        if end < scalars.count, scalars[end] == "-" || scalars[end] == "+" { end += 1 }
        var digits = 0
        while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1; digits += 1 }
        if allowFraction, end < scalars.count, scalars[end] == "." {
            end += 1
            while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if allowFraction, end < scalars.count, scalars[end] == "e" || scalars[end] == "E" {
            var exponentEnd = end + 1
            if exponentEnd < scalars.count, scalars[exponentEnd] == "-" || scalars[exponentEnd] == "+" { exponentEnd += 1 }
            let start = exponentEnd
            while exponentEnd < scalars.count, ("0"..."9").contains(scalars[exponentEnd]) { exponentEnd += 1 }
            if exponentEnd > start { end = exponentEnd }
        }
        return Double(String(String.UnicodeScalarView(scalars[0..<end])))
    }

    /// A number as JSON: integers without a fraction.
    init(_ number: Double) { self = .number(number) }
    init(_ number: Int) { self = .number(Double(number)) }
}

extension Double {
    /// How JavaScript prints a number: `25`, not `25.0`.
    var jsDescription: String {
        if isFinite, rounded() == self, abs(self) < 1e15 { return String(Int64(self)) }
        return String(self)
    }
}

// MARK: Reading parameters

extension Dictionary where Key == String, Value == JSONValue {
    /// Merges an update into the stored parameters, as `Object.assign` does.
    mutating func merge(_ update: DeviceParams) {
        for (key, value) in update { self[key] = value }
    }

    /// The `switches` array of a multi-channel device: `[{outlet, switch}]`.
    var switches: [JSONValue]? { self["switches"]?.arrayValue }

    /// The state of one outlet of `switches`.
    func outletSwitch(_ outlet: Int) -> JSONValue? {
        switches?.first { $0["outlet"]?.jsNumber == Double(outlet) }?["switch"]
    }
}

/// `'on'` or the JSON boolean `true` (some Zigbee devices, e.g. the SWV-BSP valve, report a boolean).
func isOn(_ value: JSONValue?) -> Bool {
    switch value {
    case .string(let text): text == "on"
    case .bool(let flag): flag
    default: false
    }
}

func onOff(_ on: Bool) -> JSONValue { .string(on ? "on" : "off") }
