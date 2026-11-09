import Foundation
import Homeswift
import HomeswiftPlugin

/// The services of one Dummy accessory the engine shows its state on.
struct DeviceServices: Sendable {
    let primary: Service
    let sensor: Service?
    let history: EveHistory?
}

/// Where a change comes from: it decides the logs, commands and the sensor's pulse (spec 7.1, 7.5).
enum ChangeSource: Sendable, Equatable {
    case homeKit, webhook, sync, schedule, condition, conditionReset, autoReset, limiter, fade, restore

    /// A reset that pulses a TIMER sensor: an auto-reset, a limiter's expiry, conditions no longer met.
    var isReset: Bool { self == .autoReset || self == .limiter || self == .conditionReset }
}

/// The three timers a schedule can drive.
enum TimerSlot: String, Sendable, CaseIterable {
    case schedule, autoReset

    var storedKey: String {
        switch self {
        case .schedule: "Schedule"
        case .autoReset: "AutoReset"
        }
    }

    var verb: String {
        switch self {
        case .schedule: "trigger"
        case .autoReset: "reset"
        }
    }

    var label: String {
        switch self {
        case .schedule: "schedule"
        case .autoReset: "auto-reset"
        }
    }
}

/// A limiter's usage (spec 6.3), stored as the Homebridge plugin stores it.
struct LimiterRecord: Codable, Sendable, Equatable {
    var timeRemaining: Double
    var resetTimestamp: Double
    var startTimestamp: Double?

    var json: JSONValue {
        var object: [String: JSONValue] = ["timeRemaining": .number(timeRemaining), "resetTimestamp": .number(resetTimestamp)]
        if let startTimestamp { object["startTimestamp"] = .number(startTimestamp) }
        return .object(object)
    }

    init(timeRemaining: Double, resetTimestamp: Double, startTimestamp: Double? = nil) {
        self.timeRemaining = timeRemaining
        self.resetTimestamp = resetTimestamp
        self.startTimestamp = startTimestamp
    }

    init?(_ json: JSONValue?) {
        guard let remaining = json?["timeRemaining"]?.doubleValue, let reset = json?["resetTimestamp"]?.doubleValue else { return nil }
        self.init(timeRemaining: remaining, resetTimestamp: reset, startTimestamp: json?["startTimestamp"]?.doubleValue)
    }
}

/// One configured accessory's state and timers. It lives inside `DummyEngine` and is only touched there.
final class DummyDevice {
    let config: AccessoryConfig
    let services: DeviceServices

    /// The main value: On (1/0), Lock Target State, Target Position (0/100), Target Door State, Active, or a sensor's
    /// 0/1.
    var primary: Int
    let defaultPrimary: Int
    let triggeredPrimary: Int

    var brightness = 100
    var fadeValue: Int?
    var fadeTimer: DummyTimer?

    var timeouts: [TimerSlot: DummyTimer] = [:]
    var expiries: [TimerSlot: Double] = [:]
    var repeating: [TimerSlot: DummyTimer] = [:]
    /// The stored expiries left from before the restart, used the first time their timer starts.
    var resumable: Set<String> = []

    var limiterID: String?
    var limiter: LimiterRecord?
    var limiterTimer: DummyTimer?

    var sensorActive = false
    var sensorPulse: DummyTimer?

    /// Current Position or Current Door State while a simulation runs.
    var current: Int
    var simulationTimer: DummyTimer?

    /// Valve: Set Duration in seconds, and the auto-reset's duration HomeKit chose since launch.
    var setDuration: Int?
    var autoResetOverride: Double?

    // Thermostat, humidifier and value sensors.
    var targetMode = 0
    var currentMode = 0
    var currentModeExplicit = false
    var targetTemperature = 20.0
    var currentTemperature = 20.0
    var currentTemperatureExplicit = false
    var targetHumidity = 50.0
    var currentHumidity = 50.0
    var currentHumidityExplicit = false
    var value = 0.0
    /// A humidifier reports to conditions only once its state was set.
    var hasBeenSet = false

    init(config: AccessoryConfig, services: DeviceServices) {
        self.config = config
        self.services = services
        switch config.family {
        case .onOff, .valve, .humidifier:
            defaultPrimary = config.defaultOn ? 1 : 0
            triggeredPrimary = 1 - defaultPrimary
        case .lock:
            defaultPrimary = config.defaultLocked ? 1 : 0
            triggeredPrimary = 1 - defaultPrimary
        case .position:
            defaultPrimary = config.defaultOpen ? 100 : 0
            triggeredPrimary = config.defaultOpen ? 0 : 100
        case .garage:
            defaultPrimary = config.defaultOpen ? 0 : 1
            triggeredPrimary = 1 - defaultPrimary
        case .binarySensor:
            defaultPrimary = 0
            triggeredPrimary = 1
        case .button, .thermostat, .valueSensor:
            defaultPrimary = 0
            triggeredPrimary = 0
        }
        primary = defaultPrimary
        current = defaultPrimary
        if config.type == .thermostat {
            targetMode = config.validStates.contains(config.defaultThermostatState) ? config.defaultThermostatState : (config.validStates.first ?? 0)
            currentMode = targetMode == 3 ? 0 : targetMode
            targetTemperature = min(max(config.defaultTemperature, config.minimumTemperature), config.maximumTemperature)
            currentTemperature = targetTemperature
        }
    }

    var name: String { config.name }
    var identifier: String { config.identifier }
    var isTriggered: Bool { primary != defaultPrimary }

    /// The key the main value is stored under, and its stored form.
    var primaryKey: String {
        switch config.family {
        case .onOff, .valve, .humidifier: "On"
        case .lock: "LockTargetState"
        case .position: "TargetPosition"
        case .garage: "TargetDoorState"
        case .binarySensor: config.type.sensorKey
        default: ""
        }
    }

    var storedPrimary: JSONValue {
        switch config.family {
        case .onOff: .bool(primary == 1)
        case .binarySensor where config.type == .motionSensor: .bool(primary == 1)
        default: .number(Double(primary))
        }
    }

    func primary(fromStored value: JSONValue) -> Int? {
        if let bool = value.boolValue { return bool ? 1 : 0 }
        guard let number = value.doubleValue, number.isFinite else { return nil }
        if config.family == .position { return config.exactPosition ? Int(min(max(number, 0), 100)) : number == 0 ? 0 : 100 }
        return number == 0 ? 0 : 1
    }

    /// What it tells the condition engine: nil for the types that do not report.
    var conditionState: String? {
        switch config.family {
        case .onOff, .valve: primary == 1 ? "on" : "off"
        case .humidifier: hasBeenSet ? (primary == 1 ? "on" : "off") : nil
        case .position: primary == 0 ? "closed" : "open"
        case .garage: primary == 1 ? "closed" : "open"
        case .lock: primary == 1 ? "locked" : "unlocked"
        default: nil
        }
    }

    var isOpen: Bool {
        switch config.family {
        case .position: primary != 0
        case .garage: primary == 0
        default: false
        }
    }

    /// A temperature as the block gives it: °C or, with `temperatureUnits: "F"`, °F rounded.
    func shownTemperature(_ celsius: Double) -> Double {
        config.fahrenheit ? Temperature.fahrenheit(celsius: celsius) : celsius
    }

    func temperatureText(_ celsius: Double) -> String {
        "\(javaScriptNumber(shownTemperature(celsius)))°\(config.fahrenheit ? "F" : "C")"
    }

    /// The log line for the main value, also a webhook's answer (spec 12).
    var stateMessage: String {
        switch config.family {
        case .onOff:
            if primary == 1, config.isDimmer { return "\(name) is on, brightness is \(brightness)%" }
            return "\(name) is \(primary == 1 ? "on" : "off")"
        case .valve, .humidifier: return "\(name) is \(primary == 1 ? "on" : "off")"
        case .lock: return "\(name) is \(primary == 1 ? "locked" : "unlocked")"
        case .position where config.exactPosition && primary > 0 && primary < 100: return "\(name) is \(primary)% open"
        case .position, .garage: return "\(name) is \(isOpen ? "open" : "closed")"
        case .binarySensor:
            let words = config.type.sensorWords
            return "\(name) \(primary == 1 ? words.on : words.off)"
        case .thermostat: return "\(name) set to \(Self.modeNames[targetMode])"
        case .valueSensor:
            return config.type == .temperatureSensor ? "\(name) is \(temperatureText(value))" : "\(name) humidity is \(javaScriptNumber(value))%"
        case .button: return "\(name)"
        }
    }

    static let modeNames = ["Off", "Heat", "Cool", "Auto"]
    static let pressNames = ["single", "double", "long"]

    func pressMessage(_ value: Int) -> String { "\(name) was \(Self.pressNames[min(max(value, 0), 2)]) pressed" }
}
