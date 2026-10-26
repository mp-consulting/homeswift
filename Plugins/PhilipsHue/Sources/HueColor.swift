import Foundation

/// A CIE 1931 chromaticity, as Hue lights take colours.
struct HueXY: Sendable, Equatable, Codable {
    var x: Double
    var y: Double
}

/// The colours a light can show: the triangle of its red, green and blue primaries (`color.gamut` of a v2 light).
struct HueGamut: Sendable, Equatable, Codable {
    var red: HueXY
    var green: HueXY
    var blue: HueXY

    /// Gamut C, of most current colour lights, for a light that reports none (homebridge-lib's `Colour`).
    static let c = HueGamut(red: HueXY(x: 0.692, y: 0.308), green: HueXY(x: 0.17, y: 0.7), blue: HueXY(x: 0.153, y: 0.048))
}

/// HomeKit's hue and saturation to Hue's xy and back, with Philips' published conversion ("RGB to xy and back":
/// sRGB with its gamma, the Wide RGB D65 matrix), clamped into the light's gamut.
enum HueColor {
    /// HomeKit hue (0-360) and saturation (0-100), at full value, as xy inside `gamut`.
    static func xy(hue: Double, saturation: Double, gamut: HueGamut = .c) -> HueXY {
        let (r, g, b) = rgb(hue: hue, saturation: saturation)
        let (red, green, blue) = (linear(r), linear(g), linear(b))
        let x = red * 0.664511 + green * 0.154324 + blue * 0.162028
        let y = red * 0.283881 + green * 0.668433 + blue * 0.047685
        let z = red * 0.000088 + green * 0.072310 + blue * 0.986039
        let sum = x + y + z
        guard sum > 0 else { return white }
        return clamp(HueXY(x: x / sum, y: y / sum), to: gamut)
    }

    /// An xy as HomeKit hue (0-360) and saturation (0-100).
    static func hueSaturation(_ point: HueXY, gamut: HueGamut = .c) -> (hue: Double, saturation: Double) {
        var point = clamp(point, to: gamut)
        if point.y == 0 { point.y = 0.000001 }
        let luminance = 1.0
        let x = luminance / point.y * point.x
        let z = luminance / point.y * (1 - point.x - point.y)
        var r = x * 1.656492 - luminance * 0.354851 - z * 0.255038
        var g = -x * 0.707196 + luminance * 1.655397 + z * 0.036152
        var b = x * 0.051713 - luminance * 0.121364 + z * 1.011530
        // A negative channel lifts all three (a step Philips' formulas leave out, homebridge-lib's `xyToHsv`), then
        // the brightest is brought back to 1.
        let lowest = min(r, g, b)
        if lowest < 0 { (r, g, b) = (r - lowest, g - lowest, b - lowest) }
        let peak = max(r, g, b)
        if peak > 1 { (r, g, b) = (r / peak, g / peak, b / peak) }
        (r, g, b) = (gamma(r), gamma(g), gamma(b))
        let top = max(r, g, b)
        if top > 1 { (r, g, b) = (r / top, g / top, b / top) }
        return hsv(r, g, b)
    }

    /// The white point Hue uses when there is no colour (D65).
    static let white = HueXY(x: 0.3127, y: 0.3290)

    // MARK: sRGB

    static func rgb(hue: Double, saturation: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 100) / 100
        let sector = Int(h.rounded(.down))
        let f = h - Double(sector)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        switch sector {
        case 0: return (1, t, p)
        case 1: return (q, 1, p)
        case 2: return (p, 1, t)
        case 3: return (p, q, 1)
        case 4: return (t, p, 1)
        default: return (1, p, q)
        }
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double) {
        let top = max(r, g, b), bottom = min(r, g, b), delta = top - bottom
        guard top > 0, delta > 0 else { return (0, 0) }
        var hue: Double
        if top == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if top == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, delta / top * 100)
    }

    /// sRGB's gamma removed.
    static func linear(_ value: Double) -> Double {
        value > 0.04045 ? pow((value + 0.055) / 1.055, 2.4) : value / 12.92
    }

    /// sRGB's gamma applied.
    static func gamma(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    // MARK: Whites

    /// Whether a colour reads as a white: within 0.006 of the line of whites (the Planckian locus in CIE 1960 uv, by
    /// Krystek's approximation, 1,000 to 15,000 K) at 1,600 K or more. Hue's own whites (Nightlight's 1,700 K to
    /// Energize's 6,400 K) are; the reds and oranges near the locus below 1,600 K, and anything off it, are colours.
    static func isWhite(_ point: HueXY) -> Bool {
        let d = -2 * point.x + 12 * point.y + 3
        guard d > 0 else { return false }
        let u = 4 * point.x / d, v = 6 * point.y / d
        var nearest = (distance: Double.infinity, kelvin: 0.0)
        for kelvin in stride(from: 1000.0, through: 15000, by: 50) {
            let t2 = kelvin * kelvin
            let lu = (0.860117757 + 1.54118254e-4 * kelvin + 1.28641212e-7 * t2) / (1 + 8.42420235e-4 * kelvin + 7.08145163e-7 * t2)
            let lv = (0.317398726 + 4.22806245e-5 * kelvin + 4.20481691e-8 * t2) / (1 - 2.89741816e-5 * kelvin + 1.61456053e-7 * t2)
            let distance = ((u - lu) * (u - lu) + (v - lv) * (v - lv)).squareRoot()
            if distance < nearest.distance { nearest = (distance, kelvin) }
        }
        return nearest.distance < 0.006 && nearest.kelvin >= 1600
    }

    // MARK: The gamut

    /// The point itself when the light can show it, else the closest point on the triangle's edges.
    static func clamp(_ point: HueXY, to gamut: HueGamut) -> HueXY {
        if contains(point, gamut) { return point }
        let candidates = [
            closest(point, gamut.red, gamut.green), closest(point, gamut.green, gamut.blue), closest(point, gamut.blue, gamut.red),
        ]
        return candidates.min { distance($0, point) < distance($1, point) }!
    }

    static func contains(_ point: HueXY, _ gamut: HueGamut) -> Bool {
        func side(_ a: HueXY, _ b: HueXY) -> Double { (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) }
        let d1 = side(gamut.red, gamut.green), d2 = side(gamut.green, gamut.blue), d3 = side(gamut.blue, gamut.red)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    static func closest(_ point: HueXY, _ a: HueXY, _ b: HueXY) -> HueXY {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return a }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / length, 0), 1)
        return HueXY(x: a.x + t * dx, y: a.y + t * dy)
    }

    static func distance(_ a: HueXY, _ b: HueXY) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
