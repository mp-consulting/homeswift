import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin
import NIOSSL

/// The webhook server's HTTPS identity: the PEM key and certificate `https_keyfile` and `https_certfile` name, or a
/// self-signed certificate made once and kept in the vault (its key is a secret), made again after 364 days as the
/// Homebridge plugin does. It names `homebridgeHttpWebhooks.com` and `localhost`, as that plugin's did, so a client that
/// pinned or allowed those names still connects.
enum WebhookCertificate {
    /// What the vault keeps, under the Homebridge plugin's cache key.
    struct Stored: Codable, Sendable {
        var `private`: String
        var cert: String
        /// Milliseconds since 1970.
        var timestamp: Double
        var certVersion: Int
    }

    static let fileName = "http-webhook-ssl-cert.json"
    static let version = 2
    static let validity: TimeInterval = 365 * 86_400
    static let renewAfter: TimeInterval = 364 * 86_400
    static let names = ["homebridgeHttpWebhooks.com", "localhost"]

    struct FileError: Error, CustomStringConvertible {
        var description: String
    }

    static func context(keyFile: String?, certificateFile: String?, secrets: SecretFile<Stored>, now: Date = Date()) throws -> (NIOSSLContext, generated: Bool) {
        let chain: [NIOSSLCertificate]
        let key: NIOSSLPrivateKey
        var generated = false
        if let keyFile, let certificateFile {
            do {
                chain = try NIOSSLCertificate.fromPEMFile(expand(certificateFile))
                key = try NIOSSLPrivateKey(file: expand(keyFile), format: .pem)
            } catch {
                throw FileError(description: "cannot read https_keyfile or https_certfile: \(error)")
            }
        } else {
            let stored: Stored
            if let current = secrets.load(), current.certVersion == version, now.timeIntervalSince1970 * 1000 - current.timestamp <= renewAfter * 1000 {
                stored = current
            } else {
                stored = try make(now: now)
                try secrets.save(stored)
                generated = true
            }
            chain = try NIOSSLCertificate.fromPEMBytes(Array(stored.cert.utf8))
            key = try NIOSSLPrivateKey(bytes: Array(stored.private.utf8), format: .pem)
        }
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: chain.map { .certificate($0) }, privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        return (try NIOSSLContext(configuration: configuration), generated)
    }

    private static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    /// An X.509 v3 certificate with a P-256 key, signed with ECDSA-SHA256, for `names`.
    static func make(now: Date) throws -> Stored {
        let key = P256.Signing.PrivateKey()
        let subject = DER.sequence([
            DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8String(names[0])])]),
            DER.set([DER.sequence([DER.oid([2, 5, 4, 10]), DER.utf8String("Homeswift HTTP Webhooks")])]),
        ])
        let extensions = DER.tlv(0xA3, DER.sequence([
            DER.sequence([DER.oid([2, 5, 29, 17]), DER.octetString(DER.sequence(names.map { DER.tlv(0x82, Array($0.utf8)) }))]),
            // Basic constraints: not a CA.
            DER.sequence([DER.oid([2, 5, 29, 19]), DER.octetString(DER.sequence([]))]),
            // Extended key usage: TLS server.
            DER.sequence([DER.oid([2, 5, 29, 37]), DER.octetString(DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])]))]),
        ]))
        let algorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        var serial = Array(Secrets.randomBytes(16))
        serial[0] &= 0x7F
        let tbs = DER.sequence([
            DER.tlv(0xA0, DER.integer([2])),
            DER.integer(serial),
            algorithm,
            subject,
            DER.sequence([DER.utcTime(now.addingTimeInterval(-3600)), DER.utcTime(now.addingTimeInterval(validity))]),
            subject,
            Array(key.publicKey.derRepresentation),
            extensions,
        ])
        let signature = try key.signature(for: tbs)
        let certificate = DER.sequence([tbs, algorithm, DER.bitString(Array(signature.derRepresentation))])
        return Stored(private: key.pemRepresentation, cert: pem(certificate), timestamp: (now.timeIntervalSince1970 * 1000).rounded(), certVersion: version)
    }

    static func pem(_ der: [UInt8]) -> String {
        let base64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }
}

/// Distinguished Encoding Rules, the little a certificate needs (X.690).
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
