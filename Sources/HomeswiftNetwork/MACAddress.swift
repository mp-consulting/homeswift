import Foundation

/// MAC addresses as people and devices spell them: colons, hyphens, dots or no separator at all, either case,
/// octets with or without their leading zero (macOS's `arp` drops it). One spelling comes out,
/// `3C:6A:9D:04:0A:0B`, so a device is keyed the same however its address reached the bridge: the accessory id
/// is built from it, and HomeKit keeps rooms and scenes by that id.
public enum MACAddress {
    /// The canonical spelling, or nil when the text is not a MAC address.
    public static func canonical(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let octets = trimmed.split(whereSeparator: { $0 == ":" || $0 == "-" })
        let digits: String
        if octets.count == 6, octets.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) {
            digits = octets.map { $0.count == 1 ? "0" + $0 : String($0) }.joined()
        } else {
            digits = trimmed.filter { $0 != ":" && $0 != "-" && $0 != "." && $0 != " " }
        }
        guard digits.count == 12, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let characters = Array(digits.uppercased())
        return stride(from: 0, to: 12, by: 2).map { String(characters[$0..<$0 + 2]) }.joined(separator: ":")
    }
}
