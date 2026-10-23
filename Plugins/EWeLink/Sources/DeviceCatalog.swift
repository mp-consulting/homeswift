import Foundation

/// The catalog of eWeLink devices by UIID (the eWeLink model type), the single source of truth for routing a
/// device to an accessory type, its channels, power monitoring, battery and parameter names. The entries are
/// in DeviceCatalogData.swift, generated from the Homebridge plugin's `device-catalog.ts`.
enum DeviceCatalog {
    private static let byUIID: [Int: DeviceCatalogEntry] = Dictionary(entries.map { ($0.uiid, $0) }, uniquingKeysWith: { first, _ in first })

    static func entry(_ uiid: Int) -> DeviceCatalogEntry? { byUIID[uiid] }

    static func channelCount(_ uiid: Int) -> Int { byUIID[uiid]?.capabilities.channels ?? 1 }
    /// Unknown UIIDs count as monitoring power, as the Homebridge plugin's `undefined !== 'none'` does.
    static func hasPowerMonitoring(_ uiid: Int) -> Bool { byUIID[uiid]?.capabilities.powerMonitoring != PowerMonitoring.none }
    static func hasFullPowerReadings(_ uiid: Int) -> Bool { byUIID[uiid]?.capabilities.powerMonitoring == .full }
    static func isDualR3(_ uiid: Int) -> Bool { [126, 165].contains(uiid) }
    static func isTHSensor(_ uiid: Int) -> Bool { [15, 181].contains(uiid) }
    static func isDimmableLightForFan(_ uiid: Int) -> Bool { [36, 44, 57].contains(uiid) }
    static func isMotionSensor(_ uiid: Int) -> Bool { byUIID[uiid]?.primaryService == .motionSensor }
    static func isContactSensor(_ uiid: Int) -> Bool { byUIID[uiid]?.primaryService == .contactSensor }
    static func hasTemperature(_ uiid: Int) -> Bool { byUIID[uiid]?.capabilities.hasTemperature ?? false }
    static func hasHumidity(_ uiid: Int) -> Bool { byUIID[uiid]?.capabilities.hasHumidity ?? false }
    static func hasBattery(_ uiid: Int) -> Bool { byUIID[uiid]?.capabilities.hasBattery ?? false }
    static func batteryType(_ uiid: Int) -> BatteryType { byUIID[uiid]?.params.battery ?? .percentage }
    static func lightType(_ uiid: Int) -> LightType? { byUIID[uiid]?.capabilities.lightType }
    static func isProgrammableSwitch(_ uiid: Int) -> Bool { byUIID[uiid]?.category == .programmableSwitch }
    static func isGroup(_ uiid: Int) -> Bool { byUIID[uiid]?.category == .group }
    static func isNSPanelPro(_ uiid: Int) -> Bool { uiid == 195 || uiid == 228 }
    /// Zigbee water valves (SWV-BSP, UIID 7027) default to a faucet.
    static func isWaterValve(_ uiid: Int) -> Bool { byUIID[uiid]?.primaryService == .valve }
    static func brightness(_ uiid: Int) -> DeviceCatalogEntry.Brightness? { byUIID[uiid]?.params.brightness }
    static func position(_ uiid: Int) -> DeviceCatalogEntry.Position? { byUIID[uiid]?.params.position }
    static func motorTurnParam(_ uiid: Int) -> String? { byUIID[uiid]?.params.motorTurn }
    static func switchParamName(_ uiid: Int) -> String { byUIID[uiid]?.params.onOffParam ?? "switch" }
    static func switchStyle(_ uiid: Int) -> SwitchStyle { byUIID[uiid]?.params.switchStyle ?? .single }
    static func isCurtain(_ uiid: Int) -> Bool { byUIID[uiid]?.category == .curtain }

    /// UIID 126 (DUALR3) is a two-channel switch or a curtain motor, depending on what it reports.
    static func hasCurtainParams(_ params: DeviceParams?) -> Bool {
        guard let params else { return false }
        return params["currLocation"] != nil || params["setclose"] != nil || params["location"] != nil
    }

    static func isCurtain(uiid: Int, params: DeviceParams?) -> Bool {
        isCurtain(uiid) || (uiid == 126 && hasCurtainParams(params))
    }

    /// A device's brightness (`min...max`) as 0...100.
    static func normalizeBrightness(_ uiid: Int, _ value: Double) -> Int {
        guard let range = brightness(uiid) else { return jsRound(value).clampedInt }
        return jsRound((value - Double(range.min)) / Double(range.max - range.min) * 100).clampedInt
    }

    /// 0...100 as the device's brightness range.
    static func denormalizeBrightness(_ uiid: Int, _ percent: Double) -> Int {
        guard let range = brightness(uiid) else { return jsRound(percent).clampedInt }
        return jsRound(percent / 100 * Double(range.max - range.min) + Double(range.min)).clampedInt
    }

    /// The simulations a `showAs` can name, as the Homebridge plugin lists them.
    static let simulationTypes: [String] = [
        "outlet", "light", "valve", "tap", "lock", "garage", "gate", "sensor", "sensor_leak", "p_button", "doorbell", "purifier", "tv",
        "fan", "blind", "door", "window", "heater", "cooler", "humidifier", "dehumidifier", "thermostat",
    ]

    enum CategoryType: String, Sendable {
        case singleSwitch = "single_switch", multiSwitch = "multi_switch", outlet, light, fan, curtain, garage, thermostat, sensor
        case airConditioner = "air_conditioner", humidifier, diffuser, panel, rfBridge = "rf_bridge", zigbeeBridge = "zigbee_bridge"
        case virtual, group, programmableSwitch = "programmable_switch"
    }

    enum ServiceKind: String, Sendable {
        case `switch`, outlet, lightbulb, fan, fanv2, windowCovering, garageDoorOpener, lockMechanism, thermostat, heaterCooler
        case humidifierDehumidifier, airPurifier, valve, temperatureSensor, humiditySensor, motionSensor, contactSensor, leakSensor
        case smokeSensor, carbonMonoxideSensor, occupancySensor, statelessProgrammableSwitch, doorbell, television, battery
    }

    enum PowerMonitoring: String, Sendable { case none, basic, full }
    enum LightType: String, Sendable { case switchOnly = "switch_only", dimmable, cct, rgb, rgbcct }
    enum SwitchStyle: String, Sendable { case single, multi, state }
    enum BatteryType: String, Sendable { case percentage, voltage }
}

struct DeviceCatalogEntry: Sendable {
    struct Capabilities: Sendable {
        var powerMonitoring: DeviceCatalog.PowerMonitoring
        var channels: Int
        var lightType: DeviceCatalog.LightType? = nil
        var hasTemperature = false
        var hasHumidity = false
        var hasBattery = false
        var hasRelay = false
        var supportsInching = false
        var supportsLAN = false
        var isSensor = false
        var isBridge = false
    }

    struct Brightness: Sendable {
        var param: String
        var min: Int
        var max: Int
        var asString = false
        var requiresMode = false
    }

    struct ColorTemperature: Sendable {
        var param: String
        var min: Int
        var max: Int
        var asString = false
    }

    struct RGB: Sendable {
        var r: String, g: String, b: String
        var br: String?
    }

    struct Position: Sendable {
        var current: String
        var target: String
        var inverted = false
    }

    struct Power: Sendable {
        var power: String
        var voltage: String?
        var current: String?
    }

    struct FanSpeed: Sendable {
        var param: String
        var min: Int
        var max: Int
    }

    struct Params: Sendable {
        var switchStyle: DeviceCatalog.SwitchStyle? = nil
        var onOffParam: String? = nil
        var brightness: Brightness? = nil
        var colorTemp: ColorTemperature? = nil
        var rgb: RGB? = nil
        var position: Position? = nil
        var temperature: String? = nil
        var humidity: String? = nil
        var power: Power? = nil
        var fanSpeed: FanSpeed? = nil
        var motorTurn: String? = nil
        var battery: DeviceCatalog.BatteryType? = nil
    }

    var uiid: Int
    var category: DeviceCatalog.CategoryType
    var name: String
    var models: [String] = []
    var brand: String? = nil
    var primaryService: DeviceCatalog.ServiceKind
    var additionalServices: [DeviceCatalog.ServiceKind] = []
    var capabilities: Capabilities
    var params: Params
    var supportedSimulations: [String] = []
    var notes: String? = nil
}

/// How the plugin routes a device: the Homebridge plugin's `DeviceCategory`.
enum DeviceCategory: String, Sendable, Codable {
    case singleSwitch = "single", multiSwitch = "multi", thermostat, fan, light, sensor, rfBridge = "rf_bridge", outlet, curtain
    case garage, lock, airConditioner = "air_conditioner", humidifier, diffuser, panel, virtual, motor, group, unknown

    init(catalog type: DeviceCatalog.CategoryType) {
        switch type {
        case .singleSwitch, .programmableSwitch: self = .singleSwitch
        case .multiSwitch: self = .multiSwitch
        case .outlet: self = .outlet
        case .light: self = .light
        case .fan: self = .fan
        case .curtain: self = .curtain
        case .garage: self = .garage
        case .thermostat: self = .thermostat
        case .sensor: self = .sensor
        case .airConditioner: self = .airConditioner
        case .humidifier: self = .humidifier
        case .diffuser: self = .diffuser
        case .panel: self = .panel
        case .rfBridge, .zigbeeBridge: self = .rfBridge
        case .virtual: self = .virtual
        case .group: self = .group
        }
    }

    /// The category of a UIID, `.unknown` when the catalog does not list it.
    init(uiid: Int) {
        self = DeviceCatalog.entry(uiid).map { DeviceCategory(catalog: $0.category) } ?? .unknown
    }

    /// A UIID 126 reporting curtain parameters is a curtain; everything else goes by its UIID.
    static func resolve(_ device: EWeLinkDevice) -> DeviceCategory {
        if device.uiid == 126, DeviceCatalog.hasCurtainParams(device.params) { return .curtain }
        return DeviceCategory(uiid: device.uiid)
    }
}

/// JavaScript's `Math.round`: halves go up, also for negative numbers (-2.5 is -2).
func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }
