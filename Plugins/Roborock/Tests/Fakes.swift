import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftRoborock

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Records an issue unless `condition` holds within `timeout` (no `await` inside `#expect`, which Linux rejects).
func expectEventually(
    timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () async -> Bool
) async {
    let held = await eventually(timeout: timeout, condition)
    #expect(held, sourceLocation: sourceLocation)
}

enum Sample {
    static let duid = "DUID00000000000001AB"
    static let sharedDUID = "DUID00000000000002CD"
    static let otherDUID = "DUID00000000000003EF"
    static let localKey = "0123456789abcdef"
    static let ip = "192.0.2.10"
    static let homeID = 123456
    /// Bit 37 set: the dock washes the mop.
    static let washingFeatures = "137438953472"

    static let session: JSONValue = [
        "uid": 1, "token": "rr-token", "rruid": "rr1", "region": "eu",
        "rriot": ["u": "u_example", "s": "s_example", "h": "h_example", "k": "k_example",
                  "r": ["r": "EU", "a": "https://api-eu.roborock.com", "m": "ssl://mqtt-eu.roborock.com:8883"]],
    ]

    static func device(_ duid: String, name: String, online: Bool = true, featureSet: String = washingFeatures, pv: String = "1.0", key: String? = localKey) -> JSONValue {
        var device: [String: JSONValue] = [
            "duid": .string(duid), "name": .string(name), "productId": "prod-1", "fv": "02.29.02", "pv": .string(pv),
            "online": .bool(online), "sn": "R0000000000000", "featureSet": .string(featureSet),
            "deviceStatus": ["120": 0, "121": 8, "122": 100, "133": 1],
        ]
        if let key { device["localKey"] = .string(key) }
        return .object(device)
    }

    static func home(devices: [JSONValue]? = nil, shared: [JSONValue] = []) -> JSONValue {
        [
            "id": 1, "name": "Home",
            "products": [[
                "id": "prod-1", "name": "Roborock S7", "model": "roborock.vacuum.a15",
                "schema": [["id": "120", "code": "error_code"], ["id": 121, "code": "state"], ["id": "122", "code": "battery"], ["id": "133", "code": "charge_status"]],
            ]],
            "devices": .array(devices ?? [device(duid, name: "Robbie")]),
            "receivedDevices": .array(shared),
            "rooms": [["id": 11, "name": "Kitchen"]],
        ]
    }

    static func scene(_ id: Int, name: String, duid: String = Sample.duid, enabled: Bool = true) -> JSONValue {
        let inner = JSONValue.object(["id": 1, "method": "do_scenes_segments", "params": ["segments": [16]]]).text()
        let param = JSONValue.object(["triggers": [], "action": ["type": "S", "items": [["id": 1, "type": "CMD", "entityId": .string(duid), "param": .string(inner)]]]]).text()
        return ["id": .number(Double(id)), "name": .string(name), "enabled": .bool(enabled), "type": "WORKFLOW", "param": .string(param)]
    }
}

/// The cloud's HTTP endpoints, answered from canned JSON.
final class FakeCloud: HTTPSending {
    struct State {
        var requests: [HomeswiftNetwork.HTTPRequest] = []
        var home = Sample.home()
        var scenes: [JSONValue] = []
        var loginResponse: JSONValue = ["code": 200, "data": Sample.session]
        var codeLoginResponse: JSONValue = ["code": 200, "data": Sample.session]
        var homeStatus = 200
        var homeDate: String?
    }

    let state = NIOLockedValueBox(State())

    var requests: [HomeswiftNetwork.HTTPRequest] { state.withLockedValue { $0.requests } }
    func paths() -> [String] { requests.map { "\($0.method) \($0.url.path)" } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let snapshot = state.withLockedValue { state in
            state.requests.append(request)
            return state
        }
        func json(_ value: JSONValue, status: Int = 200, headers: [(name: String, value: String)] = []) -> HomeswiftNetwork.HTTPResponse {
            HomeswiftNetwork.HTTPResponse(status: status, headers: headers, body: value.encoded())
        }
        let path = request.url.path
        switch path {
        case "/api/v1/getUrlByEmail":
            return json(["code": 200, "data": ["url": "https://euiot.roborock.com", "country": "FR", "countrycode": "33"]])
        case "/api/v3/key/sign": return json(["code": 200, "data": ["k": "ABCDEFGHIJKLMNOP"]])
        case "/api/v3/app/agreement/latest": return json(["code": 200, "data": ["majorVersion": 15, "minorVersion": 1]])
        case "/api/v4/email/code/send": return json(["code": 200, "msg": "success"])
        case "/api/v4/auth/email/login/pwd": return json(snapshot.loginResponse)
        case "/api/v4/auth/email/login/code": return json(snapshot.codeLoginResponse)
        case "/api/v1/getHomeDetail": return json(["code": 200, "data": ["rrHomeId": .number(Double(Sample.homeID))]])
        case "/v2/user/homes/\(Sample.homeID)", "/user/homes/\(Sample.homeID)":
            if snapshot.homeStatus != 200 {
                return HomeswiftNetwork.HTTPResponse(status: snapshot.homeStatus, headers: snapshot.homeDate.map { [("Date", $0)] } ?? [])
            }
            return json(["api": 1, "result": snapshot.home, "status": "ok", "success": true])
        case "/user/scene/home/\(Sample.homeID)": return json(["result": .array(snapshot.scenes)])
        default:
            if path.hasPrefix("/user/scene/") { return json(["result": true]) }
            return HomeswiftNetwork.HTTPResponse(status: 404)
        }
    }
}

/// A robot's local port in memory: it reads each request frame with the local key and answers with a protocol-4
/// frame, as the robot does. Each connection is a link of its own.
final class FakeRobot: Sendable {
    struct State {
        var methods: [String] = []
        var answers: [String: JSONValue] = [:]
        var silent: Set<String> = []
        var connections = 0
    }

    let duid: String
    let localKey: String
    let state = NIOLockedValueBox(State())

    init(duid: String, localKey: String = Sample.localKey) {
        self.duid = duid
        self.localKey = localKey
        state.withLockedValue {
            $0.answers = [
                "get_status": [["state": 8, "battery": 90, "charge_status": 1, "error_code": 0, "in_cleaning": 0]],
                "get_consumable": [["main_brush_work_time": 324000, "side_brush_work_time": 360000, "filter_work_time": 513000]],
            ]
        }
    }

    var methods: [String] { state.withLockedValue { $0.methods } }
    var connections: Int { state.withLockedValue { $0.connections } }

    func answer(_ method: String, with result: JSONValue) { state.withLockedValue { $0.answers[method] = result } }

    func silence(_ method: String) { state.withLockedValue { _ = $0.silent.insert(method) } }

    func link() -> Link {
        state.withLockedValue { $0.connections += 1 }
        return Link(robot: self)
    }

    /// The answer frames to a request's bytes.
    func handle(_ data: Data) throws -> [Data] {
        var buffer = LengthPrefixedBuffer()
        var replies: [Data] = []
        for segment in try buffer.append(data) {
            let frame = try RoborockFrame.decode(segment)
            guard frame.protocolNumber == RoborockFrameProtocol.localRequest else { continue }
            let plain = try RoborockCipher.decrypt(frame.payload, frame: frame, localKey: localKey, nonces: nil)
            let body = try JSONValue(data: plain)
            let inner = try JSONValue(string: try #require(body["dps"]?["4"]?.stringValue))
            let method = try #require(inner["method"]?.stringValue), id = try #require(inner["id"]?.intValue)
            let (answer, silent) = state.withLockedValue { state -> (JSONValue, Bool) in
                state.methods.append(method)
                return (state.answers[method] ?? ["ok"], state.silent.contains(method))
            }
            guard !silent else { continue }
            replies.append(reply(id: id, result: answer))
        }
        return replies
    }

    func reply(id: Int, result: JSONValue) -> Data {
        var frame = RoborockFrame(version: .v1, seq: 77, random: 99, timestamp: 1_700_000_005, protocolNumber: RoborockFrameProtocol.localRequest)
        let inner = JSONValue.object(["id": .number(Double(id)), "result": result]).text()
        let body = JSONValue.object(["dps": ["102": .string(inner)], "t": 1_700_000_005]).encoded()
        frame.payload = try! RoborockCipher.encrypt(body, frame: frame, localKey: localKey, nonces: nil)
        return frame.lengthPrefixed()
    }

    final class Link: LocalLink {
        let robot: FakeRobot
        let received: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation

        init(robot: FakeRobot) {
            self.robot = robot
            (received, continuation) = AsyncStream.makeStream(of: Data.self)
        }

        func send(_ data: Data) async throws {
            for reply in try robot.handle(data) { continuation.yield(reply) }
        }

        func close() async { continuation.finish() }
    }
}

/// Connects to the fake robots by IP; any other address is refused.
final class FakeDialer: LocalDialing {
    let robots = NIOLockedValueBox<[String: FakeRobot]>([:])
    let attempts = NIOLockedValueBox<[String]>([])

    func add(_ robot: FakeRobot, at ip: String) { robots.withLockedValue { $0[ip] = robot } }

    func connect(host: String, port: Int, timeout: Duration) async throws -> any LocalLink {
        attempts.withLockedValue { $0.append(host) }
        guard port == 58867, let robot = robots.withLockedValue({ $0[host] }) else { throw RoborockRequestError.refused("connection refused") }
        return robot.link()
    }
}

/// Answers the cloud requests a fake broker receives, as the robots behind it would.
func answerCloud(_ mqtt: FakeMQTTConnection, localKey: String = Sample.localKey, result: @escaping @Sendable (String) -> JSONValue = { _ in ["ok"] }) -> Task<Void, Never> {
    Task {
        var seen = 0
        while !Task.isCancelled {
            let published = mqtt.published
            for message in published.dropFirst(seen) {
                guard let frame = try? RoborockFrame.decode(message.payload), frame.protocolNumber == RoborockFrameProtocol.cloudRequest,
                    let plain = try? RoborockCipher.decrypt(frame.payload, frame: frame, localKey: localKey, nonces: nil),
                    let inner = (try? JSONValue(data: plain))?["dps"]?["101"]?.stringValue.flatMap({ try? JSONValue(string: $0) }),
                    let id = inner["id"]?.intValue, let method = inner["method"]?.stringValue
                else { continue }
                let duid = String(message.topic.split(separator: "/").last ?? "")
                var reply = RoborockFrame(version: .v1, seq: 5, random: 6, timestamp: 1_700_000_005, protocolNumber: RoborockFrameProtocol.response)
                let body = JSONValue.object(["dps": ["102": .string(JSONValue.object(["id": .number(Double(id)), "result": result(method)]).text())], "t": 1]).encoded()
                reply.payload = try! RoborockCipher.encrypt(body, frame: reply, localKey: localKey, nonces: nil)
                mqtt.receive("rr/m/o/u_example/bb7e313c/\(duid)", payload: reply.encoded())
            }
            seen = published.count
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A host with one Roborock block on fakes.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Roborock-tests-\(UUID().uuidString)")
    let cloud = FakeCloud()
    let dialer = FakeDialer()
    let mqtt = FakeMQTTConnection()
    let robot = FakeRobot(duid: Sample.duid)
    let discovered = NIOLockedValueBox<[String: String]>([Sample.duid: Sample.ip])
    private let plugins = NIOLockedValueBox<[RoborockPlugin]>([])

    static let timings: RoborockTimings = {
        var timings = RoborockTimings.standard
        timings.requestTimeout = .milliseconds(500)
        timings.reconnect = .milliseconds(100)
        timings.handshake = .milliseconds(200)
        timings.probe = .milliseconds(30)
        timings.homeRefresh = .seconds(600)
        timings.activePoll = .seconds(600)
        timings.scenePoll = .milliseconds(30)
        timings.sceneSwitchReset = .milliseconds(50)
        timings.udpListen = .milliseconds(10)
        return timings
    }()

    init() {
        dialer.add(robot, at: Sample.ip)
    }

    var plugin: RoborockPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = ["email": "user@example.com", "password": "hunter2"], timings: RoborockTimings = TestEnvironment.timings) async throws -> PluginHost {
        var registry = PluginRegistry()
        let mqtt = mqtt, discovered = discovered
        registry.register(platform: RoborockPlugin.platform, name: RoborockPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(RoborockPlugin.Configuration.self, from: json)
            let dependencies = RoborockPlugin.Dependencies(
                transport: self.cloud, dialer: self.dialer, makeMQTT: { _ in mqtt },
                discoverIPs: { known in discovered.withLockedValue { $0 }.filter { known.contains($0.key) } }, timings: timings)
            let plugin = RoborockPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: RoborockPlugin.platform, name: RoborockPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    func accessory(_ host: PluginHost, duid: String = Sample.duid) -> Accessory? {
        host.mainBridge.server.accessories.first { $0.id == RoborockPlugin.accessoryID(duid: duid) }
    }
}
