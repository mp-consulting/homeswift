import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import HomeswiftNetwork

/// A self-signed certificate for the TLS tests (CN=localhost, good for a century) and its key.
enum TestCertificate {
    static let certificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIICpjCCAY4CCQC4VGCS9PYQrjANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAls
        b2NhbGhvc3QwIBcNMjYxMDIyMDIzNjQ5WhgPMjEyNjA5MjgwMjM2NDlaMBQxEjAQ
        BgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
        AK1lr7Hwhc106tBgBdcKqWX3hTQwve4CbT998VzT73kpYOp1CBmLsjIrMeiODWso
        OdmisLDzs3IBNUFRxTJ5w4rlmSkj/MWkxY8NPlTPeplRQ15gWP5szVeyy226zR/5
        5MxEvm2qhuc0mG72UQP/wELOh2wCrzyySPR2/EKLo1bwS397KEk0Q42x/0yckl+D
        2EKr5rZb1S6BR6dtpAMdAtupanJF67Wf9dzszPwo4HFJS5a97dm5jIui5AmExIPP
        5pGXQQx1PrK2sW1366sqYH7WgS+M1cefUm6TPra8eenukCXJS1WoGIbpan1yat7Z
        NgGjJBIrfi80fl9DDGuDuNsCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAaJO3Tg+x
        rvdnZ5Dpjg9y60J1T1GS2w2hCDKvXNlN+4H7l+xW2u3PW/MLFMAjL5w8pLWakZ1y
        BVJsW4+4K5sb6RKq3SxGXurVD7sR42CPtpXqNm/eUF3McpK1F3jwSh86pkljz8X8
        Wz/kBgKntvs2EKeFabp4OG8fpTn4k6a7amhvhOcZO4tqbZ5WUkmejTTGDtcyBMM4
        QHEyabWVZ5UyzROirsmuA8q9lAQoVBuHb25KJUIInNlQw4rUXZlu15eQG+6NEZ6T
        cUS2Z0GoVkBUWrvxV02gNCj+uezNvtunAGnQY2UUuQckNP3Ba6m/oqmja23cjDuh
        0mzUwkRxOBcQCg==
        -----END CERTIFICATE-----
        """
    static let keyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCtZa+x8IXNdOrQ
        YAXXCqll94U0ML3uAm0/ffFc0+95KWDqdQgZi7IyKzHojg1rKDnZorCw87NyATVB
        UcUyecOK5ZkpI/zFpMWPDT5Uz3qZUUNeYFj+bM1Xssttus0f+eTMRL5tqobnNJhu
        9lED/8BCzodsAq88skj0dvxCi6NW8Et/eyhJNEONsf9MnJJfg9hCq+a2W9UugUen
        baQDHQLbqWpyReu1n/Xc7Mz8KOBxSUuWve3ZuYyLouQJhMSDz+aRl0EMdT6ytrFt
        d+urKmB+1oEvjNXHn1Jukz62vHnp7pAlyUtVqBiG6Wp9cmre2TYBoyQSK34vNH5f
        Qwxrg7jbAgMBAAECggEAaNr4DyOC1kaghJe8kFi7LZUrsO7Uu+wtwlpXranfw6YZ
        HE7fMgt/G8VxLc9RH/64VPqD3M3SMtu2J6TaGfb2H7VOFEnV3nMQoLwCeGjrG3G/
        yn968Yg7+I9/YwC2cGK+UCQ1/71CTOhKUbeUMFXlHsEjtVY+P/cUFPkq/NbSVIyG
        FezaXyYMwH8dbrlrgvyzrTDITkMSUtzfB448q/dRlX5491m3u3ki4Hhajk6rUoKr
        G56DM5NwVYA1OFo5ByIpB4xjb9ZSkavKw2UIac7k1FRTbjwRZbpmvuCISbTfIP3c
        7lVGxgclfJTVdOOYcWNFrDGOSVpbVoy/WanQxhmAeQKBgQDckNn+IPn6CL27l5G8
        Z+AY00vOTGxy6OlSx6svrx63V74QmIBjQnhB3G8/lyXnDud3UXFWa3WSsz3TcuiN
        5MWftm98yYI3HC50T/dupnhU4YWB8iW5lWa48ksoQUK05Sl4T4ewm8vHo+WkTpk0
        U8nFYemoDptVBJQbhN4b6obq5wKBgQDJQPHKlmZUTaeLXU17/TTYY59Wh2hjOMoX
        EYDPgqapH1fZiDVau+xX/NOMdcrMKNi9YeyQfhgGhp6M7ONZscwuAF9vfAIpbgqI
        RXf9ID5gNt3FvUsAGSjASVOY/8s4Oe6v2WTwCtUDZ9+enQQ2YBfMWoIxlk0tRoFr
        ZYAgA8KX7QKBgGfqwxoNNVlNFv80GRCYLCfmHTgUH6BABfXfZtLvgdxFtaGiCBM7
        9Oaq0as3Lj9fcURxFaHuvRUh58YgxFpd55Io5Pv5AKWwXF6mcmAqhFURb9JaYNXA
        Awat+ST9Ik2SDmjFp5tYu7jSilZQRbQ2qcCaMfjg8OQsZQ9WGUMzyt8PAoGATl++
        Sbi8bQQ4xSs2q5x14fcZ7CabXliVStqEIUut/5q3KX3D2WvppHJPKBoPOeaGUWo7
        KCIS1SfDwvnVp+53p0p53/6ZEO1LqLn0+lx+LhXv07vd41Ho7skfhyvGRkU5UL4G
        cvyk68id6zUWmN5fJjPxE8KGl6UnbV1/wff05hkCgYEA0stiGgzqAlrieswzI9mb
        3Gmce7FB/mebli409WKnbi4FKAfCSCQma6M+5VOutk1Ng7z4ylLDo+BcSeG2pG7m
        JnPbaIGR5/S4vFq14kNOy4xg76eMcjvkNi2Va63Wpity8Iebg5uIII8SIGaHC01U
        2/zyYR0F8KifnQN/U0nnBPc=
        -----END PRIVATE KEY-----
        """
    static let fingerprint = "c43472df954b9ec5cc883c84d8709a6c1a461cdfe607df1e40633c77af5b9a78"
}

/// What the test server saw of a request, sent back as JSON.
struct Seen: Codable, Equatable {
    var method: String
    var uri: String
    var headers: [String: String]
    var body: String
}

/// A small HTTP/1.1 server on NIO, plain or with the test certificate, that answers every request with what it
/// received, or with a canned response, or never (for the timeout test). The first `dropping` connections it
/// closes without an answer, as a server does with a connection it timed out.
final class TestServer: Sendable {
    enum Behaviour: Sendable { case echo, status(Int, body: String, headers: [(String, String)]), silent }
    /// When a dropped connection closes: as soon as it is accepted, or once the request was read.
    enum Drop: Sendable { case onAccept, afterRequest }
    struct Counts { var connections = 0, requests = 0 }

    let channel: any Channel
    let counts = NIOLockedValueBox(Counts())
    var port: Int { channel.localAddress!.port! }
    var connections: Int { counts.withLockedValue { $0.connections } }
    var requests: Int { counts.withLockedValue { $0.requests } }

    init(tls: Bool, behaviour: Behaviour, dropping: Int = 0, drop: Drop = .onAccept) async throws {
        var context: NIOSSLContext?
        if tls {
            let certificate = try NIOSSLCertificate(bytes: Array(TestCertificate.certificatePEM.utf8), format: .pem)
            let key = try NIOSSLPrivateKey(bytes: Array(TestCertificate.keyPEM.utf8), format: .pem)
            context = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)))
        }
        let counts = counts
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(behaviour: behaviour, counts: counts, dropping: dropping, drop: drop))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async { try? await channel.close().get() }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let behaviour: Behaviour
        let counts: NIOLockedValueBox<Counts>
        let dropping: Int
        let drop: Drop
        var dropped = false
        var head: HTTPRequestHead?
        var body = ""

        init(behaviour: Behaviour, counts: NIOLockedValueBox<Counts>, dropping: Int, drop: Drop) {
            self.behaviour = behaviour
            self.counts = counts
            self.dropping = dropping
            self.drop = drop
        }

        func channelActive(context: ChannelHandlerContext) {
            let connection = counts.withLockedValue { counts in
                counts.connections += 1
                return counts.connections
            }
            dropped = connection <= dropping
            if dropped, drop == .onAccept { return context.close(promise: nil) }
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): self.head = head
            case .body(var buffer): body += buffer.readString(length: buffer.readableBytes) ?? ""
            case .end:
                guard let head else { return }
                counts.withLockedValue { $0.requests += 1 }
                if dropped { return context.close(promise: nil) }
                switch behaviour {
                case .silent:
                    return
                case .echo:
                    var headers: [String: String] = [:]
                    for header in head.headers { headers[header.name.lowercased()] = header.value }
                    let seen = Seen(method: head.method.rawValue, uri: head.uri, headers: headers, body: body)
                    let data = try! JSONEncoder().encode(seen)
                    respond(context: context, status: 200, body: ByteBuffer(bytes: data), headers: [("Content-Type", "application/json")])
                case .status(let status, let body, let headers):
                    respond(context: context, status: status, body: ByteBuffer(string: body), headers: headers)
                }
            }
        }

        private func respond(context: ChannelHandlerContext, status: Int, body: ByteBuffer, headers: [(String, String)]) {
            var responseHead = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status))
            responseHead.headers.add(name: "Content-Length", value: String(body.readableBytes))
            for (name, value) in headers { responseHead.headers.add(name: name, value: value) }
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.close(promise: nil)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HTTPClientTests {
    @Test func sendsRequestsOverPlainHTTP() async throws {
        let server = try await TestServer(tls: false, behaviour: .echo)
        defer { Task { await server.stop() } }
        let client = HTTPClient()
        var request = HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:\(server.port)/6/powerstate?x=1")!, body: Data(#"{"powerstate":"On"}"#.utf8))
        request.setHeader("Content-Type", "application/json")
        request.setHeader("content-type", "application/json; charset=utf-8")
        let response = try await client.send(request)
        #expect(response.status == 200 && response.isSuccess)
        #expect(response.header("content-type") == "application/json")
        #expect(response.certificateFingerprint == nil)
        let seen = try JSONDecoder().decode(Seen.self, from: response.body)
        #expect(seen.method == "POST" && seen.uri == "/6/powerstate?x=1" && seen.body == #"{"powerstate":"On"}"#)
        #expect(seen.headers["content-type"] == "application/json; charset=utf-8")
        #expect(seen.headers["content-length"] == "19")
        #expect(seen.headers["host"] == "127.0.0.1:\(server.port)")
        #expect(seen.headers["connection"] == "close")
    }

    @Test func aTimeoutBeyondNIOsRangeIsClamped() async throws {
        let server = try await TestServer(tls: false, behaviour: .echo)
        defer { Task { await server.stop() } }
        // More nanoseconds than Int64 holds, as a timeout from a configuration may be.
        let response = try await HTTPClient().send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: .seconds(Int64.max)))
        #expect(response.status == 200)
    }

    @Test func requestsThePathAsItIsEncoded() async throws {
        let server = try await TestServer(tls: false, behaviour: .echo)
        defer { Task { await server.stop() } }
        let response = try await HTTPClient().send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/a%20b/c%2Fd?q=%2F")!))
        #expect(try JSONDecoder().decode(Seen.self, from: response.body).uri == "/a%20b/c%2Fd?q=%2F")
    }

    @Test func retriesOnceOnAFreshConnectionWhenTheServerDropsOneUnanswered() async throws {
        // Closed as soon as accepted: whether or not the request went out, a GET may go again.
        let accepted = try await TestServer(tls: false, behaviour: .echo, dropping: 1)
        defer { Task { await accepted.stop() } }
        let get = try await HTTPClient().send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(accepted.port)/state")!))
        #expect(get.status == 200 && accepted.connections == 2)

        // Closed once the request was read: a GET goes again, a POST does not (the server may have acted on it).
        let read = try await TestServer(tls: false, behaviour: .echo, dropping: 1, drop: .afterRequest)
        defer { Task { await read.stop() } }
        let again = try await HTTPClient().send(HTTPRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(read.port)/state")!, body: Data("on".utf8)))
        #expect(again.status == 200 && read.requests == 2)
        let once = try await TestServer(tls: false, behaviour: .echo, dropping: 1, drop: .afterRequest)
        defer { Task { await once.stop() } }
        await #expect(throws: HTTPClientError.connectionClosed) {
            try await HTTPClient().send(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:\(once.port)/unlock")!, body: Data("{}".utf8)))
        }
        #expect(once.requests == 1 && once.connections == 1)

        // Over TLS a connection closed during the handshake never carried the request: a POST goes again too.
        let handshake = try await TestServer(tls: true, behaviour: .echo, dropping: 1)
        defer { Task { await handshake.stop() } }
        let post = try await HTTPClient(tls: .any).send(HTTPRequest(method: "POST", url: URL(string: "https://127.0.0.1:\(handshake.port)/unlock")!))
        #expect(post.status == 200 && handshake.connections == 2 && handshake.requests == 1)

        // Only once: a server that drops every connection fails the request after two.
        let always = try await TestServer(tls: false, behaviour: .echo, dropping: .max, drop: .afterRequest)
        defer { Task { await always.stop() } }
        await #expect(throws: HTTPClientError.connectionClosed) {
            try await HTTPClient().send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(always.port)/state")!))
        }
        #expect(always.connections == 2)
    }

    @Test func reportsStatusesTimeoutsAndBadURLs() async throws {
        let server = try await TestServer(tls: false, behaviour: .status(401, body: "", headers: [("WWW-Authenticate", "Digest realm=\"XTV\", nonce=\"abc\", qop=\"auth\"")]))
        defer { Task { await server.stop() } }
        let client = HTTPClient()
        let response = try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/x")!))
        #expect(response.status == 401 && !response.isSuccess)
        #expect(response.header("www-authenticate")?.hasPrefix("Digest") == true)

        let silent = try await TestServer(tls: false, behaviour: .silent)
        defer { Task { await silent.stop() } }
        await #expect(throws: HTTPClientError.timeout) {
            try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(silent.port)/")!, timeout: .milliseconds(300)))
        }
        await #expect(throws: HTTPClientError.invalidURL("ftp://x/")) { try await client.send(HTTPRequest(url: URL(string: "ftp://x/")!)) }
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:1/")!, timeout: .seconds(2)))
            Issue.record("port 1 answered")
        } catch let error as HTTPClientError {
            guard case .cannotConnect(let host, let port, let code, let reason) = error else { throw error }
            #expect(host == "127.0.0.1" && port == 1 && code == ECONNREFUSED && reason == "connection refused")
        }
    }

    @Test func trustsAndPinsSelfSignedCertificates() async throws {
        let server = try await TestServer(tls: true, behaviour: .echo)
        defer { Task { await server.stop() } }
        let url = URL(string: "https://127.0.0.1:\(server.port)/6/system")!

        await #expect(throws: (any Error).self) { try await HTTPClient(tls: .system).send(HTTPRequest(url: url)) }

        let any = try await HTTPClient(tls: .any).send(HTTPRequest(url: url))
        #expect(any.status == 200)
        #expect(any.certificateFingerprint == TestCertificate.fingerprint)

        let pinned = try await HTTPClient(tls: .pinned(TestCertificate.fingerprint.uppercased())).send(HTTPRequest(url: url))
        #expect(pinned.status == 200 && pinned.certificateFingerprint == TestCertificate.fingerprint)

        let other = String(repeating: "00", count: 32)
        await #expect(throws: HTTPClientError.certificateMismatch(expected: other, observed: TestCertificate.fingerprint)) {
            try await HTTPClient(tls: .pinned(other)).send(HTTPRequest(url: url))
        }
    }

    @Test func offersTheCipherSuitesItIsGiven() async throws {
        let server = try await TestServer(tls: true, behaviour: .echo)
        defer { Task { await server.stop() } }
        let url = URL(string: "https://127.0.0.1:\(server.port)/")!
        // OpenSSL's DEFAULT list (Node's `ciphers: "DEFAULT"`), and one named suite.
        #expect(try await HTTPClient(tls: .any, cipherSuites: "DEFAULT").send(HTTPRequest(url: url)).status == 200)
        #expect(try await HTTPClient(tls: .any, cipherSuites: "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256").send(HTTPRequest(url: url)).status == 200)
        // A list that leaves no suite fails the requests (NIOSSL would stop the process on it).
        await #expect(throws: TLSCipherListError(list: "NO-SUCH-CIPHER")) {
            try await HTTPClient(tls: .any, cipherSuites: "NO-SUCH-CIPHER").send(HTTPRequest(url: url))
        }
        #expect(throws: TLSCipherListError(list: "ALL:!ALL")) { try TLSOptions(cipherSuites: "ALL:!ALL").makeContext() }
        #expect(TLSOptions(cipherSuites: "DEFAULT") != TLSOptions())
        _ = try TLSOptions(trust: .any, cipherSuites: "DEFAULT").makeContext()
    }

    @Test func tellsUsableCipherListsAsBoringSSLDoes() throws {
        let lists = [
            "DEFAULT", "ALL", "HIGH", "ECDHE-RSA-AES128-GCM-SHA256", "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", "ECDHE+AESGCM:!aPSK",
            "DEFAULT:!3DES", "kRSA+AES256", "3DES", "DES-CBC3-SHA", "-ALL:AES", "AES:@STRENGTH", "UNKNOWN:AES128", "ECDHE-RSA-AES128-SHA256",
            "NO-SUCH-CIPHER", "ALL:!ALL", "SHA256", "TLS_AES_128_GCM_SHA256", "!AES:AES", "AES:@SECLEVEL=2", "[AES|CHACHA20]", "-AES",
        ]
        // A context builds for every list judged usable (the others would stop the process in NIOSSL); equal-preference
        // groups are refused, though BoringSSL reads them.
        for list in lists {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.cipherSuites = list
            let usable = TLSCipherList.isUsable(list)
            #expect(usable == ["DEFAULT", "ALL", "HIGH", "ECDHE-RSA-AES128-GCM-SHA256", "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
                               "ECDHE+AESGCM:!aPSK", "DEFAULT:!3DES", "kRSA+AES256", "3DES", "DES-CBC3-SHA", "-ALL:AES", "AES:@STRENGTH",
                               "UNKNOWN:AES128", "ECDHE-RSA-AES128-SHA256"].contains(list), "\(list)")
            if usable { _ = try NIOSSLContext(configuration: configuration) }
        }
    }
}

@Suite struct DigestTests {
    @Test func matchesTheRFC2617Example() {
        var digest = DigestAuthentication(username: "Mufasa", password: "Circle Of Life")
        #expect(digest.authorization(method: "GET", uri: "/dir/index.html") == nil)
        let accepted = digest.accept(challenge: "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"")
        #expect(accepted)
        let header = digest.authorization(method: "GET", uri: "/dir/index.html", cnonce: "0a4f113b")
        #expect(header == "Digest username=\"Mufasa\", realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", uri=\"/dir/index.html\", response=\"6629fae49393a05397450978507c4ef1\", qop=auth, nc=00000001, cnonce=\"0a4f113b\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"")
        #expect(digest.authorization(method: "GET", uri: "/dir/index.html", cnonce: "0a4f113b")?.contains("nc=00000002") == true)
        digest.clear()
        #expect(!digest.hasChallenge)
        let basic = digest.accept(challenge: "Basic realm=\"x\"")
        #expect(!basic)
        #expect(DigestAuthentication.Challenge(header: "Digest realm=x, nonce=") == nil)
        #expect(DigestAuthentication.Challenge(header: "digest realm=XTV,nonce=abc,algorithm=MD5") == .init(realm: "XTV", nonce: "abc", qop: nil, opaque: nil, algorithm: "MD5"))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WakeOnLANTests {
    @Test func buildsMagicPackets() {
        #expect(WakeOnLAN.hexDigits(mac: "AA:bb-cc.dd ee ff") == "aabbccddeeff")
        #expect(WakeOnLAN.hexDigits(mac: "aabbccddee") == nil)
        let packet = try! #require(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:AB"))
        #expect(packet.count == 102)
        #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        #expect(packet[6..<12] == Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB]))
        #expect(packet.suffix(6) == Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB]))
        #expect(WakeOnLAN.magicPacket(mac: "nope") == nil)
        #expect(WakeOnLAN.ipv4("192.168.1.20") == 0xC0A8_0114)
        #expect(WakeOnLAN.dotted(0xC0A8_01FF) == "192.168.1.255")
        #expect(WakeOnLAN.broadcastAddress(for: "127.0.0.1") == "127.255.255.255")
        #expect(WakeOnLAN.broadcastAddress(for: "203.0.113.9") == nil)
    }

    @Test func sendsBurstsOverUDP() async throws {
        final class Collector: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            let received = NIOLockedValueBoxCompat<[Data]>([])
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data).data
                received.withLockedValue { $0.append(Data(buffer.readBytes(length: buffer.readableBytes) ?? [])) }
            }
        }
        let collector = Collector()
        let listener = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) } }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { Task { try? await listener.close().get() } }
        let port = listener.localAddress!.port!
        try await WakeOnLAN.wake(mac: "01:23:45:67:89:AB", addresses: ["127.0.0.1"], port: port, bursts: 2, packetsPerBurst: 3, interval: .milliseconds(20))
        let deadline = ContinuousClock.now + .seconds(3)
        while collector.received.withLockedValue({ $0.count }) < 6, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let packets = collector.received.withLockedValue { $0 }
        #expect(packets.count == 6)
        #expect(packets.allSatisfy { $0 == WakeOnLAN.magicPacket(mac: "01:23:45:67:89:AB") })
        await #expect(throws: WakeOnLANError.invalidMAC("x")) { try await WakeOnLAN.wake(mac: "x", addresses: ["127.0.0.1"], port: port) }
    }
}

/// A lock-protected value for the test collector (NIOConcurrencyHelpers is not a dependency of this target).
final class NIOLockedValueBoxCompat<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLockedValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@Suite struct ARPTableTests {
    @Test func readsMacOSOutput() {
        let output = "? (192.168.1.20) at 0:11:22:aa:b:c on en0 ifscope [ethernet]\n"
        #expect(ARPTable.darwinEntry(in: output, ip: "192.168.1.20") == "00:11:22:AA:0B:0C")
        #expect(ARPTable.darwinEntry(in: output, ip: "192.168.1.2") == nil)
        #expect(ARPTable.darwinEntry(in: "? (192.168.1.20) at (incomplete) on en0 ifscope [ethernet]", ip: "192.168.1.20") == nil)
        #expect(ARPTable.darwinEntry(in: "192.168.1.20 (192.168.1.20) -- no entry", ip: "192.168.1.20") == nil)
    }

    @Test func readsProcNetARP() {
        let table = """
            IP address       HW type     Flags       HW address            Mask     Device
            192.168.1.2      0x1         0x0         00:00:00:00:00:00     *        eth0
            192.168.1.20     0x1         0x2         AA:BB:CC:DD:EE:FF     *        eth0
            """
        #expect(ARPTable.linuxEntry(in: table, ip: "192.168.1.20") == "AA:BB:CC:DD:EE:FF")
        #expect(ARPTable.linuxEntry(in: table, ip: "192.168.1.2") == nil)
    }

    @Test func ignoresWhatIsNotAnIPv4Address() async {
        #expect(await ARPTable.macAddress(for: "-a") == nil)
    }
}
