import Crypto
import CryptoExtras
import Foundation

/// This side's DTLS certificate: an ephemeral self-signed X.509 v3 certificate on a P-256 key, as WebRTC peers use.
/// Nobody validates it by chain: the peer compares its SHA-256 fingerprint with the one in the SDP.
public struct DTLSCertificate: Sendable {
    public let privateKey: P256.Signing.PrivateKey
    /// The certificate's DER.
    public let der: [UInt8]

    /// A new key and a certificate for it, valid from a day ago (clocks differ) for `validity`.
    public static func generate(commonName: String = "homeswift", validity: TimeInterval = 30 * 86400, now: Date = Date()) throws -> DTLSCertificate {
        let key = P256.Signing.PrivateKey()
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7f  // positive
        serial[0] |= 0x01  // and never a leading zero to strip
        let algorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))  // ecdsa-with-SHA256, no parameters
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([2, 5, 4, 3]) + DER.utf8String(commonName))))
        let validityField = DER.sequence(DER.utcTime(now.addingTimeInterval(-86400)) + DER.utcTime(now.addingTimeInterval(validity)))
        let tbs = DER.sequence(
            DER.contextExplicit(0, DER.integer([2]))  // v3
                + DER.integer(serial) + algorithm + name + validityField + name
                + Array(key.publicKey.derRepresentation)  // SubjectPublicKeyInfo
        )
        let signature = try key.signature(for: tbs)
        let der = DER.sequence(tbs + algorithm + DER.bitString(Array(signature.derRepresentation)))
        return DTLSCertificate(privateKey: key, der: der)
    }

    public init(privateKey: P256.Signing.PrivateKey, der: [UInt8]) {
        self.privateKey = privateKey
        self.der = der
    }

    /// `AA:BB:…`, the SHA-256 of the DER in upper-case hex, for `a=fingerprint:sha-256`.
    public var fingerprint: String { Self.fingerprint(of: der) }

    public static func fingerprint(of der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// A fingerprint as SDP or a person writes it, reduced to its bytes: an optional `sha-256 ` prefix, any case,
    /// colons or not. Nil when it is not 32 bytes of hex. ASCII only: `Character.isHexDigit` also takes fullwidth
    /// digits, which the value comes from a remote SDP to carry.
    static func fingerprintBytes(_ text: String) -> [UInt8]? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sha-256") { text = String(text.dropFirst("sha-256".count)) }
        var nibbles: [UInt8] = []
        for unit in text.utf8 {
            switch unit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibbles.append(unit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibbles.append(unit - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibbles.append(unit - UInt8(ascii: "A") + 10)
            case UInt8(ascii: ":"), UInt8(ascii: " "): continue
            default: return nil
            }
        }
        guard nibbles.count == 64 else { return nil }
        return stride(from: 0, to: 64, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }
}

/// The public key in a peer's certificate, to check its ServerKeyExchange or CertificateVerify signature.
enum PeerPublicKey {
    case p256(P256.Signing.PublicKey)
    case rsa(_RSA.Signing.PublicKey)

    /// Reads the SubjectPublicKeyInfo out of a certificate's DER: Certificate → tbsCertificate → its seventh field
    /// (sixth without the explicit version).
    init(certificate der: [UInt8]) throws {
        var outer = DER.Reader(der)
        guard let certificate = outer.element(), certificate.tag == 0x30 else { throw DTLSError.badCertificate }
        var inner = DER.Reader(certificate.content)
        guard let tbs = inner.element(), tbs.tag == 0x30 else { throw DTLSError.badCertificate }
        var reader = DER.Reader(tbs.content)
        var fields: [DER.Element] = []
        while let element = reader.element() { fields.append(element) }
        let offset = fields.first?.tag == 0xa0 ? 1 : 0
        guard fields.count > offset + 5, fields[offset + 5].tag == 0x30 else { throw DTLSError.badCertificate }
        let spki = fields[offset + 5].raw
        if let key = try? P256.Signing.PublicKey(derRepresentation: spki) {
            self = .p256(key)
        } else if let key = try? _RSA.Signing.PublicKey(derRepresentation: spki) {
            self = .rsa(key)
        } else {
            throw DTLSError.unsupportedCertificate
        }
    }

    /// Whether `signature` with TLS SignatureScheme `scheme` signs `data`.
    func verify(scheme: UInt16, signature: [UInt8], data: [UInt8]) -> Bool {
        switch (self, scheme) {
        case (.p256(let key), DTLSConstants.ecdsaP256SHA256):
            guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(parsed, for: data)
        case (.rsa(let key), DTLSConstants.rsaPKCS1SHA256):
            return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        case (.rsa(let key), DTLSConstants.rsaPSSRSAESHA256):
            return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: SHA256.hash(data: data), padding: .PSS)
        default:
            return false
        }
    }

    /// The schemes this key can have signed with, of those this side offers.
    var schemes: [UInt16] {
        switch self {
        case .p256: [DTLSConstants.ecdsaP256SHA256]
        case .rsa: [DTLSConstants.rsaPSSRSAESHA256, DTLSConstants.rsaPKCS1SHA256]
        }
    }
}

/// Just enough DER (X.690) to write a certificate and find a key in one.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }
    static func set(_ content: [UInt8]) -> [UInt8] { tlv(0x31, content) }
    static func contextExplicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xa0 | number, content) }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0c, Array(text.utf8)) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }

    /// A non-negative INTEGER from big-endian bytes: leading zeros dropped, one added when the top bit is set.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }

    static func oid(_ arcs: [UInt]) -> [UInt8] {
        var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7f)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7f) | 0x80, at: 0)
                value >>= 7
            }
            content += chunk
        }
        return tlv(0x06, content)
    }

    /// UTCTime `YYMMDDHHMMSSZ` (RFC 5280 uses it through 2049).
    static func utcTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ", c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return tlv(0x17, Array(text.utf8))
    }

    struct Element {
        var tag: UInt8
        var content: [UInt8]
        /// The whole TLV.
        var raw: [UInt8]
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func element() -> Element? {
            let start = index
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count >= 1, count <= 4, index + count <= bytes.count else { return nil }
                length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard length >= 0, index + length <= bytes.count else { return nil }
            let content = Array(bytes[index..<(index + length)])
            index += length
            return Element(tag: tag, content: content, raw: Array(bytes[start..<index]))
        }
    }
}
