import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDysonPureCool

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A Dyson device's broker in memory, behind the `MQTTConnection`s `mqtt` makes: it accepts or refuses
/// CONNECTs, answers `REQUEST-CURRENT-STATE` with `CURRENT-STATE`, applies `STATE-SET` and reports
/// `STATE-CHANGE`, as a device does. (The shared `FakeMQTTConnection` records publishes but cannot answer them.)
final class FakeDyson: @unchecked Sendable {
    struct Published: Equatable {
        var topic: String
        var json: JSONValue
        var data: [String: String] {
            var fields: [String: String] = [:]
            for (key, value) in json["data"]?.objectValue ?? [:] { fields[key] = value.stringValue }
            return fields
        }
    }

    private struct Store {
        var productState: [String: String] = [:]
        var connects: [MQTTConfiguration] = []
        var published: [Published] = []
        var subscriptions: [String] = []
        var connections: [FakeConnection] = []
        /// Refuses CONNECTs whose client id is not the serial (Big+Quiet firmware) with this code.
        var refuseLongClientIDs: UInt8?
        var refuseAll: (any Error)?
        var reachableHosts: Set<String>?
        var answersStateRequests = true
        var echoesCommands = true
    }

    private let store = NIOLockedValueBox(Store())

    init(productState: [String: String] = [:]) {
        store.withLockedValue { $0.productState = productState }
    }

    /// The connection factory the plugin gets.
    var mqtt: DysonMQTTClient.Connect {
        { configuration in FakeConnection(device: self, configuration: configuration) }
    }

    var connects: [MQTTConfiguration] { store.withLockedValue { $0.connects } }
    var published: [Published] { store.withLockedValue { $0.published } }
    var commands: [[String: String]] { published.filter { $0.json["msg"] == "STATE-SET" }.map(\.data) }
    var subscriptions: [String] { store.withLockedValue { $0.subscriptions } }
    var productState: [String: String] { store.withLockedValue { $0.productState } }
    var openConnections: [FakeConnection] { store.withLockedValue { $0.connections.filter { !$0.isClosed } } }

    func set(refuseLongClientIDs code: UInt8?) { store.withLockedValue { $0.refuseLongClientIDs = code } }
    func set(refuseAll error: (any Error)?) { store.withLockedValue { $0.refuseAll = error } }
    /// nil: every host answers.
    func set(reachableHosts: Set<String>?) { store.withLockedValue { $0.reachableHosts = reachableHosts } }
    func set(answersStateRequests: Bool) { store.withLockedValue { $0.answersStateRequests = answersStateRequests } }
    /// false: commands are taken but no STATE-CHANGE confirms them.
    func set(echoesCommands: Bool) { store.withLockedValue { $0.echoesCommands = echoesCommands } }
    func clearPublished() { store.withLockedValue { $0.published = [] } }

    /// A CONNECT: the refusal, or nil once the connection is open.
    fileprivate func connecting(_ connection: FakeConnection) -> (any Error)? {
        store.withLockedValue { store in
            let configuration = connection.configuration
            store.connects.append(configuration)
            if let hosts = store.reachableHosts, !hosts.contains(configuration.host) {
                return DysonMQTTError.unreachable("connect ECONNREFUSED \(configuration.host):1883")
            }
            if let error = store.refuseAll { return error }
            if let code = store.refuseLongClientIDs, configuration.clientID != configuration.username { return MQTTError.connectionRefused(code: code) }
            store.connections.append(connection)
            return nil
        }
    }

    /// The device reports a change: `STATE-CHANGE` with `[old, new]` pairs.
    func change(_ fields: [String: String]) {
        let pairs: [String: JSONValue] = store.withLockedValue { store in
            var pairs: [String: JSONValue] = [:]
            for (key, value) in fields {
                pairs[key] = [.string(store.productState[key] ?? ""), .string(value)]
                store.productState[key] = value
            }
            return pairs
        }
        broadcast(["msg": "STATE-CHANGE", "time": "2026-01-16T10:31:00.000Z", "mode-reason": "LAPP", "product-state": .object(pairs)])
    }

    func sendEnvironment(_ fields: [String: String]) {
        broadcast(["msg": "ENVIRONMENTAL-CURRENT-SENSOR-DATA", "time": "2026-01-16T10:30:00.000Z", "data": .object(fields.mapValues { .string($0) })])
    }

    func broadcast(_ message: JSONValue) {
        for connection in openConnections { connection.deliver(message) }
    }

    /// Drops every connection, as a device that lost power.
    func dropConnections() {
        for connection in openConnections { connection.drop() }
    }

    fileprivate func received(_ topic: String, _ payload: Data, on connection: FakeConnection) {
        guard let json = try? JSONValue(data: payload) else { return }
        store.withLockedValue { $0.published.append(Published(topic: topic, json: json)) }
        switch json["msg"]?.stringValue {
        case "REQUEST-CURRENT-STATE":
            let (answers, state) = store.withLockedValue { ($0.answersStateRequests, $0.productState) }
            guard answers else { return }
            connection.deliver(["msg": "CURRENT-STATE", "time": "2026-01-16T10:30:00.000Z", "mode-reason": "LAPP", "product-state": .object(state.mapValues { .string($0) })])
        case "STATE-SET":
            guard store.withLockedValue({ $0.echoesCommands }) else { return }
            var fields: [String: String] = [:]
            for (key, value) in json["data"]?.objectValue ?? [:] { fields[key] = value.stringValue }
            change(fields)
        default:
            break
        }
    }

    fileprivate func subscribed(_ topic: String) {
        store.withLockedValue { $0.subscriptions.append(topic) }
    }
}

extension MQTTConfiguration {
    var host: String {
        guard case .tcp(let host, _) = transport else { return "" }
        return host
    }

    var port: Int {
        guard case .tcp(_, let port) = transport else { return 0 }
        return port
    }
}

/// One connection to the fake device, as `MQTTClient` behaves with its reconnection off.
final class FakeConnection: MQTTConnection, @unchecked Sendable {
    let configuration: MQTTConfiguration
    private weak var device: FakeDyson?

    private struct State {
        var current: MQTTConnectionState = .disconnected
        var closed = false
        var topics: [String] = []
        var next = 0
        var messageReaders: [Int: AsyncStream<MQTTMessage>.Continuation] = [:]
        var stateReaders: [Int: AsyncStream<MQTTConnectionState>.Continuation] = [:]
    }

    private let state = NIOLockedValueBox(State())

    init(device: FakeDyson, configuration: MQTTConfiguration) {
        self.device = device
        self.configuration = configuration
    }

    var isClosed: Bool { state.withLockedValue { $0.closed } }
    private var isConnected: Bool {
        state.withLockedValue { state in
            if case .connected = state.current { return !state.closed }
            return false
        }
    }

    func connect() async throws {
        if let refusal = device?.connecting(self) { throw refusal }
        setState(.connected(sessionPresent: false))
    }

    func disconnect() async {
        state.withLockedValue { $0.closed = true }
        setState(.disconnected)
    }

    func subscribe(_ topic: String, qos: MQTTQoS) async throws {
        guard isConnected else { throw MQTTError.notConnected }
        state.withLockedValue { $0.topics.append(topic) }
        device?.subscribed(topic)
    }

    func unsubscribe(_ topic: String) async throws {
        state.withLockedValue { $0.topics.removeAll { $0 == topic } }
    }

    func publish(_ message: MQTTMessage) async throws {
        guard isConnected else { throw MQTTError.notConnected }
        device?.received(message.topic, message.payload, on: self)
    }

    var messages: AsyncStream<MQTTMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: MQTTMessage.self)
        state.withLockedValue { state in
            state.next += 1
            state.messageReaders[state.next] = continuation
        }
        return stream
    }

    var states: AsyncStream<MQTTConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: MQTTConnectionState.self)
        state.withLockedValue { state in
            state.next += 1
            state.stateReaders[state.next] = continuation
            continuation.yield(state.current)
        }
        return stream
    }

    private func setState(_ newState: MQTTConnectionState) {
        let readers = state.withLockedValue { state in
            state.current = newState
            return Array(state.stateReaders.values)
        }
        for reader in readers { reader.yield(newState) }
    }

    func deliver(_ message: JSONValue) {
        let (readers, topics) = state.withLockedValue { state in
            state.closed ? ([], []) : (Array(state.messageReaders.values), state.topics.filter { $0.hasSuffix("/status/current") })
        }
        for topic in topics {
            for reader in readers { reader.yield(MQTTMessage(topic: topic, payload: message.encoded())) }
        }
    }

    /// The device goes away: the connection is lost, as the client reports it.
    func drop() {
        state.withLockedValue { $0.closed = true }
        setState(.connectionLost("the connection to the MQTT broker dropped"))
    }
}

/// The Dyson cloud in memory.
final class FakeCloud: HTTPSending, @unchecked Sendable {
    struct Account {
        var email = "user@example.com"
        var password = "secret"
        var status = "ACTIVE"
        var code = "123456"
        var direct = false
    }

    private struct Store {
        var account = Account()
        var manifest: JSONValue = []
        var requests: [HomeswiftNetwork.HTTPRequest] = []
        var challenge = "challenge-1"
        var token = "token-1"
        var expiredTokens: Set<String> = []
    }

    private let store = NIOLockedValueBox(Store())

    var requests: [HomeswiftNetwork.HTTPRequest] { store.withLockedValue { $0.requests } }
    var paths: [String] { requests.map { "\($0.method) \($0.url.path)" } }

    func set(account: Account) { store.withLockedValue { $0.account = account } }
    func set(manifest: JSONValue) { store.withLockedValue { $0.manifest = manifest } }
    func expire(token: String) { store.withLockedValue { _ = $0.expiredTokens.insert(token) } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let store = store.withLockedValue { store -> Store in
            store.requests.append(request)
            return store
        }
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let json = { (value: JSONValue, status: Int) in HomeswiftNetwork.HTTPResponse(status: status, body: value.encoded()) }
        switch (request.method, request.url.path) {
        case ("GET", "/v1/provisioningservice/application/Android/version"):
            return json("5.0.21061", 200)
        case ("POST", "/v3/userregistration/email/userstatus"):
            guard body?["email"]?.stringValue == store.account.email else { return json(["accountStatus": "UNREGISTERED", "authenticationMethod": "EMAIL_PWD_2FA"], 200) }
            return json(["accountStatus": .string(store.account.status), "authenticationMethod": "EMAIL_PWD_2FA"], 200)
        case ("POST", "/v3/userregistration/email/auth"):
            return store.account.direct ? json(["account": "abc", "token": .string(store.token), "tokenType": "Bearer"], 200)
                : json(["challengeId": .string(store.challenge)], 200)
        case ("POST", "/v3/userregistration/email/verify"):
            guard body?["challengeId"]?.stringValue == store.challenge, body?["otpCode"]?.stringValue == store.account.code else {
                return json(["Message": "Invalid OTP code"], 400)
            }
            guard body?["password"]?.stringValue == store.account.password else {
                return json(["Message": "Unable to authenticate user."], 401)
            }
            return json(["account": "abc", "token": .string(store.token), "tokenType": "Bearer"], 200)
        case ("GET", "/v2/provisioningservice/manifest"):
            let token = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            guard let token, token == store.token, !store.expiredTokens.contains(token) else { return json(["Message": "Unauthorized"], 401) }
            return json(store.manifest, 200)
        default:
            return HomeswiftNetwork.HTTPResponse(status: 404)
        }
    }
}

/// A host with one DysonPureCool block whose plugin talks to `dyson`, finds what `discovered` holds over
/// mDNS, and signs in to `cloud`.
final class DysonTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-dyson-tests-\(UUID().uuidString)")
    let dyson: FakeDyson
    let cloud = FakeCloud()
    private let found = NIOLockedValueBox<[String: String]>([:])
    private let scans = NIOLockedValueBox(0)
    private let plugins = NIOLockedValueBox<[DysonPureCoolPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])
    var offlineRetry: Duration = .seconds(300)

    init(productState: [String: String] = FakeStates.tp04) {
        dyson = FakeDyson(productState: productState)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var plugin: DysonPureCoolPlugin? { plugins.withLockedValue { $0.last } }
    var scanCount: Int { scans.withLockedValue { $0 } }

    func set(discovered: [String: String]) { found.withLockedValue { $0 = discovered } }

    var dependencies: DysonPureCoolPlugin.Dependencies {
        let found = found
        let scans = scans
        return DysonPureCoolPlugin.Dependencies(
            mqtt: dyson.mqtt,
            discover: { _, _ in
                scans.withLockedValue { $0 += 1 }
                return found.withLockedValue { $0 }
            },
            http: cloud, backoff: { _ in .milliseconds(10) }, offlineRetry: offlineRetry)
    }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies
        registry.register(platform: DysonPureCoolPlugin.platform, name: DysonPureCoolPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(DysonPureCoolPlugin.Configuration.self, from: json)
            let plugin = DysonPureCoolPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: DysonPureCoolPlugin.platform, name: "Dyson", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { name in
            self.storages.withLockedValue { storages in
                if let storage = storages[name] { return storage }
                let storage = MemoryStorage()
                storages[name] = storage
                return storage
            }
        }
        return try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
    }

    /// Starts the host and waits for the first connections.
    func start(settings: [String: Any]) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        await plugin?.settle()
        return host
    }
}

/// Product states from the Homebridge plugin's fixtures (test/fixtures/dyson-payloads.json).
enum FakeStates {
    static let tp04: [String: String] = [
        "fpwr": "ON", "fmod": "FAN", "auto": "OFF", "fnsp": "0005", "oson": "ON", "oscs": "0045", "osce": "0315", "nmod": "OFF",
        "rhtm": "ON", "ffoc": "OFF", "tact": "2951", "hact": "0055", "p25r": "0003", "p10r": "0005", "va10": "0002", "filf": "2400", "cflr": "0100",
    ]
    static let hp02: [String: String] = [
        "fmod": "OFF", "fnst": "OFF", "fnsp": "AUTO", "qtar": "0004", "oson": "OFF", "rhtm": "ON", "filf": "4119", "ercd": "NONE",
        "nmod": "OFF", "wacd": "NONE", "hmod": "HEAT", "hmax": "2950", "hsta": "OFF", "ffoc": "ON", "tilt": "OK",
    ]
    static let hp04: [String: String] = [
        "fpwr": "ON", "fmod": "FAN", "auto": "OFF", "fnsp": "0004", "oson": "OFF", "nmod": "OFF", "rhtm": "ON", "ffoc": "ON",
        "hmod": "HEAT", "hmax": "2951", "tact": "2901", "hact": "0045", "p25r": "0002", "p10r": "0003", "va10": "0001", "filf": "3600",
    ]
    static let ph03: [String: String] = [
        "fpwr": "ON", "fmod": "AUTO", "auto": "ON", "fnsp": "0003", "oson": "ON", "nmod": "OFF", "rhtm": "ON", "ffoc": "OFF",
        "hume": "ON", "humt": "0050", "tact": "2941", "hact": "0040", "p25r": "0001", "p10r": "0002", "va10": "0001", "filf": "4800",
    ]
    static let tp09: [String: String] = [
        "fpwr": "ON", "fmod": "FAN", "auto": "OFF", "fnsp": "0006", "oson": "ON", "oscs": "0000", "osce": "0360", "nmod": "OFF",
        "rhtm": "ON", "ffoc": "OFF", "tact": "2961", "hact": "0048", "p25r": "0002", "p10r": "0004", "va10": "0001", "noxl": "0001",
        "hchr": "0005", "filf": "1800", "cflr": "0095",
    ]
}
