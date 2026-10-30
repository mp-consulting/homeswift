import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import Matter
import Testing

@testable import HomeswiftMatter

let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Waits until `condition` holds, failing after `timeout`.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met in \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A plugin with a color lamp, a door sensor, a lock and a button, which tests change and remove.
actor HouseholdPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Household"
    static let name = "Household"

    let context: PluginContext
    let lamp = Service(.lightbulb, name: "Lamp", optional: [.brightness, .hue, .saturation], isPrimary: true)
    let door = Service(.contactSensor, name: "Door")
    let lock = Service(.lockMechanism, name: "Lock")
    let button = Service(.statelessProgrammableSwitch, name: "Button")

    init(configuration: Configuration, context: PluginContext) {
        self.context = context
    }

    func start() async throws {
        try context.add(Accessory(id: "Household:lamp", name: "Lamp", category: .lightbulb, services: [lamp]))
        try context.add(Accessory(id: "Household:door", name: "Front door", category: .sensor, services: [door]))
        try context.add(Accessory(id: "Household:lock", name: "Lock", category: .doorLock, services: [lock]))
        try context.add(Accessory(id: "Household:button", name: "Button", category: .programmableSwitch, services: [button]))
    }

    func stop() async {}

    func removeDoor() async throws { try await context.remove(id: "Household:door") }
}

/// A host running the plugin, a Matter bridge over it on a memory network, and a commissioner on that network.
struct BridgeFixture {
    let host: PluginHost
    let plugin: HouseholdPlugin
    let matter: HomeswiftMatterBridge
    let commissioner: Commissioner
    let session: UInt16

    init(_ configuration: MatterConfiguration = MatterConfiguration()) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-matter-tests-\(UUID().uuidString)")
        let created = PluginBox()
        var registry = PluginRegistry()
        registry.register(platform: HouseholdPlugin.platform, name: HouseholdPlugin.name) { _, context in
            let plugin = HouseholdPlugin(configuration: .init(), context: context)
            created.plugin = plugin
            return plugin
        }
        host = try PluginHost(
            configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [try .init(platform: "Household", name: "Household", settings: [:])]),
            registry: registry, storageDirectory: directory,
            options: PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() })
        try await host.start()
        plugin = try #require(created.plugin)

        let network = MemoryNetwork()
        matter = try await HomeswiftMatterBridge(configuration: configuration, host: host, storageDirectory: directory.appendingPathComponent("matter"),
                                                 transport: await network.transport(named: "bridge"), advertise: false,
                                                 resyncInterval: .milliseconds(50), logger: testLogger)
        try await matter.start()
        let layer = MessageLayer(transport: await network.transport(named: "controller"))
        commissioner = try Commissioner(layer: layer, fabricID: 0xFAB, nodeID: 0x1122)
        try await commissioner.start()
        session = try await commissioner.commission(.memory("bridge"), passcode: matter.setupPayload.passcode, nodeID: 0x42).localSessionID
    }

    func endpoint(_ id: String) async throws -> EndpointNumber {
        try #require(await matter.device(for: id)).endpoint
    }

    func read(_ id: String, _ cluster: ClusterID, _ attribute: AttributeID) async throws -> TLVValue {
        try await commissioner.client.read(endpoint: try await endpoint(id), cluster: cluster, attribute: attribute, session: session)
    }

    func stop() async {
        await matter.stop()
        await host.stop()
    }
}

final class PluginBox: @unchecked Sendable {
    var plugin: HouseholdPlugin?
}

@Suite(.timeLimit(.minutes(1)))
struct MatterBridgeTests {
    @Test func bridgesAccessoriesBothWays() async throws {
        let fixture = try await BridgeFixture()
        defer { Task { await fixture.stop() } }
        // The lock stays out unless exposeSecurity is on; the others are bridged.
        #expect(await fixture.matter.bridgedIDs == ["Household:button", "Household:door", "Household:lamp"])

        // A Matter command writes the characteristic as Apple Home would.
        let lamp = try await fixture.endpoint("Household:lamp")
        _ = try await fixture.commissioner.client.invoke(CommandPath(endpoint: lamp, cluster: OnOffCluster.id, command: OnOffCluster.Command.on),
                                                         session: fixture.session)
        #expect(fixture.plugin.lamp[.on]?.value == .bool(true))
        _ = try await fixture.commissioner.client.invoke(
            CommandPath(endpoint: lamp, cluster: LevelControlCluster.id, command: LevelControlCluster.Command.moveToLevel),
            fields: .structure([.field(0, .unsigned(127)), .field(1, .null), .field(2, .unsigned(0)), .field(3, .unsigned(0))]), session: fixture.session)
        try await eventually { fixture.plugin.lamp[.brightness]?.value == .int(50) }

        // A value the plugin sets reaches Matter.
        fixture.plugin.lamp[.brightness]?.value = .int(100)
        try await eventually { (try? await fixture.read("Household:lamp", LevelControlCluster.id, LevelControlCluster.Attribute.currentLevel)) == .unsigned(254) }
        // HAP's contact detected (0) is a closed contact, Matter's true.
        fixture.plugin.door[.contactSensorState]?.value = .int(1)
        try await eventually { (try? await fixture.read("Household:door", BooleanStateCluster.id, BooleanStateCluster.Attribute.stateValue)) == .bool(false) }
        fixture.plugin.door[.contactSensorState]?.value = .int(0)
        try await eventually { (try? await fixture.read("Household:door", BooleanStateCluster.id, BooleanStateCluster.Attribute.stateValue)) == .bool(true) }

        // An accessory the plugin removes leaves the bridge.
        try await fixture.plugin.removeDoor()
        try await eventually { await fixture.matter.bridgedIDs == ["Household:button", "Household:lamp"] }
    }

    @Test func bridgesLocksOnlyWhenAsked() async throws {
        var configuration = MatterConfiguration()
        configuration.exposeSecurity = true
        configuration.include = ["Lock"]
        let fixture = try await BridgeFixture(configuration)
        defer { Task { await fixture.stop() } }
        #expect(await fixture.matter.bridgedIDs == ["Household:lock"])
        fixture.plugin.lock[.lockCurrentState]?.value = .int(1)
        try await eventually { (try? await fixture.read("Household:lock", DoorLockCluster.id, DoorLockCluster.Attribute.lockState)) == .unsigned(1) }
    }

    @Test func reportsStatusWithoutTheCodeUnlessAsked() async throws {
        let fixture = try await BridgeFixture()
        defer { Task { await fixture.stop() } }
        let status = await fixture.matter.statusJSON(includePairing: true)
        #expect(status["commissioned"] == .bool(true))
        #expect(status["fabrics"]?.arrayValue?.count == 1)
        // Commissioned: the window closed, so no code even for an administrator.
        #expect(status["pairing"] == nil)
        _ = try await fixture.matter.openCommissioningWindow(minutes: 5)
        #expect(await fixture.matter.statusJSON(includePairing: true)["pairing"]?["manualCode"]?.stringValue == fixture.matter.setupPayload.manualCode)
        #expect(await fixture.matter.statusJSON(includePairing: false)["pairing"] == nil)
        #expect(await fixture.matter.qrCodePayload() == fixture.matter.setupPayload.qrCode)

        _ = try await fixture.matter.removeFabric(index: 1)
        #expect(await !fixture.matter.isCommissioned)
        await #expect(throws: Error.self) { try await fixture.matter.removeFabric(index: 1) }
    }
}

struct MatterMappingTests {
    @Test func readsTheBlock() throws {
        let configuration = try MatterConfiguration(block: ["platform": "HomeswiftMatter", "port": 5541, "include": ["PhilipsHue", " Desk* "], "exclude": ["*garage*"]])
        #expect(configuration.port == 5541)
        #expect(configuration.include == ["PhilipsHue", "Desk*"])
        #expect(configuration.bridges(["PhilipsHue", "Hue", "PhilipsHue:1", "Kitchen"]))
        #expect(configuration.bridges(["Other", "x", "Other:2", "desk lamp"]))
        #expect(!configuration.bridges(["PhilipsHue", "Hue", "PhilipsHue:3", "Garage light"]))
        #expect(!configuration.bridges(["Other", "x", "Other:4", "Hall"]))
        #expect(throws: MatterConfigurationError.invalid(key: "port", expected: "a port number")) { try MatterConfiguration(block: ["port": 70000]) }
        #expect(throws: MatterConfigurationError.invalid(key: "include", expected: "a list of names")) { try MatterConfiguration(block: ["include": "Hue"]) }
        #expect(MatterConfiguration().bridges(["anything"]))
    }

    @Test func convertsValues() {
        #expect(ServiceMapping.level(percent: 0) == 1)
        #expect(ServiceMapping.level(percent: 100) == 254)
        #expect(ServiceMapping.percent(level: 254) == 100)
        #expect(ServiceMapping.percent(level: 1) == 1)
        #expect(ServiceMapping.scale(180, from: 360) == 127)
        #expect(ServiceMapping.unscale(254, to: 360) == 360)
        #expect(ServiceMapping.hapMode(systemMode: ServiceMapping.systemMode(hap: 2)) == 2)
        #expect(ServiceMapping.hapMode(systemMode: ServiceMapping.systemMode(hap: 0)) == 0)
        #expect(ServiceMapping.press(.int(2)) == .long)
    }

    @Test func mapsServicesAndCommands() throws {
        let covering = Service(.windowCovering, name: "Blind")
        covering[.currentPosition]?.value = .int(30)
        let mapping = try #require(ServiceMapping(covering, exposeSecurity: false))
        // 30 % open is 70 % closed.
        #expect(mapping.states() == [.coveringPosition(percent100ths: 7000)])
        #expect(mapping.writes(for: .setCoveringPosition(percent100ths: 2500)).map(\.1) == [.int(75)])

        let light = Service(.lightbulb, name: "Lamp", optional: [.colorTemperature])
        #expect(ServiceMapping(light, exposeSecurity: false)?.role == .light(dimmable: false, colorTemperature: true, hueSaturation: false))
        // A switch that opens something is a security control, left out like a lock.
        let opener = Service(.switch, name: "Gate")
        opener[.on]?.securityControl()
        #expect(ServiceMapping(opener, exposeSecurity: false) == nil)
        #expect(ServiceMapping(Service(.lockMechanism, name: "Lock"), exposeSecurity: false) == nil)
        #expect(ServiceMapping(Service(.lockMechanism, name: "Lock"), exposeSecurity: true)?.role == .lock)
    }

    @Test func convertsChromaticity() {
        // The sRGB primaries' chromaticities come back as their hues, fully saturated.
        let red = ColorConversion.hueSaturation(x: 0.64, y: 0.33)
        #expect(abs(red.hue - 0) < 2 || abs(red.hue - 360) < 2)
        #expect(red.saturation > 98)
        let green = ColorConversion.hueSaturation(x: 0.30, y: 0.60)
        #expect(abs(green.hue - 120) < 2)
        let blue = ColorConversion.hueSaturation(x: 0.15, y: 0.06)
        #expect(abs(blue.hue - 240) < 2)
        // D65 white has no saturation to speak of.
        #expect(ColorConversion.hueSaturation(x: 0.3127, y: 0.3290).saturation < 2)
    }

    @Test func derivesStableShortDeviceIDs() {
        let id = HomeswiftMatterBridge.deviceID("PhilipsHue:00000000-0000-0000-0000-000000000000")
        #expect(id.count == 32)
        #expect(id == HomeswiftMatterBridge.deviceID("PhilipsHue:00000000-0000-0000-0000-000000000000"))
        #expect(id != HomeswiftMatterBridge.deviceID("PhilipsHue:1"))
    }
}
