import Crypto
import Foundation
import HomeswiftAI
import _CryptoExtras

/// Tuya OpenAPI's request signature (developer.tuya.com, "API request" / "Sign request"): HMAC-SHA256 of
/// `client_id + access_token + t + nonce + stringToSign`, uppercase hex.
enum TuyaSignature {
    static let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The method, the body's SHA-256, the signed header (`client_id`) and the URL with its query sorted by key, unencoded.
    static func stringToSign(method: String, path: String, query: [(String, String)], body: Data?, accessID: String) -> String {
        let bodyHash = body.map { hex(SHA256.hash(data: $0)) } ?? emptyBodyHash
        var url = path
        let sorted = query.sorted { $0.0 < $1.0 }
        if !sorted.isEmpty { url += "?" + sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&") }
        return [method.uppercased(), bodyHash, "client_id:\(accessID)\n", url].joined(separator: "\n")
    }

    static func sign(accessID: String, accessKey: String, accessToken: String, t: String, nonce: String, stringToSign: String) -> String {
        let message = accessID + accessToken + t + nonce + stringToSign
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(accessKey.utf8)))
        return hex(mac).uppercased()
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    /// The password as the Smart Home login sends it: its lowercase MD5, unless it is one already (32 hex digits).
    static func loginPassword(_ password: String) -> (value: String, wasHashed: Bool) {
        if password.count == 32, password.allSatisfy(\.isHexDigit) { return (password, true) }
        return (hex(Insecure.MD5.hash(data: Data(password.utf8))), false)
    }
}

/// A JSON object written with its keys in a given order, compactly: Tuya hashes the exact bytes it is sent.
enum OrderedJSON {
    static func object(_ pairs: [(String, JSONValue)]) -> Data {
        Data(text(pairs).utf8)
    }

    static func text(_ pairs: [(String, JSONValue)]) -> String {
        "{" + pairs.map { JSONValue.string($0.0).text() + ":" + $0.1.text() }.joined(separator: ",") + "}"
    }

    /// `{"commands":[{"code":…,"value":…},…]}`.
    static func commands(_ commands: [TuyaCommand]) -> Data {
        Data(("{\"commands\":[" + commands.map { text([("code", .string($0.code)), ("value", $0.value)]) }.joined(separator: ",") + "]}").utf8)
    }
}

/// What a device is told: a DP code and its device-side value.
struct TuyaCommand: Sendable, Equatable {
    var code: String
    var value: JSONValue
}

/// The open-hub MQTT messages' encryption (developer.tuya.com, "Message Service"): AES-128-ECB with PKCS#7 for
/// `msg_encrypted_version` 1.0, AES-128-GCM for 2.0; the key is characters 8 to 23 of the MQTT password.
enum TuyaMessageCrypto {
    enum Failure: Error { case key, base64, decrypt, authentication }

    static func key(fromPassword password: String) -> SymmetricKey? {
        let characters = Array(password)
        guard characters.count >= 24 else { return nil }
        let key = Data(String(characters[8..<24]).utf8)
        return key.count == 16 ? SymmetricKey(data: key) : nil
    }

    /// AES-128-ECB, PKCS#7: each block decrypted alone, done as CBC with a zero IV whose chaining is undone.
    static func decryptECB(_ base64: String, key: SymmetricKey) throws -> Data {
        guard let ciphertext = Data(base64Encoded: base64) else { throw Failure.base64 }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw Failure.decrypt }
        var plain = try [UInt8](AES._CBC.decrypt(ciphertext, using: key, iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)), noPadding: true))
        let cipher = [UInt8](ciphertext)
        for index in 16..<plain.count { plain[index] ^= cipher[index - 16] }
        guard let padding = plain.last, (1...16).contains(Int(padding)), plain.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
            throw Failure.decrypt
        }
        return Data(plain.dropLast(Int(padding)))
    }

    /// AES-128-GCM: a 4-byte big-endian IV length, the IV, the ciphertext and a 16-byte tag; the authenticated data is the
    /// envelope's `t` as 6 bytes big-endian, tried as sent, then in the other unit (seconds or milliseconds). The tag is
    /// checked: a message that fails both is refused.
    static func decryptGCM(_ base64: String, key: SymmetricKey, t: Int64) throws -> Data {
        guard let data = Data(base64Encoded: base64) else { throw Failure.base64 }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw Failure.decrypt }
        let ivLength = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard ivLength >= 12, ivLength <= 64, bytes.count >= 4 + ivLength + 16 else { throw Failure.decrypt }
        let iv = bytes[4..<(4 + ivLength)]
        let ciphertext = bytes[(4 + ivLength)..<(bytes.count - 16)]
        let tag = bytes[(bytes.count - 16)...]
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let other = t >= 1_000_000_000_000 ? t / 1000 : t * 1000
        for time in [t, other] {
            if let plain = try? AES.GCM.open(box, using: key, authenticating: sixBytes(time)) { return plain }
        }
        throw Failure.authentication
    }

    static func sixBytes(_ value: Int64) -> Data {
        Data((0..<6).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}
