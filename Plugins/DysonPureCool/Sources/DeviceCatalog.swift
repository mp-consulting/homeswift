import Foundation

/// What a Dyson model can do. The services the accessory gets follow from it.
struct DeviceFeatures: Sendable, Equatable {
    var fan = true
    var oscillation = true
    var autoMode = true
    var nightMode = true
    var continuousMonitoring = true
    /// Jet focus: a focused or a diffused stream.
    var frontAirflow = false
    var temperatureSensor = false
    var humiditySensor = false
    var airQualitySensor = false
    /// Link models report a 0-9 particulate index (`pact`/`vact`) rather than densities (`p25r`/`p10r`/`va10`).
    var basicAirQualitySensor = false
    var no2Sensor = false
    var heating = false
    var humidifier = false
    var hepaFilter = false
    var carbonFilter = false

    /// A model the catalog does not know: a fan, no sensors.
    static let `default` = DeviceFeatures()
}

/// The MQTT field that switches the fan on and off.
enum PowerProtocol: String, Sendable {
    /// `fmod` carries power and mode at once (`OFF`, `FAN`, `AUTO`). Most purifiers.
    case fmod
    /// `fpwr` carries power (`ON`, `OFF`), with `auto` and `fnsp` for mode and speed. The Pure Cool Link series
    /// and newer fans such as the CF1, which ignore `fmod` for power.
    case fpwr
}

enum DeviceSeries: String, Sendable {
    case pureCoolLink = "pure-cool-link", pureCool = "pure-cool", hotCoolLink = "hot-cool-link", hotCool = "hot-cool"
    case humidifyCool = "humidify-cool", bigQuiet = "big-quiet", cool
}

struct DeviceModel: Sendable {
    /// The product type code the cloud and the MQTT topics use (`438`, `527K`).
    var productType: String
    var modelName: String
    /// `TP04`, `HP07`.
    var modelCode: String
    var series: DeviceSeries
    var features: DeviceFeatures
    var formaldehyde: Bool
    var powerProtocol: PowerProtocol = .fmod
}

/// Every Dyson model the plugin knows, as in the Homebridge plugin's `deviceCatalog.ts`.
enum DeviceCatalog {
    private static let pureCoolBase: DeviceFeatures = {
        var features = DeviceFeatures()
        features.temperatureSensor = true
        features.humiditySensor = true
        features.airQualitySensor = true
        features.hepaFilter = true
        features.carbonFilter = true
        return features
    }()

    private static func with(_ base: DeviceFeatures, _ change: (inout DeviceFeatures) -> Void) -> DeviceFeatures {
        var features = base
        change(&features)
        return features
    }

    static let pureCoolLink = with(pureCoolBase) { $0.basicAirQualitySensor = true }
    static let pureCoolJet = with(pureCoolBase) { $0.frontAirflow = true }
    static let pureCoolNoJet = pureCoolBase
    static let pureCoolFormaldehyde = with(pureCoolJet) { $0.no2Sensor = true }
    static let hotCoolLink = with(pureCoolBase) { $0.frontAirflow = true; $0.heating = true; $0.basicAirQualitySensor = true }
    static let hotCoolJet = with(pureCoolBase) { $0.frontAirflow = true; $0.heating = true }
    static let hotCoolNoJet = with(pureCoolBase) { $0.heating = true }
    static let hotCoolFormaldehyde = with(hotCoolJet) { $0.no2Sensor = true }
    static let humidifyCool = with(pureCoolBase) { $0.frontAirflow = true; $0.humidifier = true }
    static let humidifyCoolFormaldehyde = with(humidifyCool) { $0.no2Sensor = true }
    static let bigQuiet = with(pureCoolBase) { $0.oscillation = false; $0.no2Sensor = true }
    /// A plain fan: no sensors, no filters, no auto mode.
    static let coolFan = with(DeviceFeatures()) { $0.autoMode = false; $0.continuousMonitoring = false }

    static let models: [DeviceModel] = [
        // Pure Cool Link
        DeviceModel(productType: "475", modelName: "Dyson Pure Cool Link Tower", modelCode: "TP02", series: .pureCoolLink, features: pureCoolLink, formaldehyde: false, powerProtocol: .fpwr),
        DeviceModel(productType: "469", modelName: "Dyson Pure Cool Link Desk", modelCode: "DP01", series: .pureCoolLink, features: pureCoolLink, formaldehyde: false, powerProtocol: .fpwr),
        // Pure Cool (438 also covers the TP06, 527 the HP06: they share the product type)
        DeviceModel(productType: "438", modelName: "Dyson Pure Cool Tower", modelCode: "TP04", series: .pureCool, features: pureCoolJet, formaldehyde: false),
        DeviceModel(productType: "438E", modelName: "Dyson Purifier Cool", modelCode: "TP07", series: .pureCool, features: pureCoolJet, formaldehyde: false),
        DeviceModel(productType: "438K", modelName: "Dyson Purifier Cool Formaldehyde", modelCode: "TP09", series: .pureCool, features: pureCoolFormaldehyde, formaldehyde: true),
        DeviceModel(productType: "438M", modelName: "Dyson Purifier Cool", modelCode: "TP11", series: .pureCool, features: pureCoolNoJet, formaldehyde: false),
        DeviceModel(productType: "520", modelName: "Dyson Pure Cool Desk", modelCode: "DP04", series: .pureCool, features: pureCoolJet, formaldehyde: false),
        // Hot+Cool Link
        DeviceModel(productType: "455", modelName: "Dyson Pure Hot+Cool Link", modelCode: "HP02", series: .hotCoolLink, features: hotCoolLink, formaldehyde: false),
        // Hot+Cool
        DeviceModel(productType: "527", modelName: "Dyson Pure Hot+Cool", modelCode: "HP04", series: .hotCool, features: hotCoolJet, formaldehyde: false),
        DeviceModel(productType: "527E", modelName: "Dyson Purifier Hot+Cool", modelCode: "HP07", series: .hotCool, features: hotCoolJet, formaldehyde: false),
        DeviceModel(productType: "527K", modelName: "Dyson Purifier Hot+Cool Formaldehyde", modelCode: "HP09", series: .hotCool, features: hotCoolFormaldehyde, formaldehyde: true),
        DeviceModel(productType: "527M", modelName: "Dyson Purifier Hot+Cool", modelCode: "HP11", series: .hotCool, features: hotCoolNoJet, formaldehyde: false),
        // Humidify+Cool
        DeviceModel(productType: "358", modelName: "Dyson Pure Humidify+Cool", modelCode: "PH01", series: .humidifyCool, features: humidifyCool, formaldehyde: false),
        DeviceModel(productType: "520E", modelName: "Dyson Pure Humidify+Cool", modelCode: "PH02", series: .humidifyCool, features: humidifyCool, formaldehyde: false),
        DeviceModel(productType: "358H", modelName: "Dyson Purifier Humidify+Cool", modelCode: "PH03", series: .humidifyCool, features: humidifyCool, formaldehyde: false),
        DeviceModel(productType: "358J", modelName: "Dyson Purifier Humidify+Cool", modelCode: "PH03", series: .humidifyCool, features: humidifyCool, formaldehyde: false),
        DeviceModel(productType: "358E", modelName: "Dyson Purifier Humidify+Cool Formaldehyde", modelCode: "PH04", series: .humidifyCool, features: humidifyCoolFormaldehyde, formaldehyde: true),
        DeviceModel(productType: "520F", modelName: "Dyson Purifier Humidify+Cool Formaldehyde", modelCode: "PH04", series: .humidifyCool, features: humidifyCoolFormaldehyde, formaldehyde: true),
        DeviceModel(productType: "358K", modelName: "Dyson Purifier Humidify+Cool De-Nox", modelCode: "PH05", series: .humidifyCool, features: humidifyCoolFormaldehyde, formaldehyde: false),
        // Big+Quiet
        DeviceModel(productType: "664", modelName: "Dyson Purifier Big+Quiet", modelCode: "BP02", series: .bigQuiet, features: bigQuiet, formaldehyde: false),
        DeviceModel(productType: "664B", modelName: "Dyson Purifier Big+Quiet Formaldehyde", modelCode: "BP03", series: .bigQuiet, features: bigQuiet, formaldehyde: true),
        DeviceModel(productType: "664E", modelName: "Dyson Purifier Big+Quiet Formaldehyde", modelCode: "BP04", series: .bigQuiet, features: bigQuiet, formaldehyde: true),
        DeviceModel(productType: "664F", modelName: "Dyson Purifier Big+Quiet", modelCode: "BP06", series: .bigQuiet, features: bigQuiet, formaldehyde: false),
        // Cool: a plain fan that takes power only through `fpwr`
        DeviceModel(productType: "739", modelName: "Dyson Cool", modelCode: "CF1", series: .cool, features: coolFan, formaldehyde: false, powerProtocol: .fpwr),
    ]

    private static let byProductType: [String: DeviceModel] = Dictionary(models.map { ($0.productType, $0) }, uniquingKeysWith: { first, _ in first })

    static func model(_ productType: String) -> DeviceModel? { byProductType[productType] }
    static func isSupported(_ productType: String) -> Bool { byProductType[productType] != nil }
    static func features(_ productType: String) -> DeviceFeatures { byProductType[productType]?.features ?? .default }
    static func powerProtocol(_ productType: String) -> PowerProtocol { byProductType[productType]?.powerProtocol ?? .fmod }

    /// `Dyson Pure Cool Tower (TP04)`, or `Dyson Device (<code>)` for an unknown one.
    static func modelName(_ productType: String) -> String {
        guard let model = byProductType[productType] else { return "Dyson Device (\(productType))" }
        return "\(model.modelName) (\(model.modelCode))"
    }

    /// `TP04 - Dyson Pure Cool Tower` by product type, for the settings page.
    static var displayNames: [String: String] {
        Dictionary(models.map { ($0.productType, "\($0.modelCode) - \($0.modelName)") }, uniquingKeysWith: { first, _ in first })
    }

    static var heatingProductTypes: [String] { models.filter(\.features.heating).map(\.productType) }
    static var jetFocusProductTypes: [String] { models.filter(\.features.frontAirflow).map(\.productType) }
}
