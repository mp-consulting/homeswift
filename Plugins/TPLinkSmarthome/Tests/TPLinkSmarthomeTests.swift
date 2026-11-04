import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTPLinkSmarthome

/// The plugin on a host against devices of a fake LAN.
@Suite(.timeLimit(.minutes(1)))
struct TPLinkSmarthomeTests {
    let environment = TestEnvironment()

    @Test func anEnergyPlugBecomesAnOutlet() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        environment.lan.reply("emeter.get_realtime", #"{"current":0.1256,"voltage":122.05,"power":3.14,"total":51.493,"err_code":0}"#)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.hs110ID) != nil })
        let accessory = try #require(host.accessory(Fixtures.hs110ID))
        #expect(accessory.category == .outlet)
        #expect(accessory.information[.name]?.value == .string("Kitchen Kettle"))
        #expect(accessory.information[.manufacturer]?.value == .string("TP-Link"))
        #expect(accessory.information[.model]?.value == .string("HS110(US)"))
        #expect(accessory.information[.serialNumber]?.value == .string("50:C7:BF:01:02:03 \(Fixtures.hs110ID)"))
        #expect(accessory.information[.firmwareRevision]?.value == .string("1.0.8"))
        #expect(accessory.information[.hardwareRevision]?.value == .string("1.0"))
        let outlet = try #require(accessory.service(.outlet))
        #expect(outlet.isPrimary && outlet.subtype == nil)
        #expect(outlet[.on]?.value == .bool(true))
        #expect(outlet[.outletInUse] != nil)
        #expect(accessory.service(.eveHistory) != nil)
        // The first reading arrives on its own; 3.14 W is above the 0 W threshold.
        #expect(await eventually { outlet[KasaEve.watts]?.value.doubleValue == 3.1 })
        #expect(abs((outlet[KasaEve.volts]?.value.doubleValue ?? 0) - 122.05) <= 0.051)
        #expect(outlet[KasaEve.kilowattHours]?.value.doubleValue == 51.493)
        #expect(abs((outlet[KasaEve.voltAmperes]?.value.doubleValue ?? 0) - 15.3) < 0.001)
        #expect(outlet[.outletInUse]?.value == .bool(true))
        await host.stop()
    }

    @Test func aWriteReachesTheDeviceOnce() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.hs110ID) != nil })
        let on = try #require(host.accessory(Fixtures.hs110ID)?.service(.outlet)?[.on])
        let handler = try #require(on.writeHandler(for: .bool(false)))
        // Two writes within the window: one command, with the one that came last.
        async let first: Void = handler(.bool(true))
        async let second: Void = handler(.bool(false))
        _ = try await (first, second)
        let relays = environment.lan.commands("set_relay_state")
        #expect(relays.count == 1)
        let sent = relays.first?.json == #"{"system":{"set_relay_state":{"state":1}}}"#
        #expect(relays.first?.json.hasPrefix(#"{"system":{"set_relay_state":{"state":"#) == true)
        #expect(on.value == .bool(sent))
        #expect(relays.first?.host == "192.168.1.20" && relays.first?.port == 9999)
        await host.stop()
    }

    @Test func aChangeOnTheDeviceReachesHomeKit() async throws {
        environment.lan.put(Fixtures.hs200, at: "192.168.1.21")
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.hs200ID) != nil })
        let accessory = try #require(host.accessory(Fixtures.hs200ID))
        // HS200 is in the default switchModels.
        #expect(accessory.category == .switch)
        let on = try #require(accessory.service(.switch)?[.on])
        #expect(on.value == .bool(false))
        #expect(accessory.service(.switch)?[KasaEve.watts] == nil)
        environment.lan.remove(at: "192.168.1.21")
        environment.lan.put(Fixtures.hs200.replacingOccurrences(of: #""relay_state":0"#, with: #""relay_state":1"#), at: "192.168.1.22")
        // The next round's reply, from a new address: followed.
        #expect(await eventually { on.value == .bool(true) })
        try await write(on, .bool(false))
        #expect(environment.lan.commands("set_relay_state").last?.host == "192.168.1.22")
        await host.stop()
    }

    @Test func aStripIsItsOutlets() async throws {
        environment.lan.put(Fixtures.hs300(shortIDs: true), at: "192.168.1.30")
        let host = try await environment.start()
        let ids = (0..<6).map { Fixtures.hs300ID + String(format: "%02d", $0) }
        #expect(await eventually { ids.allSatisfy { host.accessory($0) != nil } })
        #expect(host.accessory(Fixtures.hs300ID) == nil)
        let lamp = try #require(host.accessory(ids[1]))
        #expect(lamp.information[.name]?.value == .string("Lamp"))
        #expect(lamp.information[.model]?.value == .string("HS300(US)"))
        #expect(lamp.information[.serialNumber]?.value == .string("B0:BE:76:11:22:33 \(ids[1])"))
        #expect(host.accessory(ids[0])?.service(.outlet)?[.on]?.value == .bool(true))
        let on = try #require(lamp.service(.outlet)?[.on])
        try await write(on, .bool(true))
        #expect(environment.lan.commands("set_relay_state").map(\.json) == [#"{"system":{"set_relay_state":{"state":1}},"context":{"child_ids":["\#(ids[1])"]}}"#])
        #expect(on.value == .bool(true))
        // Each outlet meters on its own.
        await environment.plugin?.pollEnergy()
        #expect(environment.lan.commands("get_realtime").contains { $0.json.contains(ids[5]) })
        await host.stop()
    }

    @Test func aDimmerIsALightbulb() async throws {
        environment.lan.put(Fixtures.hs220, at: "192.168.1.40")
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.hs220ID) != nil })
        let light = try #require(host.accessory(Fixtures.hs220ID)?.service(.lightbulb))
        #expect(light[.brightness]?.value == .int(50))
        #expect(light[.colorTemperature] == nil)
        try await write(light[.brightness], .int(30))
        #expect(environment.lan.commands("set_brightness").map(\.json) == [#"{"smartlife.iot.dimmer":{"set_brightness":{"brightness":30}}}"#])
        try await write(light[.brightness], .int(0))
        #expect(environment.lan.commands("set_relay_state").map(\.json) == [#"{"system":{"set_relay_state":{"state":0}}}"#])
        await host.stop()
    }

    @Test func aColourBulbWithAdaptiveLighting() async throws {
        environment.lan.put(Fixtures.lb130(), at: "192.168.1.50")
        environment.lan.reply(
            "smartlife.iot.smartbulb.lightingservice.transition_light_state",
            #"{"on_off":1,"mode":"normal","hue":0,"saturation":0,"color_temp":4000,"brightness":80,"err_code":0}"#)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.lb130ID) != nil })
        let accessory = try #require(host.accessory(Fixtures.lb130ID))
        #expect(accessory.information[.serialNumber]?.value == .string("50C7BF445566 \(Fixtures.lb130ID)"))
        let light = try #require(accessory.service(.lightbulb))
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.brightness]?.value == .int(60))
        #expect(light[.hue]?.value.doubleValue == 120)
        #expect(light[.saturation]?.value.doubleValue == 80)
        #expect(light[.colorTemperature]?.type.minValue == 112)
        #expect(light[.colorTemperature]?.type.maxValue == 400)
        #expect(light[.colorTemperature]?.value == .int(400))
        #expect(light[KasaEve.watts] != nil)
        #expect(light[KasaEve.volts] == nil)

        // Brightness and a white in one moment: one command.
        let setBrightness = try #require(light[.brightness]?.writeHandler(for: .int(80)))
        let setWhite = try #require(light[.colorTemperature]?.writeHandler(for: .int(250)))
        async let brightness: Void = setBrightness(.int(80))
        async let white: Void = setWhite(.int(250))
        _ = try await (brightness, white)
        #expect(environment.lan.commands("transition_light_state").map(\.json) == [
            #"{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"brightness":80,"color_temp":4000}}}"#,
        ])
        #expect(light[.colorTemperature]?.value == .int(250))

        // A hue is a colour.
        try await write(light[.hue], .double(200))
        #expect(environment.lan.commands("transition_light_state").last?.json == #"{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"hue":200,"color_temp":0}}}"#)

        // Adaptive Lighting: on, then a colour set in the Kasa app turns it off. Its writes answer what the bulb shows.
        environment.lan.reply("smartlife.iot.smartbulb.lightingservice.transition_light_state", #"{"on_off":1,"brightness":60,"err_code":0}"#)
        let lighting = await environment.plugin?.adaptiveLighting[Fixtures.lb130ID]
        let controller = try #require(lighting)
        try controller.activateForTesting()
        #expect(controller.isAdaptiveLightingActive)
        environment.lan.put(Fixtures.lb130(light: #"{"on_off":1,"mode":"normal","hue":10,"saturation":90,"color_temp":0,"brightness":60}"#), at: "192.168.1.50")
        // Once the bridge's own writes have settled (3 of the tests' seconds), the next round's report turns it off.
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        await host.stop()
    }

    @Test func anOffBulbReadsItsDefaults() async throws {
        environment.lan.put(Fixtures.lb120Off, at: "192.168.1.51")
        environment.lan.put(Fixtures.kl430Off, at: "192.168.1.52")
        environment.lan.reply("smartlife.iot.lightStrip.set_light_state", #"{"on_off":1,"mode":"normal","err_code":0}"#)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.lb120ID) != nil && host.accessory(Fixtures.kl430ID) != nil })
        let bulb = try #require(host.accessory(Fixtures.lb120ID)?.service(.lightbulb))
        #expect(bulb[.on]?.value == .bool(false))
        #expect(bulb[.brightness]?.value == .int(100))
        #expect(bulb[.colorTemperature]?.value == .int(370))
        #expect(bulb[.colorTemperature]?.type.minValue == 154)
        #expect(bulb[.hue] == nil)
        // A light strip's commands go to its own module.
        let strip = try #require(host.accessory(Fixtures.kl430ID)?.service(.lightbulb))
        #expect(strip[.colorTemperature]?.value == .int(112))
        try await write(strip[.on], .bool(true))
        #expect(environment.lan.commands("set_light_state").map(\.json) == [#"{"smartlife.iot.lightStrip":{"set_light_state":{"ignore_default":1,"on_off":1}}}"#])
        #expect(strip[.on]?.value == .bool(true))
        await host.stop()
    }

    @Test func aSilentDeviceShowsNoResponseThenComesBack() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        let host = try await environment.start(settings: ["pollingInterval": 1, "emeterPollingInterval": 0])
        #expect(await eventually { host.accessory(Fixtures.hs110ID) != nil })
        let accessory = try #require(host.accessory(Fixtures.hs110ID))
        #expect(!accessory.isUnavailable)
        environment.lan.silence("192.168.1.20")
        #expect(await eventually { accessory.isUnavailable })
        let found = try await environment.plugin?.discover()
        #expect(found?.first { $0.deviceID == Fixtures.hs110ID }?.isReachable == false)
        environment.lan.silence("192.168.1.20", false)
        #expect(await eventually { !accessory.isUnavailable })
        await host.stop()
    }

    @Test func discoveryGoesToTheBroadcastAndTheListedHosts() async throws {
        let host = try await environment.start(settings: ["broadcast": "10.0.0.255", "devices": [["host": "10.0.1.7", "port": "10007"], ["host": "10.0.1.8"]]])
        #expect(await eventually { environment.lan.packets.count >= 3 })
        let packets = Array(environment.lan.packets.prefix(3))
        #expect(packets.map(\.host) == ["10.0.0.255", "10.0.1.7", "10.0.1.8"])
        #expect(packets.map(\.port) == [9999, 10007, 9999])
        #expect(packets.allSatisfy { $0.json == #"{"system":{"get_sysinfo":{}}}"# })
        await host.stop()
    }

    @Test func commandsGoToTheReplysPortWhenAsked() async throws {
        // A device behind a port forward: its reply comes from the outside port.
        environment.lan.put(Fixtures.hs200, at: "203.0.113.9")
        let host = try await environment.start(settings: ["devicesUseDiscoveryPort": true, "devices": [["host": "203.0.113.9", "port": 20002]]])
        #expect(await eventually { host.accessory(Fixtures.hs200ID) != nil })
        try await write(host.accessory(Fixtures.hs200ID)?.service(.switch)?[.on], .bool(true))
        #expect(environment.lan.commands("set_relay_state").last.map { "\($0.host):\($0.port)" } == "203.0.113.9:20002")
        await host.stop()
    }

    @Test func filtersLeaveDevicesOut() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        environment.lan.put(Fixtures.hs200, at: "192.168.1.21")
        environment.lan.put(Fixtures.lb120Off, at: "192.168.1.51")
        let host = try await environment.start(settings: ["excludeMacAddresses": ["50:c7:bf:04:*"], "deviceTypes": ["plug"]])
        #expect(await eventually { host.accessory(Fixtures.hs110ID) != nil })
        #expect(await eventually { await environment.plugin?.round ?? 0 >= 2 })
        #expect(host.accessory(Fixtures.hs200ID) == nil)
        #expect(host.accessory(Fixtures.lb120ID) == nil)
        let found = try await environment.plugin?.discover() ?? []
        #expect(found.first { $0.deviceID == Fixtures.hs200ID }?.excludedBySettings == true)
        #expect(found.first { $0.deviceID == Fixtures.hs110ID }?.isSetUp == true)
        #expect(found.first { $0.deviceID == Fixtures.hs110ID }?.kind == "outlet")
        await host.stop()
    }

    @Test func invalidRepliesAreIgnored() async throws {
        let host = try await environment.start()
        #expect(await eventually { environment.lan.packets.count >= 1 })
        environment.lan.deliver("not json", from: "192.168.1.99")
        environment.lan.deliver(#"{"system":{"get_sysinfo":null}}"#, from: "192.168.1.99")
        environment.lan.deliver(#"{"system":{"get_sysinfo":\#(Fixtures.hs110.replacingOccurrences(of: Fixtures.hs110ID, with: ""))}}"#, from: "192.168.1.99")
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.mainBridge.server.accessories.filter { $0.id.hasPrefix("TplinkSmarthome:") }.isEmpty)
        await host.stop()
    }

    @Test func identifyBlinksTheLED() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.hs110ID) != nil })
        let identify = try #require(host.accessory(Fixtures.hs110ID)?.information[.identify]?.writeHandler(for: .bool(true)))
        try await identify(.bool(true))
        // Once, then twice; the LED was on, so it is put back on after each.
        #expect(environment.lan.commands("set_led_off").map { $0.json.contains(#""off":0"#) ? "on" : "off" } == ["on", "off", "on", "on", "off", "on", "off", "on"])
        await host.stop()
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(TPLinkSmarthomePlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/TPLinkSmarthome TPLinkSmarthomePlugin")
        let schema = try JSONValue(string: try #require(TPLinkSmarthomePlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "TplinkSmarthome")
    }

    @Test func anAccessorysOwnThresholdWins() async throws {
        environment.lan.put(Fixtures.hs110, at: "192.168.1.20")
        environment.lan.reply("emeter.get_realtime", #"{"power_mw":4380,"err_code":0}"#)
        let host = try await environment.start(settings: ["inUseThreshold": 1, "_accessories": [Fixtures.hs110ID: ["inUseThreshold": 10]]])
        #expect(await eventually { host.accessory(Fixtures.hs110ID)?.service(.outlet)?[KasaEve.watts]?.value.doubleValue == 4.4 })
        #expect(host.accessory(Fixtures.hs110ID)?.service(.outlet)?[.outletInUse]?.value == .bool(false))
        #expect(await environment.plugin?.deviceKind(of: Fixtures.hs110ID) == "outlet")
        await host.stop()
    }
}

/// Runs the write handler of `characteristic` for `value`.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    let handler = try #require(characteristic?.writeHandler(for: value))
    try await handler(value)
}
