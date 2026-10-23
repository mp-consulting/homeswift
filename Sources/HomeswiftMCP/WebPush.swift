import Crypto
import Foundation
import HomeswiftNetwork

/// Web Push without a dependency, as Glass UI's web-push.ts: VAPID (RFC 8292) signed with ES256, and the payload
/// encrypted as `aes128gcm` (RFC 8188, RFC 8291) in one record.
public enum WebPush {
    public struct Keys: Codable, Sendable, Equatable {
        /// The uncompressed P-256 public key (65 bytes), base64url: the browser's `applicationServerKey`.
        public var publicKey: String
        /// The private scalar (32 bytes), base64url.
        public var privateKey: String

        public static func generate() -> Keys {
            let key = P256.Signing.PrivateKey()
            return Keys(publicKey: base64url(key.publicKey.x963Representation), privateKey: base64url(key.rawRepresentation))
        }

        public var isValid: Bool {
            guard let pub = data(base64url: publicKey), let priv = data(base64url: privateKey), pub.count == 65, priv.count == 32 else { return false }
            return (try? P256.Signing.PrivateKey(rawRepresentation: priv)) != nil
        }
    }

    public struct Subscription: Codable, Sendable, Equatable {
        public var id: String
        public var endpoint: String
        /// The browser's P-256 public key, base64url.
        public var p256dh: String
        /// The 16-byte auth secret, base64url.
        public var auth: String
        public var label: String
        public var username: String?
        public var createdAt: String
    }

    static let recordSize = 4096
    /// The most plaintext one record holds (the record size, less the delimiter and the GCM tag, and the header).
    public static let maxPayloadBytes = recordSize - 17 - 86

    public static func base64url(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "=", with: "")
        guard base64.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }) else { return nil }
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// The `Authorization` header for a push service: a VAPID JWT for the endpoint's origin, valid 12 hours.
    public static func authorization(endpoint: URL, keys: Keys, subject: String, now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host, let raw = data(base64url: keys.privateKey) else { throw WebPushError("Invalid push endpoint or keys") }
        let origin = "\(scheme)://\(host)\(endpoint.port.map { ":\($0)" } ?? "")"
        let header = base64url(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: JSONValueLike = ["aud": .string(origin), "exp": .int(Int(now.timeIntervalSince1970) + 12 * 3600), "sub": .string(subject)]
        let body = base64url(Data(claims.json.utf8))
        let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        let signature = try key.signature(for: Data("\(header).\(body)".utf8))
        return "vapid t=\(header).\(body).\(base64url(signature.rawRepresentation)), k=\(keys.publicKey)"
    }

    /// Encrypts a payload for one subscription (RFC 8291, one aes128gcm record). `salt` and `serverKey` are for
    /// tests: by default both are random.
    public static func encrypt(_ payload: Data, p256dh: String, auth: String, salt: Data? = nil, serverKey: P256.KeyAgreement.PrivateKey? = nil) throws -> Data {
        guard payload.count <= maxPayloadBytes else { throw WebPushError("Push payload too large (\(payload.count) bytes)") }
        guard let uaPublic = data(base64url: p256dh), let authSecret = data(base64url: auth), uaPublic.count == 65, authSecret.count == 16 else {
            throw WebPushError("Invalid push subscription keys")
        }
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let server = serverKey ?? P256.KeyAgreement.PrivateKey()
        let asPublic = server.publicKey.x963Representation
        let shared = try server.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: uaPublic))
        let keyInfo = Data("WebPush: info\0".utf8) + uaPublic + asPublic
        let ikm = shared.withUnsafeBytes { secret in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret)), salt: authSecret, info: keyInfo, outputByteCount: 32)
        }
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        // The last (and only) record ends with the 0x02 delimiter.
        let sealed = try AES.GCM.seal(payload + Data([2]), using: cek, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
        var header = salt
        withUnsafeBytes(of: UInt32(recordSize).bigEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(asPublic.count))
        return header + asPublic + sealed.ciphertext + sealed.tag
    }

    /// The push service no longer knows the subscription (404, 410): forget it.
    public struct Gone: Error {}

    /// Sends one push message; throws `Gone` for a subscription that no longer exists.
    public static func send(_ payload: Data, to subscription: Subscription, keys: Keys, subject: String, urgent: Bool, http: any HTTPSending) async throws {
        guard let endpoint = URL(string: subscription.endpoint) else { throw WebPushError("Invalid push endpoint") }
        let body = try encrypt(payload, p256dh: subscription.p256dh, auth: subscription.auth)
        let request = HTTPRequest(method: "POST", url: endpoint, headers: [
            ("Authorization", try authorization(endpoint: endpoint, keys: keys, subject: subject)),
            ("Content-Encoding", "aes128gcm"), ("Content-Type", "application/octet-stream"),
            ("TTL", "\(24 * 3600)"), ("Urgency", urgent ? "high" : "normal"),
        ], body: body)
        let response = try await http.send(request)
        if response.status == 404 || response.status == 410 { throw Gone() }
        guard (200..<300).contains(response.status) else { throw WebPushError("HTTP \(response.status)") }
    }
}

public struct WebPushError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// A tiny JSON writer for the JWT claims, in a fixed key order.
struct JSONValueLike: ExpressibleByDictionaryLiteral {
    enum Value { case string(String), int(Int) }
    let pairs: [(String, Value)]
    init(dictionaryLiteral elements: (String, Value)...) { pairs = elements }
    var json: String {
        "{" + pairs.map { key, value in
            let text: String = switch value {
            case .string(let string): "\"\(string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            case .int(let int): "\(int)"
            }
            return "\"\(key)\":\(text)"
        }.joined(separator: ",") + "}"
    }
}
