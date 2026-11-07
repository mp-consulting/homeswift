import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftXiaomiMiot

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// A logger that keeps every line, at every level, to check what reaches the log.
final class LogRecorder: @unchecked Sendable {
    let lines = NIOLockedValueBox<[(level: Logger.Level, message: String, metadata: String)]>([])

    var logger: Logger {
        var logger = Logger(label: "miot-test") { _ in Handler(recorder: self) }
        logger.logLevel = .trace
        return logger
    }

    var all: [String] { lines.withLockedValue { $0.map { "\($0.message) \($0.metadata)" } } }

    func contains(_ text: String) -> Bool { all.contains { $0.contains(text) } }

    struct Handler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) {
            let metadata = (event.metadata ?? [:]).merging(self.metadata) { a, _ in a }
            recorder.lines.withLockedValue { $0.append((event.level, event.message.description, metadata.description)) }
        }
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

func hex(_ text: String) -> [UInt8] { MiioToken.decode(text) ?? [] }

func hexString(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// The registry's responses saved in Fixtures (docs/clean-room/XiaomiMiot.md section 13).
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ name: String) -> Data {
        // swiftlint:disable:next force_try
        try! Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func json(_ name: String) -> JSONValue {
        // swiftlint:disable:next force_try
        try! JSONValue(data: data(name))
    }

    static func spec(_ model: String) -> MiotSpec {
        // swiftlint:disable:next force_try
        try! MiotSpec(json: json("\(model).json"))
    }

    static let models = ["yeelink.light.colorc", "cuco.plug.v3", "zhimi.airpurifier.ma4", "zhimi.humidifier.ca4", "zhimi.fan.za5", "zhimi.heater.mc2",
                         "lumi.curtain.hagl08", "dreame.vacuum.p2009", "cgllc.sensor_ht.qpg1", "rockrobo.vacuum.v1"]

    /// The fixture file of an instance URN.
    static func instance(urn: String) -> Data? {
        for model in models where json("\(model).json")["type"]?.stringValue == urn { return data("\(model).json") }
        return nil
    }
}

/// HTTP answered in memory: miot-spec.org from the fixtures, the rest by `handler`.
final class FakeHTTP: HTTPSending, @unchecked Sendable {
    let requests = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])
    let handler = NIOLockedValueBox<(@Sendable (HomeswiftNetwork.HTTPRequest) throws -> HomeswiftNetwork.HTTPResponse)?>(nil)

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        requests.withLockedValue { $0.append(request) }
        let url = request.url.absoluteString
        if url.hasPrefix("https://miot-spec.org/miot-spec-v2/instances") {
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Fixture.data("instances-sample.json"))
        }
        if url.hasPrefix("https://miot-spec.org/miot-spec-v2/instance?type=") {
            let urn = URLComponents(string: url)?.queryItems?.first { $0.name == "type" }?.value ?? ""
            guard let data = Fixture.instance(urn: urn) else { return HomeswiftNetwork.HTTPResponse(status: 404) }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: data)
        }
        guard let handler = handler.withLockedValue({ $0 }) else { throw HTTPClientError.timeout }
        return try handler(request)
    }

    func count(_ prefix: String) -> Int { requests.withLockedValue { $0.filter { $0.url.absoluteString.hasPrefix(prefix) }.count } }
}

/// A device on the fake network: it answers the hello and the miIO requests its token opens.
final class FakeMiioDevice: @unchecked Sendable {
    let ip: String
    let did: UInt32
    let token: MiioToken
    let model: String
    let state = NIOLockedValueBox(State())

    struct State {
        var properties: [PropertyKey: JSONValue] = [:]
        var silent = false
        var unknownMIoT = false
        var status: JSONValue?
        var consumables: JSONValue?
        var calls: [(method: String, params: JSONValue)] = []
        var stamp: UInt32 = 0x1000
        /// Errors to answer, in turn, before the next answers.
        var errors: [(code: Int, message: String)] = []
        /// set_properties answers this code per item (a refusal) instead of 0.
        var writeCode = 0
    }

    init(ip: String, did: UInt32, token: String, model: String, spec: MiotSpec? = nil) {
        self.ip = ip
        self.did = did
        self.token = MiioToken(hex: token)!
        self.model = model
        if let spec {
            state.withLockedValue { state in
                for property in spec.services.flatMap(\.properties) where property.isReadable {
                    state.properties[property.key] = property.isBool ? .bool(false) : property.isString ? .string("")
                        : property.values?.first?.value ?? .number(property.lower ?? 0)
                }
            }
        }
    }

    subscript(key: String) -> JSONValue? {
        get { state.withLockedValue { $0.properties[PropertyKey(key)!] } }
        set { state.withLockedValue { $0.properties[PropertyKey(key)!] = newValue } }
    }

    var calls: [(method: String, params: JSONValue)] { state.withLockedValue { $0.calls } }

    func calls(_ method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    var silent: Bool {
        get { state.withLockedValue { $0.silent } }
        set { state.withLockedValue { $0.silent = newValue } }
    }

    /// The hello reply.
    var helloReply: Data {
        let stamp = state.withLockedValue { $0.stamp }
        return Data(MiioPacket.header(deviceID: did, stamp: stamp, payloadLength: 0) + [UInt8](repeating: 0xFF, count: 16))
    }

    func handle(_ data: Data) -> Data? {
        if state.withLockedValue({ $0.silent }) { return nil }
        guard let packet = MiioPacket(data) else { return nil }
        if packet.isHandshake { return helloReply }
        guard packet.verifies(with: token), let plain = try? packet.decrypt(with: token), let request = try? JSONValue(data: plain),
              let id = request["id"]?.intValue, let method = request["method"]?.stringValue else { return nil }
        let params = request["params"] ?? .null
        let reply: JSONValue = state.withLockedValue { state in
            state.calls.append((method, params))
            state.stamp += 1
            if !state.errors.isEmpty {
                let error = state.errors.removeFirst()
                return ["id": .number(Double(id)), "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
            }
            return ["id": .number(Double(id)), "result": answer(method, params, &state)]
        }
        let stamp = state.withLockedValue { $0.stamp }
        return try? MiioPacket.encode(payload: reply.encoded(), token: token, deviceID: did, stamp: stamp)
    }

    private func answer(_ method: String, _ params: JSONValue, _ state: inout State) -> JSONValue {
        switch method {
        case "miIO.info":
            return ["model": .string(model), "fw_ver": "1.4.2_0010", "hw_ver": "esp32", "mac": "AA:BB:CC:DD:EE:01"]
        case "get_properties":
            if state.unknownMIoT { return "unknown_method" }
            return .array((params.arrayValue ?? []).map { item in
                let key = PropertyKey(siid: item["siid"]?.intValue ?? 0, piid: item["piid"]?.intValue ?? 0)
                guard let value = state.properties[key] else {
                    return ["did": item["did"] ?? .null, "siid": .number(Double(key.siid)), "piid": .number(Double(key.piid)), "code": -4003]
                }
                return ["did": item["did"] ?? .null, "siid": .number(Double(key.siid)), "piid": .number(Double(key.piid)), "code": 0, "value": value]
            })
        case "set_properties":
            if state.unknownMIoT { return "unknown_method" }
            return .array((params.arrayValue ?? []).map { item in
                let key = PropertyKey(siid: item["siid"]?.intValue ?? 0, piid: item["piid"]?.intValue ?? 0)
                if state.writeCode == 0 { state.properties[key] = item["value"] ?? .null }
                return ["did": item["did"] ?? .null, "siid": .number(Double(key.siid)), "piid": .number(Double(key.piid)), "code": .number(Double(state.writeCode))]
            })
        case "action":
            return ["code": 0, "out": []]
        case "get_status":
            return state.status ?? "unknown_method"
        case "get_consumable":
            return state.consumables ?? "unknown_method"
        case "app_start", "app_stop", "app_charge", "find_me":
            return ["ok"]
        default:
            return "unknown_method"
        }
    }
}

/// The LAN in memory: sockets that reach the fake devices by address, and the broadcast.
final class FakeMiioNetwork: MiioNetwork, @unchecked Sendable {
    let devices = NIOLockedValueBox<[String: FakeMiioDevice]>([:])

    func add(_ device: FakeMiioDevice) {
        devices.withLockedValue { $0[device.ip] = device }
    }

    func open() async throws -> any MiioSocket {
        FakeSocket(network: self)
    }

    final class FakeSocket: MiioSocket, @unchecked Sendable {
        let network: FakeMiioNetwork
        let datagrams: AsyncStream<UDPSocket.Datagram>
        private let continuation: AsyncStream<UDPSocket.Datagram>.Continuation

        init(network: FakeMiioNetwork) {
            self.network = network
            (datagrams, continuation) = AsyncStream.makeStream()
        }

        func send(_ data: Data, to host: String, port: Int) async throws {
            let all = network.devices.withLockedValue { $0 }
            let targets = host.hasSuffix(".255") ? Array(all.values) : all[host].map { [$0] } ?? []
            for device in targets {
                if let reply = device.handle(data) { continuation.yield(UDPSocket.Datagram(data: reply, address: device.ip, port: MiioPacket.port)) }
            }
        }

        func close() async { continuation.finish() }
    }
}

/// Short waits for tests.
let fastTimings: DeviceTimings = {
    var timings = DeviceTimings()
    timings.defaultInterval = .milliseconds(200)
    timings.minimumInterval = .milliseconds(50)
    timings.reconnectFloor = .milliseconds(300)
    timings.reconnectMaximum = .milliseconds(600)
    timings.debounce = .milliseconds(20)
    timings.miio = MiioTimings(requestTimeout: .milliseconds(150), retries: 1, handshakeTimeout: .milliseconds(150), handshakeValidity: .seconds(120),
                               infoTimeout: .milliseconds(150), infoRetries: 1)
    timings.accessory = AccessoryTimings(switchReset: .milliseconds(20), colorWait: .milliseconds(100))
    return timings
}()

/// A host with one `miot` block whose plugin talks to the fake network and HTTP.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-miot-tests-\(UUID().uuidString)")
    let network = FakeMiioNetwork()
    let http = FakeHTTP()
    private let plugins = NIOLockedValueBox<[XiaomiMiotPlugin]>([])
    let now = NIOLockedValueBox(Date(timeIntervalSince1970: 1_700_000_000))

    var plugin: XiaomiMiotPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: XiaomiMiotPlugin.Dependencies {
        var dependencies = XiaomiMiotPlugin.Dependencies()
        dependencies.network = network
        dependencies.http = http
        dependencies.timings = fastTimings
        dependencies.discoveryWindow = .milliseconds(150)
        dependencies.qrPollTimeout = .milliseconds(200)
        let now = now
        dependencies.now = { now.withLockedValue { $0 } }
        return dependencies
    }

    func start(settings: [String: Any] = [:], logger: Logger = testLogger, pluginLogger: Logger? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: XiaomiMiotPlugin.platform, name: XiaomiMiotPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(XiaomiMiotPlugin.Configuration.self, from: json)
            var dependencies = self.dependencies
            dependencies.logger = pluginLogger
            let plugin = XiaomiMiotPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: XiaomiMiotPlugin.platform, name: XiaomiMiotPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: logger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    func accessory(_ host: PluginHost, did: String) -> Accessory? {
        host.mainBridge.server.accessories.first { $0.id == "miot:\(did)" }
    }
}

/// A handle with no device: builders' tests.
let detachedHandle = DeviceHandle()

/// Builds a fixture model's accessory with `options` (section 13).
func buildFixture(_ model: String, options: [String: JSONValue] = [:], defaults: MappingDefaults = MappingDefaults()) -> BuiltAccessory? {
    MiotAccessoryBuilder(
        spec: Fixture.spec(model), model: model, name: "Test", accessoryID: "miot:1", serialNumber: "1", firmware: "1", options: DeviceOptions(options),
        defaults: defaults, handle: detachedHandle, timings: fastTimings.accessory, logger: testLogger, makeAdaptiveLighting: { service in
            AdaptiveLightingController(service, mode: .automatic)
        }).build()
}

extension Accessory {
    func service(subtype: String) -> Service? { services.first { $0.subtype == subtype } }
    func services(_ type: ServiceType) -> [Service] { services.filter { $0.type.uuid == type.uuid } }
    func switchNames() -> [String] { services(.switch).compactMap { $0[.name]?.value.stringValue } }
}
