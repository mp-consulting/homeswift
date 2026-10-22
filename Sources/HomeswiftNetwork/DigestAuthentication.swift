import Crypto
import Foundation

/// HTTP Digest authentication (RFC 2617, MD5, `qop=auth`), the scheme of Philips TVs and other devices.
///
/// Remembers the challenge of a 401 so later requests carry an `Authorization` header straight away, with
/// a nonce count that grows by one per request. The password stays inside; nothing here prints it.
public struct DigestAuthentication: Sendable {
    public struct Challenge: Sendable, Equatable {
        public var realm: String
        public var nonce: String
        public var qop: String?
        public var opaque: String?
        public var algorithm: String?

        public init(realm: String, nonce: String, qop: String? = nil, opaque: String? = nil, algorithm: String? = nil) {
            self.realm = realm
            self.nonce = nonce
            self.qop = qop
            self.opaque = opaque
            self.algorithm = algorithm
        }

        /// Parses a `WWW-Authenticate: Digest …` header. nil for another scheme or no nonce.
        public init?(header: String) {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("digest") else { return nil }
            var parameters: [String: String] = [:]
            var rest = Substring(trimmed.dropFirst("digest".count))
            while let equals = rest.firstIndex(of: "=") {
                let key = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: ", \t")).lowercased()
                rest = rest[rest.index(after: equals)...]
                let value: String
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    let end = rest.firstIndex(of: "\"") ?? rest.endIndex
                    value = String(rest[..<end])
                    rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
                } else {
                    let end = rest.firstIndex(of: ",") ?? rest.endIndex
                    value = rest[..<end].trimmingCharacters(in: .whitespaces)
                    rest = rest[end...]
                }
                if !key.isEmpty { parameters[key] = value }
            }
            guard let realm = parameters["realm"], let nonce = parameters["nonce"], !nonce.isEmpty else { return nil }
            // A server may offer several qop values; `auth` is the one this implements.
            let qop = parameters["qop"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                .flatMap { $0.contains("auth") ? "auth" : $0.first }
            self.init(realm: realm, nonce: nonce, qop: qop, opaque: parameters["opaque"], algorithm: parameters["algorithm"])
        }
    }

    public let username: String
    private let password: String
    private(set) var challenge: Challenge?
    private var nonceCount: UInt32 = 0

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var hasChallenge: Bool { challenge != nil }

    /// Remembers the challenge of a 401. Returns false when the header is not a Digest challenge.
    @discardableResult
    public mutating func accept(challenge header: String) -> Bool {
        guard let parsed = Challenge(header: header) else { return false }
        challenge = parsed
        nonceCount = 0
        return true
    }

    /// Forgets the challenge, e.g. after a 401 to a request that carried credentials (a stale nonce).
    public mutating func clear() {
        challenge = nil
        nonceCount = 0
    }

    /// The `Authorization` header for a request, or nil without a challenge. `cnonce` is random unless a
    /// test passes one.
    public mutating func authorization(method: String, uri: String, cnonce: String? = nil) -> String? {
        guard let challenge else { return nil }
        nonceCount &+= 1
        let nc = String(format: "%08x", nonceCount)
        let cnonce = cnonce ?? Self.randomHex(16)
        let ha1 = Self.md5("\(username):\(challenge.realm):\(password)")
        let ha2 = Self.md5("\(method.uppercased()):\(uri)")
        let response: String
        if let qop = challenge.qop {
            response = Self.md5("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = Self.md5("\(ha1):\(challenge.nonce):\(ha2)")
        }
        var header = "Digest username=\"\(Self.quote(username))\", realm=\"\(Self.quote(challenge.realm))\", nonce=\"\(challenge.nonce)\", uri=\"\(uri)\", response=\"\(response)\""
        if let qop = challenge.qop {
            header += ", qop=\(qop), nc=\(nc), cnonce=\"\(cnonce)\""
        }
        if let opaque = challenge.opaque {
            header += ", opaque=\"\(opaque)\""
        }
        if let algorithm = challenge.algorithm {
            header += ", algorithm=\(algorithm)"
        }
        return header
    }

    static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
