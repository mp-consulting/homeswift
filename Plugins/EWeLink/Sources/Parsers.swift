import Foundation
import HomeswiftPlugin

/// Reads values out of device parameters the way the Homebridge plugin does: temperatures and humidities
/// reported ×100 are scaled back, strings are parsed, missing values fall back to defaults.
enum DeviceValueParser {
    /// `currentTemperature`, else `temperature`; values above 1000 were sent ×100.
    static func temperature(_ params: DeviceParams, default defaultValue: Double = 20) -> Double {
        for key in ["currentTemperature", "temperature"] {
            if let value = params[key], let temperature = value.jsParseFloat {
                return temperature > 1000 ? temperature / 100 : temperature
            }
        }
        return defaultValue
    }

    /// `currentHumidity`, else `humidity`; values above 100 were sent ×100.
    static func humidity(_ params: DeviceParams, default defaultValue: Double = 50) -> Double {
        for key in ["currentHumidity", "humidity"] {
            if let value = params[key], let humidity = value.jsParseFloat {
                return humidity > 100 ? humidity / 100 : humidity
            }
        }
        return defaultValue
    }

    static func battery(_ params: DeviceParams, default defaultValue: Double = 100) -> Double {
        guard let value = params["battery"] else { return defaultValue }
        return value.jsParseFloat ?? defaultValue
    }

    static func number(_ value: JSONValue?, default defaultValue: Double = 0) -> Double {
        guard let value, !value.isNull else { return defaultValue }
        return value.jsParseFloat ?? defaultValue
    }

    /// `'on'` (any case) or `true`.
    static func parseSwitch(_ value: JSONValue?) -> Bool {
        if case .bool(let flag) = value { return flag }
        return value?.jsString?.lowercased() == "on"
    }

    /// `true`, `1`, `'on'`, `'true'` or `'1'`.
    static func parseBoolean(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number == 1
        default:
            let text = value?.jsString?.lowercased() ?? "undefined"
            return text == "on" || text == "true" || text == "1"
        }
    }

    static func hasTemperature(_ params: DeviceParams) -> Bool { params["currentTemperature"] != nil || params["temperature"] != nil }
    static func hasHumidity(_ params: DeviceParams) -> Bool { params["currentHumidity"] != nil || params["humidity"] != nil }
    static func hasBattery(_ params: DeviceParams) -> Bool { params["battery"] != nil }
    static func hasPowerReadings(_ params: DeviceParams) -> Bool { params["power"] != nil || params["voltage"] != nil || params["current"] != nil }

    struct PowerReadings: Equatable {
        var power: Double?
        var voltage: Double?
        var current: Double?
    }

    /// `power`, `voltage` and `current` as numbers; a value that does not parse is NaN in JavaScript, and nil here.
    static func powerReadings(_ params: DeviceParams) -> PowerReadings {
        PowerReadings(power: params["power"]?.jsParseFloat, voltage: params["voltage"]?.jsParseFloat, current: params["current"]?.jsParseFloat)
    }

    /// Motion is `switch: 'on'` or `state: 1`.
    static func motionState(_ params: DeviceParams) -> Bool {
        params["switch"] == .string("on") || params["state"] == .number(1)
    }

    /// A contact sensor is open on `switch: 'on'` or `state: 1`.
    static func contactState(_ params: DeviceParams) -> Bool {
        params["switch"] == .string("on") || params["state"] == .number(1)
    }
}

/// Switch state for single-channel (`switch`) and multi-channel (`switches`) devices.
enum SwitchHelper {
    static func currentState(_ params: DeviceParams, channel: Int = 0) -> Bool {
        if let switches = params.switches {
            return isOn(switches.first { $0["outlet"]?.jsNumber == Double(channel) }?["switch"])
        }
        return isOn(params["switch"])
    }

    /// The command for one channel: the whole `switches` array with that outlet changed, or `switch`.
    static func switchParams(_ params: DeviceParams, channel: Int, on: Bool) -> DeviceParams {
        if let switches = params.switches {
            let updated: [JSONValue] = switches.map { entry in
                guard var object = entry.objectValue, entry["outlet"]?.jsNumber == Double(channel) else { return entry }
                object["switch"] = onOff(on)
                return .object(object)
            }
            return ["switches": .array(updated)]
        }
        return ["switch": onOff(on)]
    }

    static func channelCount(_ params: DeviceParams) -> Int {
        let count = params.switches?.count ?? 0
        return count == 0 ? 1 : count
    }

    static func isMultiChannel(_ params: DeviceParams) -> Bool { (params.switches?.count ?? 0) > 1 }

    /// Some single-channel devices report a `switches` array too.
    static func isSCMDevice(_ params: DeviceParams) -> Bool { params.switches != nil }
}

/// Colour conversions for lights and the diffuser (the eWeLink app's, not `Homeswift.ColorUtils`).
enum EWeLinkColor {
    static let minimumMired = 140.0
    static let maximumMired = 500.0
    static let miredRange = 360.0
    static let defaultMired = 320.0

    /// RGB (0-255) to hue (0-360), saturation and value (0-100), rounded.
    static func rgbToHSV(_ red: Double, _ green: Double, _ blue: Double) -> (h: Double, s: Double, v: Double) {
        let r = red / 255, g = green / 255, b = blue / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let difference = maximum - minimum
        var hue = 0.0
        let saturation = maximum == 0 ? 0 : difference / maximum * 100
        let value = maximum * 100
        if difference != 0 {
            switch maximum {
            case r: hue = ((g - b) / difference + (g < b ? 6 : 0)) * 60
            case g: hue = ((b - r) / difference + 2) * 60
            default: hue = ((r - g) / difference + 4) * 60
            }
        }
        return (jsRound(hue), jsRound(saturation), jsRound(value))
    }

    static func hsvToRGB(_ hue: Double, _ saturation: Double, _ value: Double) -> (r: Double, g: Double, b: Double) {
        let s = saturation / 100, v = value / 100
        let c = v * s
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double) =
            switch hue {
            case 0..<60: (c, x, 0)
            case 60..<120: (x, c, 0)
            case 120..<180: (0, c, x)
            case 180..<240: (0, x, c)
            case 240..<300: (x, 0, c)
            default: (c, 0, x)
            }
        return (jsRound((r + m) * 255), jsRound((g + m) * 255), jsRound((b + m) * 255))
    }

    /// The device's 0-100 colour temperature as mired (140-500).
    static func miredFromPercent(_ percent: Double) -> Double { jsRound(minimumMired + percent / 100 * miredRange) }

    static func percentFromMired(_ mired: Double) -> Double { jsRound((mired - minimumMired) / miredRange * 100) }

    /// Hue and saturation to RGB (pure-color's algorithm, as the Homebridge plugin uses for the diffuser).
    static func hsToRGB(_ hue: Double, _ saturation: Double) -> (r: Int, g: Int, b: Int) {
        let h = hue / 60, s = saturation / 100
        guard h.isFinite, s.isFinite else { return (255, 255, 255) }
        let f = h - h.rounded(.down)
        let p = 255 * (1 - s), q = 255 * (1 - s * f), t = 255 * (1 - s * (1 - f))
        let sector = Int(h.rounded(.down)) % 6
        var rgb: [Double]
        switch sector {
        case 0: rgb = [255, t, p]
        case 1: rgb = [q, 255, p]
        case 2: rgb = [p, 255, t]
        case 3: rgb = [p, q, 255]
        case 4: rgb = [t, p, 255]
        case 5: rgb = [255, p, q]
        default: return (255, 255, 255)
        }
        // Near-red colours become pure red.
        if rgb[0] == 255, rgb[1] <= 25, rgb[2] <= 25 {
            rgb[1] = 0
            rgb[2] = 0
        }
        return (Int(jsRound(rgb[0])), Int(jsRound(rgb[1])), Int(jsRound(rgb[2])))
    }

    static func rgbToHS(_ red: Double, _ green: Double, _ blue: Double) -> (h: Int, s: Int) {
        let minimum = min(red, green, blue), maximum = max(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        let saturation = maximum == 0 ? 0 : delta / maximum * 100
        if maximum == minimum {
            hue = 0
        } else if red == maximum {
            hue = (green - blue) / delta
        } else if green == maximum {
            hue = 2 + (blue - red) / delta
        } else {
            hue = 4 + (red - green) / delta
        }
        hue = min(hue * 60, 360)
        if hue < 0 { hue += 360 }
        return (Int(jsRound(hue)), Int(jsRound(saturation)))
    }
}

/// HomeKit's rules for Name and ConfiguredName (HAP-NodeJS checks them): letters, numbers, spaces, `’ ' . , -`,
/// starting with a letter or number and ending with one or `’`.
func sanitizeHomeKitName(_ name: String?, fallback: String = "Unnamed") -> String {
    guard let name, !name.isEmpty else { return fallback }
    var result = ""
    for character in name {
        if character.isLetter || character.isNumber || "’ '.,-".contains(character) {
            result.append(character)
        } else {
            result.append(" ")
        }
    }
    let collapsed = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let trimmed = collapsed.drop { !($0.isLetter || $0.isNumber) }
    var end = trimmed.endIndex
    while end > trimmed.startIndex {
        let previous = trimmed.index(before: end)
        let character = trimmed[previous]
        if character.isLetter || character.isNumber || character == "’" { break }
        end = previous
    }
    let final = String(trimmed[trimmed.startIndex..<end])
    return final.isEmpty ? fallback : final
}
