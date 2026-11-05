import Foundation
import Homeswift

/// The colour arithmetic of the Homebridge plugin (sections 5.2 and 5.3: doubles and JavaScript's rounding, so the bytes
/// are the same) and of the newer firmware (section 10.3, 10.4, 10.7).
enum MagicHomeColour {
    /// JavaScript's `Math.round`: halves go up.
    static func round(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// A level, rounded half up and clamped to a byte; 0 for NaN.
    static func byte(_ value: Double) -> UInt8 { UInt8(clamping: Int(saturating: round(value)) ?? 0) }

    // MARK: The Homebridge plugin's (section 5)

    /// HSV to RGB with the value fixed at 1: hue 0-360, saturation 0-100, each channel 0-255 rounded half up.
    static func fullColour(hue: Double, saturation: Double) -> (red: Double, green: Double, blue: Double) {
        let s = saturation / 100
        let h = hue / 360 * 6
        let sector = h.isFinite ? h.rounded(.down) : 0
        let f = h.isFinite ? h - sector : 0
        let p = 1 - s, q = 1 - f * s, t = 1 - (1 - f) * s
        let channels: (Double, Double, Double)
        switch (Int(saturating: sector) ?? 0) % 6 {
        case 0: channels = (1, t, p)
        case 1: channels = (q, 1, p)
        case 2: channels = (p, 1, t)
        case 3: channels = (p, q, 1)
        case 4: channels = (t, p, 1)
        default: channels = (1, p, q)
        }
        return (round(channels.0 * 255), round(channels.1 * 255), round(channels.2 * 255))
    }

    /// A 0-255 channel at a brightness of 0-100: `round(clamp(channel) / 100 × brightness)`, in that order.
    static func scaled(_ channel: Double, brightness: Double) -> UInt8 {
        byte(min(max(channel, 0), 255) / 100 * brightness)
    }

    /// The white of a brightness of 0-100: `round(255 / 100 × brightness)`.
    static func white(brightness: Double) -> UInt8 { byte(255 / 100 * brightness) }

    /// The warm and cold levels a hue stands for ("hue to white temperature"): red warm, cyan cold, 90 and 270 both.
    static func hueSplit(_ hue: Double) -> (warm: Double, cold: Double) {
        if hue <= 90 { return (255, round(255 * hue / 90)) }
        if hue <= 180 { return (round(255 * (1 - (hue - 90) / 90)), 255) }
        if hue <= 270 { return (round(255 * (hue - 180) / 90), 255) }
        return (255, round(255 * (1 - (hue - 270) / 90)))
    }

    /// RGB to HSV: hue 0-360, saturation and value 0-100, unrounded (section 5.3).
    static func hsv(red: UInt8, green: UInt8, blue: UInt8) -> (hue: Double, saturation: Double, value: Double) {
        let r = Double(red), g = Double(green), b = Double(blue)
        let high = max(r, g, b), low = min(r, g, b), d = high - low
        let saturation = high == 0 ? 0 : d / high * 100
        let value = high / 255 * 100
        guard d > 0 else { return (0, saturation, value) }
        let hue: Double
        if high == r {
            hue = ((g - b) + d * (g < b ? 6 : 0)) / (6 * d)
        } else if high == g {
            hue = ((b - r) + 2 * d) / (6 * d)
        } else {
            hue = ((r - g) + 4 * d) / (6 * d)
        }
        return (hue * 360, saturation, value)
    }

    // MARK: The newer firmware's (section 10)

    /// HSV to RGB, every value a fraction (hue 0-1 for 0-360°).
    static func rgb(hue: Double, saturation: Double, value: Double) -> (red: Double, green: Double, blue: Double) {
        let h = (hue.isFinite ? hue - hue.rounded(.down) : 0) * 6
        let sector = h.rounded(.down), f = h - sector
        let s = min(max(saturation, 0), 1), v = min(max(value, 0), 1)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(sector) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// RGB levels truncated, as flux_led converts (section 10.3.2): hue 0-360, saturation and value 0-100.
    static func truncatedRGB(hue: Double, saturation: Double, value: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let colour = rgb(hue: hue / 360, saturation: saturation / 100, value: value / 100)
        func channel(_ fraction: Double) -> UInt8 { UInt8(clamping: Int(saturating: (fraction * 255).rounded(.towardZero)) ?? 0) }
        return (channel(colour.red), channel(colour.green), channel(colour.blue))
    }

    /// Rounded to two decimals, as flux_led takes a brightness fraction.
    static func twoDecimals(_ value: Double) -> Double { round(value * 100) / 100 }

    /// A tunable white's temperature and brightness in percent to warm and cool levels (section 10.4.2).
    static func whiteLevels(temperaturePercent: Int, brightnessPercent: Int) -> (warm: UInt8, cool: UInt8) {
        let t = Double(min(max(temperaturePercent, 0), 100))
        let b = twoDecimals(Double(min(max(brightnessPercent, 0), 100)) / 100)
        let warmShare = (100 - t) / 100 * b
        return (byte(255 * (100 - t) / 100 * b), byte(255 * (b - warmShare)))
    }

    /// Warm and cool levels to the temperature and brightness in percent of the `35 B1` frame (section 10.3.5); the
    /// brightness is at least 2, below which the device turns from cool to warm.
    static func temperatureAndBrightness(warm: UInt8, cool: UInt8) -> (temperature: UInt8, brightness: UInt8) {
        let s = Double(warm) / 255 + Double(cool) / 255
        let temperature = s == 0 ? 0 : round(Double(cool) / 255 / s * 100)
        return (UInt8(min(max(temperature, 0), 100)), UInt8(max(2, min(100, round(s * 100)))))
    }

    // MARK: HomeKit's whites (section 10.7)

    /// The Color Temperature HomeKit is offered: 6500 K to 2700 K.
    static let miredRange = 154...370

    /// Mireds to the temperature fraction: 0 warm (2700 K), 1 cool (6500 K).
    static func temperatureFraction(mireds: Int) -> Double {
        let kelvin = 1_000_000 / Double(max(mireds, 1))
        return (min(max(kelvin, 2700), 6500) - 2700) / 3800
    }

    /// The temperature fraction to mireds, within `miredRange`.
    static func mireds(fraction: Double) -> Int {
        let t = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let mireds = Int(saturating: round(1_000_000 / (2700 + 3800 * t))) ?? miredRange.upperBound
        return min(max(mireds, miredRange.lowerBound), miredRange.upperBound)
    }

    /// The temperature fraction of warm and cool levels; nil when both are 0.
    static func temperatureFraction(warm: UInt8, cool: UInt8) -> Double? {
        let sum = Double(warm) + Double(cool)
        return sum == 0 ? nil : Double(cool) / sum
    }

    /// HomeKit's Brightness of warm and cool levels: their sum, capped at 255, in percent.
    static func brightness(warm: UInt8, cool: UInt8) -> Int {
        Int(round(100 * min(1, (Double(warm) + Double(cool)) / 255)))
    }

    /// The warm and cool levels of a temperature fraction and a brightness of 0-100.
    static func whiteLevels(fraction t: Double, brightness: Double) -> (warm: UInt8, cool: UInt8) {
        let b = min(max(brightness, 0), 100) / 100
        return (byte(255 * (1 - t) * b), byte(255 * t * b))
    }
}
