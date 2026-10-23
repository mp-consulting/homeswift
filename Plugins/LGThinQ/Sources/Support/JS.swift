import Foundation
import Homeswift
import HomeswiftPlugin

/// JavaScript's reading of loosely typed values, which the LG cloud and the Homebridge plugin rely on: device
/// snapshots carry numbers as strings, flags as 0/1 or "ON", and the plugin compares them with `Number()`,
/// `parseInt()` and truthiness. A missing key is JavaScript's `undefined`, here `nil`.
enum JS {
    /// `!!value`.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let bool)?: bool
        case .number(let number)?: number != 0 && !number.isNaN
        case .string(let string)?: !string.isEmpty
        case .array?, .object?: true
        }
    }

    /// `Number(value)`: NaN for what is not a number.
    static func number(_ value: JSONValue?) -> Double {
        switch value {
        case nil: .nan
        case .null?: 0
        case .bool(let bool)?: bool ? 1 : 0
        case .number(let number)?: number
        case .string(let string)?: number(string)
        case .array(let array)?: array.isEmpty ? 0 : array.count == 1 ? number(.string(string(array[0]))) : .nan
        case .object?: .nan
        }
    }

    /// `Number(string)`: the whole trimmed string must be a numeric literal; empty is 0.
    static func number(_ string: String) -> Double {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let lower = trimmed.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            return UInt64(lower.dropFirst(2), radix: radix).map(Double.init) ?? .nan
        }
        switch trimmed {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        // Swift accepts "nan", "inf" and hex floats; JavaScript does not.
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }) else { return .nan }
        return Double(trimmed) ?? .nan
    }

    /// `String(value)`.
    static func string(_ value: JSONValue?) -> String {
        switch value {
        case nil: "undefined"
        case .null?: "null"
        case .bool(let bool)?: bool ? "true" : "false"
        case .number(let number)?: format(number)
        case .string(let string)?: string
        case .array(let array)?: array.map { $0.isNull ? "" : string($0) }.joined(separator: ",")
        case .object?: "[object Object]"
        }
    }

    /// A number as JavaScript prints it: `350`, `25.5`, `-0.01`.
    static func format(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        if number == number.rounded(), abs(number) < 1e21 {
            // Whole numbers past Int64 (to 1e21) are still printed in full.
            return Int64(exactly: number).map { String($0) } ?? String(format: "%.0f", number)
        }
        return "\(number)"
    }

    /// `parseInt(string)` in base 10 (or 16 with a `0x` prefix): NaN when no digit leads.
    static func parseInt(_ string: String) -> Double {
        var characters = Substring(string.drop { $0.isWhitespace })
        var sign = 1.0
        if characters.first == "-" || characters.first == "+" {
            if characters.first == "-" { sign = -1 }
            characters = characters.dropFirst()
        }
        var radix = 10
        if characters.lowercased().hasPrefix("0x") {
            radix = 16
            characters = characters.dropFirst(2)
        }
        let digits = characters.prefix { $0.isASCII && $0.isHexDigit && Int(String($0), radix: radix) != nil }
        guard !digits.isEmpty else { return .nan }
        var result = 0.0
        for digit in digits { result = result * Double(radix) + Double(Int(String(digit), radix: radix)!) }
        return sign * result
    }

    /// `parseFloat(string)`: the longest leading decimal literal.
    static func parseFloat(_ string: String) -> Double {
        let trimmed = Substring(string.drop { $0.isWhitespace })
        if trimmed.hasPrefix("Infinity") || trimmed.hasPrefix("+Infinity") { return .infinity }
        if trimmed.hasPrefix("-Infinity") { return -.infinity }
        // [+-]? digits [. digits] [e [+-] digits], the exponent only when complete.
        let characters = Array(trimmed)
        var index = 0
        var literal = ""
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            literal.append(characters[index])
            index += 1
        }
        var digits = 0
        while index < characters.count, characters[index].isASCII, characters[index].isNumber {
            literal.append(characters[index])
            index += 1
            digits += 1
        }
        if index < characters.count, characters[index] == "." {
            literal.append(".")
            index += 1
            while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                literal.append(characters[index])
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else { return .nan }
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            var exponent = "e"
            var position = index + 1
            if position < characters.count, characters[position] == "+" || characters[position] == "-" {
                exponent.append(characters[position])
                position += 1
            }
            var exponentDigits = 0
            while position < characters.count, characters[position].isASCII, characters[position].isNumber {
                exponent.append(characters[position])
                position += 1
                exponentDigits += 1
            }
            if exponentDigits > 0 { literal += exponent }
        }
        if literal.hasSuffix(".") { literal += "0" }
        if literal.hasPrefix(".") || literal.hasPrefix("-.") || literal.hasPrefix("+.") { literal = literal.replacingOccurrences(of: ".", with: "0.") }
        return Double(literal) ?? .nan
    }

    /// `safeParseInt(value, fallback)` of the Homebridge plugin: `parseInt(String(value))`, the fallback for NaN.
    static func parseInt(_ value: JSONValue?, fallback: Double = 0) -> Double {
        let parsed = parseInt(string(value))
        return parsed.isNaN ? fallback : parsed
    }

    static func int(_ value: JSONValue?, fallback: Int = 0) -> Int {
        let parsed = parseInt(string(value))
        return parsed.isFinite ? Int(saturating: parsed) ?? fallback : fallback
    }

    /// `safeParseFloat(value, fallback)`.
    static func parseFloat(_ value: JSONValue?, fallback: Double = 0) -> Double {
        let parsed = parseFloat(string(value))
        return parsed.isNaN ? fallback : parsed
    }

    /// The keys of an object in JavaScript's order where it can be known: integer keys ascending, then the
    /// others (insertion order is lost in decoding, so alphabetical).
    static func keys(_ object: [String: JSONValue]) -> [String] {
        let integers = object.keys.compactMap { key -> (String, UInt32)? in
            guard let value = UInt32(key), String(value) == key else { return nil }
            return (key, value)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        let integerSet = Set(integers)
        return integers + object.keys.filter { !integerSet.contains($0) }.sorted()
    }

    /// `===` between two JSON values, with `undefined` as nil.
    static func strictEquals(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.number(let a)?, .number(let b)?): a == b
        case (.string(let a)?, .string(let b)?): a == b
        case (.bool(let a)?, .bool(let b)?): a == b
        case (.null?, .null?): true
        default: false
        }
    }

    /// `ToInt32`, for the bit shifts of the binary monitor decoding.
    static func int32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let truncated = value.rounded(.towardZero)
        let modulo = truncated.truncatingRemainder(dividingBy: 4_294_967_296)
        var unsigned = modulo < 0 ? modulo + 4_294_967_296 : modulo
        if unsigned >= 2_147_483_648 { unsigned -= 4_294_967_296 }
        return Int32(unsigned)
    }

    /// `value << count` on JavaScript numbers.
    static func shiftLeft(_ value: Double, _ count: Int) -> Double {
        Double(Int32(truncatingIfNeeded: Int64(int32(value)) << Int64(count & 31)))
    }
}

/// What a HomeKit write carries, read as the Homebridge plugin's `normalizeBoolean` and `normalizeNumber` do.
enum Normalize {
    static func boolean(_ value: HAPValue) -> Bool {
        switch value {
        case .bool(let bool): bool
        case .int(let int): int == 1
        case .double(let double): double == 1
        case .string(let string): ["1", "true", "on"].contains(string.lowercased())
        case .null: false
        }
    }

    static func number(_ value: HAPValue) -> Double? {
        switch value {
        case .null: return nil
        case .int(let int): return Double(int)
        case .double(let double): return double
        case .bool(let bool): return bool ? 1 : 0
        case .string(let string):
            let number = JS.number(string)
            return number.isNaN ? nil : number
        }
    }
}
