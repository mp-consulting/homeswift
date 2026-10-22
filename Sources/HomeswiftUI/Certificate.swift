import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOSSL

/// The web UI's identity for HTTPS: the certificate and key the HomeswiftUI block names, or a self-signed
/// certificate the bridge makes once and keeps next to config.json. Browsers only let a page use the
/// microphone over HTTPS (or on localhost), so voice in the Assistant's chat needs it on the network.
///
/// The self-signed certificate names this machine (its host name, `.local` name, `localhost`, the block's
/// `allowedHosts`) and its LAN addresses, lasts 397 days (Apple's limit for a server certificate) and is
/// marked as a CA, so an iPhone can trust it once installed. It is made again when it is about to expire or
/// when the names or addresses change.
struct UICertificate: Sendable {
    /// The certificate served, then the rest of its chain (the intermediates of a CA-issued one).
    let chainDER: [Data]
    let keyPEM: String

    init(chainDER: [Data], keyPEM: String) {
        self.chainDER = chainDER
        self.keyPEM = keyPEM
    }

    init(certificateDER: Data, keyPEM: String) {
        self.init(chainDER: [certificateDER], keyPEM: keyPEM)
    }

    var certificateDER: Data { chainDER[0] }

    /// The SHA-256 of the certificate, as browsers show it: `AB:CD:…`.
    var fingerprint: String {
        let hex = HTTPClient.fingerprint(der: Array(certificateDER)).uppercased()
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            String(hex[hex.index(hex.startIndex, offsetBy: offset)...].prefix(2))
        }.joined(separator: ":")
    }

    var certificatePEM: String {
        let base64 = certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    func sslContext() throws -> NIOSSLContext {
        let chain = try chainDER.map { try NIOSSLCertificate(bytes: Array($0), format: .der) }
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        return try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: chain.map { .certificate($0) }, privateKey: .privateKey(key)))
    }

    static let certificateFile = "ui-certificate.pem"
    static let keyFile = "ui-key.pem"
    static let namesFile = "ui-certificate.json"

    /// The block's files when it names them, else the generated certificate in `directory`, made or made
    /// again as needed.
    static func load(configuration: UIConfiguration, directory: URL, names: [String], logger: Logger) throws -> UICertificate {
        if let certificatePath = configuration.certificate, let keyPath = configuration.privateKey {
            // Every certificate of the file: a fullchain.pem has the intermediates browsers need too.
            let pem = try String(contentsOfFile: expand(certificatePath), encoding: .utf8)
            let chain = try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8)).map { Data(try $0.toDERBytes()) }
            guard !chain.isEmpty else { throw UIConfigurationError.invalid(key: "certificate", expected: "a PEM certificate file") }
            return UICertificate(chainDER: chain, keyPEM: try String(contentsOfFile: expand(keyPath), encoding: .utf8))
        }
        // Loopback and link-local (169.254.x) addresses reach nobody.
        let addresses = NetworkInterfaces.ipv4().map(\.address).filter { $0 >> 24 != 127 && $0 >> 16 != 0xA9FE }
        let wanted = Set(names + addresses.map(WakeOnLAN.dotted))
        let certificateURL = directory.appendingPathComponent(certificateFile)
        let keyURL = directory.appendingPathComponent(keyFile)
        let namesURL = directory.appendingPathComponent(namesFile)
        // Kept while it names everything this machine is reached by now: an address that went away (a VPN
        // that disconnected) does not cost the trust a phone or a computer gave it.
        if let stored = try? JSONValue(data: Data(contentsOf: namesURL)),
           Set(stored["names"]?.arrayValue?.compactMap(\.stringValue) ?? []).isSuperset(of: wanted),
           let notAfter = stored["notAfter"]?.doubleValue, Date(timeIntervalSince1970: notAfter).timeIntervalSinceNow > 30 * 86_400,
           let pem = try? String(contentsOf: certificateURL, encoding: .utf8), let key = try? String(contentsOf: keyURL, encoding: .utf8),
           let der = try? NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem).toDERBytes() {
            return UICertificate(certificateDER: Data(der), keyPEM: key)
        }
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let notAfter = now.addingTimeInterval(397 * 86_400)
        let made = UICertificate(certificateDER: try selfSigned(key: key, names: names, addresses: addresses, notBefore: now.addingTimeInterval(-86_400), notAfter: notAfter), keyPEM: key.pemRepresentation)
        try OwnerOnlyFile.write(Data(made.keyPEM.utf8), to: keyURL)
        try OwnerOnlyFile.write(Data(made.certificatePEM.utf8), to: certificateURL)
        let record: JSONValue = ["names": .array(wanted.sorted().map(JSONValue.string)), "notAfter": .number(notAfter.timeIntervalSince1970)]
        try OwnerOnlyFile.write(record.encoded(pretty: true), to: namesURL)
        logger.info("Web UI: made a self-signed certificate for HTTPS", metadata: ["names": "\(wanted.sorted().joined(separator: ", "))", "sha256": "\(made.fingerprint)"])
        return made
    }

    private static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    // MARK: A self-signed certificate (RFC 5280), DER by hand

    static func selfSigned(key: P256.Signing.PrivateKey, names: [String], addresses: [UInt32], notBefore: Date, notAfter: Date) throws -> Data {
        let ecdsaWithSHA256 = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8("Homeswift \(names.first ?? "bridge")")])]),
            DER.set([DER.sequence([DER.oid([2, 5, 4, 10]), DER.utf8("Homeswift")])]),
        ])
        var serial = Array(Secrets.randomBytes(16))
        serial[0] &= 0x7F   // positive
        let alternativeNames = names.map { DER.tagged(0x82, Data($0.utf8)) }
            + addresses.map { DER.tagged(0x87, withUnsafeBytes(of: $0.bigEndian) { Data($0) }) }
        let extensions = DER.sequence([
            // A CA, so a phone lists it under its trusted certificates once installed.
            DER.extensionValue([2, 5, 29, 19], critical: true, DER.sequence([DER.boolean(true)])),
            // digitalSignature and keyCertSign.
            DER.extensionValue([2, 5, 29, 15], critical: true, DER.tagged(0x03, Data([0x02, 0x84]))),
            // serverAuth.
            DER.extensionValue([2, 5, 29, 37], critical: false, DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
            DER.extensionValue([2, 5, 29, 17], critical: false, DER.sequence(alternativeNames)),
        ])
        let spki = key.publicKey.derRepresentation
        let tbs = DER.sequence([
            DER.tagged(0xA0, DER.integer([2])),
            DER.integer(serial),
            ecdsaWithSHA256,
            name,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            spki,
            DER.tagged(0xA3, extensions),
        ])
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence([tbs, ecdsaWithSHA256, DER.tagged(0x03, Data([0]) + signature)])
    }
}

/// The few DER encodings a certificate needs (X.690).
enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ parts: [Data]) -> Data { tagged(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { tagged(0x31, parts.reduce(Data(), +)) }
    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0x00])) }
    static func utf8(_ text: String) -> Data { tagged(0x0C, Data(text.utf8)) }

    /// A non-negative INTEGER from big-endian bytes: no superfluous leading zero, one added when the top bit is set.
    static func integer(_ bytes: [UInt8]) -> Data {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tagged(0x02, Data(value))
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var out = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            out.append(contentsOf: chunk)
        }
        return tagged(0x06, out)
    }

    /// UTCTime until 2049, GeneralizedTime after (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year! < 2050
        formatter.dateFormat = utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tagged(utc ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }

    static func extensionValue(_ oid: [UInt], critical: Bool, _ value: Data) -> Data {
        sequence([DER.oid(oid)] + (critical ? [boolean(true)] : []) + [tagged(0x04, value)])
    }
}
