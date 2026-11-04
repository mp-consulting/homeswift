import Crypto
import Foundation

/// Web push's `aesgcm` content encoding (draft-ietf-webpush-encryption-03, draft-ietf-httpbis-encryption-encoding-03),
/// which FCM uses for a web-push registration's messages: the sender's key in `crypto-key` (`dh=`), the salt in
/// `encryption` (`salt=`), records of `rs` bytes each with a 16-byte tag and a 2-byte padding length
/// (docs/clean-room/FCMReceiver.md, section 8).
public enum WebPushDecryption {
    public enum DecryptionError: Error, Equatable, CustomStringConvertible {
        case missingCryptoKey
        case missingEncryption
        case missingParameter(String)
        case invalidKey
        case authenticationFailed
        case invalidPadding

        public var description: String {
            switch self {
            case .missingCryptoKey: "the message has no crypto-key"
            case .missingEncryption: "the message has no encryption parameters"
            case .missingParameter(let name): "the message has no \(name)"
            case .invalidKey: "the message's key is not a P-256 point"
            case .authenticationFailed: "the message does not decrypt with this receiver's keys"
            case .invalidPadding: "the message's padding is malformed"
            }
        }
    }

    /// The receiver's keys: its P-256 private key (32 bytes) and the 16-byte auth secret it registered with.
    public struct Keys: Sendable {
        public var privateKey: P256.KeyAgreement.PrivateKey
        public var authSecret: [UInt8]

        public init(privateKey: P256.KeyAgreement.PrivateKey, authSecret: [UInt8]) {
            self.privateKey = privateKey
            self.authSecret = authSecret
        }

        /// The receiver's public key, uncompressed (65 bytes).
        public var publicKey: [UInt8] { Array(privateKey.publicKey.x963Representation) }
    }

    /// One parameter of a `crypto-key` or `encryption` header value: `a=b;c=d`.
    public static func parameter(_ name: String, in header: String) -> String? {
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals] == name { return String(trimmed[trimmed.index(after: equals)...]) }
        }
        return nil
    }

    /// Decrypts a message from its app data (`crypto-key`, `encryption`) and raw data. `recordSize` is the `rs` of the
    /// `encryption` value when given, 4096 otherwise.
    public static func decrypt(_ ciphertext: [UInt8], appData: [String: String], keys: Keys, recordSize: Int? = nil) throws -> [UInt8] {
        guard let cryptoKey = appData["crypto-key"] else { throw DecryptionError.missingCryptoKey }
        guard let encryption = appData["encryption"] else { throw DecryptionError.missingEncryption }
        guard let dh = parameter("dh", in: cryptoKey).flatMap(base64URLDecode) else { throw DecryptionError.missingParameter("dh") }
        guard let salt = parameter("salt", in: encryption).flatMap(base64URLDecode) else { throw DecryptionError.missingParameter("salt") }
        let size = recordSize ?? parameter("rs", in: encryption).flatMap { Int($0) } ?? 4096
        return try decrypt(ciphertext, senderPublicKey: dh, salt: salt, keys: keys, recordSize: size)
    }

    public static func decrypt(_ ciphertext: [UInt8], senderPublicKey: [UInt8], salt: [UInt8], keys: Keys, recordSize: Int = 4096) throws -> [UInt8] {
        let (key, nonce) = try contentKeys(senderPublicKey: senderPublicKey, salt: salt, keys: keys)
        guard recordSize > 2 else { throw DecryptionError.invalidPadding }
        let chunk = recordSize + 16
        var plaintext: [UInt8] = []
        var offset = 0
        var record: UInt64 = 0
        while offset < ciphertext.count {
            let end = min(offset + chunk, ciphertext.count)
            let piece = ciphertext[offset..<end]
            guard piece.count > 16 else { throw DecryptionError.authenticationFailed }
            var recordNonce = nonce
            for index in 0..<6 { recordNonce[6 + index] ^= UInt8(truncatingIfNeeded: record >> (8 * UInt64(5 - index))) }
            let decrypted: [UInt8]
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: recordNonce), ciphertext: piece.dropLast(16), tag: piece.suffix(16))
                decrypted = Array(try AES.GCM.open(box, using: SymmetricKey(data: key)))
            } catch {
                throw DecryptionError.authenticationFailed
            }
            guard decrypted.count >= 2 else { throw DecryptionError.invalidPadding }
            let padding = Int(decrypted[0]) << 8 | Int(decrypted[1])
            guard padding <= decrypted.count - 2, decrypted[2..<2 + padding].allSatisfy({ $0 == 0 }) else { throw DecryptionError.invalidPadding }
            plaintext += decrypted[(2 + padding)...]
            offset = end
            record += 1
        }
        return plaintext
    }

    /// The content encryption key (16 bytes) and the base nonce (12 bytes) of a message.
    static func contentKeys(senderPublicKey: [UInt8], salt: [UInt8], keys: Keys) throws -> (key: [UInt8], nonce: [UInt8]) {
        guard senderPublicKey.count == 65, let sender = try? P256.KeyAgreement.PublicKey(x963Representation: senderPublicKey) else {
            throw DecryptionError.invalidKey
        }
        let shared = try keys.privateKey.sharedSecretFromKeyAgreement(with: sender).withUnsafeBytes { Array($0) }
        let ikm = hkdf(salt: keys.authSecret, ikm: shared, info: Array("Content-Encoding: auth".utf8) + [0], length: 32)
        let receiver = keys.publicKey
        let context = Array("P-256".utf8) + [0, 0, 65] + receiver + [0, 65] + senderPublicKey
        let key = hkdf(salt: salt, ikm: ikm, info: Array("Content-Encoding: aesgcm".utf8) + [0] + context, length: 16)
        let nonce = hkdf(salt: salt, ikm: ikm, info: Array("Content-Encoding: nonce".utf8) + [0] + context, length: 12)
        return (key, nonce)
    }

    /// RFC 5869 with SHA-256, for a length of at most 32 bytes (one block).
    static func hkdf(salt: [UInt8], ikm: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        let block = HMAC<SHA256>.authenticationCode(for: info + [1], using: SymmetricKey(data: Data(prk)))
        return Array(Array(block).prefix(length))
    }
}

extension WebPushDecryption {
    /// Base64url without padding (`+`→`-`, `/`→`_`, no `=`), as web push writes keys.
    public static func base64URLEncode(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Either alphabet, padded or not.
    public static func base64URLDecode(_ text: String) -> [UInt8]? {
        var base64 = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).map(Array.init)
    }
}
