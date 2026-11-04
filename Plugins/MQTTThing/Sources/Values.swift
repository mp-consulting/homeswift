import Foundation
import Homeswift
import HomeswiftPlugin

/// How MQTTThing reads and writes values (docs/clean-room/MQTTThing.md, section 3.4): text as JavaScript writes it,
/// `parseInt` and `parseFloat`, and loose equality.
enum JS {
    /// The text a value is published as: `true`, `1`, `21.5`, `255,0,0`.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .null: "null"
        default: value.text()
        }
    }

    /// Present and not `false`, `0`, `""` or `null`.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let flag)?: flag
        case .number(let number)?: number != 0 && !number.isNaN
        case .string(let text)?: !text.isEmpty
        default: true
        }
    }

    /// JavaScript's `parseInt`: leading white space, a sign, `0x` for hex, then digits up to the first other character.
    static func parseInt(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let number): return number.isFinite ? Int(exactly: number.rounded(.towardZero)) : nil
        case .string(let text): return parseInt(text)
        default: return nil
        }
    }

    static func parseInt(_ text: String) -> Int? {
        var scalars = Substring(text).drop { $0.isWhitespace }
        var negative = false
        if let sign = scalars.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        var radix = 10
        if scalars.hasPrefix("0x") || scalars.hasPrefix("0X") {
            radix = 16
            scalars = scalars.dropFirst(2)
        }
        let digits = scalars.prefix { $0.isASCII && $0.hexDigitValue.map { $0 < radix } == true }
        guard !digits.isEmpty, let magnitude = Int(digits, radix: radix) else { return nil }
        return negative ? -magnitude : magnitude
    }

    /// JavaScript's `parseFloat`: the longest decimal number at the start, after white space (`"21.5 C"` is 21.5).
    static func parseFloat(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let text): return parseFloat(text)
        default: return nil
        }
    }

    static func parseFloat(_ text: String) -> Double? {
        let characters = Array(text.drop { $0.isWhitespace })
        var end = 0
        if end < characters.count, characters[end] == "-" || characters[end] == "+" { end += 1 }
        if characters[end...].starts(with: "Infinity") {
            return characters.first == "-" ? -.infinity : .infinity
        }
        var digits = 0
        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1; digits += 1 }
        if end < characters.count, characters[end] == "." {
            end += 1
            while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        // An exponent counts only when digits follow it.
        if end < characters.count, characters[end] == "e" || characters[end] == "E" {
            var exponent = end + 1
            if exponent < characters.count, characters[exponent] == "-" || characters[exponent] == "+" { exponent += 1 }
            let start = exponent
            while exponent < characters.count, characters[exponent].isASCII, characters[exponent].isNumber { exponent += 1 }
            if exponent > start { end = exponent }
        }
        return Double(String(characters[..<end]))
    }

    /// Whether a received value `message` matches a configured one: identical, or equal to its text under JavaScript's
    /// loose equality (a payload's text exactly, a number numerically, a boolean as 1 or 0).
    static func matches(_ message: JSONValue, _ configured: JSONValue) -> Bool {
        if message == configured { return true }
        let text = Self.text(configured)
        switch message {
        case .string(let received): return received == text
        case .number(let number): return number == jsNumber(text)
        case .bool(let flag): return (flag ? 1 : 0) == jsNumber(text)
        default: return false
        }
    }

    /// JavaScript's `Number(text)`: white space trimmed, empty is 0, anything else not a number is NaN.
    static func jsNumber(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") { return Int(trimmed.dropFirst(2), radix: 16).map(Double.init) ?? .nan }
        return Double(trimmed) ?? .nan
    }
}

/// The on and off values of a boolean (section 3.4).
struct Booleans: Sendable {
    var on: JSONValue
    /// nil: "off" publishes nothing, and only `otherValueOff` reads anything as off.
    var off: JSONValue?
    var otherValueOff: Bool

    init(_ config: Config) {
        if JS.truthy(config["onValue"]) {
            on = config["onValue"] ?? .bool(true)
            off = config["offValue"].flatMap { $0 == .null ? nil : $0 }
        } else if JS.truthy(config["integerValue"]) {
            on = .number(1)
            off = .number(0)
        } else {
            on = .bool(true)
            off = .bool(false)
        }
        otherValueOff = JS.truthy(config["otherValueOff"])
    }

    /// true for on, false for off, nil for a message that is neither (ignored).
    func decode(_ message: JSONValue) -> Bool? {
        if JS.matches(message, on) { return true }
        if otherValueOff { return false }
        if let off, JS.matches(message, off) { return false }
        return nil
    }

    func encode(_ flag: Bool) -> JSONValue? { flag ? on : off }
}

/// An enumeration's MQTT values by HomeKit index (section 3.4).
struct Enumeration: Sendable {
    var values: [JSONValue]

    init(_ config: Config, keys: [String], default defaults: [String]) {
        let given = keys.lazy.compactMap { config[$0]?.arrayValue }.first
        values = given ?? defaults.map(JSONValue.string)
    }

    init(values: [JSONValue]) { self.values = values }

    func index(of message: JSONValue) -> Int? {
        let text = JS.text(message)
        return values.firstIndex { JS.text($0) == text }
    }

    func value(at index: Int) -> JSONValue? { values.indices.contains(index) ? values[index] : nil }
}

/// The first value a JSONPath query finds (the `jsonpath` library's syntax: `$.a.b`, `$.a[0]`, `$['a b']`, `$..a`,
/// `*`), with its JSON type.
enum JSONPath {
    enum Step: Equatable {
        case key(String)
        case index(Int)
        case wildcard
        case descendant(String)
    }

    static func parse(_ path: String) -> [Step]? {
        var characters = Substring(path)
        guard characters.first == "$" else { return nil }
        characters = characters.dropFirst()
        var steps: [Step] = []
        func name(_ text: inout Substring) -> String {
            let found = text.prefix { $0 != "." && $0 != "[" }
            text = text.dropFirst(found.count)
            return String(found)
        }
        while let first = characters.first {
            if characters.hasPrefix("..") {
                characters = characters.dropFirst(2)
                let key = name(&characters)
                guard !key.isEmpty else { return nil }
                steps.append(key == "*" ? .wildcard : .descendant(key))
            } else if first == "." {
                characters = characters.dropFirst()
                let key = name(&characters)
                guard !key.isEmpty else { return nil }
                steps.append(key == "*" ? .wildcard : .key(key))
            } else if first == "[" {
                guard let close = characters.firstIndex(of: "]") else { return nil }
                let inside = characters[characters.index(after: characters.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                characters = characters[characters.index(after: close)...]
                if inside == "*" {
                    steps.append(.wildcard)
                } else if let index = Int(inside) {
                    steps.append(.index(index))
                } else if inside.count >= 2, let quote = inside.first, quote == "'" || quote == "\"", inside.last == quote {
                    steps.append(.key(String(inside.dropFirst().dropLast())))
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return steps
    }

    static func first(_ steps: [Step], in value: JSONValue) -> JSONValue? {
        guard let step = steps.first else { return value }
        let rest = Array(steps.dropFirst())
        switch step {
        case .key(let key):
            return value[key].flatMap { first(rest, in: $0) }
        case .index(let index):
            guard let array = value.arrayValue else { return nil }
            let position = index < 0 ? array.count + index : index
            return array.indices.contains(position) ? first(rest, in: array[position]) : nil
        case .wildcard:
            for child in children(of: value) { if let found = first(rest, in: child) { return found } }
            return nil
        case .descendant(let key):
            if let child = value[key], let found = first(rest, in: child) { return found }
            for child in children(of: value) { if let found = first(steps, in: child) { return found } }
            return nil
        }
    }

    private static func children(of value: JSONValue) -> [JSONValue] {
        switch value {
        case .array(let items): items
        case .object(let object): object.keys.sorted().compactMap { object[$0] }
        default: []
        }
    }
}

/// The colour conversions of the RGB family (section 5.17.3).
enum Colour {
    struct RGB: Equatable { var r: Int, g: Int, b: Int }

    /// The hexcone formula, each component times 255 rounded half up.
    static func rgb(hue: Double, saturation: Double, value: Double) -> RGB {
        let h = hue / 360, s = saturation / 100, v = value / 100
        let i = (6 * h).rounded(.down)
        let f = 6 * h - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch ((Int(i) % 6) + 6) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func byte(_ x: Double) -> Int { Int((x * 255 + 0.5).rounded(.down)) }
        return RGB(r: byte(r), g: byte(g), b: byte(b))
    }

    /// Hue, saturation and brightness of a colour, each floored.
    static func hsv(_ c: RGB) -> (hue: Int, saturation: Int, brightness: Int) {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let maximum = max(r, g, b), minimum = min(r, g, b), d = maximum - minimum
        let s = maximum == 0 ? 0 : d / maximum
        let v = maximum / 255
        var h = 0.0
        if maximum != minimum {
            if maximum == r {
                h = ((g - b) + (g < b ? 6 * d : 0)) / (6 * d)
            } else if maximum == g {
                h = ((b - r) + 2 * d) / (6 * d)
            } else {
                h = ((r - g) + 4 * d) / (6 * d)
            }
        }
        return (Int((360 * h).rounded(.down)), Int((100 * s).rounded(.down)), Int((100 * v).rounded(.down)))
    }

    static let defaultWarmWhite = RGB(r: 255, g: 158, b: 61)
    static let defaultColdWhite = RGB(r: 204, g: 219, b: 255)

    /// `r,g,b` as configured, else the default.
    static func white(_ text: String?, default fallback: RGB) -> RGB {
        guard let parts = text?.split(separator: ",", omittingEmptySubsequences: false), parts.count == 3 else { return fallback }
        let values = parts.map { JS.parseInt(String($0)) ?? 0 }
        return RGB(r: values[0], g: values[1], b: values[2])
    }

    /// How much of the white `x` the colour holds, in 0...1.
    static func whiteFactor(_ c: RGB, against x: RGB) -> Double {
        let channels = [(Double(c.r), Double(x.r)), (Double(c.g), Double(x.g)), (Double(c.b), Double(x.b))]
        let direct = channels.map { $0.1 == 0 ? 1 : $0.0 / $0.1 }.min() ?? 0
        var shape = 0.0
        let maximum = max(Double(c.r), Double(c.g), Double(c.b))
        if maximum >= 1 {
            let k = 255 / maximum
            let xmin = min(Double(x.r), Double(x.g), Double(x.b))
            let cmin = channels.map { $0.0 * k }.min() ?? 0
            let factors = channels.map { channel, white in white > xmin ? (channel * k - cmin) / (white - xmin) / k : 1 }
            shape = min(max(factors.min() ?? 0, 0), 1)
        }
        return min(max(min(direct, shape), 0), 1)
    }

    struct RGBWW: Equatable { var r: Int, g: Int, b: Int, warm: Int, cold: Int }

    /// A colour as red, green, blue, warm white and cold white (step 5 of section 5.17.3).
    static func rgbww(_ c: RGB, warm w: RGB, cold k: RGB, noWhiteMix: Bool, thresholds: RGB) -> RGBWW {
        var fw = whiteFactor(c, against: w), fc = whiteFactor(c, against: k)
        if fw + fc > 1 {
            let sum = fw + fc
            fw /= sum
            fc /= sum
        }
        var warm = Int((255 * fw).rounded(.down)), cold = Int((255 * fc).rounded(.down))
        func channel(_ value: Int, _ wc: Int, _ kc: Int) -> Int { max(0, Int((Double(value) - fw * Double(wc) - fc * Double(kc)).rounded(.down))) }
        var r = channel(c.r, w.r, k.r), g = channel(c.g, w.g, k.g), b = channel(c.b, w.b, k.b)
        let m = min(r, g, b, 255 - warm, 255 - cold)
        warm += m / 2
        cold += m / 2
        r -= m
        g -= m
        b -= m
        if noWhiteMix, warm > 0 || cold > 0, r > 0 || g > 0 || b > 0 {
            if r > thresholds.r || g > thresholds.g || b > thresholds.b {
                return RGBWW(r: c.r, g: c.g, b: c.b, warm: 0, cold: 0)
            }
            r = 0
            g = 0
            b = 0
        }
        return RGBWW(r: r, g: g, b: b, warm: warm, cold: cold)
    }

    /// The whites added back to a received colour.
    static func adding(warm: Int, cold: Int, to c: RGB, warmWhite w: RGB, coldWhite k: RGB) -> RGB {
        func add(_ value: Int, _ wc: Int, _ kc: Int) -> Int { value + wc * warm / 255 + kc * cold / 255 }
        return RGB(r: add(c.r, w.r, k.r), g: add(c.g, w.g, k.g), b: add(c.b, w.b, k.b))
    }

    /// `ff0000`, after the prefix.
    static func hex(_ components: [Int], prefix: String) -> String {
        prefix + components.map { String(format: "%02x", max(0, min(255, $0))) }.joined()
    }

    /// The components of a payload: decimal `r,g,b`, or the prefix and two hex digits each. nil when it has not
    /// `count` of them.
    static func components(_ text: String, count: Int, hexPrefix: String?) -> [Int]? {
        if let prefix = hexPrefix {
            guard text.count == prefix.count + 2 * count, text.hasPrefix(prefix) else { return nil }
            let digits = Array(text.dropFirst(prefix.count))
            var values: [Int] = []
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let byte = Int(String(digits[index...index + 1]), radix: 16) else { return nil }
                values.append(byte)
            }
            return values
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == count else { return nil }
        let values = parts.compactMap { JS.parseInt(String($0)) }
        return values.count == count ? values : nil
    }
}
