import Foundation
import Homeswift
import HomeswiftPlugin

// The parts of zwave-js-server's state dump (`start_listening`) and events the plugin reads: each node with its
// device class and its values, each value by its value id (command class, endpoint, property, property key).

/// Command classes the plugin maps, by their numbers in the Z-Wave specification.
enum CommandClass {
    static let binarySwitch = 0x25
    static let multilevelSwitch = 0x26
    static let binarySensor = 0x30
    static let multilevelSensor = 0x31
    static let meter = 0x32
    static let colorSwitch = 0x33
    static let thermostatMode = 0x40
    static let thermostatOperatingState = 0x42
    static let thermostatSetpoint = 0x43
    static let centralScene = 0x5B
    static let doorLock = 0x62
    static let manufacturerSpecific = 0x72
    static let notification = 0x71
    static let battery = 0x80
}

/// A value's id: what `node.set_value` takes back, and the key values are kept by. A property or a property key is a
/// number or a string in zwave-js; both are kept as JSON so a write sends them as they came.
struct ValueID: Hashable, Sendable {
    var commandClass: Int
    var endpoint: Int
    var property: JSONValue
    var propertyKey: JSONValue?

    init(commandClass: Int, endpoint: Int = 0, property: JSONValue, propertyKey: JSONValue? = nil) {
        self.commandClass = commandClass
        self.endpoint = endpoint
        self.property = property
        self.propertyKey = propertyKey?.isNull == true ? nil : propertyKey
    }

    /// From a value's or an event's fields: `commandClass`, `endpoint`, `property`, `propertyKey`.
    init?(_ json: JSONValue) {
        guard let commandClass = json["commandClass"]?.intValue, let property = json["property"], !property.isNull else { return nil }
        self.init(commandClass: commandClass, endpoint: json["endpoint"]?.intValue ?? 0, property: property, propertyKey: json["propertyKey"])
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["commandClass": .number(Double(commandClass)), "endpoint": .number(Double(endpoint)), "property": property]
        if let propertyKey { fields["propertyKey"] = propertyKey }
        return .object(fields)
    }

    /// The property as text: a name (`currentValue`, `Air temperature`) or a number.
    var propertyText: String { Self.text(property) }
    var propertyKeyText: String? { propertyKey.map(Self.text) }

    static func text(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let number = value.intValue { return String(number) }
        return value.text()
    }

    /// The same value on another property: `targetValue` beside `currentValue`.
    func with(property: String, propertyKey: JSONValue? = nil) -> ValueID {
        ValueID(commandClass: commandClass, endpoint: endpoint, property: .string(property), propertyKey: propertyKey)
    }
}

/// One value of a node, as the state dump gives it.
struct ZValue: Sendable {
    var id: ValueID
    var value: JSONValue?
    /// `type`, `readable`, `writeable`, `label`, `min`, `max`, `unit`, `states`, `ccSpecific`.
    var metadata: JSONValue

    init?(_ json: JSONValue) {
        guard let id = ValueID(json) else { return nil }
        self.id = id
        value = json["value"]?.nonNull
        metadata = json["metadata"] ?? .null
    }

    init(id: ValueID, value: JSONValue?, metadata: JSONValue = .null) {
        self.id = id
        self.value = value
        self.metadata = metadata
    }

    var unit: String? { metadata["unit"]?.stringValue }
    /// The named states (`"0": "Off"`), by number.
    var states: [Int: String] {
        guard let states = metadata["states"]?.objectValue else { return [:] }
        return Dictionary(states.compactMap { key, label in Int(key).flatMap { number in label.stringValue.map { (number, $0) } } }, uniquingKeysWith: { first, _ in first })
    }
}

/// A node's status in zwave-js (`NodeStatus`).
enum NodeStatus: Int, Sendable {
    case unknown = 0, asleep, awake, dead, alive
}

/// One Z-Wave node, as the state dump or a `node added`/`ready` event gives it.
struct ZNode: Sendable {
    var nodeID: Int
    var name: String?
    var location: String?
    var manufacturer: String?
    /// The product's model (`ZW100`).
    var label: String?
    /// The product's description (`Multisensor 6`).
    var productDescription: String?
    var firmwareVersion: String?
    var status: NodeStatus
    var isControllerNode: Bool
    var ready: Bool
    var genericClass: Int?
    var genericLabel: String?
    var specificClass: Int?
    var specificLabel: String?
    var values: [ValueID: ZValue]

    init?(_ json: JSONValue) {
        guard let nodeID = json["nodeId"]?.intValue else { return nil }
        self.nodeID = nodeID
        name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        location = json["location"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        let config = json["deviceConfig"]
        manufacturer = config?["manufacturer"]?.stringValue?.nonEmpty ?? json["manufacturer"]?.stringValue?.nonEmpty
        label = json["label"]?.stringValue?.nonEmpty ?? config?["label"]?.stringValue?.nonEmpty
        productDescription = config?["description"]?.stringValue?.nonEmpty ?? json["productDescription"]?.stringValue?.nonEmpty
        firmwareVersion = json["firmwareVersion"]?.stringValue?.nonEmpty
        status = json["status"]?.intValue.flatMap(NodeStatus.init(rawValue:)) ?? .unknown
        isControllerNode = json["isControllerNode"]?.boolValue ?? false
        ready = json["ready"]?.boolValue ?? true
        let deviceClass = json["deviceClass"]
        genericClass = deviceClass?["generic"]?["key"]?.intValue
        genericLabel = deviceClass?["generic"]?["label"]?.stringValue
        specificClass = deviceClass?["specific"]?["key"]?.intValue
        specificLabel = deviceClass?["specific"]?["label"]?.stringValue
        var values: [ValueID: ZValue] = [:]
        for item in json["values"]?.arrayValue ?? [] {
            guard let value = ZValue(item) else { continue }
            values[value.id] = value
        }
        self.values = values
    }

    var isDead: Bool { status == .dead }

    /// Its Name until a person gives one: the name set in Z-Wave JS UI, else the product's description, else its label.
    var displayName: String { name ?? productDescription ?? label ?? "Node \(nodeID)" }

    /// The serial number the node reports (Manufacturer Specific's Device ID), if any.
    var serialNumber: String? {
        let ids = values.values.filter { $0.id.commandClass == CommandClass.manufacturerSpecific && $0.id.propertyText == "deviceId" }
        let serial = ids.first { $0.id.propertyKeyText == "SerialNumber" } ?? ids.first
        return serial?.value?.stringValue.map { String($0.filter { !$0.isASCII || ($0.asciiValue ?? 0) >= 0x20 }.prefix(64)).trimmingCharacters(in: .whitespaces) }?.nonEmpty
    }

    /// A motor's Multilevel Switch moves a cover: the generic Window Covering class, or a Motor Control specific class.
    var isCover: Bool {
        genericClass == 0x09 || (genericClass == 0x11 && [0x05, 0x06, 0x07].contains(specificClass ?? -1))
            || (specificLabel ?? "").localizedCaseInsensitiveContains("motor control")
    }

    /// A lock, a door strike or a gate: the Entry Control device class, or a node with Door Lock.
    var isEntryControl: Bool { genericClass == 0x40 || values.keys.contains { $0.commandClass == CommandClass.doorLock } }

    func values(_ commandClass: Int, endpoint: Int? = nil) -> [ZValue] {
        values.values.filter { $0.id.commandClass == commandClass && (endpoint == nil || $0.id.endpoint == endpoint) }
            .sorted { ($0.id.endpoint, $0.id.propertyText, $0.id.propertyKeyText ?? "") < ($1.id.endpoint, $1.id.propertyText, $1.id.propertyKeyText ?? "") }
    }

    func value(_ commandClass: Int, endpoint: Int, property: String, propertyKey: String? = nil) -> ZValue? {
        values.values.first {
            $0.id.commandClass == commandClass && $0.id.endpoint == endpoint && $0.id.propertyText == property && $0.id.propertyKeyText == propertyKey
        }
    }

    var endpoints: [Int] { Set(values.keys.map(\.endpoint)).sorted() }
}

extension JSONValue {
    /// A number, or a boolean as 0 and 1.
    var numberValue: Double? {
        if let number = doubleValue { return number.isFinite ? number : nil }
        if let bool = boolValue { return bool ? 1 : 0 }
        return nil
    }
}
