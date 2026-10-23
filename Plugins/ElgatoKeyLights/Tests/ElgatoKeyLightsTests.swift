import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftElgatoKeyLights

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

enum FakeError: Error { case unreachable }

/// A light's HTTP API in memory.
actor FakeLight: KeyLightTransport {
    var info = KeyLightInfo(
        productName: "Elgato Key Light Air", hardwareBoardType: 200, firmwareBuildNumber: 218, firmwareVersion: "1.0.3",
        serialNumber: "BW12K1A00001", displayName: "Studio Light", features: ["lights"])
    var state = LightState(on: 1, brightness: 50, temperature: 200)
    var settings = KeyLightSettings(
        powerOnBehavior: 1, powerOnBrightness: 20, powerOnTemperature: 213,
        switchOnDurationMs: 300, switchOffDurationMs: 300, colorChangeDurationMs: 100)
    var reachable = true
    /// Hosts where a different light answers (another serial number).
    var impostorHosts: Set<String> = []
    /// Hosts where nothing answers.
    var unreachableHosts: Set<String> = []
    private(set) var identifyCount = 0
    private(set) var lightWrites: [LightState] = []

    func set(state: LightState) { self.state = self.state.merging(state) }
    func set(reachable: Bool) { self.reachable = reachable }
    func set(impostorHosts: Set<String>) { self.impostorHosts = impostorHosts }
    func set(unreachableHosts: Set<String>) { self.unreachableHosts = unreachableHosts }
    func set(macAddress: String?) { info.macAddress = macAddress }

    func send(_ request: KeyLightRequest) async throws -> KeyLightResponse {
        guard reachable, !unreachableHosts.contains(request.url.host ?? "") else { throw FakeError.unreachable }
        let path = request.url.path.replacingOccurrences(of: "/elgato/", with: "")
        let encoder = JSONEncoder()
        switch (request.method, path) {
        case ("GET", "accessory-info"):
            var info = info
            if let host = request.url.host, impostorHosts.contains(host) { info.serialNumber = "IMPOSTOR" }
            return KeyLightResponse(status: 200, body: try encoder.encode(info))
        case ("GET", "lights"):
            return KeyLightResponse(status: 200, body: try encoder.encode(LightsPayload(numberOfLights: 1, lights: [state])))
        case ("PUT", "lights"):
            let payload = try JSONDecoder().decode(LightsPayload.self, from: request.body ?? Data())
            let change = try #require(payload.lights.first)
            lightWrites.append(change)
            state = state.merging(change)
            return KeyLightResponse(status: 200, body: try encoder.encode(LightsPayload(numberOfLights: 1, lights: [state])))
        case ("GET", "lights/settings"):
            return KeyLightResponse(status: 200, body: try encoder.encode(settings))
        case ("PUT", "lights/settings"):
            settings = try JSONDecoder().decode(KeyLightSettings.self, from: request.body ?? Data())
            return KeyLightResponse(status: 200, body: Data("{}".utf8))
        case ("POST", "identify"):
            identifyCount += 1
            return KeyLightResponse(status: 200, body: Data("{}".utf8))
        default:
            return KeyLightResponse(status: 404, body: Data())
        }
    }
}

/// A host with one Elgato platform block whose plugin talks to `light` and discovers what the test yields.
final class ElgatoTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-elgato-tests-\(UUID().uuidString)")
    let light = FakeLight()
    let discovered: AsyncStream<ElgatoKeyLightsPlugin.DiscoveredLight>
    let discover: AsyncStream<ElgatoKeyLightsPlugin.DiscoveredLight>.Continuation
    private let plugins = NIOLockedValueBox<[ElgatoKeyLightsPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    init() {
        (discovered, discover) = AsyncStream<ElgatoKeyLightsPlugin.DiscoveredLight>.makeStream()
    }

    var plugin: ElgatoKeyLightsPlugin? { plugins.withLockedValue { $0.last } }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let discovered = discovered
        registry.register(platform: ElgatoKeyLightsPlugin.platform, name: ElgatoKeyLightsPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(ElgatoKeyLightsPlugin.Configuration.self, from: json)
            let plugin = ElgatoKeyLightsPlugin(
                configuration: configuration, context: context,
                dependencies: .init(transport: self.light, discover: { _ in discovered }))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights", settings: settings)
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

    /// Starts the host and waits for the lights known so far to be added.
    func start(settings: [String: Any]) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        await plugin?.settle()
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

var configuredLight: [String: Any] { ["mac": "3c:6a:9d:04:0a:0b", "ip": "192.168.1.50"] }
let lightID = "ElgatoKeyLights:3C:6A:9D:04:0A:0B"

@Suite(.timeLimit(.minutes(1)))
struct ElgatoKeyLightsTests {
    let environment = ElgatoTestEnvironment()

    @Test func helpers() {
        #expect(ElgatoKeyLightsPlugin.canonicalMAC("3c:6a:9d:4:a:b") == "3C:6A:9D:04:0A:0B")
        #expect(ElgatoKeyLightsPlugin.canonicalMAC("3C-6A-9D-04-0A-0B") == "3C:6A:9D:04:0A:0B")
        #expect(ElgatoKeyLightsPlugin.canonicalMAC(" 3c6a9d040a0b ") == "3C:6A:9D:04:0A:0B")
        #expect(ElgatoKeyLightsPlugin.canonicalMAC("hello") == "HELLO")
        #expect(ElgatoKeyLightsPlugin.mirek(kelvin: 4695) == 213)
        #expect(ElgatoKeyLightsPlugin.mirek(kelvin: 2900) == 344)
        #expect(ElgatoKeyLightsPlugin.mirek(kelvin: 7000) == 143)
        #expect(ElgatoKeyLightsPlugin.mirek(kelvin: 0) == 143)
        #expect(LightState(on: 1, brightness: 5, temperature: 200).merging(LightState(brightness: 9)) == LightState(on: 1, brightness: 9, temperature: 200))
        #expect(KeyLightClient(host: "fe80::1", port: 9123, transport: environment.light).baseURL?.absoluteString == "http://[fe80::1]:9123/elgato/")
        #expect(KeyLightClient(host: "light.local/../x?y", port: 9123, transport: environment.light).baseURL == nil)
        #expect(KeyLightClient(host: "10.0.0.5", port: 0, transport: environment.light).baseURL == nil)
        #expect(KeyLightClient.isValidHost("elgato-key-light-1234.local"))
        #expect(!KeyLightClient.isValidHost(""))
        #expect(!KeyLightClient.isValidHost("a b"))
    }

    @Test func pinnedLightsIgnoreAnnouncements() async throws {
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        let device = try #require(await environment.plugin?.device(mac: "3C:6A:9D:04:0A:0B"))
        await environment.light.set(unreachableHosts: ["192.168.1.50"])
        environment.discover.yield(.init(name: "Elgato Key Light", mac: "3C:6A:9D:04:0A:0B", host: "10.0.0.9", port: 9123))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.host == "192.168.1.50")
        await host.stop()
    }

    @Test func pinnedLightsRetryAtTheirConfiguredAddress() async throws {
        await environment.light.set(unreachableHosts: ["192.168.1.50"])
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        #expect(host.mainBridge.server.accessories.count == 1)

        // The configured address answers again; the announcement names another one, which is ignored.
        await environment.light.set(unreachableHosts: [])
        environment.discover.yield(.init(name: "Elgato Key Light", mac: "3C:6A:9D:04:0A:0B", host: "10.0.0.9", port: 9123))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })
        let device = try #require(await environment.plugin?.device(mac: "3C:6A:9D:04:0A:0B"))
        #expect(await device.host == "192.168.1.50")
        await host.stop()
    }

    @Test func announcementsFromADifferentLightAreIgnored() async throws {
        let host = try await environment.start(settings: [:])
        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "10.0.0.5", port: 9123))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })
        let device = try #require(await environment.plugin?.device(mac: "aa:bb:cc:dd:ee:ff"))

        await environment.light.set(unreachableHosts: ["10.0.0.5"])
        await environment.light.set(impostorHosts: ["10.0.0.9"])
        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "10.0.0.9", port: 9123))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.host == "10.0.0.5")

        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "bad host", port: 9123))
        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "10.0.0.6", port: 9123))
        #expect(await eventually { await device.host == "10.0.0.6" })
        await host.stop()
    }

    @Test func probesALightByItsAddressForThePage() async throws {
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        await environment.light.set(macAddress: "3c:6a:9d:04:0a:0b")
        let answer = try await plugin.handleWebRequest(.init(method: "GET", path: "probe", query: ["host": "192.168.1.50"], user: "admin"))
        #expect(answer.status == 200)
        #expect(answer.json["light"]?["mac"] == "3C:6A:9D:04:0A:0B" && answer.json["light"]?["name"] == "Studio Light")
        #expect(answer.json["light"]?["port"] == 9123 && answer.json["light"]?["model"] == "Elgato Key Light Air")
        await environment.light.set(unreachableHosts: ["192.168.1.51"])
        #expect(try await plugin.handleWebRequest(.init(method: "GET", path: "probe", query: ["host": "192.168.1.51"], user: "admin")).status == 502)
        #expect(try await plugin.handleWebRequest(.init(method: "GET", path: "probe", query: ["host": "a/b"], user: "admin")).status == 400)
        #expect(try await plugin.handleWebRequest(.init(method: "GET", path: "probe", query: ["host": "192.168.1.50", "port": "0"], user: "admin")).status == 400)
    }

    @Test func configuredLightBecomesAnAccessory() async throws {
        var light = configuredLight
        light["displayName"] = "Desk"
        light["powerOnBehavior"] = 2
        let host = try await environment.start(settings: ["devices": [light], "powerOnTemperature": 4000, "switchOffDurationMs": 50])
        let server = host.mainBridge.server
        let accessory = try #require(server.accessories.first { $0.id == lightID })
        #expect(accessory.name == "Desk")
        #expect(accessory.category == .lightbulb)
        #expect(accessory.information[.manufacturer]?.value == .string("Elgato"))
        #expect(accessory.information[.model]?.value == .string("Elgato Key Light Air"))
        #expect(accessory.information[.serialNumber]?.value == .string("BW12K1A00001"))
        #expect(accessory.information[.firmwareRevision]?.value == .string("1.0.3"))

        let lightbulb = try #require(accessory.service(.lightbulb))
        #expect(lightbulb.isPrimary)
        #expect(lightbulb[.on]?.value == .bool(true))
        #expect(lightbulb[.brightness]?.value == .int(50))
        #expect(lightbulb[.colorTemperature]?.value == .int(200))
        #expect(lightbulb[.colorTemperature]?.type.minValue == 143)
        #expect(lightbulb[.colorTemperature]?.type.maxValue == 344)
        // Adaptive Lighting, kept by the plugin: its transition characteristics are on the lightbulb.
        #expect(lightbulb.adaptiveLighting != nil)
        #expect(lightbulb[.characteristicValueTransitionControl] != nil)
        #expect(lightbulb[.configuredName]?.value == .string("Desk"))

        // Per-light settings win over the platform's, which win over the light's own; the rest stays.
        #expect(await environment.light.settings == KeyLightSettings(
            powerOnBehavior: 2, powerOnBrightness: 20, powerOnTemperature: 250,
            switchOnDurationMs: 300, switchOffDurationMs: 50, colorChangeDurationMs: 100))
        await host.stop()
    }

    @Test func writesReachTheLight() async throws {
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        let lightbulb = try #require(host.mainBridge.server.accessories.first { $0.id == lightID }?.service(.lightbulb))

        try await lightbulb.characteristic(.on).writeHandler(for: .bool(false))?(.bool(false))
        try await lightbulb.characteristic(.brightness).writeHandler(for: .int(75))?(.int(75))
        try await lightbulb.characteristic(.colorTemperature).writeHandler(for: .int(300))?(.int(300))
        #expect(await environment.light.lightWrites == [LightState(on: 0), LightState(brightness: 75), LightState(temperature: 300)])
        #expect(await environment.light.state == LightState(on: 0, brightness: 75, temperature: 300))

        // Reads come from the device's state, which already carries the writes.
        #expect(try await lightbulb.characteristic(.on).readHandler?() == .bool(false))
        #expect(try await lightbulb.characteristic(.brightness).readHandler?() == .int(75))

        // A write the light does not answer is a communication failure. (The characteristic still holds
        // `true`: the handlers above were called directly, so `changesOnly` would skip a write of `true`.)
        await environment.light.set(reachable: false)
        await #expect(throws: (any Error).self) {
            try await lightbulb.characteristic(.on).writeHandler(for: .bool(false))?(.bool(false))
        }

        try await host.mainBridge.server.accessories.first { $0.id == lightID }?.information.characteristic(.identify).writeHandler(for: .bool(true))?(.bool(true))
        await host.stop()
    }

    @Test func pollsForChangesAndReportsUnreachableLights() async throws {
        let host = try await environment.start(settings: ["devices": [configuredLight], "pollingRate": 250])
        let lightbulb = try #require(host.mainBridge.server.accessories.first { $0.id == lightID }?.service(.lightbulb))

        // A change made elsewhere reaches the characteristics with the next poll.
        await environment.light.set(state: LightState(on: 0, brightness: 10))
        #expect(await eventually { lightbulb[.brightness]?.value == .int(10) })
        #expect(lightbulb[.on]?.value == .bool(false))

        // After three failed polls, reads fail so the Home app shows "No Response".
        await environment.light.set(reachable: false)
        #expect(await eventually {
            do {
                _ = try await lightbulb.characteristic(.on).readHandler?()
                return false
            } catch let error as HAPStatusError {
                return error.status == .serviceCommunicationFailure
            } catch {
                return false
            }
        })

        // And work again once it answers.
        await environment.light.set(reachable: true)
        await environment.light.set(state: LightState(brightness: 33))
        #expect(await eventually { lightbulb[.brightness]?.value == .int(33) })
        #expect(try await lightbulb.characteristic(.on).readHandler?() == .bool(false))
        await host.stop()
    }

    @Test func discoversLightsAndIgnoresDisabledOnes() async throws {
        let host = try await environment.start(settings: [
            "devices": [["mac": "11:22:33:44:55:66", "enabled": false, "name": "Spare"]],
        ])
        environment.discover.yield(.init(name: "Elgato Key Light Air 1234", mac: "aa:bb:cc:dd:ee:ff", host: "10.0.0.5", port: 9123))
        environment.discover.yield(.init(name: "Elgato Key Light 5678", mac: "11:22:33:44:55:66", host: "10.0.0.6", port: 9123))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })
        try await Task.sleep(for: .milliseconds(200))
        let accessory = try #require(host.mainBridge.server.accessories.last)
        #expect(accessory.id == "ElgatoKeyLights:AA:BB:CC:DD:EE:FF")
        #expect(accessory.name == "Studio Light")
        #expect(host.mainBridge.server.accessories.count == 2)

        // Announced again on a new address while the old one still answers: nothing moves.
        let device = try #require(await environment.plugin?.device(mac: "aa:bb:cc:dd:ee:ff"))
        environment.discover.yield(.init(name: "Elgato Key Light Air 1234", mac: "AA:BB:CC:DD:EE:FF", host: "10.0.0.7", port: 9124))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.host == "10.0.0.5")

        // Once the old address is dead, the device follows.
        await environment.light.set(unreachableHosts: ["10.0.0.5"])
        environment.discover.yield(.init(name: "Elgato Key Light Air 1234", mac: "AA:BB:CC:DD:EE:FF", host: "10.0.0.7", port: 9124))
        #expect(await eventually {
            let host = await device.host
            let port = await device.port
            return host == "10.0.0.7" && port == 9124
        })
        await host.stop()
    }

    @Test func unreachableLightsAreRetriedWhenAnnounced() async throws {
        await environment.light.set(reachable: false)
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        #expect(host.mainBridge.server.accessories.count == 1)

        await environment.light.set(reachable: true)
        environment.discover.yield(.init(name: "Elgato Key Light", mac: "3C:6A:9D:04:0A:0B", host: "192.168.1.50", port: 9123))
        #expect(await eventually { host.mainBridge.server.accessories.map(\.id) == ["bridge", lightID] })
        await host.stop()
    }

    @Test func cachedLightIsReplacedWhenTheLightAnswers() async throws {
        let first = try await environment.start(settings: ["devices": [configuredLight]])
        let original = try #require(first.mainBridge.server.accessories.first { $0.id == lightID })
        await first.stop()

        let second = try environment.host(settings: ["devices": [configuredLight]])
        let restored = try #require(second.mainBridge.server.accessories.first { $0.id == lightID })
        #expect(restored.aid == original.aid)
        #expect(restored.service(.lightbulb)?[.brightness]?.value == .int(50))
        #expect(restored.service(.lightbulb)?[.on]?.readHandler == nil)

        try await second.start()
        await environment.plugin?.settle()
        let live = try #require(second.mainBridge.server.accessories.first { $0.id == lightID })
        #expect(live !== restored)
        #expect(live.aid == original.aid)
        #expect(live.service(.lightbulb)?.iid == original.service(.lightbulb)?.iid)
        #expect(live.service(.lightbulb)?[.on]?.readHandler != nil)
        #expect(second.mainBridge.server.accessories.count == 2)
        await second.stop()
    }

    @Test func disabledCachedLightIsRemoved() async throws {
        let first = try await environment.start(settings: ["devices": [configuredLight]])
        #expect(first.mainBridge.server.accessories.count == 2)
        await first.stop()

        var disabled = configuredLight
        disabled["enabled"] = false
        let second = try environment.host(settings: ["devices": [disabled]])
        #expect(second.mainBridge.server.accessories.count == 2)
        try await second.start()
        #expect(second.mainBridge.server.accessories.count == 1)
        await second.stop()
    }
}
