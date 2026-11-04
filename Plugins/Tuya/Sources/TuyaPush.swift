import Crypto
import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// A message from Tuya's open-hub MQTT, decrypted.
enum TuyaPushMessage: Sendable, Equatable {
    /// Protocol 4: DP values of a device. `items` are code and value pairs, `raw` the status entries as sent.
    case status(deviceID: String, items: [StatusItem], t: Int64)
    /// Protocol 20: `online`, `offline`, `nameUpdate`, `bindUser`, `delete`…
    case lifecycle(code: String, deviceID: String, data: JSONValue)

    struct StatusItem: Sendable, Equatable {
        var code: String
        var value: JSONValue
        var t: Int64?
    }

    /// The decrypted text of a payload, by the project's `msg_encrypted_version`.
    static func decrypt(_ payload: Data, key: SymmetricKey, version: String) throws -> (text: Data, t: Int64, protocol: Int) {
        let envelope = try JSONValue(data: payload)
        guard let data = envelope["data"]?.stringValue else { throw TuyaMessageCrypto.Failure.decrypt }
        let t = Int64(envelope["t"]?.doubleValue ?? 0)
        let plain = version == "2.0"
            ? try TuyaMessageCrypto.decryptGCM(data, key: key, t: t)
            : try TuyaMessageCrypto.decryptECB(data, key: key)
        return (plain, t, envelope["protocol"]?.intValue ?? 0)
    }

    /// The message a decrypted text holds, or nil for a protocol the plugin does not read.
    static func parse(_ text: Data, protocol number: Int, t: Int64) throws -> TuyaPushMessage? {
        let message = try JSONValue(data: text)
        let deviceID = message["devId"]?.stringValue ?? ""
        switch number {
        case 4:
            let items = (message["status"]?.arrayValue ?? []).compactMap { entry -> StatusItem? in
                guard let code = entry["code"]?.stringValue else { return nil }
                return StatusItem(code: code, value: entry["value"] ?? .null, t: entry["t"]?.doubleValue.map { Int64($0) })
            }
            return .status(deviceID: deviceID, items: items, t: t)
        case 20:
            return .lifecycle(code: message["bizCode"]?.stringValue ?? "", deviceID: deviceID, data: message["bizData"] ?? .null)
        default:
            return nil
        }
    }
}

/// Keeps a late status message from rolling a DP back: the messages applied in the last 30 seconds, and a message older
/// than the newest one takes, for each code, the value a newer message of the same device gave.
struct TuyaMessageOrder: Sendable {
    private struct Kept {
        var t: Int64
        var deviceID: String
        var items: [TuyaPushMessage.StatusItem]
    }

    private var kept: [Kept] = []
    private var newest: Int64 = 0
    static let window: Int64 = 30_000
    static let limit = 500

    /// Milliseconds: a timestamp above 10^12 is one already, a lower one is seconds.
    static func milliseconds(_ t: Int64) -> Int64 { t > 1_000_000_000_000 ? t : t * 1000 }

    /// The items to apply: corrected when the message is late.
    mutating func order(deviceID: String, items: [TuyaPushMessage.StatusItem], t: Int64, now: Int64) -> (items: [TuyaPushMessage.StatusItem], late: Bool) {
        let time = Self.milliseconds(t)
        kept.removeAll { now - $0.t > Self.window }
        if time < newest {
            let corrected = items.map { item -> TuyaPushMessage.StatusItem in
                for message in kept.reversed() where message.deviceID == deviceID {
                    if let newer = message.items.last(where: { $0.code == item.code }) {
                        return newer.value != item.value ? newer : item
                    }
                }
                return item
            }
            return (corrected, true)
        }
        newest = time
        kept.append(Kept(t: time, deviceID: deviceID, items: items))
        if kept.count > Self.limit { kept.removeFirst(kept.count - Self.limit) }
        return (items, false)
    }
}

/// The open-hub MQTT connection: its configuration from the OpenAPI, renewed a minute before it expires (and after a
/// failure, with a growing delay), the messages decrypted, ordered and handed over.
actor TuyaPush {
    private let api: TuyaOpenAPI
    private let version: String
    private let linkID = UUID().uuidString.lowercased()
    private let makeConnection: @Sendable (MQTTConfiguration) -> any MQTTConnection
    private let logger: Logger
    private let debug: Bool
    private let timeScale: Double
    private let backoff: Backoff
    private let now: @Sendable () -> Date
    private let handler: @Sendable (TuyaPushMessage) async -> Void
    private var loop: Task<Void, Never>?
    private var order = TuyaMessageOrder()
    private var reportedFailure = false
    private var reportedDecryption = false

    init(
        api: TuyaOpenAPI, version: String, logger: Logger, debug: Bool, timeScale: Double, backoff: Backoff,
        now: @escaping @Sendable () -> Date = { Date() },
        makeConnection: @escaping @Sendable (MQTTConfiguration) -> any MQTTConnection,
        handler: @escaping @Sendable (TuyaPushMessage) async -> Void
    ) {
        self.api = api
        self.version = version
        self.logger = logger
        self.debug = debug
        self.timeScale = timeScale
        self.backoff = backoff
        self.now = now
        self.makeConnection = makeConnection
        self.handler = handler
    }

    func start() {
        logger.info("Starting the MQTT connection")
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    /// A new configuration and connection, so a device bound since gets its messages.
    func restart() { start() }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let config: JSONValue
            do {
                config = try await api.mqttConfig(linkID: linkID, version: version)
            } catch {
                if !reportedFailure { logger.warning("Could not get the MQTT configuration, trying again: \(error)") }
                reportedFailure = true
                try? await Task.sleep(for: backoff.delay(attempt: attempt) * timeScale)
                attempt += 1
                continue
            }
            guard let address = config["url"]?.stringValue, let url = URL(string: address), let clientID = config["client_id"]?.stringValue,
                  let password = config["password"]?.stringValue, let key = TuyaMessageCrypto.key(fromPassword: password),
                  let topic = config["source_topic"]?["device"]?.stringValue, var configuration = try? MQTTConfiguration(url: url, clientID: clientID) else {
                if !reportedFailure { logger.warning("The MQTT configuration Tuya gave is incomplete, trying again") }
                reportedFailure = true
                try? await Task.sleep(for: backoff.delay(attempt: attempt) * timeScale)
                attempt += 1
                continue
            }
            configuration.username = config["username"]?.stringValue
            configuration.password = password
            let connection = makeConnection(configuration)
            let messages = connection.messages
            let consumer = Task { [weak self] in
                for await message in messages { await self?.receive(message.payload, key: key) }
            }
            do {
                try await connection.connect()
                try await connection.subscribe(topic)
            } catch {
                consumer.cancel()
                await connection.disconnect()
                if !reportedFailure { logger.warning("Could not connect to Tuya's MQTT, trying again: \(error)") }
                reportedFailure = true
                try? await Task.sleep(for: backoff.delay(attempt: attempt) * timeScale)
                attempt += 1
                continue
            }
            if reportedFailure { logger.info("Connected to Tuya's MQTT") }
            reportedFailure = false
            attempt = 0
            let seconds = max(60, config["expire_time"]?.doubleValue ?? 7200) - 60
            try? await Task.sleep(for: .seconds(seconds) * timeScale)
            consumer.cancel()
            await connection.disconnect()
        }
    }

    func receive(_ payload: Data, key: SymmetricKey) async {
        let decrypted: (text: Data, t: Int64, protocol: Int)
        do {
            decrypted = try TuyaPushMessage.decrypt(payload, key: key, version: version)
        } catch {
            // The payload is ciphertext, but it stays out of the log: once at warning level, after that at debug.
            if !reportedDecryption { logger.warning("Dropping a Tuya MQTT message that does not decrypt or authenticate (\(error))") }
            else { logger.debug("Dropping a Tuya MQTT message that does not decrypt or authenticate (\(error))") }
            reportedDecryption = true
            return
        }
        guard var message = try? TuyaPushMessage.parse(decrypted.text, protocol: decrypted.protocol, t: decrypted.t) else {
            logger.debug("Unhandled Tuya MQTT message", metadata: ["protocol": "\(decrypted.protocol)"])
            return
        }
        if debug { logger.debug("Tuya MQTT message", metadata: ["protocol": "\(decrypted.protocol)", "t": "\(decrypted.t)"]) }
        if case .status(let deviceID, let items, let t) = message {
            let ordered = order.order(deviceID: deviceID, items: items, t: t, now: Int64(now().timeIntervalSince1970 * 1000))
            if ordered.late, ordered.items != items { logger.debug("Corrected a late Tuya status message", metadata: ["device": "\(deviceID)"]) }
            message = .status(deviceID: deviceID, items: ordered.items, t: t)
        }
        await handler(message)
    }
}
