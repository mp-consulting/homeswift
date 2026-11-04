import Foundation
import HomeswiftPlugin

// The block of `@homebridge-plugins/homebridge-tado` (docs/clean-room/Tado.md, section 2), read leniently from its
// JSON: a value of the wrong type is the option's default rather than a block that does not load. What changed from the
// Homebridge plugin is said where it is read.

enum ZoneType: String, Sendable, CaseIterable {
    case heating = "HEATING", hotWater = "HOT_WATER", airConditioning = "AIR_CONDITIONING"

    /// The last word of the zone accessory's name, part of its identity.
    var suffix: String {
        switch self {
        case .heating: "Heater"
        case .hotWater: "Boiler"
        case .airConditioning: "AC"
        }
    }

    /// The Device Kind of the zone's accessory, for the settings editor's `x-kinds`.
    var deviceKind: String {
        switch self {
        case .heating: "heating"
        case .hotWater: "hotWater"
        case .airConditioning: "airConditioning"
        }
    }

    /// Default target limits in °C (section 2.3).
    var defaultLimits: (min: Double, max: Double) { self == .hotWater ? (30, 65) : (5, 25) }
}

/// How an overlay the plugin makes ends.
enum ZoneMode: String, Sendable {
    case manual = "MANUAL", auto = "AUTO", timer = "TIMER", custom = "CUSTOM"
}

/// The zone accessory's kind, also its primary service's subtype (section 6.1).
enum ZoneKind: String, Sendable {
    case thermostat = "zone-thermostat"
    case heaterCooler = "zone-heatercooler"
    case boiler = "zone-heatercooler-boiler"
    case airConditioner = "zone-heatercooler-ac"
    case `switch` = "zone-switch"
    case faucet = "zone-faucet"

    var isHeaterCooler: Bool { self == .heaterCooler || self == .boiler || self == .airConditioner }
}

enum TemperatureUnit: String, Sendable {
    case celsius = "CELSIUS", fahrenheit = "FAHRENHEIT"

    /// A value of this unit in °C, rounded to 2 decimals.
    func celsius(_ value: Double) -> Double {
        self == .celsius ? value : ((value - 32) * 5 / 9 * 100).rounded() / 100
    }
}

extension JSONValue {
    /// A boolean, or the string "true" (the block's `skipAuth` and `addJitter`).
    var flag: Bool { boolValue ?? (stringValue?.lowercased() == "true") }
    /// A non-empty string.
    var text: String? {
        guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// One zone of `homes[].zones[]`, with the zone's Accessory Settings on top (`TadoPlugin.zoneOptionKeys`).
struct ZoneSettings: Sendable {
    var active: Bool
    var id: Int?
    var name: String
    var type: ZoneType
    var mode: ZoneMode
    /// Minutes, 1 at least.
    var modeTimer: Int
    var easyMode: Bool
    var minValue: Double?
    var maxValue: Double?
    var minStep: Double?
    var noBattery: Bool
    var delaySwitch: Bool
    var autoOffDelay: Bool
    var openWindowSensor: Bool
    var openWindowSwitch: Bool
    var separateTemperature: Bool
    var separateHumidity: Bool
    var boilerTempSupport: Bool
    var faucet: Bool
    var acFanSpeed: Bool
    var acFanModeSwitch: Bool
    var acDryModeSwitch: Bool
    /// The block's `type` was not one tado has (it is HEATING then, as in the Homebridge plugin).
    var invalidType: String?

    /// Nil for a zone without a name: it is skipped, and only it (the Homebridge plugin skipped every later zone too).
    init?(_ json: JSONValue) {
        guard let name = json["name"]?.text else { return nil }
        self.name = name
        active = json["active"]?.flag ?? false
        id = json["id"]?.saturatingIntValue
        let rawType = json["type"]?.stringValue
        type = rawType.flatMap(ZoneType.init(rawValue:)) ?? .heating
        invalidType = rawType != nil && ZoneType(rawValue: rawType!) == nil ? rawType : nil
        mode = json["mode"]?.stringValue.flatMap(ZoneMode.init(rawValue:)) ?? .manual
        modeTimer = max(json["modeTimer"]?.saturatingIntValue ?? 1, 1)
        easyMode = json["easyMode"]?.flag ?? false
        minValue = json["minValue"]?.doubleValue?.finite
        maxValue = json["maxValue"]?.doubleValue?.finite
        minStep = json["minStep"]?.doubleValue?.finite
        noBattery = json["noBattery"]?.flag ?? false
        delaySwitch = json["delaySwitch"]?.flag ?? false
        autoOffDelay = json["autoOffDelay"]?.flag ?? false
        openWindowSensor = json["openWindowSensor"]?.flag ?? false
        openWindowSwitch = json["openWindowSwitch"]?.flag ?? false
        separateTemperature = json["separateTemperature"]?.flag ?? false
        separateHumidity = json["separateHumidity"]?.flag ?? false
        boilerTempSupport = json["boilerTempSupport"]?.flag ?? false
        faucet = json["accTypeBoiler"]?.stringValue == "FAUCET"
        acFanSpeed = json["acFanSpeed"]?.flag ?? false
        acFanModeSwitch = json["acFanModeSwitch"]?.flag ?? false
        acDryModeSwitch = json["acDryModeSwitch"]?.flag ?? false
    }

    /// `boilerTempSupport` makes a HeaterCooler of a HOT_WATER zone only (the Homebridge plugin did it for any type,
    /// and its HEATING poll then never updated the accessory).
    var kind: ZoneKind {
        switch type {
        case .heating: easyMode ? .heaterCooler : .thermostat
        case .airConditioning: .airConditioner
        case .hotWater: boilerTempSupport ? .boiler : (faucet ? .faucet : .switch)
        }
    }

    /// Whether the zone's accessories have a Battery service (section 6.2).
    var hasBattery: Bool { type == .heating && !noBattery }

    /// The target range in °C and its step. `minValue` and `maxValue` are in the home's unit; HomeKit's are °C (the
    /// Homebridge plugin put Fahrenheit numbers in them). `heaterCoolerRule`: a limit counts only when above 0.
    func limits(unit: TemperatureUnit, heaterCoolerRule: Bool) -> (min: Double, max: Double, step: Double) {
        let defaults = type.defaultLimits
        var low = defaults.min, high = defaults.max
        if let value = minValue.map(unit.celsius), !heaterCoolerRule || (minValue ?? 0) > 0, value < high { low = value }
        if let value = maxValue.map(unit.celsius), !heaterCoolerRule || (maxValue ?? 0) > 0, value > low { high = value }
        var step = 1.0
        if let minStep, minStep > 0, minStep <= 1 { step = (minStep * 100).rounded() / 100 }
        return (low, high, step)
    }
}

/// One home of `homes[]`.
struct HomeSettings: Sendable {
    struct User: Sendable { var name: String; var motion: Bool }
    struct ChildLock: Sendable { var name: String; var serialNumber: String }

    var id: Int?
    var name: String
    /// The tado account's e-mail, or the path of a token file another program keeps (ends with `.json`).
    var username: String
    var apiBase: URL
    var hasCustomAPI: Bool
    var skipAuth: Bool
    var addJitter: Bool
    /// The block's `polling`, raised to 30; nil when it has none (the plugin then fits the daily budget).
    var polling: Int?
    var nightPolling: Int?
    var temperatureUnit: TemperatureUnit?
    var users: [User]
    var anyone: Bool
    var anyoneMotion: Bool
    var weatherTemperature: Bool
    var solarIntensity: Bool
    var solarAsSensor: Bool
    var centralSwitch: Bool
    var runningInformation: Bool
    var boostSwitch: Bool
    var sheduleSwitch: Bool
    var turnoffSwitch: Bool
    var dummySwitch: Bool
    var presenceLock: Bool
    var presenceLockAlarm: Bool
    var childLocks: [ChildLock]
    /// Every zone with a name, active or not.
    var zones: [ZoneSettings]
    var telegram: TelegramSettings?
    /// Why entries of the home were left out, for the log.
    var warnings: [String] = []

    static let defaultAPI = URL(string: "https://my.tado.com")!

    /// Nil, with the reason, for a home without a name or a username. `zoneOverrides` gives a zone's Accessory Settings
    /// by its zone accessory's Device Id.
    init(_ json: JSONValue, telegramToken: String? = nil, zoneOverrides: (String) -> [String: JSONValue] = { _ in [:] }) throws(SkippedHome) {
        guard let name = json["name"]?.text else { throw SkippedHome(reason: "a home has no name") }
        guard let username = json["username"]?.text else { throw SkippedHome(reason: "home \(name) has no username") }
        self.name = name
        self.username = username
        id = json["id"]?.saturatingIntValue
        if let custom = json["tadoApiUrl"]?.text, let url = URL(string: custom.hasSuffix("/") ? String(custom.dropLast()) : custom), url.scheme != nil {
            apiBase = url
            hasCustomAPI = true
        } else {
            apiBase = Self.defaultAPI
            hasCustomAPI = false
        }
        skipAuth = json["skipAuth"]?.flag ?? false
        addJitter = json["addJitter"]?.flag ?? false
        polling = json["polling"]?.intValue.map { max($0, TadoBudget.minimumPolling) }
        nightPolling = json["nightPolling"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
        temperatureUnit = json["temperatureUnit"]?.stringValue.flatMap(TemperatureUnit.init(rawValue:))
        let presence = json["presence"]
        anyone = presence?["anyone"]?.flag ?? false
        anyoneMotion = presence?["accTypeAnyone"]?.stringValue == "MOTION"
        users = []
        for entry in presence?["user"]?.arrayValue ?? [] where entry["active"]?.flag == true {
            guard let user = entry["name"]?.text else {
                warnings.append("a presence user of home \(name) has no name")
                continue
            }
            users.append(User(name: user, motion: entry["accType"]?.stringValue == "MOTION"))
        }
        let weather = json["weather"]
        weatherTemperature = weather?["temperatureSensor"]?.flag ?? false
        solarIntensity = weather?["solarIntensity"]?.flag ?? false
        solarAsSensor = weather?["accTypeSolarIntensity"]?.stringValue == "SENSOR"
        let extras = json["extras"]
        centralSwitch = extras?["centralSwitch"]?.flag ?? false
        runningInformation = extras?["runningInformation"]?.flag ?? false
        boostSwitch = extras?["boostSwitch"]?.flag ?? false
        sheduleSwitch = extras?["sheduleSwitch"]?.flag ?? false
        turnoffSwitch = extras?["turnoffSwitch"]?.flag ?? false
        dummySwitch = extras?["dummySwitch"]?.flag ?? false
        presenceLock = extras?["presenceLock"]?.flag ?? false
        presenceLockAlarm = extras?["accTypePresenceLock"]?.stringValue == "ALARM"
        childLocks = []
        for entry in extras?["childLockSwitches"]?.arrayValue ?? [] where entry["active"]?.flag == true {
            guard let lock = entry["name"]?.text, let serial = entry["serialNumber"]?.text else {
                warnings.append("a child lock of home \(name) has no name or serial number")
                continue
            }
            childLocks.append(ChildLock(name: lock, serialNumber: serial))
        }
        zones = []
        for entry in json["zones"]?.arrayValue ?? [] {
            guard var fields = entry.objectValue, let zone = ZoneSettings(entry) else {
                if entry["active"]?.flag == true { warnings.append("an active zone of home \(name) has no name") }
                continue
            }
            for (key, value) in zoneOverrides(Self.zoneDeviceID(home: name, zone: zone.name, type: zone.type)) { fields[key] = value }
            guard var merged = ZoneSettings(.object(fields)) else { continue }
            merged.name = zone.name
            if let invalid = merged.invalidType { warnings.append("zone \(zone.name) has type \(invalid), taken as HEATING") }
            zones.append(merged)
        }
        telegram = TelegramSettings(json["telegram"], vaultToken: telegramToken)
    }

    var isTokenFile: Bool { username.lowercased().hasSuffix(".json") }
    var activeZones: [ZoneSettings] { zones.filter(\.active) }

    /// The zone accessory's Device Id: its display name, the Homebridge plugin's identity seed.
    static func zoneDeviceID(home: String, zone: String, type: ZoneType) -> String { "\(home) \(zone) \(type.suffix)" }
}

struct SkippedHome: Error { var reason: String }

/// `telegram`: messages to a Telegram chat on presence and open-window changes. `token` sits under a secret-named key,
/// so the runtime seals and resolves it.
struct TelegramSettings: Sendable {
    var token: String
    var chatID: String
    var messages: [String: String]

    init?(_ json: JSONValue?, vaultToken: String? = nil) {
        guard let json, json["active"]?.flag == true, let token = json["token"]?.text ?? vaultToken, let chat = json["chatID"]?.text else { return nil }
        self.token = token
        chatID = chat
        var messages: [String: String] = [:]
        for (group, keys) in [("presence", ["user_in", "user_out", "anyone_in", "anyone_out"]), ("openWindow", ["opened", "closed"])] {
            for key in keys {
                if let text = json["messages"]?[group]?[key]?.text { messages["\(group).\(key)"] = text }
            }
        }
        self.messages = messages
    }

    /// The template's first `@` is the accessory's name without the home's, its first `%` the home's name.
    static func fill(_ template: String, accessory: String?, home: String) -> String {
        var text = template
        if let accessory, let range = text.range(of: "@") { text.replaceSubrange(range, with: accessory) }
        if let range = text.range(of: "%") { text.replaceSubrange(range, with: home) }
        return text
    }
}

/// The hashes the Homebridge plugin names things with.
enum TadoHash {
    /// The 32-bit string hash `h = 31·h + code unit` over UTF-16, wrapped to signed 32 bits.
    static func java(_ text: String) -> Int32 {
        var hash: Int32 = 0
        for unit in text.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return hash
    }

    /// An accessory's serial number: the absolute value of `java`, in decimal.
    static func serial(_ text: String) -> String { String(abs(Int(java(text)))) }

    /// The `<h>` of `.tado-token-<h>.json`: `java` as unsigned, base 36, padded with zeros to 7 characters.
    static func username(_ username: String) -> String {
        let text = String(UInt32(bitPattern: java(username)), radix: 36)
        return String(repeating: "0", count: max(0, 7 - text.count)) + text
    }
}
