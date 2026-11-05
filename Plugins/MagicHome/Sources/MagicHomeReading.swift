import Foundation

/// What a state reply shows in HomeKit (section 5.3, 10.4, 10.7): nil leaves a characteristic as it is. Values are
/// rounded, Brightness is not shown while the light is off, and a white on a light with Color Temperature gives its
/// mireds.
struct MagicHomeReading: Sendable, Equatable {
    var on: Bool
    var brightness: Int?
    var hue: Double?
    var saturation: Double?
    var mireds: Int?
    /// The device shows a white (its whites set, its colour off), for Adaptive Lighting; false for a colour.
    var showsWhite = false

    static func of(_ state: MagicHomeState, profile: MagicHomeProfile, effects: MagicHomeWhiteEffects) -> MagicHomeReading {
        var reading = MagicHomeReading(on: state.isOn)
        let on = state.isOn
        func percent(_ level: Double) -> Int { Int(MagicHomeColour.round(min(max(level, 0), 100))) }
        func colour() -> (hue: Double, saturation: Double, value: Double) {
            MagicHomeColour.hsv(red: state.red, green: state.green, blue: state.blue)
        }
        func setColour(_ hsv: (hue: Double, saturation: Double, value: Double)) {
            reading.hue = MagicHomeColour.round(min(max(hsv.hue, 0), 360))
            reading.saturation = MagicHomeColour.round(min(max(hsv.saturation, 0), 100))
        }
        /// A tunable white's mireds from its levels; nil when both are 0 (the last stays).
        func white(warm: UInt8, cool: UInt8) {
            guard let t = MagicHomeColour.temperatureFraction(warm: warm, cool: cool) else { return }
            reading.mireds = MagicHomeColour.mireds(fraction: t)
            reading.showsWhite = true
            if on { reading.brightness = MagicHomeColour.brightness(warm: warm, cool: cool) }
        }
        let colourIsOff = state.red == 0 && state.green == 0 && state.blue == 0
        switch profile.writer {
        case .powerOnly:
            break
        case .percentCCT:
            // Bytes 9 and 11: the temperature and brightness in percent.
            reading.mireds = MagicHomeColour.mireds(fraction: Double(min(state.warm, 100)) / 100)
            reading.showsWhite = true
            if on { reading.brightness = Int(min(state.cool, 100)) }
        case .remappedCCT:
            white(warm: state.red, cool: state.green)
        case .original(let logic):
            let hsv = colour()
            switch logic {
            case .dimmerStrip:
                if on { reading.brightness = percent(Double(state.red) / 2.55) }
            case .rgbStrip, .grbStrip:
                setColour(hsv)
                if on, hsv.value > 0 { reading.brightness = percent(hsv.value) }
            case .rgbwBulb, .rgbwStrip:
                setColour(hsv)
                if on { reading.brightness = percent(hsv.value > 0 ? hsv.value : Double(state.warm) / 2.55) }
            case .rgbwwStrip, .rgbwwBulb:
                setColour(hsv)
                if on, hsv.value > 0 {
                    reading.brightness = percent(hsv.value)
                } else if colourIsOff {
                    // White: a point near white on the colour wheel, as the Homebridge plugin made it.
                    let threshold = effects.colorWhiteThreshold
                    if state.warm > state.cool {
                        reading.saturation = MagicHomeColour.round(threshold - threshold * Double(state.cool) / 255)
                        reading.hue = 0
                    } else {
                        reading.saturation = MagicHomeColour.round(threshold - threshold * Double(state.warm) / 255)
                        reading.hue = 180
                    }
                    if on { reading.brightness = percent(Double(state.cool) / 2.55 + Double(state.warm) / 2.55) }
                    if profile.hasTemperature { white(warm: state.warm, cool: state.cool) }
                }
            case .cctStrip, .switch:
                break
            }
        case .family:
            var warm = state.warm
            // Addressable v3 carries its white on a scale of 128 to 228.
            if profile.family == .addressableV3 {
                warm = MagicHomeColour.byte((Double(min(max(warm, 128), 228)) - 128) * 255 / 100)
            }
            let row = MagicHomeModel.table[profile.model]
            switch profile.mode {
            case .none:
                break
            case .dim, .cct:
                let level = row?.remap == .whiteInRed ? state.red : warm
                if on { reading.brightness = percent(Double(level) / 255 * 100) }
            default:
                let hsv = colour()
                if colourIsOff, profile.hasTemperature, warm > 0 || state.cool > 0 {
                    white(warm: warm, cool: state.cool)
                } else if colourIsOff, profile.mode == .rgbOrWhite || profile.mode == .rgbw, warm > 0 {
                    setColour(hsv)
                    if on { reading.brightness = percent(Double(warm) / 255 * 100) }
                } else {
                    setColour(hsv)
                    if on, hsv.value > 0 { reading.brightness = percent(hsv.value) }
                }
            }
        }
        return reading
    }
}
