import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftHTTPWebhooks

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The client's request and response, not the HAP server's of the same names.
typealias HTTPRequest = HomeswiftNetwork.HTTPRequest
typealias HTTPResponse = HomeswiftNetwork.HTTPResponse

/// The systems the entries call, in memory: records each request and answers 200, or the status set for its URL.
actor FakeHTTP: HTTPSending {
    private(set) var requests: [HTTPRequest] = []
    private var statuses: [String: Int] = [:]
    private var redirects: [String: String] = [:]

    func answer(_ url: String, status: Int) { statuses[url] = status }
    func redirect(_ url: String, to location: String) { redirects[url] = location }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let url = request.url.absoluteString
        if let location = redirects[url] { return HTTPResponse(status: 302, headers: [("Location", location)]) }
        return HTTPResponse(status: statuses[url] ?? 200)
    }

    var urls: [String] { requests.map(\.url.absoluteString) }
}

/// The example block of the specification (docs/clean-room/HTTPWebhooks.md, 8.1).
nonisolated(unsafe) let exampleBlock: [String: Any] = [
    "webhook_port": "51828",
    "http_auth_user": "hook",
    "http_auth_pass": "s3cret",
    "sensors": [
        ["id": "motion1", "name": "Hall Motion", "type": "motion", "autoRelease": true, "autoReleaseTime": 2000],
        ["id": "temp1", "name": "Attic Temperature", "type": "temperature"],
        ["id": "door1", "name": "Front Door", "type": "contact"],
    ],
    "switches": [["id": "switch1", "name": "Switch name 1", "on_url": "http://10.0.0.5/relay?on=1", "off_url": "http://10.0.0.5/relay?on=0"]],
    "pushbuttons": [
        [
            "id": "bell", "name": "Gate Button", "push_url": "http://10.0.0.6/pulse", "push_method": "POST", "push_body": #"{"pulse":true}"#,
            "push_headers": #"{"Content-Type":"application/json"}"#,
        ]
    ],
    "doorbells": [["id": "db1", "name": "Doorbell", "double_press": false, "long_press": false]],
    "lights": [
        ["id": "light1", "name": "Desk Lamp", "brightness_factor": 2.55, "brightness_url": "http://10.0.0.7/set?on=%statusPlaceholder&bri=%brightnessPlaceholder"]
    ],
    "thermostats": [
        [
            "id": "th1", "name": "Living Thermostat", "set_target_temperature_url": "http://10.0.0.8/t?target=%f",
            "set_target_heating_cooling_state_url": "http://10.0.0.8/m?mode=%b",
        ]
    ],
    "outlets": [["id": "out1", "name": "Kettle"]],
    "security": [["id": "alarm", "name": "Alarm", "set_state_url": "http://10.0.0.9/mode/%d"]],
    "garagedooropeners": [["id": "garage", "name": "Garage", "open_url": "http://10.0.0.10/open", "close_url": "http://10.0.0.10/close"]],
    "statelessswitches": [["id": "remote", "name": "Remote", "buttons": [["name": "Up"], ["name": "Down", "long_press": false]]]],
    "windowcoverings": [
        ["id": "blind", "name": "Blind", "open_url": "http://x/o", "open_40_url": "http://x/o40", "close_url": "http://x/c", "auto_set_current_position": true]
    ],
    "lockmechanisms": [["id": "lock", "name": "Front Lock", "open_url": "http://x/unlock", "close_url": "http://x/lock"]],
    "fanv2s": [["id": "fan", "name": "Ceiling Fan", "speed_url": "http://x/fan?s=%speedPlaceholder", "speed_factor": 0.03]],
    "co2sensors": [["id": "co2", "name": "CO2", "co2_peak_level": 1000]],
    "valves": [["id": "tap", "name": "Garden Tap", "type": "irrigation"]],
]

/// A host with one HttpWebHooks block whose plugin calls `http`, listening on a port of its own choosing.
/// Waits the tests let go themselves: each `wait` stays until `release()` (in order) or its task's cancellation.
final class HeldWaits: Sendable {
    private let held = NIOLockedValueBox<[(id: UUID, continuation: CheckedContinuation<Void, any Error>)]>([])
    private let started = NIOLockedValueBox(0)

    /// The waits under way, and how many began.
    var pending: Int { held.withLockedValue { $0.count } }
    var begun: Int { started.withLockedValue { $0 } }

    @Sendable func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                held.withLockedValue { $0.append((id, continuation)) }
                started.withLockedValue { $0 += 1 }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { cancel(id) }
    }

    /// Lets the oldest wait under way go.
    func release() {
        held.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }?.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        let found = held.withLockedValue { list -> CheckedContinuation<Void, any Error>? in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            return list.remove(at: index).continuation
        }
        found?.resume(throwing: CancellationError())
    }
}

final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-HTTPWebhooks-tests-\(UUID().uuidString)")
    let http = FakeHTTP()
    private let plugins = NIOLockedValueBox<[HTTPWebhooksPlugin]>([])

    static let timing = KindEnvironment.Timing(
        pushButtonRelease: .milliseconds(20), currentPositionDelay: .milliseconds(20), coalescing: .zero, callTimeout: .seconds(5),
        slowCallTimeout: .seconds(5), autoReleaseScale: 0.01)
    let timing: KindEnvironment.Timing

    /// `releases`: the sensors' auto releases wait until the test lets them go.
    init(releases: HeldWaits? = nil) {
        var timing = Self.timing
        if let releases { timing.releaseWait = releases.wait }
        self.timing = timing
    }

    var plugin: HTTPWebhooksPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = exampleBlock) async throws -> PluginHost {
        var registry = PluginRegistry()
        let http = http, timing = timing
        registry.register(platform: HTTPWebhooksPlugin.platform, name: HTTPWebhooksPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(HTTPWebhooksPlugin.Configuration.self, from: json)
            let plugin = HTTPWebhooksPlugin(
                configuration: configuration, context: context, dependencies: .init(client: { _ in http }, port: 0, timing: timing))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: HTTPWebhooksPlugin.platform, name: HTTPWebhooksPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    static let authorization = "Basic " + Data("hook:s3cret".utf8).base64EncodedString()

    /// What the webhook server answers `uri`, with the example's credentials unless told otherwise.
    func call(_ uri: String, method: String = "GET", authorization: String? = TestEnvironment.authorization) async throws -> WebhookHTTPResponse {
        let router = try #require(await plugin?.router)
        return router.respond(method: method, uri: uri, authorization: authorization)
    }

    /// The JSON body of a webhook's answer.
    func json(_ uri: String) async throws -> JSONValue {
        let response = try await call(uri)
        #expect(response.status == 200, "\(uri): \(response.status) \(response.body)")
        return try JSONValue(string: response.body)
    }
}

extension PluginHost {
    func accessory(named name: String) throws -> Accessory {
        try #require(mainBridge.server.accessories.first { $0.id == HTTPWebhooksPlugin.accessoryID(name: name) }, "no accessory \(name)")
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
