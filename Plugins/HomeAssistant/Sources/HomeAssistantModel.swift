import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// An entity's state as `get_states` and `state_changed` give it (docs/clean-room/HomeAssistant.md, 2.6 and 5).
struct EntityState: Sendable, Equatable {
    var entityID: String
    var state: String
    var attributes: [String: JSONValue]

    init(entityID: String, state: String, attributes: [String: JSONValue] = [:]) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
    }

    init?(_ json: JSONValue) {
        guard let entityID = json["entity_id"]?.stringValue, let state = json["state"]?.stringValue else { return nil }
        self.init(entityID: entityID, state: state, attributes: json["attributes"]?.objectValue ?? [:])
    }

    var domain: String { String(entityID.prefix { $0 != "." }) }
    var objectID: String { entityID.firstIndex(of: ".").map { String(entityID[entityID.index(after: $0)...]) } ?? entityID }

    var friendlyName: String? { attributes["friendly_name"]?.stringValue?.nonEmpty }
    var deviceClass: String? { attributes["device_class"]?.stringValue }
    var unit: String? { attributes["unit_of_measurement"]?.stringValue }
    /// The `supported_features` bitmask, 0 when absent.
    var features: Int { attributes["supported_features"]?.intValue ?? 0 }
    func supports(_ bit: Int) -> Bool { features & bit != 0 }

    /// `unavailable`: No Response; `unknown`: keep the last values (4.5).
    var isUnavailable: Bool { state == "unavailable" }
    var isUnknown: Bool { state == "unknown" }
    var hasValue: Bool { !isUnavailable && !isUnknown }

    func double(_ key: String) -> Double? {
        switch attributes[key] {
        case .number(let value)?: value.finite
        case .string(let text)?: Double(text)?.finite
        default: nil
        }
    }

    func string(_ key: String) -> String? { attributes[key]?.stringValue }
    func strings(_ key: String) -> [String] { attributes[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// The state as a number; HA sends numbers as strings.
    var number: Double? { Double(state)?.finite }
}

/// An element of `config/entity_registry/list` (4.1).
struct EntityEntry: Sendable, Equatable, Codable {
    var id: String
    var entityID: String
    var uniqueID: String?
    var platform: String?
    var deviceID: String?
    var areaID: String?
    var disabledBy: String?
    var hiddenBy: String?
    var entityCategory: String?
    var name: String?
    var originalName: String?

    init(id: String, entityID: String, uniqueID: String? = nil, platform: String? = nil, deviceID: String? = nil, areaID: String? = nil,
         disabledBy: String? = nil, hiddenBy: String? = nil, entityCategory: String? = nil, name: String? = nil, originalName: String? = nil) {
        self.id = id
        self.entityID = entityID
        self.uniqueID = uniqueID
        self.platform = platform
        self.deviceID = deviceID
        self.areaID = areaID
        self.disabledBy = disabledBy
        self.hiddenBy = hiddenBy
        self.entityCategory = entityCategory
        self.name = name
        self.originalName = originalName
    }

    init?(_ json: JSONValue) {
        guard let entityID = json["entity_id"]?.stringValue else { return nil }
        // The registry id is stable across renames; an old server without one falls back on platform and unique id.
        let uniqueID = json["unique_id"]?.stringValue ?? json["unique_id"]?.doubleValue.map { String(Int(saturating: $0) ?? 0) }
        let platform = json["platform"]?.stringValue
        guard let id = json["id"]?.stringValue ?? uniqueID.map({ "\(platform ?? "").\($0)" }) else { return nil }
        self.init(
            id: id, entityID: entityID, uniqueID: uniqueID, platform: platform, deviceID: json["device_id"]?.stringValue?.nonEmpty,
            areaID: json["area_id"]?.stringValue?.nonEmpty, disabledBy: json["disabled_by"]?.stringValue, hiddenBy: json["hidden_by"]?.stringValue,
            entityCategory: json["entity_category"]?.stringValue, name: json["name"]?.stringValue, originalName: json["original_name"]?.stringValue)
    }
}

/// An element of `config/device_registry/list` (4.2).
struct DeviceEntry: Sendable, Equatable, Codable {
    var id: String
    var name: String?
    var nameByUser: String?
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var swVersion: String?
    var areaID: String?
    var disabledBy: String?
    var viaDeviceID: String?
    /// `connections`: `[type, value]` pairs (`mac`, `bluetooth`, `zigbee`…).
    var connections: [[String]]
    /// `identifiers`: `[domain, id]` pairs.
    var identifiers: [[String]]

    init(id: String, name: String? = nil, nameByUser: String? = nil, manufacturer: String? = nil, model: String? = nil, serialNumber: String? = nil,
         swVersion: String? = nil, areaID: String? = nil, disabledBy: String? = nil, viaDeviceID: String? = nil, connections: [[String]] = [], identifiers: [[String]] = []) {
        self.id = id
        self.name = name
        self.nameByUser = nameByUser
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.swVersion = swVersion
        self.areaID = areaID
        self.disabledBy = disabledBy
        self.viaDeviceID = viaDeviceID
        self.connections = connections
        self.identifiers = identifiers
    }

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        func pairs(_ key: String) -> [[String]] {
            (json[key]?.arrayValue ?? []).compactMap { pair in
                let items = pair.arrayValue?.compactMap(\.stringValue) ?? []
                return items.count >= 2 ? items : nil
            }
        }
        self.init(
            id: id, name: json["name"]?.stringValue, nameByUser: json["name_by_user"]?.stringValue, manufacturer: json["manufacturer"]?.stringValue,
            model: json["model"]?.stringValue, serialNumber: json["serial_number"]?.stringValue, swVersion: json["sw_version"]?.stringValue,
            areaID: json["area_id"]?.stringValue?.nonEmpty, disabledBy: json["disabled_by"]?.stringValue, viaDeviceID: json["via_device_id"]?.stringValue?.nonEmpty,
            connections: pairs("connections"), identifiers: pairs("identifiers"))
    }

    var displayName: String? { nameByUser?.nonEmpty ?? name?.nonEmpty }

    /// The `mac` connection as the repository's Serial Number: uppercase hex without separators.
    var macSerial: String? {
        for pair in connections where pair[0] == "mac" {
            if let canonical = MACAddress.canonical(pair[1]) { return canonical.replacingOccurrences(of: ":", with: "") }
        }
        return nil
    }
}

/// What `get_config` says that the plugin uses.
struct ServerConfig: Sendable, Equatable {
    var locationName: String?
    var version: String?
    var state: String?
    /// `°C` or `°F`: the unit of the climate domain's temperatures.
    var temperatureUnit: String
    var components: Set<String>

    init(locationName: String? = nil, version: String? = nil, state: String? = "RUNNING", temperatureUnit: String = "°C", components: Set<String> = []) {
        self.locationName = locationName
        self.version = version
        self.state = state
        self.temperatureUnit = temperatureUnit
        self.components = components
    }

    init(_ json: JSONValue) {
        self.init(
            locationName: json["location_name"]?.stringValue, version: json["version"]?.stringValue, state: json["state"]?.stringValue,
            temperatureUnit: json["unit_system"]?["temperature"]?.stringValue ?? "°C",
            components: Set(json["components"]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    var isFahrenheit: Bool { temperatureUnit == "°F" }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Temperatures: HomeKit is Celsius (7.6, 7.7).
enum Temperature {
    static func celsius(_ value: Double, fahrenheit: Bool) -> Double { fahrenheit ? (value - 32) * 5 / 9 : value }
    static func fromCelsius(_ value: Double, fahrenheit: Bool) -> Double { fahrenheit ? value * 9 / 5 + 32 : value }
    /// To one decimal, HomeKit's step.
    static func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
