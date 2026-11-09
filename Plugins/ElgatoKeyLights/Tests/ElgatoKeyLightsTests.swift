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
    private(set) var requestCount = 0
    private(set) var lightWrites: [LightState] = []

    func set(state: LightState) { self.state = self.state.merging(state) }
    func set(reachable: Bool) { self.reachable = reachable }
    func set(impostorHosts: Set<String>) { self.impostorHosts = impostorHosts }
    func set(unreachableHosts: Set<String>) { self.unreachableHosts = unreachableHosts }
    func set(macAddress: String?) { info.macAddress = macAddress }

    func send(_ request: KeyLightRequest) async throws -> KeyLightResponse {
        requestCount += 1
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
    /// The ARP table the plugin sees, by MAC.
    let arpTable = NIOLockedValueBox<[String: String]>([:])
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
                dependencies: .init(
                    transport: self.light, discover: { _ in discovered }, arp: { mac in self.arpTable.withLockedValue { $0[mac] } }, minimumPollingRate: 20,
                    discoveryWindow: .milliseconds(300)))
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
/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
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
        let host = try await environment.start(settings: ["devices": [light], "switchOffDurationMs": 50])
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

        // The platform's transitions over the light's own; its Power On stays as the light has it.
        #expect(await environment.light.settings == KeyLightSettings(
            powerOnBehavior: 1, powerOnBrightness: 20, powerOnTemperature: 213,
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
        let host = try await environment.start(settings: ["devices": [configuredLight], "pollingRate": 50])
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

    /// The bridge's Power On: read from the light's settings, written to them; Natural Light at its brightness now.
    @Test func setsALightsPowerOn() async throws {
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.powerOnSupport(of: lightID)?.behaviours == [.natural, .lastOn, .custom])
        #expect(try await plugin.powerOn(of: lightID) == PowerOn(.lastOn))
        try await plugin.setPowerOn(PowerOn(.custom, brightness: 60, temperature: 4000), of: lightID)
        var settings = await environment.light.settings
        #expect(settings.powerOnBehavior == 2 && settings.powerOnBrightness == 60 && settings.powerOnTemperature == 250)
        #expect(try await plugin.powerOn(of: lightID) == PowerOn(.custom, brightness: 60, temperature: 4000))
        try await plugin.setPowerOn(PowerOn(.natural, temperature: 2700), of: lightID)
        settings = await environment.light.settings
        #expect(settings.powerOnBrightness == 50 && settings.powerOnTemperature == 344)
        await #expect(throws: PowerOnError.self) { try await plugin.setPowerOn(PowerOn(.off), of: lightID) }
        // Its transitions stay as they were.
        #expect(await environment.light.settings.switchOnDurationMs == 300)
        await host.stop()
    }

    @Test func hostNamesAreResolvedThroughTheARPTableThenTheAnnouncedAddresses() async throws {
        environment.arpTable.withLockedValue { $0["AA:BB:CC:DD:EE:FF"] = "10.0.0.8" }
        let host = try await environment.start(settings: [:])
        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "elgato-key-light-1234.local", port: 9123, addresses: ["10.0.0.5"]))
        environment.discover.yield(.init(name: "Elgato Key Light 5678", mac: "11:22:33:44:55:66", host: "elgato-key-light-5678.local", port: 9123, addresses: ["fe80::1", "10.0.0.6"]))
        #expect(await eventually { host.mainBridge.server.accessories.count == 3 })
        #expect(await environment.plugin?.device(mac: "AA:BB:CC:DD:EE:FF")?.host == "10.0.0.8")
        #expect(await environment.plugin?.device(mac: "11:22:33:44:55:66")?.host == "10.0.0.6")
        await host.stop()
    }

    @Test func useIPConnectsToTheAnnouncedAddress() async throws {
        environment.arpTable.withLockedValue { $0["AA:BB:CC:DD:EE:FF"] = "10.0.0.8" }
        let host = try await environment.start(settings: ["useIP": true])
        environment.discover.yield(.init(name: "Elgato Key Light 1234", mac: "aa:bb:cc:dd:ee:ff", host: "elgato-key-light-1234.local", port: 9123, addresses: ["10.0.0.5"]))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })
        #expect(await environment.plugin?.device(mac: "AA:BB:CC:DD:EE:FF")?.host == "10.0.0.5")
        await host.stop()
    }

    @Test func hostResolution() async {
        let none: @Sendable (String) async -> String? = { _ in nil }
        #expect(await HostResolution.resolve(host: "192.168.1.5", mac: "AA:BB:CC:DD:EE:FF", addresses: ["10.0.0.1"], arp: { _ in "10.0.0.2" }) == "192.168.1.5")
        #expect(await HostResolution.resolve(host: "light.local", mac: "AA:BB:CC:DD:EE:FF", addresses: ["10.0.0.1"], arp: { _ in "10.0.0.2" }) == "10.0.0.2")
        #expect(await HostResolution.resolve(host: "light.local", mac: "AA:BB:CC:DD:EE:FF", addresses: ["fe80::1", "10.0.0.1"], arp: none) == "10.0.0.1")
        #expect(await HostResolution.resolve(host: "light.local", mac: "AA:BB:CC:DD:EE:FF", addresses: ["fe80::1"], arp: none) == "fe80::1")
        #expect(await HostResolution.resolve(host: "light.local", mac: "AA:BB:CC:DD:EE:FF", addresses: [], arp: none) == "light.local")
        #expect(HostResolution.isIPv4("10.0.0.255") && !HostResolution.isIPv4("10.0.0.256") && !HostResolution.isIPv4("10.0.0") && !HostResolution.isIPv4("light.local"))

        let darwin = """
            ? (192.168.1.1) at 0:11:22:aa:bb:cc on en0 ifscope [ethernet]
            ? (192.168.1.20) at 3c:6a:9d:4:a:b on en0 ifscope [ethernet]
            ? (192.168.1.21) at (incomplete) on en0 ifscope [ethernet]
            """
        #expect(HostResolution.address(in: darwin, mac: "3C:6A:9D:04:0A:0B") == "192.168.1.20")
        let linux = """
            IP address       HW type     Flags       HW address            Mask     Device
            192.168.1.30     0x1         0x2         3c:6a:9d:04:0a:0b     *        eth0
            """
        #expect(HostResolution.address(in: linux, mac: "3c-6a-9d-04-0a-0b") == "192.168.1.30")
        #expect(HostResolution.address(in: "192.168.1.40 dev eth0 lladdr 3c:6a:9d:04:0a:0b REACHABLE", mac: "3C:6A:9D:04:0A:0B") == "192.168.1.40")
        #expect(HostResolution.address(in: darwin, mac: "3C:6A:9D:04:0A:0C") == nil)
    }

    @Test func thePageListsOfflineAndAnnouncedLights() async throws {
        await environment.light.set(unreachableHosts: ["192.168.1.50"])
        let host = try await environment.start(settings: ["devices": [configuredLight]])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        environment.discover.yield(.init(name: "Elgato Key Light Air 1234", mac: "aa:bb:cc:dd:ee:ff", host: "elgato-key-light-air-1234.local", port: 9123, addresses: ["10.0.0.5"], model: "Elgato Key Light Air"))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })

        let answer = try await plugin.handleWebRequest(.init(method: "GET", path: "lights", query: [:], user: "admin"))
        #expect(answer.json["lights"]?[0]?["mac"] == "AA:BB:CC:DD:EE:FF")
        let pending = try #require(answer.json["pending"]?[0])
        #expect(pending["mac"] == "3C:6A:9D:04:0A:0B" && pending["status"] == "failed" && pending["host"] == "192.168.1.50")
        #expect(pending["error"] != nil && pending["error"] != .null)
        let discovered = try #require(answer.json["discovered"]?[0])
        #expect(discovered["mac"] == "AA:BB:CC:DD:EE:FF" && discovered["model"] == "Elgato Key Light Air")
        #expect(discovered["address"] == "10.0.0.5" && discovered["running"] == true)
    }

    // MARK: Setup

    /// Setup lists the lights by MAC: the announced ones set up as they are, one `enabled: false` left out by its
    /// settings, and nothing to authorize.
    @Test func setUpListsTheLightsByMAC() async throws {
        let host = try await environment.start(settings: [
            "devices": [["mac": "11:22:33:44:55:66", "enabled": false, "name": "Spare"]],
        ])
        environment.discover.yield(.init(name: "Elgato Key Light Air 1234", mac: "aa:bb:cc:dd:ee:ff", host: "10.0.0.5", port: 9123, model: "Elgato Key Light Air"))
        #expect(await eventually { host.mainBridge.server.accessories.count == 2 })
        let devices = try await host.discover(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights").devices
        let light = try #require(devices.first { $0.deviceID == "AA:BB:CC:DD:EE:FF" })
        #expect(light.isSetUp && !light.excludedBySettings && light.authorization == .none)
        #expect(light.name == "Studio Light" && light.address == "10.0.0.5")
        let spare = try #require(devices.first { $0.deviceID == "11:22:33:44:55:66" })
        #expect(spare.excludedBySettings && !spare.isSetUp && spare.name == "Spare")
        let plugin = try #require(environment.plugin)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(light))) else { Issue.record("expected done"); return }
        #expect(outcome.credentials == nil && outcome.settings.isEmpty)
        await host.stop()
    }

    /// An instance made only for Setup (not started) browses Bonjour for a moment and lists what it heard.
    @Test func setUpBrowsesOnAnInstanceThatIsNotRunning() async throws {
        let host = try environment.host(settings: [:])
        environment.discover.yield(.init(name: "Elgato Ring Light", mac: "aa:bb:cc:00:11:22", host: "ring.local", port: 9123, addresses: ["10.0.0.9"], model: "Elgato Ring Light"))
        let devices = try await host.discover(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights").devices
        #expect(devices == [DiscoveredDevice(deviceID: "AA:BB:CC:00:11:22", name: "Elgato Ring Light", model: "Elgato Ring Light", address: "10.0.0.9", isSetUp: true, kind: "light")])
        #expect(await environment.light.requestCount == 0)
    }

    /// A light Excluded in its Accessory Settings is never reached nor added, and Setup shows it as not set up.
    @Test func anExcludedLightIsNotReached() async throws {
        let host = try await environment.start(settings: [
            "devices": [configuredLight], "_accessories": ["3C:6A:9D:04:0A:0B": ["excluded": true]],
        ])
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge"])
        #expect(await environment.light.requestCount == 0)
        let devices = try await host.discover(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights").devices
        #expect(devices.first { $0.deviceID == "3C:6A:9D:04:0A:0B" }?.isSetUp == false)
        await host.stop()
    }

    /// Add by address: the light's host asked, the light there asked who it is, and its host kept in its Accessory
    /// Settings under its MAC; nothing answering, or a bad port, is said and asked again.
    @Test func addByAddressProbesTheLightAndKeepsItsHost() async throws {
        #expect(ElgatoKeyLightsPlugin.newDevices == .byAddress)
        await environment.light.set(macAddress: "3c:6a:9d:04:0a:0b")
        await environment.light.set(unreachableHosts: ["192.0.2.50"])
        let host = try environment.host(settings: [:])
        let outcome = try await host.withSetupPlugin(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights") { plugin, _ in
            guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { throw SetupError("expected a prompt") }
            #expect(prompt.fields.map(\.key) == ["host", "port"] && prompt.fields[1].optional)
            await #expect(throws: SetupError("No light answered at 192.0.2.50:9123")) {
                try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.50"]))
            }
            await #expect(throws: SetupError("The port must be between 1 and 65535")) {
                try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.60", "port": "0"]))
            }
            guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": " 192.168.1.60 ", "port": "9123"])) else {
                throw SetupError("expected done")
            }
            return outcome
        }
        #expect(outcome.deviceID == "3C:6A:9D:04:0A:0B" && outcome.credentials == nil)
        #expect(outcome.settings == ["host": "192.168.1.60", "port": .null])
    }

    /// A light whose Accessory Settings give its host (Add by address) is reached there without Bonjour, pinned, and
    /// listed by Setup at that address; its older entry of `addresses` is left aside.
    @Test func aLightAddedByAddressIsReachedAtItsHost() async throws {
        let host = try await environment.start(settings: [
            "addresses": [["host": "192.168.1.50", "mac": "3C:6A:9D:04:0A:0B"]],
            "_accessories": ["3C:6A:9D:04:0A:0B": ["host": "192.168.1.60", "port": 9124]],
        ])
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge", lightID])
        let device = try #require(await environment.plugin?.device(mac: "3C:6A:9D:04:0A:0B"))
        #expect(await device.host == "192.168.1.60")
        #expect(await device.port == 9124)
        environment.discover.yield(.init(name: "Elgato Key Light", mac: "3C:6A:9D:04:0A:0B", host: "10.0.0.99", port: 9123))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await device.host == "192.168.1.60")
        let devices = try await host.discover(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights").devices
        #expect(devices.first { $0.deviceID == "3C:6A:9D:04:0A:0B" }.map { $0.isSetUp && $0.address == "192.168.1.60" } == true)
        await host.stop()
    }

    /// The name an Accessory Setting gives a light wins over the one it reports.
    @Test func theAccessorySettingsNameNamesTheLight() async throws {
        let host = try await environment.start(settings: [
            "devices": [configuredLight], "_accessories": ["3C:6A:9D:04:0A:0B": ["name": "Desk"]],
        ])
        #expect(host.mainBridge.server.accessories.first { $0.id == lightID }?.name == "Desk")
        await host.stop()
    }

    // MARK: Settings

    /// A Homebridge block's `devices` moves into `_accessories` by MAC and `addresses`; what is there already stays, an
    /// entry without a MAC stays in `devices`, and the legacy power-on keys go (the light's own Power On now; one that
    /// had its own keeps its device's rather than taking Natural Light).
    @Test func canonicalSettingsMovesTheDevicesList() throws {
        let block = try JSONValue(any: [
            "platform": "ElgatoKeyLights", "name": "Elgato Key Lights", "powerOnBrightness": 30,
            "devices": [
                ["mac": "3c:6a:9d:4:a:b", "name": "Desk", "displayName": "Desk Light", "ip": "192.168.1.50", "port": 9124, "model": "Key Light",
                 "powerOnBehavior": 2, "powerOnBrightness": 40, "powerOnTemperature": 0],
                ["mac": "11:22:33:44:55:66", "enabled": false, "powerOnBehavior": 0, "host": "spare.local"],
                ["mac": "aa:bb:cc:dd:ee:ff", "displayName": "Ignored", "host": ""],
                ["name": "No MAC", "ip": "10.0.0.1"],
            ],
            "addresses": [["host": "10.0.0.9"]],
            "_accessories": ["AA:BB:CC:DD:EE:FF": ["name": "Kept"]],
        ] as [String: Any])
        let canonical = ElgatoKeyLightsPlugin.canonical(block, learned: ["10.0.0.9:9123": "AA:BB:CC:00:11:22"])
        #expect(canonical == (try JSONValue(any: [
            "platform": "ElgatoKeyLights", "name": "Elgato Key Lights",
            "devices": [["name": "No MAC", "ip": "10.0.0.1"]],
            "addresses": [
                ["host": "10.0.0.9", "mac": "AA:BB:CC:00:11:22"],
                ["host": "192.168.1.50", "port": 9124, "mac": "3C:6A:9D:04:0A:0B"],
                ["host": "spare.local", "mac": "11:22:33:44:55:66"],
            ],
            "_accessories": [
                "3C:6A:9D:04:0A:0B": ["name": "Desk Light", "naturalLight": false],
                "11:22:33:44:55:66": ["excluded": true],
                "AA:BB:CC:DD:EE:FF": ["name": "Kept"],
            ],
        ] as [String: Any])))
        // Canonical already: unchanged.
        #expect(ElgatoKeyLightsPlugin.canonical(canonical, learned: ["10.0.0.9:9123": "AA:BB:CC:00:11:22"]) == canonical)
    }

    /// The running instance answers `canonicalSettings` with the MACs it learned, and every light is a `light`.
    @Test func theRunningInstanceWritesTheCanonicalBlock() async throws {
        await environment.light.set(macAddress: "3c:6a:9d:04:0a:0b")
        let host = try await environment.start(settings: ["addresses": [["host": "192.168.1.50"]]])
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == lightID } })
        let block = try JSONValue(any: ["platform": "ElgatoKeyLights", "name": "Elgato Key Lights", "addresses": [["host": "192.168.1.50"]]] as [String: Any])
        let canonical = await host.canonicalSettings(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights", block: block)
        #expect(canonical["addresses"] == [["host": "192.168.1.50", "mac": "3C:6A:9D:04:0A:0B"]])
        #expect(await host.deviceKind(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights", deviceID: "3C:6A:9D:04:0A:0B") == "light")
        let devices = try await host.discover(platform: ElgatoKeyLightsPlugin.platform, name: "Elgato Key Lights").devices
        #expect(devices.map(\.kind) == ["light"] && devices.first?.deviceID == "3C:6A:9D:04:0A:0B" && devices.first?.address == "192.168.1.50")
        await host.stop()
    }

    /// A light of `addresses` with its MAC is pinned there: reached without Bonjour, never moved by an announcement.
    @Test func aLightByAddressIsPinned() async throws {
        let host = try await environment.start(settings: ["addresses": [["host": "192.168.1.50", "mac": "3c:6a:9d:04:0a:0b"]]])
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge", lightID])
        let device = try #require(await environment.plugin?.device(mac: "3C:6A:9D:04:0A:0B"))
        environment.discover.yield(.init(name: "Elgato Key Light", mac: "3C:6A:9D:04:0A:0B", host: "10.0.0.99", port: 9123))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await device.host == "192.168.1.50")
        await host.stop()
    }

    /// The schema declares a light's address (Add by address); its Power On is the bridge's.
    @Test func theSchemaDeclaresTheAccessorySettings() throws {
        let schema = try JSONValue(string: try #require(ElgatoKeyLightsPlugin.configurationSchemaJSON))
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        #expect(Set(fields.keys) == ["host", "port"])
        #expect(schema["schema"]?["properties"]?["powerOnBehavior"] == nil)
        #expect(schema["schema"]?["properties"]?["devices"] == nil && schema["schema"]?["properties"]?["addresses"] != nil)
    }

    @Test func assistantBackgroundDescribesThePort() throws {
        let background = try #require(ElgatoKeyLightsPlugin.assistantBackground)
        #expect(!background.isEmpty)
        #expect(!background.contains("Homebridge"))
        #expect(background.contains("is not responding, will keep retrying"))
        #expect(background.contains("Could not reach"))
    }
}
