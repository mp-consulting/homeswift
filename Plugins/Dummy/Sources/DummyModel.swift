import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The 21 accessory types of a `HomebridgeDummy` block (`type`).
enum DummyType: String, CaseIterable, Sendable {
    case `switch` = "Switch"
    case outlet = "Outlet"
    case lightbulb = "Lightbulb"
    case button = "StatelessProgrammableSwitch"
    case lock = "LockMechanism"
    case door = "Door"
    case window = "Window"
    case windowCovering = "WindowCovering"
    case garageDoor = "GarageDoorOpener"
    case valve = "Valve"
    case humidifier = "HumidifierDehumidifier"
    case thermostat = "Thermostat"
    case temperatureSensor = "TemperatureSensor"
    case humiditySensor = "HumiditySensor"
    case carbonDioxideSensor = "CarbonDioxideSensor"
    case carbonMonoxideSensor = "CarbonMonoxideSensor"
    case contactSensor = "ContactSensor"
    case leakSensor = "LeakSensor"
    case motionSensor = "MotionSensor"
    case occupancySensor = "OccupancySensor"
    case smokeSensor = "SmokeSensor"

    enum Family: Sendable { case onOff, button, lock, position, garage, valve, humidifier, thermostat, valueSensor, binarySensor }

    var family: Family {
        switch self {
        case .switch, .outlet, .lightbulb: .onOff
        case .button: .button
        case .lock: .lock
        case .door, .window, .windowCovering: .position
        case .garageDoor: .garage
        case .valve: .valve
        case .humidifier: .humidifier
        case .thermostat: .thermostat
        case .temperatureSensor, .humiditySensor: .valueSensor
        default: .binarySensor
        }
    }

    static let sensorTypes: [DummyType] = [.carbonDioxideSensor, .carbonMonoxideSensor, .contactSensor, .leakSensor, .motionSensor, .occupancySensor, .smokeSensor]

    var service: ServiceType {
        switch self {
        case .switch: .switch
        case .outlet: .outlet
        case .lightbulb: .lightbulb
        case .button: .statelessProgrammableSwitch
        case .lock: .lockMechanism
        case .door: .door
        case .window: .window
        case .windowCovering: .windowCovering
        case .garageDoor: .garageDoorOpener
        case .valve: .valve
        case .humidifier: .humidifierDehumidifier
        case .thermostat: .thermostat
        case .temperatureSensor: .temperatureSensor
        case .humiditySensor: .humiditySensor
        case .carbonDioxideSensor: .carbonDioxideSensor
        case .carbonMonoxideSensor: .carbonMonoxideSensor
        case .contactSensor: .contactSensor
        case .leakSensor: .leakSensor
        case .motionSensor: .motionSensor
        case .occupancySensor: .occupancySensor
        case .smokeSensor: .smokeSensor
        }
    }

    var category: AccessoryCategory {
        switch self {
        case .switch: .switch
        case .outlet: .outlet
        case .lightbulb: .lightbulb
        case .button: .programmableSwitch
        case .lock: .doorLock
        case .door: .door
        case .window: .window
        case .windowCovering: .windowCovering
        case .garageDoor: .garageDoorOpener
        case .valve: .faucet
        case .humidifier: .humidifier
        case .thermostat: .thermostat
        default: .sensor
        }
    }

    /// A binary sensor's characteristic: also its stored key and its webhook name.
    var sensorCharacteristic: CharacteristicType? {
        switch self {
        case .carbonDioxideSensor: .carbonDioxideDetected
        case .carbonMonoxideSensor: .carbonMonoxideDetected
        case .contactSensor: .contactSensorState
        case .leakSensor: .leakDetected
        case .motionSensor: .motionDetected
        case .occupancySensor: .occupancyDetected
        case .smokeSensor: .smokeDetected
        default: nil
        }
    }

    /// The key of a binary sensor's characteristic, as the Homebridge plugin names it.
    var sensorKey: String {
        switch self {
        case .carbonDioxideSensor: "CarbonDioxideDetected"
        case .carbonMonoxideSensor: "CarbonMonoxideDetected"
        case .contactSensor: "ContactSensorState"
        case .leakSensor: "LeakDetected"
        case .motionSensor: "MotionDetected"
        case .occupancySensor: "OccupancyDetected"
        case .smokeSensor: "SmokeDetected"
        default: ""
        }
    }

    /// What a binary sensor's log says on activation and deactivation.
    var sensorWords: (on: String, off: String) {
        switch self {
        case .carbonDioxideSensor: ("detected carbon dioxide", "stopped detecting carbon dioxide")
        case .carbonMonoxideSensor: ("detected carbon monoxide", "stopped detecting carbon monoxide")
        case .contactSensor: ("detected contact opened", "detected contact closed")
        case .leakSensor: ("detected a leak", "stopped detecting a leak")
        case .motionSensor: ("detected motion", "stopped detecting motion")
        case .occupancySensor: ("detected occupancy", "stopped detecting occupancy")
        case .smokeSensor: ("detected smoke", "stopped detecting smoke")
        default: ("", "")
        }
    }
}

enum TimeUnits: String, CaseIterable, Sendable {
    case milliseconds = "MILLISECONDS", seconds = "SECONDS", minutes = "MINUTES", hours = "HOURS"

    var milliseconds: Double {
        switch self {
        case .milliseconds: 1
        case .seconds: 1000
        case .minutes: 60_000
        case .hours: 3_600_000
        }
    }

    /// "5 seconds", "1 minute": a duration in the largest unit not over it, rounded (spec 7.2).
    static func describe(milliseconds ms: Double) -> String {
        func plural(_ value: Double, _ unit: String) -> String {
            let rounded = Int(saturating: value.rounded()) ?? 0
            return "\(rounded) \(unit)\(rounded == 1 ? "" : "s")"
        }
        if ms < 1000 { return plural(ms, "millisecond") }
        if ms < 60_000 { return plural(ms / 1000, "second") }
        if ms < 3_600_000 { return plural(ms / 60_000, "minute") }
        return plural(ms / 3_600_000, "hour")
    }
}

/// A sun event of a schedule, with the sun's altitude that defines it (SunCalc's angles).
enum SunEvent: String, CaseIterable, Sendable {
    case sunrise = "SUNRISE", sunset = "SUNSET", dawn = "DAWN", dusk = "DUSK", goldenHour = "GOLDEN_HOUR", night = "NIGHT"
}

/// `schedule`, `autoReset` or `syncSchedule`.
struct ScheduleConfig: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case timeout(milliseconds: Double, random: Bool)
        case interval(milliseconds: Double, random: Bool)
        case cron(CronExpression)
        case sun(SunEvent, offsetMinutes: Double, latitude: Double, longitude: Double)
    }

    var kind: Kind

    var isTimeout: Bool {
        if case .timeout = kind { return true }
        return false
    }

    var timeoutMilliseconds: Double? {
        if case .timeout(let ms, _) = kind { return ms }
        return nil
    }
}

enum SensorBehavior: String, Sendable { case mirror = "MIRROR", timer = "TIMER" }

struct SensorAddOn: Sendable, Equatable {
    var type: DummyType
    var behavior: SensorBehavior
}

struct NotificationConfig: Sendable, Equatable {
    enum API: String, Sendable { case notify = "PINGIE_NOTIFY", pushover = "PUSHOVER" }
    var api: API
    var token: String
    var id: String?
    var title: String?
    var text: String?
    var resetTitle: String?
    var resetText: String?
    var groupType: String?
    var iconURL: String?
}

struct LimiterConfig: Sendable, Equatable {
    enum Period: String, CaseIterable, Sendable {
        case hour = "HOUR", day = "DAY", week = "WEEK", month = "MONTH"

        var milliseconds: Double {
            switch self {
            case .hour: 3_600_000
            case .day: 86_400_000
            case .week: 7 * 86_400_000
            case .month: 31 * 86_400_000
            }
        }
    }

    var limit: Double
    var units: TimeUnits
    var period: Period
    var resetOnRestart: Bool
    var legacyID: String?

    var limitMilliseconds: Double { limit * units.milliseconds }
}

struct ConditionsConfig: Sendable, Equatable {
    enum Operator: String, Sendable { case and, or }

    enum Operand: Sendable, Equatable {
        case accessory(id: String, state: String)
        case log(pattern: String)
        case ping(host: String, available: Bool, intervalMilliseconds: Double)
    }

    var `operator`: Operator
    var operands: [Operand]
}

struct FadeConfig: Sendable, Equatable {
    enum Kind: String, Sendable { case fixed = "FIXED", incremental = "INCREMENTAL" }
    var kind: Kind
    var milliseconds: Double
}

struct SimulationConfig: Sendable, Equatable {
    var milliseconds: Double
}

/// One entry of `accessories`, read and checked as the Homebridge plugin reads it.
struct AccessoryConfig: Sendable {
    var identifier: String
    /// The part of the accessory's id after `HomebridgeDummy:`: `id`, else `<type>:<name without whitespace>`.
    var deviceID: String
    var name: String
    var type: DummyType
    var isMatter: Bool
    var groupName: String?
    var sensor: SensorAddOn?
    var schedule: ScheduleConfig?
    var autoReset: ScheduleConfig?
    var notification: NotificationConfig?
    var limiter: LimiterConfig?
    var conditions: ConditionsConfig?
    var simulation: SimulationConfig?
    var fade: FadeConfig?
    var resetOnRestart: Bool
    var enableWebhook: Bool
    var enableHistory: Bool
    var disableLogging: Bool
    /// The type-specific options.
    var defaultOn = false
    var isDimmer = false
    var defaultLocked = true
    var defaultOpen = false
    var fahrenheit = false
    var defaultThermostatState = 0
    var defaultTemperature = 20.0
    var minimumTemperature = 10.0
    var maximumTemperature = 38.0
    var validStates = [0, 1, 2, 3]
    var dehumidifier = false
    var valveType = 0
    /// The shell command keys this entry sets: Homeswift runs none.
    var commandKeys: [String] = []

    var family: DummyType.Family { type.family }
}

/// Reads the block's entries with the Homebridge plugin's checks: a problem is logged with the accessory's name, and
/// the feature (or the accessory) it concerns is left out.
struct ConfigReader {
    let logger: Logger
    /// A device's credentials in the vault (`notificationToken`, `notificationID`), moved there by `canonicalSettings`.
    var credentials: (String) -> JSONValue? = { _ in nil }

    static let commandKeys = [
        "commandOn", "commandOff", "commandLock", "commandUnlock", "commandOpen", "commandClose", "commandActive", "commandInactive",
        "commandHumidity", "commandTemperature", "commandSync",
    ]

    /// `HomebridgeDummy:<type>:<name>` with every run of whitespace taken out (JavaScript's `\s`).
    static func derivedIdentifier(type: String, name: String) -> String {
        "\(DummyPlugin.platform):\(type):\(stripWhitespace(name))"
    }

    static func stripWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !isJavaScriptWhitespace($0) }.map(Character.init))
    }

    /// JavaScript's `\s`: Unicode's white space plus the byte order mark.
    static func isJavaScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0xFEFF
    }

    func missing(_ name: String, _ key: String) {
        logger.error("\(name) is missing required field '\(key)'")
    }

    func invalid(_ name: String, _ thing: String, _ value: JSONValue?, _ valid: [String], warning: Bool = false) {
        let shown = value?.stringValue ?? value.map { $0.text() } ?? ""
        let message = "\(name) has invalid \(thing) '\(shown)'. Must be one of: \(valid.map { "'\($0)'" }.joined(separator: ", "))"
        if warning { logger.warning("\(message)") } else { logger.error("\(message)") }
    }

    /// The entry, or nil when it has no name, an unknown type or an unsupported protocol.
    func accessory(_ json: JSONValue) -> AccessoryConfig? {
        guard let name = json["name"]?.stringValue else { return nil }
        let typeName = json["type"]?.stringValue
        guard let typeName else {
            missing(name, "type")
            return nil
        }
        guard let type = DummyType(rawValue: typeName) else {
            logger.error("\(name) has unsupported accessory type '\(typeName)'")
            return nil
        }
        var isMatter = false
        if let proto = json["protocol"] {
            switch proto.stringValue {
            case "HomeKit": break
            case "Matter" where [.switch, .outlet, .lightbulb].contains(type): isMatter = true
            case "Matter":
                logger.warning("\(name) is a \(typeName): Matter is supported only for Switch, Outlet and Lightbulb")
                return nil
            default:
                invalid(name, "protocol", proto, ["HomeKit", "Matter"], warning: true)
                return nil
            }
        }
        let deviceID: String
        let identifier: String
        if let id = json["id"]?.stringValue {
            deviceID = id
            identifier = id
        } else {
            identifier = Self.derivedIdentifier(type: typeName, name: name)
            deviceID = String(identifier.dropFirst(DummyPlugin.platform.count + 1))
        }
        let groupName = json["groupName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if isMatter, groupName != nil {
            logger.warning("\(name): groups are not supported for Matter accessories")
            return nil
        }
        var config = AccessoryConfig(
            identifier: identifier, deviceID: deviceID, name: name, type: type, isMatter: isMatter, groupName: groupName,
            resetOnRestart: json["resetOnRestart"]?.boolValue ?? false,
            enableWebhook: json["enableWebhook"]?.boolValue == true || json["enableWebook"]?.boolValue == true,
            enableHistory: !isMatter && json["enableHistory"]?.boolValue == true,
            disableLogging: json["disableLogging"]?.boolValue ?? false)
        config.commandKeys = Self.commandKeys.filter { json[$0]?.stringValue?.isEmpty == false }
        readTypeOptions(json, into: &config)
        if !isMatter, let sensor = json["sensor"] { config.sensor = sensorAddOn(sensor, name: name) }
        config.schedule = json["schedule"].flatMap { schedule($0, name: name) }
        config.autoReset = json["autoReset"].flatMap { schedule($0, name: name) }
        if json["commandSync"] != nil, json["syncSchedule"] == nil { missing(name, "syncSchedule") }
        config.notification = json["notification"].flatMap { notification($0, name: name, vault: credentials(deviceID)) }
        config.limiter = json["limiter"].flatMap { limiter($0, name: name) }
        config.conditions = json["conditions"].flatMap { conditions($0, name: name, identifier: identifier) }
        if [.door, .window, .windowCovering, .garageDoor].contains(type), let simulation = json["simulation"] {
            config.simulation = self.simulation(simulation, name: name)
        }
        if type == .lightbulb, let fade = json["fadeOut"] {
            if fade.boolValue != nil {
                // The legacy form: the auto-reset's timeout becomes a fixed fade, and the auto-reset goes.
                if case .timeout(let ms, _) = config.autoReset?.kind, json["autoReset"]?["time"] != nil, json["autoReset"]?["units"] != nil {
                    config.fade = FadeConfig(kind: .fixed, milliseconds: ms)
                    config.autoReset = nil
                }
            } else {
                config.fade = self.fade(fade, name: name)
            }
            if !config.isDimmer { config.fade = nil }
        }
        if type.family == .binarySensor, config.schedule == nil, !config.enableWebhook {
            logger.warning("\(name) has no schedule and no webhook: it will never be triggered")
        }
        return config
    }

    private func readTypeOptions(_ json: JSONValue, into config: inout AccessoryConfig) {
        let name = config.name
        switch config.type.family {
        case .onOff, .valve, .humidifier:
            if let state = json["defaultState"] {
                switch state.stringValue {
                case "on": config.defaultOn = true
                case "off": config.defaultOn = false
                default: invalid(name, "defaultState", state, ["on", "off"], warning: true)
                }
            }
        default: break
        }
        switch config.type {
        case .lightbulb:
            config.isDimmer = json["isDimmer"]?.boolValue ?? (json["defaultBrightness"] != nil)
        case .lock:
            if let state = json["defaultLockState"] {
                switch state.stringValue {
                case "locked": config.defaultLocked = true
                case "unlocked": config.defaultLocked = false
                default: invalid(name, "defaultLockState", state, ["locked", "unlocked"], warning: true)
                }
            }
        case .door, .window, .windowCovering, .garageDoor:
            if let position = json["defaultPosition"] {
                switch position.stringValue {
                case "open": config.defaultOpen = true
                case "closed": config.defaultOpen = false
                default: invalid(name, "defaultPosition", position, ["open", "closed"], warning: true)
                }
            }
        case .humidifier:
            if let kind = json["humidifierType"] {
                switch kind.stringValue {
                case "humidifier": config.dehumidifier = false
                case "dehumidifier": config.dehumidifier = true
                default: invalid(name, "humidifierType", kind, ["humidifier", "dehumidifier"], warning: true)
                }
            }
        case .valve:
            if let kind = json["valveType"] {
                switch kind.stringValue {
                case "generic": config.valveType = 0
                case "irrigation": config.valveType = 1
                case "shower": config.valveType = 2
                case "faucet": config.valveType = 3
                default: invalid(name, "valveType", kind, ["generic", "faucet", "irrigation", "shower"], warning: true)
                }
            }
        case .thermostat, .temperatureSensor:
            if let units = json["temperatureUnits"] {
                switch units.stringValue {
                case "C": config.fahrenheit = false
                case "F": config.fahrenheit = true
                default: invalid(name, "temperatureUnits", units, ["C", "F"], warning: true)
                }
            }
            guard config.type == .thermostat else { break }
            let fahrenheit = config.fahrenheit
            func celsius(_ value: Double) -> Double { fahrenheit ? Temperature.celsius(fahrenheit: value) : value }
            if let state = json["defaultThermostatState"] {
                if let mode = Self.thermostatModes.firstIndex(of: state.stringValue ?? "") {
                    config.defaultThermostatState = mode
                } else {
                    invalid(name, "defaultThermostatState", state, ["auto", "heat", "cool", "off"], warning: true)
                }
            }
            // A default temperature of 0 is taken as none, as the Homebridge plugin does; the bounds take 0.
            if let value = json["defaultTemperature"]?.doubleValue, value != 0 { config.defaultTemperature = celsius(value) }
            if let value = json["minimumTemperature"]?.doubleValue { config.minimumTemperature = celsius(value) }
            if let value = json["maximumTemperature"]?.doubleValue { config.maximumTemperature = celsius(value) }
            if let states = json["validStates"] {
                let names = states.arrayValue?.compactMap(\.stringValue)
                if let names, names.count == states.arrayValue?.count, names.allSatisfy(Self.thermostatModes.contains) {
                    config.validStates = Array(Set(names.compactMap { Self.thermostatModes.firstIndex(of: $0) })).sorted()
                } else {
                    logger.warning("\(name) has invalid validStates: it must list 'off', 'heat', 'cool' or 'auto'; all four are used")
                }
                if config.validStates.isEmpty { config.validStates = [0, 1, 2, 3] }
            }
        default: break
        }
    }

    /// HAP's Target Heating Cooling State values, by the names the block gives them.
    static let thermostatModes = ["off", "heat", "cool", "auto"]

    func sensorAddOn(_ json: JSONValue, name: String) -> SensorAddOn? {
        guard let typeValue = json["type"], let typeName = typeValue.stringValue else {
            missing(name, "sensor.type")
            return nil
        }
        guard let type = DummyType(rawValue: typeName), DummyType.sensorTypes.contains(type) else {
            invalid(name, "sensor type", typeValue, DummyType.sensorTypes.map(\.rawValue))
            return nil
        }
        var behavior = SensorBehavior.mirror
        if let value = json["behavior"] {
            guard let parsed = value.stringValue.flatMap(SensorBehavior.init) else {
                invalid(name, "sensor behavior", value, ["MIRROR", "TIMER"])
                return nil
            }
            behavior = parsed
        }
        if json["timerControlled"]?.boolValue == true { behavior = .timer }
        return SensorAddOn(type: type, behavior: behavior)
    }

    func units(_ value: JSONValue?, name: String, key: String = "units") -> TimeUnits? {
        guard let value else {
            missing(name, key)
            return nil
        }
        guard let units = value.stringValue.flatMap(TimeUnits.init) else {
            invalid(name, key, value, TimeUnits.allCases.map(\.rawValue))
            return nil
        }
        return units
    }

    func schedule(_ json: JSONValue, name: String) -> ScheduleConfig? {
        var json = json
        // The legacy form: `delay` is a timeout of that many units.
        if let delay = json["delay"] {
            json = .object(["type": "TIMEOUT", "time": delay, "units": json["units"] ?? .null, "random": json["random"] ?? .null])
        }
        guard let typeValue = json["type"], let typeName = typeValue.stringValue else {
            missing(name, "type")
            return nil
        }
        switch typeName {
        case "TIMEOUT", "INTERVAL":
            guard let time = json["time"]?.doubleValue else {
                missing(name, "delay")
                return nil
            }
            guard let units = units(json["units"]?.nonNull, name: name) else { return nil }
            let ms = time * units.milliseconds
            let random = json["random"]?.boolValue ?? false
            return ScheduleConfig(kind: typeName == "TIMEOUT" ? .timeout(milliseconds: ms, random: random) : .interval(milliseconds: ms, random: random))
        case "CRON":
            guard let cron = json["cron"]?.stringValue else {
                missing(name, "cron")
                return nil
            }
            var expression = cron
            if cron == "CRON_CUSTOM" {
                guard let custom = json["cronCustom"]?.stringValue else {
                    missing(name, "cronCustom")
                    return nil
                }
                expression = custom
            }
            guard let parsed = try? CronExpression(expression) else {
                logger.error("\(name) has invalid cron expression '\(expression)'")
                return nil
            }
            return ScheduleConfig(kind: .cron(parsed))
        default:
            guard let event = SunEvent(rawValue: typeName) else {
                invalid(name, "schedule type", typeValue, ["TIMEOUT", "INTERVAL", "CRON"] + SunEvent.allCases.map(\.rawValue))
                return nil
            }
            guard let latitude = json["latitude"]?.doubleValue else {
                missing(name, "latitude")
                return nil
            }
            guard let longitude = json["longitude"]?.doubleValue else {
                missing(name, "longitude")
                return nil
            }
            return ScheduleConfig(kind: .sun(event, offsetMinutes: json["offset"]?.doubleValue ?? 0, latitude: latitude, longitude: longitude))
        }
    }

    func notification(_ json: JSONValue, name: String, vault: JSONValue? = nil) -> NotificationConfig? {
        guard let apiValue = json["api"] else {
            missing(name, "notification.api")
            return nil
        }
        guard let api = apiValue.stringValue.flatMap(NotificationConfig.API.init) else {
            invalid(name, "notification api", apiValue, ["PINGIE_NOTIFY", "PUSHOVER"], warning: true)
            return nil
        }
        func text(_ key: String) -> String? { json[key]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        guard text("text") != nil || text("resetText") != nil else {
            logger.warning("\(name) has a notification without 'text' or 'resetText': notifications are off")
            return nil
        }
        var ok = true
        let token = json["token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? vault?["notificationToken"]?.stringValue
        if token?.isEmpty != false { missing(name, "notification.token"); ok = false }
        let id = json["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? vault?["notificationID"]?.stringValue
        // Notify! needs the device or group; Pushover the application token, which the bridge has none of its own for.
        if id == nil { missing(name, "notification.id"); ok = false }
        guard ok, let token else { return nil }
        return NotificationConfig(
            api: api, token: token, id: id, title: json["title"]?.stringValue, text: text("text"), resetTitle: json["resetTitle"]?.stringValue,
            resetText: text("resetText"), groupType: json["groupType"]?.stringValue, iconURL: json["iconURL"]?.stringValue)
    }

    func limiter(_ json: JSONValue, name: String) -> LimiterConfig? {
        let limit = json["limit"]?.doubleValue
        if limit == nil { missing(name, "limiter.limit") }
        let units = units(json["units"], name: name, key: "limiter.units")
        var period: LimiterConfig.Period?
        if let value = json["period"] {
            period = value.stringValue.flatMap(LimiterConfig.Period.init)
            if period == nil { invalid(name, "limiter.period", value, LimiterConfig.Period.allCases.map(\.rawValue)) }
        } else {
            missing(name, "limiter.period")
        }
        guard let limit, let units, let period else { return nil }
        let config = LimiterConfig(limit: limit, units: units, period: period, resetOnRestart: json["resetOnRestart"]?.boolValue ?? false, legacyID: json["id"]?.stringValue)
        guard config.limitMilliseconds <= period.milliseconds else {
            logger.error("\(name) has a limiter whose limit exceeds its period")
            return nil
        }
        return config
    }

    static let accessoryStates = ["on", "off", "open", "closed", "locked", "unlocked"]

    func conditions(_ json: JSONValue, name: String, identifier: String) -> ConditionsConfig? {
        var ok = true
        var op: ConditionsConfig.Operator?
        if let value = json["operator"] {
            op = value.stringValue.flatMap(ConditionsConfig.Operator.init)
            if op == nil { invalid(name, "conditions operator", value, ["and", "or"]); ok = false }
        } else {
            missing(name, "conditions.operator")
            ok = false
        }
        var operands: [ConditionsConfig.Operand] = []
        let list = json["operands"]?.arrayValue ?? []
        if list.isEmpty { missing(name, "conditions.operands"); ok = false }
        for item in list {
            switch item["type"]?.stringValue {
            case "ACCESSORY":
                let id = item["accessoryId"]?.stringValue
                let state = item["accessoryState"]?.stringValue
                if id == nil { missing(name, "accessoryId"); ok = false }
                if state == nil { missing(name, "accessoryState"); ok = false }
                if let state, !Self.accessoryStates.contains(state) { invalid(name, "accessoryState", .string(state), Self.accessoryStates); ok = false }
                if id == identifier {
                    logger.error("\(name) has a condition that cannot reference itself")
                    ok = false
                }
                if let id, let state { operands.append(.accessory(id: id, state: state)) }
            case "LOG":
                guard let pattern = item["pattern"]?.stringValue else { missing(name, "pattern"); ok = false; continue }
                operands.append(.log(pattern: pattern))
            case "PING":
                guard let host = item["pingHost"]?.stringValue else { missing(name, "pingHost"); ok = false; continue }
                let amount = (item["checkInterval"] ?? item["pingInterval"])?.doubleValue ?? 60
                let unitsValue = item["checkUnits"] ?? item["pingUnits"]
                let unit = unitsValue.flatMap { $0.stringValue.flatMap(TimeUnits.init) } ?? .seconds
                operands.append(.ping(host: host, available: item["pingAvailability"]?.stringValue != "NOT_AVAILABLE",
                                      intervalMilliseconds: max(1, amount) * unit.milliseconds))
            case nil:
                missing(name, "type")
                ok = false
            case let other?:
                invalid(name, "condition type", .string(other), ["ACCESSORY", "LOG", "PING"])
                ok = false
            }
        }
        if op == .and, operands.filter({ if case .log = $0 { true } else { false } }).count > 1 {
            logger.error("\(name) has more than one log condition while ALL conditions must be met")
            ok = false
        }
        guard ok, let op else { return nil }
        return ConditionsConfig(operator: op, operands: operands)
    }

    func simulation(_ json: JSONValue, name: String) -> SimulationConfig? {
        guard let enabled = json["enabled"]?.boolValue else {
            missing(name, "simulation.enabled")
            return nil
        }
        guard enabled else { return nil }
        let time = json["time"]?.doubleValue ?? 15
        let unit = json["units"].flatMap { $0.stringValue.flatMap(TimeUnits.init) } ?? .seconds
        return SimulationConfig(milliseconds: max(1, time) * unit.milliseconds)
    }

    func fade(_ json: JSONValue, name: String) -> FadeConfig? {
        var kind: FadeConfig.Kind?
        if let value = json["type"] {
            kind = value.stringValue.flatMap(FadeConfig.Kind.init)
            if kind == nil { invalid(name, "fadeOut type", value, ["FIXED", "INCREMENTAL"]) }
        } else {
            missing(name, "fadeOut.type")
        }
        let time = json["time"]?.doubleValue
        if time == nil { missing(name, "fadeOut.time") }
        let unit = units(json["units"], name: name, key: "fadeOut.units")
        guard let kind, let time, let unit else { return nil }
        return FadeConfig(kind: kind, milliseconds: time * unit.milliseconds)
    }
}

enum Temperature {
    /// Not rounded, as the Homebridge plugin converts.
    static func celsius(fahrenheit: Double) -> Double { (fahrenheit - 32) * 5 / 9 }
    static func fahrenheit(celsius: Double) -> Double { (celsius * 9 / 5 + 32).rounded() }
}

/// A number as JavaScript writes it: `1`, `1.5`.
func javaScriptNumber(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e21 { return String(Int64(value)) }
    return "\(value)"
}
