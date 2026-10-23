import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// Plugin time runs a hundred times faster in tests: a 10 s timer lasts 100 ms.
let testClock = EWeLinkClock(scale: 0.01)

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A device as the cloud lists it.
func device(_ id: String, uiid: Int, name: String = "Device", params: JSONValue = [:], online: Bool = true, extra: [String: JSONValue] = [:]) -> JSONValue {
    var raw: [String: JSONValue] = [
        "deviceid": .string(id), "name": .string(name), "brandName": "SONOFF", "productModel": "BASIC", "online": .bool(online),
        "apikey": "device-api-key", "devicekey": "a1b2c3d4-e5f6-7890-abcd-ef0123456789",
        "extra": ["uiid": .number(Double(uiid)), "model": "PSF-B01-GL"], "params": params,
    ]
    for (key, value) in extra { raw[key] = value }
    return .object(raw)
}

/// The eWeLink cloud's HTTP API in memory.
final class FakeCloud: HTTPSending, @unchecked Sendable {
    struct State {
        var devices: [JSONValue] = []
        var groups: [JSONValue] = []
        var homes: [String] = ["home-1"]
        /// Answers to the next logins, in order; then success.
        var loginAnswers: [JSONValue] = []
        /// The access token the API accepts; others get `error: 401` (or HTTP 401 with `httpTokenErrors`).
        var validToken = "access-token-1"
        var httpTokenErrors = false
        var refreshCount = 0
        var failRefresh = false
        var dispatchDomain: String? = "eu-pconnect9.coolkit.cc"
        var statusError = 0
        var requests: [HomeswiftNetwork.HTTPRequest] = []
        var loginBodies: [String] = []
        var unreachable = false
    }

    let state = NIOLockedValueBox(State())

    func update(_ change: (inout State) -> Void) { state.withLockedValue(change) }
    var requests: [HomeswiftNetwork.HTTPRequest] { state.withLockedValue { $0.requests } }
    func requests(path: String) -> [HomeswiftNetwork.HTTPRequest] { requests.filter { $0.url.path == path } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        try await Task.sleep(for: .milliseconds(1))
        return try state.withLockedValue { state in
            state.requests.append(request)
            if state.unreachable { throw URLError(.cannotConnectToHost) }
            func answer(_ json: JSONValue, status: Int = 200) -> HomeswiftNetwork.HTTPResponse { HomeswiftNetwork.HTTPResponse(status: status, body: json.encoded()) }
            let authorized = request.header("Authorization") == "Bearer \(state.validToken)"
            switch request.url.path {
            case "/v2/user/login":
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                state.loginBodies.append(body)
                if !state.loginAnswers.isEmpty { return answer(state.loginAnswers.removeFirst()) }
                return answer(["error": 0, "data": ["at": .string(state.validToken), "rt": "refresh-token-1", "user": ["apikey": "user-api-key"]]])
            case "/v2/user/refresh":
                state.refreshCount += 1
                if state.failRefresh { return answer(["error": 401, "msg": "refresh failed"]) }
                state.validToken = "access-token-\(state.refreshCount + 1)"
                return answer(["error": 0, "data": ["at": .string(state.validToken), "rt": .string("refresh-token-\(state.refreshCount + 1)")]])
            case "/dispatch/app":
                guard let domain = state.dispatchDomain else { return answer(["error": "unavailable"], status: 503) }
                return answer(["domain": .string(domain)])
            default:
                break
            }
            guard authorized else {
                return state.httpTokenErrors ? answer(["error": 401], status: 401) : answer(["error": 401, "msg": "token expired"])
            }
            switch request.url.path {
            case "/v2/family":
                return answer(["error": 0, "data": ["familyList": .array(state.homes.map { ["id": .string($0), "name": "Home"] })]])
            case "/v2/device/thing":
                let things = state.devices.map { JSONValue.object(["itemType": 1, "itemData": $0]) } + state.groups.map { .object(["itemType": 3, "itemData": $0]) }
                return answer(["error": 0, "data": ["thingList": .array(things)]])
            case "/v2/device/thing/status":
                return answer(["error": .number(Double(state.statusError))])
            default:
                return answer(["error": 404], status: 404)
            }
        }
    }
}

/// The eWeLink WebSocket server in memory: accepts the login, answers commands, pushes updates.
final class FakeSocketServer: @unchecked Sendable {
    struct State {
        var sockets: [FakeWebSocket] = []
        var urls: [URL] = []
        var refuseConnections = false
        /// The error code of the `userOnline` answer.
        var authError = 0
        /// Commands get this error code (0 is success); nil leaves them unanswered.
        var commandError: Int? = 0
        var hbInterval = 145
        /// The next socket drops right after it answers the `userOnline`.
        var dropAfterAuthentication = false
    }

    let state = NIOLockedValueBox(State())

    func update(_ change: (inout State) -> Void) { state.withLockedValue(change) }
    var current: FakeWebSocket? { state.withLockedValue { $0.sockets.last } }
    var connections: Int { state.withLockedValue { $0.sockets.count } }

    /// Every message the plugin sent but its pings, parsed, on every socket.
    var sent: [JSONValue] {
        state.withLockedValue { $0.sockets.flatMap(\.sentText) }.filter { $0 != "ping" }.compactMap { try? JSONValue(string: $0) }
    }

    /// The `params` of every `update` command but the `uiActive` polls.
    var commands: [JSONValue] { sent.filter { $0["action"] == "update" }.compactMap { $0["params"] }.filter { $0["uiActive"] == nil } }

    /// `CloudSocket.Connect` for the plugin.
    func connect(to url: URL, options: WebSocket.Options) throws -> any WebSocketConnection {
        let socket = try state.withLockedValue { state -> FakeWebSocket in
            if state.refuseConnections { throw URLError(.cannotConnectToHost) }
            let socket = FakeWebSocket(url: url)
            state.sockets.append(socket)
            state.urls.append(url)
            return socket
        }
        socket.onSend { [weak self, weak socket] message in
            guard let self, let socket, let text = message.text else { return }
            self.answer(text, on: socket)
        }
        return socket
    }

    /// What the eWeLink server answers.
    private func answer(_ text: String, on socket: FakeWebSocket) {
        if text == "ping" {
            socket.receive(text: "pong")
            return
        }
        guard let message = try? JSONValue(string: text) else { return }
        let state = state.withLockedValue { $0 }
        switch message["action"]?.stringValue {
        case "userOnline":
            socket.receive(text: JSONValue.object(["error": .number(Double(state.authError)), "config": ["hb": 1, "hbInterval": .number(Double(state.hbInterval))], "sequence": message["sequence"] ?? .null]).text())
            if state.dropAfterAuthentication {
                update { $0.dropAfterAuthentication = false }
                socket.drop()
            }
        case "update":
            guard let code = state.commandError else { return }
            socket.receive(text: JSONValue.object(["error": .number(Double(code)), "sequence": message["sequence"] ?? .null, "deviceid": message["deviceid"] ?? .null]).text())
        case "query":
            socket.receive(text: JSONValue.object(["error": 0, "sequence": message["sequence"] ?? .null, "deviceid": message["deviceid"] ?? .null, "params": ["switch": "on"]]).text())
        default:
            break
        }
    }

    /// Pushes a message to the plugin on the open socket.
    func push(_ message: JSONValue) { current?.receive(text: message.text()) }
}

/// The LAN in memory: services to announce, datagrams to deliver, devices that answer HTTP.
final class FakeLAN: LANNetwork, @unchecked Sendable {
    struct State {
        var browsers: [AsyncStream<LANServiceEvent>.Continuation] = []
        var announced: [LANServiceEvent] = []
        var listeners: [FakeListener] = []
        var posts: [(url: URL, body: JSONValue)] = []
        /// The `error` devices answer with; nil fails the request.
        var answer: Int? = 0
    }

    let state = NIOLockedValueBox(State())

    func update(_ change: (inout State) -> Void) { state.withLockedValue(change) }
    var posts: [(url: URL, body: JSONValue)] { state.withLockedValue { $0.posts } }

    func browse(logger: Logger) -> AsyncStream<LANServiceEvent> {
        let (stream, continuation) = AsyncStream<LANServiceEvent>.makeStream()
        state.withLockedValue { state in
            for event in state.announced { continuation.yield(event) }
            state.browsers.append(continuation)
        }
        return stream
    }

    /// Announces a service now and to later browsers.
    func announce(_ event: LANServiceEvent) {
        let browsers = state.withLockedValue { state in
            state.announced.append(event)
            return state.browsers
        }
        for browser in browsers { browser.yield(event) }
    }

    func listen(port: Int, logger: Logger) async throws -> any LANDatagramListener {
        let listener = FakeListener()
        state.withLockedValue { $0.listeners.append(listener) }
        return listener
    }

    func deliver(_ message: JSONValue, from address: String) {
        state.withLockedValue { $0.listeners.last }?.continuation.yield((message.encoded(), address))
    }

    func post(_ url: URL, body: Data, timeout: Int) async throws -> Data {
        let answer = try state.withLockedValue { state -> Int? in
            state.posts.append((url, try JSONValue(data: body)))
            return state.answer
        }
        guard let answer else { throw URLError(.timedOut) }
        return JSONValue.object(["error": .number(Double(answer))]).encoded()
    }
}

final class FakeListener: LANDatagramListener, @unchecked Sendable {
    let datagrams: AsyncStream<(data: Data, address: String)>
    let continuation: AsyncStream<(data: Data, address: String)>.Continuation

    init() {
        (datagrams, continuation) = AsyncStream<(data: Data, address: String)>.makeStream()
    }

    func close() async { continuation.finish() }
}

/// A LAN whose UDP socket opens only when the test says so, for `stop()` during `start()`.
final class SlowLAN: LANNetwork, @unchecked Sendable {
    struct State {
        var waiting = false
        var release = false
    }

    final class Listener: LANDatagramListener, @unchecked Sendable {
        let datagrams = AsyncStream<(data: Data, address: String)> { _ in }
        let closed = NIOLockedValueBox(false)
        func close() async { closed.withLockedValue { $0 = true } }
    }

    let state = NIOLockedValueBox(State())
    let listener = Listener()

    func browse(logger: Logger) -> AsyncStream<LANServiceEvent> { AsyncStream { _ in } }

    func listen(port: Int, logger: Logger) async throws -> any LANDatagramListener {
        state.withLockedValue { $0.waiting = true }
        while !state.withLockedValue({ $0.release }) { try await Task.sleep(for: .milliseconds(5)) }
        return listener
    }

    func post(_ url: URL, body: Data, timeout: Int) async throws -> Data { throw URLError(.timedOut) }
}

/// A host with one eWeLink block whose plugin talks to the fakes.
final class EWeLinkTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-ewelink-tests-\(UUID().uuidString)")
    let cloud = FakeCloud()
    let socket = FakeSocketServer()
    let lan = FakeLAN()
    private let plugins = NIOLockedValueBox<[EWeLinkPlugin]>([])
    /// Plugin time; slower than `testClock` for tests whose windows are short.
    let clock: EWeLinkClock
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    init(clock: EWeLinkClock = testClock) {
        self.clock = clock
    }

    var plugin: EWeLinkPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: EWeLinkPlugin.Dependencies {
        let socket = socket
        return EWeLinkPlugin.Dependencies(
            transport: cloud, connectSocket: { url, options in try socket.connect(to: url, options: options) }, lanNetwork: lan, clock: clock,
            random: { 0.5 }, lanScanDuration: 2000)
    }

    static var account: [String: Any] { ["username": "user@example.com", "password": "secret", "countryCode": "+351"] }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: EWeLinkPlugin.platform, name: EWeLinkPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(EWeLinkPlugin.Configuration.self, from: json)
            let plugin = EWeLinkPlugin(configuration: configuration, context: context, dependencies: self.dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: EWeLinkPlugin.platform, name: "eWeLink", settings: settings)
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

    /// Starts a host with the account and `settings`, the cloud listing `devices`, and waits for discovery.
    func start(devices: [JSONValue] = [], groups: [JSONValue] = [], settings: [String: Any] = [:]) async throws -> PluginHost {
        cloud.update {
            $0.devices = devices
            $0.groups = groups
        }
        let host = try host(settings: Self.account.merging(settings) { $1 })
        try await host.start()
        await plugin?.settle()
        return host
    }

    func accessory(_ host: PluginHost, _ deviceID: String) -> Accessory? {
        host.mainBridge.server.accessories.first { $0.id == "eWeLink:\(deviceID)" }
    }

    func platform() async -> EWeLinkPlatform? { await plugin?.platformCore() }

    /// Waits for the WebSocket to be up.
    func socketReady() async -> Bool {
        await eventually { await self.platform()?.socket?.isConnected ?? false }
    }

    /// Sends an update as the cloud would.
    func push(_ deviceID: String, _ params: JSONValue) {
        socket.push(["action": "update", "deviceid": .string(deviceID), "params": params])
    }
}

extension Characteristic {
    /// A write from HomeKit: the handler, then the value.
    func homeKitWrite(_ value: HAPValue) async throws {
        try await write(value)
    }

    func read() async throws -> HAPValue {
        if let handler = readHandler { return try await handler() }
        return value
    }
}
