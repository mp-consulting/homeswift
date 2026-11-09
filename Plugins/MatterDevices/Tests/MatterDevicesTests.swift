import Foundation
import Homeswift
@testable import HomeswiftMatterDevices
import HomeswiftPlugin
import Logging
import Matter
import NIOConcurrencyHelpers
import Testing

let testLogger = Logger(label: "MatterDevicesTests")

/// What the plugin finds on a memory network: the test node's pairing window, and the node once operational.
struct FakeDiscovery: MatterDiscovery {
    var window = CommissionableNode(instance: "4A1B2C3D4E5F6071", info: CommissionableNodeInfo(txt: ["D": "3840", "CM": "1", "VP": "65521+32768"])!,
                                    address: NodeAddress(host: "node", port: 0))
    let windowOpen = NIOLockedValueBox(true)

    func commissionable(for duration: Duration, until match: (@Sendable (CommissionableNode) -> Bool)?) async -> [CommissionableNode] {
        windowOpen.withLockedValue { $0 } ? [window] : []
    }

    func operational(instance: String, timeout: Duration) async -> NodeAddress? {
        NodeAddress(host: "node", port: 0)
    }
}

/// A Matter node with bridged devices on a memory network, and a bridge running the plugin against it.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-MatterDevices-tests-\(UUID().uuidString)")
    let network = MemoryNetwork()
    let discovery = FakeDiscovery()
    let node: MatterNode
    let bridge: MatterBridge
    let commands = NIOLockedValueBox<[DeviceCommand]>([])
    private let plugins = NIOLockedValueBox<[MatterDevicesPlugin]>([])
    var plugin: MatterDevicesPlugin? { plugins.withLockedValue { $0.last } }
    static let pairingCode = "34970112332"
    /// What the plugin checks attestation against: the Matter registry, as on a bridge, unless a test gives the test PKI.
    let trustStore: AttestationTrustStore

    init(trustStore: AttestationTrustStore = .registry) async throws {
        self.trustStore = trustStore
        var configuration = NodeConfiguration(passcode: 20202021, discriminator: 3840)
        configuration.reliability = ReliabilityParameters(timeScale: 0.2)
        node = try await MatterNode(configuration: configuration, storage: MemoryStorage(), transport: await network.transport(named: "node"))
        try await node.start()
        bridge = try await MatterBridge(node: node)
    }

    func start(settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let network = network, discovery = discovery, trustStore = trustStore
        registry.register(platform: MatterDevicesPlugin.platform, name: MatterDevicesPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(MatterDevicesPlugin.Configuration.self, from: json)
            var timing = MatterNodeLink.Timing()
            timing.lookup = .milliseconds(100)
            timing.firstRetry = .milliseconds(100)
            timing.longestRetry = .milliseconds(400)
            timing.grace = .milliseconds(500)
            timing.maxInterval = 2
            let dependencies = MatterDevicesPlugin.Dependencies(
                transport: { await network.transport(named: "homeswift-\(UUID().uuidString)") }, discovery: discovery,
                peer: { .memory($0.host) }, timing: timing,
                windowSearch: .milliseconds(100), reliability: ReliabilityParameters(timeScale: 0.2), trustStore: trustStore)
            let plugin = MatterDevicesPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: MatterDevicesPlugin.platform, name: MatterDevicesPlugin.name, settings: settings)
        let host = try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry,
                                  storageDirectory: directory, options: PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() })
        try await host.start()
        return host
    }

    /// Setup as the bridge runs it: the code asked for, the node commissioned, the credentials kept in the vault.
    func addNode(_ host: PluginHost) async throws -> String {
        let plugin = try #require(plugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { throw TestFailure("expected the code") }
        #expect(prompt.fields.map(\.key) == ["code"])
        // swift-matter's node attests with connectedhomeip's test PKI, which is not in the Matter registry: the person is
        // told so, and says to add it anyway.
        guard case .ask(let uncertified, let state) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["code": Self.pairingCode])) else {
            throw TestFailure("expected the uncertified device's prompt")
        }
        #expect(uncertified.fields.map(\.key) == ["trust"])
        #expect(uncertified.message.contains("not come from a manufacturer in the Matter registry"))
        #expect(state["code"]?.stringValue == Self.pairingCode)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["trust": "add"], state: state)) else {
            throw TestFailure("expected done")
        }
        let deviceID = try #require(outcome.deviceID)
        try plugin.context.saveCredentials(try #require(outcome.credentials), for: deviceID)
        return deviceID
    }

    func recordCommands() -> @Sendable (DeviceCommand) async -> Void {
        { [commands] command in commands.withLockedValue { $0.append(command) } }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct MatterDevicesTests {
    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } }, "no accessory \(id)")
        return try #require(host.mainBridge.server.accessories.first { $0.id == id })
    }

    @Test func addsADeviceByItsPairingCodeAndFollowsWhatItReports() async throws {
        let environment = try await TestEnvironment()
        let light = try await environment.bridge.add(BridgedDeviceInfo(id: "lamp", name: "Desk lamp"), kind: .dimmableLight,
                                                     handler: environment.recordCommands())
        let door = try await environment.bridge.add(BridgedDeviceInfo(id: "door", name: "Front door"), kind: .contactSensor, battery: true)
        let button = try await environment.bridge.add(BridgedDeviceInfo(id: "button", name: "Button"), kind: .genericSwitch)

        var host = try await environment.start()
        let deviceID = try await environment.addNode(host)
        #expect(deviceID.count == 16)
        #expect(await environment.node.fabrics.count == 1)
        // The person knows Homeswift by its fabric's label in their other apps (Core §5.5, step 13).
        #expect(await environment.node.fabrics.all.first?.label == "Homeswift")
        // The bridge reloads the plugin once Setup is done.
        await host.stop()
        host = try await environment.start()

        let lamp = try await accessory(host, "MatterDevices:\(deviceID):\(light.endpoint)")
        #expect(lamp.name == "Desk lamp")
        let bulb = try #require(lamp.services.first { $0.type == .lightbulb })
        #expect(bulb[.brightness] != nil)

        // Reports reach HomeKit.
        await light.update(.on(true))
        await light.update(.level(127))
        #expect(await eventually { bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 50 })
        let sensor = try await accessory(host, "MatterDevices:\(deviceID):\(door.endpoint)")
        await door.update(.contact(false))
        #expect(await eventually { sensor.services.first { $0.type == .contactSensor }?[.contactSensorState]?.value.intValue == 1 })
        #expect(sensor.services.contains { $0.type == .battery })

        // HomeKit's writes reach the device.
        try await bulb.characteristic(.on).write(.bool(false))
        try await bulb.characteristic(.brightness).write(.int(100))
        #expect(await eventually { environment.commands.withLockedValue { $0 }.contains(.setOn(false)) })
        #expect(await eventually { environment.commands.withLockedValue { $0 }.contains(.setLevel(254)) })

        // A double press is a double press in HomeKit, once subscribed.
        let remote = try await accessory(host, "MatterDevices:\(deviceID):\(button.endpoint)")
        #expect(await eventually { await environment.plugin?.nodes[deviceID]?.link.status == .connected })
        let event = try #require(remote.services.first { $0.type == .statelessProgrammableSwitch }?[.programmableSwitchEvent])
        await button.press(.double)
        #expect(await eventually { event.value.intValue == HAPConstants.ProgrammableSwitchEvent.doublePress })
        await button.press(.long)
        #expect(await eventually { event.value.intValue == HAPConstants.ProgrammableSwitchEvent.longPress })

        // The page lists it, connected.
        let answer = try await #require(environment.plugin).handleWebRequest(PluginWebRequest(method: "GET", path: "nodes", query: [:], body: .null, user: "test"))
        let listed = try #require(answer.json["nodes"]?.arrayValue?.first)
        #expect(listed["device"]?.stringValue == deviceID && listed["status"]?.stringValue == "connected")
        await host.stop()
    }

    /// A remote of the BILRESA's shape behind the node (a wheel channel: two rotary parts and a button) dims a light of
    /// the bridge, a step per notch as the turn's running count comes in, and its button toggles it.
    @Test func aWheelDimsTheLightItsChannelIsSetTo() async throws {
        let environment = try await TestEnvironment()
        let lamp = try await environment.bridge.add(BridgedDeviceInfo(id: "lamp", name: "Desk lamp"), kind: .dimmableLight,
                                                    handler: environment.recordCommands())
        let wheel = try await environment.bridge.add(BridgedDeviceInfo(id: "wheel", name: "Wheel"), parts: [
            DevicePart(Self.switchKind(features: 22, multiPressMax: 18)), DevicePart(Self.switchKind(features: 22, multiPressMax: 18)),
            DevicePart(Self.switchKind(features: 30, multiPressMax: 3)),
        ])
        var host = try await environment.start()
        let deviceID = try await environment.addNode(host)
        await host.stop()
        let lampID = "MatterDevices:\(deviceID):\(lamp.endpoint)"
        host = try await environment.start(settings: ["_accessories": [deviceID: ["light1": lampID, "dimStep": 10, "double1": "evening", "long1": "night"]]])
        // The home's scenes, as the catalog lends them: what the button's double and long presses run.
        let ran = NIOLockedValueBox<[String]>([])
        host.homeScenes = HomeScenes(list: { [HomeScene(id: "evening", name: "Evening"), HomeScene(id: "night", name: "Night")] },
                                     run: { id in ran.withLockedValue { $0.append(id) } })
        let bulb = try #require(try await accessory(host, lampID).services.first { $0.type == .lightbulb })
        #expect(await eventually { await environment.plugin?.nodes[deviceID]?.channels.count == 1 })
        // Subscribed: what the remote sends from now on is acted on (what came before is the priming report's, listed only).
        #expect(await eventually { await environment.plugin?.nodes[deviceID]?.link.status == .connected })

        typealias E = SwitchCluster.Event
        let count = { (value: UInt64) in TLVValue.structure([.field(0, .unsigned(1)), .field(1, .unsigned(value))]) }
        let position = TLVValue.structure([.field(0, .unsigned(1))])
        // First notch: the light, off, comes on at one step.
        await wheel.emit(E.initialPress, data: position, cluster: SwitchCluster.id, part: 0)
        await wheel.emit(E.shortRelease, data: position, cluster: SwitchCluster.id, part: 0)
        #expect(await eventually { bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 10 })
        // Three more notches counted while turning: 40 %.
        await wheel.emit(E.multiPressOngoing, data: count(4), cluster: SwitchCluster.id, part: 0)
        #expect(await eventually { bulb[.brightness]?.value.intValue == 40 })
        #expect(await eventually { environment.commands.withLockedValue { $0 }.contains(.setLevel(LevelControlCluster.level(percent: 40))) })
        await wheel.emit(E.multiPressComplete, data: count(4), cluster: SwitchCluster.id, part: 0)
        // Down two notches.
        await wheel.emit(E.initialPress, data: position, cluster: SwitchCluster.id, part: 1)
        await wheel.emit(E.multiPressComplete, data: count(2), cluster: SwitchCluster.id, part: 1)
        #expect(await eventually { bulb[.brightness]?.value.intValue == 20 })
        // The button toggles it off.
        await wheel.press(.single, part: 2)
        #expect(await eventually { bulb[.on]?.value.boolValue == false })
        // Its double press runs Evening, its long press Night.
        await wheel.press(.double, part: 2)
        #expect(await eventually { ran.withLockedValue { $0 } == ["evening"] })
        await wheel.press(.long, part: 2)
        #expect(await eventually { ran.withLockedValue { $0 } == ["evening", "night"] })
        // The settings offer the home's scenes for them.
        let choices = await environment.plugin?.accessorySettingChoices("double1", deviceID: deviceID)
        #expect(choices?.map(\.label) == ["Evening", "Night"] && choices?.first?.group == "Scenes")
        await host.stop()
    }

    /// A Switch part with these features (Application Clusters §1.13.4).
    static func switchKind(features: UInt32, multiPressMax: UInt64) -> DeviceKind {
        DeviceKind(deviceTypes: [DeviceTypes.genericSwitch]) { _ in
            [AttributeCluster(SwitchCluster.definition, featureMap: features, attributes: [
                SwitchCluster.Attribute.numberOfPositions: .unsigned(2), SwitchCluster.Attribute.currentPosition: .unsigned(0),
                SwitchCluster.Attribute.multiPressMax: .unsigned(multiPressMax),
            ])]
        }
    }

    @Test func forgettingADeviceTakesHomeswiftOffIt() async throws {
        let environment = try await TestEnvironment()
        _ = try await environment.bridge.add(BridgedDeviceInfo(id: "lamp", name: "Desk lamp"), kind: .onOffLight, handler: environment.recordCommands())
        var host = try await environment.start()
        let deviceID = try await environment.addNode(host)
        #expect(await environment.node.fabrics.count == 1)
        // Forget drops its credentials; the plugin, reloaded, removes its fabric from the node and its record.
        let plugin = try #require(environment.plugin)
        plugin.context.removeCredentials(for: deviceID)
        await host.stop()
        host = try await environment.start()
        #expect(await eventually { await environment.node.fabrics.count == 0 })
        let reloaded = try #require(environment.plugin)
        #expect(await eventually { await reloaded.records()[deviceID] == nil })
        await host.stop()
    }

    @Test func addsACertifiedDeviceWithoutAsking() async throws {
        // Against the test PKI, swift-matter's node is attested: added at once.
        let environment = try await TestEnvironment(trustStore: .test)
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["code": TestEnvironment.pairingCode])) else {
            throw TestFailure("expected done")
        }
        #expect(outcome.deviceID?.count == 16)
        #expect(await environment.node.fabrics.count == 1)
        await host.stop()
    }

    @Test func addsNoUncertifiedDeviceThePersonDeclines() async throws {
        let environment = try await TestEnvironment()
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        guard case .ask(_, let state) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["code": TestEnvironment.pairingCode])) else {
            throw TestFailure("expected the uncertified device's prompt")
        }
        await #expect(throws: SetupError("The device was not added.")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["trust": "cancel"], state: state))
        }
        #expect(await environment.node.fabrics.count == 0)
        await host.stop()
    }

    @Test func refusesACodeNoWindowMatches() async throws {
        let environment = try await TestEnvironment()
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["code": "not a code"]))
        }
        environment.discovery.windowOpen.withLockedValue { $0 = false }
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["code": TestEnvironment.pairingCode]))
        }
        #expect(await environment.node.fabrics.count == 0)
        await host.stop()
    }
}

/// The remote BILRESA scroll wheel as the probe read it (2026-11-08): three channels, each two rotary endpoints and a
/// button, a battery on the root endpoint.
let bilresa: NodeStructure = {
    let rotary = UInt32(22), button = UInt32(30)  // Switch features: momentary, release, multi-press; buttons add long press
    // Power Source FeatureMap 10: a replaceable battery (BAT and REPLC), as the probe read it.
    var endpoints = [NodeStructure.Endpoint(id: 0, deviceTypes: [0x0016, 0x0011], clusters: [0x001D, 0x0028, 0x002F], parts: Array(1...9), powerFeatures: 10)]
    for id in UInt16(1)...9 {
        let isButton = id % 3 == 0
        endpoints.append(NodeStructure.Endpoint(id: id, deviceTypes: [DeviceTypes.genericSwitch.id], clusters: [0x001D, 0x0003, SwitchCluster.id],
                                                parts: [], switchFeatures: isButton ? button : rotary, multiPressMax: isButton ? 3 : 18))
    }
    return NodeStructure(endpoints: endpoints, vendorName: "IKEA of Sweden", productName: "BILRESA scroll wheel")
}()

struct MatterRemoteTests {
    @Test func aScrollWheelIsARemoteWithButtonsChannelsAndABattery() {
        let plan = MatterAccessories.plan(bilresa, accessoryID: "MatterDevices:0123", serialNumber: "0123") { _, _, _, _ in }
        #expect(plan.deviceKind == "remote")
        #expect(plan.accessories.count == 1)
        let services = plan.accessories[0].services
        #expect(services.filter { $0.type == .statelessProgrammableSwitch }.count == 9)
        #expect(services.contains { $0.type == .battery } && services.contains { $0.type == .serviceLabel })
        #expect(services.first { $0.isPrimary }?.type == .statelessProgrammableSwitch)
        #expect(plan.accessories[0].category == .programmableSwitch)
        // The Home app's list says which is which: each part by its channel and role, in channel order.
        let names = services.filter { $0.type == .statelessProgrammableSwitch }.map { $0[.configuredName]?.value.stringValue ?? "" }
        #expect(names == (1...3).flatMap { ["Channel \($0) up", "Channel \($0) down", "Channel \($0) button"] })
        // A turn is one single press; a button has single, double and long.
        #expect(MatterAccessories.buttonEvents(bilresa.endpoint(1)!) == [0])
        #expect(MatterAccessories.buttonEvents(bilresa.endpoint(3)!) == [0, 1, 2])
        #expect(WheelChannel.channels(bilresa) == [
            WheelChannel(number: 1, up: 1, down: 2, press: 3), WheelChannel(number: 2, up: 4, down: 5, press: 6),
            WheelChannel(number: 3, up: 7, down: 8, press: 9),
        ])
        // Its settings: a light for each of its three channels, no fourth.
        #expect(DimmerSettings.keys(channels: WheelChannel.channels(bilresa).count)
            == ["light1", "light2", "light3", "power1", "power2", "power3", "double1", "double2", "double3", "long1", "long2", "long3", "hold1", "hold2", "hold3",
                "dimStep", "reverseWheel", "powerDelay"])
        #expect(DimmerSettings.keys(channels: 0).isEmpty)
        // Its battery and its first button's events are subscribed.
        #expect(plan.attributes.contains(ConcreteAttribute(0, PowerSourceCluster.id, PowerSourceCluster.Attribute.batPercentRemaining)))
    }

    @Test func mapsSwitchEventsToHomeKitPresses() {
        let wheel = bilresa.endpoint(1)!, button = bilresa.endpoint(3)!
        let complete = { (count: UInt64) in TLVValue.structure([.field(0, .unsigned(1)), .field(1, .unsigned(count))]) }
        typealias E = SwitchCluster.Event
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(1), endpoint: button) == 0)
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(2), endpoint: button) == 1)
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(3), endpoint: button) == nil)
        #expect(MatterAccessories.buttonEvent(E.longPress, data: .null, endpoint: button) == 2)
        #expect(MatterAccessories.buttonEvent(E.shortRelease, data: .null, endpoint: button) == nil)
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(9), endpoint: wheel) == 0)
        #expect(MatterAccessories.buttonEvent(E.multiPressOngoing, data: complete(4), endpoint: wheel) == nil)
        // A count of 0 is an aborted sequence, beyond MultiPressMax (Application Clusters §1.13.6.7): no press.
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(0), endpoint: wheel) == nil)
        #expect(MatterAccessories.buttonEvent(E.multiPressComplete, data: complete(0), endpoint: button) == nil)
        // A sleepy node's reports get the time its retransmissions take: about 14 idle intervals.
        let sleepy = SessionParameters(idleInterval: .milliseconds(9500), activeInterval: .milliseconds(2100), activeThreshold: .seconds(5))
        #expect(MatterNodeLink.deliveryTime(sleepy) > .seconds(100) && MatterNodeLink.deliveryTime(sleepy) < .seconds(140))
    }

    /// The turn the probe recorded: a slow turn up of nine notches, reported as a running count about twice a second.
    @Test func aTurnMovesTheLightByEachNewNotch() {
        var gestures = WheelGestures()
        let channel = WheelChannel(number: 1, up: 1, down: 2, press: 3)
        typealias E = SwitchCluster.Event
        let ongoing = { (count: UInt64) in TLVValue.structure([.field(0, .unsigned(1)), .field(1, .unsigned(count))]) }
        let position = TLVValue.structure([.field(0, .unsigned(1))])
        let sequence: [(EventID, TLVValue)] = [
            (E.initialPress, position), (E.shortRelease, position),
            (E.initialPress, position), (E.multiPressOngoing, ongoing(4)), (E.shortRelease, position),
            (E.initialPress, position), (E.multiPressOngoing, ongoing(8)), (E.shortRelease, position),
            (E.initialPress, position), (E.multiPressOngoing, ongoing(9)), (E.shortRelease, position),
            (E.multiPressComplete, ongoing(9)),
        ]
        let actions = sequence.compactMap { gestures.handle($0.0, data: $0.1, endpoint: 1, channel: channel, reversed: false) }
        #expect(actions == [.step(1), .step(3), .step(4), .step(1)])
        // Down, reversed: the same notches the other way.
        let down = [(E.initialPress, position), (E.multiPressOngoing, ongoing(9)), (E.multiPressComplete, ongoing(10))]
            .compactMap { gestures.handle($0.0, data: $0.1, endpoint: 2, channel: channel, reversed: true) }
        #expect(down == [.step(9), .step(1)])
        // The button toggles on a single press only, as `MatterAccessories.buttonEvent` reads its events.
        let single = HAPConstants.ProgrammableSwitchEvent.singlePress, double = HAPConstants.ProgrammableSwitchEvent.doublePress
        #expect(gestures.handle(E.multiPressComplete, data: ongoing(1), endpoint: 3, channel: channel, reversed: false, press: single) == .toggle)
        #expect(gestures.handle(E.multiPressComplete, data: ongoing(2), endpoint: 3, channel: channel, reversed: false, press: double) == nil)
        #expect(gestures.handle(E.initialPress, data: position, endpoint: 3, channel: channel, reversed: false) == nil)
    }

    /// A turn whose MultiPressComplete was lost (the subscription went down) does not hold the next turn back.
    @Test func aNewTurnCountsAfterALostEnd() {
        var gestures = WheelGestures()
        let channel = WheelChannel(number: 1, up: 1, down: 2, press: 3)
        typealias E = SwitchCluster.Event
        let count = { (value: UInt64) in TLVValue.structure([.field(0, .unsigned(1)), .field(1, .unsigned(value))]) }
        let first = [(E.initialPress, count(0)), (E.multiPressOngoing, count(9))]
            .compactMap { gestures.handle($0.0, data: $0.1, endpoint: 1, channel: channel, reversed: false) }
        #expect(first == [.step(9)])
        let next = [(E.initialPress, count(0)), (E.multiPressOngoing, count(3)), (E.multiPressOngoing, count(6)), (E.multiPressComplete, count(6))]
            .compactMap { gestures.handle($0.0, data: $0.1, endpoint: 1, channel: channel, reversed: false) }
        #expect(next == [.step(3), .step(3)])
    }

    @Test func aWiredPowerSourceIsNoBattery() {
        var structure = bilresa
        structure.endpoints[0].powerFeatures = 1
        let plan = MatterAccessories.plan(structure, accessoryID: "MatterDevices:0123", serialNumber: "0123") { _, _, _, _ in }
        #expect(!plan.accessories[0].services.contains { $0.type == .battery })
    }

    @Test func dimsWithinTheLightsRange() {
        #expect(DimmerWriter.target(current: 50, change: 10, isOn: true) == 60)
        #expect(DimmerWriter.target(current: 95, change: 10, isOn: true) == 100)
        #expect(DimmerWriter.target(current: 30, change: -50, isOn: true) == 1)
        #expect(DimmerWriter.target(current: 1, change: -5, isOn: true) == 0)
        #expect(DimmerWriter.target(current: 80, change: 15, isOn: false) == 15)
        #expect(DimmerWriter.target(current: 80, change: -5, isOn: false) == 0)
    }

    @Test func writesTheLightThroughItsCharacteristics() async throws {
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(true)
        bulb[.brightness]?.value = .int(40)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.step(3), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.step(-20), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 1 && bulb[.on]?.value.boolValue == true)
        await writer.apply(.step(-1), step: 5)
        #expect(bulb[.on]?.value.boolValue == false)
        // The button turns it back on at the level it had before the wheel took it to the floor, not at 1 %.
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == false && bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 55)
    }

    @Test func stepsFromWhatItSetNotFromALateReport() async throws {
        // Govee's cloud reports a level from before the last writes, late: the next notch steps from what the wheel set.
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(true)
        bulb[.brightness]?.value = .int(40)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.step(1), step: 5)
        bulb[.brightness]?.value = .int(20)   // the late report
        await writer.apply(.step(1), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 50)
        // Once the moment has passed, the light's own value counts again (another app may have changed it).
        let later = DimmerWriter(lightID: lamp.id, trustLastSet: .zero) { $0 == lamp.id ? lamp : nil }
        await later.apply(.step(1), step: 5)
        bulb[.brightness]?.value = .int(20)
        await later.apply(.step(1), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 25)
    }

    static func lamp(_ id: String, on: Bool, level: Int) -> Accessory {
        let bulb = Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(on)
        bulb[.brightness]?.value = .int(level)
        return Accessory(id: id, name: id, category: .lightbulb, services: [bulb])
    }

    static func bulb(_ accessory: Accessory) -> Service { accessory.services.first { $0.type == .lightbulb }! }

    static func channel(_ accessories: [Accessory], power: [String] = []) -> ChannelDimmer {
        let byID = Dictionary(uniqueKeysWithValues: accessories.map { ($0.id, $0) })
        let find: @Sendable (String) -> Accessory? = { byID[$0] }
        let lights = accessories.filter { [.lightbulb, .windowCovering].contains($0.category) }.map(\.id)
        return ChannelDimmer(targets: ChannelTargets(lights: lights, power: power, powerDelay: .milliseconds(20)),
                             writers: lights.map { DimmerWriter(lightID: $0, find: find) }, find: find)
    }

    @Test func aChannelDimsItsLightsTogetherAndSwitchesThemTheSameWay() async throws {
        let a = Self.lamp("A", on: true, level: 40), b = Self.lamp("B", on: false, level: 70)
        let channel = Self.channel([a, b])
        await channel.apply(.step(2), step: 5)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 50)
        #expect(Self.bulb(b)[.on]?.value.boolValue == true && Self.bulb(b)[.brightness]?.value.intValue == 10)
        // Both on: the button switches both off; then both on.
        await channel.apply(.toggle, step: 5)
        #expect(Self.bulb(a)[.on]?.value.boolValue == false && Self.bulb(b)[.on]?.value.boolValue == false)
        await channel.apply(.toggle, step: 5)
        #expect(Self.bulb(a)[.on]?.value.boolValue == true && Self.bulb(b)[.on]?.value.boolValue == true)
    }

    @Test func aChannelSwitchesThePowerOfItsLights() async throws {
        let relay = Service(.switch, name: "Relay", isPrimary: true)
        relay.characteristic(.on).value = .bool(false)
        let power = Accessory(id: "EWeLink:relay", name: "Relay", category: .switch, services: [relay])
        // A second relay, an outlet, switched with it.
        let socket = Service(.outlet, name: "Socket", isPrimary: true)
        socket.characteristic(.on).value = .bool(false)
        let second = Accessory(id: "EWeLink:socket", name: "Socket", category: .outlet, services: [socket])
        let a = Self.lamp("A", on: true, level: 30), b = Self.lamp("B", on: true, level: 30)
        let channel = Self.channel([power, second, a, b], power: [power.id, second.id])
        // Turning up with the power off: on first, then, once the lights are back, the notches.
        await channel.apply(.step(2), step: 5)
        #expect(relay[.on]?.value.boolValue == true && socket[.on]?.value.boolValue == true)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 40 && Self.bulb(b)[.on]?.value.boolValue == true)
        // Down past the floor: the power goes off, the lights stay on (they come back with it).
        await channel.apply(.step(-20), step: 5)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 1 && relay[.on]?.value.boolValue == true)
        await channel.apply(.step(-1), step: 5)
        #expect(relay[.on]?.value.boolValue == false && socket[.on]?.value.boolValue == false && Self.bulb(a)[.on]?.value.boolValue == true)
        // Turning down with the power off does nothing; the button switches it on, the lights back at their level.
        await channel.apply(.step(-1), step: 5)
        #expect(relay[.on]?.value.boolValue == false)
        await channel.apply(.toggle, step: 5)
        #expect(relay[.on]?.value.boolValue == true && Self.bulb(a)[.brightness]?.value.intValue == 40)
        await channel.apply(.toggle, step: 5)
        #expect(relay[.on]?.value.boolValue == false)
    }

    /// A shutter on a channel: a notch moves its Target Position a step from where the wheel last sent it; the button
    /// stops it while it moves, else opens it, or closes it when more than half open.
    @Test func aChannelMovesItsShuttersPrecisely() async throws {
        let covering = Service(.windowCovering, name: "Shutter", optional: [.holdPosition], isPrimary: true)
        covering[.targetPosition]?.value = .int(40)
        covering[.currentPosition]?.value = .int(40)
        covering[.positionState]?.value = .int(2)
        let shutter = Accessory(id: "Somfy:1", name: "Shutter", category: .windowCovering, services: [covering])
        let channel = Self.channel([shutter])
        await channel.apply(.step(3), step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 55)
        await channel.apply(.step(-20), step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 0)
        // Still, closed: the button opens it; moving, it stops.
        await channel.apply(.toggle, step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 100)
        covering[.positionState]?.value = .int(1)
        await channel.apply(.toggle, step: 5)
        #expect(covering[.holdPosition]?.value.boolValue == true && covering[.targetPosition]?.value.intValue == 100)
    }

    /// A held button dims a step at a time until it is let go: up or down as set, or each hold the other way.
    @Test func aHeldButtonDimsUntilLetGo() async throws {
        let lamp = Self.lamp("A", on: true, level: 30)
        let channel = Self.channel([lamp])
        let level: @Sendable () -> Int = { Self.bulb(lamp)[.brightness]?.value.intValue ?? 0 }
        await channel.hold(step: 5, direction: .up)
        #expect(await eventually { level() >= 40 })
        await channel.release()
        let stopped = level()
        try await Task.sleep(for: .milliseconds(700))
        #expect(level() == stopped)
        await channel.hold(step: 5, direction: .down)
        #expect(await eventually { level() < stopped })
        await channel.release()
        // Alternating: the hold after a hold goes the other way (the last was down: up now), however long after.
        let before = level()
        await channel.hold(step: 5, direction: .alternate)
        #expect(await eventually { level() > before })
        await channel.release()
        // Never against a limit: at full, the next hold dims although the last one brightened.
        try await Task.sleep(for: .seconds(3.1))   // past the writer's trust in its own last level
        Self.bulb(lamp)[.brightness]?.value = .int(100)
        await channel.hold(step: 5, direction: .alternate)
        #expect(await eventually { level() < 100 })
        await channel.release()
    }

    @Test func turnsOnAtFullALightLeftAtTheFloor() async throws {
        // Dimmed to 1 % by something else: the writer knows no level before, so full.
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(false)
        bulb[.brightness]?.value = .int(1)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 100)
    }

    @Test func readsAStructureWithAListSentAsAppends() {
        let descriptor = DescriptorCluster.self
        let reports: [AttributeReport] = [
            .data(path: AttributePath(endpoint: 0, cluster: BasicInformationCluster.id, attribute: BasicInformationCluster.Attribute.productName),
                  dataVersion: 1, value: .utf8("BILRESA scroll wheel")),
            .data(path: AttributePath(endpoint: 1, cluster: descriptor.id, attribute: descriptor.Attribute.serverList), dataVersion: 1, value: .array([])),
            .data(path: AttributePath(endpoint: 1, cluster: descriptor.id, attribute: descriptor.Attribute.serverList, listIndex: .append),
                  dataVersion: 1, value: .unsigned(UInt64(SwitchCluster.id))),
            .data(path: AttributePath(endpoint: 1, cluster: descriptor.id, attribute: descriptor.Attribute.deviceTypeList), dataVersion: 1,
                  value: .array([TLVElement(.structure([.field(0, .unsigned(15)), .field(1, .unsigned(3))]))])),
            // A value of the wrong type is left out.
            .data(path: AttributePath(endpoint: 0, cluster: BasicInformationCluster.id, attribute: BasicInformationCluster.Attribute.vendorId),
                  dataVersion: 1, value: .utf8("4476")),
        ]
        let structure = NodeStructure(reports: reports)
        #expect(structure.name == "BILRESA scroll wheel")
        #expect(structure.vendorID == nil)
        #expect(structure.endpoint(1)?.clusters == [SwitchCluster.id])
        #expect(structure.endpoint(1)?.deviceTypes == [15])
    }
}
