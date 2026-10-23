import Crypto
import Foundation
import Homeswift
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A self-signed certificate for the OAuth callback server: the redirect URI the Developer Portal requires
/// is `https://`, so the browser lands on this host over TLS (and warns once about the certificate).
///
/// The Homebridge plugin calls the `openssl` binary for this; here the certificate is built directly: an
/// X.509 v3 certificate with a P-256 key, the address as its common name and subject alternative name (an IP
/// address or a DNS name), valid for a year, signed with ECDSA-SHA256. Kept as `server.crt` and
/// `server.key` (PEM) under `daikin-cloud-certs/`, and reused while it is valid for the same address.
enum SelfSignedCertificate {
    struct Material: Sendable {
        var certificateDER: [UInt8]
        var certificatePEM: String
        var privateKeyPEM: String
    }

    static let validity: TimeInterval = 365 * 24 * 3600
    /// A certificate older than this is made again, before browsers call it expired as well as unknown.
    static let renewAfter: TimeInterval = 300 * 24 * 3600

    /// A host name or address safe to put in a certificate: letters, digits, dots, hyphens, underscores and
    /// colons (IPv6), 253 characters at most.
    static func validate(_ hostname: String) throws {
        guard !hostname.isEmpty else { throw DaikinError("Hostname is required") }
        guard hostname.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".:_-".contains($0)) }) else {
            throw DaikinError("Invalid hostname: contains disallowed characters")
        }
        guard hostname.count <= 253 else { throw DaikinError("Hostname too long (max 253 characters)") }
    }

    /// The certificate in `directory` when it is still good for `hostname`, else a new one written there.
    static func load(for hostname: String, in directory: URL, now: Date = Date()) throws -> Material {
        try validate(hostname)
        let keyURL = directory.appendingPathComponent("server.key")
        let certificateURL = directory.appendingPathComponent("server.crt")
        let hostURL = directory.appendingPathComponent("server.host")
        if let key = try? String(contentsOf: keyURL, encoding: .utf8), let certificate = try? String(contentsOf: certificateURL, encoding: .utf8),
            (try? String(contentsOf: hostURL, encoding: .utf8)) == hostname,
            let created = (try? FileManager.default.attributesOfItem(atPath: certificateURL.path))?[.modificationDate] as? Date,
            now.timeIntervalSince(created) < renewAfter, let der = derFromPEM(certificate)
        {
            return Material(certificateDER: der, certificatePEM: certificate, privateKeyPEM: key)
        }
        let material = try make(hostname: hostname, now: now)
        try OwnerOnlyFile.write(Data(material.privateKeyPEM.utf8), to: keyURL)
        try OwnerOnlyFile.write(Data(material.certificatePEM.utf8), to: certificateURL)
        try OwnerOnlyFile.write(Data(hostname.utf8), to: hostURL)
        return material
    }

    static func make(hostname: String, now: Date = Date()) throws -> Material {
        let key = P256.Signing.PrivateKey()
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8String(hostname)])]),
            DER.set([DER.sequence([DER.oid([2, 5, 4, 10]), DER.utf8String("Homeswift Daikin Cloud")])]),
            DER.set([DER.sequence([DER.oid([2, 5, 4, 6]), DER.printableString("US")])]),
        ])
        let alternativeName: [UInt8]
        if let address = ipAddressBytes(hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            alternativeName = DER.tlv(0x87, address)
        } else {
            alternativeName = DER.tlv(0x82, Array(hostname.utf8))
        }
        let extensions = DER.tlv(0xA3, DER.sequence([
            DER.sequence([DER.oid([2, 5, 29, 17]), DER.octetString(DER.sequence([alternativeName]))]),
            // Basic constraints: not a CA.
            DER.sequence([DER.oid([2, 5, 29, 19]), DER.octetString(DER.sequence([]))]),
            // Extended key usage: TLS server.
            DER.sequence([DER.oid([2, 5, 29, 37]), DER.octetString(DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])]))]),
        ]))
        let signatureAlgorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        var serial = Array(Secrets.randomBytes(16))
        serial[0] &= 0x7F
        let tbs = DER.sequence([
            DER.tlv(0xA0, DER.integer([2])),
            DER.integer(serial),
            signatureAlgorithm,
            name,
            DER.sequence([DER.utcTime(now.addingTimeInterval(-3600)), DER.utcTime(now.addingTimeInterval(validity))]),
            name,
            Array(key.publicKey.derRepresentation),
            extensions,
        ])
        let signature = try key.signature(for: tbs)
        let certificate = DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature.derRepresentation))])
        return Material(certificateDER: certificate, certificatePEM: pem(certificate, label: "CERTIFICATE"), privateKeyPEM: key.pemRepresentation)
    }

    /// The bytes of an IPv4 or IPv6 literal.
    static func ipAddressBytes(_ string: String) -> [UInt8]? {
        let trimmed = string
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    static func pem(_ der: [UInt8], label: String) -> String {
        let base64 = Data(der).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----\n"
    }

    static func derFromPEM(_ pem: String) -> [UInt8]? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map(Array.init)
    }
}

/// Distinguished Encoding Rules, the little a certificate needs.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }
    static func utf8String(_ string: String) -> [UInt8] { tlv(0x0C, Array(string.utf8)) }
    static func printableString(_ string: String) -> [UInt8] { tlv(0x13, Array(string.utf8)) }

    /// A non-negative integer from its big-endian bytes.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var trimmed = Array(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { trimmed = [0] }
        if trimmed[0] & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return tlv(0x02, trimmed)
    }

    static func oid(_ components: [UInt]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(component & 0x7F)]
            var value = component >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }

    /// `YYMMDDHHMMSSZ` in UTC.
    static func utcTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ", (c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return tlv(0x17, Array(text.utf8))
    }
}
