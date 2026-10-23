import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// An MQTT broker in memory behind the `MQTTConnection` a plugin uses: it records what the plugin publishes and
/// subscribes, and a test pushes messages and connection states to the plugin. No socket, no broker.
///
/// ```swift
/// let mqtt = FakeMQTTConnection()
/// let plugin = MyPlugin(..., mqtt: mqtt)
/// mqtt.receive("device/1/status", string: #"{"on":true}"#)
/// #expect(mqtt.published(on: "device/1/command").count == 1)
/// ```
public final class FakeMQTTConnection: MQTTConnection {
    private struct State {
        var connected = false
        var connectCount = 0
        var connectFailures: [any Error] = []
        var published: [MQTTMessage] = []
        var subscriptions: [String: MQTTQoS] = [:]
        var current: MQTTConnectionState = .disconnected
        var next = 0
        var messageReaders: [Int: AsyncStream<MQTTMessage>.Continuation] = [:]
        var stateReaders: [Int: AsyncStream<MQTTConnectionState>.Continuation] = [:]
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    // MARK: MQTTConnection

    public func connect() async throws {
        let failure = state.withLockedValue { state -> (any Error)? in
            state.connectCount += 1
            return state.connectFailures.isEmpty ? nil : state.connectFailures.removeFirst()
        }
        if let failure { throw failure }
        setState(.connected(sessionPresent: false))
    }

    public func disconnect() async { setState(.disconnected) }

    public func subscribe(_ topic: String, qos: MQTTQoS) async throws {
        state.withLockedValue { $0.subscriptions[topic] = qos }
    }

    public func unsubscribe(_ topic: String) async throws {
        _ = state.withLockedValue { $0.subscriptions.removeValue(forKey: topic) }
    }

    /// Recorded; throws `MQTTError.notConnected` while disconnected, as the real client does.
    public func publish(_ message: MQTTMessage) async throws {
        try state.withLockedValue { state in
            guard state.connected else { throw MQTTError.notConnected }
            state.published.append(message)
        }
    }

    public var messages: AsyncStream<MQTTMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: MQTTMessage.self)
        let id = state.withLockedValue { state -> Int in
            state.next += 1
            state.messageReaders[state.next] = continuation
            return state.next
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLockedValue { _ = $0.messageReaders.removeValue(forKey: id) } }
        return stream
    }

    public var states: AsyncStream<MQTTConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: MQTTConnectionState.self)
        let id = state.withLockedValue { state -> Int in
            state.next += 1
            state.stateReaders[state.next] = continuation
            continuation.yield(state.current)
            return state.next
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLockedValue { _ = $0.stateReaders.removeValue(forKey: id) } }
        return stream
    }

    // MARK: For tests

    /// Every message published, in order.
    public var published: [MQTTMessage] { state.withLockedValue { $0.published } }
    /// The messages published on `topic`, as text.
    public func published(on topic: String) -> [String] { published.filter { $0.topic == topic }.compactMap(\.string) }
    /// The current subscriptions and their QoS.
    public var subscriptions: [String: MQTTQoS] { state.withLockedValue { $0.subscriptions } }
    public var isConnected: Bool { state.withLockedValue { $0.connected } }
    /// How many times `connect()` was called.
    public var connectCount: Int { state.withLockedValue { $0.connectCount } }

    /// The next `connect()` calls throw these errors, one each, before one succeeds.
    public func failConnects(with errors: [any Error]) {
        state.withLockedValue { $0.connectFailures.append(contentsOf: errors) }
    }

    /// A message from the broker, to every `messages` reader. Delivered whatever the subscriptions: the test decides.
    public func receive(_ message: MQTTMessage) {
        for reader in state.withLockedValue({ Array($0.messageReaders.values) }) { reader.yield(message) }
    }

    public func receive(_ topic: String, string: String) { receive(MQTTMessage(topic: topic, string: string)) }
    public func receive(_ topic: String, payload: Data) { receive(MQTTMessage(topic: topic, payload: payload)) }

    /// Changes the connection state (a drop: `.connectionLost("reason")`), to every `states` reader.
    public func setState(_ newState: MQTTConnectionState) {
        let readers = state.withLockedValue { state in
            state.current = newState
            if case .connected = newState { state.connected = true } else { state.connected = false }
            return Array(state.stateReaders.values)
        }
        for reader in readers { reader.yield(newState) }
    }
}

/// A WebSocket in memory behind the `WebSocketConnection` a plugin uses: it records what the plugin sends, and a
/// test pushes messages, a close frame or a drop.
public final class FakeWebSocket: WebSocketConnection {
    public let url: URL?
    public let messages: AsyncThrowingStream<WebSocketMessage, any Error>
    private let continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation

    private struct State {
        var sent: [WebSocketMessage] = []
        var pings = 0
        var open = true
        var closeCode: UInt16?
        var closeReason: String?
        var onSend: (@Sendable (WebSocketMessage) -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    public init(url: URL? = nil) {
        self.url = url
        (messages, continuation) = AsyncThrowingStream.makeStream(of: WebSocketMessage.self, throwing: (any Error).self)
    }

    // MARK: WebSocketConnection

    /// Recorded, then given to `onSend`; throws `WebSocketError.notConnected` once closed.
    public func send(_ message: WebSocketMessage) async throws {
        let onSend = try state.withLockedValue { state in
            guard state.open else { throw WebSocketError.notConnected }
            state.sent.append(message)
            return state.onSend
        }
        onSend?(message)
    }

    public func ping(timeout: Duration) async throws {
        try state.withLockedValue { state in
            guard state.open else { throw WebSocketError.notConnected }
            state.pings += 1
        }
    }

    /// Closes as a server would answer: the close frame echoed, the stream finished.
    public func close(code: UInt16, reason: String) async {
        finish(code: code, reason: reason)
    }

    public var closeCode: UInt16? { state.withLockedValue { $0.closeCode } }
    public var closeReason: String? { state.withLockedValue { $0.closeReason } }

    // MARK: For tests

    /// Every message sent, in order.
    public var sent: [WebSocketMessage] { state.withLockedValue { $0.sent } }
    /// The text messages sent.
    public var sentText: [String] { sent.compactMap(\.text) }
    public var pingCount: Int { state.withLockedValue { $0.pings } }
    public var isOpen: Bool { state.withLockedValue { $0.open } }

    /// Called with each message sent, to answer it (`socket.receive(...)`) as the server would.
    public func onSend(_ handler: (@Sendable (WebSocketMessage) -> Void)?) {
        state.withLockedValue { $0.onSend = handler }
    }

    /// A message from the server.
    public func receive(_ message: WebSocketMessage) { continuation.yield(message) }
    public func receive(text: String) { receive(.text(text)) }
    public func receive(binary: Data) { receive(.binary(binary)) }

    /// The server closes with a close frame: the stream ends, `closeCode` is set.
    public func finish(code: UInt16 = 1000, reason: String = "") {
        let first = state.withLockedValue { state -> Bool in
            guard state.open else { return false }
            state.open = false
            state.closeCode = code
            state.closeReason = reason
            return true
        }
        if first { continuation.finish() }
    }

    /// The connection drops without a close frame: the stream throws `error`.
    public func drop(_ error: any Error = WebSocketError.connectionLost) {
        let first = state.withLockedValue { state -> Bool in
            defer { state.open = false }
            return state.open
        }
        if first { continuation.finish(throwing: error) }
    }
}
