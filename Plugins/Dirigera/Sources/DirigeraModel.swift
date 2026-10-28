import Foundation
import HomeswiftPlugin

/// A device of the hub, in HomeKit's units: a light, an outlet, a door and window sensor, or (DirigeraSensors.swift) a
/// motion, light, air or water sensor, a blind, an air purifier or a remote's button.
struct DirigeraDevice: Sendable, Equatable {
    enum Kind: String, Sendable { case light, outlet, contact, motion, lightSensor, environment, leak, blinds, airPurifier, controller }

    var id: String
    var kind: Kind
    var name: String
    var model: String
    var manufacturer: String
    var serial: String
    var firmware: String
    var room: String?
    var reachable: Bool
    var on: Bool
    /// 1-100, nil when the device does not dim.
    var brightness: Int?
    /// 0-360 and 0-100, nil without colour.
    var hue: Double?
    var saturation: Double?
    /// In mirek, and the range the light takes; nil without a white temperature.
    var mirek: Int?
    var mirekRange: ClosedRange<Int>?
    /// A sensor's: whether the door or window is open, and its battery (0-100).
    var open = false
    var battery: Int?
    /// The device it is part of (a VALLHORN's motion and light sensors, a remote's buttons): one accessory for them all.
    var relationID: String?
    /// A motion or occupancy sensor's, a water sensor's.
    var detected = false
    var leak = false
    /// A light sensor's, in lux.
    var illuminance: Double?
    /// An environment sensor's, each only when it measures it: °C, %, µg/m³, Sensirion's VOC index (100 is average), ppm.
    var temperature: Double?
    var humidity: Double?
    var pm25: Double?
    var vocIndex: Double?
    var co2: Double?
    /// A blind's: IKEA's level, 0 fully open to 100 fully closed, and whether it moves (`up`, `down`, `stopped`).
    var blindsLevel: Int?
    var blindsTarget: Int?
    var blindsState: String?
    /// An air purifier's: its mode (`auto`, `low`, `medium`, `high`, `on`, `off`), its motor (0 to 50), its filter
    /// (in minutes) and its child lock.
    var fanMode: String?
    var motorState: Int?
    var filterAlarm = false
    var filterElapsed: Double?
    var filterLifetime: Double?
    var childLock: Bool?
    /// A button's place on its remote (BILRESA's `switchGroup`), for its number.
    var switchGroup: Int?

    var hasColour: Bool { hue != nil }
    /// The kinds that have an accessory of their own, by device id (the ones this plugin started with).
    var isStandalone: Bool { kind == .light || kind == .outlet || kind == .contact }
    /// The id of the accessory it shows on (`Dirigera:<groupID>`): its own for a light, an outlet or a contact sensor,
    /// its relation's for a part of a product (a VALLHORN's sensors, a remote's buttons).
    var groupID: String { isStandalone ? id : relationID ?? id }

    /// A device of `GET /v1/devices`, or nil for one this plugin does not show (speakers, repeaters, the hub).
    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        let kind: Kind
        switch (json["type"]?.stringValue, json["deviceType"]?.stringValue) {
        case ("light", _): kind = .light
        case ("outlet", _): kind = .outlet
        case ("sensor", "openCloseSensor"): kind = .contact
        case (_, "motionSensor"), (_, "occupancySensor"): kind = .motion
        case (_, "lightSensor"): kind = .lightSensor
        case (_, "environmentSensor"): kind = .environment
        case (_, "waterSensor"): kind = .leak
        case ("blinds", _): kind = .blinds
        case ("airPurifier", _): kind = .airPurifier
        case ("controller", _): kind = .controller
        default: return nil
        }
        let attributes = json["attributes"]
        let writable = Set((json["capabilities"]?["canReceive"]?.arrayValue ?? []).compactMap(\.stringValue))
        self.id = id
        self.kind = kind
        name = attributes?["customName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? attributes?["model"]?.stringValue ?? "IKEA \(kind.rawValue)"
        model = attributes?["model"]?.stringValue ?? "DIRIGERA \(kind.rawValue)"
        manufacturer = attributes?["manufacturer"]?.stringValue ?? "IKEA of Sweden"
        serial = attributes?["serialNumber"]?.stringValue ?? id
        firmware = attributes?["firmwareVersion"]?.stringValue ?? ""
        room = json["room"]?["name"]?.stringValue
        reachable = json["isReachable"]?.boolValue ?? true
        on = attributes?["isOn"]?.boolValue ?? false
        open = attributes?["isOpen"]?.boolValue ?? false
        battery = attributes?["batteryPercentage"]?.intValue
        relationID = json["relationId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switchGroup = attributes?["switchGroup"]?.intValue
        applySensors(attributes)
        // Plugs list lightLevel too, though they only switch: a level is a light's.
        if kind == .light, writable.contains("lightLevel"), let level = attributes?["lightLevel"]?.doubleValue { brightness = Int(level.rounded()) }
        if writable.contains("colorHue"), let hue = attributes?["colorHue"]?.doubleValue {
            self.hue = hue
            saturation = (attributes?["colorSaturation"]?.doubleValue ?? 0) * 100
        }
        if writable.contains("colorTemperature") {
            // Kelvin, with the bounds inverted (Min is the coldest); some bulbs give the bounds in mireds.
            let bound = { (value: Double?) -> Int? in value.map { $0 < 1000 ? Int($0.rounded()) : Int((1_000_000 / $0).rounded()) } }
            let first = bound(attributes?["colorTemperatureMin"]?.doubleValue) ?? 153
            let second = bound(attributes?["colorTemperatureMax"]?.doubleValue) ?? 454
            mirekRange = min(first, second)...max(first, second)
            if let kelvin = attributes?["colorTemperature"]?.doubleValue, kelvin > 0 { mirek = Int((1_000_000 / kelvin).rounded()) }
        }
    }

    /// Applies a `deviceStateChanged` event's attributes (only the ones that changed).
    mutating func apply(_ attributes: JSONValue?, reachable: Bool?) {
        if let reachable { self.reachable = reachable }
        guard let attributes else { return }
        if let on = attributes["isOn"]?.boolValue { self.on = on }
        if let open = attributes["isOpen"]?.boolValue { self.open = open }
        if let battery = attributes["batteryPercentage"]?.intValue { self.battery = battery }
        if let level = attributes["lightLevel"]?.doubleValue, brightness != nil { brightness = Int(level.rounded()) }
        if let hue = attributes["colorHue"]?.doubleValue, self.hue != nil { self.hue = hue }
        if let saturation = attributes["colorSaturation"]?.doubleValue, self.saturation != nil { self.saturation = saturation * 100 }
        if let kelvin = attributes["colorTemperature"]?.doubleValue, kelvin > 0, mirekRange != nil { mirek = Int((1_000_000 / kelvin).rounded()) }
        if let name = attributes["customName"]?.stringValue, !name.isEmpty { self.name = name }
        applySensors(attributes)
    }

    /// The attributes of sensors, blinds and air purifiers that `attributes` has (all of them in a read, the changed
    /// ones in an event).
    private mutating func applySensors(_ attributes: JSONValue?) {
        guard let attributes else { return }
        if let detected = attributes["isDetected"]?.boolValue { self.detected = detected }
        if let leak = attributes["waterLeakDetected"]?.boolValue { self.leak = leak }
        if let lux = attributes["illuminance"]?.doubleValue { illuminance = lux }
        if let value = attributes["currentTemperature"]?.doubleValue { temperature = value }
        if let value = attributes["currentRH"]?.doubleValue { humidity = value }
        if let value = attributes["currentPM25"]?.doubleValue { pm25 = value }
        if let value = attributes["vocIndex"]?.doubleValue { vocIndex = value }
        if let value = attributes["currentCO2"]?.doubleValue { co2 = value }
        if let level = attributes["blindsCurrentLevel"]?.intValue { blindsLevel = level }
        if let level = attributes["blindsTargetLevel"]?.intValue { blindsTarget = level }
        if let state = attributes["blindsState"]?.stringValue { blindsState = state }
        if let mode = attributes["fanMode"]?.stringValue { fanMode = mode }
        if let motor = attributes["motorState"]?.intValue { motorState = motor }
        if let alarm = attributes["filterAlarmStatus"]?.boolValue { filterAlarm = alarm }
        if let elapsed = attributes["filterElapsedTime"]?.doubleValue { filterElapsed = elapsed }
        if let lifetime = attributes["filterLifetime"]?.doubleValue { filterLifetime = lifetime }
        if let lock = attributes["childLock"]?.boolValue { childLock = lock }
    }
}

/// A scene of the hub (`GET /v1/scenes`). User and custom scenes are the ones a person runs, which a switch
/// triggers; wake-up and playlist scenes run on their own schedule, so the page shows them without running them.
struct DirigeraScene: Sendable, Equatable {
    var id: String
    var name: String
    var icon: String?
    /// The hub's `type`: `userScene`, `customScene`, `wakeUpScene`…
    var type: String

    var isRunnable: Bool { type == "userScene" || type == "customScene" }

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue, let name = json["info"]?["name"]?.stringValue else { return nil }
        self.id = id
        self.name = name
        icon = json["info"]?["icon"]?.stringValue
        type = json["type"]?.stringValue ?? "userScene"
    }

    init(id: String, name: String, icon: String? = nil, type: String = "userScene") {
        self.id = id
        self.name = name
        self.icon = icon
        self.type = type
    }
}
