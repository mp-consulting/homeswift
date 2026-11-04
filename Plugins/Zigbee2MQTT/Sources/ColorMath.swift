import Foundation

/// HomeKit's hue and saturation, CIE xy and mireds, converted as section 12 of docs/clean-room/Zigbee2MQTT.md says.
enum ColorMath {
    /// JavaScript's `Math.round`: halves go up.
    static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// HSV (degrees, percent, percent) to RGB (0-255), each rounded.
    static func hsvToRGB(_ hue: Double, _ saturation: Double, _ value: Double) -> (r: Double, g: Double, b: Double) {
        let h = hue / 60, s = saturation / 100
        var v = value / 100
        let sector = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = 255 * v * (1 - s), q = 255 * v * (1 - s * f), t = 255 * v * (1 - s * (1 - f))
        v *= 255
        let rgb: (Double, Double, Double) =
            switch (sector + 6) % 6 {
            case 0: (v, t, p)
            case 1: (q, v, p)
            case 2: (p, v, t)
            case 3: (p, q, v)
            case 4: (t, p, v)
            default: (v, p, q)
            }
        return (jsRound(rgb.0), jsRound(rgb.1), jsRound(rgb.2))
    }

    /// RGB (0-255) to hue (degrees) and saturation (percent), rounded.
    static func rgbToHS(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double) {
        let red = r / 255, green = g / 255, blue = b / 255
        let value = max(red, green, blue)
        let difference = value - min(red, green, blue)
        guard difference != 0 else { return (0, 0) }
        let saturation = difference / value
        func dif(_ c: Double) -> Double { (value - c) / 6 / difference + 1 / 2 }
        var hue: Double
        if red == value {
            hue = dif(blue) - dif(green)
        } else if green == value {
            hue = 1 / 3 + dif(red) - dif(blue)
        } else {
            hue = 2 / 3 + dif(green) - dif(red)
        }
        if hue < 0 { hue += 1 } else if hue > 1 { hue -= 1 }
        return (jsRound(hue * 360), jsRound(saturation * 100))
    }

    /// HomeKit hue and saturation to CIE xy (12.1), for `color_xy` lights.
    static func hsToXY(hue: Double, saturation: Double) -> (x: Double, y: Double) {
        let rgb = hsvToRGB(hue, saturation, 100)
        func gamma(_ c: Double) -> Double {
            let v = c / 255
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let r = gamma(rgb.r), g = gamma(rgb.g), b = gamma(rgb.b)
        let X = 0.664511 * r + 0.154324 * g + 0.162028 * b
        let Y = 0.283881 * r + 0.668433 * g + 0.047685 * b
        let Z = 0.000088 * r + 0.072310 * g + 0.986039 * b
        let sum = X + Y + Z
        guard sum > 0 else { return (0, 0) }
        func round5(_ v: Double) -> Double { jsRound((v + pow(2, -52)) * 100_000) / 100_000 }
        return (round5(X / sum), round5(Y / sum))
    }

    /// CIE xy to HomeKit hue and saturation (12.2).
    static func xyToHS(x: Double, y: Double) -> (hue: Double, saturation: Double) {
        guard y != 0 else { return (0, 0) }
        let z = 1 - x - y
        let Y = 1.0, X = x / y, Z = z / y
        var r = 1.656492 * X - 0.354851 * Y - 0.255038 * Z
        var g = -0.707196 * X + 1.655397 * Y + 0.036152 * Z
        var b = 0.051713 * X - 0.121364 * Y + 1.011530 * Z
        let lowest = min(r, g, b)
        if lowest < 0 {
            r -= lowest
            g -= lowest
            b -= lowest
        }
        if r > g, r > b, r > 1 {
            g /= r
            b /= r
            r = 1
        } else if g > r, g > b, g > 1 {
            r /= g
            b /= g
            g = 1
        } else if b > r, b > g, b > 1 {
            r /= b
            g /= b
            b = 1
        }
        func inverse(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        r = inverse(r)
        g = inverse(g)
        b = inverse(b)
        let highest = max(r, g, b)
        guard highest > 0 else { return (0, 0) }
        func scale(_ c: Double) -> Double { c == highest ? 255 : 255 * c / highest }
        return rgbToHS(scale(r), scale(g), scale(b))
    }

    /// Mireds to CIE xy, deCONZ's polynomial (12.3).
    static func miredToXY(_ mired: Double) -> (x: Double, y: Double) {
        let t = 1_000_000 / mired
        let X: Double =
            t < 4000
            ? 57_520_658 / t + 11790 - 15_358_885_888 / (t * t) - 17_440_695_910_400 / (t * t * t)
            : 138_086_835_814 / (t * t) + 14_590_587 / t + 15754 - 198_301_902_438_400 / (t * t * t)
        let x2: Double = X * X, x3: Double = X * X * X
        let p48: Double = pow(2, 48), p32: Double = pow(2, 32)
        // Each branch is c1·X/2^16 ± c3·X³/2^48 − c2·X²/2^32 − c0, evaluated left to right as JavaScript does
        // (split into typed terms: the one-line form is too slow for the type checker).
        let linear: Double, cubic: Double, square: Double, constant: Double
        if t < 2222 {
            linear = 35808 * X / 65536; cubic = -(18126 * x3 / p48); square = 22087 * x2 / p32; constant = 3312
        } else if t < 4000 {
            linear = 34265 * X / 65536; cubic = -(15645 * x3 / p48); square = 22514 * x2 / p32; constant = 2744
        } else {
            linear = 61458 * X / 65536; cubic = 50491 * x3 / p48; square = 96229 * x2 / p32; constant = 6062
        }
        var Y: Double = linear + cubic
        Y = Y - square
        Y = Y - constant
        Y *= 4
        func round4(_ v: Double) -> Double { jsRound(v * 10_000) / 10_000 }
        return (round4(X / 65535), round4(Y / 65535))
    }

    /// Mireds to HomeKit hue and saturation, through CIE xy.
    static func miredToHS(_ mired: Double) -> (hue: Double, saturation: Double) {
        let xy = miredToXY(mired)
        return xyToHS(x: xy.x, y: xy.y)
    }
}
