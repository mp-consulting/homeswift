import Foundation
import HomeswiftPlugin

/// One device's options (docs/clean-room/XiaomiMiot.md sections 2.2, 2.3): its Accessory Settings over its entry of a
/// Homebridge-shaped `devices` list, read leniently. Flags that add a service default to false (15.8);
/// `childLockControl` and `showTemperature` to true.
struct DeviceOptions: Sendable, Equatable {
    var raw: [String: JSONValue]

    init(_ fields: [String: JSONValue] = [:]) {
        raw = fields
    }

    /// The legacy entry's keys, the Accessory Settings' on top.
    init(legacy: [String: JSONValue]?, settings: [String: JSONValue]) {
        raw = (legacy ?? [:]).merging(settings) { $1 }
    }

    func flag(_ key: String, default value: Bool = false) -> Bool {
        switch raw[key] {
        case .bool(let flag): flag
        case .number(let number): number != 0
        case .string(let text): text.lowercased() == "true"
        default: value
        }
    }

    var ip: String? { raw["ip"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
    var model: String? { raw["model"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
    var deviceID: String? { raw["deviceId"]?.idText }
    var name: String? { raw["name"]?.stringValue?.nonEmpty }
    var token: String? { raw["token"]?.stringValue?.nonEmpty }
    var deviceEnabled: Bool { flag("deviceEnabled", default: true) }
    var customAccessory: Bool { flag("customAccessory") }
    var onlyMainService: Bool { flag("onlyMainService") }

    /// Seconds: values below 500 are seconds, others milliseconds; under 1 s after that is ignored (section 2.2).
    var pollingInterval: Double? { Self.interval(raw["pollingInterval"]) }

    static func interval(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue ?? value?.stringValue.flatMap(Double.init), number.isFinite, number > 0 else { return nil }
        let seconds = number < 500 ? number : number / 1000
        return seconds < 1 ? nil : seconds
    }

    /// 1–14, 14 by default.
    var propertyChunkSize: Int? {
        guard let size = raw["propertyChunkSize"]?.intValue else { return nil }
        return min(max(size, 1), 14)
    }

    var micloud: [String: JSONValue] { raw["micloud"]?.objectValue ?? [:] }

    // MARK: Extra controls (2.3)

    var buzzerControl: Bool { flag("buzzerControl") }
    var ledControl: Bool { flag("ledControl") }
    var childLockControl: Bool { flag("childLockControl", default: true) }
    var modeControl: Bool { flag("modeControl") }
    var screenControl: Bool { flag("screenControl") }
    var fanLevelControl: Bool { flag("fanLevelControl") }
    var swingControl: Bool { flag("swingControl") }
    var moveControl: Bool { flag("moveControl") }
    var ioniserControl: Bool { flag("ioniserControl") }
    var offDelayControl: Bool { flag("offDelayControl") }
    var motorControl: Bool { flag("motorControl") }
    var showTemperature: Bool { flag("showTemperature", default: true) }

    /// `true`, or the angles to offer.
    func angleButtons(_ key: String) -> [Int]? {
        switch raw[key] {
        case .bool(true): []
        case .array(let items):
            items.compactMap(\.intValue).filter { (1...360).contains($0) }
        default: nil
        }
    }

    var suppressed: Set<String> { Set(raw["suppressAutoServiceCreation"]?.arrayValue?.compactMap(\.stringValue) ?? []) }

    var actionButtons: JSONValue? { raw["actionButtons"] }
    var methodButtons: [JSONValue] { raw["methodButtons"]?.arrayValue ?? [] }
    var propertyControl: [JSONValue] { raw["propertyControl"]?.arrayValue ?? [] }
    var propertyMonitor: [JSONValue] { raw["propertyMonitor"]?.arrayValue ?? [] }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension JSONValue {
    /// An id written as text or as an integer (a did, a user id, an action's `siid.aiid` as a number); nil when empty.
    var idText: String? { (stringValue ?? intValue.map(String.init))?.nonEmpty }
}
