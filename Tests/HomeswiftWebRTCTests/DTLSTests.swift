import Crypto
import Foundation
import HomeswiftNetwork
import Testing
#if canImport(Glibc)
import Glibc
#endif

@testable import HomeswiftWebRTC

/// The pieces against published vectors and OpenSSL's own tools.
@Suite(.timeLimit(.minutes(1))) struct DTLSPrimitiveTests {
    /// The TLS 1.2 PRF with SHA-256 vector from the IETF TLS list, as ell's unit/test-tls.c carries it
    /// (`tls12_prf_sha256_0`); `openssl kdf … TLS1-PRF` gives the same 100 bytes.
    @Test func thePRFMatchesThePublishedVector() {
        let output = TLSPRF.prf(secret: bytes("9bbe436ba940f017b17652849a71db35"), label: "test label",
                                seed: bytes("a0ba9f936cda311827a6f796ffd5198c"), length: 100)
        #expect(hex(output) == """
            e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17\
            abfd3797c0564bab4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff701 87347b66
            """.replacingOccurrences(of: " ", with: ""))
    }

    @Test func recordsSealAndOpenAndRefuseTampering() throws {
        let cipher = DTLSRecordCipher(key: Array(repeating: 7, count: 16), salt: [1, 2, 3, 4])
        let sequence: [UInt8] = [0, 1, 0, 0, 0, 0, 0, 5]
        let sealed = try cipher.seal(Array("hello".utf8), sequence: sequence, type: 23, version: 0xfefd)
        #expect(sealed.count == 5 + DTLSRecordCipher.overhead)
        #expect(Array(sealed.prefix(8)) == sequence)
        #expect(try cipher.open(sealed, sequence: sequence, type: 23, version: 0xfefd) == Array("hello".utf8))
        var damaged = sealed
        damaged[10] ^= 1
        #expect(throws: DTLSError.decryptFailed) { try cipher.open(damaged, sequence: sequence, type: 23, version: 0xfefd) }
        // Another sequence number or type is other additional data.
        #expect(throws: DTLSError.decryptFailed) { try cipher.open(sealed, sequence: sequence, type: 22, version: 0xfefd) }
    }

    @Test func fingerprintsReadAsSDPWritesThem() throws {
        let certificate = try DTLSCertificate.generate()
        let fingerprint = certificate.fingerprint
        #expect(fingerprint.count == 95)
        #expect(fingerprint == fingerprint.uppercased())
        let digest = Array(SHA256.hash(data: certificate.der))
        #expect(DTLSCertificate.fingerprintBytes(fingerprint) == digest)
        #expect(DTLSCertificate.fingerprintBytes("sha-256 " + fingerprint.lowercased()) == digest)
        #expect(DTLSCertificate.fingerprintBytes("AA:BB") == nil)
    }

    @Test func ourCertificateCarriesItsKey() throws {
        let certificate = try DTLSCertificate.generate()
        guard case .p256(let key) = try PeerPublicKey(certificate: certificate.der) else {
            Issue.record("not a P-256 key")
            return
        }
        #expect(key.rawRepresentation == certificate.privateKey.publicKey.rawRepresentation)
    }

    /// The certificate as OpenSSL reads it: v3, ecdsa-with-SHA256, CN homeswift, P-256, a signature that verifies with
    /// its own key, about 30 days, and the same SHA-256 fingerprint.
    @Test func openSSLReadsOurCertificate() throws {
        guard let openssl = OpenSSL.path else { return }
        let directory = try OpenSSL.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try DTLSCertificate.generate()
        let path = directory.appendingPathComponent("ours.der").path
        try Data(certificate.der).write(to: URL(fileURLWithPath: path))
        let text = try ChildProcess.run(openssl, arguments: ["x509", "-inform", "DER", "-in", path, "-noout", "-text", "-fingerprint", "-sha256"])
        #expect(text.status == 0)
        #expect(text.text.contains("Version: 3"))
        #expect(text.text.contains("ecdsa-with-SHA256"))
        #expect(text.text.contains("CN=homeswift") || text.text.contains("CN = homeswift"))
        #expect(text.text.contains("prime256v1") || text.text.contains("P-256"))
        #expect(text.text.contains("sha256 Fingerprint=\(certificate.fingerprint)") || text.text.contains("SHA256 Fingerprint=\(certificate.fingerprint)"))
        // Self-signed: it verifies against itself.
        let pem = directory.appendingPathComponent("ours.pem").path
        _ = try ChildProcess.run(openssl, arguments: ["x509", "-inform", "DER", "-in", path, "-out", pem])
        let verify = try ChildProcess.run(openssl, arguments: ["verify", "-CAfile", pem, pem])
        #expect(verify.text.contains("OK"), "\(verify.text)\(verify.errorText)")
    }

    @Test func fragmentsReassembleInAnyOrder() {
        let message = HandshakeMessage(type: 11, messageSeq: 3, body: (0..<500).map { UInt8($0 & 0xff) })
        var fragments = message.fragments(maximum: 120)
        #expect(fragments.count == 5)
        // Overlapping copies and a reversed order.
        fragments.append(HandshakeFragment(type: 11, length: 500, messageSeq: 3, offset: 100, body: Array(message.body[100..<300])))
        var reassembler = HandshakeReassembler()
        for fragment in fragments.reversed().dropLast() { reassembler.add(fragment) }
        #expect(reassembler.take(3) == nil)
        reassembler.add(fragments[0])
        #expect(reassembler.take(3) == message)
        // Encoded and decoded as records carry them.
        let wire = fragments[1].encode() + fragments[2].encode()
        #expect((try? HandshakeFragment.decodeAll(wire)) == [fragments[1], fragments[2]])
        // Another type or length for a message already begun is refused.
        let begun = reassembler.add(HandshakeFragment(type: 12, length: 10, messageSeq: 5, offset: 0, body: [1]))
        let otherType = reassembler.add(HandshakeFragment(type: 13, length: 10, messageSeq: 5, offset: 1, body: [1]))
        let otherLength = reassembler.add(HandshakeFragment(type: 12, length: 11, messageSeq: 5, offset: 1, body: [1]))
        #expect(begun && !otherType && !otherLength)
    }

    @Test func recordsSplitFromADatagram() {
        let a = DTLSRecord(type: 22, version: 0xfefd, epoch: 0, sequence: 1, fragment: [1, 2, 3])
        let b = DTLSRecord(type: 20, version: 0xfefd, epoch: 0, sequence: 0xffff_ffff_ff, fragment: [1])
        #expect(DTLSRecord.decodeAll(a.encode() + b.encode() + [22, 0xfe]) == [a, b])
    }

    @Test func theDemultiplexerFollowsRFC7983() {
        #expect(ICEDemultiplexer.classify(0) == .stun)
        #expect(ICEDemultiplexer.classify(22) == .dtls)
        #expect(ICEDemultiplexer.classify(63) == .dtls)
        #expect(ICEDemultiplexer.classify(0x80) == .media)
        #expect(ICEDemultiplexer.classify(191) == .media)
        #expect(ICEDemultiplexer.classify(64) == .other)
    }
}

/// Handshakes between this side's two roles over a memory pipe that loses what it is told to, and over ICE.
@Suite(.timeLimit(.minutes(1))) struct DTLSHandshakeTests {
    @Test func bothRolesAgreeAndLoseTheirFirstFlights() async throws {
        let clientCertificate = try DTLSCertificate.generate(), serverCertificate = try DTLSCertificate.generate()
        // The client's first ClientHello and the server's first flight after the cookie are lost.
        let (a, b) = MemoryPipe.pair(dropFromA: [0], dropFromB: [1])
        let client = DTLSTransport(role: .client, certificate: clientCertificate, remoteFingerprint: serverCertificate.fingerprint, transport: a,
                                   retransmitTimeout: .milliseconds(100))
        let server = DTLSTransport(role: .server, certificate: serverCertificate, remoteFingerprint: clientCertificate.fingerprint, transport: b,
                                   retransmitTimeout: .milliseconds(100))
        async let serverKeys = server.handshake(timeout: .seconds(10))
        let clientKeys = try await client.handshake(timeout: .seconds(10))
        let keys = try await serverKeys
        #expect(clientKeys.material == keys.material)
        #expect(clientKeys.localMasterKey == keys.remoteMasterKey)
        #expect(clientKeys.localMasterSalt == keys.remoteMasterSalt)
        #expect(a.dropped >= 1 && b.dropped >= 1)
        // SRTP from one side opens on the other.
        var sending = try clientKeys.sendingContext()
        var receiving = try keys.receivingContext()
        let rtp: [UInt8] = [0x80, 96, 0, 1, 0, 0, 0, 1, 0, 0, 0, 9] + Array("frame".utf8)
        #expect(try receiving.unprotect(rtp: try sending.protect(rtp: rtp)) == rtp)
        // Application data both ways.
        try await client.send(application: Array("ping".utf8))
        var serverIterator = server.received.makeAsyncIterator()
        #expect(await serverIterator.next() == Array("ping".utf8))
        try await server.send(application: Array("pong".utf8))
        var clientIterator = client.received.makeAsyncIterator()
        #expect(await clientIterator.next() == Array("pong".utf8))
        await client.close()
        await server.close()
    }

    @Test func aSmallMTUFragmentsEveryFlight() async throws {
        let clientCertificate = try DTLSCertificate.generate(), serverCertificate = try DTLSCertificate.generate()
        let (a, b) = MemoryPipe.pair(dropFromA: [], dropFromB: [])
        let client = DTLSTransport(role: .client, certificate: clientCertificate, remoteFingerprint: serverCertificate.fingerprint, transport: a, mtu: 150)
        let server = DTLSTransport(role: .server, certificate: serverCertificate, remoteFingerprint: clientCertificate.fingerprint, transport: b, mtu: 150)
        async let serverKeys = server.handshake(timeout: .seconds(10))
        let clientKeys = try await client.handshake(timeout: .seconds(10))
        #expect(try await serverKeys.material == clientKeys.material)
        #expect(a.largest <= 150 && b.largest <= 150)
    }

    @Test func aWrongFingerprintFailsBothSides() async throws {
        let clientCertificate = try DTLSCertificate.generate(), serverCertificate = try DTLSCertificate.generate()
        let other = try DTLSCertificate.generate()
        let (a, b) = MemoryPipe.pair(dropFromA: [], dropFromB: [])
        let client = DTLSTransport(role: .client, certificate: clientCertificate, remoteFingerprint: other.fingerprint, transport: a)
        let server = DTLSTransport(role: .server, certificate: serverCertificate, remoteFingerprint: clientCertificate.fingerprint, transport: b)
        let serverResult = Task { try await server.handshake(timeout: .seconds(10)) }
        await #expect(throws: DTLSError.fingerprintMismatch) { try await client.handshake(timeout: .seconds(10)) }
        // The client's bad_certificate alert ends the server's handshake.
        await #expect(throws: DTLSError.alert(level: 2, description: DTLSConstants.Alert.badCertificate)) { try await serverResult.value }
    }

    @Test func aSilentPeerTimesOut() async throws {
        let (a, _) = MemoryPipe.pair(dropFromA: [], dropFromB: [])
        let client = DTLSTransport(role: .client, certificate: try DTLSCertificate.generate(), remoteFingerprint: "", transport: a,
                                   retransmitTimeout: .milliseconds(20), maximumRetransmissions: 3)
        await #expect(throws: DTLSError.timeout) { try await client.handshake(timeout: .seconds(10)) }
        #expect(a.sent == 4)
    }

    /// Over two ICE agents on the loopback, with the demultiplexer: DTLS reaches the transport, RTP the media stream.
    @Test func dtlsRunsOverICE() async throws {
        let a = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true))
        let b = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true))
        for candidate in await b.hostCandidates(addresses: ["127.0.0.1"]) { await a.add(remote: candidate) }
        for candidate in await a.hostCandidates(addresses: ["127.0.0.1"]) { await b.add(remote: candidate) }
        await a.start(remote: b.local)
        await b.start(remote: a.local)
        #expect(await a.waitForSelection() != nil)
        #expect(await b.waitForSelection() != nil)
        let routeA = ICEDemultiplexer(agent: a), routeB = ICEDemultiplexer(agent: b)
        let clientCertificate = try DTLSCertificate.generate(), serverCertificate = try DTLSCertificate.generate()
        let client = DTLSTransport(role: .client, certificate: clientCertificate, remoteFingerprint: serverCertificate.fingerprint, transport: routeA.dtls)
        let server = DTLSTransport(role: .server, certificate: serverCertificate, remoteFingerprint: clientCertificate.fingerprint, transport: routeB.dtls)
        async let serverKeys = server.handshake(timeout: .seconds(10))
        let clientKeys = try await client.handshake(timeout: .seconds(10))
        #expect(try await serverKeys.material == clientKeys.material)
        var sending = try clientKeys.sendingContext()
        let rtp: [UInt8] = [0x80, 96, 0, 7, 0, 0, 0, 1, 0, 0, 0, 9, 1, 2, 3]
        try await a.send(try sending.protect(rtp: rtp))
        var media = routeB.media.makeAsyncIterator()
        var receiving = try await serverKeys.receivingContext()
        #expect(try receiving.unprotect(rtp: try #require(await media.next())) == rtp)
        await a.stop()
        await b.stop()
    }
}

/// This side against OpenSSL 3's `s_server` and `s_client` on the loopback: the exported keying material must be the
/// bytes OpenSSL prints. Skipped when no OpenSSL with DTLS 1.2 is found.
@Suite(.timeLimit(.minutes(1))) struct DTLSOpenSSLTests {
    static let srtpArguments = ["-dtls1_2", "-use_srtp", "SRTP_AES128_CM_SHA1_80", "-keymatexport", "EXTRACTOR-dtls_srtp", "-keymatexportlen", "60"]

    struct Server {
        var process: OpenSSLProcess
        var port: Int
    }

    func startServer(_ openssl: String, _ files: OpenSSL.Files, extra: [String] = []) async throws -> Server {
        let process = try OpenSSLProcess(openssl, arguments: ["s_server"] + Self.srtpArguments + [
            "-accept", "127.0.0.1:0", "-cert", files.certificate, "-key", files.key, "-Verify", "1", "-naccept", "1",
        ] + extra)
        let accept = try #require(await process.waitFor("ACCEPT 127.0.0.1:"), "s_server did not start: \(process.output)")
        let port = try #require(Int(accept.prefix { $0.isNumber }))
        return Server(process: process, port: port)
    }

    func client(port: Int, fingerprint: String, mtu: Int = 1200, drop: Set<Int> = []) async throws -> (DTLSTransport, LossyTransport) {
        let socket = try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true)
        let transport = LossyTransport(UDPPeerTransport(socket: socket, remoteHost: "127.0.0.1", remotePort: port), drop: drop)
        let dtls = DTLSTransport(role: .client, certificate: try DTLSCertificate.generate(), remoteFingerprint: fingerprint, transport: transport,
                                 mtu: mtu, retransmitTimeout: .milliseconds(300))
        return (dtls, transport)
    }

    @Test(arguments: [false, true]) func ourClientAgainstSServer(cookies: Bool) async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .ec)
        defer { files.remove() }
        // -listen makes s_server answer with a HelloVerifyRequest first.
        let server = try await startServer(openssl, files, extra: cookies ? ["-listen"] : [])
        defer { server.process.stop() }
        let (client, _) = try await client(port: server.port, fingerprint: files.fingerprint)
        let keys = try await client.handshake(timeout: .seconds(15))
        let printed = try #require(await server.process.waitFor("Keying material: "), "\(server.process.output)")
        #expect(printed.prefix { $0.isHexDigit } == hex(keys.material).uppercased())
        #expect(server.process.output.contains("SRTP Extension negotiated, profile=SRTP_AES128_CM_SHA1_80"))
        // Application data both ways: s_server prints what it receives and sends what its input says.
        try await client.send(application: Array("from homeswift\n".utf8))
        #expect(await server.process.waitFor("from homeswift") != nil)
        server.process.write("from openssl\n")
        var iterator = client.received.makeAsyncIterator()
        #expect(await iterator.next() == Array("from openssl\n".utf8))
        await client.close()
    }

    @Test func ourClientAgainstAnRSAServer() async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .rsa)
        defer { files.remove() }
        let server = try await startServer(openssl, files)
        defer { server.process.stop() }
        let (client, _) = try await client(port: server.port, fingerprint: files.fingerprint)
        let keys = try await client.handshake(timeout: .seconds(15))
        let printed = try #require(await server.process.waitFor("Keying material: "), "\(server.process.output)")
        #expect(printed.prefix { $0.isHexDigit } == hex(keys.material).uppercased())
        #expect(server.process.output.contains("ECDHE-RSA-AES128-GCM-SHA256"))
    }

    @Test func ourClientLosesItsFirstFlightsAndFragmentsAgainstSServer() async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .ec)
        defer { files.remove() }
        let server = try await startServer(openssl, files, extra: ["-mtu", "300"])
        defer { server.process.stop() }
        // The ClientHello and the first datagram of the second flight are lost; every datagram is 200 bytes at most.
        let (client, transport) = try await client(port: server.port, fingerprint: files.fingerprint, mtu: 200, drop: [0, 1])
        let keys = try await client.handshake(timeout: .seconds(20))
        let printed = try #require(await server.process.waitFor("Keying material: "), "\(server.process.output)")
        #expect(printed.prefix { $0.isHexDigit } == hex(keys.material).uppercased())
        #expect(transport.dropped == 2)
        #expect(transport.largest <= 200)
    }

    @Test(arguments: [0, 1]) func ourServerAgainstSClient(dropFirst: Int) async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .ec)
        defer { files.remove() }
        let socket = try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true)
        let port = try #require(socket.localPort)
        // With dropFirst, the HelloVerifyRequest is lost: s_client sends its hello again on its own timer.
        let transport = LossyTransport(UDPPeerTransport(socket: socket), drop: dropFirst == 1 ? [0] : [])
        let server = DTLSTransport(role: .server, certificate: try DTLSCertificate.generate(), remoteFingerprint: files.fingerprint, transport: transport)
        async let keys = server.handshake(timeout: .seconds(20))
        let client = try OpenSSLProcess(openssl, arguments: ["s_client"] + Self.srtpArguments + [
            "-connect", "127.0.0.1:\(port)", "-cert", files.certificate, "-key", files.key,
        ])
        defer { client.stop() }
        let exported = try await keys
        let printed = try #require(await client.waitFor("Keying material: "), "\(client.output)")
        #expect(printed.prefix { $0.isHexDigit } == hex(exported.material).uppercased())
        #expect(client.output.contains("ECDHE-ECDSA-AES128-GCM-SHA256"))
        #expect(client.output.contains("Extended master secret: yes"))
        #expect(transport.dropped == dropFirst)
        await server.close()
    }

    @Test func aFingerprintMismatchFailsAgainstSServer() async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .ec)
        defer { files.remove() }
        let server = try await startServer(openssl, files)
        defer { server.process.stop() }
        let (client, _) = try await client(port: server.port, fingerprint: try DTLSCertificate.generate().fingerprint)
        await #expect(throws: DTLSError.fingerprintMismatch) { try await client.handshake(timeout: .seconds(15)) }
    }

    @Test func aFingerprintMismatchFailsAgainstSClient() async throws {
        guard let openssl = OpenSSL.path else { return }
        let files = try OpenSSL.files(openssl, key: .ec)
        defer { files.remove() }
        let socket = try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true)
        let port = try #require(socket.localPort)
        let server = DTLSTransport(role: .server, certificate: try DTLSCertificate.generate(),
                                   remoteFingerprint: try DTLSCertificate.generate().fingerprint, transport: UDPPeerTransport(socket: socket))
        let result = Task { try await server.handshake(timeout: .seconds(15)) }
        let client = try OpenSSLProcess(openssl, arguments: ["s_client"] + Self.srtpArguments + [
            "-connect", "127.0.0.1:\(port)", "-cert", files.certificate, "-key", files.key,
        ])
        defer { client.stop() }
        await #expect(throws: DTLSError.fingerprintMismatch) { try await result.value }
        _ = await client.waitFor("alert number 42", timeout: .seconds(5))
        #expect(client.output.contains("alert number 42") || client.output.contains("bad certificate"), "\(client.output)")
    }
}

// MARK: Helpers

/// Two ends of an in-memory datagram pipe; each drops the sends whose index (from 0) it is given.
final class MemoryPipe: DatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private weak var peer: MemoryPipe?
    private let drop: Set<Int>
    private let lock = NSLock()
    private var count = 0
    private var droppedCount = 0
    private var largestDatagram = 0

    var sent: Int { lock.withLock { count } }
    var dropped: Int { lock.withLock { droppedCount } }
    var largest: Int { lock.withLock { largestDatagram } }

    private init(drop: Set<Int>) {
        self.drop = drop
        (incoming, continuation) = AsyncStream<[UInt8]>.makeStream()
    }

    static func pair(dropFromA: Set<Int>, dropFromB: Set<Int>) -> (MemoryPipe, MemoryPipe) {
        let a = MemoryPipe(drop: dropFromA), b = MemoryPipe(drop: dropFromB)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ datagram: [UInt8]) async throws {
        let deliver = lock.withLock {
            defer { count += 1 }
            largestDatagram = max(largestDatagram, datagram.count)
            if drop.contains(count) { droppedCount += 1; return false }
            return true
        }
        if deliver { peer?.continuation.yield(datagram) }
    }
}

/// A transport that loses the sends whose index (from 0) it is given.
final class LossyTransport: DatagramTransport, @unchecked Sendable {
    let base: any DatagramTransport
    private let drop: Set<Int>
    private let lock = NSLock()
    private var count = 0
    private var droppedCount = 0
    private var largestDatagram = 0

    var incoming: AsyncStream<[UInt8]> { base.incoming }
    var dropped: Int { lock.withLock { droppedCount } }
    var largest: Int { lock.withLock { largestDatagram } }

    init(_ base: any DatagramTransport, drop: Set<Int>) {
        self.base = base
        self.drop = drop
    }

    func send(_ datagram: [UInt8]) async throws {
        let deliver = lock.withLock {
            defer { count += 1 }
            largestDatagram = max(largestDatagram, datagram.count)
            if drop.contains(count) { droppedCount += 1; return false }
            return true
        }
        if deliver { try await base.send(datagram) }
    }
}

enum OpenSSL {
    /// OpenSSL (not LibreSSL) with DTLS 1.2: Homebrew's on macOS, the system's on Linux.
    static let path: String? = {
        let candidates = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/bin/openssl", "/usr/local/bin/openssl"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let version = try? ChildProcess.run(candidate, arguments: ["version"]), version.text.hasPrefix("OpenSSL "),
                  let help = try? ChildProcess.run(candidate, arguments: ["s_server", "-help"]),
                  (help.text + help.errorText).contains("-dtls1_2"), (help.text + help.errorText).contains("-keymatexport") else { continue }
            return candidate
        }
        return nil
    }()

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-dtls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum KeyKind { case ec, rsa }

    struct Files {
        var directory: URL
        var certificate: String
        var key: String
        var fingerprint: String

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A self-signed certificate and key made by OpenSSL, and the fingerprint of its DER.
    static func files(_ openssl: String, key kind: KeyKind) throws -> Files {
        let directory = try temporaryDirectory()
        let certificate = directory.appendingPathComponent("cert.pem").path, key = directory.appendingPathComponent("key.pem").path
        let der = directory.appendingPathComponent("cert.der").path
        let keyArguments = kind == .ec ? ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256"] : ["-newkey", "rsa:2048"]
        let made = try ChildProcess.run(openssl, arguments: ["req", "-x509"] + keyArguments + [
            "-nodes", "-keyout", key, "-out", certificate, "-days", "2", "-subj", "/CN=openssl",
        ])
        guard made.status == 0 else { throw OpenSSLFailure(text: made.errorText) }
        _ = try ChildProcess.run(openssl, arguments: ["x509", "-in", certificate, "-outform", "DER", "-out", der])
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: der)))
        return Files(directory: directory, certificate: certificate, key: key, fingerprint: DTLSCertificate.fingerprint(of: bytes))
    }
}

struct OpenSSLFailure: Error {
    var text: String
}

/// An `openssl` command running, its output (standard output and error together) collected as it comes.
final class OpenSSLProcess: @unchecked Sendable {
    private let child: ChildProcess
    private let input: FileHandle
    private let lock = NSLock()
    private var collected = Data()

    var output: String { lock.withLock { String(decoding: collected, as: UTF8.self) } }

    init(_ path: String, arguments: [String]) throws {
        let out = try ChildProcess.pipe(), stdin = try ChildProcess.pipe()
        child = try ChildProcess.launch(path, arguments: arguments, standardInput: stdin.reading.fileDescriptor,
                                        standardOutput: out.writing.fileDescriptor, standardError: out.writing.fileDescriptor)
        try? stdin.reading.close()
        try? out.writing.close()
        input = stdin.writing
        let reading = out.reading
        let thread = Thread { [weak self] in
            while true {
                let data = reading.availableData
                if data.isEmpty { break }
                guard let self else { break }
                self.lock.withLock { self.collected.append(data) }
            }
            try? reading.close()
        }
        thread.start()
    }

    /// What follows `marker` on its line, once it appears; nil after `timeout`.
    func waitFor(_ marker: String, timeout: Duration = .seconds(15)) async -> String? {
        let clock = ContinuousClock(), end = clock.now + timeout
        while clock.now < end {
            let text = output
            if let range = text.range(of: marker) {
                let rest = text[range.upperBound...]
                if rest.contains("\n") { return String(rest.prefix { $0 != "\n" && $0 != "\r" }) }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func write(_ text: String) { try? input.write(contentsOf: Data(text.utf8)) }

    func stop() {
        child.signal(SIGKILL)
        try? input.close()
    }
}
