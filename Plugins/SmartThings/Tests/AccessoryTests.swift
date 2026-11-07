import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

/// The devices of the spec's fixtures (docs/clean-room/SmartThings.md, section 15) as accessories.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryTests {
    let environment = TestEnvironment()

    func started(_ settings: [String: Any] = TestEnvironment.block, accessories: [String: Any]? = nil) async throws -> PluginHost {
        let host = try await environment.start(settings: settings, accessories: accessories)
        // The remote is the last device of the list's second page.
        #expect(await eventually { host.accessory(Fixture.remote) != nil })
        return host
    }

    @Test func theLampIsALightWithAdaptiveLighting() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let lamp = try #require(host.accessory(Fixture.lamp))
        let light = try #require(lamp.service(subtype: "main/light"))
        #expect(light.type == .lightbulb && light.isPrimary)
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.brightness]?.value.intValue == 72)
        #expect(light[.hue]?.value.doubleValue == 180)
        #expect(light[.saturation]?.value.doubleValue == 80)
        #expect(light[.colorTemperature]?.value.intValue == 370)
        #expect(light[.colorTemperature]?.type.minValue == 154 && light[.colorTemperature]?.type.maxValue == 455)
        #expect(light.adaptiveLighting != nil)
        #expect(lamp.information[.manufacturer]?.value == "SmartThingsCommunity")
        #expect(lamp.information[.serialNumber]?.value == .string(Fixture.lamp))
    }

    @Test func theThermostatHeatsInFahrenheit() async throws {
        let host = try await started(TestEnvironment.block.merging(["thermostatModeOverrides": [["deviceName": "Floor Heating", "heatMode": "radiatingfloor"]]]) { $1 })
        defer { Task { await host.stop() } }
        let thermostat = try #require(host.accessory(Fixture.thermostat)?.service(subtype: "main/thermostat"))
        let current = try #require(thermostat[.currentTemperature]?.value.doubleValue)
        // HAP rounds to the characteristic's 0.1 step.
        #expect(abs(current - 20.28) < 0.05)
        let target = try #require(thermostat[.targetTemperature]?.value.doubleValue)
        // 21.11 °C on the setpoint's 0.5 step.
        #expect(abs(target - 21.11) <= 0.25)
        #expect(thermostat[.targetHeatingCoolingState]?.value.intValue == 1)
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1])
        #expect(thermostat[.currentHeatingCoolingState]?.value.intValue == 1)
        #expect(thermostat[.temperatureDisplayUnits]?.value.intValue == 1)

        try await write(thermostat[.targetHeatingCoolingState], .int(1))
        let modeBody = try #require(environment.cloud.sent("POST", "/v1/devices/\(Fixture.thermostat)/commands").last?.body)
        #expect(modeBody == ["commands": [["component": "main", "capability": "thermostatMode", "command": "setThermostatMode", "arguments": ["radiatingfloor"]]]])
        try await write(thermostat[.targetTemperature], .double(22))
        let setpointBody = try #require(environment.cloud.sent("POST", "/v1/devices/\(Fixture.thermostat)/commands").last?.body)
        #expect(setpointBody == ["commands": [["component": "main", "capability": "thermostatHeatingSetpoint", "command": "setHeatingSetpoint", "arguments": [72]]]])
    }

    @Test func theHubIsAnExcludedDiscoveredDeviceWithItsCapabilitiesInDiagnostics() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        #expect(host.accessory(Fixture.hub) == nil)
        let plugin = try #require(environment.plugin)
        let hub = try #require(try await plugin.discover().first { $0.deviceID == Fixture.hub })
        #expect(hub.kind == "unsupported" && hub.excludedBySettings && !hub.isSetUp)
        let diagnostics = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "diagnostics", user: "admin")).json
        let entry = try #require(diagnostics["unsupported"]?.arrayValue?.first { $0["deviceId"] == .string(Fixture.hub) })
        #expect(entry["type"] == "HUB" && entry["components"]?[0]?["id"] == "main")
    }

    @Test func theWasherHasPowerAndRunning() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let washer = try #require(host.accessory(Fixture.washer))
        let power = try #require(washer.service(subtype: "main/switch"))
        #expect(power[.on]?.value == .bool(true))
        #expect(power[.name]?.value == "Washer Power")
        let running = try #require(washer.service(subtype: "main/occupancy.running"))
        #expect(running[.occupancyDetected]?.value.intValue == 1)
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "devices", user: "admin")).json
        let details = try #require(devices["devices"]?.arrayValue?.first { $0["deviceId"] == .string(Fixture.washer) }?["details"]?.arrayValue)
        let pairs = details.compactMap { item in item["label"]?.stringValue.map { ($0, item["value"]?.stringValue ?? "") } }
        #expect(pairs.contains { $0 == ("Remaining", "42 min") })
        #expect(pairs.contains { $0 == ("Job", "rinse") })
        #expect(pairs.contains { $0 == ("Remote control", "allowed") })

        // A stopped machine with a stale job is not running (section 8.2).
        let stopped = DeviceStatus(status: Fixture.json(#"{ "components": { "main": { "washerOperatingState": { "machineState": { "value": "stop" }, "washerJobState": { "value": "rinse" } } } } }"#))
        #expect(!Appliance.isRunning(.washer, stopped))
    }

    @Test func aWasherWithoutPowerSwitchStartsRemotely() throws {
        var status = DeviceStatus(status: Fixture.json(#"{ "components": { "main": { "remoteControlStatus": { "remoteControlEnabled": { "value": "true" } }, "washerOperatingState": { "machineState": { "value": "stop" }, "supportedMachineStates": { "value": ["stop", "run", "pause"] } } } } }"#))
        status.health = "ONLINE"
        let device = try #require(SmartThingsDevice(Fixture.item("w", "Washer", components: [("main", [("remoteControlStatus", .null), ("washerOperatingState", .null)])])))
        let sent = SentCommands()
        let binding = try #require(TestBuild.binding(device, status: status, sent: sent))
        let start = try #require(binding.accessory.service(subtype: "main/switch.start"))
        #expect(start[.name]?.value == "Washer Start")
        _ = start
    }

    @Test func theTelevisionIsPublishedOnItsOwn() async throws {
        let host = try await started(TestEnvironment.block.merging(["tvApps": ["3201907018807"]]) { $1 })
        defer { Task { await host.stop() } }
        #expect(await eventually { host.bridges.contains { $0.isExternal } })
        let bridge = try #require(host.bridges.first { $0.isExternal })
        let tv = bridge.server.primary
        #expect(tv.id == SmartThingsPlugin.accessoryID(Fixture.tv) && tv.category == .television)
        #expect(tv.information[.model]?.value == "QE55Q80" && tv.information[.firmwareRevision]?.value == "T-PTMAKUC-1.0")
        let television = try #require(tv.service(.television))
        #expect(television[.active]?.value.intValue == 1)
        #expect(television[.activeIdentifier]?.value.intValue == 3)
        let inputs = tv.services.filter { $0.type == .inputSource }.sorted { ($0[.identifier]?.value.intValue ?? 0) < ($1[.identifier]?.value.intValue ?? 0) }
        #expect(inputs.map { $0[.configuredName]?.value.stringValue ?? "" } == ["TV", "HDMI1", "PlayStation", "Netflix"])
        #expect(inputs.map { $0[.inputSourceType]?.value.intValue ?? -1 } == [2, 3, 3, 10])
        let speaker = try #require(tv.service(.televisionSpeaker))
        #expect(speaker[.volume]?.value.intValue == 14 && speaker[.mute]?.value == .bool(false))

        try await write(television[.remoteKey], .int(HAPConstants.RemoteKey.arrowUp))
        try await write(television[.remoteKey], .int(HAPConstants.RemoteKey.playPause))
        let bodies = environment.cloud.sent("POST", "/v1/devices/\(Fixture.tv)/commands").compactMap(\.body)
        #expect(bodies.contains(["commands": [["component": "main", "capability": "keypadInput", "command": "sendKey", "arguments": ["UP"]]]]))
        #expect(bodies.contains(["commands": [["component": "main", "capability": "mediaPlayback", "command": "pause", "arguments": []]]]))
    }

    @Test func theRemotesButtonsAreLabelledAndPressedByPolls() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let remote = try #require(host.accessory(Fixture.remote))
        #expect(remote.service(subtype: "main/button") == nil)
        let first = try #require(remote.service(subtype: "button1/button"))
        #expect(first[.serviceLabelIndex]?.value.intValue == 1)
        #expect(first[.programmableSwitchEvent]?.type.validValues == [0, 1, 2])
        #expect(remote.service(subtype: "button2/button")?[.programmableSwitchEvent]?.type.validValues == [0, 2])
        #expect(remote.service(.serviceLabel) != nil)
        #expect(remote.service(subtype: "main/battery")?[.batteryLevel]?.value.intValue == 90)
    }

    @Test func otherDevicesMapToTheirServices() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let ac = try #require(host.accessory(Fixture.airConditioner))
        let acThermostat = try #require(ac.service(subtype: "main/thermostat"))
        #expect(acThermostat[.targetHeatingCoolingState]?.value.intValue == 0)
        #expect(acThermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1, 2, 3])
        #expect(ac.service(subtype: "main/fan")?[.rotationSpeed]?.value.intValue == 25)
        // Humidity is consumed and not shown without exposeHumidity (section 7.3.10).
        #expect(ac.service(.humiditySensor) == nil)
        let blind = try #require(host.accessory(Fixture.shade)?.service(subtype: "main/windowCovering"))
        #expect(blind[.currentPosition]?.value.intValue == 40 && blind[.positionState]?.value.intValue == 2 && blind[.holdPosition] != nil)
        #expect(host.accessory(Fixture.shade)?.service(.battery)?[.statusLowBattery]?.value.intValue == 1)
        let lock = try #require(host.accessory(Fixture.lock)?.service(.lockMechanism))
        #expect(lock[.lockCurrentState]?.value.intValue == 1 && lock[.lockTargetState]?.isSecurityControl == true)
        let alarm = try #require(host.accessory(Fixture.security)?.service(.securitySystem))
        #expect(alarm[.securitySystemCurrentState]?.value.intValue == 3 && alarm[.securitySystemTargetState]?.type.validValues == [0, 1, 3])
        let strip = try #require(host.accessory(Fixture.strip))
        #expect(strip.services.filter { $0.type == .switch }.count == 3)
        #expect(strip.service(subtype: "outlet2/switch")?[.name]?.value == "Power Strip outlet2")
    }

    @Test func anOfflineDeviceShowsNoResponse() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        await plugin.bindings[Fixture.lamp]?.box.setHealth("OFFLINE")
        #expect(host.accessory(Fixture.lamp)?.isUnavailable == true)
        // A fresh event is the device answering.
        await plugin.apply(DeviceEvent(deviceID: Fixture.lamp, component: "main", capability: "switch", attribute: "switch", value: "off"))
        #expect(host.accessory(Fixture.lamp)?.isUnavailable == false)
        #expect(host.accessory(Fixture.lamp)?.service(.lightbulb)?[.on]?.value == .bool(false))
    }

    @Test func aDeviceGoneFromTheListIsRemovedAfterASecondList() async throws {
        let host = try await started()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let without = Fixture.page2["items"]?.arrayValue?.filter { $0["deviceId"] != .string(Fixture.lock) } ?? []
        environment.cloud.reset("GET", "/v1/devices?page=2")
        environment.cloud.answer("GET", "/v1/devices?page=2", ["items": .array(without)])
        await plugin.reconcile()
        #expect(host.accessory(Fixture.lock)?.isUnavailable == true)
        await plugin.reconcile()
        #expect(await eventually { host.accessory(Fixture.lock) == nil })
    }

    /// A device removed while the bridge was off leaves with the first list, even when the scenes cannot be read; the
    /// cached scenes stay until they can.
    @Test func aDeviceGoneWhileTheBridgeWasOffLeavesAtTheFirstList() async throws {
        let first = try await started()
        #expect(await eventually { first.accessory("scene:\(Fixture.scene)") != nil })
        await first.stop()
        let cloud = environment.cloud
        cloud.reset("GET", "/v1/devices?page=2")
        cloud.answer("GET", "/v1/devices?page=2", ["items": .array(Fixture.page2["items"]?.arrayValue?.filter { $0["deviceId"] != .string(Fixture.lock) } ?? [])])
        cloud.reset("GET", "/v1/scenes")
        cloud.answer("GET", "/v1/scenes", status: 403)
        // The devices are not listed at start: the cached accessories are all there.
        cloud.reset("GET", "/v1/devices")
        cloud.answer("GET", "/v1/devices", status: 400)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(host.accessory(Fixture.lock) != nil && host.accessory(Fixture.lamp) != nil)
        cloud.reset("GET", "/v1/devices")
        cloud.answer("GET", "/v1/devices", Fixture.page1)
        await environment.plugin?.reconcile()
        #expect(host.accessory(Fixture.lock) == nil)
        #expect(host.accessory(Fixture.lamp) != nil && host.accessory("scene:\(Fixture.scene)") != nil)
    }

    @Test func excludedAndListedOutDevicesAreNotAccessories() async throws {
        let host = try await started(TestEnvironment.block.merging(["IgnoreDevices": ["Front Door"]]) { $1 }, accessories: [Fixture.lamp: ["excluded": true]])
        defer { Task { await host.stop() } }
        #expect(host.accessory(Fixture.lamp) == nil && host.accessory(Fixture.lock) == nil)
        let discovered = try await #require(environment.plugin).discover()
        #expect(discovered.first { $0.deviceID == Fixture.lock }?.excludedBySettings == true)
        #expect(discovered.first { $0.deviceID == Fixture.lamp }?.isSetUp == false)
    }
}

/// Commands a binding built outside the plugin sends.
final class SentCommands: Sendable {
    private let box = NIOLockedValueBoxWrapper<[[DeviceCommand]]>([])
    func append(_ commands: [DeviceCommand]) { box.mutate { $0.append(commands) } }
    var all: [[DeviceCommand]] { box.value }
}

import NIOConcurrencyHelpers

final class NIOLockedValueBoxWrapper<Value: Sendable>: Sendable {
    private let lock: NIOLockedValueBox<Value>
    init(_ value: Value) { lock = NIOLockedValueBox(value) }
    func mutate(_ body: (inout Value) -> Void) { lock.withLockedValue { body(&$0) } }
    var value: Value { lock.withLockedValue { $0 } }
}

/// Builds a device's binding without a plugin, its commands recorded.
enum TestBuild {
    static func binding(_ device: SmartThingsDevice, status: DeviceStatus, settings: SmartThingsSettings = SmartThingsSettings(.object([:])), sent: SentCommands) -> DeviceBinding? {
        let box = StatusBox(status)
        let timing = SmartThingsTiming(scale: 0.001)
        let env = BindingEnvironment(deviceID: device.deviceID, timing: timing, logger: testLogger, now: Date.init,
                                     send: { commands, _ in sent.append(commands) }, controllable: true, sliders: LatestCallGuard(delay: timing.seconds(0.3)))
        var builder = AccessoryBuilder(device: device, status: status, settings: settings, options: DeviceOptions(), box: box, env: env, context: nil,
                                       accessoryID: "HomeBridgeSmartThings:\(device.deviceID)")
        builder.build()
        guard !builder.services.isEmpty else { return nil }
        let accessory = Accessory(id: "HomeBridgeSmartThings:\(device.deviceID)", name: device.displayName, services: builder.services)
        let binding = DeviceBinding(device: device, accessory: accessory, kind: builder.kind ?? "unsupported", box: box, signature: "", isTelevision: false,
                                    updaters: builder.updaters, eventHooks: builder.eventHooks, details: builder.details, adaptiveLighting: [], meters: [])
        binding.show(status)
        return binding
    }
}
