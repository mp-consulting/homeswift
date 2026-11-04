import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Where a block's MQTT connection goes and who it signs in as (section 4.1). The blocks with the same settings share
/// one connection.
struct BrokerSettings: Sendable, Hashable {
    var url: String
    var username: String?
    var password: String?
    /// `mqttOptions` as given: TLS files, keep-alive, client id, protocol.
    var options: JSONValue

    /// The URL without a user name or password, for logs and Setup.
    var displayURL: String { Self.displayURL(url) }

    static func displayURL(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.user != nil || components.password != nil else { return url }
        components.user = nil
        components.password = nil
        return components.string ?? url
    }

    /// `url` with `mqtt://` in front when it has no scheme.
    static func normalized(_ url: String) -> String { url.contains("://") ? url : "mqtt://\(url)" }

    /// The broker settings of a block: its own `url`, `username` and `password` first, then what Setup kept for the URL,
    /// then `MQTTTHING_URL`, `MQTTTHING_USERNAME` and `MQTTTHING_PASSWORD`.
    init(_ config: Config, credentials: [String: BrokerCredentials], environment: [String: String]) {
        url = Self.normalized(config.string("url").flatMap { $0.isEmpty ? nil : $0 } ?? environment["MQTTTHING_URL"] ?? "mqtt://localhost:1883")
        let kept = credentials[Self.displayURL(url)]
        username = config.string("username").flatMap { $0.isEmpty ? nil : $0 } ?? kept?.username ?? environment["MQTTTHING_USERNAME"]
        password = config.string("password").flatMap { $0.isEmpty ? nil : $0 } ?? kept?.password ?? environment["MQTTTHING_PASSWORD"]
        options = config["mqttOptions"] ?? .object([:])
    }
}

/// What Setup keeps in the vault for a broker.
struct BrokerCredentials: Codable, Sendable, Equatable {
    var username: String?
    var password: String
}

/// The vault entry of the instance's account: the brokers' credentials by URL.
struct AccountCredentials: Codable, Sendable, Equatable {
    var brokers: [String: BrokerCredentials] = [:]
}

/// One MQTT connection, shared by the accessories whose blocks name the same broker and credentials: one subscription
/// per topic, messages handed to every accessory subscribed, publishes queued (a few) until the broker answers.
actor Broker {
    let settings: BrokerSettings
    let connection: any MQTTConnection
    private let logger: Logger
    private let backoff: Backoff
    private var subscribers: [String: [Thing]] = [:]
    private var queued: [MQTTMessage] = []
    private var connected = false
    private var down = false
    private(set) var refused = false
    private var tasks: [Task<Void, Never>] = []
    static let queueLimit = 256

    /// Subscriptions and publishes, in the order the accessories made them.
    private enum Command: Sendable {
        case subscribe(String, Thing)
        case publish(MQTTMessage)
    }

    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation

    init(settings: BrokerSettings, connection: any MQTTConnection, logger: Logger, backoff: Backoff) {
        self.settings = settings
        self.connection = connection
        self.logger = logger
        self.backoff = backoff
        (commands, commandSink) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .bufferingNewest(4096))
    }

    /// Subscribes `thing` to `topic`, after what was asked before.
    nonisolated func subscribe(_ topic: String, for thing: Thing) { commandSink.yield(.subscribe(topic, thing)) }

    /// Publishes, after what was asked before.
    nonisolated func publish(_ message: MQTTMessage) { commandSink.yield(.publish(message)) }

    var isConnected: Bool { connected }

    func start() {
        // The streams are taken now, so nothing that arrives from here on is missed.
        let messages = connection.messages
        let states = connection.states
        let commands = commands
        tasks.append(Task { [weak self] in
            for await command in commands {
                guard let self else { return }
                switch command {
                case .subscribe(let topic, let thing): await self.add(topic, for: thing)
                case .publish(let message): await self.send(queuing: message)
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                await self.dispatch(message)
            }
        })
        tasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.changed(state)
            }
        })
        tasks.append(Task { [weak self] in await self?.connectUntilAnswered() })
    }

    func stop() async {
        commandSink.finish()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscribers.removeAll()
        queued.removeAll()
        await connection.disconnect()
    }

    /// The first connection, tried again with the backoff until the broker answers; the client reconnects by itself
    /// after that.
    private func connectUntilAnswered() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await connection.connect()
                return
            } catch {
                if case MQTTError.connectionRefused(let code) = error, [4, 5, 0x86, 0x87].contains(code) { refused = true }
                if attempt == 0 { logger.error("Cannot reach the MQTT broker at \(settings.displayURL): \(error); trying again") }
                let delay = backoff.delay(attempt: attempt)
                attempt += 1
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func changed(_ state: MQTTConnectionState) async {
        switch state {
        case .connected:
            connected = true
            refused = false
            if down { logger.info("Connected to the MQTT broker at \(settings.displayURL) again") }
            down = false
            let pending = queued
            queued.removeAll()
            for message in pending { await send(message) }
        case .connectionLost(let reason):
            connected = false
            if !down { logger.warning("Lost the MQTT broker at \(settings.displayURL): \(reason)") }
            down = true
        case .disconnected, .connecting:
            connected = false
        }
    }

    /// Subscribes `thing` to `topic`; the broker hears of each topic once.
    private func add(_ topic: String, for thing: Thing) async {
        let first = subscribers[topic] == nil
        if !(subscribers[topic]?.contains { $0 === thing } ?? false) { subscribers[topic, default: []].append(thing) }
        guard first else { return }
        do {
            try await connection.subscribe(topic)
        } catch {
            logger.error("Cannot subscribe to \(topic): \(error)")
        }
    }

    private func send(queuing message: MQTTMessage) async {
        guard connected else {
            // Kept for when the broker answers, the oldest dropped beyond the limit.
            if queued.count >= Self.queueLimit { queued.removeFirst() }
            queued.append(message)
            return
        }
        await send(message)
    }

    private func send(_ message: MQTTMessage) async {
        do {
            try await connection.publish(message)
        } catch {
            logger.warning("Cannot publish on \(message.topic): \(error)")
        }
    }

    private func dispatch(_ message: MQTTMessage) async {
        guard let things = subscribers[message.topic], !things.isEmpty else {
            logger.warning("No MQTT dispatch handler for topic \(message.topic)")
            return
        }
        for thing in things { await thing.received(topic: message.topic, payload: message.payload) }
    }
}
