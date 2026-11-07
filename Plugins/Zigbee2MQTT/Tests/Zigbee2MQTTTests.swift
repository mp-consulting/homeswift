import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftZigbee2MQTT

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Exposes and devices as Zigbee2MQTT reports them (described in the spec's 15.8; written for these tests).
enum Fixtures {
    static func binary(_ name: String, _ property: String? = nil, access: Int = 7, on: String = "\"ON\"", off: String = "\"OFF\"") -> String {
        #"{"type":"binary","name":"\#(name)","property":"\#(property ?? name)","access":\#(access),"value_on":\#(on),"value_off":\#(off)}"#
    }
    static func numeric(_ name: String, access: Int = 1, min: Double? = nil, max: Double? = nil, endpoint: String? = nil) -> String {
        var fields = [#""type":"numeric""#, #""name":"\#(name)""#, #""property":"\#(name)""#, #""access":\#(access)"#]
        if let min { fields.append(#""value_min":\#(min)"#) }
        if let max { fields.append(#""value_max":\#(max)"#) }
        if let endpoint { fields.append(#""endpoint":"\#(endpoint)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }
    static func enumeration(_ name: String, _ values: [String], access: Int = 1) -> String {
        #"{"type":"enum","name":"\#(name)","property":"\#(name)","access":\#(access),"values":[\#(values.map { "\"\($0)\"" }.joined(separator: ","))]}"#
    }

    static let hueLight = #"""
        {"type":"light","features":[\#(binary("state")),\#(numeric("brightness", access: 7, min: 0, max: 254)),
         \#(numeric("color_temp", access: 7, min: 153, max: 500)),
         {"type":"composite","name":"color_xy","property":"color","access":7,"features":[\#(numeric("x", access: 7)),\#(numeric("y", access: 7))]}]}
        """#
    static let hsLight = #"""
        {"type":"light","features":[\#(binary("state")),
         {"type":"composite","name":"color_hs","property":"color","access":7,"features":[\#(numeric("hue", access: 7)),\#(numeric("saturation", access: 7))]}]}
        """#
    static let climate = #"""
        {"type":"climate","features":[\#(numeric("local_temperature", access: 5)),
         {"type":"numeric","name":"current_heating_setpoint","property":"current_heating_setpoint","access":7,"value_min":5,"value_max":30,"value_step":0.5},
         \#(enumeration("system_mode", ["off", "auto", "heat"], access: 7)),\#(enumeration("running_state", ["idle", "heat"], access: 5))]}
        """#

    static func device(_ address: String, _ name: String, model: String = "M1", _ exposes: [String]) -> String {
        #"{"ieee_address":"\#(address)","friendly_name":"\#(name)","supported":true,"type":"Router","software_build_id":"1.2.3","date_code":"20240101","definition":{"vendor":"Acme","model":"\#(model)","exposes":[\#(exposes.joined(separator: ","))]}}"#
    }

    static let light = device("0x00178d0009876543", "test_light", model: "8718696449691", [hueLight, numeric("linkquality")])
    static let sensor = device("0x0000000000000002", "test_sensor", model: "WSDCGQ12LM", [
        numeric("temperature"), numeric("humidity"), numeric("pressure"), numeric("battery", min: 0, max: 100), binary("battery_low", access: 1, on: "true", off: "false"),
    ])
    static let cover = device("0x0000000000000003", "blind", model: "E1926", [
        #"{"type":"cover","features":[\#(enumeration("state", ["OPEN", "CLOSE", "STOP"], access: 3)),\#(numeric("position", access: 7, min: 0, max: 100))]}"#,
    ])
    static let motorCover = device("0x0000000000000004", "shutter", model: "BMCT-SLZ", [
        #"{"type":"cover","features":[\#(numeric("position", access: 7, min: 0, max: 100))]}"#, enumeration("motor_state", ["opening", "closing", "stopped"]),
    ])
    static let tiltCover = device("0x0000000000000005", "venetian", model: "57008000", [
        #"{"type":"cover","features":[\#(enumeration("state", ["OPEN", "CLOSE", "STOP"], access: 3)),\#(numeric("position", access: 7, min: 0, max: 100)),\#(numeric("tilt", access: 7, min: 0, max: 100))]}"#,
    ])
    static let lock = device("0x0000000000000006", "door", model: "V3", [
        #"{"type":"lock","features":[\#(binary("state", on: "\"LOCK\"", off: "\"UNLOCK\"")),\#(enumeration("lock_state", ["locked", "unlocked", "not_fully_locked"]))]}"#,
    ])
    static let thermostat = device("0x0000000000000007", "radiator", model: "07703L", [climate])
    static let plug = device("0x0000000000000008", "plug", model: "TS0115", [
        #"{"type":"switch","endpoint":"l1","features":[\#(binary("state", "state_l1"))]}"#, #"{"type":"switch","endpoint":"l2","features":[\#(binary("state", "state_l2"))]}"#,
        numeric("power"), numeric("energy"), numeric("voltage"),
    ])
    static let remote = device("0x0000000000000009", "remote", model: "WXKG07LM", [
        enumeration("action", ["single_left", "single_right", "single_both", "double_left", "double_right", "double_both", "hold_left", "hold_right", "hold_both"]),
        numeric("battery", min: 0, max: 100),
    ])
    static let hsBulb = device("0x000000000000000a", "hs bulb", [hsLight])
    static let motion = device("0x000000000000000b", "hall motion", [binary("occupancy", access: 1, on: "true", off: "false"), binary("tamper", access: 1, on: "true", off: "false")])
}

/// A host with one block, whose plugin talks to a fake broker.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Zigbee2MQTT-tests-\(UUID().uuidString)")
    private let connections = NIOLockedValueBox<[FakeMQTTConnection]>([])
    private let plugins = NIOLockedValueBox<[Zigbee2MQTTPlugin]>([])

    var broker: FakeMQTTConnection { connections.withLockedValue { $0[0] } }
    var allConnections: [FakeMQTTConnection] { connections.withLockedValue { $0 } }
    var plugin: Zigbee2MQTTPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: Zigbee2MQTTPlugin.Dependencies {
        var dependencies = Zigbee2MQTTPlugin.Dependencies()
        dependencies.connect = { _ in
            let connection = FakeMQTTConnection()
            self.connections.withLockedValue { $0.append(connection) }
            return connection
        }
        // The real window: one request's writes, made at once, can be further apart than 10 ms on a busy runner.
        dependencies.coalescing = .milliseconds(100)
        dependencies.coverPollInterval = .milliseconds(150)
        dependencies.bridgeTimeout = .seconds(1)
        return dependencies
    }

    nonisolated(unsafe) static let mqtt: [String: Any] = ["base_topic": "zigbee2mqtt", "server": "mqtt://localhost:1883"]

    func start(_ settings: [String: Any] = ["mqtt": TestEnvironment.mqtt]) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: Zigbee2MQTTPlugin.platform, name: Zigbee2MQTTPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(Zigbee2MQTTPlugin.Configuration.self, from: json)
            let plugin = Zigbee2MQTTPlugin(configuration: configuration, context: context, dependencies: self.dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: Zigbee2MQTTPlugin.platform, name: Zigbee2MQTTPlugin.name, settings: settings)
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry,
                                  storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// Starts, and sends Zigbee2MQTT's retained messages with these devices and groups.
    func started(devices: [String], groups: String = "[]", settings: [String: Any] = ["mqtt": TestEnvironment.mqtt]) async throws -> PluginHost {
        let host = try await start(settings)
        #expect(await eventually { self.allConnections.first?.isConnected == true })
        broker.receive("zigbee2mqtt/bridge/state", string: #"{"state":"online"}"#)
        broker.receive("zigbee2mqtt/bridge/devices", string: "[" + devices.joined(separator: ",") + "]")
        broker.receive("zigbee2mqtt/bridge/groups", string: groups)
        return host
    }

    func send(_ topic: String, _ payload: String) { broker.receive("zigbee2mqtt/\(topic)", string: payload) }

    func published(_ topic: String) -> [String] { broker.published(on: "zigbee2mqtt/\(topic)") }
}

extension PluginHost {
    func accessory(_ deviceID: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == Zigbee2MQTTPlugin.accessoryID(deviceID: deviceID) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Zigbee2MQTTTests {
    let environment = TestEnvironment()

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(Zigbee2MQTTPlugin.Configuration.self, from: Data(#"{"platform":"zigbee2mqtt","mqtt":{"base_topic":"z","server":"mqtt://h"}}"#.utf8))
        #expect(try Settings(configuration.block).mqtt.baseTopic == "z")
    }

    @Test func subscribesAndAsksForTheStateOfNewDevices() async throws {
        let host = try await environment.started(devices: [Fixtures.light])
        defer { Task { await host.stop() } }
        #expect(environment.broker.subscriptions["zigbee2mqtt/#"] == .atMostOnce)
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil })
        // Brightness is not asked for by default.
        #expect(await eventually { environment.published("0x00178d0009876543/get") == [#"{"color":0,"color_temp":0,"state":0}"#] })
        #expect(environment.broker.published.first { $0.topic.hasSuffix("/get") }?.qos == .atLeastOnce)
        let accessory = try #require(host.accessory("0x00178d0009876543"))
        #expect(accessory.information.characteristic(.manufacturer).value == .string("Acme"))
        #expect(accessory.information.characteristic(.model).value == .string("8718696449691"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("0x00178d0009876543"))
        #expect(accessory.information[.hardwareRevision]?.value == .string("20240101"))
        #expect(accessory.name == "test light")
    }

    @Test func lightStateAndWrites() async throws {
        let host = try await environment.started(devices: [Fixtures.light])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil })
        let light = try #require(host.accessory("0x00178d0009876543")?.service(.lightbulb))
        #expect(light.adaptiveLighting != nil)
        #expect(light[.colorTemperature]?.type.minValue == 153)
        for (state, percent) in [(0, 0), (1, 1), (2, 1), (127, 50), (254, 100)] {
            environment.send("test_light", #"{"state":"ON","brightness":\#(state)}"#)
            #expect(await eventually { light.characteristic(.brightness).value == .int(percent) }, "\(state)")
        }
        environment.send("test_light", #"{"state":"TOGGLE"}"#)
        environment.send("test_light", #"{"color":{"hue":34,"saturation":77,"x":0.4435,"y":0.4062},"color_mode":"color_temp","color_temp":343,"linkquality":72}"#)
        #expect(await eventually { light.characteristic(.colorTemperature).value == .int(343) })
        #expect(light.characteristic(.on).value == .bool(true))
        // Hue and saturation follow the colour temperature: on a loaded runner they may land after it.
        #expect(await eventually { light.characteristic(.hue).value == .double(39) })
        #expect(await eventually { light.characteristic(.saturation).value == .double(48) })
        environment.send("test_light", #"{"color":{"x":0.44416,"y":0.51657},"color_mode":"xy","color_temp":169}"#)
        #expect(await eventually { light.characteristic(.hue).value == .double(60) })
        #expect(await eventually { light.characteristic(.saturation).value == .double(100) })
        #expect(light.characteristic(.colorTemperature).value == .int(343))

        // One request's On and Brightness are one message; Hue and Saturation become xy.
        async let on: Void = light.characteristic(.on).write(.bool(true))
        async let brightness: Void = light.characteristic(.brightness).write(.int(50))
        _ = try await (on, brightness)
        #expect(await eventually { environment.published("0x00178d0009876543/set").contains(#"{"brightness":127,"state":"ON"}"#) })
        async let hue: Void = light.characteristic(.hue).write(.double(0))
        async let saturation: Void = light.characteristic(.saturation).write(.double(100))
        _ = try await (hue, saturation)
        #expect(await eventually { environment.published("0x00178d0009876543/set").contains(#"{"color":{"x":0.70061,"y":0.2993}}"#) })
        try await light.characteristic(.brightness).write(.int(0))
        #expect(await eventually { environment.published("0x00178d0009876543/set").last == #"{"brightness":0}"# })
        try await light.characteristic(.brightness).write(.int(100))
        #expect(await eventually { environment.published("0x00178d0009876543/set").last == #"{"brightness":254}"# })
    }

    @Test func hsLightSendsHueAndSaturation() async throws {
        let host = try await environment.started(devices: [Fixtures.hsBulb])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x000000000000000a") != nil })
        let light = try #require(host.accessory("0x000000000000000a")?.service(.lightbulb))
        #expect(light.adaptiveLighting == nil)
        async let hue: Void = light.characteristic(.hue).write(.double(0))
        async let saturation: Void = light.characteristic(.saturation).write(.double(100))
        _ = try await (hue, saturation)
        #expect(await eventually { environment.published("0x000000000000000a/set") == [#"{"color":{"hue":0,"saturation":100}}"#] })
    }

    @Test func adaptiveLightingGatesAndTurnsOff() async throws {
        let host = try await environment.started(devices: [Fixtures.light], settings: [
            "mqtt": TestEnvironment.mqtt, "defaults": ["converters": ["light": ["adaptive_lighting": ["transition": 2, "min_delta": 5]]]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil })
        let light = try #require(host.accessory("0x00178d0009876543")?.service(.lightbulb))
        let controller = try #require(light.adaptiveLighting)
        try controller.activateForTesting(mireds: 300)
        let topic = "0x00178d0009876543/set"
        // Off: nothing sent (only_when_on).
        try await light.characteristic(.colorTemperature).write(.int(300), context: ObjectIdentifier(controller))
        environment.send("test_light", #"{"state":"ON"}"#)
        #expect(await eventually { light.characteristic(.on).value == .bool(true) })
        try await light.characteristic(.colorTemperature).write(.int(300), context: ObjectIdentifier(controller))
        #expect(await eventually { environment.published(topic) == [#"{"color_temp":300,"transition":2}"#] })
        try await light.characteristic(.colorTemperature).write(.int(303), context: ObjectIdentifier(controller))
        try await light.characteristic(.colorTemperature).write(.int(310), context: ObjectIdentifier(controller))
        #expect(await eventually { environment.published(topic).last == #"{"color_temp":310,"transition":2}"# })
        #expect(environment.published(topic).count == 2)
        // The device reports a white it was set to elsewhere: Adaptive Lighting turns off.
        environment.send("test_light", #"{"color_mode":"color_temp","color_temp":400}"#)
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        try controller.activateForTesting(mireds: 300)
        environment.send("test_light", #"{"color_mode":"xy","color":{"x":0.3,"y":0.3}}"#)
        #expect(await eventually { !controller.isAdaptiveLightingActive })
    }

    @Test func sensorsShowTheirReadings() async throws {
        let host = try await environment.started(devices: [Fixtures.sensor, Fixtures.motion])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000002") != nil && host.accessory("0x000000000000000b") != nil })
        let sensor = try #require(host.accessory("0x0000000000000002"))
        environment.send("test_sensor", #"{"temperature":22.5,"humidity":45,"battery":95,"pressure":1009,"battery_low":false,"linkquality":null}"#)
        let temperature = try #require(sensor.service(.temperatureSensor))
        #expect(await eventually { temperature.characteristic(.currentTemperature).value == .double(22.5) })
        #expect(temperature[.currentTemperature]?.type.minValue == -100)
        #expect(temperature.characteristic(.statusLowBattery).value == .int(0))
        #expect(sensor.service(.humiditySensor)?.characteristic(.currentRelativeHumidity).value == .double(45))
        #expect(sensor.service(.battery)?.characteristic(.batteryLevel).value == .int(95))
        #expect(sensor.service(.battery)?.characteristic(.chargingState).value == .int(2))
        #expect(sensor.service(EveTypes.airPressureSensor)?.characteristic(EveTypes.airPressure).value == .int(1009))
        #expect(sensor.services.map { $0.characteristic(.name).value } .contains(.string("test sensor")))
        let motion = try #require(host.accessory("0x000000000000000b")?.service(.occupancySensor))
        environment.send("hall motion", #"{"occupancy":true,"tamper":true}"#)
        #expect(await eventually { motion.characteristic(.occupancyDetected).value == .int(1) })
        #expect(motion.characteristic(.statusTampered).value == .int(1))
    }

    @Test func occupancyAsMotion() async throws {
        let host = try await environment.started(devices: [Fixtures.motion], settings: [
            "mqtt": TestEnvironment.mqtt, "devices": [["id": "Hall Motion", "converters": ["occupancy": ["type": "motion"]]]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x000000000000000b") != nil })
        let motion = try #require(host.accessory("0x000000000000000b")?.service(.motionSensor))
        #expect(motion.subtype == "occupancy")
        #expect(motion.characteristic(.name).value == .string("hall motion occupancy"))
    }

    @Test func coverWithoutMotorState() async throws {
        let host = try await environment.started(devices: [Fixtures.cover, Fixtures.sensor])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000003") != nil })
        let cover = try #require(host.accessory("0x0000000000000003")?.service(.windowCovering))
        let current = cover.characteristic(.currentPosition), target = cover.characteristic(.targetPosition), state = cover.characteristic(.positionState)
        environment.send("blind", #"{"position":100}"#)
        #expect(await eventually { current.value == .int(100) && state.value == .int(2) && target.value == .int(100) })
        environment.send("blind", #"{"position":50}"#)
        #expect(await eventually { current.value == .int(50) })
        try await target.write(.int(51))
        #expect(await eventually { environment.published("0x0000000000000003/set").last == #"{"position":51}"# })
        #expect(state.value == .int(1))
        environment.send("blind", #"{"position":51}"#)
        // Messages are handled in order: once the sensor shows this, the blind had its own.
        environment.send("test_sensor", #"{"temperature":1}"#)
        #expect(await eventually { host.accessory("0x0000000000000002")?.service(.temperatureSensor)?.characteristic(.currentTemperature).value == .double(1) })
        try await target.write(.int(49))
        #expect(state.value == .int(0))
        #expect(current.value == .int(50))
        environment.send("blind", #"{"position":51}"#)
        #expect(await eventually { current.value == .int(51) })
        environment.send("blind", #"{"position":49}"#)
        #expect(await eventually { current.value == .int(49) })
        #expect(state.value == .int(0))
        environment.send("blind", #"{"position":49}"#)
        #expect(await eventually { state.value == .int(2) && target.value == .int(49) })
        // Asked again for the same position: stopped at once, then a get for the position.
        let gets = environment.published("0x0000000000000003/get").count
        try await target.write(.int(49))
        #expect(state.value == .int(2))
        #expect(await eventually { environment.published("0x0000000000000003/get").count > gets })
        #expect(environment.published("0x0000000000000003/get").last == #"{"position":0}"#)
        try await cover.characteristic(.holdPosition).write(.bool(true))
        #expect(await eventually { environment.published("0x0000000000000003/set").last == #"{"state":"STOP"}"# })
    }

    @Test func coverWithMotorStateAndTilt() async throws {
        let host = try await environment.started(devices: [Fixtures.motorCover, Fixtures.tiltCover])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000004") != nil && host.accessory("0x0000000000000005") != nil })
        let cover = try #require(host.accessory("0x0000000000000004")?.service(.windowCovering))
        let current = cover.characteristic(.currentPosition), target = cover.characteristic(.targetPosition), state = cover.characteristic(.positionState)
        environment.send("shutter", #"{"position":100,"motor_state":"stopped"}"#)
        #expect(await eventually { current.value == .int(100) && state.value == .int(2) && target.value == .int(100) })
        try await target.write(.int(51))
        #expect(await eventually { environment.published("0x0000000000000004/set").last == #"{"position":51}"# })
        environment.send("shutter", #"{"position":41,"motor_state":"closing"}"#)
        #expect(await eventually { state.value == .int(0) })
        #expect(target.value == .int(51))
        #expect(current.value == .int(100))
        environment.send("shutter", #"{"position":51,"motor_state":"stopped"}"#)
        #expect(await eventually { current.value == .int(51) && state.value == .int(2) && target.value == .int(51) })

        let venetian = try #require(host.accessory("0x0000000000000005")?.service(.windowCovering))
        for (tilt, angle) in [(100, 90), (50, 0), (0, -90)] {
            environment.send("venetian", #"{"position":100,"tilt":\#(tilt)}"#)
            #expect(await eventually { venetian.characteristic(.currentHorizontalTiltAngle).value == .int(angle) })
        }
        for (angle, tilt) in [(-90, 0), (0, 50), (90, 100)] {
            try await venetian.characteristic(.targetHorizontalTiltAngle).write(.int(angle))
            #expect(await eventually { environment.published("0x0000000000000005/set").last == #"{"tilt":\#(tilt)}"# })
        }
    }

    @Test func lockThermostatAndSwitches() async throws {
        let host = try await environment.started(devices: [Fixtures.lock, Fixtures.thermostat, Fixtures.plug])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000006") != nil && host.accessory("0x0000000000000007") != nil && host.accessory("0x0000000000000008") != nil })
        let lock = try #require(host.accessory("0x0000000000000006")?.service(.lockMechanism))
        try await lock.characteristic(.lockTargetState).write(.int(1))
        #expect(await eventually { environment.published("0x0000000000000006/set").last == #"{"state":"LOCK"}"# })
        try await lock.characteristic(.lockTargetState).write(.int(0))
        #expect(await eventually { environment.published("0x0000000000000006/set").last == #"{"state":"UNLOCK"}"# })
        environment.send("door", #"{"lock_state":"not_fully_locked"}"#)
        #expect(await eventually { lock.characteristic(.lockCurrentState).value == .int(2) })

        let thermostat = try #require(host.accessory("0x0000000000000007")?.service(.thermostat))
        environment.send("radiator", #"{"local_temperature":19.5,"running_state":"heat","system_mode":"auto"}"#)
        // A message's properties are shown one after the other: each is waited for.
        #expect(await eventually { thermostat.characteristic(.currentTemperature).value == .double(19.5) })
        #expect(await eventually { thermostat.characteristic(.currentHeatingCoolingState).value == .int(1) })
        #expect(await eventually { thermostat.characteristic(.targetHeatingCoolingState).value == .int(3) })
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1, 3])
        try await thermostat.characteristic(.targetTemperature).write(.double(19))
        #expect(await eventually { environment.published("0x0000000000000007/set").last == #"{"current_heating_setpoint":19}"# })
        try await thermostat.characteristic(.targetHeatingCoolingState).write(.int(0))
        #expect(await eventually { environment.published("0x0000000000000007/set").last == #"{"system_mode":"off"}"# })

        let plug = try #require(host.accessory("0x0000000000000008"))
        let switches = plug.services.filter { $0.type.uuid == ServiceType.switch.uuid }
        #expect(switches.map(\.subtype) == ["l1", "l2"])
        #expect(switches.map { $0.characteristic(.name).value } == [.string("plug l1"), .string("plug l2")])
        try await switches[1].characteristic(.on).write(.bool(true))
        #expect(await eventually { environment.published("0x0000000000000008/set").last == #"{"state_l2":"ON"}"# })
        environment.send("plug", #"{"state_l1":"ON","power":12.5,"energy":3.25,"voltage":230}"#)
        #expect(await eventually { switches[0].characteristic(.on).value == .bool(true) })
        let meter = try #require(plug.service(EveService.energy))
        #expect(await eventually { meter.characteristic(EveTypes.consumption).value == .double(12.5) })
        #expect(await eventually { meter.characteristic(EveTypes.voltage).value == .double(230) })
        // Every electrical property is asked for, whatever its access.
        #expect(await eventually { environment.published("0x0000000000000008/get").first == #"{"energy":0,"power":0,"state_l1":0,"state_l2":0,"voltage":0}"# })
    }

    @Test func outletsByConverter() async throws {
        let host = try await environment.started(devices: [Fixtures.plug], settings: [
            "mqtt": TestEnvironment.mqtt, "devices": [["id": "0x0000000000000008", "excluded_endpoints": ["l2"], "converters": ["switch": ["type": "outlet"]]]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000008") != nil })
        let plug = try #require(host.accessory("0x0000000000000008"))
        #expect(plug.services.filter { $0.type.uuid == ServiceType.outlet.uuid }.map(\.subtype) == ["l1"])
    }

    @Test func remoteButtonsFireEvents() async throws {
        let host = try await environment.started(devices: [Fixtures.remote])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000009") != nil })
        let buttons = try #require(host.accessory("0x0000000000000009")).services.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }
        #expect(buttons.map(\.subtype) == ["both", "left", "right"])
        #expect(buttons.map { $0.characteristic(.serviceLabelIndex).value } == [.int(1), .int(2), .int(3)])
        #expect(buttons[1][.programmableSwitchEvent]?.type.validValues == [0, 1, 2])
        let events = NIOLockedValueBox<[HAPValue]>([])
        buttons[1].characteristic(.programmableSwitchEvent).observe { change in events.withLockedValue { $0.append(change.newValue) } }
        environment.send("remote", #"{"action":"single_left"}"#)
        environment.send("remote", #"{"action":""}"#)
        environment.send("remote", #"{"action":"hold_left"}"#)
        #expect(await eventually { events.withLockedValue { $0 } == [.int(0), .int(2)] })
    }

    @Test func offlineDevicesAndBrokerGiveNoResponse() async throws {
        let host = try await environment.started(devices: [Fixtures.light, Fixtures.sensor], settings: [
            "mqtt": TestEnvironment.mqtt, "devices": [["id": "test_sensor", "ignore_availability": true, "ignore_z2m_online": true]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil && host.accessory("0x0000000000000002") != nil })
        let light = try #require(host.accessory("0x00178d0009876543")), sensor = try #require(host.accessory("0x0000000000000002"))
        environment.send("bridge/info", #"{"version":"2.7.2","config":{"availability":{"enabled":true}}}"#)
        environment.send("test_light/availability", #"{"state":"offline"}"#)
        environment.send("test_sensor/availability", "offline")
        #expect(await eventually { light.isUnavailable })
        #expect(!sensor.isUnavailable)
        await #expect(throws: HAPStatusError.self) { try await light.service(.lightbulb)?.characteristic(.on).write(.bool(true)) }
        environment.send("test_light/availability", #"{"state":"online"}"#)
        #expect(await eventually { !light.isUnavailable })
        // The broker away: every device but those ignoring it.
        environment.broker.setState(.connectionLost("gone"))
        #expect(await eventually { light.isUnavailable })
        #expect(!sensor.isUnavailable)
        environment.broker.setState(.connected(sessionPresent: false))
        #expect(await eventually { !light.isUnavailable })
        environment.send("bridge/state", "offline")
        #expect(await eventually { light.isUnavailable })
        environment.send("bridge/state", #"{"state":"online"}"#)
        #expect(await eventually { !light.isUnavailable })
    }

    @Test func availabilityOffInZigbee2MQTTIgnoresDeviceMessages() async throws {
        let host = try await environment.started(devices: [Fixtures.light])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil })
        environment.send("bridge/info", #"{"version":"2.7.2","config":{"availability":false}}"#)
        environment.send("test_light/availability", #"{"state":"offline"}"#)
        environment.send("test_light", #"{"state":"ON"}"#)
        let light = try #require(host.accessory("0x00178d0009876543"))
        #expect(await eventually { light.service(.lightbulb)?.characteristic(.on).value == .bool(true) })
        #expect(!light.isUnavailable)
    }

    @Test func groupsAreKeptAndBuiltFromTheirMembers() async throws {
        let group = #"[{"id":5,"friendly_name":"Living room","members":[{"ieee_address":"0x00178d0009876543","endpoint":11},{"ieee_address":"0x000000000000000a","endpoint":11}]}]"#
        let host = try await environment.started(devices: [Fixtures.light, Fixtures.hsBulb], groups: group)
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("group-5") != nil })
        let accessory = try #require(host.accessory("group-5"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("GROUP:5"))
        #expect(accessory.information.characteristic(.model).value == .string("GROUP-5"))
        // The members share On only.
        let light = try #require(accessory.service(.lightbulb))
        #expect(light[.brightness] == nil)
        try await light.characteristic(.on).write(.bool(true))
        #expect(await eventually { environment.published("Living room/set") == [#"{"state":"ON"}"#] })
        environment.send("5", #"{"state":"ON"}"#)
        #expect(await eventually { light.characteristic(.on).value == .bool(true) })
        // A device list on its own (a broker resending it) does not drop the group.
        environment.send("bridge/devices", "[" + [Fixtures.light, Fixtures.hsBulb].joined(separator: ",") + "]")
        // Messages are handled in order: once this shows, the device list was too, and its removals ran.
        environment.send("5", #"{"state":"OFF"}"#)
        #expect(await eventually { light.characteristic(.on).value == .bool(false) })
        #expect(host.accessory("group-5") === accessory)
        // A device gone from the list goes.
        environment.send("bridge/devices", "[" + Fixtures.light + "]")
        #expect(await eventually { host.accessory("0x000000000000000a") == nil })
    }

    @Test func excludedAndGroupedDevices() async throws {
        let group = #"[{"id":5,"friendly_name":"Living room","members":[{"ieee_address":"0x00178d0009876543","endpoint":11}]}]"#
        let host = try await environment.started(devices: [Fixtures.light, Fixtures.hsBulb, Fixtures.sensor], groups: group, settings: [
            "mqtt": TestEnvironment.mqtt, "exclude_grouped_devices": true, "devices": [["id": "HS BULB", "exclude": true]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("group-5") != nil && host.accessory("0x0000000000000002") != nil })
        #expect(host.accessory("0x00178d0009876543") == nil)
        #expect(host.accessory("0x000000000000000a") == nil)
        let discovered = try #require(try await environment.plugin?.discover())
        #expect(discovered.first { $0.deviceID == "0x00178d0009876543" }?.excludedBySettings == true)
        #expect(discovered.first { $0.deviceID == "0x0000000000000002" }?.excludedBySettings == false)
        #expect(discovered.contains { $0.deviceID == "group-5" })
    }

    @Test func accessoriesComeBackBeforeTheBroker() async throws {
        let host = try await environment.started(devices: [Fixtures.light])
        #expect(await eventually { host.accessory("0x00178d0009876543") != nil })
        await host.stop()
        let again = try await environment.start()
        defer { Task { await again.stop() } }
        #expect(await eventually { again.accessory("0x00178d0009876543")?.service(.lightbulb) != nil })
        let light = try #require(again.accessory("0x00178d0009876543")?.service(.lightbulb))
        try await light.characteristic(.on).write(.bool(true))
        let broker = try #require(environment.allConnections.last)
        #expect(await eventually { broker.published(on: "zigbee2mqtt/0x00178d0009876543/set") == [#"{"state":"ON"}"#] })
    }

    @Test func anInvalidConfigurationDoesNothing() async throws {
        let host = try await environment.start(["mqtt": ["server": "mqtt://localhost"]])
        defer { Task { await host.stop() } }
        // `start()` has returned: it connected to nothing.
        #expect(environment.allConnections.isEmpty)
        #expect(await environment.plugin?.settings == nil)
    }

    @Test func setupChecksTheBrokerAndKeepsThePasswordOut() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, _) = first else { Issue.record("expected a prompt"); return }
        #expect(prompt.fields.map(\.key) == ["server", "base_topic", "user", "password"])
        let answers = ["server": "mqtt://broker:1883", "base_topic": "zigbee2mqtt", "user": "z2m", "password": "secret"]
        let step = Task { try await plugin.authorize(SetupRequest(target: .account, answers: answers)) }
        #expect(await eventually { environment.allConnections.count == 2 && environment.allConnections[1].isConnected })
        let broker = environment.allConnections[1]
        #expect(broker.subscriptions["zigbee2mqtt/bridge/devices"] != nil)
        broker.receive("zigbee2mqtt/bridge/devices", string: "[" + Fixtures.light + "]")
        broker.receive("zigbee2mqtt/bridge/groups", string: "[]")
        guard case .done(let outcome) = try await step.value else { Issue.record("expected done"); return }
        #expect(outcome.credentials == ["server": "mqtt://broker:1883", "user": "z2m", "password": "secret"])
        #expect(outcome.settings["mqtt"]?["server"] == "mqtt://broker:1883")
        #expect(outcome.settings["mqtt"]?["user"] == "z2m")
        #expect(outcome.settings["mqtt"]?["password"] == nil)
    }

    // MARK: Join

    /// The permit_join requests published, as their `time`.
    func permitJoins() -> [Int] {
        environment.broker.published(on: "zigbee2mqtt/bridge/request/permit_join").compactMap { (try? JSONValue(string: $0))?["time"]?.intValue }
    }

    @Test func joinOpensTheNetworkUntilTheDeviceIsInterviewed() async throws {
        #expect(Zigbee2MQTTPlugin.newDevices == .joined(label: "Add a Zigbee device…"))
        let host = try await environment.started(devices: [Fixtures.light])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        guard case .ask(let wait, let state) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(wait.retryAfter == 2 && (wait.waitSeconds ?? 0) > 100 && wait.fields.isEmpty && wait.warning != nil)
        #expect(await eventually { self.permitJoins() == [120] })
        let request = try JSONValue(string: try #require(environment.broker.published(on: "zigbee2mqtt/bridge/request/permit_join").first))
        #expect(request["value"] == true)
        // A device the bridge has, interviewed again as it rejoins, is not the new one.
        environment.broker.receive("zigbee2mqtt/bridge/event", string: #"{"type":"device_interview","data":{"friendly_name":"test_light","ieee_address":"0x00178d0009876543","status":"successful","supported":true}}"#)
        #expect(await eventually { await plugin.joining != nil })
        #expect(await plugin.joining?.joined == nil)
        // Another device's interview is not the one Setup waits for.
        environment.broker.receive("zigbee2mqtt/bridge/event", string: #"{"type":"device_joined","data":{"friendly_name":"0x00158d0001a2b3c4","ieee_address":"0x00158d0001a2b3c4"}}"#)
        environment.broker.receive("zigbee2mqtt/bridge/event", string: #"{"type":"device_interview","data":{"friendly_name":"other","ieee_address":"0x0000000000000099","status":"successful","supported":true}}"#)
        #expect(await eventually { await plugin.joining?.joined?.address == "0x00158d0001a2b3c4" })
        guard case .ask(let reading, _) = try await plugin.authorize(SetupRequest(target: .newDevice, state: state)) else { Issue.record("no prompt"); return }
        #expect(reading.values == ["name": "0x00158d0001a2b3c4"] && reading.retryAfter == 2)
        environment.broker.receive("zigbee2mqtt/bridge/event", string: #"{"type":"device_interview","data":{"friendly_name":"0x00158d0001a2b3c4","ieee_address":"0x00158d0001a2b3c4","status":"successful","supported":true}}"#)
        #expect(await eventually { await plugin.joining?.interviewed == true })
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, state: state)) else { Issue.record("not done"); return }
        #expect(outcome.deviceID == "0x00158d0001a2b3c4")
        // The network closes once the device is in.
        #expect(await eventually { self.permitJoins() == [120, 0] })
        await #expect(throws: SetupError("Zigbee2MQTT closed its network: start again to add a device")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, state: state))
        }
    }

    @Test func joinSaysWhenTheInterviewFails() async throws {
        let host = try await environment.started(devices: [Fixtures.light])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        guard case .ask(_, let state) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        environment.broker.receive("zigbee2mqtt/bridge/event", string: #"{"type":"device_interview","data":{"friendly_name":"x","ieee_address":"0x01","status":"failed"}}"#)
        #expect(await eventually { await plugin.joining?.failure != nil })
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .newDevice, state: state)) }
        #expect(await eventually { self.permitJoins() == [120, 0] })
    }

    @Test func joinNeedsTheBroker() async throws {
        let plugin = Zigbee2MQTTPlugin(
            configuration: try JSONDecoder().decode(Zigbee2MQTTPlugin.Configuration.self, from: Data(#"{"platform":"zigbee2mqtt"}"#.utf8)),
            context: try #require(try await environment.start().context(platform: Zigbee2MQTTPlugin.platform, name: Zigbee2MQTTPlugin.name)),
            dependencies: environment.dependencies)
        await #expect(throws: SetupError("Zigbee2MQTT is not connected: set up its MQTT broker first, then add devices")) {
            try await plugin.authorize(SetupRequest(target: .newDevice))
        }
    }

    @Test func setupSaysWhenNoZigbee2MQTTAnswers() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["server": "mqtt://broker", "base_topic": "elsewhere"]))
        }
    }

    @Test func homebridgeDeviceEntriesMoveToAccessorySettings() async throws {
        let group = #"[{"id":5,"friendly_name":"Living room","members":[]}]"#
        let host = try await environment.started(devices: [Fixtures.light, Fixtures.plug], groups: group)
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.knownLists != nil })
        let block = try JSONValue(string: #"""
            {"platform":"zigbee2mqtt","mqtt":{"base_topic":"zigbee2mqtt","server":"mqtt://h"},
             "devices":[{"id":"TEST_LIGHT","exclude":true},{"id":"0x0000000000000008","excluded_endpoints":["l2"],"converters":{"switch":{"type":"outlet"}}},
                        {"id":"living room","ignore_availability":true},{"id":"unknown","exclude":true},{"id":"0x0000000000000008","exclude":false}]}
            """#)
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["_accessories"]?["0x00178d0009876543"] == ["excluded": true])
        #expect(canonical["_accessories"]?["0x0000000000000008"]?["excluded_endpoints"] == ["l2"])
        #expect(canonical["_accessories"]?["group-5"]?["ignore_availability"] == true)
        #expect(canonical["devices"]?.arrayValue?.count == 2)
        #expect(await plugin.deviceKind(of: "0x00178d0009876543") == "light")
        #expect(await plugin.deviceKind(of: "0x0000000000000008") == "switch")
    }

    @Test func accessorySettingsApply() async throws {
        let host = try await environment.started(devices: [Fixtures.plug], settings: [
            "mqtt": TestEnvironment.mqtt, "_accessories": ["0x0000000000000008": ["excluded_endpoints": ["l1"], "converters": ["switch": ["type": "outlet"]]]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("0x0000000000000008") != nil })
        let plug = try #require(host.accessory("0x0000000000000008"))
        #expect(plug.services.filter { $0.type.uuid == ServiceType.outlet.uuid }.map(\.subtype) == ["l2"])
    }

    @Test func schemaDeclaresNoPassword() throws {
        let schema = try JSONValue(string: try #require(Zigbee2MQTTPlugin.configurationSchemaJSON))
        #expect(schema["schema"]?["properties"]?["mqtt"]?["properties"]?["password"] == nil)
        #expect(schema["accessorySchema"]?["properties"]?["converters"] != nil)
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(Zigbee2MQTTPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Zigbee2MQTT Zigbee2MQTTPlugin")
        let schema = try JSONValue(string: try #require(Zigbee2MQTTPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "zigbee2mqtt")
    }
}
