import Foundation

/// The colour temperatures each bulb takes, by model (docs/clean-room/TPLinkSmarthome.md, section 4.5.1).
enum KasaColorTemperature {
    /// The first prefix of `model` that matches wins; anything else is 2700 K to 6500 K.
    static let ranges: [(prefix: String, kelvin: ClosedRange<Int>)] = [
        ("KB130", 2500...9000), ("KL120(EU)", 2700...6500), ("KL120(US)", 2700...5000), ("KL125", 2500...6500), ("KL130", 2500...9000),
        ("KL135", 2500...9000), ("KL430", 2500...9000), ("LB120", 2700...6500), ("LB130", 2500...9000), ("LB230", 2500...9000),
    ]
    static let defaultRange = 2700...6500

    static func kelvinRange(model: String) -> ClosedRange<Int> {
        ranges.first { model.hasPrefix($0.prefix) }?.kelvin ?? defaultRange
    }

    /// Color Temperature's props: ceil(1e6 / the coolest) to floor(1e6 / the warmest).
    static func miredRange(model: String) -> ClosedRange<Int> {
        let kelvin = kelvinRange(model: model)
        let low = Int((1_000_000.0 / Double(kelvin.upperBound)).rounded(.up))
        let high = Int((1_000_000.0 / Double(kelvin.lowerBound)).rounded(.down))
        return low...high
    }

    /// A reported kelvin as mireds, kept within the props (9000 K rounds to 111, below 112).
    static func mireds(kelvin: Int, within range: ClosedRange<Int>) -> Int {
        guard kelvin > 0 else { return range.upperBound }
        return min(max(Int((1_000_000.0 / Double(kelvin)).rounded()), range.lowerBound), range.upperBound)
    }

    /// A written mired value as kelvin.
    static func kelvin(mireds: Int) -> Int {
        guard mireds > 0 else { return 0 }
        return Int((1_000_000.0 / Double(mireds)).rounded())
    }
}

/// The MAC allow and deny lists: glob patterns (`*`, `?`) over the MAC's letters and digits (section 3.3).
struct KasaMACFilter: Sendable {
    let allow: [String]
    let deny: [String]

    init(allow: [String]?, deny: [String]?) {
        self.allow = (allow ?? []).map { Self.normalize($0, keeping: "?*") }
        self.deny = (deny ?? []).map { Self.normalize($0, keeping: "?*") }
    }

    /// Why a device with this MAC is left out, or nil when it is not.
    func rejection(of mac: String) -> String? {
        let normalized = Self.normalize(mac, keeping: "")
        if !allow.isEmpty, !allow.contains(where: { Self.matches(normalized, pattern: $0) }) { return "not in macAddresses" }
        if deny.contains(where: { Self.matches(normalized, pattern: $0) }) { return "in excludeMacAddresses" }
        return nil
    }

    static func normalize(_ text: String, keeping extra: String) -> String {
        String(text.unicodeScalars.filter { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || extra.unicodeScalars.contains($0) }).uppercased()
    }

    /// The whole of `text` against the pattern.
    static func matches(_ text: String, pattern: String) -> Bool {
        let text = Array(text), pattern = Array(pattern)
        // The classic two-pointer glob, backtracking to the last `*`.
        var t = 0, p = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                t += 1
                p += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                mark = t
                p += 1
            } else if star >= 0 {
                p = star + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

extension KasaSysinfo {
    /// The first "x.y.z" of `sw_ver` (`1.5.7 Build 180912 Rel.104837`): HomeKit takes a version of numbers only.
    static func firmwareRevision(_ software: String) -> String {
        let prefix = software.prefix { $0.isNumber || $0 == "." }
        let parts = prefix.split(separator: ".").prefix(3)
        return parts.isEmpty ? "1.0.0" : parts.joined(separator: ".")
    }
}
