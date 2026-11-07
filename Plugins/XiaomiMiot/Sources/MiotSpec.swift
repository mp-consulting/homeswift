import Foundation
import HomeswiftPlugin

// A model's MIoT instance spec, as miot-spec.org serves it (docs/clean-room/XiaomiMiot.md section 6.2), with the names
// homebridge-miot gives its properties and actions (6.3), which the options use.

/// `urn:<namespace>:<kind>:<name>:<type code>:<model>:<version>[:<extra>]`.
struct MiotURN: Sendable, Equatable {
    var namespace: String
    var kind: String
    var name: String

    init(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        namespace = parts.count > 1 ? parts[1] : ""
        kind = parts.count > 2 ? parts[2] : ""
        name = parts.count > 3 ? parts[3] : ""
    }

    /// A standard type: only `miot-spec-v2` names map generically (vendor namespaces reuse the names).
    var isStandard: Bool { namespace == "miot-spec-v2" }
}

/// A property by its service and property ids.
struct PropertyKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    var siid: Int
    var piid: Int

    var description: String { "\(siid).\(piid)" }

    static func < (a: PropertyKey, b: PropertyKey) -> Bool { (a.siid, a.piid) < (b.siid, b.piid) }

    /// `"2.7"`.
    init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count == 2, let siid = Int(parts[0]), let piid = Int(parts[1]) else { return nil }
        self.init(siid: siid, piid: piid)
    }

    init(siid: Int, piid: Int) {
        self.siid = siid
        self.piid = piid
    }
}

struct MiotSpec: Sendable, Equatable {
    struct ValueEntry: Sendable, Equatable {
        var value: JSONValue
        var description: String
    }

    struct Property: Sendable, Equatable {
        var siid: Int
        var iid: Int
        var urn: MiotURN
        var description: String
        var format: String
        var access: [String]
        var unit: String?
        /// `[min, max, step]`.
        var range: [Double]?
        var values: [ValueEntry]?
        /// homebridge-miot's name, `<service name>:<property name>` (6.3).
        var name: String

        var key: PropertyKey { PropertyKey(siid: siid, piid: iid) }
        var isReadable: Bool { access.contains("read") }
        var isWritable: Bool { access.contains("write") }
        var isBool: Bool { format == "bool" }
        var isString: Bool { format == "string" }
        var isInteger: Bool { format.hasPrefix("int") || format.hasPrefix("uint") }
        /// A value list is an enumeration even when the unit says `percentage` (6.4).
        var isList: Bool { !(values ?? []).isEmpty }
        var isRange: Bool { !isList && (range?.count ?? 0) >= 2 }
        var lower: Double? { range?.first }
        var upper: Double? { range.flatMap { $0.count > 1 ? $0[1] : nil } }
        var step: Double { range.flatMap { $0.count > 2 ? $0[2] : nil }.flatMap { $0 > 0 ? $0 : nil } ?? 1 }

        /// The values whose description is `description`, compared without spaces and case ("Go Charging" = "gocharging").
        func values(described description: String) -> [JSONValue] {
            let wanted = MiotSpec.squash(description)
            return (values ?? []).filter { MiotSpec.squash($0.description) == wanted }.map(\.value)
        }

        func value(described description: String) -> JSONValue? { values(described: description).first }

        /// The description of a value of the list.
        func description(of value: JSONValue) -> String? {
            (values ?? []).first { MiotSpec.sameValue($0.value, value) }?.description
        }

        /// A value as this property's format: a number from text, a bool from `"true"`; clamped to the range and to its
        /// step when it has one (6.4).
        func coerce(_ value: JSONValue) -> JSONValue {
            switch format {
            case "bool":
                if let bool = value.boolValue { return .bool(bool) }
                if let number = value.doubleValue { return .bool(number != 0) }
                if let text = value.stringValue?.lowercased() { return .bool(text == "true" || text == "1" || text == "on") }
                return value
            case "string":
                if let text = value.stringValue { return .string(text) }
                return .string(value.text())
            default:
                var number = value.doubleValue ?? value.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    ?? value.boolValue.map { $0 ? 1 : 0 }
                guard var raw = number else { return value }
                if isRange, let lower, let upper { raw = min(max(raw, lower), upper) }
                if isInteger { raw = raw.rounded() }
                number = raw
                return .number(raw)
            }
        }
    }

    struct Action: Sendable, Equatable {
        var siid: Int
        var iid: Int
        var urn: MiotURN
        var description: String
        var inputs: [Int]
        var outputs: [Int]
        /// `<service name>:<action name>`.
        var name: String
    }

    struct Service: Sendable, Equatable {
        var iid: Int
        var urn: MiotURN
        var description: String
        var properties: [Property]
        var actions: [Action]
        /// The name homebridge-miot gives it: the URN's name, `<name><siid>` for a second service of that name.
        var name: String

        /// A standard property of this service by its URN name.
        func property(_ name: String) -> Property? {
            properties.first { $0.urn.isStandard && $0.urn.name == name }
        }

        func action(_ name: String) -> Action? {
            actions.first { $0.urn.isStandard && $0.urn.name == name }
        }
    }

    var type: String
    var description: String
    var services: [Service]

    /// The device type: the instance URN's name (`air-purifier`, `vacuum`).
    var deviceType: String { MiotURN(type).name }

    init(json: JSONValue) throws {
        guard let type = json["type"]?.stringValue, let list = json["services"]?.arrayValue else { throw SpecError.invalid }
        self.type = type
        description = json["description"]?.stringValue ?? ""
        var services: [Service] = []
        var seenServices = Set<String>()
        for item in list {
            guard let siid = item["iid"]?.intValue, let serviceType = item["type"]?.stringValue else { continue }
            let urn = MiotURN(serviceType)
            var name = urn.name
            if urn.name != "device-information" {
                if seenServices.contains(name) { name = "\(name)\(siid)" }
                seenServices.insert(urn.name)
            }
            var properties: [Property] = []
            var seenProperties = Set<String>()
            for property in item["properties"]?.arrayValue ?? [] {
                guard let piid = property["iid"]?.intValue, let propertyType = property["type"]?.stringValue else { continue }
                let propertyURN = MiotURN(propertyType)
                var propertyName = propertyURN.name
                if seenProperties.contains(propertyName) { propertyName = "\(propertyName)\(piid)" }
                seenProperties.insert(propertyURN.name)
                let values = property["value-list"]?.arrayValue?.compactMap { entry -> ValueEntry? in
                    guard let value = entry["value"] else { return nil }
                    return ValueEntry(value: value, description: entry["description"]?.stringValue ?? "")
                }
                properties.append(Property(
                    siid: siid, iid: piid, urn: propertyURN, description: property["description"]?.stringValue ?? "",
                    format: property["format"]?.stringValue ?? "", access: property["access"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    unit: property["unit"]?.stringValue, range: property["value-range"]?.arrayValue?.compactMap(\.doubleValue),
                    values: values, name: "\(name):\(propertyName)"))
            }
            var actions: [Action] = []
            var seenActions = Set<String>()
            for action in item["actions"]?.arrayValue ?? [] {
                guard let aiid = action["iid"]?.intValue, let actionType = action["type"]?.stringValue else { continue }
                let actionURN = MiotURN(actionType)
                var actionName = actionURN.name
                if seenActions.contains(actionName) { actionName = "\(actionName)\(aiid)" }
                seenActions.insert(actionURN.name)
                actions.append(Action(
                    siid: siid, iid: aiid, urn: actionURN, description: action["description"]?.stringValue ?? "",
                    inputs: action["in"]?.arrayValue?.compactMap(\.intValue) ?? [], outputs: action["out"]?.arrayValue?.compactMap(\.intValue) ?? [],
                    name: "\(name):\(actionName)"))
            }
            services.append(Service(iid: siid, urn: urn, description: item["description"]?.stringValue ?? "", properties: properties, actions: actions, name: name))
        }
        self.services = services
    }

    enum SpecError: Error, CustomStringConvertible {
        case invalid
        var description: String { "the spec is not an instance spec" }
    }

    // MARK: Lookups

    /// The standard services of a name, by siid.
    func services(_ name: String) -> [Service] {
        services.filter { $0.urn.isStandard && $0.urn.name == name }.sorted { $0.iid < $1.iid }
    }

    func service(_ name: String) -> Service? { services(name).first }

    func service(siid: Int) -> Service? { services.first { $0.iid == siid } }

    /// A standard property `service:property` (both standard).
    func property(_ service: String, _ property: String) -> Property? {
        self.service(service)?.property(property)
    }

    func property(_ key: PropertyKey) -> Property? {
        service(siid: key.siid)?.properties.first { $0.iid == key.piid }
    }

    /// A property by homebridge-miot's name (`fan:anion`, any namespace: the names leave it out) or by `siid.piid`.
    func property(named reference: String) -> Property? {
        if let key = PropertyKey(reference) { return property(key) }
        return services.lazy.flatMap(\.properties).first { $0.name == reference }
    }

    /// An action by name (`filter:reset-filter-life`) or `siid.aiid`.
    func action(named reference: String) -> Action? {
        if let key = PropertyKey(reference) {
            return service(siid: key.siid)?.actions.first { $0.iid == key.piid }
        }
        return services.lazy.flatMap(\.actions).first { $0.name == reference }
    }

    /// A property of any namespace by its URN name, in a service of any namespace by its URN name: homebridge-miot's
    /// lookups by name, for the vendor properties some controls write (`swing-step-move`).
    func anyProperty(_ name: String, in serviceName: String? = nil) -> Property? {
        services.lazy.filter { serviceName == nil || $0.urn.name == serviceName }.flatMap(\.properties).first { $0.urn.name == name }
    }

    /// The main service (6.5): the standard service named as the device type; the lowest `switch` of an outlet or a
    /// switch; else the lowest service other than the device information.
    var mainService: Service? {
        let type = deviceType
        if let named = service(type) { return named }
        if type == "outlet" || type == "switch", let first = service("switch") { return first }
        return services.filter { $0.urn.name != "device-information" }.min { $0.iid < $1.iid }
    }

    /// Every property and action of the device but its information service.
    var readableProperties: [Property] {
        services.filter { $0.urn.name != "device-information" }.flatMap(\.properties).filter(\.isReadable)
    }

    static func squash(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func sameValue(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.doubleValue ?? a.boolValue.map({ $0 ? 1 : 0 }), let y = b.doubleValue ?? b.boolValue.map({ $0 ? 1 : 0 }) { return x == y }
        return a == b
    }
}

extension MiotSpec {
    /// The Device Kind of a device type (`x-kinds` in the schema).
    static func kind(deviceType: String) -> String {
        switch deviceType {
        case "light": "light"
        case "outlet": "outlet"
        case "switch": "switch"
        case "air-purifier": "airPurifier"
        case "humidifier": "humidifier"
        case "dehumidifier": "dehumidifier"
        case "fan": "fan"
        case "ceiling-fan": "ceilingFan"
        case "heater": "heater"
        case "air-conditioner": "airConditioner"
        case "curtain", "window-opener", "motor-controller": "curtain"
        case "temperature-humidity-sensor": "sensor"
        case "air-monitor": "airMonitor"
        case "vacuum": "vacuum"
        default: "other"
        }
    }

    /// The Device Kind from a model's middle segment, when no spec is cached (section 3.5).
    static func kind(model: String) -> String {
        let parts = model.split(separator: ".")
        guard parts.count >= 2 else { return "other" }
        switch parts[1] {
        case "light": return "light"
        case "plug", "outlet": return "outlet"
        case "switch": return "switch"
        case "airpurifier", "airp": return "airPurifier"
        case "humidifier": return "humidifier"
        case "derh": return "dehumidifier"
        case "fan": return "fan"
        case "heater": return "heater"
        case "aircondition", "airc": return "airConditioner"
        case "curtain": return "curtain"
        case "sensor_ht": return "sensor"
        case "airmonitor", "airm": return "airMonitor"
        case "vacuum": return "vacuum"
        default: return "other"
        }
    }

    /// The legacy miIO vacuums (section 8.1 rule 1): the Roborock miIO family.
    static func isLegacyVacuum(model: String) -> Bool {
        model.hasPrefix("rockrobo.vacuum.") || model.hasPrefix("roborock.vacuum.")
    }

    /// Models homebridge-miot marks as needing the cloud that are not vacuums (section 10): out of scope.
    static let cloudOnlyModels: Set<String> = [
        "yeelink.light.color1", "yeelink.light.color2", "yeelink.light.color3", "yeelink.light.color4", "yeelink.light.color5",
        "chuangmi.plug.m1", "chuangmi.plug.v1", "chuangmi.plug.v3",
        "zhimi.airpurifier.m1", "zhimi.airpurifier.m2", "zhimi.airpurifier.ma2", "zhimi.airpurifier.v6", "zhimi.airpurifier.v7",
        "zhimi.fan.v3", "zhimi.fan.za3", "zhimi.fan.za4", "zhimi.fan.sa1", "zhimi.humidifier.ca1", "zhimi.humidifier.cb1",
    ]

    static func needsCloud(model: String) -> Bool {
        cloudOnlyModels.contains(model) || model.hasPrefix("philips.light.")
    }

    /// Device types and models out of scope (section 10): cameras, doorbells, speakers, gateways, IR remotes.
    static let skippedDeviceTypes: Set<String> = ["camera", "video-doorbell", "speaker", "gateway"]

    static func isSkippedModel(_ model: String) -> Bool {
        model.contains(".ir.") || model.hasPrefix("miir.")
    }
}
