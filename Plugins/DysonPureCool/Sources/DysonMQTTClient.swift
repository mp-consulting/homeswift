import Foundation
import HomeswiftNetwork

enum DysonMQTTError: Error, CustomStringConvertible, Equatable {
    /// CONNACK with a non-zero return code (MQTT 3.1.1 numbering: 1 protocol, 2 identifier, 3 server,
    /// 4 user name or password, 5 not authorized).
    case refused(code: Int)
    case timeout(Duration)
    case unreachable(String)
    case notConnected

    var description: String {
        switch self {
        case .refused(let code):
            // The texts of mqtt.js, which the Assistant's notes rely on.
            switch code {
            case 1: "Connection refused: Unacceptable protocol version"
            case 2: "Connection refused: Identifier rejected"
            case 3: "Connection refused: Server unavailable"
            case 4: "Connection refused: Bad username or password"
            case 5: "Connection refused: Not authorized"
            default: "Connection refused: return code \(code)"
            }
        case .timeout(let duration): "Connection timeout after \(duration.components.seconds * 1000)ms"
        case .unreachable(let reason): reason
        case .notConnected: "Not connected to MQTT broker"
        }
    }
}

/// The MQTT session with one device, as the Homebridge plugin's `DysonMqttClient`: the CONNECT variant ladder
/// for picky firmware, the status subscription and command topic, and reconnection with exponential backoff
/// that gives up after five attempts (the plugin then retries every five minutes).
///
/// The broker is the device itself (TCP port 1883): a CONNECT with the serial number as user name and the
/// local credential as password, one subscription, QoS 0 publishes. Each attempt is a fresh connection from
/// `mqtt` (an `MQTTClient`, a fake broker in tests) with its own reconnection off.
actor DysonMQTTClient {
    typealias Connect = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    /// One CONNECT combination. Some firmware (notably Big+Quiet) refuses the historical client id, protocol
    /// level or clean session at CONNACK; the ladder tries the next combination on those refusals only.
    struct Variant: Sendable, Equatable {
        enum ClientID: Sendable { case `default`, short }
        var label: String
        var clientID: ClientID
        var protocolLevel: Int
        var clean: Bool
    }

    static let variants: [Variant] = [
        Variant(label: "default", clientID: .default, protocolLevel: 4, clean: true),
        Variant(label: "short-id", clientID: .short, protocolLevel: 4, clean: true),
        Variant(label: "short-id-persistent", clientID: .short, protocolLevel: 4, clean: false),
        Variant(label: "mqtt5-short-id", clientID: .short, protocolLevel: 5, clean: true),
        Variant(label: "mqtt3.1-short-id", clientID: .short, protocolLevel: 3, clean: true),
    ]

    static let port = 1883
    static let keepAlive: Duration = .seconds(30)
    static let maxReconnectAttempts = 5
    /// 1 s, 2 s, 4 s… up to 30 s.
    static let reconnectBackoff = Backoff(initial: .seconds(1), maximum: .seconds(30))

    struct Settings: Sendable {
        var host: String
        var serial: String
        var credentials: String
        var productType: String
        var timeout: Duration = .seconds(10)
        var autoReconnect = true
    }

    enum Event: Sendable {
        case connected
        case disconnected
        case message(topic: String, payload: Data)
        case reconnecting(attempt: Int)
        /// Every reconnection attempt failed: the device is offline.
        case reconnectFailed
        case error(String)
    }

    let settings: Settings
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let mqtt: Connect
    private let backoff: @Sendable (Int) -> Duration

    private var connection: (any MQTTConnection)?
    /// Bumped on every connection, so a loss reported by an old one does nothing.
    private var generation = 0
    private var readTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    private var connected = false
    private var subscribedTopics: [String] = []
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private var intentionalDisconnect = false
    private var lastSuccessfulVariant: Int?
    /// Bumped by every `disconnect()`: a CONNECT still in flight when it changes is closed, not kept.
    private var disconnects = 0
    private(set) var activeVariant: Variant?

    init(settings: Settings, mqtt: @escaping Connect, backoff: @escaping @Sendable (Int) -> Duration = DysonMQTTClient.exponentialBackoff) {
        self.settings = settings
        self.mqtt = mqtt
        self.backoff = backoff
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    @Sendable static func exponentialBackoff(attempt: Int) -> Duration {
        reconnectBackoff.delay(attempt: attempt)
    }

    var statusTopic: String { MessageCodec.statusTopic(productType: settings.productType, serial: settings.serial) }
    var commandTopic: String { MessageCodec.commandTopic(productType: settings.productType, serial: settings.serial) }
    var isConnected: Bool { connected && connection != nil }
    var topics: [String] { subscribedTopics }

    static func clientID(_ strategy: Variant.ClientID, serial: String, now: Date = Date()) -> String {
        switch strategy {
        case .short: serial
        case .default: "homebridge_\(serial)_\(Int(now.timeIntervalSince1970 * 1000))"
        }
    }

    /// CONNACK refusals mean "wrong CONNECT shape, try another"; timeouts and network errors do not climb
    /// the ladder.
    static func isRecoverable(_ error: any Error) -> Bool {
        if case DysonMQTTError.refused = error { return true }
        return false
    }

    /// Connects, trying the variants in order from the one that worked last.
    func connect() async throws {
        if isConnected { return }
        // A fresh connect() re-enables reconnection after an earlier disconnect().
        if !isReconnecting { intentionalDisconnect = false }
        let start = lastSuccessfulVariant ?? 0
        let epoch = disconnects
        var lastError: (any Error)?
        for offset in 0..<Self.variants.count {
            let index = (start + offset) % Self.variants.count
            let variant = Self.variants[index]
            do {
                try await connect(with: variant, epoch: epoch)
                lastSuccessfulVariant = index
                activeVariant = variant
                return
            } catch {
                lastError = error
                guard Self.isRecoverable(error) else { throw error }
            }
        }
        throw lastError ?? DysonMQTTError.unreachable("All MQTT connect variants exhausted")
    }

    /// One CONNECT. A `disconnect()` while it is in flight (`epoch` changed) closes the new connection and
    /// throws `notConnected`, so a session opened after a stop does not stay up.
    private func connect(with variant: Variant, epoch: Int) async throws {
        let version: MQTTProtocolVersion
        switch variant.protocolLevel {
        case 3: version = .v3_1
        case 4: version = .v3_1_1
        default:
            // MQTT 3.1 and 3.1.1 only. Answering as the broker would ("unacceptable protocol version") lets the
            // ladder move on to the next combination.
            throw DysonMQTTError.refused(code: 1)
        }
        let timeout = settings.timeout
        let opened: any MQTTConnection
        do {
            opened = try await mqtt(MQTTConfiguration(
                transport: .tcp(host: settings.host, port: Self.port), clientID: Self.clientID(variant.clientID, serial: settings.serial),
                username: settings.serial, password: settings.credentials, keepAlive: Self.keepAlive, cleanSession: variant.clean,
                protocolVersion: version, connectTimeout: timeout, reconnect: nil))
        } catch {
            throw Self.failure(error, timeout: timeout)
        }
        guard disconnects == epoch else {
            await opened.disconnect()
            throw DysonMQTTError.notConnected
        }
        // Taken before connecting, so nothing that follows the CONNACK is missed.
        let messages = opened.messages
        let states = opened.states
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await opened.connect()
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return false
                }
                defer { group.cancelAll() }
                guard try await group.next() == true else { throw DysonMQTTError.timeout(timeout) }
            }
        } catch {
            // Also drops a connection that lands after the deadline.
            await opened.disconnect()
            throw Self.failure(error, timeout: timeout)
        }
        guard disconnects == epoch else {
            await opened.disconnect()
            throw DysonMQTTError.notConnected
        }
        cleanupConnection()
        generation += 1
        let generation = generation
        connection = opened
        connected = true
        reconnectAttempts = 0
        isReconnecting = false
        continuation.yield(.connected)
        let continuation = continuation
        readTasks = [
            Task {
                for await message in messages {
                    continuation.yield(.message(topic: message.topic, payload: message.payload))
                }
            },
            Task { [weak self] in
                // The stream starts with the state when it was taken, before the CONNECT: only a loss after the
                // connection counts.
                var connected = false
                for await state in states {
                    switch state {
                    case .connected: connected = true
                    case .connectionLost, .disconnected:
                        guard connected else { continue }
                        await self?.connectionClosed(generation: generation)
                        return
                    case .connecting: continue
                    }
                }
            },
        ]
        // Topics are recorded after a successful subscribe and cleared on an intentional disconnect, so any
        // here means this is a reconnection.
        if !subscribedTopics.isEmpty {
            do {
                try await resubscribe()
            } catch {
                continuation.yield(.error("\(error)"))
            }
        }
    }

    /// A failed CONNECT as the mqtt.js texts: the broker's refusal, the deadline, or why the device is unreachable.
    private static func failure(_ error: any Error, timeout: Duration) -> any Error {
        switch error {
        case is DysonMQTTError: error
        case MQTTError.connectionRefused(let code): DysonMQTTError.refused(code: Int(code))
        case MQTTError.timeout: DysonMQTTError.timeout(timeout)
        default: DysonMQTTError.unreachable("\(error)")
        }
    }

    private func connectionClosed(generation: Int) {
        guard generation == self.generation, connection != nil else { return }
        let wasConnected = connected
        connection = nil
        connected = false
        for task in readTasks { task.cancel() }
        readTasks = []
        if wasConnected, !intentionalDisconnect, !isReconnecting {
            continuation.yield(.disconnected)
            handleReconnection()
        }
    }

    /// Disconnects; an intentional disconnect also stops reconnection and forgets the topics.
    func disconnect(intentional: Bool = true) async {
        disconnects += 1
        if intentional {
            intentionalDisconnect = true
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        if let connection {
            self.connection = nil
            await connection.disconnect()
        }
        cleanup()
    }

    /// Ends the stream of events; the client is not used afterwards.
    func finish() {
        continuation.finish()
    }

    func subscribe(_ topic: String) async throws {
        guard isConnected, let connection else { throw DysonMQTTError.notConnected }
        do {
            try await connection.subscribe(topic, qos: .atMostOnce)
        } catch {
            throw DysonMQTTError.unreachable("Failed to subscribe to \(topic): \(error)")
        }
        if !subscribedTopics.contains(topic) { subscribedTopics.append(topic) }
    }

    func publish(_ topic: String, payload: Data) async throws {
        guard isConnected, let connection else { throw DysonMQTTError.notConnected }
        do {
            try await connection.publish(topic, payload: payload)
        } catch MQTTError.notConnected {
            throw DysonMQTTError.unreachable("Failed to publish to \(topic): \(DysonMQTTError.notConnected)")
        } catch {
            throw DysonMQTTError.unreachable("Failed to publish to \(topic): \(error)")
        }
    }

    func subscribeToStatus() async throws { try await subscribe(statusTopic) }
    func publishCommand(_ payload: Data) async throws { try await publish(commandTopic, payload: payload) }
    func requestCurrentState() async throws { try await publishCommand(MessageCodec.requestCurrentState()) }
    func requestEnvironment() async throws { try await publishCommand(MessageCodec.requestEnvironment()) }

    private func resubscribe() async throws {
        guard let connection else { return }
        var failures: [String] = []
        for topic in subscribedTopics {
            do {
                try await connection.subscribe(topic, qos: .atMostOnce)
            } catch {
                failures.append("Failed to resubscribe to \(topic): \(error)")
            }
        }
        if !failures.isEmpty {
            throw DysonMQTTError.unreachable("Failed to resubscribe to \(failures.count) topic(s): \(failures.joined(separator: "; "))")
        }
    }

    private func handleReconnection() {
        guard settings.autoReconnect, !intentionalDisconnect, !isReconnecting else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            continuation.yield(.reconnectFailed)
            return
        }
        isReconnecting = true
        let attempt = reconnectAttempts
        let delay = backoff(attempt)
        continuation.yield(.reconnecting(attempt: attempt + 1))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.reconnect()
        }
    }

    private func reconnect() async {
        guard !Task.isCancelled, !intentionalDisconnect else {
            isReconnecting = false
            return
        }
        reconnectAttempts += 1
        cleanupConnection()
        do {
            try await connect()
            // disconnect() asked for while the attempt was in flight drops the new connection.
            if intentionalDisconnect { await disconnect() }
        } catch {
            isReconnecting = false
            if reconnectAttempts < Self.maxReconnectAttempts {
                handleReconnection()
            } else {
                continuation.yield(.reconnectFailed)
            }
        }
    }

    private func cleanupConnection() {
        for task in readTasks { task.cancel() }
        readTasks = []
        if let old = connection {
            connection = nil
            Task { await old.disconnect() }
        }
        connected = false
    }

    private func cleanup() {
        cleanupConnection()
        isReconnecting = false
        activeVariant = nil
        // Topics and the variant that worked are kept for reconnections within a session.
        if intentionalDisconnect {
            subscribedTopics.removeAll()
            reconnectAttempts = 0
            lastSuccessfulVariant = nil
        }
    }
}
