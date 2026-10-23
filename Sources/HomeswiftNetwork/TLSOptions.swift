import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

/// How a WebSocket or MQTT client sets up TLS: whom it trusts, the certificate it presents, ALPN, the cipher suites.
///
/// The trust modes are `HTTPClient.TLS`'s, plus a bundled root (`.roots`) for clouds such as AWS IoT whose
/// certificate a plugin ships the CA of. A client certificate (`clientIdentity`) is for mutual TLS: AWS IoT
/// with a device certificate in PEM (LG ThinQ) or PKCS#12 (Govee).
public struct TLSOptions: Sendable, Equatable {
    public enum Trust: Sendable, Equatable {
        /// Verify the server's certificate against the system's trusted roots and its host name.
        case system
        /// Accept any certificate (a device's self-signed one), and record its fingerprint.
        case any
        /// Accept only the certificate with this SHA-256 fingerprint, in any spelling (`aa:bb:…` or hex).
        case pinned(String)
        /// Verify against these PEM roots (one or more certificates) instead of the system's, host name included.
        case roots(pem: String)

        /// Amazon Root CA 1, which AWS IoT's `*-ats.iot.*.amazonaws.com` endpoints chain to. Expires 2038-01-17.
        public static let amazonRootCA1 = Trust.roots(pem: amazonRootCA1PEM)

        /// Amazon Root CA 1 in PEM (Amazon Trust Services' `AmazonRootCA1.pem`).
        public static let amazonRootCA1PEM = """
            -----BEGIN CERTIFICATE-----
            MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF
            ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
            b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL
            MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
            b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj
            ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM
            9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw
            IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6
            VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L
            93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm
            jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
            AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA
            A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI
            U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs
            N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv
            o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU
            5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy
            rqXRfboQnoZsG4q5WTP468SQvvG5
            -----END CERTIFICATE-----
            """
    }

    public enum ClientIdentity: Sendable, Equatable {
        /// A certificate (or a chain, leaf first) and its private key, both PEM.
        case pem(certificate: String, privateKey: String)
        /// A PKCS#12 (`.p12`, `.pfx`) bundle and its passphrase.
        case pkcs12(Data, passphrase: String?)
    }

    public var trust: Trust
    public var clientIdentity: ClientIdentity?
    /// ALPN protocols to offer, e.g. `["x-amzn-mqtt-ca"]` for AWS IoT MQTT with a client certificate on port 443.
    public var alpn: [String]
    /// The name sent as SNI and checked against the certificate, when it is not the host connected to.
    public var serverName: String?
    /// The TLS 1.2 cipher suites offered, as an OpenSSL cipher list (`"DEFAULT"`); nil for NIOSSL's own. See
    /// `HTTPClient.cipherSuites`.
    public var cipherSuites: String?

    /// The context built from these options, reused while they stay the same (one per client, not per connection).
    private let contextCache = ContextCache()

    public static func == (lhs: TLSOptions, rhs: TLSOptions) -> Bool {
        lhs.contextKey == rhs.contextKey && lhs.serverName == rhs.serverName
    }

    public init(
        trust: Trust = .system, clientIdentity: ClientIdentity? = nil, alpn: [String] = [], serverName: String? = nil, cipherSuites: String? = nil
    ) {
        self.trust = trust
        self.clientIdentity = clientIdentity
        self.alpn = alpn
        self.serverName = serverName
        self.cipherSuites = cipherSuites
    }

    /// The same trust as an `HTTPClient` with this mode.
    public init(_ tls: HTTPClient.TLS) {
        switch tls {
        case .system: self.init(trust: .system)
        case .any: self.init(trust: .any)
        case .pinned(let fingerprint): self.init(trust: .pinned(fingerprint))
        }
    }

    public static let system = TLSOptions()

    /// What the context depends on.
    private struct ContextKey: Equatable {
        var trust: Trust
        var clientIdentity: ClientIdentity?
        var alpn: [String]
        var cipherSuites: String?
    }

    private var contextKey: ContextKey { ContextKey(trust: trust, clientIdentity: clientIdentity, alpn: alpn, cipherSuites: cipherSuites) }

    private final class ContextCache: Sendable {
        let entry = NIOLockedValueBox<(key: ContextKey, context: NIOSSLContext)?>(nil)
    }

    /// The context for these options: built once, again only after a field it depends on changed.
    func makeContext() throws -> NIOSSLContext {
        let key = contextKey
        return try contextCache.entry.withLockedValue { entry in
            if let entry, entry.key == key { return entry.context }
            let context = try buildContext()
            entry = (key, context)
            return context
        }
    }

    private func buildContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch trust {
        case .system:
            break
        case .any, .pinned:
            // The callback decides; nothing a self-signed certificate lacks should fail the handshake first.
            configuration.certificateVerification = .noHostnameVerification
        case .roots(let pem):
            configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8)))
        }
        switch clientIdentity {
        case nil:
            break
        case .pem(let certificate, let privateKey):
            configuration.certificateChain = try NIOSSLCertificate.fromPEMBytes(Array(certificate.utf8)).map { .certificate($0) }
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey.utf8), format: .pem))
        case .pkcs12(let data, let passphrase):
            let bundle = try NIOSSLPKCS12Bundle(buffer: Array(data), passphrase: passphrase.map { Array($0.utf8) })
            configuration.certificateChain = bundle.certificateChain.map { .certificate($0) }
            configuration.privateKey = .privateKey(bundle.privateKey)
        }
        if !alpn.isEmpty { configuration.applicationProtocols = alpn }
        if let cipherSuites {
            guard TLSCipherList.isUsable(cipherSuites) else { throw TLSCipherListError(list: cipherSuites) }
            configuration.cipherSuites = cipherSuites
        }
        return try NIOSSLContext(configuration: configuration)
    }

    /// A client handler for `host`. `observed` receives the server certificate's fingerprint for `.any` and
    /// `.pinned`; a pinned mismatch is stored in `mismatch` and fails the handshake.
    func makeHandler(
        context: NIOSSLContext, host: String, observed: NIOLockedValueBox<String?>, mismatch: NIOLockedValueBox<(any Error)?>
    ) throws -> NIOSSLClientHandler {
        let name = serverName ?? host
        // SNI carries host names only; a device is often reached by its address.
        let serverHostname = name.contains(":") || name.allSatisfy({ $0.isNumber || $0 == "." }) ? nil : name
        switch trust {
        case .system, .roots:
            return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
        case .any, .pinned:
            let trust = trust
            return try NIOSSLClientHandler(context: context, serverHostname: serverHostname) { certificates, promise in
                guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                    promise.succeed(.failed)
                    return
                }
                let fingerprint = HTTPClient.fingerprint(der: der)
                observed.withLockedValue { $0 = fingerprint }
                if case .pinned(let expected) = trust, HTTPClient.normalizeFingerprint(expected) != fingerprint {
                    mismatch.withLockedValue {
                        $0 = HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(expected), observed: fingerprint)
                    }
                    promise.succeed(.failed)
                    return
                }
                promise.succeed(.certificateVerified)
            }
        }
    }
}

/// A cipher list BoringSSL would refuse: NIOSSL stops the process on one (a precondition), so the clients check
/// first and throw this instead.
public struct TLSCipherListError: Error, CustomStringConvertible, Equatable, Sendable {
    public var list: String
    public var description: String { "no TLS cipher suite matches the cipher list \"\(list)\"" }
}

/// OpenSSL cipher lists as BoringSSL reads them (`ssl_create_cipher_list`, not strict): which TLS 1.2 suites a
/// list leaves, to tell a usable list from one NIOSSL would stop the process on.
public enum TLSCipherList {
    /// Whether BoringSSL accepts the list: no unknown command, and at least one suite left. Unknown names are
    /// skipped, as BoringSSL does; equal-preference groups (`[A|B]`) are refused, to be safe.
    public static func isUsable(_ list: String) -> Bool {
        guard !list.contains(where: { "[]|".contains($0) }) else { return false }
        var rules = Substring(list)
        var active: [Int] = []
        var killed: Set<Int> = []
        // DEFAULT is read only at the start, as BoringSSL's ALL.
        if rules.hasPrefix("DEFAULT") {
            active = suites.indices.filter { !suites[$0].deprecated }
            rules = rules.dropFirst(7)
        }
        for rule in rules.split(whereSeparator: { ":, ;".contains($0) }) {
            var rule = rule
            let operation = rule.first.flatMap { "!-+".contains($0) ? $0 : nil }
            if operation != nil { rule = rule.dropFirst() }
            if rule.hasPrefix("@") {
                guard rule == "@STRENGTH" else { return false }
                continue
            }
            let terms = rule.split(separator: "+").map(String.init)
            if terms.isEmpty { continue }
            // A suite named outright is the only match, deprecated or not; aliases leave deprecated suites out
            // unless they name them (3DES).
            let named = terms.count == 1 ? suites.indices.first { suites[$0].names.contains(terms[0]) } : nil
            let matches: [Int]
            if let named {
                matches = [named]
            } else if terms.allSatisfy({ aliases.contains($0) }) {
                matches = suites.indices.filter { index in
                    terms.allSatisfy { suites[index].tags.contains($0) } && (!suites[index].deprecated || terms.contains("3DES"))
                }
            } else {
                continue
            }
            switch operation {
            case "!":
                killed.formUnion(matches)
                active.removeAll { matches.contains($0) }
            case "-":
                active.removeAll { matches.contains($0) }
            case "+":
                break
            default:
                for index in matches where !killed.contains(index) && !active.contains(index) { active.append(index) }
            }
        }
        return !active.isEmpty
    }

    private static let aliases: Set<String> = [
        "ALL", "kRSA", "kECDHE", "kEECDH", "ECDH", "kPSK", "aRSA", "aECDSA", "ECDSA", "aPSK", "ECDHE", "EECDH", "RSA", "PSK",
        "3DES", "AES128", "AES256", "AES", "AESGCM", "CHACHA20", "SHA1", "SHA", "SSLv3", "TLSv1", "TLSv1.2", "HIGH", "FIPS", "SHA256", "SHA384",
    ]

    /// BoringSSL's TLS 1.2 suites (TLS 1.3's cannot be configured): their OpenSSL and standard names and the aliases
    /// that match them.
    private static let suites: [(names: [String], tags: Set<String>, deprecated: Bool)] = {
        func suite(_ name: String, _ standard: String, _ tags: [String], version: String = "SSLv3", deprecated: Bool = false)
            -> (names: [String], tags: Set<String>, deprecated: Bool)
        {
            var all = Set(tags + ["ALL", "HIGH", "FIPS", version])
            if version == "SSLv3" { all.insert("TLSv1") }
            if all.contains("kRSA") { all.formUnion(["RSA"]) }
            if all.contains("kECDHE") { all.formUnion(["ECDHE", "EECDH", "kEECDH", "ECDH"]) }
            if all.contains("aECDSA") { all.insert("ECDSA") }
            if all.contains("kPSK") { all.insert("PSK") }
            if all.contains("SHA1") { all.insert("SHA") }
            if all.contains("AES128") || all.contains("AES256") { all.insert("AES") }
            return ([name, standard], all, deprecated)
        }
        return [
            suite("DES-CBC3-SHA", "TLS_RSA_WITH_3DES_EDE_CBC_SHA", ["kRSA", "aRSA", "3DES", "SHA1"], deprecated: true),
            suite("AES128-SHA", "TLS_RSA_WITH_AES_128_CBC_SHA", ["kRSA", "aRSA", "AES128", "SHA1"]),
            suite("AES256-SHA", "TLS_RSA_WITH_AES_256_CBC_SHA", ["kRSA", "aRSA", "AES256", "SHA1"]),
            suite("PSK-AES128-CBC-SHA", "TLS_PSK_WITH_AES_128_CBC_SHA", ["kPSK", "aPSK", "AES128", "SHA1"]),
            suite("PSK-AES256-CBC-SHA", "TLS_PSK_WITH_AES_256_CBC_SHA", ["kPSK", "aPSK", "AES256", "SHA1"]),
            suite("AES128-GCM-SHA256", "TLS_RSA_WITH_AES_128_GCM_SHA256", ["kRSA", "aRSA", "AES128", "AESGCM"], version: "TLSv1.2"),
            suite("AES256-GCM-SHA384", "TLS_RSA_WITH_AES_256_GCM_SHA384", ["kRSA", "aRSA", "AES256", "AESGCM"], version: "TLSv1.2"),
            suite("ECDHE-ECDSA-AES128-SHA", "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA", ["kECDHE", "aECDSA", "AES128", "SHA1"]),
            suite("ECDHE-ECDSA-AES256-SHA", "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA", ["kECDHE", "aECDSA", "AES256", "SHA1"]),
            suite("ECDHE-RSA-AES128-SHA", "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA", ["kECDHE", "aRSA", "AES128", "SHA1"]),
            suite("ECDHE-RSA-AES256-SHA", "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA", ["kECDHE", "aRSA", "AES256", "SHA1"]),
            suite("ECDHE-RSA-AES128-SHA256", "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256", ["kECDHE", "aRSA", "AES128"], version: "TLSv1.2", deprecated: true),
            suite("ECDHE-ECDSA-AES128-GCM-SHA256", "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", ["kECDHE", "aECDSA", "AES128", "AESGCM"], version: "TLSv1.2"),
            suite("ECDHE-ECDSA-AES256-GCM-SHA384", "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384", ["kECDHE", "aECDSA", "AES256", "AESGCM"], version: "TLSv1.2"),
            suite("ECDHE-RSA-AES128-GCM-SHA256", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", ["kECDHE", "aRSA", "AES128", "AESGCM"], version: "TLSv1.2"),
            suite("ECDHE-RSA-AES256-GCM-SHA384", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", ["kECDHE", "aRSA", "AES256", "AESGCM"], version: "TLSv1.2"),
            suite("ECDHE-PSK-AES128-CBC-SHA", "TLS_ECDHE_PSK_WITH_AES_128_CBC_SHA", ["kECDHE", "aPSK", "AES128", "SHA1"]),
            suite("ECDHE-PSK-AES256-CBC-SHA", "TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA", ["kECDHE", "aPSK", "AES256", "SHA1"]),
            suite("ECDHE-RSA-CHACHA20-POLY1305", "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256", ["kECDHE", "aRSA", "CHACHA20"], version: "TLSv1.2"),
            suite("ECDHE-ECDSA-CHACHA20-POLY1305", "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256", ["kECDHE", "aECDSA", "CHACHA20"], version: "TLSv1.2"),
            suite("ECDHE-PSK-CHACHA20-POLY1305", "TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256", ["kECDHE", "aPSK", "CHACHA20"], version: "TLSv1.2"),
        ]
    }()
}
