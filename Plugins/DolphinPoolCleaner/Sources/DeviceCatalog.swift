/// What a robot model can do.
struct DeviceFeatures: Sendable, Equatable {
    var hasTemperatureSensor: Bool
    var hasWaterQualitySensor: Bool
    var hasSmartMode: Bool
    var hasWeeklySchedule: Bool
    var hasDelayStart: Bool
    var hasRemoteControl: Bool
    var hasLEDControl: Bool
    var hasPickupMode: Bool
    var supportedCleaningModes: [String]
}

/// A robot model, by the `connectVia` device type the account reports.
struct DeviceModel: Sendable, Equatable {
    var deviceType: Int
    var modelName: String
    var series: String
    var features: DeviceFeatures
}

/// The robots the plugin knows, as the Homebridge plugin's catalog lists them.
///
/// The temperature sensor is off for every model: not all M400/M600 have one, and the catalog cannot tell
/// which. The Homebridge plugin behaves the same way.
enum DeviceCatalog {
    /// IoT-enabled models.
    static let baseFeatures = DeviceFeatures(
        hasTemperatureSensor: false, hasWaterQualitySensor: false, hasSmartMode: true, hasWeeklySchedule: true, hasDelayStart: true,
        hasRemoteControl: true, hasLEDControl: false, hasPickupMode: true,
        supportedCleaningModes: ["regular", "floor", "wall", "water", "ultra", "short"])

    static let mSeriesFeatures: DeviceFeatures = {
        var features = baseFeatures
        features.hasLEDControl = true
        features.supportedCleaningModes = ["regular", "floor", "wall", "water", "ultra", "short", "cove", "spot"]
        return features
    }()

    static let libertyFeatures: DeviceFeatures = {
        var features = baseFeatures
        features.hasLEDControl = true
        features.supportedCleaningModes = ["regular", "floor", "wall", "ultra", "short"]
        return features
    }()

    static let models: [Int: DeviceModel] = [
        62: DeviceModel(deviceType: 62, modelName: "Dolphin M400/M600", series: "M-Series", features: mSeriesFeatures),
        65: DeviceModel(deviceType: 65, modelName: "Dolphin Liberty", series: "Liberty", features: libertyFeatures),
        60: DeviceModel(deviceType: 60, modelName: "Dolphin S Series", series: "S-Series", features: baseFeatures),
        61: DeviceModel(deviceType: 61, modelName: "Dolphin E Series", series: "E-Series", features: baseFeatures),
    ]

    static func model(deviceType: Int) -> DeviceModel? { models[deviceType] }

    static func features(deviceType: Int) -> DeviceFeatures { models[deviceType]?.features ?? baseFeatures }

    static func modelName(deviceType: Int) -> String { models[deviceType]?.modelName ?? "Unknown Dolphin (Type \(deviceType))" }

    static func isSupported(deviceType: Int) -> Bool { models[deviceType] != nil }

    static var supportedDeviceTypes: [Int] { models.keys.sorted() }
}
