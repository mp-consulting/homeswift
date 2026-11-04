import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

/// What a device is, from its `type` (docs/clean-room/Tapo.md, 1 and 3.1), matched case-insensitively; anything else is
/// a plug. `WhiteLight` is a white lightbulb: the Homebridge plugin meant it so, but compared it in a way that never
/// matched, which made such a bulb an Outlet there.
enum TapoKind: String, Sendable, Equatable, CaseIterable {
    case plug, powerPlug, light, whiteLight, colorLight

    init(type: String?) {
        switch type?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "powerplug": self = .powerPlug
        case "light": self = .light
        case "whitelight": self = .whiteLight
        case "colorlight": self = .colorLight
        default: self = .plug
        }
    }

    /// Accessory Information's Model: one per kind, not the device's own.
    var model: String {
        switch self {
        case .plug: "Tapo P100"
        case .powerPlug: "Tapo P110"
        case .light: "Tapo L510E"
        case .whiteLight: "Tapo L520E"
        case .colorLight: "Tapo L530"
        }
    }

    var isLight: Bool { self == .light || self == .whiteLight || self == .colorLight }
    var hasColor: Bool { self == .colorLight }
    var measuresEnergy: Bool { self == .powerPlug || self == .colorLight }

    /// Color Temperature's range in mireds, for the bulbs that have one.
    var colorTemperatureRange: ClosedRange<Int>? {
        switch self {
        case .whiteLight: 154...400
        case .colorLight: 140...400
        default: nil
        }
    }
}

/// What `get_device_info` reports, in the device's units: kelvin, 0 in colour mode.
struct TapoState: Sendable, Equatable {
    var on: Bool?
    var brightness: Int?
    var kelvin: Int?
    var hue: Int?
    var saturation: Int?
    var hardwareID: String?
    var firmware: String?

    init(on: Bool? = nil, brightness: Int? = nil, kelvin: Int? = nil, hue: Int? = nil, saturation: Int? = nil) {
        self.on = on
        self.brightness = brightness
        self.kelvin = kelvin
        self.hue = hue
        self.saturation = saturation
    }

    init(info: JSONValue) {
        on = info["device_on"]?.boolValue
        brightness = info["brightness"]?.saturatingIntValue
        kelvin = info["color_temp"]?.saturatingIntValue
        hue = info["hue"]?.saturatingIntValue
        saturation = info["saturation"]?.saturatingIntValue
        hardwareID = info["hw_id"]?.stringValue
        firmware = info["fw_ver"]?.stringValue
    }

    /// The firmware's version as HAP takes it: `1.2.1 Build 20200616 Rel. 31218` is `1.2.1`.
    var firmwareRevision: String? {
        guard let version = firmware?.split(separator: " ").first, version.allSatisfy({ $0.isNumber || $0 == "." }), version.first?.isNumber == true else { return nil }
        return String(version)
    }
}

/// The conversions between HomeKit's units and the device's (docs/clean-room/Tapo.md, 3.5).
enum TapoConversion {
    static let kelvinRange = 2500...6500
    /// What a read of the device's white shows, whatever the bulb's own range.
    static let miredsRange = 154...400

    /// floor(1 000 000 / mireds), within 2500-6500 K.
    static func kelvin(mireds: Int) -> Int {
        guard mireds > 0 else { return kelvinRange.upperBound }
        return min(max(1_000_000 / mireds, kelvinRange.lowerBound), kelvinRange.upperBound)
    }

    /// floor(1 000 000 / kelvin), within 154-400 mireds; 400 for none.
    static func mireds(kelvin: Int) -> Int {
        guard kelvin > 0 else { return miredsRange.upperBound }
        return min(max(1_000_000 / kelvin, miredsRange.lowerBound), miredsRange.upperBound)
    }
}

/// A device's energy: the power now in watts, and today's energy in kWh (the devices count from midnight).
struct TapoEnergy: Sendable, Equatable {
    var watts: Double
    var todayKWh: Double

    /// A P110's `get_energy_usage`: `current_power` in milliwatts, `today_energy` in watt-hours.
    init?(plugUsage usage: JSONValue) {
        guard let milliwatts = usage["current_power"]?.doubleValue?.finite else { return nil }
        watts = max(0, milliwatts / 1000)
        todayKWh = max(0, (usage["today_energy"]?.doubleValue?.finite ?? 0) / 1000)
    }

    /// An L530's `get_device_usage`: today's watt-hours over today's hours on, so an average while on, not the power
    /// now; 0 while off or before it has been on today.
    init?(bulbUsage usage: JSONValue, isOn: Bool) {
        guard let wattHours = usage["power_usage"]?["today"]?.doubleValue?.finite else { return nil }
        let minutes = usage["time_usage"]?["today"]?.doubleValue?.finite ?? 0
        todayKWh = max(0, wattHours / 1000)
        watts = isOn && minutes > 0 ? max(0, wattHours / (minutes / 60)) : 0
    }

    init(watts: Double, todayKWh: Double) {
        self.watts = watts
        self.todayKWh = todayKWh
    }
}

/// The writes HomeKit made within a moment, sent together: on or off first, then the brightness, then a white or a
/// colour (the later of the two). Hue and Saturation become one request.
struct TapoWrite: Sendable, Equatable {
    var on: Bool?
    var brightness: Int?
    var mireds: Int?
    var hue: Int?
    var saturation: Int?

    var isEmpty: Bool { self == TapoWrite() }

    mutating func merge(_ later: TapoWrite) {
        if let on = later.on { self.on = on }
        if let brightness = later.brightness { self.brightness = brightness }
        if let mireds = later.mireds {
            self.mireds = mireds
            hue = nil
            saturation = nil
        }
        if later.hue != nil || later.saturation != nil {
            mireds = nil
            if let hue = later.hue { self.hue = hue }
            if let saturation = later.saturation { self.saturation = saturation }
        }
    }
}
