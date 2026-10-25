import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftWingman

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A host with one Wingman block whose plugin talks to a fake Wingman, Bonjour announcing it at 10.0.0.5.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Wingman-tests-\(UUID().uuidString)")
    let wingman = FakeWingman()
    private let plugins = NIOLockedValueBox<[WingmanPlugin]>([])

    var plugin: WingmanPlugin? { plugins.withLockedValue { $0.last } }

    nonisolated(unsafe) static let paired: [String: Any] = ["id": "wm-1", "name": "Mac mini", "host": "10.0.0.5", "token": FakeWingman.token, "fingerprint": FakeWingman.fingerprint]

    func start(settings: [String: Any] = ["devices": [TestEnvironment.paired]]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let wingman = self.wingman
        registry.register(platform: WingmanPlugin.platform, name: WingmanPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(WingmanPlugin.Configuration.self, from: json)
            var dependencies = WingmanPlugin.Dependencies(transports: wingman)
            dependencies.browse = { _ in
                AsyncStream { continuation in
                    continuation.yield(.found(BonjourService(
                        name: "Mac mini", type: "_homeswift-wingman._tcp.", domain: "local.", hostName: "mac-mini.local.", port: 8619,
                        txt: ["v": "1", "id": "wm-1", "home": "abcd"], addresses: ["10.0.0.5"], interfaceIndex: 1)))
                }
            }
            dependencies.retry = Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
            dependencies.bridgeName = "Homeswift on test"
            let plugin = WingmanPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: WingmanPlugin.platform, name: WingmanPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct WingmanTests {
    let environment = TestEnvironment()

    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == "Wingman:\(id)" } })
        return try #require(host.mainBridge.server.accessories.first { $0.id == "Wingman:\(id)" })
    }

    func web(_ plugin: WingmanPlugin?, _ method: String, _ path: String, query: [String: String] = [:], body: JSONValue = .null) async throws -> PluginWebResponse {
        try await #require(plugin).handleWebRequest(PluginWebRequest(method: method, path: path, query: query, body: body, user: "admin"))
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(WingmanPlugin.Configuration.self, from: Data(#"{"platform":"Wingman"}"#.utf8))
        #expect(configuration.devices == nil)
        #expect(configuration.homes == nil)
    }

    @Test func appleHomeIsMirroredWithHomeswiftsTypesAndTheDevicesRanges() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        #expect(light.mirroredFrom == "Apple Home")
        #expect(light.suggestedRoom == "Salon")
        #expect(light.category == .lightbulb)
        #expect(light.information[.manufacturer]?.value == .string("Signify"))
        let bulb = try #require(light.service(.lightbulb))
        #expect(bulb.type.name == "Lightbulb")
        #expect(bulb.isPrimary)
        #expect(bulb[.on]?.value == .bool(true))
        #expect(bulb[.brightness]?.value == .int(40))
        #expect(bulb[.brightness]?.type.name == "Brightness")
        // HomeKit's range for this bulb, not HAP's default 140-500.
        #expect(bulb[.colorTemperature]?.type.minValue == 153)
        #expect(bulb[.colorTemperature]?.type.maxValue == 454)

        let sensor = try await accessory(host, "sensor-1")
        #expect(sensor.isUnavailable)
        #expect(sensor.service(.temperatureSensor)?[.currentTemperature]?.value == .double(12.5))
        // A lock target is a security control: the web UI and the MCP server ask first.
        let lock = try await accessory(host, "lock-1")
        #expect(lock.service(.lockMechanism)?[.lockTargetState]?.isSecurityControl == true)
        await host.stop()
    }

    @Test func homeswiftsOwnAccessoriesAreLeftOut() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        #expect(!host.mainBridge.server.accessories.contains { $0.id == "Wingman:homeswift-switch" })
        let status = try await web(environment.plugin, "GET", "wingmen")
        let wingman = try #require(status.json["wingmen"]?.arrayValue?.first)
        #expect(wingman["state"] == "connected")
        #expect(wingman["accessories"]?.doubleValue == 3)
        #expect(wingman["leftOut"]?.doubleValue == 1)
        #expect(wingman["notResponding"]?.doubleValue == 1)
        await host.stop()
    }

    @Test func homeKitIsNotGivenTheMirroredAccessories() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let database = host.mainBridge.server.database(includeValues: false).accessories.map(\.aid)
        #expect(!database.contains(light.aid))
        await host.stop()
    }

    @Test func writesReachWingmanByCharacteristicIDOverThePinnedCertificate() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let brightness = try #require(light.service(.lightbulb)?[.brightness])
        let write = try #require(brightness.writeHandler(for: .int(75)))
        try await write(.int(75))
        #expect(environment.wingman.writes == [.init(accessory: "light-1", characteristic: "light-brightness", value: "75")])
        // Every connection after pairing holds Wingman to the certificate pinned then.
        #expect(environment.wingman.tlsModes.allSatisfy { $0 == .pinned(FakeWingman.fingerprint) })
        await host.stop()
    }

    @Test func aRefusedWriteIsNoResponse() async throws {
        let host = try await environment.start()
        let lock = try await accessory(host, "lock-1")
        let target = try #require(lock.service(.lockMechanism)?[.lockTargetState])
        let write = try #require(target.writeHandler(for: .int(0)))
        await #expect(throws: HAPStatusError.self) { try await write(.int(0)) }
        await host.stop()
    }

    @Test func valueChangesReachHomeswiftAtOnce() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let brightness = try #require(light.service(.lightbulb)?[.brightness])
        environment.wingman.push(accessory: "light-1", characteristic: "light-brightness", type: "00000008-0000-1000-8000-0026BB765291", value: 90)
        #expect(await eventually { brightness.value == .int(90) })
        // A sensor that reports again answers again.
        let sensor = try await accessory(host, "sensor-1")
        environment.wingman.push(accessory: "sensor-1", characteristic: "temp", type: "00000011-0000-1000-8000-0026BB765291", value: 13)
        #expect(await eventually { !sensor.isUnavailable })
        await host.stop()
    }

    @Test func aBridgeWingmanForgotIsShownAsUnpaired() async throws {
        environment.wingman.forgetBridge()
        let host = try await environment.start()
        #expect(await eventually {
            let status = try? await web(environment.plugin, "GET", "wingmen")
            return status?.json["wingmen"]?.arrayValue?.first?["state"] == "unpaired"
        })
        await host.stop()
    }

    @Test func discoveryAsksEachWingmanWhoItIs() async throws {
        let host = try await environment.start(settings: [:])
        let answer = try await web(environment.plugin, "GET", "discover")
        let found = try #require(answer.json["wingmen"]?.arrayValue?.first)
        #expect(found["id"] == "wm-1")
        #expect(found["host"] == "10.0.0.5")
        #expect(found["pairing"] == true)
        #expect(found["paired"] == false)
        #expect(found["fingerprint"]?.stringValue == FakeWingman.fingerprint)
        await host.stop()
    }

    @Test func pairingAnswersTheEntryWithTheCertificatePinned() async throws {
        let host = try await environment.start(settings: [:])
        let wrong = try await web(environment.plugin, "POST", "pair", body: ["host": "10.0.0.5", "code": "111111", "fingerprint": .string(FakeWingman.fingerprint)])
        #expect(wrong.status == 403)
        let unchecked = try await web(environment.plugin, "POST", "pair", body: ["host": "10.0.0.5", "code": .string(FakeWingman.code)])
        #expect(unchecked.status == 400)

        let paired = try await web(environment.plugin, "POST", "pair", body: [
            "host": "10.0.0.5", "code": "482 913", "fingerprint": .string(FakeWingman.fingerprint), "name": "Mac mini",
        ])
        #expect(paired.status == 200)
        let device = try #require(paired.json["device"])
        #expect(device["id"] == "wm-1")
        #expect(device["token"]?.stringValue == FakeWingman.token)
        #expect(device["fingerprint"]?.stringValue == FakeWingman.fingerprint)
        #expect(device["host"] == "10.0.0.5")
        #expect(device["name"] == "Mac mini")
        #expect(environment.wingman.tlsModes.last == .pinned(FakeWingman.fingerprint))
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(WingmanPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Wingman WingmanPlugin")
        let schema = try JSONValue(string: try #require(WingmanPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Wingman")
    }
}
