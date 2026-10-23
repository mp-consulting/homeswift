import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// The MQTT publishing of the Homebridge plugin (`MqttClient` of homebridge-plugin-utils): every topic is
/// `<base topic>/<device MAC>/<topic>`; `<topic>/get` with `true` publishes the current value, `<topic>/set`
/// changes it. docs/mqtt.md of the Homebridge plugin lists the topics; they are the same here.
final class ProtectMQTTClient: Sendable {
    static let defaultReconnectInterval = 60

    /// TLS failures that retrying will not fix: the message says how to fix them.
    static let tlsVerificationErrors: Set<String> = [
        "CERT_HAS_EXPIRED", "DEPTH_ZERO_SELF_SIGNED_CERT", "ERR_TLS_CERT_ALTNAME_INVALID", "SELF_SIGNED_CERT_IN_CHAIN", "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
        "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
    ]

    typealias Handler = @Sendable (Data) async -> Void

    let brokerURL: String
    let topicPrefix: String
    private let log: ProtectLog
    private let reconnectInterval: Int
    private let connection: (any MQTTConnection)?
    private let subscriptions = NIOLockedValueBox<[String: Handler]>([:])
    /// Whether the broker is connected, and whether it ever was (failures before are explained, as mqtt.js's
    /// first connection errors were).
    private let connectionState = NIOLockedValueBox((isConnected: false, hasConnected: false))
    private let tasks = TaskBag()
    /// Publishes and subscriptions go out in the order they are made.
    private enum Operation: Sendable {
        case publish(String, Data)
        case subscribe(String)
        case unsubscribe(String)
    }
    private let operations: AsyncStream<Operation>.Continuation
    private let worker: Task<Void, Never>?
    /// Operations wait for the broker, as mqtt.js queues them while offline: a device's readings published at start, before the
    /// first connection, or after a drop, would otherwise be lost (the connection refuses them while disconnected).
    private let gate: BrokerGate
    /// Operations kept while the broker is away; the oldest go past this many.
    static let queueLimit = 1000

    /// `connect` makes the connection (`MQTTClient` in a build, a fake in tests).
    init(brokerURL: String, topicPrefix: String, log: ProtectLog, reconnectInterval: Int = ProtectMQTTClient.defaultReconnectInterval, verifyTLS: Bool = true,
         connect: @Sendable (MQTTConfiguration) -> any MQTTConnection) {
        self.brokerURL = brokerURL
        self.topicPrefix = topicPrefix
        self.log = log
        self.reconnectInterval = reconnectInterval
        var connection: (any MQTTConnection)?
        do {
            let url = try MQTTBrokerURL.validate(brokerURL)
            var configuration = try MQTTConfiguration(url: url, clientID: "homeswift-unifi-protect-" + String(UInt32.random(in: 0...UInt32.max), radix: 16),
                                                      tls: verifyTLS ? .system : TLSOptions(trust: .any))
            // Reconnection every `reconnectInterval` as the Homebridge plugin did, the first connection included.
            let interval = Duration.seconds(reconnectInterval)
            configuration.reconnect = MQTTConfiguration.Reconnect(delay: interval, maximumDelay: interval, firstConnection: true)
            connection = connect(configuration)
        } catch ProtectMQTTURLError.missingProtocol {
            log.error("MQTT Broker: Invalid URL provided: \(Self.redact(brokerURL)).")
        } catch ProtectMQTTURLError.unsupportedProtocol(let scheme) {
            log.error("MQTT Broker: Unsupported protocol: \(scheme). Only mqtt://, mqtts://, tcp://, and ssl:// broker URLs are supported: \(Self.redact(brokerURL)).")
        } catch {
            log.error("MQTT Broker: Error: \(error).")
        }
        self.connection = connection
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self, bufferingPolicy: .bufferingNewest(Self.queueLimit))
        operations = continuation
        let gate = BrokerGate()
        self.gate = gate
        worker = connection.map { connection in
            Task {
                for await operation in stream {
                    await gate.wait()
                    switch operation {
                    case .publish(let topic, let payload): try? await connection.publish(MQTTMessage(topic: topic, payload: payload))
                    case .subscribe(let topic): try? await connection.subscribe(topic, qos: .atMostOnce)
                    case .unsubscribe(let topic): try? await connection.unsubscribe(topic)
                    }
                }
            }
        }
        guard let connection else { return }
        let states = connection.states, messages = connection.messages
        tasks.add { [weak self] in
            for await state in states { await self?.handle(state) }
        }
        tasks.add { [weak self] in
            for await message in messages {
                if let handler = self?.subscriptions.withLockedValue({ $0[message.topic] }) { await handler(message.payload) }
            }
        }
        tasks.add { try? await connection.connect() }
    }

    /// The broker URL without the credentials it may carry, for the log.
    static func redact(_ url: String) -> String {
        guard let at = url.lastIndex(of: "@") else { return url }
        var scheme = ""
        if let match = url.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:/*", options: .regularExpression) { scheme = String(url[match]) }
        return scheme + "REDACTED" + url[at...]
    }

    private func handle(_ state: MQTTConnectionState) async {
        switch state {
        case .connected:
            connectionState.withLockedValue { $0 = (true, true) }
            gate.open()
            log.info("MQTT Broker: Connected to \(Self.redact(brokerURL)) (topic: \(topicPrefix)).")
        case .disconnected:
            closed()
        case .connectionLost(let reason):
            let hadConnected = closed()
            await failed(code: hadConnected ? nil : Self.code(of: reason), message: reason)
        case .connecting:
            break
        }
    }

    /// The connection closed; returns whether the broker was ever connected.
    @discardableResult
    private func closed() -> Bool {
        gate.close()
        let (wasConnected, hasConnected) = connectionState.withLockedValue { state in
            defer { state.isConnected = false }
            return state
        }
        if wasConnected { log.info("MQTT Broker: Connection closed.") }
        return hasConnected
    }

    private func failed(code: String?, message: String) async {
        let retry = "Will retry again in \(reconnectInterval) second\(reconnectInterval != 1 ? "s" : "")."
        if let code, Self.tlsVerificationErrors.contains(code) {
            log.error("MQTT Broker: Unable to verify the TLS certificate of the broker (\(code)). If your broker uses a self-signed certificate, disable MQTT TLS "
                + "certificate verification in the plugin settings. \(retry)")
            return
        }
        switch code {
        case "ECONNREFUSED": log.error("MQTT Broker: Connection refused. \(retry)")
        case "ECONNRESET": log.error("MQTT Broker: Connection reset. \(retry)")
        case "ENOTFOUND":
            log.error("MQTT Broker: Hostname or IP address not found.")
            // Retrying will not find it either.
            await connection?.disconnect()
        default: log.error("MQTT Broker: \(message). \(retry)")
        }
    }

    /// The Node error code the messages are keyed on, from why a connection failed (`HTTPClientError.cannotConnect`
    /// carries the system's reason).
    static func code(of reason: String) -> String? {
        let text = reason.lowercased()
        if text.contains("refused") { return "ECONNREFUSED" }
        if text.contains("connection reset") { return "ECONNRESET" }
        if text.contains("resolve") || text.contains("not known") || text.contains("nodename") { return "ENOTFOUND" }
        if text.contains("certificate") { return text.contains("self") ? "DEPTH_ZERO_SELF_SIGNED_CERT" : "UNABLE_TO_VERIFY_LEAF_SIGNATURE" }
        return nil
    }

    private func expand(_ id: String, _ topic: String) -> String? {
        id.isEmpty ? nil : "\(topicPrefix)/\(id)/\(topic)"
    }

    /// Publishes `message` on `<prefix>/<id>/<topic>`.
    func publish(_ id: String, _ topic: String, _ message: String) {
        guard let topic = expand(id, topic), connection != nil else { return }
        log.debug("MQTT publish: \(topic) Message: \(message).")
        operations.yield(.publish(topic, Data(message.utf8)))
    }

    func subscribe(_ id: String, _ topic: String, handler: @escaping Handler) {
        guard let topic = expand(id, topic) else { return }
        log.debug("MQTT subscribe: \(topic).")
        subscriptions.withLockedValue { $0[topic] = handler }
        operations.yield(.subscribe(topic))
    }

    /// `<topic>/get`: a `true` publishes `getValue()` on `<topic>`.
    func subscribeGet(_ id: String, _ topic: String, type: String, log: ProtectLog? = nil, _ getValue: @escaping @Sendable () async -> String) {
        let log = log ?? self.log
        subscribe(id, topic + "/get") { [weak self] message in
            guard String(decoding: message, as: UTF8.self).lowercased() == "true" else { return }
            self?.publish(id, topic, await getValue())
            log.info("MQTT: \(type) status published.")
        }
    }

    /// `<topic>/set`: the message, lower-cased and as sent, goes to `setValue`.
    func subscribeSet(_ id: String, _ topic: String, type: String, log: ProtectLog? = nil, _ setValue: @escaping @Sendable (_ value: String, _ raw: String) async throws -> Void) {
        let log = log ?? self.log
        subscribe(id, topic + "/set") { message in
            let raw = String(decoding: message, as: UTF8.self)
            let value = raw.lowercased()
            do {
                try await setValue(value, raw)
                log.info("MQTT: set message received for \(type): \(value).")
            } catch {
                var reason = "\(error)"
                if reason.hasSuffix(".") { reason.removeLast() }
                log.error("MQTT: error setting \(type) to \(value): \(reason).")
            }
        }
    }

    func unsubscribe(_ id: String, _ topic: String) {
        guard let topic = expand(id, topic) else { return }
        subscriptions.withLockedValue { $0[topic] = nil }
        operations.yield(.unsubscribe(topic))
    }

    /// Disconnects and stops reconnecting.
    func end() async {
        subscriptions.withLockedValue { $0 = [:] }
        tasks.cancelAll()
        operations.finish()
        // What is still queued goes now or not at all: nothing waits for a broker any more.
        gate.end()
        await worker?.value
        await connection?.disconnect()
        connectionState.withLockedValue { $0.isConnected = false }
    }
}

/// Holds operations back until the broker is connected. `end()` lets everything through for good.
final class BrokerGate: Sendable {
    private let state = NIOLockedValueBox((open: false, ended: false, waiters: [CheckedContinuation<Void, Never>]()))

    /// Returns once the broker is connected, or the client has ended.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let through = state.withLockedValue { state -> Bool in
                if state.open || state.ended { return true }
                state.waiters.append(continuation)
                return false
            }
            if through { continuation.resume() }
        }
    }

    func open() { release { $0.open = true } }

    func close() { state.withLockedValue { $0.open = false } }

    func end() { release { $0.ended = true } }

    private func release(_ change: (inout (open: Bool, ended: Bool, waiters: [CheckedContinuation<Void, Never>])) -> Void) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            change(&state)
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
