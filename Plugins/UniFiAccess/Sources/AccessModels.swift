import Foundation
import HomeswiftPlugin

/// A device as the controller describes it (`AccessDeviceConfig`). The JSON is kept as it came, so fields the
/// plugin does not read survive for the settings page, and a firmware that adds or drops fields cannot break
/// decoding; the accessors read what the plugin needs.
struct AccessDevice: Sendable, Equatable {
    var json: [String: JSONValue]

    init(_ json: [String: JSONValue]) { self.json = json }

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else { return nil }
        json = object
    }

    struct ConfigEntry: Sendable, Equatable {
        var key: String
        var value: String
    }

    struct Extension: Sendable, Equatable {
        var extensionName: String?
        var sourceId: String?
        var targetName: String?
        var targetValue: String?
        var targetConfig: [(key: String, value: JSONValue)]?

        static func == (lhs: Extension, rhs: Extension) -> Bool {
            lhs.extensionName == rhs.extensionName && lhs.sourceId == rhs.sourceId && lhs.targetName == rhs.targetName && lhs.targetValue == rhs.targetValue
        }
    }

    private func string(_ key: String) -> String? { json[key]?.stringValue }
    private func flag(_ key: String) -> Bool? { json[key]?.boolValue }

    var alias: String? { string("alias") }
    var name: String? { string("name") }
    var mac: String { string("mac") ?? "" }
    var model: String? { string("model") }
    var displayModel: String? { string("display_model") }
    var deviceType: String { string("device_type") ?? "" }
    var uniqueId: String { string("unique_id") ?? "" }
    var sourceId: String? { string("source_id") }
    var locationId: String? { string("location_id") }
    var firmware: String? { string("firmware") }
    var ip: String? { string("ip") }
    var capabilities: [String] { json["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var isManaged: Bool { flag("is_managed") ?? false }
    var isAdopted: Bool { flag("is_adopted") ?? false }
    var isConnected: Bool { flag("is_connected") ?? false }
    var isOnline: Bool? { flag("is_online") }
    /// The door the device is bound to.
    var doorId: String? { json["door"]?["unique_id"]?.stringValue }

    var configs: [ConfigEntry]? {
        json["configs"]?.arrayValue?.compactMap { entry in
            guard let key = entry["key"]?.stringValue else { return nil }
            return ConfigEntry(key: key, value: entry["value"].map(Self.text) ?? "")
        }
    }

    var extensions: [Extension]? {
        json["extensions"]?.arrayValue?.map { value in
            Extension(
                extensionName: value["extension_name"]?.stringValue, sourceId: value["source_id"]?.stringValue, targetName: value["target_name"]?.stringValue,
                targetValue: value["target_value"]?.stringValue,
                targetConfig: value["target_config"]?.arrayValue?.compactMap { config in
                    guard let key = config["config_key"]?.stringValue else { return nil }
                    return (key, config["config_value"] ?? .null)
                })
        }
    }

    /// A config value by key.
    func config(_ key: String) -> String? { configs?.first { $0.key == key }?.value }

    /// Whether every one of these configs is `on`.
    func wiringActive(_ keys: [String]) -> Bool {
        let configs = configs
        return keys.allSatisfy { key in configs?.contains { $0.key == key && $0.value == "on" } ?? false }
    }

    func has(capability: String) -> Bool { capabilities.contains(capability) }
    func has(anyCapability: [String]) -> Bool { anyCapability.contains { capabilities.contains($0) } }

    /// Every one of adopted, connected, managed and online.
    var isFullyOnline: Bool { isAdopted && isConnected && isManaged && (isOnline ?? false) }

    var catalog: DeviceCatalogEntry? { DeviceCatalog.entry(deviceType) }

    /// The device's id in feature options and MQTT topics.
    var identifier: String { DeviceCatalog.deviceIdentifier(deviceType: deviceType, mac: mac, sourceId: sourceId) }

    /// A hub or a reader: what the plugin supports.
    var isSupported: Bool { has(capability: "is_hub") || has(capability: "is_reader") }

    /// The name to give it: its alias, its name, its model.
    var resolvedName: String {
        if let alias, !alias.isEmpty { return alias }
        return name ?? displayModel ?? model ?? (deviceType.isEmpty ? "Access Device" : deviceType)
    }

    var resolvedModel: String { displayModel ?? model ?? (deviceType.isEmpty ? "Unknown Model" : deviceType) }

    /// `config_value`s are strings, but a firmware could send booleans or numbers.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): string
        case .bool(let bool): bool ? "true" : "false"
        case .number(let number): FeatureOptions.javaScriptString(number)
        case .null: ""
        default: value.text()
        }
    }
}

/// A door from the bootstrap's floors.
struct AccessDoor: Sendable, Equatable {
    var json: [String: JSONValue]

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else { return nil }
        json = object
    }

    var uniqueId: String { json["unique_id"]?.stringValue ?? "" }
    var name: String { json["name"]?.stringValue ?? "" }
    var doorPositionStatus: String? { json["door_position_status"]?.stringValue }
    var doorLockRelayStatus: String? { json["door_lock_relay_status"]?.stringValue }
    /// The devices bound to the door; the bootstrap nests them in groups.
    var deviceGroups: [JSONValue] { Self.flatten(json["device_groups"]) }
    var deviceMACs: [String] { deviceGroups.compactMap { $0["mac"]?.stringValue } }

    /// `device_groups` is an array of arrays of devices; flatten two levels as the TypeScript did.
    static func flatten(_ value: JSONValue?) -> [JSONValue] {
        guard let groups = value?.arrayValue else { return [] }
        return groups.flatMap { group -> [JSONValue] in
            if let inner = group.arrayValue { return inner.flatMap { $0.arrayValue ?? [$0] } }
            return [group]
        }.filter { !$0.isNull }
    }
}

/// The controller (`access/info`).
struct AccessControllerInfo: Sendable, Equatable {
    var json: [String: JSONValue]

    var version: String { json["version"]?.stringValue ?? "" }
    var hostMAC: String? { json["host"]?["mac"]?.stringValue }
    var hostFirmware: String { json["host"]?["firmware_version"]?.stringValue ?? "" }
}

/// One message of the events WebSocket (`AccessEventPacket`).
struct AccessEventPacket: Sendable, Equatable {
    var event: String
    var eventObjectId: String
    var metaId: String?
    var metaObjectType: String?
    var data: JSONValue

    init(event: String, eventObjectId: String, metaId: String? = nil, metaObjectType: String? = nil, data: JSONValue = .object([:])) {
        self.event = event
        self.eventObjectId = eventObjectId
        self.metaId = metaId
        self.metaObjectType = metaObjectType
        self.data = data
    }

    init?(_ value: JSONValue) {
        guard let event = value["event"]?.stringValue else { return nil }
        self.event = event
        eventObjectId = value["event_object_id"]?.stringValue ?? ""
        metaId = value["meta"]?["id"]?.stringValue
        metaObjectType = value["meta"]?["object_type"]?.stringValue
        data = value["data"] ?? .null
    }

    /// What `Controller.Publish.Telemetry` sends: the event and the ids, never the data, which can name people.
    var telemetry: String {
        func quoted(_ string: String) -> String { JSONValue.string(string).text() }
        var text = "{\"event\":\(quoted(event)),\"event_object_id\":\(quoted(eventObjectId))"
        if metaId != nil || metaObjectType != nil {
            var meta: [String] = []
            if let metaId { meta.append("\"id\":\(quoted(metaId))") }
            if let metaObjectType { meta.append("\"object_type\":\(quoted(metaObjectType))") }
            text += ",\"meta\":{\(meta.joined(separator: ","))}"
        }
        return text + "}"
    }
}
