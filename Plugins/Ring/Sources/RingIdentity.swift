import Crypto
import Foundation
import HomeswiftPlugin

/// Ring's identifiers: the Homebridge UUIDs `hideDeviceIds` lists, the hardware id Ring knows this client by, and the
/// Homebridge plugin's refresh-token wrapper (docs/clean-room/Ring.md, 2.2, 2.3 and 4.1).
enum RingIdentity {
    /// HAP-NodeJS's name-based UUID of an identity seed (`1001camera`, a zid…): SHA-1 of the seed, version nibble 4,
    /// variant bits 10. `hideDeviceIds` holds these.
    static func homebridgeUUID(_ seed: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined())
        func digits(_ range: Range<Int>) -> String { String(digest[range]) }
        let variant = String((Int(String(digest[15]), radix: 16)! & 0x3) | 0x8, radix: 16)
        return "\(digits(0..<8))-\(digits(8..<12))-4\(digits(12..<15))-\(variant)\(digits(16..<19))-\(digits(19..<31))"
    }

    /// The namespace of Ring's hardware ids (UUID version 5 of the system id).
    static let hardwareIDNamespace = UUID(uuidString: "e53ffdc0-e91d-4ce1-bec2-df939d94739d")!

    /// RFC 4122 version 5: SHA-1 of the namespace's bytes and the name, lowercase.
    static func uuidV5(_ name: String, namespace: UUID) -> String {
        let namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        var bytes = Array(Insecure.SHA1.hash(data: Data(namespaceBytes + Array(name.utf8))).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let digits = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(digits[$0]) }.joined(separator: "-")
    }

    static func hardwareID(systemID: String) -> String { uuidV5(systemID, namespace: hardwareIDNamespace) }

    /// A new system id, as `.ring.json` keeps it: SHA-256 of 32 random bytes, in hex.
    static func newSystemID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Homebridge plugin's `refreshToken`: base64 of `{"rt": …, "hid": …, "pnc": …}`, or a bare Ring refresh token.
struct RingTokenWrapper: Equatable, Sendable {
    var refreshToken: String
    var hardwareID: String?
    /// Every other member (`pnc`, the push library's credentials; what a later version adds), kept for moving back.
    var others: [String: JSONValue]

    init(refreshToken: String, hardwareID: String?, others: [String: JSONValue] = [:]) {
        self.refreshToken = refreshToken
        self.hardwareID = hardwareID
        self.others = others
    }

    /// Reads a wrapper; anything that is not one is a bare refresh token.
    init(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed), let object = (try? JSONValue(data: data))?.objectValue,
           let rt = object["rt"]?.stringValue, !rt.isEmpty {
            refreshToken = rt
            hardwareID = object["hid"]?.stringValue
            others = object.filter { $0.key != "rt" && $0.key != "hid" }
        } else {
            refreshToken = trimmed
            hardwareID = nil
            others = [:]
        }
    }

    /// The wrapper as the Homebridge plugin writes it.
    var encoded: String {
        var object = others
        object["rt"] = .string(refreshToken)
        if let hardwareID { object["hid"] = .string(hardwareID) }
        let keys = ["rt", "hid"] + object.keys.filter { $0 != "rt" && $0 != "hid" }.sorted()
        // A compact object with `rt` and `hid` first, as the Homebridge plugin's.
        let members = keys.compactMap { key in object[key].map { "\(JSONValue.string(key).text()):\($0.text())" } }
        return Data("{\(members.joined(separator: ","))}".utf8).base64EncodedString()
    }
}

/// What the vault keeps for the account (`context.credentials()`): the current Ring refresh token (it rotates on every
/// token request, so it is saved each time), the hardware id Ring knows this client by, the members of a Homebridge
/// wrapper this plugin does not use, and which block token they were imported from.
struct RingAccount: Codable, Equatable, Sendable {
    var refreshToken: String
    var hardwareId: String
    var wrapper: [String: JSONValue]?
    /// SHA-256 of the block's `refreshToken` this was imported from: a different one pasted later wins.
    var importedFrom: String?

    var tokenWrapper: RingTokenWrapper { RingTokenWrapper(refreshToken: refreshToken, hardwareID: hardwareId, others: wrapper ?? [:]) }
}
