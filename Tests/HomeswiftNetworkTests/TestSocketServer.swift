import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Testing

@testable import HomeswiftNetwork

/// A client certificate (EC P-256, CN=homeswift-test-client) with its key, and the same in PKCS#12 (`secret`).
enum TestClientCertificate {
    static let certificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBdzCCARygAwIBAgIULUBAztFDvnpZjxx2aXa6lg25+UIwCgYIKoZIzj0EAwIw
        IDEeMBwGA1UEAwwVaG9tZXN3aWZ0LXRlc3QtY2xpZW50MCAXDTI2MTAyMjE3NTI1
        NVoYDzIxMjYwOTI4MTc1MjU1WjAgMR4wHAYDVQQDDBVob21lc3dpZnQtdGVzdC1j
        bGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ0Ky84tQfNlgJmJQ56W84W
        K1csCbeUqTOJwTMGCl94ox7dGde0DlnB9yEjhddkhLFwY1C+XZrIV7w49QRgnbPN
        ozIwMDAdBgNVHQ4EFgQUNEUlFP4BTyCcsyux62B0/RYneO0wDwYDVR0TAQH/BAUw
        AwEB/zAKBggqhkjOPQQDAgNJADBGAiEAzhWcyu4Wh1SFLfoqiL6SMB1k4XBBeN6I
        56m4U1UcWDMCIQDWjmz3P/R8WktJ5aU9WcCFLn7Z5ldvMMjZ+SezAcJALg==
        -----END CERTIFICATE-----
        """
    static let keyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgEU/Qdcp65FDoO/zj
        q+uSuKnFQG1c4au3OCAPJAGadvihRANCAAQ0Ky84tQfNlgJmJQ56W84WK1csCbeU
        qTOJwTMGCl94ox7dGde0DlnB9yEjhddkhLFwY1C+XZrIV7w49QRgnbPN
        -----END PRIVATE KEY-----
        """
    static let pkcs12 = Data(
        base64Encoded:
            "MIIDggIBAzCCA0AGCSqGSIb3DQEHAaCCAzEEggMtMIIDKTCCAh8GCSqGSIb3DQEHBqCCAhAwggIMAgEAMIICBQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIarkKUZk44k0CAggAgIIB2AswXc6uhzcMUV+y6QwaHWv+lJCdOWAkQu3oSu6/YCDW0o7mYttVTeN1yjD777CM8BvSpR4dP58pYU7wffp7mnOt/OV2cYAPPG/DnYmI8FpYbKd1SyfWUMlc2bL0QqRG9cAU2jO4YS5RFD1gIYsEyt1Uht99SX1QzXT0xmCk9on2nve2pgj/VeGXRnOPKt0Y49g7HPl07hoynzScJ7mufcV9Ckta+5cO9ZUv7eYyyGuCMjYx589tZJjrnvPjPEgFqk/CFxDk8gYQl6zv73V/qOJ0WyqPzTQrmRAJLpuJE41mw1gy3CZRvBZP21dyp0+L3twa2W8cV2OVwicpE5eBpvU9zIC8u2o0s69waKjv+paDcSrPJGYqGM1VvKGTMhyrP83t5++rOHAZTV5W3tpbU32tSU2SU/mBB5ZKImaIxTKfFeqllclEHHFfES0CdLqMKVrurN1mH4yOpI3htNOGeFN3BenXX4eS6f+QiFbFZ11tpF27DXIdOG08QDyKSm9d3tR1xm7yfcSEK4z42+rw4rsRQIWe0R9oBosOk7yJdqJqbp52GXktq1tVPugmGPYeHEc1+IRWAkFZ0y7+xDdWOfl6E3qaRlexasJmAlGZwLv6754snPPqFucwggECBgkqhkiG9w0BBwGggfQEgfEwge4wgesGCyqGSIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQI2KxOzaq38soCAggABIGQaT0JOdHNw5kZbEUKZBEqONYgcJI7TtvXJQmbXNjR/zfS1v6eik8N3cPE4SPeYqZ0fMHR/fL0jnjME8++S2ewNsKV9Vw3Zxa0Oq1puRWK3lWqgDsLxinf/K/y03IzeUiRln4ArkDR7FWYc+ClzTQPbEmSXGKq6QWjlaOf28OlUJDGpJV+/ZX1veS7Yrp64UsMMSUwIwYJKoZIhvcNAQkVMRYEFHRk47VAdfm6B6CokIyTCmPkdtR2MDkwITAJBgUrDgMCGgUABBTlrUtIp35OKI31e4N4PdG/vWrH+wQQL730atm56/6YIiMMEPIb1QICCAA="
    )!
}

/// Waits until `condition` holds, polling; fails the test after `timeout`.
func eventually(_ timeout: Duration = .seconds(5), _ comment: Comment? = nil, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(comment ?? "condition not met in time")
    throw CancellationError()
}

/// A NIO server on port 0 for the WebSocket and MQTT tests: an echoing WebSocket server, an MQTT broker over TCP,
/// or the broker over WebSocket; plain or TLS with the test certificate, optionally requiring a client certificate.
final class TestSocketServer: Sendable {
    enum Mode: Sendable { case webSocket, mqtt, mqttOverWebSocket }

    let channel: any Channel
    let broker = TestBroker()
    let webSocket = WebSocketBehaviour()
    var port: Int { channel.localAddress!.port! }

    init(mode: Mode, tls: Bool = false, requireClientCertificate: Bool = false, alpn: [String] = []) async throws {
        var sslContext: NIOSSLContext?
        if tls {
            let certificate = try NIOSSLCertificate(bytes: Array(TestCertificate.certificatePEM.utf8), format: .pem)
            let key = try NIOSSLPrivateKey(bytes: Array(TestCertificate.keyPEM.utf8), format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
            if requireClientCertificate {
                configuration.certificateVerification = .noHostnameVerification
                configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(TestClientCertificate.certificatePEM.utf8)))
            }
            if !alpn.isEmpty { configuration.applicationProtocols = alpn }
            sslContext = try NIOSSLContext(configuration: configuration)
        }
        let context = sslContext
        let broker = broker
        let behaviour = webSocket
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                    switch mode {
                    case .mqtt:
                        try channel.pipeline.syncOperations.addHandler(BrokerTCPHandler(broker: broker))
                    case .webSocket, .mqttOverWebSocket:
                        let upgrader = NIOWebSocketServerUpgrader(
                            maxFrameSize: 1 << 20, automaticErrorHandling: true,
                            shouldUpgrade: { channel, head in
                                behaviour.record(head)
                                if head.uri.hasPrefix("/refuse") { return channel.eventLoop.makeSucceededFuture(nil) }
                                var headers = HTTPHeaders()
                                if let offered = head.headers.first(name: "Sec-WebSocket-Protocol") {
                                    let first = offered.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? offered
                                    headers.add(name: "Sec-WebSocket-Protocol", value: behaviour.forcedSubprotocol ?? first)
                                }
                                return channel.eventLoop.makeSucceededFuture(headers)
                            },
                            upgradePipelineHandler: { channel, _ in
                                channel.eventLoop.makeCompletedFuture {
                                    if mode == .webSocket {
                                        try channel.pipeline.syncOperations.addHandler(EchoWebSocketHandler(behaviour: behaviour))
                                    } else {
                                        try channel.pipeline.syncOperations.addHandler(BrokerWebSocketHandler(broker: broker))
                                    }
                                }
                            }
                        )
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                            withServerUpgrade: (upgraders: [upgrader], completionHandler: { context in
                                context.pipeline.removeHandler(name: "refuse", promise: nil)
                            })
                        )
                        try channel.pipeline.syncOperations.addHandler(RefusingHTTPHandler(), name: "refuse")
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async {
        broker.dropAll()
        webSocket.dropAll()
        try? await channel.close().get()
    }
}

/// What the WebSocket server does and saw.
final class WebSocketBehaviour: Sendable {
    struct State {
        var requests: [HTTPRequestHead] = []
        var mute = false
        var received: [WebSocketMessage] = []
        var channels: [any Channel] = []
        var forcedSubprotocol: String?
    }

    let state = NIOLockedValueBox(State())

    func record(_ head: HTTPRequestHead) { state.withLockedValue { $0.requests.append(head) } }
    var requests: [HTTPRequestHead] { state.withLockedValue { $0.requests } }
    var received: [WebSocketMessage] { state.withLockedValue { $0.received } }
    var forcedSubprotocol: String? {
        get { state.withLockedValue { $0.forcedSubprotocol } }
        set { state.withLockedValue { $0.forcedSubprotocol = newValue } }
    }

    func dropAll() {
        for channel in state.withLockedValue({ $0.channels }) { channel.close(promise: nil) }
    }
}

/// Answers a non-upgrade request with 403.
private final class RefusingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var head = HTTPResponseHead(version: .http1_1, status: .forbidden)
        head.headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}

/// Greets with "hello", then: echoes messages; "fragment" sends a text message in three frames; "close" closes
/// with 4000 "bye"; "big" sends 2048 bytes; "mute" stops answering pings; "drop" drops the connection.
private final class EchoWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let behaviour: WebSocketBehaviour

    init(behaviour: WebSocketBehaviour) { self.behaviour = behaviour }

    func handlerAdded(context: ChannelHandlerContext) {
        behaviour.state.withLockedValue { $0.channels.append(context.channel) }
        send(context: context, .text, ByteBuffer(string: "hello"))
    }

    private func send(context: ChannelHandlerContext, _ opcode: WebSocketOpcode, _ data: ByteBuffer, fin: Bool = true) {
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: fin, opcode: opcode, data: data)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.unmaskedData
        switch frame.opcode {
        case .text:
            let text = payload.readString(length: payload.readableBytes) ?? ""
            behaviour.state.withLockedValue { $0.received.append(.text(text)) }
            switch text {
            case "fragment":
                send(context: context, .text, ByteBuffer(string: "frag"), fin: false)
                send(context: context, .continuation, ByteBuffer(string: "men"), fin: false)
                send(context: context, .continuation, ByteBuffer(string: "ted"), fin: true)
            case "close":
                var data = ByteBuffer()
                data.writeInteger(UInt16(4000))
                data.writeString("bye")
                send(context: context, .connectionClose, data)
            case "big":
                send(context: context, .binary, ByteBuffer(repeating: 7, count: 2048))
            case "mute":
                behaviour.state.withLockedValue { $0.mute = true }
            case "drop":
                context.close(promise: nil)
            default:
                send(context: context, .text, ByteBuffer(string: text))
            }
        case .binary:
            behaviour.state.withLockedValue { $0.received.append(.binary(Data(payload.readableBytesView))) }
            send(context: context, .binary, payload)
        case .ping:
            if !behaviour.state.withLockedValue({ $0.mute }) { send(context: context, .pong, payload) }
        case .connectionClose:
            send(context: context, .connectionClose, payload)
            context.close(promise: nil)
        default:
            break
        }
    }
}

/// A small MQTT 3.1.1 broker: checks credentials, routes publishes to matching subscriptions, acknowledges
/// QoS 1, answers pings unless muted, and records what clients sent.
final class TestBroker: Sendable {
    struct Session {
        var write: @Sendable ([UInt8]) -> Void
        var close: @Sendable () -> Void
        var subscriptions: [String] = []
        var connect: MQTTConnect?
    }

    struct State {
        var sessions: [Int: Session] = [:]
        var nextSession = 0
        var nextPacketID: UInt16 = 0
        var connects: [MQTTConnect] = []
        var subscribes: [[MQTTSubscription]] = []
        var published: [MQTTMessage] = []
        var pubacks: [UInt16] = []
        var pingreqs = 0
        var mutePings = false
        var credentials: (username: String, password: String)?
        /// CONNACK goes out this long after CONNECT.
        var connackDelay: Duration?
        /// CONNACK goes out with a packet a broker never sends right behind it, in the same write.
        var connackThenGarbage = false
    }

    let state = NIOLockedValueBox(State())

    var connects: [MQTTConnect] { state.withLockedValue { $0.connects } }
    var subscribes: [[MQTTSubscription]] { state.withLockedValue { $0.subscribes } }
    var published: [MQTTMessage] { state.withLockedValue { $0.published } }
    var pubacks: [UInt16] { state.withLockedValue { $0.pubacks } }
    var pingreqs: Int { state.withLockedValue { $0.pingreqs } }
    var sessionCount: Int { state.withLockedValue { $0.sessions.count } }

    func open(write: @escaping @Sendable ([UInt8]) -> Void, close: @escaping @Sendable () -> Void) -> Int {
        state.withLockedValue { state in
            state.nextSession += 1
            state.sessions[state.nextSession] = Session(write: write, close: close)
            return state.nextSession
        }
    }

    func closed(_ id: Int) {
        _ = state.withLockedValue { $0.sessions.removeValue(forKey: id) }
    }

    func dropAll() {
        let sessions = state.withLockedValue { $0.sessions.values.map(\.close) }
        for close in sessions { close() }
    }

    /// Publishes to every client subscribed to a matching filter.
    func publish(_ message: MQTTMessage) {
        let targets = state.withLockedValue { state -> [(@Sendable ([UInt8]) -> Void, UInt16?)] in
            state.sessions.values.filter { $0.subscriptions.contains { MQTTTopic.matches(filter: $0, topic: message.topic) } }.map { session in
                var id: UInt16?
                if message.qos != .atMostOnce {
                    state.nextPacketID += 1
                    id = state.nextPacketID
                }
                return (session.write, id)
            }
        }
        for (write, id) in targets { write(MQTTPacket.publish(message, packetID: id, duplicate: false).encode()) }
    }

    func handle(_ packet: MQTTPacket, session id: Int) {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return }
        switch packet {
        case .connect(let connect):
            let (credentials, delay, garbage) = state.withLockedValue { state in
                state.connects.append(connect)
                state.sessions[id]?.connect = connect
                return (state.credentials, state.connackDelay, state.connackThenGarbage)
            }
            if let credentials, connect.username != credentials.username || connect.password != credentials.password {
                session.write(MQTTPacket.connack(sessionPresent: false, returnCode: 4).encode())
                session.close()
            } else {
                let connack = MQTTPacket.connack(sessionPresent: false, returnCode: 0).encode() + (garbage ? MQTTPacket.pingreq.encode() : [])
                if let delay {
                    let write = session.write
                    Task {
                        try? await Task.sleep(for: delay)
                        write(connack)
                    }
                } else {
                    session.write(connack)
                }
            }
        case .subscribe(let packetID, let subscriptions):
            state.withLockedValue { state in
                state.subscribes.append(subscriptions)
                for subscription in subscriptions where !subscription.topic.hasPrefix("forbidden") {
                    state.sessions[id]?.subscriptions.append(subscription.topic)
                }
            }
            let codes = subscriptions.map { $0.topic.hasPrefix("forbidden") ? 0x80 : min($0.qos.rawValue, 1) }
            session.write(MQTTPacket.suback(packetID: packetID, returnCodes: codes).encode())
        case .unsubscribe(let packetID, let topics):
            state.withLockedValue { $0.sessions[id]?.subscriptions.removeAll { topics.contains($0) } }
            session.write(MQTTPacket.unsuback(packetID).encode())
        case .publish(let message, let packetID, _):
            state.withLockedValue { $0.published.append(message) }
            if message.qos == .atLeastOnce, let packetID { session.write(MQTTPacket.puback(packetID).encode()) }
            publish(MQTTMessage(topic: message.topic, payload: message.payload, qos: message.qos, retain: false))
        case .puback(let packetID):
            state.withLockedValue { $0.pubacks.append(packetID) }
        case .pingreq:
            let mute = state.withLockedValue { state in
                state.pingreqs += 1
                return state.mutePings
            }
            if !mute { session.write(MQTTPacket.pingresp.encode()) }
        case .disconnect:
            session.close()
        default:
            break
        }
    }
}

private final class BrokerTCPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let broker: TestBroker
    var parser = MQTTPacketParser()
    var session = 0

    init(broker: TestBroker) { self.broker = broker }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        session = broker.open(
            write: { bytes in channel.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil) },
            close: { channel.close(promise: nil) }
        )
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        parser.append(unwrapInboundIn(data).readableBytesView)
        while let packet = try? parser.next() { broker.handle(packet, session: session) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        broker.closed(session)
        context.fireChannelInactive()
    }
}

private final class BrokerWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let broker: TestBroker
    var parser = MQTTPacketParser()
    var session = 0

    init(broker: TestBroker) { self.broker = broker }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        session = broker.open(
            write: { bytes in channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(bytes: bytes)), promise: nil) },
            close: { channel.close(promise: nil) }
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .continuation:
            parser.append(frame.unmaskedData.readableBytesView)
            while let packet = try? parser.next() { broker.handle(packet, session: session) }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        broker.closed(session)
        context.fireChannelInactive()
    }
}
