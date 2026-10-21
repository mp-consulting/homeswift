import Crypto
import Foundation
import NIOCore
import NIOPosix

enum ControllerError: Error {
    case closed
    case timeout
    case pairing(step: Int, error: UInt8?)
    case status(Int, String)
}

extension ContinuousClock.Instant {
    /// Seconds since this instant.
    var elapsed: Double {
        let duration = self.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// A HomeKit controller on one TCP connection: pairing, verified sessions, requests and events.
final class Controller: @unchecked Sendable {
    final class Inbound: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<ByteBuffer>.Continuation
        init(_ continuation: AsyncStream<ByteBuffer>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { continuation.yield(unwrapInboundIn(data)) }
        func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    }

    struct PairSetupTiming {
        var m1m2: Double
        var m3m4: Double
        var m5m6: Double
        var wall: Double
        /// The three round trips: what the server spent, plus the loopback.
        var roundTrips: Double { m1m2 + m3m4 + m5m6 }
    }

    struct PairVerifyTiming {
        var m1m2: Double
        var m3m4: Double
        var wall: Double
        var roundTrips: Double { m1m2 + m3m4 }
    }

    static let hapJSON = "application/hap+json"
    static let pairingTLV = "application/pairing+tlv8"

    let identifier: String
    let signingKey: Curve25519.Signing.PrivateKey
    private var channel: (any Channel)?
    private var iterator: AsyncStream<ByteBuffer>.AsyncIterator?
    private var raw = Data()
    private var plain = Data()
    private var session: SecureSession?
    var accessoryLTPK: Data?
    var accessoryID: String?
    private(set) var eventsSkipped = 0

    init(identifier: String = UUID().uuidString.uppercased(), signingKey: Curve25519.Signing.PrivateKey = .init()) {
        self.identifier = identifier
        self.signingKey = signingKey
    }

    /// Another connection for the same controller identity, able to pair-verify at once.
    func sibling() -> Controller {
        let other = Controller(identifier: identifier, signingKey: signingKey)
        other.accessoryLTPK = accessoryLTPK
        other.accessoryID = accessoryID
        return other
    }

    func connect(host: String = "127.0.0.1", port: Int) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Inbound(continuation)) }
            }
            .connect(host: host, port: port).get()
        iterator = stream.makeAsyncIterator()
        raw = Data()
        plain = Data()
        session = nil
    }

    func close() async {
        try? await channel?.close()
        channel = nil
    }

    // MARK: HTTP

    func send(_ method: String, _ target: String, body: Data = Data(), contentType: String = Controller.hapJSON) async throws {
        guard let channel else { throw ControllerError.closed }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: hap-bench\r\n"
        if !body.isEmpty || method != "GET" { head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8) + body
        if session != nil { data = try session!.encrypt(data) }
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }

    /// The next message, response or event.
    func receive() async throws -> HTTPMessage {
        while true {
            if let message = try HTTPMessage.parse(&plain) { return message }
            guard let buffer = await iterator?.next() else { throw ControllerError.closed }
            raw.append(contentsOf: buffer.readableBytesView)
            if session != nil {
                plain.append(try session!.decrypt(&raw))
            } else {
                plain.append(raw)
                raw = Data()
            }
        }
    }

    /// The next message within `timeout`. On a timeout the connection is unusable afterwards.
    func receive(timeout: Duration) async throws -> HTTPMessage {
        try await withThrowingTaskGroup(of: HTTPMessage.self) { group in
            group.addTask { try await self.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ControllerError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// The next response, skipping events.
    func response() async throws -> HTTPMessage {
        while true {
            let message = try await receive()
            if message.isEvent {
                eventsSkipped += 1
                continue
            }
            return message
        }
    }

    /// Sends a request and returns the response with the seconds from the write to the complete response.
    func timed(_ method: String, _ target: String, body: Data = Data(), contentType: String = Controller.hapJSON) async throws -> (HTTPMessage, Double) {
        let start = ContinuousClock.now
        try await send(method, target, body: body, contentType: contentType)
        let message = try await response()
        return (message, start.elapsed)
    }

    func request(_ method: String, _ target: String, body: Data = Data(), contentType: String = Controller.hapJSON) async throws -> HTTPMessage {
        try await timed(method, target, body: body, contentType: contentType).0
    }

    func json(_ method: String, _ target: String, _ object: Any) async throws -> (HTTPMessage, Double) {
        try await timed(method, target, body: try JSONSerialization.data(withJSONObject: object))
    }

    func tlv(_ path: String, _ tlv: TLV8) async throws -> (TLV8, Double) {
        let (message, seconds) = try await timed("POST", path, body: tlv.encoded(), contentType: Controller.pairingTLV)
        return (try TLV8(decoding: message.body), seconds)
    }

    // MARK: Pairing

    func pairSetup(code: String) async throws -> PairSetupTiming {
        let start = ContinuousClock.now
        var m1 = TLV8()
        m1.append(.state, 1)
        m1.append(.method, 0)
        let (m2, t12) = try await tlv("/pair-setup", m1)
        guard m2.byte(.error) == nil, let salt = m2[.salt], let B = m2[.publicKey] else {
            throw ControllerError.pairing(step: 2, error: m2.byte(.error))
        }

        let srp = SRP.Client()
        let (K, M1, expectedM2) = srp.proof(salt: salt, serverPublicKey: B, password: code)
        var m3 = TLV8()
        m3.append(.state, 3)
        m3.append(.publicKey, srp.publicKey)
        m3.append(.proof, M1)
        let (m4, t34) = try await tlv("/pair-setup", m3)
        guard m4.byte(.error) == nil, m4[.proof] == expectedM2 else { throw ControllerError.pairing(step: 4, error: m4.byte(.error)) }

        let key = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let x = HAPCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info").data
        let ltpk = signingKey.publicKey.rawRepresentation
        let id = Data(identifier.utf8)
        var sub = TLV8()
        sub.append(.identifier, id)
        sub.append(.publicKey, ltpk)
        sub.append(.signature, try signingKey.signature(for: x + id + ltpk))
        var m5 = TLV8()
        m5.append(.state, 5)
        m5.append(.encryptedData, try HAPCrypto.seal(sub.encoded(), key: key, nonce: HAPCrypto.nonce("PS-Msg05")))
        let (m6, t56) = try await tlv("/pair-setup", m5)
        guard m6.byte(.error) == nil, let encrypted = m6[.encryptedData] else { throw ControllerError.pairing(step: 6, error: m6.byte(.error)) }

        let info = try TLV8(decoding: try HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PS-Msg06")))
        guard let accessoryID = info[.identifier], let accessoryLTPK = info[.publicKey], let signature = info[.signature] else {
            throw ControllerError.pairing(step: 6, error: nil)
        }
        let accessoryX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info").data
        guard try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
            .isValidSignature(signature, for: accessoryX + accessoryID + accessoryLTPK)
        else { throw ControllerError.pairing(step: 6, error: nil) }
        self.accessoryLTPK = accessoryLTPK
        self.accessoryID = String(data: accessoryID, encoding: .utf8)
        return PairSetupTiming(m1m2: t12, m3m4: t34, m5m6: t56, wall: start.elapsed)
    }

    func pairVerify() async throws -> PairVerifyTiming {
        let start = ContinuousClock.now
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = ephemeral.publicKey.rawRepresentation
        var m1 = TLV8()
        m1.append(.state, 1)
        m1.append(.publicKey, publicKey)
        let (m2, t12) = try await tlv("/pair-verify", m1)
        guard m2.byte(.error) == nil, let accessoryPublic = m2[.publicKey], let encrypted = m2[.encryptedData] else {
            throw ControllerError.pairing(step: 2, error: m2.byte(.error))
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: accessoryPublic)).data
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = try TLV8(decoding: try HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PV-Msg02")))
        guard let accessoryLTPK, let signature = sub[.signature], let accessoryIdentifier = sub[.identifier],
            try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
                .isValidSignature(signature, for: accessoryPublic + accessoryIdentifier + publicKey)
        else { throw ControllerError.pairing(step: 2, error: nil) }

        let id = Data(identifier.utf8)
        var reply = TLV8()
        reply.append(.identifier, id)
        reply.append(.signature, try signingKey.signature(for: publicKey + id + accessoryPublic))
        var m3 = TLV8()
        m3.append(.state, 3)
        m3.append(.encryptedData, try HAPCrypto.seal(reply.encoded(), key: key, nonce: HAPCrypto.nonce("PV-Msg03")))
        let (m4, t34) = try await tlv("/pair-verify", m3)
        guard m4.byte(.error) == nil, m4.byte(.state) == 4 else { throw ControllerError.pairing(step: 4, error: m4.byte(.error)) }
        session = SecureSession(sharedSecret: shared)
        return PairVerifyTiming(m1m2: t12, m3m4: t34, wall: start.elapsed)
    }

    /// Removes a pairing (needs a verified admin session). Servers close the removed controller's connections.
    func removePairing(_ identifier: String) async throws {
        var remove = TLV8()
        remove.append(.state, 1)
        remove.append(.method, 4)
        remove.append(.identifier, Data(identifier.utf8))
        let (reply, _) = try await tlv("/pairings", remove)
        if let error = reply.byte(.error) { throw ControllerError.pairing(step: 2, error: error) }
    }

    /// Subscribes to events for a characteristic.
    func subscribe(aid: Int, iid: Int) async throws {
        let (reply, _) = try await json("PUT", "/characteristics", ["characteristics": [["aid": aid, "iid": iid, "ev": true]]])
        guard reply.status == 204 else { throw ControllerError.status(reply.status, String(decoding: reply.body, as: UTF8.self)) }
    }
}
