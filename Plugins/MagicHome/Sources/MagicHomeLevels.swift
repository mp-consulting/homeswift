import Foundation
import Homeswift

/// A light as the plugin keeps it between HomeKit's writes and the device's reports (section 5.2): what the next level
/// frame is made from. Before any report: hue 255, saturation 100, full brightness, on.
struct MagicHomeLight: Sendable, Equatable {
    var isOn = true
    /// 0-360.
    var hue: Double = 255
    /// 0-100.
    var saturation: Double = 100
    /// 0-100.
    var brightness: Double = 100
    /// The last colour temperature, nil before one was set or reported.
    var mireds: Int?
    /// The last change was a colour temperature, not a colour.
    var showsWhite = false
}

/// The `whiteEffects` block, with its defaults (section 2).
struct MagicHomeWhiteEffects: Sendable, Equatable {
    /// `simultaniousDevicesColorWhite`.
    var simultaneous = true
    /// `colorWhiteThreshold`: below it a non-simultaneous device shows white.
    var colorWhiteThreshold: Double = 10
    /// `colorWhiteThresholdSimultaniousDevices`: below it a simultaneous device mixes colour and white.
    var mixThreshold: Double = 50
    /// `colorOffThresholdSimultaniousDevices`: below it a simultaneous device shows white only.
    var offThreshold: Double = 5
}

/// A frame to send: wrapped (version 1, or 2 for the 25-byte level frame) by the connection, which keeps the counter,
/// after `delay`.
struct MagicHomeOutgoing: Sendable, Equatable {
    var bytes: [UInt8]
    var wrapVersion: UInt8?
    var delay: Duration = .zero

    static func plain(_ bytes: [UInt8]) -> MagicHomeOutgoing { MagicHomeOutgoing(bytes: bytes, wrapVersion: nil) }
}

/// Levels the newer firmware's rules turn into frames (section 10.3): a colour, whites, or both; 0-255 each.
struct MagicHomeLevelRequest: Sendable, Equatable {
    var colour: (red: UInt8, green: UInt8, blue: UInt8)?
    var warm: UInt8?
    var cool: UInt8?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.colour?.red == rhs.colour?.red && lhs.colour?.green == rhs.colour?.green && lhs.colour?.blue == rhs.colour?.blue
            && lhs.warm == rhs.warm && lhs.cool == rhs.cool
    }
}

/// From a light's state to the level frames its device takes.
enum MagicHomeLevels {
    /// The frames that show `light` (on): its colour temperature on a tunable white whose last change was one, its colour
    /// otherwise.
    static func frames(for light: MagicHomeLight, profile: MagicHomeProfile, effects: MagicHomeWhiteEffects) -> [MagicHomeOutgoing] {
        if profile.hasTemperature, light.showsWhite, let mireds = light.mireds {
            return whiteFrames(mireds: mireds, brightness: light.brightness, profile: profile)
        }
        switch profile.writer {
        case .powerOnly:
            return []
        case .percentCCT, .remappedCCT:
            return whiteFrames(mireds: light.mireds ?? MagicHomeColour.miredRange.upperBound, brightness: light.brightness, profile: profile)
        case .original(let logic):
            return original(logic, light: light, effects: effects).map(MagicHomeOutgoing.plain)
        case .family:
            return family(profile: profile, request: request(for: light, profile: profile, effects: effects))
        }
    }

    // MARK: The Homebridge plugin's branches (section 5.2)

    static func isWarmPreset(_ light: MagicHomeLight) -> Bool { light.hue == 31 && light.saturation == 33 }
    static func isCoolPreset(_ light: MagicHomeLight) -> Bool { light.hue == 208 && light.saturation == 17 }

    /// The level frame(s) the Homebridge plugin sends for a logic type: HSV to RGB at value 1, scaled by the brightness,
    /// with the white branches of its thresholds and HomeKit's two white swatches.
    static func original(_ logic: MagicHomeLogic, light: MagicHomeLight, effects: MagicHomeWhiteEffects) -> [[UInt8]] {
        let brightness = light.brightness, saturation = light.saturation
        let full = MagicHomeColour.fullColour(hue: light.hue, saturation: saturation)
        let r = MagicHomeColour.scaled(full.red, brightness: brightness)
        let g = MagicHomeColour.scaled(full.green, brightness: brightness)
        let b = MagicHomeColour.scaled(full.blue, brightness: brightness)
        let white = MagicHomeColour.white(brightness: brightness)
        let presets = isWarmPreset(light) || isCoolPreset(light)
        /// The colour at full saturation, not scaled: the mixing branches.
        func pure() -> (UInt8, UInt8, UInt8) {
            let colour = MagicHomeColour.fullColour(hue: light.hue, saturation: 100)
            return (MagicHomeColour.byte(colour.red), MagicHomeColour.byte(colour.green), MagicHomeColour.byte(colour.blue))
        }
        func split() -> (UInt8, UInt8) {
            let whites = MagicHomeColour.hueSplit(light.hue)
            return (MagicHomeColour.scaled(whites.warm, brightness: brightness), MagicHomeColour.scaled(whites.cold, brightness: brightness))
        }
        switch logic {
        case .rgbStrip, .grbStrip:
            return [MagicHomeFrame.levels(red: r, green: g, blue: b, white: 0, mask: 0xF0)]
        case .rgbwBulb:
            if saturation < effects.colorWhiteThreshold || presets || (light.hue == 0 && saturation == 0) {
                return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, white: white, mask: 0x0F)]
            }
            return [MagicHomeFrame.levels(red: r, green: g, blue: b, white: 0, mask: 0xF0)]
        case .rgbwStrip:
            if presets || (light.hue == 0 && saturation == 0) || saturation < effects.offThreshold {
                return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, white: white, mask: 0xFF)]
            }
            if saturation < effects.mixThreshold, effects.simultaneous {
                let colour = pure()
                return [MagicHomeFrame.levels(red: colour.0, green: colour.1, blue: colour.2, white: white, mask: 0xFF)]
            }
            return [MagicHomeFrame.levels(red: r, green: g, blue: b, white: 0, mask: 0xFF)]
        case .rgbwwStrip:
            if isWarmPreset(light) { return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: white, cool: 0, mask: 0x0F)] }
            if isCoolPreset(light) { return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: 0, cool: white, mask: 0x0F)] }
            let (warm, cool) = split()
            if saturation < effects.offThreshold { return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: warm, cool: cool, mask: 0xFF)] }
            if saturation < effects.mixThreshold, effects.simultaneous {
                let colour = pure()
                return [MagicHomeFrame.levels(red: colour.0, green: colour.1, blue: colour.2, warm: warm, cool: cool, mask: 0xFF)]
            }
            return [MagicHomeFrame.levels(red: r, green: g, blue: b, warm: 0, cool: 0, mask: 0xFF)]
        case .rgbwwBulb:
            if isWarmPreset(light) { return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: white, cool: 0, mask: 0x0F)] }
            if isCoolPreset(light) { return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: 0, cool: white, mask: 0x0F)] }
            if saturation < effects.colorWhiteThreshold {
                let (warm, cool) = split()
                return [MagicHomeFrame.levels(red: 0, green: 0, blue: 0, warm: warm, cool: cool, mask: 0x0F)]
            }
            return [MagicHomeFrame.levels(red: r, green: g, blue: b, warm: 0, cool: 0, mask: 0xF0)]
        case .dimmerStrip:
            // Its intended write: the level in the red channel (section 5.2's recommendation).
            return [MagicHomeFrame.levels(red: MagicHomeColour.byte(2.55 * brightness), green: 0, blue: 0, white: 0, mask: 0xF0)]
        case .switch, .cctStrip:
            // 09, the Homebridge plugin's CCT strip, is driven as section 10.7 says (`percentCCT`).
            return []
        }
    }

    // MARK: Whites (section 10.7)

    /// A colour temperature at a brightness of 0-100, in the form the device takes.
    static func whiteFrames(mireds: Int, brightness: Double, profile: MagicHomeProfile) -> [MagicHomeOutgoing] {
        let t = MagicHomeColour.temperatureFraction(mireds: mireds)
        let percent = MagicHomeColour.byte(100 * t)
        let level = min(max(brightness, 0), 100)
        if profile.writer == .percentCCT {
            let frame = MagicHomeFrame.temperature(percent, brightness: max(2, MagicHomeColour.byte(level)))
            return [MagicHomeOutgoing(bytes: frame, wrapVersion: profile.family.wrapsRequests ? 1 : nil)]
        }
        if profile.family == .twentyFiveByte || profile.family == .extendedCustom {
            let frame = MagicHomeFrame.extendedLevels(mask: 0xB1, hue: 0, saturation: 0, value: 0, temperature: percent, brightness: MagicHomeColour.byte(level))
            return [MagicHomeOutgoing(bytes: frame, wrapVersion: 2)]
        }
        let whites = MagicHomeColour.whiteLevels(fraction: t, brightness: level)
        return family(profile: profile, request: MagicHomeLevelRequest(colour: nil, warm: whites.warm, cool: whites.cool))
    }

    // MARK: The newer firmware's rules (section 10.3)

    /// What HomeKit's colour asks of a device driven by its family's rules: the colour at the brightness (truncated, as
    /// flux_led does), a dimmer's level, or the white of an RGB/W light below `colorWhiteThreshold` and on HomeKit's white
    /// swatches, as the Homebridge plugin had it.
    static func request(for light: MagicHomeLight, profile: MagicHomeProfile, effects: MagicHomeWhiteEffects) -> MagicHomeLevelRequest {
        let white = MagicHomeColour.white(brightness: light.brightness)
        switch profile.mode {
        case .dim, .cct, .none:
            return MagicHomeLevelRequest(colour: nil, warm: white, cool: nil)
        case .rgbOrWhite where light.saturation < effects.colorWhiteThreshold || isWarmPreset(light) || isCoolPreset(light):
            return MagicHomeLevelRequest(colour: nil, warm: white, cool: nil)
        default:
            let colour = MagicHomeColour.truncatedRGB(hue: light.hue, saturation: light.saturation, value: light.brightness)
            return MagicHomeLevelRequest(colour: colour, warm: nil, cool: nil)
        }
    }

    /// The frames of a level request for the profile's family (section 10.3.2 to 10.3.7).
    static func family(profile: MagicHomeProfile, request: MagicHomeLevelRequest) -> [MagicHomeOutgoing] {
        let row = MagicHomeModel.table[profile.model]
        let together = row?.writesAllTogether == true || profile.mode == .rgbw || profile.mode == .rgbww
        let colour = request.colour
        let warm = request.warm, cool = request.cool
        let hasWhite = warm != nil || cool != nil
        // Both groups together on such models; colours only, or whites only, on the others.
        let mask: UInt8 = together ? 0x00 : (!hasWhite ? 0xF0 : (colour == nil ? 0x0F : 0x00))
        let (r, g, b) = colour ?? (0, 0, 0)
        switch profile.family {
        case .addressableV2, .addressableV3:
            let wrap: UInt8? = profile.family == .addressableV3 ? 1 : nil
            var frames: [MagicHomeOutgoing] = []
            if let colour { frames.append(MagicHomeOutgoing(bytes: MagicHomeFrame.addressableColour(red: colour.red, green: colour.green, blue: colour.blue), wrapVersion: wrap)) }
            if let warm {
                frames.append(MagicHomeOutgoing(bytes: MagicHomeFrame.addressableWhite(warm), wrapVersion: wrap, delay: colour == nil ? .zero : .seconds(1)))
            }
            return frames
        case .christmas:
            let hsv = MagicHomeColour.hsv(red: r, green: g, blue: b)
            let frame = MagicHomeFrame.christmasColour(hue: truncated(hsv.hue / 360 * 180), saturation: truncated(hsv.saturation), value: truncated(hsv.value))
            return [MagicHomeOutgoing(bytes: frame, wrapVersion: 1)]
        case .twentyFiveByte, .extendedCustom:
            let hsv = colour.map { MagicHomeColour.hsv(red: $0.red, green: $0.green, blue: $0.blue) }
            var temperature: UInt8 = 0, brightness: UInt8 = 0
            let sum = Double(warm ?? 0) + Double(cool ?? 0)
            if hasWhite, sum > 0 {
                temperature = MagicHomeColour.byte(Double(cool ?? 0) / sum * 100)
                brightness = MagicHomeColour.byte(min(sum, 255) / 255 * 100)
            }
            let extendedMask: UInt8 = colour != nil && hasWhite ? 0x00 : (colour != nil ? 0xA1 : 0xB1)
            let frame = MagicHomeFrame.extendedLevels(
                mask: extendedMask, hue: truncated((hsv?.hue ?? 0) / 2), saturation: truncated(hsv?.saturation ?? 0), value: truncated(hsv?.value ?? 0),
                temperature: temperature, brightness: brightness)
            return [MagicHomeOutgoing(bytes: frame, wrapVersion: 2)]
        case .cct, .cctWrapped:
            let levels = MagicHomeColour.temperatureAndBrightness(warm: warm ?? 0, cool: cool ?? 0)
            return [MagicHomeOutgoing(bytes: MagicHomeFrame.temperature(levels.temperature, brightness: levels.brightness), wrapVersion: profile.family.wrapsRequests ? 1 : nil)]
        case .socket, .original, .originalRGBW, .originalCCT:
            return []
        default:
            break
        }
        if profile.family.nineByteLevels || profile.logic == .rgbwwStrip || profile.logic == .rgbwwBulb {
            // One white given: the cool copies the warm (flux_led keeps the device's own on CCT and RGBWW modes).
            return [.plain(MagicHomeFrame.levels(red: r, green: g, blue: b, warm: warm ?? 0, cool: cool ?? warm ?? 0, mask: mask))]
        }
        switch row?.remap ?? .none {
        case .whiteInRed:
            // The level travels in the red byte; with the white field empty the write counts as a colour one.
            return [.plain(MagicHomeFrame.levels(red: warm ?? r, green: 0, blue: 0, white: 0, mask: together ? 0x00 : 0xF0))]
        case .warmRedCoolGreen:
            return [.plain(MagicHomeFrame.levels(red: warm ?? 0, green: cool ?? 0, blue: 0, white: 0, mask: 0x00))]
        case .none, .percent:
            return [.plain(MagicHomeFrame.levels(red: r, green: g, blue: b, white: warm ?? 0, mask: mask))]
        }
    }

    private static func truncated(_ value: Double) -> UInt8 { UInt8(clamping: Int(saturating: value.rounded(.towardZero)) ?? 0) }
}
