import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftZWaveJS

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// zwave-js-server in memory: each connection is a `FakeWebSocket` that says the version first, answers
/// `set_api_schema`, `start_listening` (the state of Fixtures/start_listening.json) and `node.set_value`, and takes
/// the events a test sends.
final class FakeServer: Sendable {
    static let homeID = "3967423180"
    static let fixture: JSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/start_listening.json")
        return try! JSONValue(data: Data(contentsOf: url))
    }()

    private struct State {
        var sockets: [FakeWebSocket] = []
        var urls: [URL] = []
        var commands: [JSONValue] = []
        var reachable = true
        var nodes: [JSONValue] = (FakeServer.fixture["state"]?["nodes"]?.arrayValue) ?? []
        var setValueStatus: Int = 255
    }

    private let state = NIOLockedValueBox(State())

    var socket: FakeWebSocket? { state.withLockedValue { $0.sockets.last } }
    var connections: Int { state.withLockedValue { $0.sockets.count } }
    var urls: [URL] { state.withLockedValue { $0.urls } }
    /// Every command received, in order.
    var commands: [JSONValue] { state.withLockedValue { $0.commands } }
    var setValues: [JSONValue] { commands.filter { $0["command"] == "node.set_value" } }

    func set(reachable: Bool) { state.withLockedValue { $0.reachable = reachable } }
    func set(setValueStatus: Int) { state.withLockedValue { $0.setValueStatus = setValueStatus } }
    /// The nodes the next `start_listening` gives.
    func removeNode(_ nodeID: Int) { state.withLockedValue { $0.nodes.removeAll { $0["nodeId"]?.intValue == nodeID } } }
    /// A node of the next `start_listening` in place of the one with its id.
    func replace(node: JSONValue) {
        state.withLockedValue { state in
            if let index = state.nodes.firstIndex(where: { $0["nodeId"] == node["nodeId"] }) { state.nodes[index] = node }
        }
    }

    func connect(_ url: URL) async throws -> any WebSocketConnection {
        let socket = FakeWebSocket(url: url)
        try state.withLockedValue { state in
            guard state.reachable else { throw WebSocketError.connectionLost }
            state.sockets.append(socket)
            state.urls.append(url)
        }
        socket.onSend { [weak self, weak socket] message in
            guard let self, let socket, let text = message.text, let json = try? JSONValue(string: text) else { return }
            self.answer(json, on: socket)
        }
        socket.receive(text: (Self.fixture["version"] ?? .null).text())
        return socket
    }

    private func answer(_ command: JSONValue, on socket: FakeWebSocket) {
        let (nodes, status) = state.withLockedValue { state in
            state.commands.append(command)
            return (state.nodes, state.setValueStatus)
        }
        let id = command["messageId"] ?? .null
        let result: JSONValue
        switch command["command"]?.stringValue {
        case "set_api_schema":
            result = .object([:])
        case "start_listening":
            var dump = Self.fixture["state"]?.objectValue ?? [:]
            dump["nodes"] = .array(nodes)
            result = .object(["state": .object(dump)])
        case "node.set_value":
            result = .object(["result": .object(["status": .number(Double(status))])])
        default:
            socket.receive(text: JSONValue.object(["type": "result", "messageId": id, "success": false, "errorCode": "unknown_command"]).text())
            return
        }
        socket.receive(text: JSONValue.object(["type": "result", "messageId": id, "success": true, "result": result]).text())
    }

    /// An event as the server sends it.
    func send(event: JSONValue) {
        socket?.receive(text: JSONValue.object(["type": "event", "event": event]).text())
    }

    func valueUpdated(node: Int, commandClass: Int, endpoint: Int = 0, property: JSONValue, propertyKey: JSONValue? = nil, value: JSONValue) {
        var args: [String: JSONValue] = [
            "commandClass": .number(Double(commandClass)), "endpoint": .number(Double(endpoint)), "property": property, "newValue": value, "prevValue": .null,
        ]
        if let propertyKey { args["propertyKey"] = propertyKey }
        send(event: ["source": "node", "event": "value updated", "nodeId": .number(Double(node)), "args": .object(args)])
    }
}

/// A host with one platform block whose plugin talks to `server`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-ZWaveJS-tests-\(UUID().uuidString)")
    let server = FakeServer()
    let announcements = NIOLockedValueBox<[ServerAnnouncement]>([])
    private let plugins = NIOLockedValueBox<[ZWaveJSPlugin]>([])

    var plugin: ZWaveJSPlugin? { plugins.withLockedValue { $0.last } }

    static var serverSettings: [String: Any] { ["_accessories": [FakeServer.homeID: ["host": "192.0.2.20"]]] }

    var dependencies: ZWaveJSPlugin.Dependencies {
        let server = self.server, announcements = self.announcements
        var dependencies = ZWaveJSPlugin.Dependencies()
        dependencies.connect = { try await server.connect($0) }
        dependencies.browse = { _, _ in announcements.withLockedValue { $0 } }
        dependencies.setupDiscoveryWindow = .zero
        dependencies.requestTimeout = .seconds(5)
        dependencies.backoff = Backoff(initial: .milliseconds(20), maximum: .milliseconds(50))
        dependencies.coalesceDelay = .milliseconds(1)
        return dependencies
    }

    func start(settings: [String: Any] = TestEnvironment.serverSettings) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = self.dependencies
        registry.register(platform: ZWaveJSPlugin.platform, name: ZWaveJSPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(ZWaveJSPlugin.Configuration.self, from: json)
            let plugin = ZWaveJSPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: ZWaveJSPlugin.platform, name: ZWaveJSPlugin.name, settings: settings)
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

extension Accessory {
    func service(_ type: ServiceType, subtype: String) -> Service? { services.first { $0.type.uuid == type.uuid && $0.subtype == subtype } }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func id(_ node: Int) -> String { ZWaveJSPlugin.accessoryID(deviceID: "\(FakeServer.homeID)-\(node)") }

@Suite(.timeLimit(.minutes(1)))
struct ZWaveJSTests {
    let environment = TestEnvironment()

    func started() async throws -> PluginHost {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(id(10)) != nil })
        return host
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(ZWaveJSPlugin.Configuration.self, from: Data(#"{"platform":"ZWaveJS"}"#.utf8))
        #expect(configuration.name == nil)
    }

    @Test func withoutAServerNothingConnects() async throws {
        let host = try await environment.start(settings: [:])
        _ = try #require(environment.plugin)
        #expect(environment.server.connections == 0)
        await host.stop()
    }

    @Test func theSessionPicksASchemaAndListens() async throws {
        let host = try await started()
        #expect(environment.server.urls.first == URL(string: "ws://192.0.2.20:3000"))
        let commands = environment.server.commands.compactMap { $0["command"]?.stringValue }
        #expect(Array(commands.prefix(2)) == ["set_api_schema", "start_listening"])
        #expect(environment.server.commands.first?["schemaVersion"] == 35)
        await host.stop()
    }

    @Test func eachNodeBecomesAnAccessory() async throws {
        let host = try await started()
        // The controller's own node is not an accessory.
        #expect(host.accessory(id(1)) == nil)

        let bulb = try #require(host.accessory(id(2)))
        #expect(bulb.category == .lightbulb)
        #expect(bulb.information.characteristic(.name).value == "Living Room Bulb")
        #expect(bulb.information.characteristic(.manufacturer).value == "Aeotec")
        #expect(bulb.information.characteristic(.model).value == "ZWA002")
        #expect(bulb.information.characteristic(.serialNumber).value == "0123456789ABCDEF")
        let light = try #require(bulb.service(.lightbulb, subtype: "0"))
        #expect(light.isPrimary)
        #expect(light[.on]?.value == true && light[.brightness]?.value == 100)
        #expect(light[.hue]?.value == .double(0) && light[.saturation]?.value == .double(100))

        let plug = try #require(host.accessory(id(3)))
        #expect(plug.category == .outlet)
        // No serial of its own: its Device Id.
        #expect(plug.information.characteristic(.serialNumber).value == .string("\(FakeServer.homeID)-3"))
        let outlet = try #require(plug.service(.outlet, subtype: "0"))
        #expect(outlet[.on]?.value == false)
        #expect(outlet[EveCharacteristic.totalConsumption]?.value == .double(12.5))
        #expect(outlet[EveCharacteristic.currentConsumption]?.value.doubleValue == 0)

        let sensor = try #require(host.accessory(id(4)))
        #expect(sensor.category == .sensor)
        #expect(sensor.service(.motionSensor, subtype: "0:motion")?[.motionDetected]?.value == false)
        // 71.6 °F
        #expect(sensor.service(.temperatureSensor, subtype: "0:temperature")?[.currentTemperature]?.value.doubleValue.map { abs($0 - 22) < 0.01 } == true)
        #expect(sensor.service(.humiditySensor, subtype: "0:humidity")?[.currentRelativeHumidity]?.value == .double(45))
        #expect(sensor.service(.lightSensor, subtype: "0:light")?[.currentAmbientLightLevel]?.value == .double(120))
        let battery = try #require(sensor.service(.battery))
        #expect(battery[.batteryLevel]?.value == 87 && battery[.statusLowBattery]?.value == 0 && battery[.chargingState]?.value == 2)

        let lock = try #require(host.accessory(id(5)))
        #expect(lock.category == .doorLock)
        let mechanism = try #require(lock.service(.lockMechanism, subtype: "0"))
        #expect(mechanism[.lockCurrentState]?.value == 1 && mechanism[.lockTargetState]?.value == 1)

        let thermostat = try #require(host.accessory(id(6))?.service(.thermostat, subtype: "0:thermostat"))
        #expect(thermostat.isPrimary)
        #expect(thermostat[.targetHeatingCoolingState]?.value == 1)
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1, 2])
        #expect(thermostat[.targetTemperature]?.value == .double(21))
        #expect(thermostat[.currentTemperature]?.value == .double(19.5))
        #expect(thermostat[.currentHeatingCoolingState]?.value == 1)
        // The thermostat took the air temperature: no sensor of its own.
        #expect(host.accessory(id(6))?.service(.temperatureSensor) == nil)

        let door = try #require(host.accessory(id(7)))
        // Notification's Door state wins over Binary Sensor's: one contact sensor, closed.
        #expect(door.services.filter { $0.type.uuid == ServiceType.contactSensor.uuid }.count == 1)
        #expect(door.service(.contactSensor)?[.contactSensorState]?.value == 0)
        #expect(door.information.characteristic(.name).value == "Door / Window Sensor Gen5")

        let remote = try #require(host.accessory(id(8)))
        #expect(remote.category == .programmableSwitch)
        let buttons = remote.services.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }
        #expect(buttons.map { $0[.serviceLabelIndex]?.value } == [1, 2])
        #expect(buttons.first?[.programmableSwitchEvent]?.type.validValues == [0, 2])
        #expect(remote.service(.serviceLabel)?[.serviceLabelNamespace]?.value == 1)

        let blind = try #require(host.accessory(id(9)))
        #expect(blind.category == .windowCovering)
        #expect(blind.service(.windowCovering, subtype: "0")?[.currentPosition]?.value == 51)

        let leak = try #require(host.accessory(id(10)))
        #expect(leak.service(.leakSensor)?[.leakDetected]?.value == 0)
        await host.stop()
    }

    @Test func writesReachTheNode() async throws {
        let host = try await started()
        let outlet = try #require(host.accessory(id(3))?.service(.outlet, subtype: "0"))
        try await outlet[.on]!.write(.bool(true), origin: nil)
        #expect(await eventually { environment.server.setValues.count == 1 })
        let write = try #require(environment.server.setValues.last)
        #expect(write["nodeId"] == 3)
        #expect(write["valueId"] == ["commandClass": 37, "endpoint": 0, "property": "targetValue"])
        #expect(write["value"] == true)

        let light = try #require(host.accessory(id(2))?.service(.lightbulb, subtype: "0"))
        try await light[.brightness]!.write(.int(50), origin: nil)
        #expect(environment.server.setValues.last?["valueId"]?["property"] == "targetValue")
        #expect(environment.server.setValues.last?["value"] == 50)
        try await light[.hue]!.write(.double(120), origin: nil)
        #expect(environment.server.setValues.last?["valueId"]?["property"] == "targetColor")
        #expect(environment.server.setValues.last?["value"] == ["red": 0, "green": 255, "blue": 0, "warmWhite": 0, "coldWhite": 0])

        let lock = try #require(host.accessory(id(5))?.service(.lockMechanism, subtype: "0"))
        #expect(lock[.lockTargetState]?.isSecurityControl == true)
        try await lock[.lockTargetState]!.write(.int(0), origin: nil)
        #expect(environment.server.setValues.last?["valueId"] == ["commandClass": 98, "endpoint": 0, "property": "targetMode"])
        #expect(environment.server.setValues.last?["value"] == 0)

        let thermostat = try #require(host.accessory(id(6))?.service(.thermostat))
        try await thermostat[.targetTemperature]!.write(.double(22.5), origin: nil)
        #expect(environment.server.setValues.last?["valueId"] == ["commandClass": 67, "endpoint": 0, "property": "setpoint", "propertyKey": 1])
        #expect(environment.server.setValues.last?["value"] == 22.5)

        let blind = try #require(host.accessory(id(9))?.service(.windowCovering))
        try await blind[.targetPosition]!.write(.int(100), origin: nil)
        #expect(environment.server.setValues.last?["value"] == 99)

        // Cool shows, and then writes, the cooling setpoint at once, before the server echoes the mode.
        try await thermostat[.targetHeatingCoolingState]!.write(.int(2), origin: nil)
        #expect(environment.server.setValues.last?["valueId"] == ["commandClass": 64, "endpoint": 0, "property": "mode"])
        #expect(thermostat[.targetTemperature]?.value == .double(24))
        try await thermostat[.targetTemperature]!.write(.double(25), origin: nil)
        #expect(environment.server.setValues.last?["valueId"] == ["commandClass": 67, "endpoint": 0, "property": "setpoint", "propertyKey": 2])
        await host.stop()
    }

    @Test func aRefusedWriteIsACommunicationFailure() async throws {
        let host = try await started()
        environment.server.set(setValueStatus: 2)
        let outlet = try #require(host.accessory(id(3))?.service(.outlet))
        await #expect(throws: HAPStatusError.self) { try await outlet[.on]!.write(.bool(true), origin: nil) }
        await host.stop()
    }

    @Test func changesOnTheNetworkReachHomeKit() async throws {
        let host = try await started()
        let server = environment.server
        let outlet = try #require(host.accessory(id(3))?.service(.outlet))
        server.valueUpdated(node: 3, commandClass: 37, property: "currentValue", value: true)
        #expect(await eventually { outlet[.on]?.value == true })
        server.valueUpdated(node: 3, commandClass: 50, property: "value", propertyKey: 66049, value: 1200)
        #expect(await eventually { outlet[EveCharacteristic.currentConsumption]?.value.doubleValue == 1200 })

        let motion = try #require(host.accessory(id(4))?.service(.motionSensor))
        server.valueUpdated(node: 4, commandClass: 113, property: "Home Security", propertyKey: "Motion sensor status", value: 8)
        #expect(await eventually { motion[.motionDetected]?.value == true })

        let door = try #require(host.accessory(id(7))?.service(.contactSensor))
        server.valueUpdated(node: 7, commandClass: 113, property: "Access Control", propertyKey: "Door state", value: 22)
        #expect(await eventually { door[.contactSensorState]?.value == 1 })

        let light = try #require(host.accessory(id(2))?.service(.lightbulb))
        server.valueUpdated(node: 2, commandClass: 38, property: "currentValue", value: 0)
        #expect(await eventually { light[.on]?.value == false })
        #expect(light[.brightness]?.value == 100)
        server.valueUpdated(node: 2, commandClass: 51, property: "currentColor", propertyKey: 4, value: 255)
        #expect(await eventually { light[.hue]?.value == .double(300) })

        let lock = try #require(host.accessory(id(5))?.service(.lockMechanism))
        server.valueUpdated(node: 5, commandClass: 98, property: "currentMode", value: 0)
        #expect(await eventually { lock[.lockCurrentState]?.value == 0 && lock[.lockTargetState]?.value == 0 })

        let thermostat = try #require(host.accessory(id(6))?.service(.thermostat))
        server.valueUpdated(node: 6, commandClass: 64, property: "mode", value: 0)
        #expect(await eventually { thermostat[.targetHeatingCoolingState]?.value == 0 && thermostat[.currentHeatingCoolingState]?.value == 0 })
        await host.stop()
    }

    @Test func centralSceneKeysArePresses() async throws {
        let host = try await started()
        let first = try #require(host.accessory(id(8))?.service(.statelessProgrammableSwitch, subtype: "scene:0:001"))
        let second = try #require(host.accessory(id(8))?.service(.statelessProgrammableSwitch, subtype: "scene:0:002"))
        func press(_ key: String, _ attribute: Int) {
            environment.server.send(event: [
                "source": "node", "event": "value notification", "nodeId": 8,
                "args": ["commandClass": 91, "endpoint": 0, "property": "scene", "propertyKey": .string(key), "value": .number(Double(attribute))],
            ])
        }
        // Key Held Down is a long press; Key Released sends nothing.
        press("002", 2)
        #expect(await eventually { second[.programmableSwitchEvent]?.value == 2 })
        press("001", 1)
        press("001", 0)
        #expect(await eventually { first[.programmableSwitchEvent]?.value == 0 })
        #expect(NodeBuilder.pressEvent(3) == 1 && NodeBuilder.pressEvent(1) == nil)
        await host.stop()
    }

    @Test func deadNodesAnswerNoResponse() async throws {
        let host = try await started()
        // Node 10 is dead in the state dump.
        #expect(host.accessory(id(10))?.isUnavailable == true)
        #expect(host.accessory(id(3))?.isUnavailable == false)
        environment.server.send(event: ["source": "node", "event": "dead", "nodeId": 3, "args": .object([:])])
        #expect(await eventually { host.accessory(id(3))?.isUnavailable == true })
        environment.server.send(event: ["source": "node", "event": "alive", "nodeId": 3, "args": .object([:])])
        #expect(await eventually { host.accessory(id(3))?.isUnavailable == false })
        await host.stop()
    }

    @Test func aLostServerMakesEveryNodeUnavailableUntilItIsBack() async throws {
        let host = try await started()
        environment.server.set(reachable: false)
        environment.server.socket?.drop()
        #expect(await eventually { host.accessory(id(2))?.isUnavailable == true && host.accessory(id(5))?.isUnavailable == true })
        let outlet = try #require(host.accessory(id(3))?.service(.outlet))
        await #expect(throws: HAPStatusError.self) { try await outlet[.on]!.write(.bool(true), origin: nil) }
        environment.server.set(reachable: true)
        #expect(await eventually { host.accessory(id(2))?.isUnavailable == false })
        #expect(environment.server.connections == 2)
        // The dead node stays so.
        #expect(host.accessory(id(10))?.isUnavailable == true)
        await host.stop()
    }

    @Test func cachedAccessoriesAnswerNoResponseWhileTheServerIsAway() async throws {
        let first = try await started()
        await first.stop()
        environment.server.set(reachable: false)
        let host = try await environment.start()
        // Back from the cache, before any connection: No Response once the first attempt fails.
        #expect(host.accessory(id(3)) != nil)
        #expect(await eventually { host.accessory(id(3))?.isUnavailable == true && host.accessory(id(2))?.isUnavailable == true })
        environment.server.set(reachable: true)
        #expect(await eventually { host.accessory(id(3))?.isUnavailable == false })
        await host.stop()
    }

    @Test func nodesComeAndGo() async throws {
        let host = try await started()
        let server = environment.server
        server.send(event: ["source": "controller", "event": "node removed", "node": ["nodeId": 9], "reason": 0])
        #expect(await eventually { host.accessory(id(9)) == nil })

        var added = try #require(FakeServer.fixture["state"]?["nodes"]?.arrayValue?.first { $0["nodeId"] == 3 }?.objectValue)
        added["nodeId"] = 11
        added["name"] = "Fan Plug"
        added["ready"] = false
        server.send(event: ["source": "controller", "event": "node added", "node": .object(added), "result": .object([:])])
        // Events are handled in order: once the plug's change shows, the added node was handled too.
        server.valueUpdated(node: 3, commandClass: 37, property: "currentValue", value: true)
        #expect(await eventually { host.accessory(id(3))?.service(.outlet)?[.on]?.value == true })
        // Not ready: interviewed first.
        #expect(host.accessory(id(11)) == nil)
        added["ready"] = true
        server.send(event: ["source": "node", "event": "ready", "nodeId": 11, "nodeState": .object(added)])
        #expect(await eventually { host.accessory(id(11))?.information.characteristic(.name).value == "Fan Plug" })

        // An older schema's `ready` has no node state: the node as `node added` gave it.
        var older = added
        older["nodeId"] = 12
        older["name"] = "Hall Plug"
        older["ready"] = false
        server.send(event: ["source": "controller", "event": "node added", "node": .object(older), "result": .object([:])])
        server.send(event: ["source": "node", "event": "ready", "nodeId": 12, "args": .object([:])])
        #expect(await eventually { host.accessory(id(12))?.information.characteristic(.name).value == "Hall Plug" })

        // A node gone while the bridge was away leaves at the next state dump.
        server.removeNode(4)
        server.socket?.drop()
        #expect(await eventually { host.accessory(id(4)) == nil })
        #expect(host.accessory(id(2)) != nil)
        await host.stop()
    }

    @Test func aBinarySwitchShowsAsItsSettingSays() async throws {
        var settings = TestEnvironment.serverSettings
        settings["_accessories"] = [FakeServer.homeID: ["host": "192.0.2.20"], "\(FakeServer.homeID)-3": ["showAs": "lightbulb"]]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(id(3)) != nil })
        let plug = try #require(host.accessory(id(3)))
        #expect(plug.category == .lightbulb)
        #expect(plug.service(.lightbulb, subtype: "0") != nil)
        #expect(await environment.plugin?.deviceKind(of: "\(FakeServer.homeID)-3") == "light")
        await host.stop()
    }

    @Test func anExcludedNodeIsNoAccessory() async throws {
        var settings = TestEnvironment.serverSettings
        settings["_accessories"] = [FakeServer.homeID: ["host": "192.0.2.20"], "\(FakeServer.homeID)-5": ["excluded": true]]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(id(10)) != nil })
        #expect(host.accessory(id(5)) == nil)
        await host.stop()
    }

    @Test func anotherNetworkAtTheAddressIsRefused() async throws {
        let host = try await environment.start(settings: ["_accessories": ["12345": ["host": "192.0.2.20"]]])
        // Refused, then tried again later: the first attempt is over.
        #expect(await eventually { environment.server.connections >= 2 })
        #expect(!environment.server.commands.contains { $0["command"] == "start_listening" })
        #expect(host.mainBridge.server.accessories.allSatisfy { !$0.id.hasPrefix("ZWaveJS:") })
        await host.stop()
    }

    // MARK: Setup

    @Test func discoverListsTheServersAndTheNodes() async throws {
        environment.announcements.withLockedValue {
            $0 = [ServerAnnouncement(name: "zwave-js-server", host: "192.0.2.30", port: 3000, homeID: "42")]
        }
        let host = try await started()
        let found = try await host.discover(platform: ZWaveJSPlugin.platform, name: ZWaveJSPlugin.name)
        #expect(found.accountState == .none)
        let server = try #require(found.devices.first { $0.deviceID == FakeServer.homeID })
        #expect(server.kind == "server" && server.isSetUp && server.address == "192.0.2.20:3000" && server.isReachable)
        // An announcement is offered by Add by address, not listed as a device ready to use.
        #expect(!found.devices.contains { $0.deviceID == "42" })
        let bulb = try #require(found.devices.first { $0.deviceID == "\(FakeServer.homeID)-2" })
        #expect(bulb.name == "Living Room Bulb" && bulb.kind == "light" && bulb.isSetUp && bulb.model == "ZWA002")
        #expect(found.devices.first { $0.deviceID == "\(FakeServer.homeID)-10" }?.isReachable == false)
        #expect(!found.devices.contains { $0.deviceID == "\(FakeServer.homeID)-1" })
        await host.stop()
    }

    @Test func addByAddressKeysTheServerByItsHomeID() async throws {
        #expect(ZWaveJSPlugin.addsDevicesByAddress)
        let host = try await environment.start(settings: [:])
        let context = try #require(host.context(platform: ZWaveJSPlugin.platform, name: ZWaveJSPlugin.name))
        let plugin = ZWaveJSPlugin(configuration: .init(), context: context, dependencies: environment.dependencies)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["host", "port"] && prompt.fields[1].optional)
        #expect(prompt.fields[0].value == nil)
        // A server the network announces is filled in.
        environment.announcements.withLockedValue { $0 = [ServerAnnouncement(name: "zwave-js-server", host: "192.0.2.30", port: 3001, homeID: "42")] }
        guard case .ask(let filled, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(filled.fields.map(\.value) == ["192.0.2.30", "3001"])
        #expect(filled.values == ["address": "192.0.2.30:3001"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": " 192.0.2.20 "])) else {
            Issue.record("not done"); return
        }
        #expect(outcome.deviceID == FakeServer.homeID && outcome.credentials == nil)
        #expect(outcome.settings == ["host": "192.0.2.20", "port": .null])
        guard case .done(let typed) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "ws://192.0.2.20:3001"])) else {
            Issue.record("not done"); return
        }
        #expect(typed.settings == ["host": "192.0.2.20", "port": 3001])
        #expect(environment.server.urls.last == URL(string: "ws://192.0.2.20:3001"))
        await #expect(throws: SetupError("The port must be between 1 and 65535")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.20", "port": "0"]))
        }
        await #expect(throws: SetupError("The port must be between 1 and 65535")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.20:99999"]))
        }
        environment.server.set(reachable: false)
        await #expect(throws: SetupError("No zwave-js-server answered at 192.0.2.60:3000")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.60"]))
        }
        environment.server.set(reachable: true)
        // A server found on the network is checked at its address, and must be the network it announced.
        let found = DiscoveredDevice(deviceID: "42", name: "Z-Wave network 42", address: "192.0.2.20:3000", kind: "server")
        await #expect(throws: SetupError("Another Z-Wave network answered at 192.0.2.20:3000: find the server again")) {
            try await plugin.authorize(SetupRequest(target: .device(found)))
        }
        let right = DiscoveredDevice(deviceID: FakeServer.homeID, name: "Z-Wave network", address: "192.0.2.20:3000", kind: "server")
        guard case .done(let checked) = try await plugin.authorize(SetupRequest(target: .device(right))) else { Issue.record("not done"); return }
        #expect(checked.deviceID == FakeServer.homeID)
        guard case .done = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("the account asks nothing"); return }
        await host.stop()
    }

    @Test func aServerSayingAKnownHomeIDDoesNotMoveIt() async throws {
        let host = try await environment.start()
        let context = try #require(host.context(platform: ZWaveJSPlugin.platform, name: ZWaveJSPlugin.name))
        let plugin = ZWaveJSPlugin(configuration: .init(), context: context, dependencies: environment.dependencies)
        // Another address answering with the home id set up at 192.0.2.20.
        await #expect(throws: SetupError("Z-Wave network \(FakeServer.homeID) is already set up at 192.0.2.20:3000: change its address in its settings")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.66"]))
        }
        guard case .done(let same) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.20"])) else { Issue.record("not done"); return }
        #expect(same.deviceID == FakeServer.homeID)
        await host.stop()
    }

    @Test func untrustedValuesDoNotCrashTheBridge() async throws {
        let host = try await started()
        let blind = try #require(host.accessory(id(9))?.service(.windowCovering))
        environment.server.valueUpdated(node: 9, commandClass: 38, property: "currentValue", value: -1e20)
        environment.server.valueUpdated(node: 9, commandClass: 38, property: "currentValue", value: 1e300)
        environment.server.valueUpdated(node: 9, commandClass: 38, property: "currentValue", value: 20)
        #expect(await eventually { blind[.currentPosition]?.value == 20 })
        #expect(NodeBuilder.percent(level: -1e20) == 0 && NodeBuilder.percent(level: 1e20) == 100)
        await host.stop()
    }

    @Test func anEntryControlSwitchIsGuardedAsALock() async throws {
        // A door strike: a Binary Switch on an Entry Control node, shown as a light by its settings.
        var settings = TestEnvironment.serverSettings
        settings["_accessories"] = [FakeServer.homeID: ["host": "192.0.2.20"], "\(FakeServer.homeID)-3": ["showAs": "lightbulb"]]
        var plug = try #require(FakeServer.fixture["state"]?["nodes"]?.arrayValue?.first { $0["nodeId"] == 3 }?.objectValue)
        plug["deviceClass"] = ["basic": ["key": 4, "label": "Routing Slave"], "generic": ["key": 64, "label": "Entry Control"], "specific": ["key": 1, "label": "Door Lock"]]
        environment.server.replace(node: .object(plug))
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(id(3)) != nil })
        let strike = try #require(host.accessory(id(3)))
        #expect(strike.category == .doorLock)
        let on = try #require(strike.service(.switch, subtype: "0")?[.on])
        #expect(on.isSecurityControl)
        #expect(await environment.plugin?.deviceKind(of: "\(FakeServer.homeID)-3") == "lock")
        await host.stop()
    }

    @Test func aLockEndpointWithASwitchIsALock() async throws {
        var lock = try #require(FakeServer.fixture["state"]?["nodes"]?.arrayValue?.first { $0["nodeId"] == 5 }?.objectValue)
        lock["values"] = .array((lock["values"]?.arrayValue ?? []) + [["endpoint": 0, "commandClass": 37, "property": "currentValue", "value": false, "metadata": ["type": "boolean"]]])
        environment.server.replace(node: .object(lock))
        let host = try await started()
        let accessory = try #require(host.accessory(id(5)))
        #expect(accessory.service(.lockMechanism, subtype: "0") != nil)
        #expect(accessory.service(.switch) == nil && accessory.service(.outlet) == nil)
        await host.stop()
    }

    // MARK: Pieces

    @Test func levelsAndColours() {
        #expect(NodeBuilder.percent(level: 99) == 100 && NodeBuilder.percent(level: 0) == 0 && NodeBuilder.percent(level: 50) == 51)
        #expect(NodeBuilder.level(percent: 100) == 99 && NodeBuilder.level(percent: 1) == 1)
        #expect(ColorMath.rgb(hue: 0, saturation: 100) == (255, 0, 0))
        #expect(ColorMath.rgb(hue: 240, saturation: 100) == (0, 0, 255))
        #expect(ColorMath.rgb(hue: 0, saturation: 0) == (255, 255, 255))
        let (hue, saturation) = ColorMath.hueSaturation(red: 0, green: 255, blue: 0)
        #expect(hue == 120 && saturation == 100)
        #expect(ZWaveJSPlugin.split("[fd00::1]:3001")! == ("fd00::1", 3001))
        #expect(ZWaveJSPlugin.url(host: "fd00::1", port: 3000) == URL(string: "ws://[fd00::1]:3000"))
        #expect(ServerVersion.homeID(.number(3967423180)) == "3967423180")
        #expect(NodeBuilder.lockState(mode: 1) == 0 && NodeBuilder.lockState(mode: 255) == 1 && NodeBuilder.lockState(mode: 254) == 3)
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(ZWaveJSPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/ZWaveJS ZWaveJSPlugin")
        let schema = try JSONValue(string: try #require(ZWaveJSPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "ZWaveJS")
    }
}
