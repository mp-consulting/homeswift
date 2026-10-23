import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

/// How a WebSocket or MQTT client sets up TLS: whom it trusts, the certificate it presents, ALPN.
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

    /// The context built from these options, reused while they stay the same (one per client, not per connection).
    private let contextCache = ContextCache()

    public static func == (lhs: TLSOptions, rhs: TLSOptions) -> Bool {
        lhs.contextKey == rhs.contextKey && lhs.serverName == rhs.serverName
    }

    public init(trust: Trust = .system, clientIdentity: ClientIdentity? = nil, alpn: [String] = [], serverName: String? = nil) {
        self.trust = trust
        self.clientIdentity = clientIdentity
        self.alpn = alpn
        self.serverName = serverName
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
    }

    private var contextKey: ContextKey { ContextKey(trust: trust, clientIdentity: clientIdentity, alpn: alpn) }

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
