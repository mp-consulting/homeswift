import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSwitchBot

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The device list of the spec's §10.2.
let specList: JSONValue = try! JSONValue(string: """
    {"statusCode":100,"message":"success","body":{"deviceList":[
      {"deviceId":"C271111EC0AB","deviceName":"Office Meter","deviceType":"Meter","enableCloudService":true,"hubDeviceId":"FA7310762361"},
      {"deviceId":"E2F6032048AB","deviceName":"Living Curtain","deviceType":"Curtain","enableCloudService":true,"hubDeviceId":"FA7310762361","calibrate":true,"group":false,"master":true,"openDirection":"left","curtainDevicesIds":["E2F6032048AB"]},
      {"deviceId":"D1A2B3C4D5E6","deviceName":"Coffee Bot","deviceType":"Bot","enableCloudService":true,"hubDeviceId":"FA7310762361"},
      {"deviceId":"6055F92F0A1B","deviceName":"Desk Plug","deviceType":"Plug Mini (US)","enableCloudService":true,"hubDeviceId":"000000000000"},
      {"deviceId":"FA7310762361","deviceName":"Hub","deviceType":"Hub 2","enableCloudService":true,"hubDeviceId":"000000000000"}
    ],"infraredRemoteList":[
      {"deviceId":"02-202008110034-13","deviceName":"Living Room TV","remoteType":"TV","hubDeviceId":"FA7310762361"},
      {"deviceId":"02-202102220012-55","deviceName":"Bedroom AC","remoteType":"Air Conditioner","hubDeviceId":"FA7310762361"}
    ]}}
    """)

/// SwitchBot's cloud in memory: the device list, a status per device, and the requests it was sent.
final class FakeCloud: HTTPSending {
    struct State {
        var list: JSONValue = specList
        var statuses: [String: JSONValue] = [:]
        var unreachable: Set<String> = []
        var commandCode = 100
        var requests: [NetRequest] = []
        var commands: [(id: String, command: Command)] = []
        var webhookActions: [String] = []
    }

    let state = NIOLockedValueBox(State())

    func send(_ request: NetRequest) async throws -> NetResponse {
        state.withLockedValue { $0.requests.append(request) }
        let parts = request.url.path.split(separator: "/").map(String.init)
        func answer(_ json: JSONValue) -> NetResponse { NetResponse(status: 200, body: json.encoded()) }
        switch parts.count >= 2 ? parts[1] : "" {
        case "devices" where parts.count == 2:
            return answer(state.withLockedValue { $0.list })
        case "devices":
            let id = parts[2].removingPercentEncoding ?? parts[2]
            if state.withLockedValue({ $0.unreachable.contains(id) }) { throw HTTPClientError.timeout }
            if parts.last == "commands" {
                let body = try JSONValue(data: request.body ?? Data())
                let command = Command(
                    command: body["command"]?.stringValue ?? "", parameter: body["parameter"]?.stringValue ?? "", commandType: body["commandType"]?.stringValue ?? "")
                let code = state.withLockedValue { state in
                    state.commands.append((id, command))
                    return state.commandCode
                }
                return answer(["statusCode": .number(Double(code)), "message": code == 100 ? "success" : "device offline", "body": [:]])
            }
            let status = state.withLockedValue { $0.statuses[id] } ?? [:]
            return answer(["statusCode": 100, "message": "success", "body": status])
        case "webhook":
            state.withLockedValue { $0.webhookActions.append(parts[2]) }
            return answer(["statusCode": 100, "message": "", "body": ["urls": ["http://elsewhere"]]])
        default:
            return NetResponse(status: 404)
        }
    }

    var commands: [(id: String, command: Command)] { state.withLockedValue { $0.commands } }
    func commands(to id: String) -> [Command] { commands.filter { $0.id == id }.map(\.command) }

    func setStatus(_ id: String, _ json: String) {
        let value = try! JSONValue(string: json)
        state.withLockedValue { $0.statuses[id] = value["body"] ?? value }
    }
}

/// A host with one SwitchBot block, talking to a `FakeCloud`, every wait shortened.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-SwitchBot-tests-\(UUID().uuidString)")
    let cloud = FakeCloud()
    /// The Bluetooth adapter the plugin gets, in memory.
    let central = FakeBLECentral()
    private let plugins = NIOLockedValueBox<[SwitchBotPlugin]>([])

    var plugin: SwitchBotPlugin? { plugins.withLockedValue { $0.last } }

    static var keys: [String: Any] { ["credentials": ["token": "yourtoken", "secret": "yoursecret"]] }

    func start(_ settings: [String: Any] = TestEnvironment.keys, timeScale: Double = 0.001) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: SwitchBotPlugin.platform, name: SwitchBotPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(SwitchBotPlugin.Configuration.self, from: json)
            let plugin = SwitchBotPlugin(configuration: configuration, context: context, dependencies: .init(
                http: self.cloud, timeScale: timeScale, webhookHost: "127.0.0.1", webhookPort: 0, bleCentral: { _ in self.central }))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: SwitchBotPlugin.platform, name: SwitchBotPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? { mainBridge.server.accessories.first { $0.id == id } }
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
typealias NetRequest = HomeswiftNetwork.HTTPRequest
typealias NetResponse = HomeswiftNetwork.HTTPResponse

extension HAPValue {
    /// A float characteristic keeps its step's rounding: compared within a hundredth.
    func near(_ expected: Double) -> Bool { doubleValue.map { abs($0 - expected) < 0.01 } ?? false }
}
