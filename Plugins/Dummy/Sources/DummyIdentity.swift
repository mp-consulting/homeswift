import Crypto
import Foundation
import Homeswift

/// The identities the Homebridge plugin derives from an accessory's identifier (spec 3.2, 6.3).
enum DummyIdentity {
    /// HAP-NodeJS's name-based UUID: the SHA-1 of the text, laid out 8-4-4-4-12 with the version digit 4 and the
    /// variant digit of RFC 4122.
    static func uuid(_ text: String) -> String {
        let hex = Array(Secrets.hex(Insecure.SHA1.hash(data: Data(text.utf8))))
        func digits(_ range: Range<Int>) -> String { String(hex[range]) }
        let variant = String((Int(String(hex[15]), radix: 16)! & 0x3) | 0x8, radix: 16)
        return "\(digits(0..<8))-\(digits(8..<12))-4\(digits(12..<15))-\(variant)\(digits(16..<19))-\(digits(19..<31))"
    }

    /// Where a limiter's usage is kept: the SHA-256 of `<identifier>:<limit>:<units>:<period>`, its first 32 digits
    /// laid out 8-4-4-4-12.
    static func limiterIdentifier(accessory identifier: String, limiter: LimiterConfig) -> String {
        let seed = "\(identifier):\(javaScriptNumber(limiter.limit)):\(limiter.units.rawValue):\(limiter.period.rawValue)"
        let hex = Array(Secrets.hex(SHA256.hash(data: Data(seed.utf8))))
        func digits(_ range: Range<Int>) -> String { String(hex[range]) }
        return "\(digits(0..<8))-\(digits(8..<12))-\(digits(12..<16))-\(digits(16..<20))-\(digits(20..<32))"
    }

    /// A group's identifier, with the two characters the Homebridge plugin appends: they decide its UUID.
    static func groupIdentifier(_ groupName: String) -> String {
        "\(DummyPlugin.platform):Group:\(ConfigReader.stripWhitespace(groupName)))}"
    }

    /// The Eve history file of an accessory: the UUID of its identifier followed by fakegato's suffix.
    static func historyFileName(_ identifier: String) -> String {
        uuid(identifier + "dbca6d94-6d1b-45e1-9feb-daf030819984")
    }
}
