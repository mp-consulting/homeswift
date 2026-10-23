import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUniFiAccess

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Collects log lines, for tests that check what the plugin says.
final class LogRecorder: @unchecked Sendable {
    private let lines = NIOLockedValueBox<[(Logger.Level, String)]>([])

    var logger: Logger {
        var logger = Logger(label: "test") { _ in Handler(recorder: self) }
        logger.logLevel = .trace
        return logger
    }

    var all: [(Logger.Level, String)] { lines.withLockedValue { $0 } }
    func messages(_ level: Logger.Level) -> [String] { all.filter { $0.0 == level }.map(\.1) }
    func contains(_ text: String, level: Logger.Level? = nil) -> Bool { all.contains { (level == nil || $0.0 == level) && $0.1.contains(text) } }
    fileprivate func record(_ level: Logger.Level, _ text: String) { lines.withLockedValue { $0.append((level, text)) } }

    private struct Handler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) { recorder.record(event.level, "\(event.message)") }

        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            recorder.record(level, "\(message)")
        }
    }
}

// MARK: Devices, as the TypeScript tests' mocks build them

func deviceJSON(_ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var device: [String: JSONValue] = [
        "adopt_time": 0, "alias": "Test Device", "capabilities": ["is_hub"], "connected_uah_id": "", "configs": [], "device_type": "UAH",
        "display_model": "UA Hub", "door": ["unique_id": "door-1"], "extensions": [], "firmware": "v3.0.0", "ip": "192.168.1.100", "is_adopted": true,
        "is_connected": true, "is_managed": true, "is_online": true, "location_id": "loc-1", "mac": "AA:BB:CC:DD:EE:FF", "model": "UAH", "name": "Test Hub",
        "source_id": "1", "unique_id": "test-device-unique-id", "version": "3.0.0",
    ]
    for (key, value) in overrides { device[key] = value }
    return device
}

func configs(_ pairs: [(String, String)]) -> JSONValue {
    .array(pairs.map { ["key": .string($0.0), "value": .string($0.1)] })
}

func uah(_ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var base: [String: JSONValue] = [
        "capabilities": ["is_hub", "door_bell", "nfc_card_easy_provision", "pin_code"],
        "configs": configs([
            ("input_state_dps", "close"), ("input_state_rel", "off"), ("input_state_ren", "off"), ("input_state_rex", "off"), ("input_state_rly-lock_dry", "lock"),
            ("wiring_state_dps-neg", "on"), ("wiring_state_dps-pos", "on"), ("wiring_state_rel-neg", "on"), ("wiring_state_rel-pos", "on"),
            ("wiring_state_ren-neg", "on"), ("wiring_state_ren-pos", "on"), ("wiring_state_rex-neg", "on"), ("wiring_state_rex-pos", "on"),
        ]),
        "device_type": "UAH", "display_model": "UA Hub",
    ]
    for (key, value) in overrides { base[key] = value }
    return deviceJSON(base)
}

func ugt(_ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var base: [String: JSONValue] = [
        "capabilities": ["is_hub", "door_bell"],
        "configs": configs([
            ("input_door_dps", "on"), ("input_gate_dps", "on"), ("output_oper1_relay", "off"), ("output_oper2_relay", "off"),
            ("wiring_state_door-dps-neg", "on"), ("wiring_state_door-dps-pos", "on"), ("wiring_state_gate-dps-neg", "on"), ("wiring_state_gate-dps-pos", "on"),
        ]),
        "device_type": "UGT", "display_model": "UA Gate", "mac": "11:22:33:44:55:66", "unique_id": "gate-1", "alias": "Gate Hub",
        "extensions": [
            ["extension_name": "port_setting", "source_id": "port1", "target_name": "oper1", "target_value": "door-1"],
            ["extension_name": "port_setting", "source_id": "port2", "target_name": "oper2", "target_value": "door-2"],
        ],
    ]
    for (key, value) in overrides { base[key] = value }
    return deviceJSON(base)
}

func ultra(mode: String = "rex", _ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var base: [String: JSONValue] = [
        "capabilities": [
            "is_hub", "is_reader", "identity_face_unlock", "hand_wave", "mobile_unlock_ver2", "support_mobile_unlock", "nfc_card_easy_provision", "pin_code", "qr_code",
            "support_apple_pass",
        ],
        "configs": configs([("input_d1_button", "off"), ("input_d1_dps", "close"), ("output_d1_lock_relay", "off"), ("nfc", "yes"), ("pin_code", "no"), ("face", "yes")]),
        "device_type": "UA-ULTRA", "display_model": "UA Ultra", "mac": "AA:00:00:00:00:01", "unique_id": "ultra-1", "alias": "Ultra",
        "extensions": [["extension_name": "rex_button_mode", "target_config": [["config_key": "rex_button_mode", "config_value": .string(mode)]]]],
    ]
    for (key, value) in overrides { base[key] = value }
    return deviceJSON(base)
}

// MARK: The controller

/// A UniFi OS console with Access, over HTTP in memory: login, bootstrap, unlocking, settings.
final class FakeController: HTTPSending, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var url: String
        var headers: [(name: String, value: String)]
        var body: String
        var tls: HTTPClient.TLS
    }

    private struct State {
        var requests: [Recorded] = []
        var bootstrap: JSONValue = ["alias": "My Controller", "device_groups": [], "floors": []]
        var controller: JSONValue = ["host": ["mac": "00:11:22:33:44:55", "firmware_version": "4.0.0", "hostname": "udm", "ip": "10.0.0.1"], "version": "2.0.0"]
        var overrides: [String: @Sendable (HTTPRequest) -> HTTPResponse] = [:]
        var fingerprint = String(repeating: "ab", count: 32)
        var failures: [String: Error] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let tls: HTTPClient.TLS

    init() { tls = .system }
    private init(sharing other: FakeController, tls: HTTPClient.TLS) {
        self.tls = tls
        parent = other
    }
    private var parent: FakeController?
    private var root: FakeController { parent ?? self }

    /// A client for a TLS mode, sharing this controller's state (`AccessAPI.HTTPFactory`).
    func client(tls: HTTPClient.TLS) -> any HTTPSending { FakeController(sharing: root, tls: tls) }

    var requests: [Recorded] { root.state.withLockedValue { $0.requests } }
    func requests(matching fragment: String) -> [Recorded] { requests.filter { $0.url.contains(fragment) } }
    func clearRequests() { root.state.withLockedValue { $0.requests = [] } }

    func setDevices(_ devices: [[String: JSONValue]], doors: [JSONValue] = []) {
        root.state.withLockedValue {
            $0.bootstrap = ["alias": "My Controller", "device_groups": .array([.array(devices.map(JSONValue.object))]), "floors": .array([["doors": .array(doors)]])]
        }
    }

    func setBootstrap(_ bootstrap: JSONValue) { root.state.withLockedValue { $0.bootstrap = bootstrap } }
    func override(_ fragment: String, _ answer: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { root.state.withLockedValue { $0.overrides[fragment] = answer } }
    func removeOverride(_ fragment: String) { root.state.withLockedValue { $0.overrides[fragment] = nil } }
    func fail(_ fragment: String, with error: Error?) { root.state.withLockedValue { $0.failures[fragment] = error } }
    func setFingerprint(_ fingerprint: String) { root.state.withLockedValue { $0.fingerprint = fingerprint } }

    static func json(_ value: JSONValue, status: Int = 200, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: value.encoded())
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let root = root
        let url = request.url.absoluteString
        let (overrides, failures, fingerprint, bootstrap, controller) = root.state.withLockedValue { state in
            state.requests.append(
                Recorded(method: request.method, url: url, headers: request.headers, body: String(decoding: request.body ?? Data(), as: UTF8.self), tls: tls))
            return (state.overrides, state.failures, state.fingerprint, state.bootstrap, state.controller)
        }
        if case .pinned(let pinned) = tls, HTTPClient.normalizeFingerprint(pinned) != fingerprint {
            throw HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(pinned), observed: fingerprint)
        }
        if let (_, error) = failures.first(where: { url.contains($0.key) }) { throw error }
        var response: HTTPResponse
        if let (_, answer) = overrides.sorted(by: { $0.key.count > $1.key.count }).first(where: { url.contains($0.key) }) {
            response = answer(request)
        } else if url.hasSuffix("/api/auth/login") {
            response = HTTPResponse(status: 200, headers: [("Set-Cookie", "TOKEN=abc123; path=/; secure"), ("X-Updated-CSRF-Token", "csrf-2")], body: Data("{}".utf8))
        } else if url.hasSuffix("access/info") {
            response = Self.json(["data": controller])
        } else if url.hasSuffix("devices/topology4") {
            response = Self.json(["data": [bootstrap]])
        } else if url.contains("/unlock") || url.contains("/lock_rule") {
            response = Self.json(["codeS": "SUCCESS"])
        } else if url.contains("/settings") || url.contains("/configs") {
            response = Self.json(["codeS": "SUCCESS"])
        } else {
            response = HTTPResponse(status: 200, headers: [("X-CSRF-Token", "csrf-1")], body: Data())
        }
        if case .any = tls { response.certificateFingerprint = fingerprint }
        return response
    }
}

// MARK: Events and MQTT

/// The events WebSocket: every connection is a `FakeWebSocket`, recorded with what it was opened with.
final class FakeEvents: Sendable {
    private let connects = NIOLockedValueBox<[(url: URL, options: WebSocket.Options, socket: FakeWebSocket)]>([])

    var connections: [(url: URL, options: WebSocket.Options, socket: FakeWebSocket)] { connects.withLockedValue { $0 } }
    var all: [FakeWebSocket] { connections.map(\.socket) }
    var last: FakeWebSocket? { all.last }

    var connector: AccessAPI.EventsConnector {
        { url, options in
            let socket = FakeWebSocket(url: url)
            self.connects.withLockedValue { $0.append((url, options, socket)) }
            return socket
        }
    }
}

/// The broker: one `FakeMQTTConnection` for every client the plugin makes, and the configurations it made them with.
final class FakeBroker: Sendable {
    let connection = FakeMQTTConnection()
    private let made = NIOLockedValueBox<[MQTTConfiguration]>([])

    var configurations: [MQTTConfiguration] { made.withLockedValue { $0 } }

    var connector: AccessMQTT.Connector {
        { configuration in
            self.made.withLockedValue { $0.append(configuration) }
            return self.connection
        }
    }
}

// MARK: A bridge with the plugin

/// A host with one UniFi Access block whose plugin talks to the fake controller.
final class AccessTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-unifi-access-tests-\(UUID().uuidString)")
    let controller = FakeController()
    let events = FakeEvents()
    let mqtt = FakeBroker()
    let log = LogRecorder()
    var discovered: [DiscoveredConsole] = []
    var refreshInterval: Duration = .seconds(60)
    private let plugins = NIOLockedValueBox<[UniFiAccessPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    var plugin: UniFiAccessPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: UniFiAccessPlugin.Dependencies {
        var dependencies = UniFiAccessPlugin.Dependencies()
        let controller = controller
        dependencies.http = { controller.client(tls: $0) }
        dependencies.events = events.connector
        dependencies.mqtt = mqtt.connector
        let discovered = discovered
        dependencies.discover = { _ in discovered }
        dependencies.checkStatus = { $0 == "10.0.0.1" }
        dependencies.apiTiming = AccessAPI.Timing(
            requestTimeout: .seconds(2), heartbeatTimeout: .seconds(30), reconnectMinimum: .milliseconds(20), reconnectMaximum: .milliseconds(100),
            throttle: .milliseconds(300), retryMinimum: .milliseconds(1), retryMaximum: .milliseconds(5))
        dependencies.hubTiming = AccessHub.Timing(second: .milliseconds(30), revert: .milliseconds(10))
        dependencies.controllerRetryInterval = .milliseconds(20)
        dependencies.controllerRefreshInterval = refreshInterval
        dependencies.logger = log.logger
        return dependencies
    }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies
        registry.register(platform: UniFiAccessPlugin.platform, name: UniFiAccessPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(UniFiAccessPlugin.Configuration.self, from: json)
            let plugin = UniFiAccessPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: UniFiAccessPlugin.platform, name: "UniFi Access", settings: settings)
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

    static var controllerBlock: [String: Any] { ["address": "10.0.0.1", "username": "homeswift", "password": "secret"] }

    /// Starts a host with these devices and options, and waits for the hubs to be in HomeKit.
    func start(devices: [[String: JSONValue]], doors: [JSONValue] = [], options: [String] = [], extra: [String: Any] = [:], expecting count: Int? = nil) async throws -> PluginHost {
        controller.setDevices(devices, doors: doors)
        var settings: [String: Any] = ["controllers": [Self.controllerBlock.merging(extra) { $1 }], "options": options]
        settings["ringDelay"] = extra["ringDelay"]
        let host = try host(settings: settings)
        try await host.start()
        let expected = count ?? devices.count
        _ = await eventually { host.mainBridge.server.accessories.count >= expected + 1 }
        if expected > 0 { _ = await eventually { await self.hub(0) != nil } }
        // Publishes are dropped until the broker is connected, which happens in the background: under load, after
        // the hubs are up.
        if (extra["mqttUrl"] as? String)?.hasPrefix("mqtt://") == true { _ = await eventually { self.mqtt.connection.isConnected } }
        return host
    }

    func hub(_ index: Int) async -> AccessHub? {
        guard let plugin else { return nil }
        let controllers = await plugin.controllers
        guard let controller = controllers.first else { return nil }
        let hubs = await controller.hubs.sorted { $0.key < $1.key }.map(\.value)
        return hubs.indices.contains(index) ? hubs[index] : nil
    }

    func hub(id: String) async -> AccessHub? {
        guard let controller = await plugin?.controllers.first else { return nil }
        return await controller.hubs[id]
    }

    func controllerActor() async -> AccessController? { await plugin?.controllers.first }

    /// Sends an event through the events WebSocket.
    func send(_ event: String, _ objectId: String, data: JSONValue = [:], meta: JSONValue? = nil) {
        var packet: [String: JSONValue] = ["event": .string(event), "event_object_id": .string(objectId), "receiver_id": "", "save_to_history": false, "data": data]
        if let meta { packet["meta"] = meta }
        events.last?.receive(text: JSONValue.object(packet).text())
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func accessory(_ host: PluginHost, _ id: String) -> Accessory? {
    host.mainBridge.server.accessories.first { $0.id == id }
}
