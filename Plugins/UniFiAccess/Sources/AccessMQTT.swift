import Foundation
import HomeswiftNetwork
import Logging

/// The plugin's MQTT topics (`MqttClient` of homebridge-plugin-utils): everything under `<topic>/<device id>/`,
/// state published as it changes, `<topic>/get` answered with the current state when it receives `true`, and
/// `<topic>/set` handed to a setter.
actor AccessMQTT {
    typealias Handler = @Sendable (String) async -> Void
    /// Makes a client for a broker; tests return a fake one.
    typealias Connector = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    static let reconnectInterval: Duration = .seconds(60)

    let brokerURL: String
    let topicPrefix: String
    private let url: URL?
    private let verifyTLS: Bool
    private let connector: Connector
    private let logger: Logger
    private let prefix: String
    private var connection: (any MQTTConnection)?
    private var subscriptions: [String: Handler] = [:]
    private var isConnected = false
    private var tasks: [Task<Void, Never>] = []

    /// A URL that is not one, or a scheme other than mqtt, mqtts, tcp and ssl, is logged and leaves the client
    /// without a connection, as the Homebridge plugin did.
    init(brokerURL: String, topicPrefix: String, verifyTLS: Bool, connector: @escaping Connector, logger: Logger, prefix: String) {
        self.brokerURL = brokerURL
        self.topicPrefix = topicPrefix
        self.verifyTLS = verifyTLS
        self.connector = connector
        self.logger = logger
        self.prefix = prefix
        let redacted = Self.redact(brokerURL)
        guard let url = URL(string: brokerURL), let scheme = url.scheme?.lowercased(), brokerURL.contains("://") else {
            logger.error("\(prefix)MQTT Broker: Invalid URL provided: \(redacted).")
            self.url = nil
            return
        }
        guard ["mqtt", "mqtts", "tcp", "ssl"].contains(scheme) else {
            logger.error("\(prefix)MQTT Broker: Unsupported protocol: \(scheme):. Only mqtt://, mqtts://, tcp://, and ssl:// broker URLs are supported: \(redacted).")
            self.url = nil
            return
        }
        self.url = url
    }

    /// Connects in the background, retrying until the broker answers as mqtt.js did; later drops are the
    /// client's to reconnect, renewing the subscriptions.
    func start() async {
        guard let url, connection == nil else { return }
        let connection: any MQTTConnection
        do {
            let clientID = "homeswift_" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
            var configuration = try MQTTConfiguration(url: url, clientID: clientID, tls: verifyTLS ? .system : TLSOptions(trust: .any))
            configuration.reconnect = .init(delay: .seconds(1), maximumDelay: Self.reconnectInterval, firstConnection: true)
            connection = try await connector(configuration)
        } catch {
            logger.error("\(prefix)MQTT Broker: Error: \(error).")
            return
        }
        self.connection = connection
        let states = connection.states
        let messages = connection.messages
        tasks = [
            Task { [weak self] in
                for await state in states { await self?.handle(state) }
            },
            Task { [weak self] in
                for await message in messages { await self?.subscriptions[message.topic]?(message.string ?? "") }
            },
            Task { try? await connection.connect() },
        ]
    }

    private func handle(_ state: MQTTConnectionState) {
        switch state {
        case .connected:
            isConnected = true
            logger.info("\(prefix)MQTT Broker: Connected to \(Self.redact(brokerURL)) (topic: \(topicPrefix)).")
        case .connectionLost(let reason):
            let seconds = Self.reconnectInterval.components.seconds
            let detail = reason.lowercased().contains("certificate")
                ? "Unable to verify the TLS certificate of the broker (\(reason)). If your broker uses a self-signed certificate, disable MQTT TLS certificate verification in the plugin settings"
                : reason
            logger.error("\(prefix)MQTT Broker: \(detail). Will retry again in \(seconds) second\(seconds == 1 ? "" : "s").")
            disconnected()
        case .disconnected:
            disconnected()
        case .connecting:
            break
        }
    }

    private func disconnected() {
        guard isConnected else { return }
        isConnected = false
        logger.info("\(prefix)MQTT Broker: Connection closed.")
    }

    /// `<prefix>/<id>/<topic>`; nil without an id.
    func expand(_ id: String, _ topic: String) -> String? {
        id.isEmpty ? nil : "\(topicPrefix)/\(id)/\(topic)"
    }

    func publish(_ id: String, _ topic: String, _ message: String) async {
        guard let expanded = expand(id, topic) else { return }
        logger.debug("\(prefix)MQTT publish: \(expanded) Message: \(message).")
        // Dropped while disconnected, as mqtt.js without a queue.
        try? await connection?.publish(expanded, string: message)
    }

    func subscribe(_ id: String, _ topic: String, _ handler: @escaping Handler) async {
        guard let expanded = expand(id, topic) else { return }
        logger.debug("\(prefix)MQTT subscribe: \(expanded).")
        subscriptions[expanded] = handler
        try? await connection?.subscribe(expanded)
    }

    /// Answers `true` on `<topic>/get` with the current value on `<topic>`.
    func subscribeGet(_ id: String, _ topic: String, type: String, logPrefix: String, value: @escaping @Sendable () async -> String) async {
        await subscribe(id, "\(topic)/get") { [weak self] message in
            guard message.lowercased() == "true", let self else { return }
            await self.publish(id, topic, await value())
            self.logger.info("\(logPrefix)MQTT: \(type) status published.")
        }
    }

    /// Hands what arrives on `<topic>/set`, lowercased, to the setter.
    func subscribeSet(_ id: String, _ topic: String, type: String, logPrefix: String, setter: @escaping @Sendable (String) async throws -> Void) async {
        await subscribe(id, "\(topic)/set") { [weak self] message in
            guard let self else { return }
            let value = message.lowercased()
            do {
                try await setter(value)
                self.logger.info("\(logPrefix)MQTT: set message received for \(type): \(value).")
            } catch {
                self.logger.error("\(logPrefix)MQTT: error setting \(type) to \(value): \(error).")
            }
        }
    }

    func unsubscribe(_ id: String, _ topic: String) async {
        guard let expanded = expand(id, topic) else { return }
        subscriptions[expanded] = nil
        try? await connection?.unsubscribe(expanded)
    }

    func end() async {
        subscriptions = [:]
        for task in tasks { task.cancel() }
        tasks = []
        await connection?.disconnect()
        connection = nil
        isConnected = false
    }

    /// The broker URL without its credentials, for the log.
    nonisolated static func redact(_ url: String) -> String {
        guard let at = url.lastIndex(of: "@") else { return url }
        var schemeEnd = url.startIndex
        if let range = url.range(of: "://"), range.lowerBound < at {
            schemeEnd = range.upperBound
            while schemeEnd < at, url[schemeEnd] == "/" { schemeEnd = url.index(after: schemeEnd) }
        } else if let colon = url.firstIndex(of: ":"), colon < at, url[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }), url.first?.isLetter == true {
            schemeEnd = url.index(after: colon)
            while schemeEnd < at, url[schemeEnd] == "/" { schemeEnd = url.index(after: schemeEnd) }
        }
        return String(url[..<schemeEnd]) + "REDACTED" + String(url[at...])
    }
}
