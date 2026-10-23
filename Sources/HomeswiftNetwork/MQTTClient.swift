import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The state of an MQTT client, as `MQTTConnection.states` reports it.
public enum MQTTConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(sessionPresent: Bool)
    /// The connection dropped (the reason, for the log); with automatic reconnection, `.connecting` follows.
    case connectionLost(String)
}

/// An MQTT client: the real one, or a fake broker in a plugin's tests.
public protocol MQTTConnection: Sendable {
    /// Connects and waits for the broker's CONNACK. Throws `MQTTError.connectionRefused` for bad credentials.
    func connect() async throws
    /// Sends DISCONNECT and closes; no reconnection follows.
    func disconnect() async
    /// Subscribes, and remembers the subscription to renew it on every reconnection. Before the first
    /// connection, or while reconnecting, it is only remembered.
    func subscribe(_ topic: String, qos: MQTTQoS) async throws
    func unsubscribe(_ topic: String) async throws
    /// Publishes. QoS 1 waits for the broker's PUBACK. Throws `MQTTError.notConnected` while disconnected.
    func publish(_ message: MQTTMessage) async throws
    /// Every message on the subscribed topics. Each access returns a new stream, from then on.
    var messages: AsyncStream<MQTTMessage> { get }
    /// The connection state, starting with the current one. Each access returns a new stream.
    var states: AsyncStream<MQTTConnectionState> { get }
}

extension MQTTConnection {
    public func subscribe(_ topic: String) async throws { try await subscribe(topic, qos: .atMostOnce) }

    public func publish(_ topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retain: Bool = false) async throws {
        try await publish(MQTTMessage(topic: topic, payload: payload, qos: qos, retain: retain))
    }

    public func publish(_ topic: String, string: String, qos: MQTTQoS = .atMostOnce, retain: Bool = false) async throws {
        try await publish(MQTTMessage(topic: topic, string: string, qos: qos, retain: retain))
    }
}

/// How an `MQTTClient` reaches its broker and introduces itself.
public struct MQTTConfiguration: Sendable {
    public enum Transport: Sendable {
        /// Plain TCP, `mqtt://` (1883).
        case tcp(host: String, port: Int = 1883)
        /// TLS, `mqtts://` (8883); AWS IoT mutual TLS with a client certificate in the options (443 with ALPN
        /// `x-amzn-mqtt-ca`).
        case tls(host: String, port: Int = 8883, options: TLSOptions = .system)
        /// A WebSocket with the `mqtt` subprotocol, `ws://` or `wss://`. The URL is asked for on every
        /// connection attempt, so a presigned URL (`AWSSignatureV4.presignIoTURL`) is fresh each time.
        case webSocket(url: @Sendable () async throws -> URL, options: WebSocket.Options = WebSocket.Options())

        /// A WebSocket to a fixed URL.
        public static func webSocket(_ url: URL, options: WebSocket.Options = WebSocket.Options()) -> Transport {
            .webSocket(url: { url }, options: options)
        }
    }

    /// Automatic reconnection after a connection drops: the delay doubles from `delay` to `maximumDelay`, with
    /// `jitter`. With `firstConnection`, `connect()` retries the same way until the broker answers (or
    /// `disconnect()`), instead of throwing the first failure; each failed attempt shows as `.connectionLost` on
    /// `states`.
    public struct Reconnect: Sendable, Equatable {
        public var delay: Duration
        public var maximumDelay: Duration
        public var jitter: Backoff.Jitter
        public var firstConnection: Bool

        public init(delay: Duration = .seconds(1), maximumDelay: Duration = .seconds(60), jitter: Backoff.Jitter = .none, firstConnection: Bool = false) {
            self.delay = delay
            self.maximumDelay = maximumDelay
            self.jitter = jitter
            self.firstConnection = firstConnection
        }

        public var backoff: Backoff { Backoff(initial: delay, maximum: maximumDelay, jitter: jitter) }
    }

    public var transport: Transport
    public var clientID: String
    public var username: String?
    public var password: String?
    /// Sent in CONNECT (whole seconds); a PINGREQ goes out every interval, and a broker silent for two is dead.
    public var keepAlive: Duration
    public var cleanSession: Bool
    public var will: MQTTMessage?
    /// 3.1.1 by default; `.v5` speaks MQTT 5 (a persistent session, `cleanSession: false`, asks the broker to keep
    /// it with no expiry, as 3.1.1 does).
    public var protocolVersion: MQTTProtocolVersion
    /// From the connection attempt to CONNACK.
    public var connectTimeout: Duration
    /// nil: a dropped connection stays down (the states stream says so).
    public var reconnect: Reconnect?
    /// Larger packets from the broker close the connection.
    public var maximumPacketSize: Int

    public init(
        transport: Transport, clientID: String, username: String? = nil, password: String? = nil, keepAlive: Duration = .seconds(60),
        cleanSession: Bool = true, will: MQTTMessage? = nil, protocolVersion: MQTTProtocolVersion = .v3_1_1,
        connectTimeout: Duration = .seconds(30), reconnect: Reconnect? = Reconnect(), maximumPacketSize: Int = 16 * 1024 * 1024
    ) {
        self.transport = transport
        self.clientID = clientID
        self.username = username
        self.password = password
        self.keepAlive = keepAlive
        self.cleanSession = cleanSession
        self.will = will
        self.protocolVersion = protocolVersion
        self.connectTimeout = connectTimeout
        self.reconnect = reconnect
        self.maximumPacketSize = maximumPacketSize
    }

    /// A broker URL as users write it: `mqtt://`, `tcp://`, `mqtts://`, `ssl://`, `ws://`, `wss://`, with the
    /// user name and password in it (`mqtt://user:pass@host:1883`). `tls` applies to the secure schemes.
    public init(url: URL, clientID: String, tls: TLSOptions = .system) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw MQTTError.invalidURL(url.absoluteString)
        }
        let transport: Transport
        switch scheme {
        case "mqtt", "tcp": transport = .tcp(host: host, port: url.port ?? 1883)
        case "mqtts", "ssl", "tls": transport = .tls(host: host, port: url.port ?? 8883, options: tls)
        case "ws", "wss":
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = nil
            components?.password = nil
            if components?.path.isEmpty ?? false { components?.path = "/mqtt" }
            guard let socketURL = components?.url else { throw MQTTError.invalidURL(url.absoluteString) }
            transport = .webSocket(socketURL, options: WebSocket.Options(tls: tls))
        default:
            throw MQTTError.invalidURL(url.absoluteString)
        }
        // `user` and `password` come decoded: decoding them again would turn a password's `%2541` into `A`.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        self.init(transport: transport, clientID: clientID, username: components?.user, password: components?.password)
    }
}

/// An MQTT 3.1.1 client on NIO (3.1 and 5 on request): TCP, TLS (client certificates, ALPN) and WebSocket; QoS 0
/// and 1 both ways (QoS 2 received), retained messages, a will, keep-alive, and automatic reconnection that renews
/// the subscriptions. With MQTT 5 it reads the reason codes (refused connections, subscriptions and publishes, a
/// DISCONNECT from the broker) and follows the broker's Server Keep Alive; it sends no topic aliases.
///
/// ```swift
/// var configuration = MQTTConfiguration(transport: .tcp(host: "192.168.1.20"), clientID: "homeswift-\(serial)",
///                                       username: serial, password: localPassword)
/// let client = MQTTClient(configuration)
/// Task { for await message in client.messages { handle(message.topic, message.payload) } }
/// try await client.connect()
/// try await client.subscribe("475/\(serial)/status/current", qos: .atLeastOnce)
/// try await client.publish("475/\(serial)/command", string: #"{"msg":"REQUEST-CURRENT-STATE"}"#)
/// ```
public actor MQTTClient: MQTTConnection {
    public nonisolated let configuration: MQTTConfiguration
    private nonisolated let group: any EventLoopGroup
    private nonisolated let messageBroadcast = Broadcast<MQTTMessage>()
    private nonisolated let stateBroadcast = Broadcast<MQTTConnectionState>(initial: .disconnected)

    private var transport: (any MQTTByteTransport)?
    private var connected = false
    /// Bumped on every connection attempt, so callbacks from an old connection do nothing.
    private var generation = 0
    private var wantsConnection = false
    private var parser = MQTTPacketParser()
    private var nextPacketID: UInt16 = 0
    private var pending: [UInt16: CheckedContinuation<MQTTPacket, any Error>] = [:]
    private var connack: CheckedContinuation<(sessionPresent: Bool, serverKeepAlive: UInt16?), any Error>?
    private var subscriptions: [MQTTSubscription] = []
    /// QoS 2 messages received but not yet released, delivered once.
    private var inboundQoS2: Set<UInt16> = []
    private var lastReceived = ContinuousClock.now
    /// When the PINGREQ still unanswered went out: the broker is dead when it says nothing for an interval after one.
    private var pingSent: ContinuousClock.Instant?
    private var readTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// The connection attempt in flight. `connect()` and the reconnection loop join it rather than start another,
    /// which would take over the one CONNACK continuation and leave the first attempt waiting forever.
    private var inFlight: (id: Int, task: Task<Void, any Error>)?
    private var attempts = 0

    public init(_ configuration: MQTTConfiguration, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.configuration = configuration
        self.group = group
        parser = MQTTPacketParser(limit: configuration.maximumPacketSize, version: configuration.protocolVersion)
    }

    private nonisolated var version: MQTTProtocolVersion { configuration.protocolVersion }

    public nonisolated var messages: AsyncStream<MQTTMessage> { messageBroadcast.stream() }
    public nonisolated var states: AsyncStream<MQTTConnectionState> { stateBroadcast.stream() }
    public var isConnected: Bool { connected }

    public func connect() async throws {
        if connected { return }
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        var attempt = 0
        while true {
            do {
                try await establish()
                return
            } catch {
                // With `Reconnect.firstConnection`, a failure waits and tries again while the connection is wanted.
                if let reconnect = configuration.reconnect, reconnect.firstConnection, wantsConnection, !Task.isCancelled {
                    stateBroadcast.yield(.connectionLost("\(error)"))
                    let delay = reconnect.backoff.delay(attempt: attempt)
                    attempt += 1
                    if (try? await Task.sleep(for: delay)) != nil, wantsConnection, !connected { continue }
                    if connected { return }
                }
                wantsConnection = false
                stateBroadcast.yield(.disconnected)
                throw error
            }
        }
    }

    public func disconnect() async {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        inFlight?.task.cancel()
        inFlight = nil
        generation += 1
        let transport = transport
        if connected { try? await transport?.send(MQTTPacket.disconnect().encode(version: version)) }
        tearDown(error: MQTTError.notConnected)
        await transport?.close()
        stateBroadcast.yield(.disconnected)
    }

    public func subscribe(_ topic: String, qos: MQTTQoS = .atMostOnce) async throws {
        subscriptions.removeAll { $0.topic == topic }
        subscriptions.append(MQTTSubscription(topic: topic, qos: qos))
        guard connected else { return }
        try await sendSubscribe([MQTTSubscription(topic: topic, qos: qos)])
    }

    public func unsubscribe(_ topic: String) async throws {
        subscriptions.removeAll { $0.topic == topic }
        guard connected else { return }
        let id = allocatePacketID()
        _ = try await request(.unsubscribe(packetID: id, [topic]), id: id)
    }

    public func publish(_ message: MQTTMessage) async throws {
        guard connected, let transport else { throw MQTTError.notConnected }
        switch message.qos {
        case .atMostOnce:
            try await transport.send(MQTTPacket.publish(message, packetID: nil, duplicate: false).encode(version: version))
        case .atLeastOnce, .exactlyOnce:
            // QoS 2 is sent as QoS 1: the devices this is for never need exactly-once delivery from the client.
            var message = message
            message.qos = .atLeastOnce
            let id = allocatePacketID()
            if case .puback(_, let code) = try await request(.publish(message, packetID: id, duplicate: false), id: id), code >= 0x80 {
                throw MQTTError.publishRefused(topic: message.topic, reasonCode: code)
            }
        }
    }

    // MARK: - Connection

    /// Connects, or waits for the attempt already in flight.
    private func establish() async throws {
        if let inFlight { return try await inFlight.task.value }
        attempts += 1
        let id = attempts
        let task = Task { try await self.attemptConnection(id: id) }
        inFlight = (id, task)
        try await task.value
    }

    private func attemptConnection(id: Int) async throws {
        defer { if inFlight?.id == id { inFlight = nil } }
        generation += 1
        let generation = generation
        stateBroadcast.yield(.connecting)
        let transport: any MQTTByteTransport
        switch configuration.transport {
        case .tcp(let host, let port):
            transport = try await MQTTSocketTransport.connect(host: host, port: port, tls: nil, timeout: configuration.connectTimeout, group: group)
        case .tls(let host, let port, let options):
            transport = try await MQTTSocketTransport.connect(host: host, port: port, tls: options, timeout: configuration.connectTimeout, group: group)
        case .webSocket(let url, var options):
            if options.subprotocols.isEmpty { options.subprotocols = ["mqtt"] }
            options.timeout = configuration.connectTimeout
            let socket = try await WebSocket.connect(to: try await url(), options: options, group: group)
            transport = MQTTWebSocketTransport(socket: socket)
        }
        guard generation == self.generation else {
            await transport.close()
            throw MQTTError.notConnected
        }
        self.transport = transport
        parser = MQTTPacketParser(limit: configuration.maximumPacketSize, version: configuration.protocolVersion)
        lastReceived = .now
        pingSent = nil
        let incoming = transport.incoming
        readTask = Task { [weak self] in
            var failure: (any Error)?
            do {
                for try await bytes in incoming {
                    guard let self else { return }
                    await self.received(bytes, generation: generation)
                }
            } catch {
                failure = error
            }
            await self?.connectionLost(generation: generation, error: failure ?? MQTTError.connectionLost)
        }

        let keepAlive = UInt16(clamping: max(configuration.keepAlive == .zero ? 0 : 1, Int(configuration.keepAlive.components.seconds)))
        var connect = MQTTConnect(
            version: configuration.protocolVersion, clientID: configuration.clientID, username: configuration.username,
            password: configuration.password, keepAlive: keepAlive, cleanSession: configuration.cleanSession, will: configuration.will
        )
        if configuration.protocolVersion == .v5 {
            // A 3.1.1 persistent session outlives the connection; in MQTT 5 that takes a Session Expiry Interval.
            if !configuration.cleanSession { connect.properties.entries.append((MQTTProperties.sessionExpiryInterval, .uint32(.max))) }
            connect.properties.entries.append((MQTTProperties.maximumPacketSize, .uint32(UInt32(clamping: configuration.maximumPacketSize))))
        }
        let connectBytes = MQTTPacket.connect(connect).encode()
        let timeout = configuration.connectTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.connackTimedOut(generation: generation) }
        }
        defer { timer.cancel() }
        let accepted: (sessionPresent: Bool, serverKeepAlive: UInt16?)
        do {
            accepted = try await withCheckedThrowingContinuation { continuation in
                connack = continuation
                Task { [weak self] in
                    do {
                        try await transport.send(connectBytes)
                    } catch {
                        await self?.connectionLost(generation: generation, error: error)
                    }
                }
            }
        } catch {
            // Unless a teardown (disconnect, a lost connection) already forgot this connection.
            if generation == self.generation {
                self.generation += 1
                tearDown(error: error)
            }
            await transport.close()
            throw error
        }
        // Torn down between the CONNACK and here (the broker closed right after it, or disconnect()): not connected.
        guard generation == self.generation else {
            await transport.close()
            throw MQTTError.connectionLost
        }
        connected = true
        stateBroadcast.yield(.connected(sessionPresent: accepted.sessionPresent))
        // MQTT 5: the broker may impose its own keep-alive, which then replaces the one sent.
        startKeepAlive(generation: generation, interval: accepted.serverKeepAlive.map { .seconds(Int($0)) } ?? configuration.keepAlive)
        if !subscriptions.isEmpty {
            // Renewed in one SUBSCRIBE: the broker forgot them with a clean session, and renewing is harmless otherwise.
            try? await sendSubscribe(subscriptions)
        }
    }

    private func sendSubscribe(_ subscriptions: [MQTTSubscription]) async throws {
        let id = allocatePacketID()
        guard case .suback(_, let codes, _) = try await request(.subscribe(packetID: id, subscriptions), id: id) else { return }
        // 0x80 in 3.1.1; any reason code from 0x80 in MQTT 5.
        for (subscription, code) in zip(subscriptions, codes) where code >= 0x80 {
            self.subscriptions.removeAll { $0.topic == subscription.topic }
            throw MQTTError.subscriptionRefused(topic: subscription.topic)
        }
    }

    /// Sends a packet and waits for its acknowledgement (PUBACK, SUBACK, UNSUBACK).
    private func request(_ packet: MQTTPacket, id: UInt16) async throws -> MQTTPacket {
        guard let transport else { throw MQTTError.notConnected }
        let generation = generation
        let bytes = packet.encode(version: version)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await transport.send(bytes)
                } catch {
                    await self?.connectionLost(generation: generation, error: error)
                }
            }
        }
    }

    private func allocatePacketID() -> UInt16 {
        repeat {
            nextPacketID = nextPacketID == UInt16.max ? 1 : nextPacketID + 1
        } while pending[nextPacketID] != nil
        return nextPacketID
    }

    private func received(_ bytes: [UInt8], generation: Int) async {
        guard generation == self.generation else { return }
        lastReceived = .now
        parser.append(bytes)
        do {
            while let packet = try parser.next() {
                try await handle(packet)
            }
        } catch {
            connectionLost(generation: generation, error: error)
        }
    }

    private func handle(_ packet: MQTTPacket) async throws {
        switch packet {
        case .connack(let sessionPresent, let code, let properties):
            let continuation = connack
            connack = nil
            if code == 0 {
                continuation?.resume(returning: (sessionPresent, properties.uint16(MQTTProperties.serverKeepAlive)))
            } else {
                continuation?.resume(throwing: MQTTError.connectionRefused(code: code))
            }
        case .publish(let message, let id, _, _):
            switch message.qos {
            case .atMostOnce:
                messageBroadcast.yield(message)
            case .atLeastOnce:
                messageBroadcast.yield(message)
                if let id { try await transport?.send(MQTTPacket.puback(id).encode(version: version)) }
            case .exactlyOnce:
                guard let id else { return }
                if inboundQoS2.insert(id).inserted { messageBroadcast.yield(message) }
                try await transport?.send(MQTTPacket.pubrec(id).encode(version: version))
            }
        case .pubrel(let id):
            inboundQoS2.remove(id)
            try await transport?.send(MQTTPacket.pubcomp(id).encode(version: version))
        case .puback(let id, _), .unsuback(let id, _), .pubcomp(let id):
            pending.removeValue(forKey: id)?.resume(returning: packet)
        case .suback(let id, _, _):
            pending.removeValue(forKey: id)?.resume(returning: packet)
        case .pubrec(let id):
            try await transport?.send(MQTTPacket.pubrel(id).encode(version: version))
        case .pingresp:
            break
        case .disconnect(let code, let properties) where version == .v5:
            // MQTT 5 brokers say why they close (session taken over, shutting down…); reconnection follows as usual.
            throw MQTTError.disconnectedByBroker(reasonCode: code, reason: properties.string(MQTTProperties.reasonString))
        case .connect, .subscribe, .unsubscribe, .pingreq, .disconnect:
            throw MQTTError.protocolError("unexpected packet from the broker")
        }
    }

    private func startKeepAlive(generation: Int, interval: Duration) {
        keepAliveTask?.cancel()
        guard interval > .zero else { return }
        let interval = max(interval, .seconds(1))
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.keepAliveTick(generation: generation, interval: interval)
            }
        }
    }

    private func keepAliveTick(generation: Int, interval: Duration) async {
        guard generation == self.generation, connected, let transport else { return }
        // Silence after our last ping, not since the last packet: a tick a busy machine runs late is no dead broker.
        if let sent = pingSent, lastReceived < sent, ContinuousClock.now - sent >= interval {
            connectionLost(generation: generation, error: MQTTError.keepAliveTimeout)
            return
        }
        pingSent = .now
        try? await transport.send(MQTTPacket.pingreq.encode(version: version))
    }

    private func connackTimedOut(generation: Int) {
        guard generation == self.generation, let continuation = connack else { return }
        connack = nil
        continuation.resume(throwing: MQTTError.timeout)
    }

    private func connectionLost(generation: Int, error: any Error) {
        guard generation == self.generation else { return }
        self.generation += 1
        let wasConnected = connected
        let transport = transport
        tearDown(error: error)
        Task { await transport?.close() }
        guard wasConnected else { return }
        stateBroadcast.yield(.connectionLost("\(error)"))
        if wantsConnection, let reconnect = configuration.reconnect {
            scheduleReconnect(reconnect)
        } else {
            wantsConnection = false
            stateBroadcast.yield(.disconnected)
        }
    }

    /// Fails everything waiting on the connection and forgets it.
    private func tearDown(error: any Error) {
        connected = false
        transport = nil
        readTask?.cancel()
        readTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        inboundQoS2 = []
        connack?.resume(throwing: error)
        connack = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: MQTTError.connectionLost) }
    }

    private func scheduleReconnect(_ reconnect: MQTTConfiguration.Reconnect) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let backoff = reconnect.backoff
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: backoff.delay(attempt: attempt))
                guard !Task.isCancelled, let self else { return }
                if await self.attemptReconnect() { return }
                attempt += 1
            }
        }
    }

    private func attemptReconnect() async -> Bool {
        guard wantsConnection else { return true }
        if connected { return true }
        do {
            try await establish()
            return true
        } catch {
            // disconnect() while this attempt ran already said `.disconnected`; connect() took over and reports itself.
            guard wantsConnection, !Task.isCancelled else { return true }
            stateBroadcast.yield(.connectionLost("\(error)"))
            return false
        }
    }
}

/// Fans values out to any number of `AsyncStream`s.
final class Broadcast<Element: Sendable>: Sendable {
    private struct State {
        var next = 0
        var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
        var current: Element?
    }

    private let state: NIOLockedValueBox<State>

    /// With `initial`, every new stream starts with the latest value.
    init(initial: Element? = nil) {
        state = NIOLockedValueBox(State(current: initial))
    }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1024))
        let id = state.withLockedValue { state -> Int in
            state.next += 1
            state.continuations[state.next] = continuation
            if let current = state.current { continuation.yield(current) }
            return state.next
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLockedValue { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ element: Element) {
        let continuations = state.withLockedValue { state in
            if state.current != nil { state.current = element }
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield(element) }
    }
}
