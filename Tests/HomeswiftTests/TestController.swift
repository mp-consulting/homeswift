import Crypto
import Foundation
import NIOCore
import NIOPosix

@testable import Homeswift

/// A minimal HomeKit controller that talks to the server over a real socket, for end-to-end tests.
final class TestController: @unchecked Sendable {
    struct Message {
        var startLine: String
        var status: Int
        var body: Data
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    }

    final class Inbound: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<ByteBuffer>.Continuation
        init(_ continuation: AsyncStream<ByteBuffer>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { continuation.yield(unwrapInboundIn(data)) }
        func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    }

    let identifier: String
    let signingKey: Curve25519.Signing.PrivateKey
    private var channel: (any Channel)!
    private var iterator: AsyncStream<ByteBuffer>.AsyncIterator!
    private var raw = Data()
    private var plain = Data()
    private var session: SecureSession?
    var accessoryLTPK: Data?
    var accessoryID: String?

    init(identifier: String = UUID().uuidString, signingKey: Curve25519.Signing.PrivateKey = .init()) {
        self.identifier = identifier
        self.signingKey = signingKey
    }

    func connect(port: Int) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Inbound(continuation)) }
            }
            .connect(host: "127.0.0.1", port: port).get()
        iterator = stream.makeAsyncIterator()
        raw = Data()
        plain = Data()
        session = nil
    }

    func close() async {
        try? await channel.close()
    }

    var isConnected: Bool { channel.isActive }

    // MARK: HTTP

    func request(_ method: String, _ target: String, body: Data = Data(), contentType: String = "application/hap+json") async throws -> Message {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: test\r\n"
        if !body.isEmpty || method != "GET" { head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8) + body
        if session != nil { data = try session!.encrypt(data) }
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
        return try await nextMessage()
    }

    func json(_ method: String, _ target: String, _ object: Any) async throws -> Message {
        try await request(method, target, body: try JSONSerialization.data(withJSONObject: object))
    }

    func tlv(_ path: String, _ tlv: TLV8) async throws -> TLV8 {
        let message = try await request("POST", path, body: tlv.encoded(), contentType: "application/pairing+tlv8")
        return try TLV8(decoding: message.body)
    }

    /// The next response or event. Tests run under a time limit, so a stuck server fails instead of hanging.
    func nextMessage() async throws -> Message {
        while true {
            if let parsed = try HTTPRequest.parse(&plain) {
                return Message(startLine: "\(parsed.method) \(parsed.target)", status: Int(parsed.target) ?? 0, body: parsed.body)
            }
            guard let buffer = await iterator.next() else { throw ChannelError.eof }
            raw.append(contentsOf: buffer.readableBytesView)
            if session != nil {
                plain.append(try session!.decrypt(&raw))
            } else {
                plain.append(raw)
                raw = Data()
            }
        }
    }

    // MARK: Pairing

    enum PairingFailure: Error { case step(Int, UInt8?) }

    func pairSetup(code: String) async throws {
        var m1 = TLV8()
        m1.append(.state, 1)
        m1.append(.method, 0)
        let m2 = try await tlv("/pair-setup", m1)
        guard m2.byte(.error) == nil, let salt = m2[.salt], let B = m2[.publicKey] else {
            throw PairingFailure.step(2, m2.byte(.error))
        }

        let srp = SRP.Client()
        let (K, M1, expectedM2) = srp.proof(salt: salt, serverPublicKey: B, password: code)
        var m3 = TLV8()
        m3.append(.state, 3)
        m3.append(.publicKey, srp.publicKey)
        m3.append(.proof, M1)
        let m4 = try await tlv("/pair-setup", m3)
        guard m4.byte(.error) == nil, m4[.proof] == expectedM2 else { throw PairingFailure.step(4, m4.byte(.error)) }

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
        let m6 = try await tlv("/pair-setup", m5)
        guard m6.byte(.error) == nil, let encrypted = m6[.encryptedData] else { throw PairingFailure.step(6, m6.byte(.error)) }

        let info = try TLV8(decoding: try HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PS-Msg06")))
        let accessoryID = info[.identifier]!
        let accessoryLTPK = info[.publicKey]!
        let accessoryX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info").data
        guard try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
            .isValidSignature(info[.signature]!, for: accessoryX + accessoryID + accessoryLTPK)
        else { throw PairingFailure.step(6, nil) }
        self.accessoryLTPK = accessoryLTPK
        self.accessoryID = String(data: accessoryID, encoding: .utf8)
    }

    func pairVerify() async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = ephemeral.publicKey.rawRepresentation
        var m1 = TLV8()
        m1.append(.state, 1)
        m1.append(.publicKey, publicKey)
        let m2 = try await tlv("/pair-verify", m1)
        guard m2.byte(.error) == nil, let accessoryPublic = m2[.publicKey], let encrypted = m2[.encryptedData] else {
            throw PairingFailure.step(2, m2.byte(.error))
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: accessoryPublic)).data
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = try TLV8(decoding: try HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PV-Msg02")))
        guard let accessoryLTPK,
            try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
                .isValidSignature(sub[.signature]!, for: accessoryPublic + sub[.identifier]! + publicKey)
        else { throw PairingFailure.step(2, nil) }

        let id = Data(identifier.utf8)
        var reply = TLV8()
        reply.append(.identifier, id)
        reply.append(.signature, try signingKey.signature(for: publicKey + id + accessoryPublic))
        var m3 = TLV8()
        m3.append(.state, 3)
        m3.append(.encryptedData, try HAPCrypto.seal(reply.encoded(), key: key, nonce: HAPCrypto.nonce("PV-Msg03")))
        let m4 = try await tlv("/pair-verify", m3)
        guard m4.byte(.error) == nil, m4.byte(.state) == 4 else { throw PairingFailure.step(4, m4.byte(.error)) }
        session = SecureSession(sharedSecret: shared, isAccessory: false)
    }
}
