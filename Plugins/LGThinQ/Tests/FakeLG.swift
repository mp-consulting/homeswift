import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftLGThinQ

// Homeswift's server has its own HTTP types, which `@testable import Homeswift` brings in.
typealias HTTPRequest = HomeswiftNetwork.HTTPRequest
typealias HTTPResponse = HomeswiftNetwork.HTTPResponse

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A sample from the Homebridge plugin's `sample/` directory.
func fixture(_ name: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    return try JSONValue(data: Data(contentsOf: url))
}

/// A latch for holding a fake's answer: `wait()` notes it was reached and returns once `open()` ran.
final class Gate: Sendable {
    private let state = NIOLockedValueBox((reached: false, open: false))

    var reached: Bool { state.withLockedValue { $0.reached } }

    func open() { state.withLockedValue { $0.open = true } }

    func wait() async {
        state.withLockedValue { $0.reached = true }
        while !state.withLockedValue({ $0.open }) {
            // Not Task.sleep: a cancelled waiter must still hold until the test opens the gate.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { continuation.resume() }
            }
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// LG's cloud in memory: the gateway, OAuth, the profile, homes and devices, model JSON, ThinQ2 commands and
/// ThinQ1 monitoring. Every request is recorded; `handlers` override routes.
final class FakeLG: HTTPSending, @unchecked Sendable {
    static let thinq2 = "https://fake-thinq2.lgthinq.test/v1"
    static let thinq1 = "https://fake-thinq1.lgthinq.test/api"
    static let oauth = "https://fake-oauth.lgeapi.test"
    static let spx = "https://fake-spx.lgaccount.test/spx"
    static let emp = "https://fake-emp.lgsmartplatform.test"

    struct State {
        var requests: [HTTPRequest] = []
        var devices: [JSONValue] = []
        var models: [String: JSONValue] = [:]
        var commandResult = "0000"
        var accessToken = "access-1"
        var refreshCount = 0
        /// ThinQ1 monitoring data by device id.
        var monitorData: [String: Data] = [:]
        var overrides: [(match: String, respond: @Sendable (HTTPRequest) throws -> HTTPResponse)] = []
    }

    let state = NIOLockedValueBox(State())
    /// Awaited before each answer, to hold a request while a test does something else.
    let beforeAnswer = NIOLockedValueBox<(@Sendable (HTTPRequest) async -> Void)?>(nil)

    var requests: [HTTPRequest] { state.withLockedValue { $0.requests } }

    /// The ThinQ2 commands sent, as their JSON bodies.
    var commands: [JSONValue] {
        requests.filter { $0.url.absoluteString.contains("/control") && $0.method == "POST" }.compactMap { $0.body.flatMap { try? JSONValue(data: $0) } }
    }

    var thinq1Controls: [JSONValue] {
        requests.filter { $0.url.absoluteString.hasSuffix("rti/rtiControl") }.compactMap { $0.body.flatMap { try? JSONValue(data: $0) } }
    }

    func override(_ match: String, _ respond: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        state.withLockedValue { $0.overrides.insert((match, respond), at: 0) }
    }

    /// Adds a device to the account with its model.
    func add(device: JSONValue, model: JSONValue) {
        let id = JS.string(device["deviceId"])
        var device = device.objectValue ?? [:]
        device["modelJsonUri"] = .string("https://fake-cdn.lgthinq.test/models/\(id).json")
        device["platformType"] = device["platformType"] ?? "thinq2"
        let record = JSONValue.object(device)
        state.withLockedValue {
            $0.devices.append(record)
            $0.models["https://fake-cdn.lgthinq.test/models/\(id).json"] = model
        }
    }

    func setSnapshot(_ id: String, _ snapshot: JSONValue) {
        state.withLockedValue { state in
            state.devices = state.devices.map { device in
                guard JS.string(device["deviceId"]) == id, var object = device.objectValue else { return device }
                object["snapshot"] = snapshot
                return .object(object)
            }
        }
    }

    static func json(_ value: JSONValue, status: Int = 200, cookies: [String] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("content-type", "application/json")] + cookies.map { ("set-cookie", $0) }, body: value.encoded())
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let overrides = state.withLockedValue { state in
            state.requests.append(request)
            return state.overrides
        }
        if let hook = beforeAnswer.withLockedValue({ $0 }) { await hook(request) }
        let url = request.url.absoluteString
        if let override = overrides.first(where: { url.contains($0.match) }) { return try override.respond(request) }
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        switch true {
        case url.hasPrefix(ThinQConstants.gatewayURL):
            return Self.json(["result": [
                "empTermsUri": .string(Self.emp), "empSpxUri": .string(Self.spx), "thinq2Uri": .string(Self.thinq2), "thinq1Uri": .string(Self.thinq1),
                "countryCode": "US", "languageCode": "en-US",
            ]])
        case url.contains("gatewayUriList"):
            return Self.json(["lgedmRoot": ["returnCd": "0000", "oauthUri": .string(Self.oauth)]])
        case url == Self.oauth + "/oauth/1.0/oauth2/token":
            let token = state.withLockedValue { state in
                state.refreshCount += 1
                return state.accessToken
            }
            return Self.json(["access_token": .string(token), "refresh_token": "refresh-from-code", "expires_in": "3600"])
        case url == Self.oauth + "/users/profile":
            return Self.json(["account": ["userNo": "US2012345678"]])
        case url == Self.thinq1 + "/member/login":
            return Self.json(["lgedmRoot": ["returnCd": "0000", "jsessionId": "jsession-1"]])
        case url == Self.thinq2 + "/service/homes":
            return Self.json(["resultCode": "0000", "result": ["item": [["homeId": "home-1", "homeName": "Home"]]]])
        case url == Self.thinq2 + "/service/homes/home-1":
            let devices = state.withLockedValue { $0.devices }
            return Self.json(["resultCode": "0000", "result": ["devices": .array(devices)]])
        case url.hasPrefix("https://fake-cdn.lgthinq.test/models/"):
            guard let model = state.withLockedValue({ $0.models[url] }) else { return Self.json([:], status: 404) }
            return Self.json(model)
        case url.contains("/control-sync") || url.hasSuffix("/control"):
            let result = state.withLockedValue { $0.commandResult }
            return Self.json(["resultCode": .string(result), "result": [:]])
        case url == "https://common.lgthinq.com/route":
            return Self.json(["result": ["mqttServer": "ssl://a3abcdef-ats.iot.eu-west-1.amazonaws.com:8883"]])
        case url == Self.thinq2 + "/service/users/client":
            return Self.json(["resultCode": "0000"])
        case url == Self.thinq2 + "/service/users/client/certificate":
            return Self.json(["resultCode": "0000", "result": ["certificatePem": "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", "subscriptions": ["app/clients/abc/push"]]])
        case url == Self.thinq1 + "/rti/rtiMon":
            return Self.json(["lgedmRoot": ["returnCd": "0000", "workId": "work-1"]])
        case url == Self.thinq1 + "/rti/rtiResult":
            let id = JS.string(body?["lgedmRoot"]?["workList"]?[0]?["deviceId"])
            guard let data = state.withLockedValue({ $0.monitorData[id] }) else {
                return Self.json(["lgedmRoot": ["returnCd": "0000", "workList": ["returnCode": "0000"]]])
            }
            return Self.json(["lgedmRoot": ["returnCd": "0000", "workList": ["returnCode": "0000", "returnData": .string(data.base64EncodedString())]]])
        case url == Self.thinq1 + "/rti/rtiControl":
            return Self.json(["lgedmRoot": ["returnCd": "0000"]])
        default:
            return Self.json(["resultCode": "0404"], status: 404)
        }
    }
}

/// The MQTT factory of the plugin: one shared fake broker, recording each configuration it was asked for.
final class FakeMQTT: @unchecked Sendable {
    let configurations = NIOLockedValueBox<[MQTTConfiguration]>([])
    let connection = FakeMQTTConnection()
    /// Awaited before the factory answers its connection.
    let beforeConnection = NIOLockedValueBox<(@Sendable () async -> Void)?>(nil)

    var factory: @Sendable (MQTTConfiguration) async throws -> any MQTTConnection {
        { configuration in
            self.configurations.withLockedValue { $0.append(configuration) }
            if let hook = self.beforeConnection.withLockedValue({ $0 }) { await hook() }
            return self.connection
        }
    }

    /// A push from the broker, once the plugin subscribed (a broker delivers to subscribers only).
    func push(_ message: JSONValue) async {
        _ = await eventually(timeout: .seconds(15)) { !self.connection.subscriptions.isEmpty }
        connection.receive("app/clients/abc/push", payload: message.encoded())
    }
}

/// A factory whose connections never come up, as without MQTT: ThinQ2 devices update through the REST poll.
let noMQTT: @Sendable (MQTTConfiguration) async throws -> any MQTTConnection = { _ in
    let connection = FakeMQTTConnection()
    connection.failConnects(with: [MQTTError.notConnected])
    return connection
}

extension HTTPRequest {
    /// The body as text: a form or JSON.
    var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// A host with one LG ThinQ block whose plugin talks to `lg`.
/// One client key for every test: the plugin makes a 2048-bit key for each new storage, slow in a debug build.
let testClientKeys: ClientIdentity.Keys = {
    let keys = try! ClientIdentity.generateKeys()
    ClientIdentity.reused.keys = keys
    return keys
}()

final class LGTestEnvironment: @unchecked Sendable {
    init() { _ = testClientKeys }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-lgthinq-tests-\(UUID().uuidString)")
    let lg = FakeLG()
    let mqtt = FakeMQTT()
    private let plugins = NIOLockedValueBox<[LGThinQPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    var plugin: LGThinQPlugin? { plugins.withLockedValue { $0.last } }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: LGThinQPlugin.platform, name: LGThinQPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(LGThinQPlugin.Configuration.self, from: json)
            let plugin = LGThinQPlugin(configuration: configuration, context: context, dependencies: .init(transport: self.lg, mqtt: self.mqtt.factory))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: LGThinQPlugin.platform, name: "LG ThinQ", settings: settings)
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

    static var defaultSettings: [String: Any] { ["refresh_token": "refresh-1", "country": "US", "language": "en-US"] }

    func start(settings: [String: Any] = defaultSettings) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        return host
    }

    /// The accessory of a device on the main bridge or on its own server, once discovery added it.
    func accessory(_ host: PluginHost, id: String) async -> Accessory? {
        let accessoryID = "LGThinQ:\(id)"
        _ = await eventually(timeout: .seconds(15)) { host.bridges.contains { bridge in bridge.server.accessories.contains { $0.id == accessoryID } } }
        for bridge in host.bridges {
            if let accessory = bridge.server.accessories.first(where: { $0.id == accessoryID }) { return accessory }
        }
        return nil
    }
}

extension JSONValue {
    /// A sample device record with another id and, optionally, another snapshot.
    func withDevice(id: String, snapshot: JSONValue? = nil, platform: String? = nil) -> JSONValue {
        var object = (self["data"] ?? self).objectValue ?? [:]
        object["deviceId"] = .string(id)
        if let snapshot { object["snapshot"] = snapshot }
        if let platform { object["platformType"] = .string(platform) }
        return .object(object)
    }
}

extension Service {
    func number(_ type: CharacteristicType) -> Double? { self[type]?.value.doubleValue }
}
