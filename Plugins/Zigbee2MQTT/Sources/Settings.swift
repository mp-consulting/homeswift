import Foundation
import HomeswiftPlugin

/// A configuration the plugin refuses (docs/clean-room/Zigbee2MQTT.md, 2.7): it then does nothing at all.
struct SettingsError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The block, validated: the `mqtt` connection, the log options, the device options and the experimental flags.
struct Settings: Sendable {
    struct MQTT: Sendable, Equatable {
        var baseTopic: String
        var server: String
        var ca: String?
        var key: String?
        var cert: String?
        var user: String?
        var password: String?
        var clientID: String?
        /// Only an explicit `false` turns certificate checks off.
        var rejectUnauthorized: Bool?
        var keepalive: Int?
        var version: Int?
        var disableQoS: Bool
    }

    enum PublishLevel: String, Sendable { case debug, info, warn, error }

    var mqtt: MQTT
    var debugAsInfo = false
    var publishLevel = PublishLevel.debug
    /// `defaults`, as JSON (an `exclude: false` taken out: it means unset there).
    var defaults: [String: JSONValue] = [:]
    var excludeGroupedDevices = false
    /// Upper-cased, trimmed.
    var experimental: Set<String> = []
    /// The `devices` entries that have an `id`, in order.
    var devices: [[String: JSONValue]] = []
    /// Entries skipped: not an object, or without an `id` (logged as warnings).
    var skippedDevices: [String] = []

    /// Reads and checks the whole block.
    init(_ block: JSONValue) throws {
        guard let mqtt = block["mqtt"]?.objectValue else { throw SettingsError("mqtt is missing") }
        func text(_ key: String) throws -> String? {
            guard let value = mqtt[key], !value.isNull else { return nil }
            guard let string = value.stringValue else { throw SettingsError("mqtt.\(key) must be a string") }
            return string
        }
        guard let base = try text("base_topic"), !base.isEmpty else { throw SettingsError("mqtt.base_topic is missing or empty") }
        guard let server = try text("server"), !server.isEmpty else { throw SettingsError("mqtt.server is missing or empty") }
        self.mqtt = MQTT(
            baseTopic: base, server: server, ca: try text("ca"), key: try text("key"), cert: try text("cert"), user: try text("user"),
            password: try text("password"), clientID: try text("client_id"), rejectUnauthorized: mqtt["reject_unauthorized"]?.boolValue,
            keepalive: mqtt["keepalive"]?.intValue, version: mqtt["version"]?.intValue, disableQoS: mqtt["disable_qos"]?.boolValue ?? false)

        // An invalid `log` block is not fatal.
        if let log = block["log"]?.objectValue {
            debugAsInfo = log["debug_as_info"]?.boolValue ?? false
            publishLevel = log["mqtt_publish"]?.stringValue.flatMap(PublishLevel.init(rawValue:)) ?? .debug
        }
        if let defaults = block["defaults"], !defaults.isNull {
            guard var object = defaults.objectValue else { throw SettingsError("defaults must be an object") }
            try DeviceOptions.validate(object, context: "defaults")
            if object["exclude"] == .bool(false) { object["exclude"] = nil }
            self.defaults = object
        }
        if let flags = block["experimental"], !flags.isNull {
            guard let list = Self.strings(flags) else { throw SettingsError("experimental must be an array of strings") }
            experimental = Set(list.map(Self.flag))
        }
        if let grouped = block["exclude_grouped_devices"], !grouped.isNull {
            guard let value = grouped.boolValue else { throw SettingsError("exclude_grouped_devices must be a boolean") }
            excludeGroupedDevices = value
        }
        if let list = block["devices"], !list.isNull {
            guard let entries = list.arrayValue else { throw SettingsError("devices must be an array") }
            for entry in entries {
                guard let object = entry.objectValue else {
                    skippedDevices.append("an entry that is not an object: \(entry.text())")
                    continue
                }
                guard let id = object["id"]?.stringValue, !id.isEmpty else {
                    skippedDevices.append("an entry without an id (an IEEE address, a friendly name or a group id): \(entry.text())")
                    continue
                }
                try DeviceOptions.validate(object, context: "devices[\(id)]")
                devices.append(object)
            }
        }
    }

    static func flag(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).uppercased() }

    static func strings(_ value: JSONValue) -> [String]? {
        guard let array = value.arrayValue else { return nil }
        let strings = array.compactMap(\.stringValue)
        return strings.count == array.count ? strings : nil
    }

    /// A device's effective options: `defaults`, then the first `devices` entry whose `id` is one of `ids` (an IEEE
    /// address, a friendly name, a group id), case-insensitively. Keys replace keys; `converters` merge by tag.
    /// The device's Plugin Accessory Settings (`_accessories`) go last, by the same rules.
    func options(for ids: [String], accessory: [String: JSONValue] = [:]) -> DeviceOptions {
        let wanted = Set(ids.map { $0.lowercased() })
        var merged = defaults
        let entry = devices.first { ($0["id"]?.stringValue).map { wanted.contains($0.lowercased()) } ?? false }
        for own in [entry ?? [:], accessory] {
            for (key, value) in own where key != "id" {
                if key == "converters", let base = merged[key]?.objectValue, let own = value.objectValue {
                    merged[key] = .object(base.merging(own) { $1 })
                } else {
                    merged[key] = value
                }
            }
        }
        return DeviceOptions(merged, matched: entry != nil || !accessory.isEmpty, globalFlags: experimental)
    }
}

/// The options of one device or group (2.3), once merged.
struct DeviceOptions: Sendable, Equatable {
    struct ValueFilter: Sendable, Equatable {
        var property: String
        var include: [String]
        var exclude: [String]
    }

    struct Light: Sendable, Equatable {
        var adaptiveLighting = true
        var onlyWhenOn = true
        var transition: Double?
        var minDelta = 1.0
        var requestBrightness = false
    }

    var exclude: Bool?
    var ignoreAvailability = false
    var ignoreZ2MOnline = false
    var excludedKeys: Set<String> = []
    var includedKeys: Set<String> = []
    var excludedEndpoints: Set<String> = []
    var values: [ValueFilter] = []
    var outlet = false
    var occupancyAsMotion = false
    var light = Light()
    var experimental: Set<String> = []
    var exposes: [Expose]?
    /// A `devices` entry matched.
    var matched = false

    init(_ object: [String: JSONValue] = [:], matched: Bool = false, globalFlags: Set<String> = []) {
        self.matched = matched
        exclude = object["exclude"]?.boolValue
        ignoreAvailability = object["ignore_availability"]?.boolValue ?? false
        ignoreZ2MOnline = object["ignore_z2m_online"]?.boolValue ?? false
        excludedKeys = Set(object["excluded_keys"].flatMap(Settings.strings) ?? [])
        includedKeys = Set(object["included_keys"].flatMap(Settings.strings) ?? [])
        excludedEndpoints = Set(object["excluded_endpoints"].flatMap(Settings.strings) ?? [])
        values = (object["values"]?.arrayValue ?? []).compactMap { entry in
            guard let property = entry["property"]?.stringValue else { return nil }
            return ValueFilter(property: property, include: entry["include"].flatMap(Settings.strings) ?? [],
                               exclude: entry["exclude"].flatMap(Settings.strings) ?? [])
        }
        let converters = object["converters"]?.objectValue ?? [:]
        // Only a lower-case "outlet" makes an Outlet, as the original does.
        outlet = converters["switch"]?["type"]?.stringValue == "outlet"
        occupancyAsMotion = converters["occupancy"]?["type"]?.stringValue == "motion"
        if let light = converters["light"]?.objectValue {
            switch light["adaptive_lighting"] {
            case .bool(let enabled): self.light.adaptiveLighting = enabled
            case .object(let options):
                self.light.adaptiveLighting = options["enabled"]?.boolValue ?? true
                self.light.onlyWhenOn = options["only_when_on"]?.boolValue ?? true
                self.light.transition = options["transition"]?.doubleValue
                self.light.minDelta = options["min_delta"]?.doubleValue ?? 1
            default: break
            }
            self.light.requestBrightness = light["request_brightness"]?.boolValue ?? false
        }
        experimental = globalFlags.union((object["experimental"].flatMap(Settings.strings) ?? []).map(Settings.flag))
        exposes = object["exposes"]?.arrayValue.map { $0.compactMap { try? $0.decode(Expose.self) } }
    }

    /// The checks of 2.7 on `defaults` or one `devices` entry.
    static func validate(_ object: [String: JSONValue], context: String) throws {
        func fail(_ reason: String) -> SettingsError { SettingsError("\(context): \(reason) in \(JSONValue.object(object).text())") }
        for key in ["exclude", "ignore_availability", "ignore_z2m_online"] {
            if let value = object[key], value.boolValue == nil { throw fail("\(key) must be a boolean") }
        }
        for key in ["excluded_keys", "excluded_endpoints", "experimental", "included_keys"] {
            if let value = object[key], Settings.strings(value) == nil { throw fail("\(key) must be an array of strings") }
        }
        if let values = object["values"] {
            guard let entries = values.arrayValue else { throw fail("values must be an array") }
            for entry in entries {
                guard let property = entry["property"]?.stringValue, !property.isEmpty else { throw fail("each value needs a property") }
                for key in ["include", "exclude"] {
                    if let list = entry[key], Settings.strings(list) == nil { throw fail("values.\(key) must be an array of strings") }
                }
            }
        }
        if let exposes = object["exposes"] {
            guard let entries = exposes.arrayValue, entries.allSatisfy(Expose.isValidEntry) else { throw fail("exposes must be an array of exposes entries") }
        }
        if let converters = object["converters"] {
            guard let tags = converters.objectValue else { throw fail("converters must be an object") }
            for (tag, value) in tags {
                switch tag {
                case "switch":
                    if let type = value["type"] {
                        guard let string = type.stringValue, ["switch", "outlet"].contains(string.lowercased()) else { throw fail("converters.switch.type must be switch or outlet") }
                    }
                case "occupancy":
                    if let type = value["type"] {
                        guard let string = type.stringValue, ["occupancy", "motion"].contains(string) else { throw fail("converters.occupancy.type must be occupancy or motion") }
                    }
                case "light":
                    guard let light = value.objectValue else { throw fail("converters.light must be an object") }
                    switch light["adaptive_lighting"] {
                    case nil, .bool?: break
                    case .object(let options)?:
                        for key in ["enabled", "only_when_on"] where options[key] != nil && options[key]?.boolValue == nil {
                            throw fail("converters.light.adaptive_lighting.\(key) must be a boolean")
                        }
                        if let transition = options["transition"], transition.doubleValue == nil { throw fail("converters.light.adaptive_lighting.transition must be a number") }
                        if let delta = options["min_delta"], (delta.doubleValue ?? 0) < 1 { throw fail("converters.light.adaptive_lighting.min_delta must be a number of 1 or more") }
                    default: throw fail("converters.light.adaptive_lighting must be a boolean or an object")
                    }
                default:
                    throw fail("unknown converter \"\(tag)\"")
                }
            }
        }
    }
}
