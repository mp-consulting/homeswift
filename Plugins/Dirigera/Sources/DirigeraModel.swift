import Foundation
import HomeswiftPlugin

/// A light, an outlet or a door and window sensor of the hub, in HomeKit's units.
struct DirigeraDevice: Sendable, Equatable {
    enum Kind: String, Sendable { case light, outlet, contact }

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

    var hasColour: Bool { hue != nil }

    /// A device of `GET /v1/devices`, or nil for one this plugin does not show (sensors, remotes, the hub).
    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        let kind: Kind
        switch (json["type"]?.stringValue, json["deviceType"]?.stringValue) {
        case ("light", _): kind = .light
        case ("outlet", _): kind = .outlet
        case ("sensor", "openCloseSensor"): kind = .contact
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
    }
}

/// A scene of the hub (`GET /v1/scenes`): user scenes, which a switch triggers.
struct DirigeraScene: Sendable, Equatable {
    var id: String
    var name: String
    var icon: String?

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue, let name = json["info"]?["name"]?.stringValue else { return nil }
        // Wake-up and playlist scenes run on their own schedule; the ones a person triggers are user and custom scenes.
        let type = json["type"]?.stringValue ?? "userScene"
        guard type == "userScene" || type == "customScene" else { return nil }
        self.id = id
        self.name = name
        icon = json["info"]?["icon"]?.stringValue
    }

    init(id: String, name: String, icon: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}
