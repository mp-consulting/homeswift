import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import Matter
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import HomeswiftMatter

let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Waits until `condition` holds, failing after `timeout`.
/// 30 seconds, as the other targets' copies: loaded CI runners are slow.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async throws {
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
        try addRobot(standsFor: nil)
    }

    /// A pool robot's switch, as its cached copy (no hint) or as the plugin makes it.
    func addRobot(standsFor: ServiceStandsFor?) throws {
        let robot = Service(.switch, name: "Robot")
        robot.standsFor = standsFor
        try context.add(Accessory(id: "Household:robot", name: "Robot", category: .switch, services: [robot]))
    }

    /// A purifier and the filter it links.
    func addPurifier() throws -> Service {
        let filter = Service(.filterMaintenance, name: "Filter", optional: [.filterLifeLevel])
        let purifier = Service(.airPurifier, name: "Purifier", optional: [.rotationSpeed], linked: [filter])
        try context.add(Accessory(id: "Household:purifier", name: "Purifier", category: .airPurifier, services: [purifier, filter]))
        return filter
    }

    func stop() async {}

    func removeDoor() async throws { try await context.remove(id: "Household:door") }

    /// The door again as a new object of the same shape, as a plugin replaces a cached accessory.
    func replaceDoor(contact: Int) throws -> Service {
        let door = Service(.contactSensor, name: "Door")
        door[.contactSensorState]?.value = .int(contact)
        try context.add(Accessory(id: "Household:door", name: "Front door", category: .sensor, services: [door]))
        return door
    }
}

/// A host running the plugin, a Matter bridge over it on a memory network, and a commissioner on that network.
struct BridgeFixture {
    let host: PluginHost
    let plugin: HouseholdPlugin
    let matter: HomeswiftMatterBridge
    let commissioner: Commissioner
    let session: UInt16

    /// `deviceTransport` replaces the accessories' own nodes' memory transports (one that fails, say).
    init(_ configuration: MatterConfiguration = MatterConfiguration(),
         deviceTransport: (@Sendable (_ accessoryID: String) async -> any MatterTransport)? = nil) async throws {
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
        matter = try await HomeswiftMatterBridge(configuration: configuration, source: host, storage: Matter.MemoryStorage(),
                                                 deviceStorage: { _ in Matter.MemoryStorage() },
                                                 transport: await network.transport(named: "bridge"),
                                                 deviceTransport: { id in
                                                     if let deviceTransport { return await deviceTransport(id) }
                                                     return await network.transport(named: id)
                                                 }, advertise: false,
                                                 reliability: Self.fast, logger: testLogger)
        try await matter.start()
        let layer = MessageLayer(transport: await network.transport(named: "controller"), reliability: Self.fast)
        commissioner = try Commissioner(layer: layer, fabricID: 0xFAB, nodeID: 0x1122)
        try await commissioner.start()
        // Without the bridge, a test commissions the accessories' own nodes itself.
        session = configuration.bridge
            ? try await commissioner.commission(.memory("bridge"), passcode: matter.setupPayload.passcode, nodeID: 0x42).localSessionID : 0
    }

    /// MRP at a tenth of its timings: acknowledgements do not hold the exchanges up, and a peer still has some 340 ms to
    /// answer before the sender gives up (33 ms before it retransmits). At a hundredth that was 34 ms, which a loaded
    /// machine running every test target at once overran: commissioning failed `notAcknowledged`, or on a duplicate.
    static let fast = ReliabilityParameters(timeScale: 0.1)

    /// The accessory's device endpoint; throws, without recording an issue, while it is not bridged (an `eventually`
    /// may wait through a device made again).
    func endpoint(_ id: String) async throws -> EndpointNumber {
        guard let device = await matter.device(for: id) else { throw NotBridged(id: id) }
        return device.endpoint
    }

    struct NotBridged: Error {
        let id: String
    }

    func read(_ id: String, _ cluster: ClusterID, _ attribute: AttributeID) async throws -> TLVValue {
        try await commissioner.client.read(endpoint: try await endpoint(id), cluster: cluster, attribute: attribute, session: session)
    }

    func stop() async {
        await matter.stop()
        await host.stop()
    }
}

/// Runs `body` on a fresh fixture and stops it afterwards, whether or not `body` throws.
func withFixture(_ configuration: MatterConfiguration = MatterConfiguration(),
                 deviceTransport: (@Sendable (_ accessoryID: String) async -> any MatterTransport)? = nil,
                 _ body: (BridgeFixture) async throws -> Void) async throws {
    let fixture = try await BridgeFixture(configuration, deviceTransport: deviceTransport)
    do {
        try await body(fixture)
    } catch {
        await fixture.stop()
        throw error
    }
    await fixture.stop()
}

/// A transport that does not start, as UDP on `::` fails on a host with IPv6 off; counts its tries.
final class FailingTransport: MatterTransport {
    let error: any Error
    let tries: NIOLockedValueBox<Int>

    init(_ error: any Error, tries: NIOLockedValueBox<Int>) {
        self.error = error
        self.tries = tries
    }

    func start(receive: @escaping @Sendable ([UInt8], PeerAddress) async -> Void) async throws {
        tries.withLockedValue { $0 += 1 }
        throw error
    }

    func send(_ datagram: [UInt8], to peer: PeerAddress) async throws {}
    func close() async {}
}

final class PluginBox: @unchecked Sendable {
    var plugin: HouseholdPlugin?
}

@Suite(.timeLimit(.minutes(1)))
struct MatterBridgeTests {
    @Test func bridgesAccessoriesBothWays() async throws { try await withFixture { fixture in
        // The lock stays out unless exposeSecurity is on; the others are bridged.
        #expect(await fixture.matter.bridgedIDs == ["Household:button", "Household:door", "Household:lamp", "Household:robot"])

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
        try await eventually { await fixture.matter.bridgedIDs == ["Household:button", "Household:lamp", "Household:robot"] }
    } }

    @Test func makesAnAccessoryAMatterDeviceOfItsOwn() async throws {
        var configuration = MatterConfiguration()
        configuration.bridge = false
        configuration.devices = ["Household:lamp"]
        try await withFixture(configuration) { fixture in
            // Only the lamp is on Matter, on a node of its own.
            #expect(await fixture.matter.bridgedIDs == ["Household:lamp"])
            let status = await fixture.matter.statusJSON(includePairing: true)
            let own = try #require(status["ownDevices"]?.arrayValue?.first)
            #expect(own["id"] == "Household:lamp")
            #expect(own["port"] == .number(5541))
            #expect(status["devices"] == .array([]))
            let code = try #require(own["pairing"]?["manualCode"]?.stringValue)
            let passcode = try ManualPairingCode(code).passcode
            // Pages hear of the lamp's new fabric and its window closing, by the lamp's id.
            let changes = NIOLockedValueBox<[String?]>([])
            fixture.matter.onChange { device in changes.withLockedValue { $0.append(device) } }
            let session = try await fixture.commissioner.commission(.memory("Household:lamp"), passcode: passcode, nodeID: 0x43).localSessionID
            try await eventually { changes.withLockedValue { $0.contains("Household:lamp") } }
            #expect(changes.withLockedValue { $0.allSatisfy { $0 == "Household:lamp" } })

            // The lamp is the node's device: on endpoint 1, under the root, with no Aggregator.
            let client = fixture.commissioner.client
            #expect(try await client.read(endpoint: 0, cluster: DescriptorCluster.id, attribute: DescriptorCluster.Attribute.partsList, session: session)
                == .array([TLVElement(.unsigned(1))]))
            #expect(try await client.read(endpoint: 0, cluster: BasicInformationCluster.id, attribute: BasicInformationCluster.Attribute.nodeLabel,
                                          session: session) == .utf8("Lamp"))
            _ = try await client.invoke(CommandPath(endpoint: 1, cluster: OnOffCluster.id, command: OnOffCluster.Command.on), session: session)
            #expect(fixture.plugin.lamp[.on]?.value == .bool(true))
            fixture.plugin.lamp[.on]?.value = .bool(false)
            try await eventually {
                (try? await client.read(endpoint: 1, cluster: OnOffCluster.id, attribute: OnOffCluster.Attribute.onOff, session: session)) == .bool(false)
            }
            let after = await fixture.matter.statusJSON(includePairing: true)["ownDevices"]?.arrayValue?.first
            #expect(after?["commissioned"] == .bool(true))
            #expect(after?["pairing"] == nil)
        }
    }

    @Test func saysWhyADeviceOfItsOwnDidNotStart() async throws {
        var configuration = MatterConfiguration()
        configuration.bridge = false
        configuration.devices = ["Household:lamp"]
        let tries = NIOLockedValueBox(0)
        let noIPv6 = IOError(errnoCode: EAFNOSUPPORT, reason: "bind")
        try await withFixture(configuration, deviceTransport: { _ in FailingTransport(noIPv6, tries: tries) }) { fixture in
            // Tried once: another port would fail the same way.
            #expect(tries.withLockedValue { $0 } == 1)
            let status = await fixture.matter.statusJSON(includePairing: true)
            #expect(status["ownDevices"] == .array([]))
            let failed = try #require(status["failedDevices"]?.arrayValue?.first)
            #expect(failed["id"] == "Household:lamp")
            #expect(failed["name"] == "Lamp")
            #expect(failed["noIPv6"] == .bool(true))
            #expect(failed["error"]?.stringValue?.contains("IPv6") == true)

            // A look at the accessories leaves it; new settings try again, and taking it off forgets it.
            await fixture.matter.sync()
            #expect(tries.withLockedValue { $0 } == 1)
            #expect(await fixture.matter.apply(configuration))
            #expect(tries.withLockedValue { $0 } == 2)
            configuration.devices = []
            #expect(await fixture.matter.apply(configuration))
            #expect(await fixture.matter.statusJSON(includePairing: false)["failedDevices"] == .array([]))
        }
    }

    /// Kept out of the Home app, an accessory is still a Matter device of its own: Matter reads the bridge's accessories,
    /// not what HomeKit sees.
    @Test func staysOnMatterWhenHiddenFromHomeKit() async throws {
        var configuration = MatterConfiguration()
        configuration.bridge = false
        configuration.devices = ["Household:lamp"]
        try await withFixture(configuration) { fixture in
            try fixture.host.mainBridge.server.setHiddenFromHomeKit(["Household:lamp"])
            await fixture.matter.sync()
            #expect(await fixture.matter.bridgedIDs == ["Household:lamp"])
            #expect(await fixture.matter.statusJSON(includePairing: false)["ownDevices"]?.arrayValue?.count == 1)
        }
    }

    @Test func triesAnotherPortWhenOneIsTaken() async throws {
        var configuration = MatterConfiguration()
        configuration.bridge = false
        configuration.devices = ["Household:lamp"]
        let tries = NIOLockedValueBox(0)
        let taken = IOError(errnoCode: EADDRINUSE, reason: "bind")
        try await withFixture(configuration, deviceTransport: { _ in FailingTransport(taken, tries: tries) }) { fixture in
            #expect(tries.withLockedValue { $0 } == 5)
            let failed = try #require(await fixture.matter.statusJSON(includePairing: false)["failedDevices"]?.arrayValue?.first)
            #expect(failed["noIPv6"] == .bool(false))
        }
    }

    @Test func movesAnAccessoryToANodeOfItsOwnInPlace() async throws { try await withFixture { fixture in
        var next = await fixture.matter.configuration
        next.devices = ["Household:door"]
        #expect(await fixture.matter.apply(next))
        // The door leaves the bridge for a node of its own; the bridge's session goes on.
        #expect(await fixture.matter.statusJSON(includePairing: false)["ownDevices"]?.arrayValue?.first?["id"] == "Household:door")
        let lamp = try await fixture.endpoint("Household:lamp")
        _ = try await fixture.commissioner.client.invoke(CommandPath(endpoint: lamp, cluster: OnOffCluster.id, command: OnOffCluster.Command.on),
                                                         session: fixture.session)
        #expect(fixture.plugin.lamp[.on]?.value == .bool(true))
        #expect(await fixture.matter.qrCode(device: "Household:door") != nil)
        // A new port needs a restart.
        next.port += 10
        #expect(await !fixture.matter.apply(next))
    } }

    @Test func turnsWhitesIntoColorsOnALightWithoutColorTemperature() async throws { try await withFixture { fixture in
        let lamp = try await fixture.endpoint("Household:lamp")
        // MoveToColorTemperature: 370 mireds, a warm white, written as the hue and saturation of that white.
        _ = try await fixture.commissioner.client.invoke(
            CommandPath(endpoint: lamp, cluster: ColorControlCluster.id, command: ColorControlCluster.Command.moveToColorTemperature),
            fields: .structure([.field(0, .unsigned(370)), .field(1, .unsigned(0)), .field(2, .unsigned(0)), .field(3, .unsigned(0))]),
            session: fixture.session)
        let white = ColorUtils.colorTemperatureToHueAndSaturation(370)
        try await eventually { fixture.plugin.lamp[.hue]?.value == .double(white.hue) && fixture.plugin.lamp[.saturation]?.value == .double(white.saturation) }
    } }

    @Test func keepsTheDeviceWhenAPluginReplacesTheAccessory() async throws { try await withFixture { fixture in
        let endpoint = try await fixture.endpoint("Household:door")
        let door = try await fixture.plugin.replaceDoor(contact: 1)
        // The same device on the new object's value, and following the new object's changes.
        try await eventually { (try? await fixture.read("Household:door", BooleanStateCluster.id, BooleanStateCluster.Attribute.stateValue)) == .bool(false) }
        #expect(try await fixture.endpoint("Household:door") == endpoint)
        door[.contactSensorState]?.value = .int(0)
        try await eventually { (try? await fixture.read("Household:door", BooleanStateCluster.id, BooleanStateCluster.Attribute.stateValue)) == .bool(true) }
    } }

    @Test func bridgesLocksOnlyWhenAsked() async throws {
        var configuration = MatterConfiguration()
        configuration.exposeSecurity = true
        configuration.include = ["Lock"]
        try await withFixture(configuration) { fixture in
        #expect(await fixture.matter.bridgedIDs == ["Household:lock"])
        fixture.plugin.lock[.lockCurrentState]?.value = .int(1)
        try await eventually { (try? await fixture.read("Household:lock", DoorLockCluster.id, DoorLockCluster.Attribute.lockState)) == .unsigned(1) }
        }
    }

    @Test func reportsStatusWithoutTheCodeUnlessAsked() async throws { try await withFixture { fixture in
        let status = await fixture.matter.statusJSON(includePairing: true)
        #expect(status["commissioned"] == .bool(true))
        #expect(status["fabrics"]?.arrayValue?.count == 1)
        // Commissioned: the window closed, so no code even for an administrator.
        #expect(status["pairing"] == nil)
        _ = try await fixture.matter.openCommissioningWindow(minutes: 5, device: nil)
        #expect(await fixture.matter.statusJSON(includePairing: true)["pairing"]?["manualCode"]?.stringValue == fixture.matter.setupPayload.manualCode)
        #expect(await fixture.matter.statusJSON(includePairing: false)["pairing"] == nil)
        #expect(await fixture.matter.statusJSON(includePairing: true)["pairing"]?["qrCode"]?.stringValue == fixture.matter.setupPayload.qrCode)

        _ = try await fixture.matter.removeFabric(index: 1, device: nil)
        #expect(await !fixture.matter.isCommissioned)
        // Without an ecosystem the bridge can be added again with its code.
        #expect(await fixture.matter.statusJSON(includePairing: true)["commissioningWindow"] == "open")
        await #expect(throws: Error.self) { try await fixture.matter.removeFabric(index: 1, device: nil) }
    } }
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
        #expect(try MatterConfiguration(block: ["tcp": true]).tcp)
        #expect(throws: MatterConfigurationError.invalid(key: "tcp", expected: "true or false")) { try MatterConfiguration(block: ["tcp": "yes"]) }
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

    @Test func mapsHeaterCoolersDoorsAndGarageDoors() throws {
        typealias Mode = ThermostatCluster.SystemModeEnum
        let air = Service(.heaterCooler, name: "Air conditioner", optional: [.heatingThresholdTemperature, .coolingThresholdTemperature])
        air[.active]?.value = .int(1)
        air[.targetHeaterCoolerState]?.value = .int(0)
        air[.heatingThresholdTemperature]?.value = .double(19)
        air[.coolingThresholdTemperature]?.value = .double(25)
        let heaterCooler = try #require(ServiceMapping(air, exposeSecurity: false))
        // Auto keeps it between its thresholds, Matter's two setpoints.
        #expect(heaterCooler.role == .heaterCooler(heating: true, cooling: true, auto: true))
        #expect(heaterCooler.states().contains(.thermostatMode(UInt8(Mode.auto))))
        #expect(heaterCooler.states().contains(.heatingSetpoint(19)) && heaterCooler.states().contains(.coolingSetpoint(25)))
        #expect(heaterCooler.writes(for: .setCoolingSetpoint(celsius: 24)).map(\.0.type.uuid) == [CharacteristicType.coolingThresholdTemperature.uuid])
        // Off is Active off; cool is Active on with the cool target.
        #expect(heaterCooler.writes(for: .setThermostatMode(UInt8(Mode.off))).map(\.1) == [.int(0)])
        #expect(heaterCooler.writes(for: .setThermostatMode(UInt8(Mode.cool))).map(\.1) == [.int(1), .int(2)])
        air[.active]?.value = .int(0)
        #expect(heaterCooler.states(changed: CharacteristicType.active.uuid) == [.thermostatMode(UInt8(Mode.off))])

        // A door moves as a covering does, with exposeSecurity on: it is an entrance. A window needs no such opt-in.
        let door = Service(.door, name: "Patio door")
        door[.currentPosition]?.value = .int(100)
        #expect(ServiceMapping(door, exposeSecurity: false) == nil)
        #expect(try #require(ServiceMapping(door, exposeSecurity: true)).states() == [.coveringPosition(percent100ths: 0)])
        #expect(ServiceMapping(Service(.window, name: "Skylight"), exposeSecurity: false)?.role == .covering)

        // A garage door is a security control, and a Closure: opening asks for its target, and on its way it is partly open.
        let garage = Service(.garageDoorOpener, name: "Garage")
        #expect(ServiceMapping(garage, exposeSecurity: false) == nil)
        let opener = try #require(ServiceMapping(garage, exposeSecurity: true))
        #expect(opener.kind.deviceTypes.map(\.id) == [DeviceTypes.closure.id])
        garage[.currentDoorState]?.value = .int(2)
        #expect(opener.states() == [.closure(.partiallyOpened, moving: true)])
        garage[.currentDoorState]?.value = .int(1)
        #expect(opener.states() == [.closure(.fullyClosed, moving: false)])
        #expect(opener.writes(for: .setClosureOpen(true)).map(\.1) == [.int(0)])

        // A faucet is a water valve whose Active says whether it runs.
        let faucet = Service(.faucet, name: "Kitchen tap")
        faucet[.active]?.value = .int(1)
        #expect(try #require(ServiceMapping(faucet, exposeSecurity: false)).states() == [.valveOpen(true)])
    }

    @Test func mapsAirPurifiersFansAndAirReadings() throws {
        let filter = Service(.filterMaintenance, name: "Filter", optional: [.filterLifeLevel, .resetFilterIndication])
        let purifier = Service(.airPurifier, name: "Purifier", optional: [.rotationSpeed, .swingMode], linked: [filter])
        purifier[.active]?.value = .int(1)
        purifier[.rotationSpeed]?.value = .double(40)
        filter[.filterLifeLevel]?.value = .double(7)
        // The filter the purifier links is reported with it, not on its own; one it does not link stays out.
        #expect(ServiceMapping(filter, exposeSecurity: false) == nil)
        #expect(ServiceMapping(Service(.airPurifier, name: "Other"), exposeSecurity: false)?.role == .airPurifier(filter: false, rocking: false))
        let mapping = try #require(ServiceMapping(purifier, exposeSecurity: false))
        #expect(mapping.role == .airPurifier(filter: true, rocking: true))
        #expect(mapping.characteristics.contains { $0 === filter[.filterLifeLevel] })
        #expect(mapping.states().contains(.fanSpeed(percent: 40)))
        #expect(mapping.states(changed: CharacteristicType.filterLifeLevel.uuid) == [.filter(percentLeft: 7, needsChange: false)])
        #expect(mapping.writes(for: .resetFilter).map { $0.0 === filter[.resetFilterIndication] } == [true])
        #expect(mapping.writes(for: .setFanRocking(true)).map(\.1) == [.int(1)])

        let fan = Service(.fanv2, name: "Ceiling fan", optional: [.rotationDirection])
        fan[.rotationDirection]?.value = .int(1)
        let fanMapping = try #require(ServiceMapping(fan, exposeSecurity: false))
        #expect(fanMapping.role == .fan(rocking: false, direction: true))
        #expect(fanMapping.states(changed: CharacteristicType.rotationDirection.uuid) == [.fanAirflowReversed(true)])

        // A carbon dioxide sensor is an air quality sensor measuring it, good until the level is abnormal.
        let co2 = Service(.carbonDioxideSensor, name: "Office", optional: [.carbonDioxideLevel])
        co2[.carbonDioxideDetected]?.value = .int(1)
        co2[.carbonDioxideLevel]?.value = .double(1450)
        let co2Mapping = try #require(ServiceMapping(co2, exposeSecurity: false))
        #expect(co2Mapping.role == .airQuality(measuring: [.carbonDioxide]))
        #expect(co2Mapping.states() == [.airQuality(4), .concentration(.carbonDioxide, 1450)])
        let quality = Service(.airQualitySensor, name: "Bedroom", optional: [.pm2_5Density, .vocDensity])
        #expect(ServiceMapping(quality, exposeSecurity: false)?.role == .airQuality(measuring: [.pm25, .totalVolatileOrganicCompounds]))
    }

    @Test func keepsTheNodeStateInOwnerOnlyFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-matter-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MatterFileStorage(directory: directory)
        try await storage.setValue([1, 2, 3], for: "fabrics")
        try await storage.setValue([4], for: "../escape")
        #expect(await storage.value(for: "fabrics") == [1, 2, 3])
        #expect(await storage.value(for: "../escape") == [4])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("fabrics").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A key that is not a plain name stays inside the directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["%2E.%2Fescape", "fabrics"])
        try await storage.setValue(nil, for: "fabrics")
        #expect(await storage.value(for: "fabrics") == nil)
    }

    @Test func reportsTheSetpointOfANewMode() throws {
        let thermostat = Service(.thermostat, name: "Heat pump")
        thermostat[.targetTemperature]?.value = .double(21)
        thermostat[.targetHeatingCoolingState]?.value = .int(2)
        let mapping = try #require(ServiceMapping(thermostat, exposeSecurity: false))
        let states = mapping.states(changed: CharacteristicType.targetHeatingCoolingState.uuid)
        #expect(states.contains(.thermostatMode(UInt8(ThermostatCluster.SystemModeEnum.cool))))
        #expect(states.contains(.coolingSetpoint(21)))
    }

    @Test func keepsAThermostatInAutoBetweenItsThresholds() throws {
        typealias Mode = ThermostatCluster.SystemModeEnum
        let thermostat = Service(.thermostat, name: "Heat pump", optional: [.heatingThresholdTemperature, .coolingThresholdTemperature])
        thermostat[.targetTemperature]?.value = .double(21)
        thermostat[.heatingThresholdTemperature]?.value = .double(19)
        thermostat[.coolingThresholdTemperature]?.value = .double(25)
        thermostat[.targetHeatingCoolingState]?.value = .int(3)
        let mapping = try #require(ServiceMapping(thermostat, exposeSecurity: false))
        #expect(mapping.role == .thermostat(cooling: true, auto: true))
        // In auto, Matter's two setpoints are the thresholds, both ways.
        let states = mapping.states(changed: CharacteristicType.targetHeatingCoolingState.uuid)
        #expect(states == [.thermostatMode(UInt8(Mode.auto)), .heatingSetpoint(19), .coolingSetpoint(25)])
        #expect(mapping.writes(for: .setHeatingSetpoint(celsius: 18)).map(\.0.type.uuid) == [CharacteristicType.heatingThresholdTemperature.uuid])
        #expect(mapping.writes(for: .setThermostatMode(UInt8(Mode.auto))).map(\.1) == [.int(3)])
        // In heat, the one target temperature is the heating setpoint again.
        thermostat[.targetHeatingCoolingState]?.value = .int(1)
        #expect(mapping.states(changed: CharacteristicType.targetHeatingCoolingState.uuid) == [.thermostatMode(UInt8(Mode.heat)), .heatingSetpoint(21)])
        #expect(mapping.writes(for: .setHeatingSetpoint(celsius: 22)).map(\.0.type.uuid) == [CharacteristicType.heatingThresholdTemperature.uuid, CharacteristicType.targetTemperature.uuid])
        // A cooling setpoint in heat keeps the heat target; one past HAP's range is the nearest it takes.
        #expect(mapping.writes(for: .setCoolingSetpoint(celsius: 24)).map(\.0.type.uuid) == [CharacteristicType.coolingThresholdTemperature.uuid])
        thermostat[.targetHeatingCoolingState]?.value = .int(3)
        #expect(mapping.writes(for: .setHeatingSetpoint(celsius: 28)).map(\.1) == [.double(25)])

        // Without thresholds there is no auto in Matter: HAP's auto shows as heat, and Matter's auto writes nothing.
        let plain = Service(.thermostat, name: "Radiator")
        plain[.targetHeatingCoolingState]?.value = .int(3)
        let single = try #require(ServiceMapping(plain, exposeSecurity: false))
        #expect(single.role == .thermostat(cooling: true, auto: false))
        #expect(single.states().contains(.thermostatMode(UInt8(Mode.heat))))
        #expect(single.writes(for: .setThermostatMode(UInt8(Mode.auto))).isEmpty)
        #expect(ServiceMapping.hapMode(systemMode: ServiceMapping.systemMode(hap: 3, auto: true), auto: true) == 3)
        #expect(ServiceMapping.hapMode(systemMode: ServiceMapping.systemMode(hap: 3)) == 1)
    }

    @Test func mapsACleaningRobotToARobotVacuum() throws {
        let robot = Service(.switch, name: "Pool robot")
        // A plain switch is a plug; one that stands for a cleaning robot is a robot vacuum.
        #expect(ServiceMapping(robot, exposeSecurity: false)?.role == .plug)
        robot.standsFor = .cleaningRobot
        let mapping = try #require(ServiceMapping(robot, exposeSecurity: false))
        #expect(mapping.role == .cleaningRobot)
        #expect(mapping.kind.deviceTypes.map(\.id) == [DeviceTypes.roboticVacuumCleaner.id])
        robot[.on]?.value = .bool(true)
        #expect(mapping.states() == [.robot(.running)])
        // Start and resume turn the switch on; stop, pause and going home turn it off.
        #expect(mapping.writes(for: .startCleaning).map(\.1) == [.bool(true)])
        #expect(mapping.writes(for: .resumeCleaning).map(\.1) == [.bool(true)])
        for command in [DeviceCommand.stopCleaning, .pauseCleaning, .returnToDock] { #expect(mapping.writes(for: command).map(\.1) == [.bool(false)]) }
    }

    @Test func reportsAPausedRobotAsPausedUntilItRunsAgain() async throws { try await withFixture { fixture in
        try await fixture.plugin.addRobot(standsFor: .cleaningRobot)
        try await eventually {
            let types = try? await fixture.read("Household:robot", DescriptorCluster.id, DescriptorCluster.Attribute.deviceTypeList)
            return types?.elements?.first?.value[0]?.uint == UInt64(DeviceTypes.roboticVacuumCleaner.id)
        }
        typealias Operational = RvcOperationalStateCluster
        let state: @Sendable () async throws -> TLVValue = { try await fixture.read("Household:robot", Operational.id, Operational.Attribute.operationalState) }
        let robot = try await fixture.endpoint("Household:robot")
        func invoke(_ command: CommandID) async throws {
            _ = try await fixture.commissioner.client.invoke(CommandPath(endpoint: robot, cluster: Operational.id, command: command),
                                                             session: fixture.session)
        }
        // Start cleaning, then pause: the switch goes off, and the robot is paused, so Resume is accepted.
        _ = try await fixture.commissioner.client.invoke(
            CommandPath(endpoint: robot, cluster: RvcRunModeCluster.id, command: RvcRunModeCluster.Command.changeToMode),
            fields: .structure([.field(0, .unsigned(1))]), session: fixture.session)
        try await eventually { (try? await state()) == .unsigned(RvcOperationalStateCluster.OperationalStateEnum.running) }
        try await invoke(Operational.Command.pause)
        try await eventually { (try? await state()) == .unsigned(RvcOperationalStateCluster.OperationalStateEnum.paused) }
        try await invoke(Operational.Command.resume)
        try await eventually { (try? await state()) == .unsigned(RvcOperationalStateCluster.OperationalStateEnum.running) }
    } }

    @Test func reportsAFiltersWearOnItsPurifier() async throws { try await withFixture { fixture in
        let filter = try await fixture.plugin.addPurifier()
        try await eventually {
            let types = try? await fixture.read("Household:purifier", DescriptorCluster.id, DescriptorCluster.Attribute.deviceTypeList)
            return types?.elements?.first?.value[0]?.uint == UInt64(DeviceTypes.airPurifier.id)
        }
        // The filter is another service: its change reaches the purifier's HEPA filter all the same.
        filter[.filterLifeLevel]?.value = .double(12)
        try await eventually {
            (try? await fixture.read("Household:purifier", HepaFilterMonitoringCluster.id, HepaFilterMonitoringCluster.Attribute.condition)) == .unsigned(12)
        }
    } }

    @Test func makesTheDeviceAgainWhenItsRoleChanges() async throws { try await withFixture { fixture in
        // A plugin replaces its cached switch with one that stands for a cleaning robot: the plug becomes a robot vacuum,
        // on the same endpoint.
        try await fixture.plugin.addRobot(standsFor: .cleaningRobot)
        try await eventually {
            let types = try? await fixture.read("Household:robot", DescriptorCluster.id, DescriptorCluster.Attribute.deviceTypeList)
            return types?.elements?.first?.value[0]?.uint == UInt64(DeviceTypes.roboticVacuumCleaner.id)
        }
    } }

    @Test func mapsAlarmsValvesAndMeters() throws {
        let smoke = Service(.smokeSensor, name: "Hall")
        smoke[.smokeDetected]?.value = .int(1)
        #expect(try #require(ServiceMapping(smoke, exposeSecurity: false)).states() == [.smoke(true)])
        let carbonMonoxide = Service(.carbonMonoxideSensor, name: "Garage")
        #expect(try #require(ServiceMapping(carbonMonoxide, exposeSecurity: false)).states() == [.carbonMonoxide(false)])
        let air = Service(.airQualitySensor, name: "Bedroom")
        air[.airQuality]?.value = .int(4)
        #expect(try #require(ServiceMapping(air, exposeSecurity: false)).states() == [.airQuality(4)])

        // A valve opens through Active and reports In Use.
        let valve = Service(.valve, name: "Garden")
        valve[.inUse]?.value = .int(1)
        let valveMapping = try #require(ServiceMapping(valve, exposeSecurity: false))
        #expect(valveMapping.states() == [.valveOpen(true)])
        #expect(valveMapping.writes(for: .setValveOpen(false)).map(\.1) == [.int(0)])
        #expect(valveMapping.writes(for: .setValveOpen(false)).first?.0.type.uuid == CharacteristicType.active.uuid)

        // An outlet with Eve's readings is metered: watts and kWh follow the on state.
        let outlet = Service(.outlet, name: "Heater", extra: [Characteristic(EveCharacteristic.currentConsumption, value: .int(1200)),
                                                              Characteristic(EveCharacteristic.totalConsumption, value: .double(3.25))])
        let outletMapping = try #require(ServiceMapping(outlet, exposeSecurity: false))
        #expect(outletMapping.isMetered)
        #expect(outletMapping.kind.deviceTypes.map(\.id) == [DeviceTypes.onOffPlugInUnit.id, DeviceTypes.electricalSensor.id])
        #expect(outletMapping.states() == [.on(false), .power(watts: 1200), .energy(kilowattHours: 3.25)])
        #expect(outletMapping.states(changed: EveCharacteristic.currentConsumption.uuid) == [.power(watts: 1200)])
        #expect(!(try #require(ServiceMapping(Service(.outlet, name: "Lamp"), exposeSecurity: false))).isMetered)
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

}
