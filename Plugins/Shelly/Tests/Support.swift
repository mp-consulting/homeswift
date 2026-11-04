import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftShelly

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
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

/// Expects `condition` to hold within `timeout`. (Swift Testing on Linux takes no `await` inside `#expect`.)
func expectEventually(_ comment: @autoclosure () -> String = "", timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: @Sendable () async -> Bool) async {
    let held = await eventually(timeout: timeout, condition)
    #expect(held, "\(comment())", sourceLocation: sourceLocation)
}

func json(_ text: String) -> JSONValue { try! JSONValue(string: text) }

/// A Gen 2+ device behind a fake WebSocket: answers `Shelly.GetDeviceInfo`, `GetStatus` and `GetConfig` from fixtures,
/// records every frame, challenges with a digest when it has a password, and pushes notifications.
final class FakeShellyNG: Sendable {
    let info: JSONValue
    private let state: NIOLockedValueBox<State>

    struct State {
        var status: JSONValue
        var config: JSONValue
        var password: String?
        var frames: [JSONValue] = []
        var sockets: [FakeWebSocket] = []
        var connections = 0
        var reachable = true
        var nonce = 1_700_000_000
    }

    init(info: String, status: String, config: String = "{}", password: String? = nil) {
        self.info = json(info)
        state = NIOLockedValueBox(State(status: json(status), config: json(config), password: password))
    }

    var id: String { info["id"]?.stringValue ?? "" }
    var frames: [JSONValue] { state.withLockedValue { $0.frames } }
    var connections: Int { state.withLockedValue { $0.connections } }
    var socket: FakeWebSocket? { state.withLockedValue { $0.sockets.last } }
    func setReachable(_ reachable: Bool) { state.withLockedValue { $0.reachable = reachable } }

    /// Frames of `method`, in order.
    func calls(_ method: String) -> [JSONValue] { frames.filter { $0["method"]?.stringValue == method } }

    func connect(_ url: URL) throws -> any WebSocketConnection {
        let socket = FakeWebSocket(url: url)
        try state.withLockedValue { state in
            guard state.reachable else { throw WebSocketError.connectionLost }
            state.connections += 1
            state.sockets.append(socket)
        }
        socket.onSend { [weak self, weak socket] message in
            guard let self, let socket, let text = message.text, let frame = try? JSONValue(string: text) else { return }
            socket.receive(text: self.answer(frame).text())
        }
        return socket
    }

    private func answer(_ frame: JSONValue) -> JSONValue {
        let id = frame["id"] ?? .null
        let method = frame["method"]?.stringValue ?? ""
        let (password, nonce, status, config) = state.withLockedValue { state in
            state.frames.append(frame)
            return (state.password, state.nonce, state.status, state.config)
        }
        func reply(_ result: JSONValue) -> JSONValue { ["id": id, "src": .string(self.id), "dst": frame["src"] ?? .null, "result": result] }
        if let password, method != "Shelly.GetDeviceInfo" {
            let challenge = #"{"auth_type":"digest","nonce":\#(nonce),"nc":1,"realm":"\#(self.id)","algorithm":"SHA-256"}"#
            let auth = frame["auth"]
            let expected = auth.map { auth -> String in
                RPCDigest(realm: self.id, nonce: .number(Double(nonce)), nc: auth["nc"]?.intValue ?? 1)
                    .response(password: password, cnonce: auth["cnonce"]?.decimalText ?? "")
            }
            if auth == nil || auth?["response"]?.stringValue != expected {
                return ["id": id, "src": .string(self.id), "error": ["code": 401, "message": .string(challenge)]]
            }
        }
        switch method {
        case "Shelly.GetDeviceInfo": return reply(info)
        case "Shelly.GetStatus": return reply(status)
        case "Shelly.GetConfig": return reply(config)
        case "Switch.Set": return reply(["was_on": false])
        default: return reply(.null)
        }
    }

    /// A notification from the device.
    func notify(_ method: String, _ params: String) {
        socket?.receive(text: JSONValue.object(["src": .string(id), "dst": "homeswift", "method": .string(method), "params": json(params)]).text())
    }
}

/// HTTP in memory: answers by path and records each request.
final class FakeHTTP: HTTPSending, Sendable {
    private let state = NIOLockedValueBox<(requests: [HomeswiftNetwork.HTTPRequest], answers: [String: (Int, String)])>(([], [:]))

    func answer(_ path: String, status: Int = 200, _ body: String) { state.withLockedValue { $0.answers[path] = (status, body) } }

    var requests: [HomeswiftNetwork.HTTPRequest] { state.withLockedValue { $0.requests } }
    /// Each request's path and query, as `/relay/0?turn=on`.
    var paths: [String] {
        requests.map { request in
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            return (components?.path ?? "") + (components?.query.map { "?\($0)" } ?? "")
        }
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let answer = state.withLockedValue { state -> (Int, String)? in
            state.requests.append(request)
            return state.answers[path]
        }
        guard let (status, body) = answer else { return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("{}".utf8)) }
        return HomeswiftNetwork.HTTPResponse(status: status, body: Data(body.utf8))
    }
}

/// CoIoT datagrams a test sends.
final class FakeCoIoT: CoIoTListener {
    let datagrams: AsyncStream<(data: Data, address: String)>
    private let continuation: AsyncStream<(data: Data, address: String)>.Continuation
    private let sentBox = NIOLockedValueBox<[Data]>([])

    init() { (datagrams, continuation) = AsyncStream.makeStream() }

    func receive(_ bytes: [UInt8], from address: String = "10.0.0.5") { continuation.yield((Data(bytes), address)) }
    func send(_ data: Data, to host: String, port: Int) async throws { sentBox.withLockedValue { $0.append(data) } }
    func close() async { continuation.finish() }
    var sent: [Data] { sentBox.withLockedValue { $0 } }
}

/// A CoIoT status datagram: `<model>#<id>#<revision>`, a validity and the `G` tuples.
func coiot(_ model: String, _ id: String, revision: Int = 2, validity: UInt16 = 382, _ values: [(Int, Double)]) -> [UInt8] {
    let payload = #"{"G":[\#(values.map { "[0,\($0.0),\($0.1)]" }.joined(separator: ","))]}"#
    return CoAPMessage(type: .nonConfirmable, code: 30, messageID: 1, options: [
        .init(number: 11, value: Array("cit".utf8)), .init(number: 11, value: Array("s".utf8)),
        .init(number: 3332, value: Array("\(model)#\(id)#\(revision)".utf8)),
        .init(number: 3412, value: [UInt8(validity >> 8), UInt8(validity & 0xFF)]),
        .init(number: 3420, value: [0, 42]),
    ], payload: Array(payload.utf8)).encoded()
}

/// A host running one `ShellyNG` or `Shelly` block on fakes.
final class ShellyEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-shelly-tests-\(UUID().uuidString)")
    let devices = NIOLockedValueBox<[String: FakeShellyNG]>([:])
    let sightings: AsyncStream<ShellyNGPlugin.Sighting>
    private let sightingContinuation: AsyncStream<ShellyNGPlugin.Sighting>.Continuation
    let http = FakeHTTP()
    let coiot = FakeCoIoT()
    private let plugins = NIOLockedValueBox<(ng: ShellyNGPlugin?, gen1: ShellyPlugin?)>((nil, nil))

    init() { (sightings, sightingContinuation) = AsyncStream.makeStream() }

    var ng: ShellyNGPlugin? { plugins.withLockedValue { $0.ng } }
    var gen1: ShellyPlugin? { plugins.withLockedValue { $0.gen1 } }

    func add(_ device: FakeShellyNG, host: String = "10.0.0.9") { devices.withLockedValue { $0[host] = device } }

    /// mDNS announces a device.
    func announce(_ id: String, host: String) { sightingContinuation.yield(.init(deviceID: id, host: host)) }

    var ngDependencies: ShellyNGPlugin.Dependencies {
        let devices = devices, sightings = sightings, http = http
        return ShellyNGPlugin.Dependencies(
            connector: { url in
                guard let device = devices.withLockedValue({ $0[url.host ?? ""] }) else { throw WebSocketError.connectionLost }
                return try device.connect(url)
            },
            browse: { _, _ in sightings }, http: http, timeScale: 0.001, writeDelay: .milliseconds(10), discoveryWindow: .milliseconds(10))
    }

    var gen1Dependencies: ShellyPlugin.Dependencies {
        let coiot = coiot
        return ShellyPlugin.Dependencies(listen: { _ in coiot }, http: http, timeScale: 0.01, discoveryWindow: .milliseconds(10))
    }

    func start(platform: String = ShellyNGPlugin.platform, settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let ngDependencies = ngDependencies, gen1Dependencies = gen1Dependencies
        registry.register(platform: ShellyNGPlugin.platform, name: ShellyNGPlugin.name) { json, context in
            let plugin = ShellyNGPlugin(configuration: try JSONDecoder().decode(ShellyNGPlugin.Configuration.self, from: json), context: context,
                                        dependencies: ngDependencies)
            self.plugins.withLockedValue { $0.ng = plugin }
            return plugin
        }
        registry.register(platform: ShellyPlugin.platform, name: ShellyPlugin.name) { json, context in
            let plugin = ShellyPlugin(configuration: try JSONDecoder().decode(ShellyPlugin.Configuration.self, from: json), context: context,
                                      dependencies: gen1Dependencies)
            self.plugins.withLockedValue { $0.gen1 = plugin }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: platform, name: "Shelly", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? { mainBridge.server.accessories.first { $0.id == id } }
}

/// The Plus 1PM of the spec's test vectors (11.1, 11.2).
func plus1PM(password: String? = nil) -> FakeShellyNG {
    FakeShellyNG(
        info: #"{"id":"shellyplus1pm-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SNSW-001P16EU","gen":2,"fw_id":"20231219-133934/1.1.0-g34b5d4f","ver":"1.1.0","app":"Plus1PM","auth_en":\#(password != nil),"auth_domain":null,"name":"Kitchen","slot":0}"#,
        status: #"{"input:0":{"id":0,"state":false},"switch:0":{"id":0,"source":"WS_in","output":false,"apower":0.0,"voltage":232.8,"current":0.0,"aenergy":{"total":110.046,"by_minute":[0.0,0.0,0.0],"minute_ts":1707326934},"temperature":{"tC":30.3,"tF":86.6}},"sys":{"mac":"AABBCCDDEEFF","restart_required":false,"uptime":2622735,"cfg_rev":35}}"#,
        config: #"{"sys":{"device":{"name":"Kitchen"}},"switch:0":{"name":"Light"}}"#, password: password)
}
