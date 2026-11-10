import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftTapo

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A host with one platform block whose plugin talks to `network`, every delay a thousandth of the real one.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Tapo-tests-\(UUID().uuidString)")
    let network: FakeTapoNetwork
    private let plugins = NIOLockedValueBox<[TapoPlugin]>([])

    init(network: FakeTapoNetwork = FakeTapoNetwork()) {
        self.network = network
    }

    var plugin: TapoPlugin? { plugins.withLockedValue { $0.last } }

    static var account: [String: Any] { ["username": "user@example.com", "password": "password123"] }

    func start(devices: [[String: Any]], settings: [String: Any] = account, bulbEnergyInterval: Duration = .seconds(600),
               connect: StreamdClient.Connect? = nil, cloud: FakeTapoCloud = FakeTapoCloud(), macAddress: String? = nil,
               neighbours: FakeNeighbours = FakeNeighbours(), control: FakeTapoControlCamera? = nil, timeScale: Double = 0.002,
               batteryInterval: Double? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        let network = network
        registry.register(platform: TapoPlugin.platform, name: TapoPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(TapoPlugin.Configuration.self, from: json)
            var dependencies = TapoPlugin.Dependencies(http: network, timeScale: timeScale, bulbEnergyInterval: bulbEnergyInterval, setupTimeout: .seconds(1))
            if let connect { dependencies.connect = connect }
            // A live view outlives its last viewer briefly here, as every other delay.
            dependencies.cameraTiming.linger = .milliseconds(20)
            // A loaded runner may let a fake session fall silent past its (scaled) timeout: the view reconnects
            // rather than giving up, so the camera stays awake for the test.
            dependencies.cameraTiming.reconnectBudget = 1_000
            dependencies.cloudHTTP = cloud
            dependencies.motionTiming = TapoMotionWatcher.Timing(interval: .milliseconds(20), maximumBackoff: .milliseconds(200))
            dependencies.motionHold = .milliseconds(300)
            dependencies.macAddress = { _ in macAddress }
            dependencies.neighbours = { neighbours.entries }
            dependencies.resolveNeighbours = { _ in neighbours.resolve() }
            if let control { dependencies.controlHTTP = control }
            if let batteryInterval { dependencies.batteryInterval = batteryInterval }
            let plugin = TapoPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        var block = settings
        block["devices"] = devices
        let platform = try HomeswiftConfiguration.Platform(platform: TapoPlugin.platform, name: "Tapo", settings: block)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [platform])
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
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
    #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
    return try #require(host.mainBridge.server.accessories.first { $0.id == id })
}

@Suite(.timeLimit(.minutes(1)))
struct TapoTests {
    let environment = TestEnvironment()
    let kitchenID = "TapoP100:192.168.1.21Kitchen"

    @Test func theHomebridgeBlockDecodes() throws {
        let block = #"""
        { "platform": "TapoP100", "name": "Tapo Smart Platform", "username": "me@example.com", "password": "...", "pollingInterval": 10,
          "devices": [ { "name": "Kitchen", "host": "192.168.1.21", "type": "Plug", "updateInterval": "10", "timeout": 2 } ] }
        """#
        let configuration = try JSONDecoder().decode(TapoPlugin.Configuration.self, from: Data(block.utf8))
        let device = try #require(configuration.devices?.first)
        #expect(device.updateInterval?.positive == 10)
        #expect(device.timeout?.positive == 2)
        #expect(device.deviceID == "192.168.1.21Kitchen")
        #expect(try JSONDecoder().decode(TapoPlugin.Configuration.self, from: Data(#"{"platform":"TapoP100"}"#.utf8)).devices == nil)
    }

    @Test func aPlugIsAnOutlet() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let plug = try await accessory(host, kitchenID)
        let outlet = try #require(plug.service(.outlet))
        #expect(outlet.isPrimary)
        #expect(outlet[.outletInUse]?.value == .bool(true))
        #expect(plug.category == .outlet)
        #expect(plug.information[.manufacturer]?.value == .string("TP-Link"))
        #expect(plug.information[.model]?.value == .string("Tapo P100"))
        #expect(await eventually { plug.information[.serialNumber]?.value == .string("0123456789ABCDEF0123456789ABCDEF") })
        #expect(plug.information[.firmwareRevision]?.value == .string("1.2.1"))
        #expect(plug.service(.eveHistory) == nil)
        await host.stop()
    }

    @Test func eachKindHasItsServices() async throws {
        let hosts = ["192.168.1.21", "192.168.1.22", "192.168.1.23", "192.168.1.24"]
        environment.network.update(hosts[1]) { $0 = .init() }
        environment.network.update(hosts[2]) { $0 = .init() }
        environment.network.update(hosts[3]) { $0 = .init() }
        let host = try await environment.start(devices: [
            ["name": "Heater", "host": hosts[0], "type": "PowerPlug"], ["name": "Desk", "host": hosts[1], "type": "light"],
            ["name": "Hall", "host": hosts[2], "type": "WhiteLight"], ["name": "Sofa", "host": hosts[3], "type": "Colorlight"],
        ])
        let heater = try await accessory(host, "TapoP100:192.168.1.21Heater")
        #expect(heater.service(.outlet)?[TapoEve.currentConsumption] != nil)
        #expect(heater.service(.outlet)?[TapoEve.totalConsumption] != nil)
        #expect(heater.service(.eveHistory) != nil)

        let desk = try #require(try await accessory(host, "TapoP100:192.168.1.22Desk").service(.lightbulb))
        #expect(desk[.brightness] != nil && desk[.colorTemperature] == nil && desk[.hue] == nil)

        let hall = try #require(try await accessory(host, "TapoP100:192.168.1.23Hall").service(.lightbulb))
        #expect(hall[.colorTemperature]?.type.minValue == 154 && hall[.colorTemperature]?.type.maxValue == 400)
        #expect(hall[.hue] == nil && hall.adaptiveLighting != nil)

        let sofaAccessory = try await accessory(host, "TapoP100:192.168.1.24Sofa")
        let sofa = try #require(sofaAccessory.service(.lightbulb))
        #expect(sofa[.colorTemperature]?.type.minValue == 140)
        #expect(sofa[.hue] != nil && sofa[.saturation] != nil && sofa[TapoEve.currentConsumption] != nil)
        #expect(sofa.adaptiveLighting != nil && sofaAccessory.service(.eveHistory) != nil)
        await host.stop()
    }

    @Test func aDeviceWithoutANameIsKnownByItsHost() async throws {
        let host = try await environment.start(devices: [["host": "192.168.1.21"]])
        let plug = try await accessory(host, "TapoP100:192.168.1.21")
        #expect(plug.name == "192.168.1.21")
        await host.stop()
    }

    @Test func writesReachTheDevice() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let plug = try await accessory(host, kitchenID)
        // The first answer taken in (its information shown), not only asked for: a write before it is No Response.
        #expect(await eventually { plug.information[.serialNumber]?.value == .string("0123456789ABCDEF0123456789ABCDEF") })
        let on = try #require(plug.service(.outlet)?[.on])
        try await on.write(.bool(true))
        let set = try #require(environment.network.device().sets.last)
        #expect(set["params"] == ["device_on": true])
        #expect(set["terminalUUID"]?.stringValue?.count == 36)
        #expect(environment.network.device().info["device_on"] == true)
        await host.stop()
    }

    @Test func changesOnTheDeviceReachHomeKit() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let on = try #require(try await accessory(host, kitchenID).service(.outlet)?[.on])
        #expect(await eventually { environment.network.device().methods.contains("get_device_info") })
        environment.network.update { $0.info["device_on"] = true }
        #expect(await eventually { on.value == .bool(true) })
        await host.stop()
    }

    /// Brightness, white and colour go only to a bulb that is on, as the Homebridge plugin sends them; on and off with
    /// them in one moment go first.
    @Test func aBulbThatIsOffTakesNoBrightness() async throws {
        environment.network.update { $0.info.merge(["brightness": 50, "color_temp": 2700, "hue": 0, "saturation": 0]) { $1 } }
        // Writes wait 50 ms for the ones made with them.
        let host = try await environment.start(
            devices: [["name": "Kitchen", "host": "192.168.1.21", "type": "Colorlight"]],
            settings: TestEnvironment.account.merging(["waitTimeUpdate": 25_000]) { $1 })
        let bulb = try #require(try await accessory(host, kitchenID).service(.lightbulb))
        #expect(await eventually { bulb[.colorTemperature]?.value == .int(370) })
        try await bulb[.brightness]!.write(.int(80))
        #expect(environment.network.device().sets.isEmpty)

        async let on: Void = bulb[.on]!.write(.bool(true))
        async let brightness: Void = bulb[.brightness]!.write(.int(30))
        _ = try await (on, brightness)
        #expect(environment.network.device().sets.map(\.["params"]) == [["device_on": true], ["brightness": 30]])

        // Hue and Saturation of one write are one request, with the white at 0.
        async let hue: Void = bulb[.hue]!.write(.double(120))
        async let saturation: Void = bulb[.saturation]!.write(.double(60))
        _ = try await (hue, saturation)
        #expect(environment.network.device().sets.last?["params"] == ["hue": 120, "saturation": 60, "color_temp": 0])

        try await bulb[.colorTemperature]!.write(.int(200))
        #expect(environment.network.device().sets.last?["params"] == ["hue": 0, "saturation": 0, "color_temp": 5000])
        await host.stop()
    }

    @Test func aRefusedSetIsNoResponse() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let plug = try await accessory(host, kitchenID)
        let on = try #require(plug.service(.outlet)?[.on])
        // Taken in: a write before the first answer would be No Response whatever the device says.
        #expect(await eventually { plug.information[.serialNumber]?.value == .string("0123456789ABCDEF0123456789ABCDEF") })
        environment.network.update { $0.setError = -1008 }
        await #expect(throws: HAPStatusError.self) { try await on.write(.bool(true)) }
        await host.stop()
    }

    /// A device that stops answering shows No Response; it is asked less often until it answers, then as before.
    @Test func anUnreachableDeviceIsNoResponseUntilItAnswers() async throws {
        environment.network.update { $0.reachable = false }
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21", "updateInterval": 10]])
        let plug = try await accessory(host, kitchenID)
        #expect(await eventually { plug.showsNoResponse })
        let device = try #require(await environment.plugin?.devices["192.168.1.21Kitchen"])
        #expect(await eventually { await device.failures >= 3 })
        environment.network.update {
            $0.reachable = true
            $0.info["device_on"] = true
        }
        // Availability and the reported value are applied in sequence by the poll.
        #expect(await eventually { !plug.showsNoResponse && plug.service(.outlet)?[.on]?.value == .bool(true) })
        #expect(plug.service(.outlet)?[.on]?.value == .bool(true))
        #expect(await device.failures == 0)
        await host.stop()
    }

    @Test func wrongCredentialsAreNoResponse() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]], settings: ["username": "user@example.com", "password": "nope"])
        let plug = try await accessory(host, kitchenID)
        #expect(await eventually { plug.showsNoResponse })
        await host.stop()
    }

    @Test func aP110ShowsItsPower() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21", "type": "PowerPlug"]])
        let outlet = try #require(try await accessory(host, kitchenID).service(.outlet))
        #expect(await eventually { outlet[TapoEve.currentConsumption]?.value == .double(15.3) && outlet[TapoEve.totalConsumption]?.value == .double(0.25) })
        #expect(outlet[TapoEve.totalConsumption]?.value == .double(0.25))
        #expect(outlet[.outletInUse]?.value == .bool(true))
        // One energy request per poll.
        let methods = environment.network.device().methods
        #expect(methods.filter { $0 == "get_energy_usage" }.count <= methods.filter { $0 == "get_device_info" }.count)
        await host.stop()
    }

    @Test func anL530ShowsItsAveragePower() async throws {
        environment.network.update { $0.info.merge(["device_on": true, "brightness": 50, "color_temp": 2700]) { $1 } }
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21", "type": "Colorlight"]])
        let bulb = try #require(try await accessory(host, kitchenID).service(.lightbulb))
        #expect(await eventually { bulb[TapoEve.currentConsumption]?.value == .double(9) && bulb[TapoEve.totalConsumption]?.value == .double(0.018) })
        #expect(bulb[TapoEve.totalConsumption]?.value == .double(0.018))
        // Every ten minutes, not every poll.
        #expect(await eventually { environment.network.device().methods.filter { $0 == "get_device_info" }.count > 3 })
        #expect(environment.network.device().methods.filter { $0 == "get_device_usage" }.count == 1)
        await host.stop()
    }

    @Test func aWhiteOrAColourSetElsewhereStopsAdaptiveLighting() async throws {
        environment.network.update { $0.info.merge(["device_on": true, "brightness": 50, "color_temp": 2700]) { $1 } }
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21", "type": "Colorlight"]])
        let bulb = try #require(try await accessory(host, kitchenID).service(.lightbulb))
        #expect(await eventually { bulb[.colorTemperature]?.value == .int(370) })
        let controller = try #require(bulb.adaptiveLighting)
        try controller.activateForTesting()
        #expect(await eventually { environment.network.device().sets.contains { $0["params"]?["color_temp"]?.intValue.map { $0 > 0 } == true } })
        // The device reporting the bridge's own white keeps it on.
        let polls = environment.network.device().methods.count
        #expect(await eventually { environment.network.device().methods.count > polls + 2 })
        #expect(controller.isAdaptiveLightingActive)
        environment.network.update { $0.info.merge(["color_temp": 0, "hue": 240, "saturation": 100]) { $1 } }
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        await host.stop()
    }

    /// The plugin keeps which devices spoke KLAP across launches: one that answers 404 later gets no securePassthrough login.
    @Test func aDeviceThatSpokeKLAPIsRememberedAcrossLaunches() async throws {
        let first = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        #expect(await eventually { environment.network.device().methods.contains("get_device_info") })
        await first.stop()
        environment.network.update { $0 = FakeTapoNetwork.Device(mode: .passthrough) }
        let second = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let plug = try await accessory(second, kitchenID)
        #expect(await eventually { plug.showsNoResponse })
        #expect(environment.network.device().handshakes == 0)
        #expect(environment.network.device().methods.isEmpty)
        await second.stop()
    }

    /// `devices` moves into `_accessories` under the same Device Id; the plugin runs from either shape alike.
    @Test func theCanonicalShapeKeepsTheIdentity() async throws {
        let block: JSONValue = [
            "platform": "TapoP100",
            "devices": [["name": "Kitchen", "host": "192.168.1.21", "type": "PowerPlug", "updateInterval": "10"], ["name": "No host"]],
            "_accessories": ["192.168.1.21Kitchen": ["type": "Plug"]],
        ]
        let canonical = TapoPlugin.canonical(block)
        #expect(canonical["devices"] == [["name": "No host"]])
        #expect(canonical["_accessories"] == ["192.168.1.21Kitchen": ["name": "Kitchen", "host": "192.168.1.21", "type": "Plug", "updateInterval": "10"]])
        #expect(TapoPlugin.canonical(canonical) == canonical)

        // Renamed once canonical: the same accessory, its new name.
        let host = try await environment.start(
            devices: [],
            settings: TestEnvironment.account.merging(["_accessories": ["192.168.1.21Kitchen": ["name": "Hob", "host": "192.168.1.21", "type": "PowerPlug"]]]) { $1 })
        let plug = try await accessory(host, kitchenID)
        #expect(plug.name == "Hob")
        #expect(plug.service(.outlet)?[TapoEve.currentConsumption] != nil)
        #expect(await environment.plugin?.deviceKind(of: "192.168.1.21Kitchen") == "powerPlug")
        await host.stop()
    }

    /// A Homebridge block's account moves into the vault, and the block loses it.
    @Test func theBlocksAccountMovesIntoTheVault() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21"]])
        let plugin = try #require(environment.plugin)
        let canonical = await plugin.canonicalSettings(["platform": "TapoP100", "username": "user@example.com", "password": "password123"])
        #expect(canonical == ["platform": "TapoP100"])
        #expect(plugin.credentials == TapoCredentials(username: "user@example.com", password: "password123"))
        #expect(await plugin.context.credentials(as: TapoCredentials.self) == TapoCredentials(username: "user@example.com", password: "password123"))
        await host.stop()
    }

    @Test func anExcludedDeviceIsNotPolled() async throws {
        let host = try await environment.start(
            devices: [["name": "Kitchen", "host": "192.168.1.21"]],
            settings: TestEnvironment.account.merging(["_accessories": ["192.168.1.21Kitchen": ["excluded": true]]]) { $1 })
        // The plugin has started (host.start waits for it) and runs no device.
        #expect(await environment.plugin?.devices.isEmpty == true)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == kitchenID })
        #expect(environment.network.device().methods.isEmpty)
        await host.stop()
    }

    @Test func setupListsTheDevicesAndChecksTheAccount() async throws {
        let host = try await environment.start(devices: [["name": "Kitchen", "host": "192.168.1.21", "type": "PowerPlug"]], settings: [:])
        let plugin = try #require(environment.plugin)
        #expect(TapoPlugin.accountAuthorization == .accountLogin)
        #expect(await plugin.accountAuthorized() == false)
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID) == ["192.168.1.21Kitchen"])
        #expect(found.first?.model == "Tapo P110")
        #expect(found.first?.address == "192.168.1.21")

        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else {
            Issue.record("Setup should ask for the account")
            return
        }
        #expect(prompt.fields.map(\.key) == ["username", "password"])
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "wrong"]))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "password123"])) else {
            Issue.record("Setup should be done")
            return
        }
        #expect(outcome.credentials?["username"] == "user@example.com")
        #expect(outcome.settings["password"] == JSONValue.null)
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(TapoPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Tapo TapoPlugin")
        let schema = try JSONValue(string: try #require(TapoPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "TapoP100")
    }
}
