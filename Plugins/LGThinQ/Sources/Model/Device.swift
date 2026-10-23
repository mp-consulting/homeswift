import Foundation
import Homeswift
import HomeswiftPlugin

/// A device as LG's device list reports it, with its latest state (`snapshot`) and, once loaded, its model.
@ThinQActor
final class ThinQDevice {
    var data: [String: JSONValue]
    var deviceModel = DeviceModel([:])

    init(_ data: [String: JSONValue]) {
        self.data = data
    }

    var id: String { JS.string(data["deviceId"]) }
    var name: String { JS.string(data["alias"]) }
    var deviceTypeCode: Int? { DeviceType.code(data["deviceType"]) }
    /// `AC`, `WASHER`… or `undefined` for a type the plugin does not know (or a missing or non-numeric one).
    var type: String { deviceTypeCode.flatMap { DeviceType.names[$0] } ?? "undefined" }

    /// The model name without its region suffix (`RAC_056905_WW` is `RAC_056905`).
    var model: String {
        let candidates = [data["modelName"], data["modemInfo"]?["modelName"], data["manufacture"]?["manufactureModel"]]
        let modelName = candidates.compactMap { $0 }.first { JS.truthy($0) }.map { JS.string($0) } ?? ""
        if modelName.range(of: #"^([A-Z]+)_(\d+)_([A-Z]{2})$"#, options: .regularExpression) != nil { return String(modelName.dropLast(3)) }
        return modelName
    }

    var macAddress: String? { data["manufacture"]?["macAddress"]?.stringValue }
    var salesModel: String? { data["manufacture"]?["salesModel"]?.stringValue }
    var serialNumber: String? { data["manufacture"]?["serialNo"]?.stringValue }
    var modelJSONURI: String { JS.string(data["modelJsonUri"]) }

    var snapshot: [String: JSONValue] {
        get { data["snapshot"]?.objectValue ?? [:] }
        set { data["snapshot"] = .object(newValue) }
    }

    var platform: String? { data["platformType"]?.stringValue }

    var online: Bool {
        if let online = data["online"] { return JS.truthy(online) }
        return JS.truthy(snapshot["online"])
    }

    var description: String { "\(id): \(name) (\(type) \(model))" }

    /// LG's device ids are UUIDs; anything else is skipped.
    var hasValidID: Bool {
        id.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }
}

/// MQTT pushes `state.reported` as a sparse delta: merged into the snapshot recursively so a one-key update
/// does not drop its siblings. Arrays are replaced.
func mergeSnapshot(_ current: [String: JSONValue]?, _ incoming: [String: JSONValue]) -> [String: JSONValue] {
    guard var result = current else { return incoming }
    for (key, next) in incoming {
        if let previous = result[key]?.objectValue, let nextObject = next.objectValue {
            result[key] = .object(mergeSnapshot(previous, nextObject))
        } else {
            result[key] = next
        }
    }
    return result
}

/// What the plugin knows about each device type: its handler for ThinQ2 and ThinQ1, its HomeKit category,
/// whether it is published on its own (devices with a Television service), where its state sits in the
/// snapshot, and its configuration defaults.
struct DeviceDescriptor: Sendable {
    var v2: BaseDevice.Type?
    var v1: BaseDevice.Type?
    var category: AccessoryCategory
    var external = false
    /// Where the state is nested; nil for devices with flat `airState.*` keys at the root.
    var snapshotKey: String?
    var defaults: [String: JSONValue] = [:]
    var modelFeatures: [String: [String]] = [:]
}

enum DeviceRegistry {
    static let acModelFeatures: [String: [String]] = [
        "jetMode": ["RAC_056905"],
        "quietMode": ["WINF_056905"],
        "energySaveMode": ["WINF_056905", "RAC_056905"],
        "airClean": ["RAC_056905"],
        /// Models that do not accept `airState.mon.timeout`.
        "noMonitorTimeout": ["RAC_056905"],
    ]

    static let washerDefaults: [String: JSONValue] = ["washer_trigger": false, "washer_door_lock": false, "washer_tub_clean": false]

    static let descriptors: [String: DeviceDescriptor] = [
        "AERO_TOWER": .init(v2: AeroTower.self, category: .airPurifier, defaults: ["air_fast_mode": false]),
        "AIR_PURIFIER": .init(v2: AirPurifier.self, v1: AirPurifierV1.self, category: .airPurifier, defaults: ["air_fast_mode": false]),
        "REFRIGERATOR": .init(v2: Refrigerator.self, v1: RefrigeratorV1.self, category: .other, snapshotKey: "refState",
            defaults: ["ref_express_freezer": false, "ref_express_fridge": false, "ref_eco_friendly": false]),
        "WASHER": .init(v2: WasherDryer.self, v1: WasherV1.self, category: .other, snapshotKey: "washerDryer", defaults: washerDefaults),
        "WASHER_NEW": .init(v2: WasherDryer.self, category: .other, snapshotKey: "washerDryer", defaults: washerDefaults),
        "WASH_TOWER": .init(v2: WasherDryer.self, category: .other, snapshotKey: "washerDryer", defaults: washerDefaults),
        "WASH_TOWER_2": .init(v2: WasherDryer2.self, category: .other, snapshotKey: "washer", defaults: washerDefaults),
        "DRYER": .init(v2: WasherDryer.self, v1: WasherV1.self, category: .other, snapshotKey: "washerDryer", defaults: washerDefaults),
        "DISHWASHER": .init(v2: Dishwasher.self, category: .sprinkler, external: true, snapshotKey: "dishwasher", defaults: ["dishwasher_trigger": false]),
        "DEHUMIDIFIER": .init(v2: Dehumidifier.self, category: .dehumidifier),
        "AC": .init(v2: AirConditioner.self, v1: AirConditionerV1.self, category: .airConditioner, defaults: [
            "ac_swing_mode": "BOTH", "ac_air_quality": false, "ac_mode": "BOTH", "ac_temperature_sensor": false, "ac_humidity_sensor": false,
            "ac_led_control": false, "ac_fan_control": false, "ac_jet_control": false, "ac_temperature_unit": "C", "ac_buttons": [],
            "ac_air_clean": true, "ac_energy_save": true,
        ], modelFeatures: acModelFeatures),
        "STYLER": .init(v2: Styler.self, category: .other, snapshotKey: "styler"),
        "HOOD": .init(v2: RangeHood.self, v1: RangeHoodV1.self, category: .other, snapshotKey: "hoodState"),
        "MICROWAVE": .init(v2: Microwave.self, category: .thermostat, external: true, snapshotKey: "ovenState"),
        "OVEN": .init(v2: Oven.self, category: .thermostat, external: true, snapshotKey: "ovenState"),
    ]

    static func handler(for type: String, platform: String?) -> BaseDevice.Type? {
        guard let descriptor = descriptors[type] else { return nil }
        return platform == PlatformType.thinq1 ? descriptor.v1 : descriptor.v2
    }

    static func category(_ type: String) -> AccessoryCategory { descriptors[type]?.category ?? .other }
    static func isExternal(_ type: String) -> Bool { descriptors[type]?.external ?? false }
    static func snapshotKey(_ type: String) -> String? { descriptors[type]?.snapshotKey }
    static func defaults(_ type: String) -> [String: JSONValue] { descriptors[type]?.defaults ?? [:] }

    /// Whether a model has a feature of its type's list (the model name contains a listed one).
    static func hasModelFeature(_ type: String, _ feature: String, model: String) -> Bool {
        descriptors[type]?.modelFeatures[feature]?.contains { model.contains($0) } ?? false
    }
}
