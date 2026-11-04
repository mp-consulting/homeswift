import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSwitchBot

/// The plugin on a bridge, against a fake cloud.
@Suite(.timeLimit(.minutes(1)))
struct SwitchBotPluginTests {
    let environment = TestEnvironment()

    static let meter = "SwitchBot:C271111EC0AB-Meter"
    static let curtain = "SwitchBot:E2F6032048AB-Curtain"
    static let bot = "SwitchBot:D1A2B3C4D5E6-Bot"
    static let plug = "SwitchBot:6055F92F0A1B-Plug Mini (US)"
    static let hub = "SwitchBot:FA7310762361-Hub 2"

    func statuses() {
        environment.cloud.setStatus("C271111EC0AB", #"{"deviceId":"C271111EC0AB","deviceType":"Meter","hubDeviceId":"FA7310762361","humidity":52,"temperature":26.1,"battery":87,"version":"V3.1"}"#)
        environment.cloud.setStatus("E2F6032048AB", #"{"deviceId":"E2F6032048AB","deviceType":"Curtain","calibrate":true,"group":false,"moving":false,"slidePosition":30,"battery":9,"lightLevel":"dim"}"#)
        environment.cloud.setStatus("D1A2B3C4D5E6", #"{"deviceId":"D1A2B3C4D5E6","deviceType":"Bot","power":"on","battery":100}"#)
        environment.cloud.setStatus("6055F92F0A1B", #"{"deviceId":"6055F92F0A1B","deviceType":"Plug Mini (US)","power":"off","voltage":120.1,"weight":0,"electricityOfDay":3,"electricCurrent":0}"#)
    }

    @Test func everyListedDeviceBecomesAnAccessory() async throws {
        let host = try await environment.start()
        #expect(await eventually { [Self.meter, Self.curtain, Self.bot, Self.plug, Self.hub].allSatisfy { host.accessory($0) != nil } })
        let meter = try #require(host.accessory(Self.meter))
        #expect(meter.information.characteristic(.manufacturer).value == "SwitchBot")
        #expect(meter.information.characteristic(.model).value == "SwitchBot MeterTH S1")
        #expect(meter.information.characteristic(.serialNumber).value == "C271111EC0AB")
        #expect(meter.service(.temperatureSensor) != nil && meter.service(.humiditySensor) != nil && meter.service(.battery) != nil)
        #expect(host.accessory(Self.bot)?.service(.switch)?.isPrimary == true)
        #expect(host.accessory(Self.plug)?.service(.outlet) != nil)
        let hub = try #require(host.accessory(Self.hub))
        #expect(hub.service(.lightSensor) != nil && hub.service(.battery) == nil)
        // The remotes: the TV on its own server, the air conditioner on the bridge.
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.entries["02-202008110034-13-TV"] != nil })
        let tv = try #require(await plugin.entries["02-202008110034-13-TV"]?.hap)
        #expect(tv.service(.television) != nil && tv.service(.televisionSpeaker) != nil)
        #expect(host.accessory("SwitchBot:02-202102220012-55-Air Conditioner")?.service(.heaterCooler) != nil)
        await host.stop()
    }

    @Test func aListExposesOnlyWhatItNames() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [
            ["deviceId": "C271111EC0AB", "configDeviceType": "Meter", "webhook": true, "hide_humidity": true],
            ["deviceId": "E2F6032048AB", "configDeviceType": "Curtain", "setOpenMode": "1", "set_minStep": 5],
            ["deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "type": "outlet", "mode": "press"],
        ]]
        let host = try await environment.start(settings)
        #expect(await eventually { [Self.meter, Self.curtain, Self.bot].allSatisfy { host.accessory($0) != nil } })
        #expect(await eventually { host.accessory("SwitchBot:02-202102220012-55-Air Conditioner") != nil })
        #expect(host.accessory(Self.plug) == nil && host.accessory(Self.hub) == nil)
        #expect(host.accessory(Self.meter)?.service(.humiditySensor) == nil)
        #expect(host.accessory(Self.bot)?.service(.outlet) != nil)
        await host.stop()
    }

    @Test func statusesReachHomeKit() async throws {
        statuses()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Self.meter)?.service(.temperatureSensor)?[.currentTemperature]?.value.near(26.1) == true })
        let meter = try #require(host.accessory(Self.meter))
        #expect(meter.service(.humiditySensor)?[.currentRelativeHumidity]?.value.near(52) == true)
        #expect(meter.service(.battery)?[.batteryLevel]?.value == .int(87))
        #expect(meter.service(.battery)?[.statusLowBattery]?.value == .int(0))
        #expect(meter.information.characteristic(.firmwareRevision).value == "3.1")
        #expect(await eventually { host.accessory(Self.curtain)?.service(.windowCovering)?[.currentPosition]?.value == .int(70) })
        let curtain = try #require(host.accessory(Self.curtain))
        #expect(curtain.service(.windowCovering)?[.targetPosition]?.value == .int(70))
        #expect(curtain.service(.windowCovering)?[.positionState]?.value == .int(2))
        #expect(curtain.service(.battery)?[.statusLowBattery]?.value == .int(1))
        #expect(curtain.service(.lightSensor)?[.currentAmbientLightLevel]?.value.near(1) == true)
        #expect(await eventually { host.accessory(Self.bot)?.service(.switch)?[.on]?.value == .bool(true) })
        #expect(host.accessory(Self.plug)?.service(.outlet)?[.on]?.value == .bool(false))
        await host.stop()
    }

    @Test func curtainWritesSendItsPositions() async throws {
        statuses()
        var settings = TestEnvironment.keys
        settings["options"] = ["deviceConfig": ["Curtain": ["setOpenMode": "1"]]]
        let host = try await environment.start(settings)
        #expect(await eventually { host.accessory(Self.curtain)?.service(.windowCovering)?[.currentPosition]?.value == .int(70) })
        let target = try #require(host.accessory(Self.curtain)?.service(.windowCovering)?[.targetPosition])
        try await target.write(.int(100))
        #expect(await eventually { environment.cloud.commands(to: "E2F6032048AB").contains(Command(command: "setPosition", parameter: "0,1,0")) })
        try await target.write(.int(20))
        #expect(await eventually { environment.cloud.commands(to: "E2F6032048AB").contains(Command(command: "setPosition", parameter: "0,ff,80")) })
        await host.stop()
    }

    @Test func botAndPlugCommands() async throws {
        statuses()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Self.plug)?.service(.outlet) != nil && host.accessory(Self.bot) != nil })
        try await host.accessory(Self.plug)!.service(.outlet)![.on]!.write(.bool(true))
        #expect(await eventually { environment.cloud.commands(to: "6055F92F0A1B") == [Command(command: "turnOn")] })
        #expect(await eventually { host.accessory(Self.bot)?.service(.switch)?[.on]?.value == .bool(true) })
        try await host.accessory(Self.bot)!.service(.switch)![.on]!.write(.bool(false))
        #expect(await eventually { environment.cloud.commands(to: "D1A2B3C4D5E6") == [Command(command: "turnOff")] })
        await host.stop()
    }

    @Test func lightsCoalesceAndConvert() async throws {
        environment.cloud.state.withLockedValue {
            $0.list = ["statusCode": 100, "body": ["deviceList": [["deviceId": "A1B2C3D4E5F6", "deviceName": "Bulb", "deviceType": "Color Bulb", "hubDeviceId": "000000000000"]]]]
        }
        environment.cloud.setStatus("A1B2C3D4E5F6", #"{"deviceId":"A1B2C3D4E5F6","deviceType":"Color Bulb","power":"on","brightness":80,"color":"255:0:0","colorTemperature":4000}"#)
        let host = try await environment.start(TestEnvironment.keys, timeScale: 0.01)
        let id = "SwitchBot:A1B2C3D4E5F6-Color Bulb"
        #expect(await eventually { host.accessory(id)?.service(.lightbulb)?[.brightness]?.value == .int(80) })
        let light = try #require(host.accessory(id)?.service(.lightbulb))
        #expect(light[.on]?.value == .bool(true) && light[.hue]?.value.near(0) == true && light[.saturation]?.value.near(100) == true)
        #expect(light[.colorTemperature]?.value == .int(250))
        #expect(light.adaptiveLighting != nil)
        // A drag: one command.
        async let a: Void = light[.brightness]!.write(.int(30))
        async let b: Void = light[.brightness]!.write(.int(40))
        async let c: Void = light[.brightness]!.write(.int(50))
        _ = try await (a, b, c)
        #expect(await eventually { environment.cloud.commands(to: "A1B2C3D4E5F6").contains(Command(command: "setBrightness", parameter: "50")) })
        #expect(environment.cloud.commands(to: "A1B2C3D4E5F6").filter { $0.command == "setBrightness" }.count == 1)
        async let hue: Void = light[.hue]!.write(.int(120))
        async let saturation: Void = light[.saturation]!.write(.int(100))
        _ = try await (hue, saturation)
        #expect(await eventually { environment.cloud.commands(to: "A1B2C3D4E5F6").contains(Command(command: "setColor", parameter: "0:255:0")) })
        try await light[.colorTemperature]!.write(.int(370))
        #expect(await eventually { environment.cloud.commands(to: "A1B2C3D4E5F6").contains(Command(command: "setColorTemperature", parameter: "2703")) })
        await host.stop()
    }

    @Test func adaptiveLightingTurnsOffOnAWhiteSetElsewhere() async throws {
        environment.cloud.state.withLockedValue {
            $0.list = ["statusCode": 100, "body": ["deviceList": [["deviceId": "C0FFEE000001", "deviceName": "Ceiling", "deviceType": "Ceiling Light", "hubDeviceId": "000000000000"]]]]
        }
        environment.cloud.setStatus("C0FFEE000001", #"{"power":"on","brightness":60,"colorTemperature":4000}"#)
        let host = try await environment.start()
        let id = "SwitchBot:C0FFEE000001-Ceiling Light"
        #expect(await eventually { host.accessory(id)?.service(.lightbulb)?[.on]?.value == .bool(true) })
        let light = try #require(host.accessory(id)?.service(.lightbulb))
        #expect(light[.hue] == nil)
        let controller = try #require(light.adaptiveLighting)
        try controller.activateForTesting()
        #expect(controller.isAdaptiveLightingActive)
        environment.cloud.setStatus("C0FFEE000001", #"{"power":"on","brightness":60,"colorTemperature":2700}"#)
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        await host.stop()
    }

    @Test func anUnreachableDeviceShowsNoResponse() async throws {
        statuses()
        environment.cloud.state.withLockedValue { $0.unreachable = ["6055F92F0A1B"] }
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Self.plug)?.isUnavailable == true })
        environment.cloud.state.withLockedValue { $0.unreachable = [] }
        #expect(await eventually { host.accessory(Self.plug)?.isUnavailable == false })
        await host.stop()
    }

    @Test func webhookEventsReachTheDevicesThatTakeThem() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = [
            "webhookURL": "http://192.168.1.10:8790/switchbot",
            "deviceConfig": ["Meter": ["webhook": true], "Curtain": ["webhook": true]],
        ]
        let host = try await environment.start(settings, timeScale: 1)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.webhookListeningPort != nil })
        #expect(await eventually { environment.cloud.state.withLockedValue { $0.webhookActions.contains("updateWebhook") } })
        let port = try #require(await plugin.webhookListeningPort)
        let path = await plugin.webhookAddress(URL(string: "http://192.168.1.10:8790/switchbot")!).path
        #expect(path.hasPrefix("/switchbot/") && path.count > 40)
        let http = HTTPClient()
        func post(_ path: String, _ body: String, method: String = "POST") async throws -> NetResponse {
            try await http.send(NetRequest(method: method, url: URL(string: "http://127.0.0.1:\(port)\(path)")!, body: Data(body.utf8)))
        }
        #expect(try await post("/switchbot", "{}").status == 403)
        #expect(try await post(path, "{}", method: "GET").status == 403)
        let meterEvent = #"{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoMeter","deviceMac":"C271111EC0AB","temperature":78.8,"scale":"FAHRENHEIT","humidity":50,"battery":90,"timeOfSample":1730700000000}}"#
        let answer = try await post(path, meterEvent)
        #expect(answer.status == 200 && String(decoding: answer.body, as: UTF8.self) == "OK")
        #expect(await eventually { host.accessory(Self.meter)?.service(.temperatureSensor)?[.currentTemperature]?.value.near(26) == true })
        _ = try await post(path, #"{"eventType":"changeReport","context":{"deviceType":"WoCurtain","deviceMac":"E2F6032048AB","slidePosition":50,"battery":100}}"#)
        #expect(await eventually { host.accessory(Self.curtain)?.service(.windowCovering)?[.currentPosition]?.value == .int(50) })
        // The plug does not take webhooks.
        _ = try await post(path, #"{"eventType":"changeReport","context":{"deviceType":"WoPlugUS","deviceMac":"6055F92F0A1B","powerState":"ON"}}"#)
        #expect(try await post(path, String(repeating: "x", count: 70 * 1024)).status == 413)
        #expect(host.accessory(Self.plug)?.service(.outlet)?[.on]?.value == .bool(false))
        await host.stop()
        #expect(environment.cloud.state.withLockedValue { $0.webhookActions.contains("deleteWebhook") })
    }

    @Test func sensorWebhookContexts() async throws {
        let entry = DeviceInfo(id: "D8C1A2B3C4D5", deviceID: "D8C1A2B3C4D5-Contact Sensor", type: "Contact Sensor", name: "Door", options: DeviceOptions(), isRemote: false, firmware: "1.0")
        let contact = SensorAccessory(info: entry, family: .contact, co2Threshold: 1000, link: DeviceLink { _ in true }, debounce: .zero, logger: testLogger)
        let fields = try JSONValue(string: #"{"deviceType":"WoContact","deviceMac":"D8C1A2B3C4D5","detectionState":"DETECTED","doorMode":"IN_DOOR","brightness":"bright","openState":"timeOutNotClose","battery":80}"#)
        contact.show(fields.objectValue!, webhook: true)
        #expect(contact.contact?[.contactSensorState]?.value == .int(1))
        #expect(contact.motion?[.motionDetected]?.value == .bool(true))
        #expect(contact.lightSensor?[.currentAmbientLightLevel]?.value.near(6001) == true)
        let lockInfo = DeviceInfo(id: "F1E2D3C4B5A6", deviceID: "F1E2D3C4B5A6-Smart Lock", type: "Smart Lock", name: "Front", options: DeviceOptions(), isRemote: false, firmware: "1.0")
        let lock = LockAccessory(info: lockInfo, link: DeviceLink { _ in true }, debounce: .zero, logger: testLogger)
        lock.show(["lockState": "locked", "doorState": "closed", "battery": 64], webhook: false)
        #expect(lock.mechanism[.lockCurrentState]?.value == .int(1) && lock.mechanism[.lockTargetState]?.value == .int(1))
        #expect(lock.contact?[.contactSensorState]?.value == .int(0))
        lock.show(["lockState": "JAMMED", "battery": 50], webhook: true)
        #expect(lock.mechanism[.lockCurrentState]?.value == .int(2))
        #expect(lock.latch?[.on]?.isSecurityControl == true)
    }

    @Test func humidifierAndBlindTiltStatuses() async throws {
        let humidifier = HumidifierAccessory(
            info: DeviceInfo(id: "500291B269BE", deviceID: "500291B269BE-Humidifier", type: "Humidifier", name: "Humidifier", options: DeviceOptions(), isRemote: false, firmware: "1"),
            link: DeviceLink { _ in true }, debounce: .zero, logger: testLogger)
        humidifier.show(try JSONValue(string: #"{"power":"on","humidity":45,"temperature":22.5,"nebulizationEfficiency":60,"auto":false,"childLock":false,"sound":true,"lackWater":false}"#).objectValue!, webhook: false)
        #expect(humidifier.humidifier[.active]?.value == .int(1))
        #expect(humidifier.humidifier[.targetHumidifierDehumidifierState]?.value == .int(1))
        #expect(humidifier.humidifier[.relativeHumidityHumidifierThreshold]?.value.near(60) == true)
        #expect(humidifier.humidifier[.currentHumidifierDehumidifierState]?.value == .int(2))
        #expect(humidifier.humidifier[.waterLevel]?.value.near(100) == true)

        let sent = SentCommands()
        let blind = CoveringAccessory(
            info: DeviceInfo(id: "B0E9FE11A2C3", deviceID: "B0E9FE11A2C3-Blind Tilt", type: "Blind Tilt", name: "Blind", options: DeviceOptions(), isRemote: false, firmware: "1"),
            family: .blindTilt, link: DeviceLink { sent.append($0); return true }, debounce: .zero, updateRate: .seconds(5), logger: testLogger)
        blind.show(try JSONValue(string: #"{"calibrate":true,"battery":75,"direction":"up","slidePosition":75,"version":"V2.1"}"#).objectValue!, webhook: false)
        #expect(blind.covering[.currentPosition]?.value == .int(50))
        for (position, command) in [(100, Command(command: "fullyOpen")), (40, Command(command: "setPosition", parameter: "up;40")), (0, Command(command: "closeUp"))] {
            try await blind.covering[.targetPosition]!.write(.int(position))
            #expect(sent.all.last == command)
        }
    }
}

extension SwitchBotPluginTests {
    @Test func aBotThatOpensIsASecurityControl() {
        for (type, characteristic, secured) in [
            ("door", CharacteristicType.targetPosition, true), ("window", .targetPosition, true), ("windowcovering", .targetPosition, true),
            ("garagedoor", .targetDoorState, true), ("lock", .lockTargetState, true), ("switch", .on, false),
        ] {
            let info = DeviceInfo(id: "D1A2B3C4D5E6", deviceID: "D1A2B3C4D5E6-Bot", type: "Bot", name: "Bot", options: DeviceOptions(["type": .string(type)]), isRemote: false, firmware: "1")
            let bot = SwitchAccessory(info: info, family: .bot, link: DeviceLink { _ in true }, debounce: .zero, logger: testLogger)
            #expect(bot.control[characteristic]?.isSecurityControl == secured, "\(type)")
        }
    }

    @Test func theWebhookSegmentMovesIntoTheVault() async throws {
        // An earlier build's plain file, in the instance's storage directory.
        let storage = environment.directory.appendingPathComponent("plugins/SwitchBot-SwitchBot")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let segment = String(repeating: "a", count: 43)
        try Data(#"{"segment":"\#(segment)"}"#.utf8).write(to: storage.appendingPathComponent("webhook.json"))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        let path = await plugin.webhookAddress(URL(string: "http://h:1/switchbot/")!).path
        #expect(path == "/switchbot/\(segment)")
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("webhook.json").path))
        let again = await plugin.webhookAddress(URL(string: "http://h:1/switchbot")!).path
        #expect(again == path)
        await host.stop()
    }
}

/// The commands an accessory sent, for tests without a host.
final class SentCommands: Sendable {
    private let box = NIOLockedValueBox<[Command]>([])
    func append(_ commands: [Command]) { box.withLockedValue { $0 += commands } }
    var all: [Command] { box.withLockedValue { $0 } }
}
