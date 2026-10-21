import Crypto
import Foundation

/// An eight-digit HomeKit setup code.
///
/// The protocol (and SRP) uses `XXX-XX-XXX`; the Home app shows the same digits as `XXXX-XXXX`.
public struct SetupCode: Sendable, Hashable, CustomStringConvertible {
    static let disallowed: Set<String> = Set((0...9).map { d in
        let s = String(d)
        return "\(s)\(s)\(s)-\(s)\(s)-\(s)\(s)\(s)"
    }).union(["123-45-678", "876-54-321"])

    /// The code as `XXX-XX-XXX`.
    public let rawValue: String

    /// Accepts `XXX-XX-XXX`, `XXXX-XXXX` or eight bare digits. Returns nil for malformed or trivial codes.
    public init?(_ string: String) {
        let digits = string.filter(\.isNumber)
        guard digits.count == 8, string.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        let chars = Array(digits)
        let formatted = String(chars[0..<3]) + "-" + String(chars[3..<5]) + "-" + String(chars[5..<8])
        guard !Self.disallowed.contains(formatted) else { return nil }
        rawValue = formatted
    }

    public static func random() -> SetupCode {
        while true {
            let digits = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
            if let code = SetupCode(digits) { return code }
        }
    }

    /// The same digits grouped as `XXXX-XXXX`, the way the Home app displays them.
    public var homeAppFormat: String {
        let digits = rawValue.filter(\.isNumber)
        return String(digits.prefix(4)) + "-" + String(digits.suffix(4))
    }

    var numericValue: UInt64 { UInt64(rawValue.filter(\.isNumber))! }

    /// Printed the way the Home app shows it, `XXXX-XXXX`.
    public var description: String { homeAppFormat }
}

enum SetupID {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func random() -> String {
        String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// `sh` TXT value: base64 of the first four bytes of SHA-512(setupID + deviceID).
    static func hash(setupID: String, deviceID: String) -> String {
        let digest = SHA512.hash(data: Data((setupID + deviceID).utf8))
        return Data(digest.prefix(4)).base64EncodedString()
    }
}

/// The `X-HM://` URI encoded in HomeKit QR codes.
///
/// Payload bits: version (3) | reserved (4) | category (8) | flags (4, 2 = IP) | setup code (27),
/// written as nine base-36 digits followed by the four-character setup ID.
func makeSetupURI(code: SetupCode, category: AccessoryCategory, setupID: String) -> String {
    let flags: UInt64 = 2
    var payload = UInt64(category.rawValue) << 31 | flags << 27 | code.numericValue
    var digits: [Character] = []
    for _ in 0..<9 {
        digits.append(SetupID.alphabet[Int(payload % 36)])
        payload /= 36
    }
    return "X-HM://" + String(digits.reversed()) + setupID
}
