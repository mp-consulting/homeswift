import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import HomeswiftDolphinPoolCleaner

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:))

/// A logger that keeps what it is told, to check what the plugin logs.
final class LogRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        var level: Logger.Level
        var message: String
    }

    private let entries = NIOLockedValueBox<[Entry]>([])

    var all: [Entry] { entries.withLockedValue { $0 } }
    func messages(_ level: Logger.Level) -> [String] { all.filter { $0.level == level }.map(\.message) }
    var warnings: [String] { messages(.warning) }
    var errors: [String] { messages(.error) }
    func contains(_ level: Logger.Level, _ text: String) -> Bool { messages(level).contains { $0.contains(text) } }

    var logger: Logger {
        var logger = Logger(label: "dolphin-tests") { _ in Handler(recorder: self) }
        logger.logLevel = .trace
        return logger
    }

    fileprivate func record(_ level: Logger.Level, _ message: String) {
        entries.withLockedValue { $0.append(Entry(level: level, message: message)) }
        if let testLogLevel, level >= testLogLevel { print("[\(level)] \(message)") }
    }

    private struct Handler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            recorder.record(event.level, "\(event.message)")
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension DolphinTiming {
    /// Every delay in milliseconds, keeping the proportions that matter.
    static let fast = DolphinTiming(
        shadowTimeout: .milliseconds(400), minimumRequestInterval: .milliseconds(5),
        pollRetry: RetryPolicy(attempts: 3, baseDelay: .milliseconds(10)), commandRetry: RetryPolicy(attempts: 2, baseDelay: .milliseconds(10)),
        maximumRetryDelay: .milliseconds(50), retryJitter: .milliseconds(2), throttleLogInterval: .seconds(600), mqttConnectTimeout: .milliseconds(400),
        stateRefreshDelay: .milliseconds(60), commandGracePeriod: .seconds(15), discoveryRetryBase: .milliseconds(150), discoveryRetryMaximum: .seconds(2))
}

// MARK: The REST and Cognito endpoints

/// Cognito and the MyDolphin backend in memory: routes by Cognito target or by path.
final class FakeCloudServer: HTTPSending, @unchecked Sendable {
    struct Route: Sendable {
        var status = 200
        var body: JSONValue
        var headers: [(name: String, value: String)] = []
    }

    private let state = NIOLockedValueBox<(routes: [String: Route], requests: [HTTPRequest])>(([:], []))

    init() {
        set("InitiateAuth", Route(body: ["AuthenticationResult": ["IdToken": "id-token", "RefreshToken": "refresh-1", "AccessToken": "access"]]))
        set("/mobapi/user/authenticate-user/", Route(body: ["Status": "1", "Data": ["mob_token": "mob", "Sernum": "E3086OFG2M", "MyRobotName": "Pool Bot", "connectVia": "62"]]))
        set("/mt-sso/aws/getToken/", Route(body: [
            "Status": "1", "Data": ["AccessKeyId": "AKIA", "SecretAccessKey": "secret", "Token": "session", "TokenExpiration": "2099-01-01T00:00:00Z"],
        ]))
        set("/mobapi/serial-numbers/getRobotDetailsByRobotSN/", Route(body: ["Status": "1", "Data": ["SERNUM": "E3086OFG2M", "MyRobotName": "Pool Bot", "PARTDES": "Dolphin M400"]]))
        set("/mobapi/serial-numbers/getSernFeatures/", Route(body: ["Status": "1", "Data": ["features": [["description": "Temperature"]]]]))
    }

    /// A Cognito target (`InitiateAuth`) or a backend path.
    func set(_ key: String, _ route: Route) { state.withLockedValue { $0.routes[key] = route } }

    /// A Cognito error, as Cognito answers it.
    func cognitoError(_ target: String, type: String, message: String) {
        set(target, Route(status: 400, body: ["__type": .string(type), "message": .string(message)]))
    }

    var requests: [HTTPRequest] { state.withLockedValue { $0.requests } }

    func requests(to key: String) -> [HTTPRequest] {
        requests.filter { Self.key(of: $0) == key }
    }

    func json(of request: HTTPRequest) -> JSONValue? { request.body.flatMap { try? JSONValue(data: $0) } }

    static func key(of request: HTTPRequest) -> String {
        if let target = request.header("X-Amz-Target") { return String(target.split(separator: ".").last ?? "") }
        // URLComponents keeps the trailing slash the backend's paths have.
        return URLComponents(url: request.url, resolvingAgainstBaseURL: true)?.path ?? request.url.path
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = state.withLockedValue { state -> Route? in
            state.requests.append(request)
            return state.routes[Self.key(of: request)]
        }
        guard let route else { return HTTPResponse(status: 404, body: Data("not found".utf8)) }
        return HTTPResponse(status: route.status, headers: route.headers, body: route.body.encoded())
    }
}

// MARK: AWS IoT

/// An AWS IoT broker in memory, as the plugin's MQTT factory (`factory`): each connection is a
/// `FakeMQTTConnection`. `respond` answers each publish (nil: no answer); by default shadow requests are
/// accepted with `shadow` and the request's client token.
final class FakeBroker: @unchecked Sendable {
    enum ConnectBehavior: Sendable { case succeed, fail, hang }

    struct Published: Sendable {
        var topic: String
        var payload: JSONValue
        var clientToken: String? { payload["clientToken"]?.stringValue }
        var desired: JSONValue? { payload["state"]?["desired"] }
    }

    private struct State {
        var behavior = ConnectBehavior.succeed
        var connections: [BrokerConnection] = []
        var configurations: [MQTTConfiguration] = []
        var published: [Published] = []
        var shadow: JSONValue = ["version": 3, "state": ["reported": ["systemState": ["pwsState": "idle"]]]]
        var respond: (@Sendable (Int, Published) -> (topic: String, payload: JSONValue)?)?
    }

    private let state = NIOLockedValueBox(State())

    var behavior: ConnectBehavior {
        get { state.withLockedValue { $0.behavior } }
        set { state.withLockedValue { $0.behavior = newValue } }
    }

    var shadow: JSONValue {
        get { state.withLockedValue { $0.shadow } }
        set { state.withLockedValue { $0.shadow = newValue } }
    }

    /// Answers publish number `n` (from 1); nil sends nothing back.
    func respond(_ handler: @escaping @Sendable (Int, Published) -> (topic: String, payload: JSONValue)?) {
        state.withLockedValue { $0.respond = handler }
    }

    var connections: [BrokerConnection] { state.withLockedValue { $0.connections } }
    /// How many connections the plugin made.
    var connectCount: Int { state.withLockedValue { $0.configurations.count } }
    var published: [Published] { state.withLockedValue { $0.published } }
    var lastConfiguration: MQTTConfiguration? { state.withLockedValue { $0.configurations.last } }

    /// The URL the last connection would open now: presigned with the credentials of the moment.
    func presignedURL() async throws -> URL {
        guard case .webSocket(let url, _)? = lastConfiguration?.transport else { throw FakeError.refused }
        return try await url()
    }

    /// What the plugin's `Dependencies.mqtt` and `ShadowClient` take.
    var factory: ShadowClient.MQTTFactory { { configuration in try await self.makeConnection(configuration) } }

    private func makeConnection(_ configuration: MQTTConfiguration) async throws -> any MQTTConnection {
        let behavior = state.withLockedValue { state in
            state.configurations.append(configuration)
            return state.behavior
        }
        let connection = BrokerConnection(broker: self)
        switch behavior {
        case .succeed:
            state.withLockedValue { $0.connections.append(connection) }
        case .fail:
            connection.mqtt.failConnects(with: [FakeError.refused])
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return connection
    }

    fileprivate func didPublish(_ message: MQTTMessage, on connection: BrokerConnection) {
        let message = Published(topic: message.topic, payload: (try? JSONValue(data: message.payload)) ?? .null)
        let (count, respond, shadow) = state.withLockedValue { state in
            state.published.append(message)
            return (state.published.count, state.respond, state.shadow)
        }
        let reply: (topic: String, payload: JSONValue)?
        if let respond {
            reply = respond(count, message)
        } else {
            let kind = message.topic.hasSuffix("/get") ? "get" : "update"
            var answer = shadow
            if case .object(var object) = answer, let token = message.clientToken {
                object["clientToken"] = .string(token)
                answer = .object(object)
            }
            reply = (message.topic.replacingOccurrences(of: "/shadow/\(kind)", with: "/shadow/\(kind)/accepted"), answer)
        }
        if let reply { connection.deliver(topic: reply.topic, payload: reply.payload) }
    }
}

enum FakeError: Error { case refused }

/// One connection to `FakeBroker`: a `FakeMQTTConnection` whose publishes the broker answers.
final class BrokerConnection: MQTTConnection, @unchecked Sendable {
    let mqtt = FakeMQTTConnection()
    private weak var broker: FakeBroker?
    private let closed = NIOLockedValueBox(false)

    init(broker: FakeBroker) { self.broker = broker }

    /// Closed by the plugin.
    var isClosed: Bool { closed.withLockedValue { $0 } }
    var subscriptions: Set<String> { Set(mqtt.subscriptions.keys) }

    func connect() async throws { try await mqtt.connect() }

    func disconnect() async {
        closed.withLockedValue { $0 = true }
        await mqtt.disconnect()
    }

    func subscribe(_ topic: String, qos: MQTTQoS) async throws { try await mqtt.subscribe(topic, qos: qos) }
    func unsubscribe(_ topic: String) async throws { try await mqtt.unsubscribe(topic) }

    func publish(_ message: MQTTMessage) async throws {
        try await mqtt.publish(message)
        broker?.didPublish(message, on: self)
    }

    var messages: AsyncStream<MQTTMessage> { mqtt.messages }
    var states: AsyncStream<MQTTConnectionState> { mqtt.states }

    /// The connection drops and every reconnection attempt fails until the plugin gives up.
    func giveUp() {
        mqtt.setState(.connectionLost("dropped"))
        for _ in 0...ShadowClient.maximumReconnectAttempts { mqtt.setState(.connecting) }
    }

    /// A message from the broker, a moment later as on a network.
    func deliver(topic: String, payload: JSONValue) {
        let mqtt = mqtt
        Task {
            try? await Task.sleep(for: .milliseconds(1))
            mqtt.receive(topic, payload: payload.encoded())
        }
    }
}

// MARK: The cloud, for devices and the plugin

/// The cloud as devices and the plugin see it.
final class FakeCloud: DolphinCloud, @unchecked Sendable {
    private struct State {
        var loginError: (any Error)?
        var robots: [RobotInfo] = [RobotInfo(serialNumber: "E3086OFG2M", name: "Pool Bot", model: "Dolphin M400", deviceType: 62)]
        var shadow: JSONValue?
        var lastPush: ContinuousClock.Instant?
        var accepts = true
        var acceptsMode = true
        var observers: [UUID: @Sendable (JSONValue) async -> Void] = [:]
        var calls: [String] = []
        var disconnected = false
    }

    private let state = NIOLockedValueBox(State())

    func configure(_ change: (inout FakeCloudSettings) -> Void) {
        state.withLockedValue { state in
            var settings = FakeCloudSettings(loginError: state.loginError, shadow: state.shadow, lastPush: state.lastPush, accepts: state.accepts, acceptsMode: state.acceptsMode, robots: state.robots)
            change(&settings)
            state.loginError = settings.loginError
            state.shadow = settings.shadow
            state.lastPush = settings.lastPush
            state.accepts = settings.accepts
            state.acceptsMode = settings.acceptsMode
            state.robots = settings.robots
        }
    }

    var calls: [String] { state.withLockedValue { $0.calls } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    var observerCount: Int { state.withLockedValue { $0.observers.count } }
    var isDisconnected: Bool { state.withLockedValue { $0.disconnected } }

    private func record(_ call: String) { state.withLockedValue { $0.calls.append(call) } }

    /// A shadow pushed over MQTT.
    func push(_ shadow: JSONValue) async {
        let observers = state.withLockedValue { $0.observers.values }
        for observer in observers { await observer(shadow) }
    }

    func login() async throws -> LoginResult {
        record("login")
        if let error = state.withLockedValue({ $0.loginError }) { throw error }
        let robot = state.withLockedValue { $0.robots.first }
        return LoginResult(serialNumber: robot?.serialNumber ?? "", robotName: robot?.name ?? "", deviceType: robot?.deviceType ?? 62)
    }

    func robots() async -> [RobotInfo] { state.withLockedValue { $0.robots } }

    func thingShadow(serialNumber: String) async -> JSONValue? {
        record("shadow \(serialNumber)")
        return state.withLockedValue { $0.shadow }
    }

    func lastShadowReceivedAt() async -> ContinuousClock.Instant? { state.withLockedValue { $0.lastPush } }

    func startRobot(serialNumber: String) async -> Bool {
        record("start \(serialNumber)")
        return state.withLockedValue { $0.accepts }
    }

    func stopRobot(serialNumber: String) async -> Bool {
        record("stop \(serialNumber)")
        return state.withLockedValue { $0.accepts }
    }

    func setCleaningMode(serialNumber: String, mode: String) async -> Bool {
        record("mode \(mode)")
        return state.withLockedValue { $0.acceptsMode }
    }

    func addShadowObserver(_ handler: @escaping @Sendable (JSONValue) async -> Void) async -> UUID {
        let id = UUID()
        state.withLockedValue { $0.observers[id] = handler }
        return id
    }

    func removeShadowObserver(_ id: UUID) async { _ = state.withLockedValue { $0.observers.removeValue(forKey: id) } }

    func disconnect() async {
        record("disconnect")
        state.withLockedValue { $0.disconnected = true }
    }
}

struct FakeCloudSettings {
    var loginError: (any Error)?
    var shadow: JSONValue?
    var lastPush: ContinuousClock.Instant?
    var accepts: Bool
    var acceptsMode: Bool
    var robots: [RobotInfo]
}
