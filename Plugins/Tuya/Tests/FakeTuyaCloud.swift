import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftTuya

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Tuya's cloud in memory: the answers of the spec's examples, by method and path, and the requests it was sent.
final class FakeTuyaCloud: HTTPSending {
    struct Sent: Sendable {
        var method: String
        var path: String
        var query: String?
        var body: String?
        var headers: [String: String]
    }

    private struct State {
        var answers: [String: JSONValue] = [:]
        var sent: [Sent] = []
        var failures: Set<String> = []
    }

    private let state = NIOLockedValueBox(State())

    init() {
        set("POST /v1.0/iot-01/associated-users/actions/authorized-login", [
            "access_token": "c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4", "refresh_token": "r1", "uid": "ay1700000000000abcd", "expire_time": 7200, "platform_url": "",
        ])
        set("POST /v1.0/iot-03/open-hub/access-config", [
            "url": "ssl://m1.tuyaeu.com:8883", "client_id": "cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c", "username": "cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c",
            "password": "f3a9c1d2e4b5a6978877665544332211", "expire_time": 7200,
            "source_topic": ["device": "cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"],
            "sink_topic": ["device": "cloud/token/out/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"],
        ])
        set("GET /v1.0/users/ay1700000000000abcd/homes", [["home_id": 12345678, "name": "Home"]])
        set("GET /v1.0/homes/12345678/devices", try! JSONValue(string: Self.deviceList))
        set("GET /v1.0/devices/bf0123456789abcdefgh/specifications", try! JSONValue(string: Self.lampSpecification))
        set("GET /v1.0/devices/bf9876543210zyxwvuts/specifications", try! JSONValue(string: Self.stripSpecification))
        set("GET /v1.1/homes/12345678/scenes", [["scene_id": "sc1", "name": "Movie", "enabled": true, "status": "1"], ["scene_id": "sc2", "name": "Off", "enabled": false, "status": "1"]])
        set("POST /v1.0/homes/12345678/scenes/sc1/trigger", true)
        set("POST /v1.0/devices/bf0123456789abcdefgh/commands", true)
        set("POST /v1.0/devices/bf9876543210zyxwvuts/commands", true)
    }

    func set(_ route: String, _ result: JSONValue) {
        state.withLockedValue { $0.answers[route] = result }
    }

    func fail(_ route: String) {
        state.withLockedValue { _ = $0.failures.insert(route) }
    }

    func unfail(_ route: String) {
        state.withLockedValue { _ = $0.failures.remove(route) }
    }

    var sent: [Sent] { state.withLockedValue { $0.sent } }

    func sent(_ method: String, _ path: String) -> [Sent] { sent.filter { $0.method == method && $0.path == path } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let route = "\(request.method) \(path)"
        var headers: [String: String] = [:]
        for header in request.headers { headers[header.name] = header.value }
        let (answer, failing) = state.withLockedValue { state -> (JSONValue?, Bool) in
            state.sent.append(Sent(method: request.method, path: path, query: request.url.query, body: request.body.map { String(decoding: $0, as: UTF8.self) },
                                   headers: headers))
            return (state.answers[route], state.failures.contains(route))
        }
        guard let answer, !failing else {
            return HomeswiftNetwork.HTTPResponse(status: 200, body: JSONValue.object(["success": false, "code": 1100, "msg": .string("no such route \(route)")]).encoded())
        }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: JSONValue.object(["success": true, "t": 1_700_000_000_123, "result": answer]).encoded())
    }

    static let deviceList = #"""
    [{"id":"bf0123456789abcdefgh","uuid":"a1b2c3d4e5f60718","name":"Desk Lamp","online":true,
      "category":"dj","product_id":"keyabc123","product_name":"Smart Bulb","owner_id":"12345678",
      "local_key":"<secret>","ip":"203.0.113.7","lat":"0","lon":"0","time_zone":"+01:00","sub":false,
      "status":[{"code":"switch_led","value":true},{"code":"work_mode","value":"white"},
                {"code":"bright_value_v2","value":800},{"code":"temp_value_v2","value":300},
                {"code":"colour_data_v2","value":"{\"h\":0,\"s\":1000,\"v\":1000}"}]},
     {"id":"bf9876543210zyxwvuts","uuid":"0718a1b2c3d4e5f6","name":"Power Strip","online":false,
      "category":"pc","product_id":"keyxyz789","owner_id":"12345678","status":[
       {"code":"switch_1","value":true},{"code":"switch_2","value":false},{"code":"switch_usb1","value":true},
       {"code":"cur_current","value":312},{"code":"cur_power","value":684},{"code":"cur_voltage","value":2301},
       {"code":"add_ele","value":1250}]}]
    """#

    static let lampSpecification = #"""
    {"category":"dj",
     "functions":[
      {"code":"switch_led","type":"Boolean","values":"{}"},
      {"code":"work_mode","type":"Enum","values":"{\"range\":[\"white\",\"colour\",\"scene\",\"music\"]}"},
      {"code":"bright_value_v2","type":"Integer","values":"{\"min\":10,\"max\":1000,\"scale\":0,\"step\":1}"},
      {"code":"temp_value_v2","type":"Integer","values":"{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}"},
      {"code":"colour_data_v2","type":"Json","values":"{\"h\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":360,\"step\":1},\"s\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1},\"v\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1}}"}],
     "status":[
      {"code":"switch_led","type":"Boolean","values":"{}"},
      {"code":"work_mode","type":"Enum","values":"{\"range\":[\"white\",\"colour\",\"scene\",\"music\"]}"},
      {"code":"bright_value_v2","type":"Integer","values":"{\"min\":10,\"max\":1000,\"scale\":0,\"step\":1}"},
      {"code":"temp_value_v2","type":"Integer","values":"{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}"},
      {"code":"colour_data_v2","type":"Json","values":"{\"h\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":360,\"step\":1},\"s\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1},\"v\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1}}"}]}
    """#

    static let stripSpecification = #"""
    {"category":"pc",
     "functions":[
      {"code":"switch_1","type":"Boolean","values":"{}"},{"code":"switch_2","type":"Boolean","values":"{}"},
      {"code":"switch_usb1","type":"Boolean","values":"{}"}],
     "status":[
      {"code":"switch_1","type":"Boolean","values":"{}"},{"code":"switch_2","type":"Boolean","values":"{}"},
      {"code":"switch_usb1","type":"Boolean","values":"{}"},
      {"code":"cur_current","type":"Integer","values":"{\"unit\":\"mA\",\"min\":0,\"max\":30000,\"scale\":0,\"step\":1}"},
      {"code":"cur_power","type":"Integer","values":"{\"unit\":\"W\",\"min\":0,\"max\":50000,\"scale\":1,\"step\":1}"},
      {"code":"cur_voltage","type":"Integer","values":"{\"unit\":\"V\",\"min\":0,\"max\":5000,\"scale\":1,\"step\":1}"},
      {"code":"add_ele","type":"Integer","values":"{\"unit\":\"kwh\",\"min\":0,\"max\":50000,\"scale\":3,\"step\":100}"}]}
    """#
}

/// A host with one Tuya block whose plugin talks to `cloud` and `mqtt`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Tuya-tests-\(UUID().uuidString)")
    let cloud = FakeTuyaCloud()
    let mqtt = FakeMQTTConnection()
    let timeScale: Double
    private let plugins = NIOLockedValueBox<[TuyaPlugin]>([])

    init(timeScale: Double = 0.5) { self.timeScale = timeScale }

    var plugin: TuyaPlugin? { plugins.withLockedValue { $0.last } }

    nonisolated(unsafe) static let smartHome: [String: Any] = [
        "options": [
            "projectType": "2", "accessId": "4h3dxjpwamt9gcrkqv8e", "accessKey": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "countryCode": 33,
            "username": "user@example.com", "password": "e4dac8847254e28266642c1bfe2ea3d2", "appSchema": "smartlife",
        ] as [String: Any],
    ]

    func start(settings: [String: Any] = TestEnvironment.smartHome) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = TuyaPlugin.Dependencies(
            transport: cloud, makeMQTT: { [mqtt] _ in mqtt }, timeScale: timeScale,
            loginBackoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(50)), pushBackoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(50)),
            requestBackoff: Backoff(initial: .milliseconds(1), maximum: .milliseconds(5)))
        registry.register(platform: TuyaPlugin.platform, name: TuyaPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(TuyaPlugin.Configuration.self, from: json)
            let plugin = TuyaPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: TuyaPlugin.platform, name: TuyaPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? { mainBridge.server.accessories.first { $0.id == id } }
}
