import Foundation

/// The OpenAPI device types the plugin exposes, by family (§3.1 of docs/clean-room/SwitchBot.md).
enum Family: Sendable {
    case bot, relay, plug, curtain, rollerShade, blindTilt, meter, hub, motion, contact, presence, waterDetector, lock
    case light, humidifier, fan, vacuum, airPurifier

    init?(deviceType: String) {
        switch deviceType {
        case "Bot": self = .bot
        case "Relay Switch 1", "Relay Switch 1PM": self = .relay
        case "Plug", "Plug Mini (US)", "Plug Mini (JP)", "Plug Mini (EU)": self = .plug
        case "Curtain", "Curtain3": self = .curtain
        case "WoRollerShade", "Roller Shade": self = .rollerShade
        case "Blind Tilt": self = .blindTilt
        case "Meter", "MeterPlus", "Meter Plus (JP)", "Meter Pro", "MeterPro(CO2)", "WoIOSensor": self = .meter
        case "Hub 2", "Hub Mini 2", "Hub 3": self = .hub
        case "Motion Sensor": self = .motion
        case "Contact Sensor": self = .contact
        case "Presence Sensor": self = .presence
        case "Water Detector": self = .waterDetector
        case "Smart Lock", "Smart Lock Pro", "Smart Lock Ultra", "Lock Ultra": self = .lock
        case "Color Bulb", "Strip Light", "Ceiling Light", "Ceiling Light Pro": self = .light
        case "Humidifier", "Humidifier2": self = .humidifier
        case "Battery Circulator Fan": self = .fan
        case "K10+", "K10+ Pro", "WoSweeper", "WoSweeperMini", "Robot Vacuum Cleaner S1", "Robot Vacuum Cleaner S1 Plus", "Robot Vacuum Cleaner S10":
            self = .vacuum
        case "Air Purifier", "Air Purifier Table", "Air Purifier VOC", "Air Purifier Table VOC", "Air Purifier PM2.5", "Air Purifier Table PM2.5":
            self = .airPurifier
        default: return nil
        }
    }

    /// The Device Kind (`x-kinds` in the accessory schema).
    var kind: String {
        switch self {
        case .bot, .relay: "bot"
        case .plug: "plug"
        case .curtain, .rollerShade: "curtain"
        case .blindTilt: "blindTilt"
        case .meter, .hub, .motion, .contact, .presence, .waterDetector: "sensor"
        case .lock: "lock"
        case .light: "light"
        case .humidifier: "humidifier"
        case .fan: "fan"
        case .vacuum: "vacuum"
        case .airPurifier: "airPurifier"
        }
    }

    /// Types the plugin skips without a warning: they have nothing for HomeKit.
    static let silentlySkipped: Set<String> = ["Hub Mini", "Hub Plus", "Remote", "Indoor Cam", "remote with screen"]
}

/// The model codes 4.x shows in Accessory Information.
func modelCode(_ deviceType: String) -> String { modelCodes[deviceType] ?? "Unknown" }

private let modelCodes: [String: String] = [
        "Humidifier": "W0801800", "Humidifier2": "WXXXXXXX", "Hub 2": "W3202100", "Hub Mini 2": "W3202100", "Hub 3": "W3302100",
        "Bot": "SwitchBot S1", "Relay Switch 1": "W5502300", "Relay Switch 1PM": "W5502310", "Meter": "SwitchBot MeterTH S1",
        "MeterPlus": "W2301500", "Meter Plus (JP)": "W2201500", "Meter Pro": "W4900000", "MeterPro(CO2)": "W4900010", "WoIOSensor": "W3400010",
        "Water Detector": "W4402000", "Motion Sensor": "W1101500", "Presence Sensor": "W8200000", "Contact Sensor": "W1201500",
        "Curtain": "W0701600", "Curtain3": "W2400000", "WoRollerShade": "W2400000", "Roller Shade": "W2400000", "Blind Tilt": "W2701600",
        "Plug": "SP11", "Plug Mini (US)": "W1901400/W1901401", "Plug Mini (JP)": "W2001400/W2001401", "Plug Mini (EU)": "W7732300",
        "Smart Lock": "W1601700", "Smart Lock Pro": "W3500000", "Smart Lock Ultra": "W3600000", "Lock Ultra": "W3600000",
        "Color Bulb": "W1401400", "K10+": "K10+", "K10+ Pro": "K10+ Pro", "WoSweeper": "WoSweeper", "WoSweeperMini": "WoSweeperMini",
        "Robot Vacuum Cleaner S1": "W3011000", "Robot Vacuum Cleaner S1 Plus": "W3011010", "Robot Vacuum Cleaner S10": "W3211800",
        "Ceiling Light": "W2612230/W2612240", "Ceiling Light Pro": "W2612210/W2612220", "Strip Light": "W1701100",
        "Battery Circulator Fan": "W3800510", "Air Purifier": "W5302300", "Air Purifier VOC": "W5302300", "Air Purifier PM2.5": "W5302300",
        "Air Purifier Table": "W5302310", "Air Purifier Table VOC": "W5302310", "Air Purifier Table PM2.5": "W5302310",
]

/// The IR remote types (§3.3), a `DIY` one as its plain type.
enum RemoteFamily: Sendable {
    case television, fan, airConditioner, light, airPurifier, waterHeater, vacuumCleaner, camera, others

    init?(remoteType: String) {
        let base = remoteType.hasPrefix("DIY ") ? String(remoteType.dropFirst(4)) : remoteType
        switch base {
        case "TV", "Projector", "Set Top Box", "IPTV", "DVD", "Speaker": self = .television
        case "Fan": self = .fan
        case "Air Conditioner": self = .airConditioner
        case "Light": self = .light
        case "Air Purifier": self = .airPurifier
        case "Water Heater": self = .waterHeater
        case "Vacuum Cleaner": self = .vacuumCleaner
        case "Camera": self = .camera
        case "Others" where remoteType == "Others": self = .others
        default: return nil
        }
    }

    /// The Device Kind of every remote.
    static let kind = "remote"
}

/// A firmware version as 4.x shows it (§4.7): no leading `V`, nothing from the first `-`, and a dot between each
/// character when it has none (`V31` → `3.1`, `V4.2-1` → `4.2`).
func normalizedVersion(_ version: String?) -> String? {
    guard var text = version?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    if text.first == "V" || text.first == "v" { text.removeFirst() }
    if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
    guard !text.isEmpty else { return nil }
    if !text.contains(".") { text = text.map(String.init).joined(separator: ".") }
    return text
}

/// A display name as 4.x cleans it (§4.6): letters, digits, spaces and apostrophes, starting and ending with a letter or
/// a digit.
func cleanedName(_ name: String) -> String {
    let kept = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" }.map(Character.init))
    let trimmed = kept.drop { !$0.isLetter && !$0.isNumber }.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed()
    return String(trimmed)
}
