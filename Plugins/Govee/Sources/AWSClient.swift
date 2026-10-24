import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOSSL

/// The account's AWS IoT connection (`connection/aws.ts`): subscribed to the account topic, where devices
/// report their status; commands and status requests are published to each device's own topic.
actor AWSClient {
    /// A publish the broker never acknowledges (the connection dropped between the check and the send)
    /// fails after this, so the command can fall back to BLE.
    static let publishTimeout: Duration = .seconds(5)
    private let publishTimeout: Duration

    let accountTopic: String
    private let connection: any MQTTConnection
    private let debug: DebugLog
    private let receive: @Sendable (JSONValue) async -> Void
    private(set) var connected = false
    private var tasks: [Task<Void, Never>] = []

    init(
        accountTopic: String, connection: any MQTTConnection, publishTimeout: Duration = AWSClient.publishTimeout, debug: DebugLog,
        receive: @escaping @Sendable (JSONValue) async -> Void
    ) {
        self.accountTopic = accountTopic
        self.publishTimeout = publishTimeout
        self.connection = connection
        self.debug = debug
        self.receive = receive
    }

    /// Watches the connection and the messages; call once.
    func start() {
        let states = connection.states
        let messages = connection.messages
        tasks.append(Task { [weak self] in
            for await state in states { await self?.handle(state) }
        })
        tasks.append(Task { [weak self] in
            for await message in messages { await self?.handle(payload: message.payload) }
        })
    }

    /// Connects and subscribes to the account topic. Throws when the broker cannot be reached, which may be
    /// never (a firewall, a revoked certificate): the caller does not wait on it.
    func connect() async throws {
        try await connection.connect()
        connected = true
        try await connection.subscribe(accountTopic)
    }

    /// Asks a device to report its status.
    func requestUpdate(topic: String, log: DeviceLog) async throws {
        guard connected else { throw GoveeAPIError.message(Lang.notAWSConn) }
        let message: JSONValue = [
            "msg": ["cmd": "status", "cmdVersion": 2, "transaction": .string(Self.transaction()), "type": 0, "accountTopic": .string(accountTopic)],
        ]
        log.debug("[AWS] \(Lang.sendingUpdate) \(Self.redacted(message).text())")
        try await publish(topic: topic, message: message)
    }

    /// Sends a command to a device.
    func updateDevice(topic: String, params: AWSParams, log: DeviceLog) async throws {
        guard connected else { throw GoveeAPIError.message(Lang.notAWSConn) }
        let message: JSONValue = [
            "msg": ["cmd": .string(params.cmd), "cmdVersion": 0, "data": params.data, "transaction": .string(Self.transaction()), "type": 1, "accountTopic": .string(accountTopic)],
        ]
        log.debug("[AWS] \(Lang.sendingUpdate) \(Self.redacted(message).text())")
        try await publish(topic: topic, message: message)
    }

    func disconnect() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        connected = false
        await connection.disconnect()
    }

    // MARK: Internals

    private func publish(topic: String, message: JSONValue) async throws {
        let payload = message.encoded()
        let connection = connection
        let timeout = publishTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await connection.publish(topic, payload: payload) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoveeAPIError.message(Lang.notAWSConn)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func handle(_ state: MQTTConnectionState) {
        switch state {
        case .connected:
            debug("[AWS] \(Lang.awsEventConnect).")
            connected = true
        case .connecting:
            debug("[AWS] \(Lang.awsEventReconnect).")
        case .connectionLost(let reason):
            // The AWS IoT SDK's `error` then `offline` events, both warnings with `debug`.
            debug.warn("[AWS] \(Lang.awsEventError) [\(reason)].")
            debug.warn("[AWS] \(Lang.awsEventOffline).")
            connected = false
        case .disconnected:
            debug.warn("[AWS] \(Lang.awsEventClose).")
            connected = false
        }
    }

    /// A message of the account topic: JSON, possibly with the real message as a JSON string in `msg`, and
    /// `data` as a JSON string too. Delivered before the next message is read, so updates keep their order.
    func handle(payload: Data) async {
        let text = String(decoding: payload, as: UTF8.self)
        guard var parsed = try? JSONValue(data: payload) else {
            debug("[AWS] \(Lang.invalidJson) [\(text)].")
            return
        }
        if let inner = parsed["msg"]?.stringValue {
            guard let message = try? JSONValue(string: inner) else {
                debug("[AWS] \(Lang.invalidJson) [\(text)].")
                return
            }
            parsed = message
        }
        if let data = parsed["data"]?.stringValue, let decoded = try? JSONValue(string: data), case .object(var object) = parsed {
            object["data"] = decoded
            parsed = .object(object)
        }
        debug("[AWS] \(Lang.awsEventMessage) [\(text)].")
        await receive(parsed)
    }

    static func transaction() -> String { "v_\(Int(Date().timeIntervalSince1970 * 1000))000" }

    /// The account topic is a credential of sorts; logs show the message without it.
    static func redacted(_ message: JSONValue) -> JSONValue {
        guard case .object(var outer) = message, case .object(var inner)? = outer["msg"] else { return message }
        inner["accountTopic"] = ""
        outer["msg"] = .object(inner)
        return .object(outer)
    }
}

/// The account's AWS IoT client certificate: the PKCS#12 file Govee hands out at login and its password
/// (`pfxToCertAndKey`), checked with BoringSSL (the same code runs on Linux) before the MQTT client uses them.
struct GoveeIoTIdentity: Sendable {
    let pkcs12: Data
    let passphrase: String

    enum IdentityError: Error, CustomStringConvertible {
        case unreadable(String)
        case noCertificate

        var description: String {
            switch self {
            case .unreadable(let reason): "the IoT certificate could not be read: \(reason)"
            case .noCertificate: "No certificate found in PFX file"
            }
        }
    }

    init(pkcs12: Data, passphrase: String) throws {
        let bundle: NIOSSLPKCS12Bundle
        do {
            bundle = try NIOSSLPKCS12Bundle(buffer: Array(pkcs12), passphrase: Array(passphrase.utf8))
        } catch {
            throw IdentityError.unreadable("\(error)")
        }
        guard !bundle.certificateChain.isEmpty else { throw IdentityError.noCertificate }
        self.pkcs12 = pkcs12
        self.passphrase = passphrase
    }
}
