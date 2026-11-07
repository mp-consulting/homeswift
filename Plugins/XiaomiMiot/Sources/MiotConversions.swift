import Foundation
import Homeswift
import HomeswiftPlugin

// The conversions between MIoT values and HomeKit's (docs/clean-room/XiaomiMiot.md section 7.2). Rounding is
// JavaScript's: halves go up.
enum MiotConversions {
    static func round(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    // MARK: Percentage of a range

    /// A range used as a percentage directly: `[x, 100, 1]`.
    static func isPercentage(_ property: MiotSpec.Property) -> Bool {
        property.upper == 100 && property.step == 1
    }

    /// The percentage a range value stands for.
    static func percent(_ value: Double, of property: MiotSpec.Property) -> Int {
        guard let lower = property.lower, let upper = property.upper, upper > lower else { return Int(saturating: value, in: 0...100) ?? 0 }
        if isPercentage(property) { return Int(saturating: round(value), in: 0...100) ?? 0 }
        return Int(saturating: round((value - lower) * 100 / (upper - lower)), in: 0...100) ?? 0
    }

    /// The range value for a percentage: the percentage itself (at least the minimum) for a percentage range, else the
    /// position in the range by its step.
    static func value(percent: Double, of property: MiotSpec.Property) -> Double {
        guard let lower = property.lower, let upper = property.upper, upper > lower else { return percent }
        if isPercentage(property) { return min(max(round(percent), lower), upper) }
        let step = property.step
        let value = lower + round(percent * (upper - lower) / 100 / step) * step
        return min(max(value, lower), upper)
    }

    // MARK: Levels and Rotation Speed

    /// A property's levels in order: its value list without `Auto`, or its range by its step.
    static func levels(of property: MiotSpec.Property) -> [JSONValue] {
        if let values = property.values, !values.isEmpty {
            return values.filter { MiotSpec.squash($0.description) != "auto" }.map(\.value)
        }
        guard let lower = property.lower, let upper = property.upper, upper >= lower else { return [] }
        let step = property.step
        let count = Int(saturating: ((upper - lower) / step).rounded(.down), in: 0...10_000) ?? 0
        return (0...count).map { .number(lower + Double($0) * step) }
    }

    /// Rotation Speed of the level at `index` of `count`: `round((i + 1) × 100 / n)`.
    static func speed(levelIndex index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(round(Double(index + 1) * 100 / Double(count)))
    }

    /// The level index for a Rotation Speed above 0: `clamp(round(p × n / 100), 1, n) − 1`.
    static func levelIndex(speed: Double, count: Int) -> Int? {
        guard speed > 0, count > 0 else { return nil }
        return min(max(Int(round(speed * Double(count) / 100)), 1), count) - 1
    }

    // MARK: Colour temperature

    static func mireds(kelvin: Double) -> Int { Int(saturating: round(1_000_000 / kelvin)) ?? 500 }

    static func kelvin(mireds: Double) -> Double { round(1_000_000 / mireds) }

    /// The Color Temperature bounds of a kelvin range, within HomeKit's 140–500.
    static func miredBounds(kelvinLower: Double, kelvinUpper: Double) -> (min: Int, max: Int) {
        let low = Int((1_000_000 / kelvinUpper).rounded(.up)), high = Int((1_000_000 / kelvinLower).rounded(.down))
        return (min(max(low, 140), 500), min(max(high, 140), 500))
    }

    /// A `color-temperature` in `percentage`: mired = 500 − (pct − 1) × 360 / 99.
    static func mireds(percent: Double) -> Int { Int(saturating: round(500 - (percent - 1) * 360 / 99)) ?? 500 }

    static func percent(mireds: Double) -> Double { round(1 + (500 - mireds) * 99 / 360) }

    // MARK: Colour

    /// Hue (0–360) and Saturation (0–100) of a `color` value `R × 65536 + G × 256 + B`, rounded.
    static func hueSaturation(rgb value: Int) -> (hue: Int, saturation: Int) {
        let (hue, saturation) = ColorUtils.hueSaturation(red: Double((value >> 16) & 0xFF), green: Double((value >> 8) & 0xFF), blue: Double(value & 0xFF))
        return (Int(round(hue ?? 0)) % 360, Int(round(saturation)))
    }

    /// The `color` value of Hue and Saturation at full value (V = 100 %), each channel rounded.
    static func rgb(hue: Double, saturation: Double) -> Int {
        let (red, green, blue) = ColorUtils.rgb(hue: hue, saturation: saturation)
        func channel(_ value: Double) -> Int { min(max(Int(round(value * 255)), 0), 255) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    // MARK: Air quality, battery, filter

    static let defaultBreakpoints = [7, 15, 30, 55]

    /// Air Quality from PM2.5 (7.4): 1 Excellent … 5 Poor.
    static func airQuality(pm25: Double, breakpoints: [Int]) -> Int {
        for (index, limit) in breakpoints.enumerated() where pm25 <= Double(limit) { return index + 1 }
        return 5
    }

    /// Four strictly increasing integers, else nil.
    static func validBreakpoints(_ value: JSONValue?) -> [Int]? {
        guard let list = value?.arrayValue, list.count == 4 else { return nil }
        let numbers = list.compactMap(\.intValue)
        guard numbers.count == 4, zip(numbers, numbers.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        return numbers
    }

    static func isLowBattery(_ level: Double) -> Bool { level <= 20 }

    static func needsChange(filterLife: Double) -> Bool { filterLife <= 5 }

    static func celsius(fahrenheit: Double) -> Double { (fahrenheit - 32) * 5 / 9 }

    /// A name HomeKit takes (7.7): letters, digits, spaces and apostrophes, single spaces, trimmed of spaces and
    /// apostrophes; `Unnamed` when nothing is left.
    static func homeKitName(_ name: String) -> String {
        let kept = name.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        let words = String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: " '"))
        return trimmed.isEmpty ? "Unnamed" : trimmed
    }

    /// `fan:toggle` → "Toggle"; `reset-filter-life` → "Reset Filter Life".
    static func friendlyName(_ name: String) -> String {
        let last = name.split(separator: ":").last.map(String.init) ?? name
        return last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
