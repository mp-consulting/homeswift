import Foundation
import HomeswiftPlugin

/// One value of a capability's attribute, as SmartThings reports it in a status (docs/clean-room/SmartThings.md, 4.3):
/// `{ "value": …, "unit"?: "…", "timestamp": "…" }`.
struct AttributeValue: Sendable, Equatable {
    var value: JSONValue
    var unit: String?
    var timestamp: Date?

    init(value: JSONValue, unit: String? = nil, timestamp: Date? = nil) {
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        value = json["value"] ?? .null
        unit = json["unit"]?.stringValue
        timestamp = json["timestamp"]?.stringValue.flatMap(SmartThingsDates.parse)
    }
}

enum SmartThingsDates {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// A device's state: component, capability, attribute (`components.<c>.<cap>.<attr>`), and its health.
struct DeviceStatus: Sendable, Equatable {
    var components: [String: [String: [String: AttributeValue]]] = [:]
    /// `ONLINE`, `OFFLINE` or `UNKNOWN`; nil when SmartThings said nothing.
    var health: String?

    func attribute(_ component: String, _ capability: String, _ attribute: String) -> AttributeValue? {
        components[component]?[capability]?[attribute]
    }

    /// The value, nil for a missing or null one.
    func value(_ component: String, _ capability: String, _ attribute: String) -> JSONValue? {
        self.attribute(component, capability, attribute)?.value.nonNull
    }

    func string(_ component: String, _ capability: String, _ attribute: String) -> String? {
        guard let value = value(component, capability, attribute) else { return nil }
        if let text = value.stringValue { return text }
        if let flag = value.boolValue { return flag ? "true" : "false" }
        if let number = value.doubleValue { return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number) }
        return nil
    }

    func number(_ component: String, _ capability: String, _ attribute: String) -> Double? {
        guard let value = value(component, capability, attribute) else { return nil }
        if let number = value.doubleValue, number.isFinite { return number }
        if let text = value.stringValue, let number = Double(text), number.isFinite { return number }
        return nil
    }

    func strings(_ component: String, _ capability: String, _ attribute: String) -> [String]? {
        value(component, capability, attribute)?.arrayValue?.compactMap(\.stringValue)
    }

    func unit(_ component: String, _ capability: String, _ attribute: String) -> String? {
        self.attribute(component, capability, attribute)?.unit
    }

    mutating func set(_ component: String, _ capability: String, _ attribute: String, _ value: AttributeValue) {
        components[component, default: [:]][capability, default: [:]][attribute] = value
    }

    /// The statuses `GET devices?includeStatus=true` embeds in each capability reference.
    init(listed device: JSONValue) {
        for component in device["components"]?.arrayValue ?? [] {
            guard let id = component["id"]?.stringValue else { continue }
            for capability in component["capabilities"]?.arrayValue ?? [] {
                guard let capabilityID = capability["id"]?.stringValue, let status = capability["status"]?.objectValue else { continue }
                for (name, json) in status { if let value = AttributeValue(json: json) { set(id, capabilityID, name, value) } }
            }
        }
        health = device["healthState"]?["state"]?.stringValue
    }

    /// `GET devices/{id}/status`: `{ "components": { "<c>": { "<cap>": { "<attr>": {…} } } }, "healthState"? }`.
    init(status json: JSONValue) {
        for (component, capabilities) in json["components"]?.objectValue ?? [:] {
            for (capability, attributes) in capabilities.objectValue ?? [:] {
                for (name, value) in attributes.objectValue ?? [:] {
                    if let attribute = AttributeValue(json: value) { set(component, capability, name, attribute) }
                }
            }
        }
        health = json["healthState"]?["state"]?.stringValue
    }

    init() {}
}

/// A component of a device: its capabilities (ids) and categories.
struct DeviceComponent: Sendable, Equatable {
    var id: String
    var label: String?
    var capabilities: [String]
    var versions: [String: Int]
    var categories: [String]

    func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// A SmartThings device as `GET devices` lists it, with what the plugin reads (section 4.3).
struct SmartThingsDevice: Sendable, Equatable {
    var deviceID: String
    var label: String?
    var name: String?
    var manufacturerName: String?
    var presentationID: String?
    var manufacturerCode: String?
    var locationID: String?
    var roomID: String?
    var type: String?
    var components: [DeviceComponent]
    var parentDeviceID: String?
    var childDeviceIDs: [String]
    var matter: JSONValue?
    var ocf: JSONValue?
    var viper: JSONValue?
    var allowed: [String]?
    var raw: JSONValue

    init?(_ json: JSONValue) {
        guard let id = json["deviceId"]?.stringValue, !id.isEmpty else { return nil }
        deviceID = id
        label = json["label"]?.stringValue
        name = json["name"]?.stringValue
        manufacturerName = json["manufacturerName"]?.stringValue
        presentationID = json["presentationId"]?.stringValue
        manufacturerCode = json["deviceManufacturerCode"]?.stringValue
        locationID = json["locationId"]?.stringValue
        roomID = json["roomId"]?.stringValue
        type = json["type"]?.stringValue
        components = (json["components"]?.arrayValue ?? []).compactMap { component in
            guard let id = component["id"]?.stringValue else { return nil }
            var ids: [String] = []
            var versions: [String: Int] = [:]
            for capability in component["capabilities"]?.arrayValue ?? [] {
                guard let capabilityID = capability["id"]?.stringValue else { continue }
                ids.append(capabilityID)
                versions[capabilityID] = capability["version"]?.saturatingIntValue ?? 1
            }
            let categories = (component["categories"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            return DeviceComponent(id: id, label: component["label"]?.stringValue, capabilities: ids, versions: versions, categories: categories)
        }
        // `main` first, the others in the device's order (section 7.1).
        if let main = components.firstIndex(where: { $0.id == "main" }), main != 0 { components.insert(components.remove(at: main), at: 0) }
        parentDeviceID = json["parentDeviceId"]?.stringValue
        childDeviceIDs = (json["childDevices"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        matter = json["matter"]?.nonNull
        ocf = json["ocf"]?.nonNull
        viper = json["viper"]?.nonNull
        allowed = json["allowed"]?.arrayValue?.compactMap(\.stringValue)
        raw = json
    }

    /// The person's name for it, else the integration's, else "SmartThings device" (sections 4.3 and 14.21).
    var displayName: String {
        for candidate in [label, name] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return "SmartThings device"
    }

    var manufacturer: String { manufacturerName.flatMap { $0.isEmpty ? nil : $0 } ?? "SmartThings" }

    var model: String {
        let candidates = [ocf?["modelNumber"]?.stringValue, viper?["modelName"]?.stringValue, manufacturerCode]
        return candidates.lazy.compactMap { $0 }.first { !$0.isEmpty } ?? "SmartThings device"
    }

    var firmware: String? {
        let candidates = [ocf?["firmwareVersion"]?.stringValue, viper?["swVersion"]?.stringValue, matter?["version"]?["softwareLabel"]?.stringValue]
        return candidates.lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    var main: DeviceComponent? { components.first { $0.id == "main" } }
    var mainCategory: String? { main?.categories.first }

    func component(_ id: String) -> DeviceComponent? { components.first { $0.id == id } }

    /// Whether any component has the capability.
    func has(_ capability: String) -> Bool { components.contains { $0.has(capability) } }

    /// The person may control it: `allowed`, when SmartThings lists it, has `x:devices`.
    var isControllable: Bool {
        guard let allowed else { return true }
        return allowed.contains("x:devices")
    }

    var isHub: Bool { type == "HUB" || raw["hub"]?.nonNull != nil }
    var isMatter: Bool { type == "MATTER" }
}

/// A command for `POST devices/{id}/commands`.
struct DeviceCommand: Sendable, Equatable {
    var component: String
    var capability: String
    var command: String
    var arguments: [JSONValue]

    init(_ component: String, _ capability: String, _ command: String, _ arguments: [JSONValue] = []) {
        self.component = component
        self.capability = capability
        self.command = command
        self.arguments = arguments
    }

    var json: JSONValue {
        ["component": .string(component), "capability": .string(capability), "command": .string(command), "arguments": .array(arguments)]
    }
}

/// A SmartThings scene (section 4.4).
struct SmartThingsScene: Sendable, Equatable {
    var id: String
    var name: String

    init?(_ json: JSONValue) {
        guard let id = json["sceneId"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["sceneName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "SmartThings scene"
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A device event from the SSE stream (section 5.1).
struct DeviceEvent: Sendable, Equatable {
    var deviceID: String
    var component: String
    var capability: String
    var attribute: String
    var value: JSONValue
    var stateChange: Bool
    var time: Date?

    init?(_ json: JSONValue) {
        let event = json["deviceEvent"] ?? json
        guard let deviceID = event["deviceId"]?.stringValue, let capability = event["capability"]?.stringValue,
              let attribute = event["attribute"]?.stringValue else { return nil }
        self.deviceID = deviceID
        component = event["componentId"]?.stringValue ?? "main"
        self.capability = capability
        self.attribute = attribute
        value = event["value"] ?? .null
        stateChange = event["stateChange"]?.boolValue ?? true
        time = json["eventTime"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    init(deviceID: String, component: String, capability: String, attribute: String, value: JSONValue, stateChange: Bool = true) {
        self.deviceID = deviceID
        self.component = component
        self.capability = capability
        self.attribute = attribute
        self.value = value
        self.stateChange = stateChange
        time = nil
    }
}

/// Typographic quotes made plain, case and spaces at the ends left out: how names in `IgnoreDevices` and
/// `ShowOnlyDevices` are compared (section 2.1).
func normalizedName(_ name: String) -> String {
    var text = name
    for (from, to) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
        text = text.replacingOccurrences(of: from, with: to)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
