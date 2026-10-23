import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftGovee

let lightID = "AA:BB:CC:DD:EE:FF:00:11"
let thermoID = "F9:44:AB:CD:12:34:56:78"
let leakID = "A1:B2:C3:D4:E5:F6:A7:B8"
let poolID = "03:55:01:25:00:00:00:0E:FF:FF:00:4F:FF:FF:00:3B"

/// A host with one Govee block whose plugin talks to fakes: Govee's cloud, the LAN, AWS IoT and Bluetooth.
final class GoveeEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-govee-tests-\(UUID().uuidString)")
    let govee = FakeGovee()
    let icons = FakeGovee()
    let lan = FakeLANSocket()
    let mqtt = FakeAWSBroker()
    let central = FakeCentral()
    var bleAvailable = true
    private let plugins = NIOLockedValueBox<[GoveePlugin]>([])

    var plugin: GoveePlugin? { plugins.withLockedValue { $0.last } }

    init(devices: [JSONValue]? = nil) {
        govee.answer("app2.govee.com/account/rest/account/v2/login", ["client": ["token": "token-1", "accountId": "acc", "topic": "account-topic"]])
        govee.answer("app2.govee.com/app/v1/account/iot/key", ["data": ["endpoint": "aws.example", "p12": .string(legacyPKCS12), "p12Pass": "secret"]])
        govee.answer("app2.govee.com/device/rest/devices/v1/list", ["devices": .array(devices ?? Self.devices)])
        govee.answer("app2.govee.com/leak/rest/device/v1/warnMessage", ["data": []])
        lan.scanReplies = [(lightID, "H6008", "192.168.1.20"), ("11:22:33:44:55:66:77:88", "H6008", "192.168.1.30")]
    }

    static let devices: [JSONValue] = [
        [
            "device": .string(lightID), "sku": "H6008", "deviceName": "Desk Light", "goodsType": 7, "versionSoft": "1.2.3",
            "deviceExt": ["deviceSettings": .string(jsonText(["topic": "GD/light-topic", "bleName": "ihoment_H6008_0011", "address": "A4:C1:38:00:00:11"]))],
        ],
        [
            "device": "f944abcd12345678", "sku": "H5179", "deviceName": "Thermometer",
            "deviceExt": [
                "deviceSettings": .string(jsonText(["battery": 94, "bleName": "GVH5179_5678"])),
                "lastDeviceData": .string(jsonText(["tem": 2213, "hum": 5170, "online": true])),
            ],
        ],
        [
            "device": .string(leakID), "sku": "H5054", "deviceName": "Leak Sensor",
            "deviceExt": [
                "deviceSettings": .string(jsonText(["battery": 80])),
                "lastDeviceData": .string(jsonText(["lastTime": 1_700_000_000, "online": true, "gwonline": true])),
            ],
        ],
        [
            "device": .string(poolID), "sku": "H5310", "deviceName": "Pool",
            "deviceExt": [
                "deviceSettings": .string(jsonText(["battery": 100])),
                "lastDeviceData": .string(jsonText(["tem": 2850, "hum": 65535, "online": true])),
            ],
        ],
    ]

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: GoveePlugin.platform, name: GoveePlugin.name) { json, context in
            var dependencies = GoveePlugin.Dependencies()
            dependencies.http = self.govee
            dependencies.icons = self.icons
            let lan = self.lan
            dependencies.lanSocket = { _ in lan }
            let central = self.central
            let available = self.bleAvailable
            dependencies.bleCentral = { _ in available ? central : nil }
            let mqtt = self.mqtt
            dependencies.mqtt = { _ in mqtt }
            dependencies.history = false
            dependencies.retryDelay = .milliseconds(1)
            let plugin = GoveePlugin(configuration: try JSONDecoder().decode(GoveePlugin.Configuration.self, from: json), context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: GoveePlugin.platform, name: "Govee", settings: settings)
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        return try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry, storageDirectory: directory, options: options)
    }

    func start(_ settings: [String: Any] = ["username": "user@example.com", "password": "pw", "httpRefreshTime": 30]) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        await plugin?.settle()
        return host
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? { mainBridge.server.accessories.first { $0.id == "Govee:\(id)" } }
}

@Suite(.serialized) struct PluginTests {
    @Test func decodesARealisticBlock() throws {
        let json = #"""
        {
          "platform": "Govee", "name": "Govee", "username": "me@example.com", "password": "secret", "code": " 1234 ",
          "ignoreMatter": true, "disableDeviceLogging": "false", "debug": false, "httpRefreshTime": "60", "awsDisable": false,
          "bleDisable": 0, "bleRefreshTime": 30, "bleControlInterval": 5, "lanDisable": false, "lanRefreshTime": 20, "lanScanInterval": 90,
          "colourSafeMode": false,
          "lightDevices": [
            { "deviceId": "0c:d7:94:45:c6:25:34:ff", "label": "Outdoor Neon", "showAs": "default", "customIPAddress": "192.168.1.50",
              "adaptiveLightingShift": -1, "brightnessStep": 5, "awsBrightnessNoScale": true, "awsColourMode": "redgreenblue",
              "scenes": [{ "name": "Forest", "sceneCode": "AAA,BBB", "sceneId": 130, "kind": "scene", "iconUrl": "https://d1f2504ijhdyjw.cloudfront.net/x.png" }],
              "musicModeLive": { "enabled": true, "effect": "rolling", "sensitivity": 70, "autoColour": false, "soft": false, "protocol": "legacy" },
              "scene": { "sceneCode": "MwUEAA==", "bleCode": "MwUEAA==", "showAs": "switch" } }
          ],
          "switchDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:22", "showAs": "heater", "temperatureSource": "11:22:33:44:55:66:77:88" }],
          "thermoDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:33", "lowBattThreshold": "15", "showExtraSwitch": true }],
          "leakDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:44", "ignoreDevice": true }],
          "fanDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:55", "hideLight": true }],
          "heaterDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:66", "tempReporting": true }],
          "humidifierDevices": [], "dehumidifierDevices": [], "purifierDevices": [], "diffuserDevices": [],
          "kettleDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:77", "hideModeGreenTea": true, "showCustomMode2": true }],
          "iceMakerDevices": [{ "deviceId": "AA:BB:CC:DD:EE:FF:00:88", "label": "Ice" }],
          "_bridge": { "username": "0E:00:00:00:00:01" }
        }
        """#
        let configuration = try JSONDecoder().decode(GoveePlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.username == "me@example.com" && configuration.password == "secret" && configuration.code == "1234")
        #expect(configuration.ignoreMatter && !configuration.disableDeviceLogging && !configuration.bleDisable)
        #expect(configuration.httpRefreshTime == 60)
        #expect(configuration.bleRefreshTime == 300)   // below the minimum of 60: the default
        #expect(configuration.belowMinimum.map(\.key) == ["bleRefreshTime"])
        #expect(configuration.bleQueueInterval == .seconds(5))
        #expect(configuration.lanRefreshTime == 20 && configuration.lanScanInterval == 90)
        let devices = configuration.devices
        #expect(devices.count == 8)
        let light = try #require(devices["0C:D7:94:45:C6:25:34:FF"])
        #expect(light.list == .lightDevices && light.label == "Outdoor Neon" && light.customIPAddress == "192.168.1.50")
        #expect(light.int("adaptiveLightingShift") == -1 && light.int("brightnessStep") == 5)
        #expect(light.commandOptions == .init(awsBrightnessNoScale: true, awsColourMode: "redgreenblue"))
        #expect(light["scenes"]?[0]?["name"] == "Forest")
        #expect(devices["AA:BB:CC:DD:EE:FF:00:22"]?.temperatureSource == "11:22:33:44:55:66:77:88")
        #expect(devices["AA:BB:CC:DD:EE:FF:00:33"]?.lowBattThreshold == 15)
        #expect(devices["AA:BB:CC:DD:EE:FF:00:44"]?.ignoreDevice == true)
        #expect(GoveePlugin.Configuration(["bleControlInterval": 750]).bleQueueInterval == .milliseconds(750))
        #expect(GoveePlugin.Configuration([:]).bleQueueInterval == .milliseconds(500))
    }

    @Test func startsWithTheAccountAndTheLAN() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.started)
        let light = try #require(host.accessory(lightID))
        #expect(light.service(.lightbulb) != nil)
        #expect(light.information[.serialNumber]?.value == .string(lightID))
        #expect(light.information[.firmwareRevision]?.value == "1.2.3")
        // A bare id from the cloud gets colons.
        #expect(host.accessory(thermoID)?.service(.temperatureSensor) != nil)
        #expect(host.accessory(leakID)?.service(.leakSensor) != nil)
        // A LAN device outside the account and the configuration stays out.
        #expect(host.accessory("11:22:33:44:55:66:77:88") == nil)
        let devices = await plugin.devices
        #expect(devices[lightID]?.transports == TransportFlags(hasAWS: true, useAWS: true, hasBLE: true, useBLE: true, hasLAN: true, useLAN: true))
        #expect(devices[lightID]?.ble == BLETarget(address: "a4:c1:38:00:00:11", name: "ihoment_H6008_0011"))
        // AWS: subscribed to the account topic, and asked the light for its status.
        #expect(await eventually { environment.mqtt.published.contains { $0.topic == "GD/light-topic" && $0.payload["msg"]?["cmd"] == "status" } })
        #expect(environment.mqtt.subscribed == ["account-topic"])
        // The login and certificate are kept, owner-only.
        let storage = environment.directory.appendingPathComponent("plugins/Govee-Govee")
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("govee.pfx").path))
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("discovered-devices.json").path))
        // The settings page's list of discovered devices.
        let cached = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "cached-devices", user: "me"))
        let list = try #require(cached.json["devices"]?.arrayValue)
        #expect(list.first?["deviceType"] == "lightDevices" && list.first?["ip"] == "192.168.1.20" && list.first?["goodsType"] == 7)
        #expect(list.contains { $0["deviceId"] == "11:22:33:44:55:66:77:88" })
    }

    @Test func commandsGoOverLANThenAWSThenBLE() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        try await plugin.sendDeviceUpdate(id: lightID, .state(true))
        #expect(environment.lan.sent.last?.json == ["msg": ["cmd": "turn", "data": ["value": 1]]])
        environment.lan.failing = true
        try await plugin.sendDeviceUpdate(id: lightID, .state(false))
        #expect(environment.mqtt.published.last?.payload["msg"]?["cmd"] == "turn")
        #expect(environment.mqtt.published.last?.payload["msg"]?["data"] == ["val": 0])
        environment.mqtt.hangs = true
        try await plugin.sendDeviceUpdate(id: lightID, .brightness(50))
        #expect(await environment.central.written.map(Array.init) == [Govee.codeBytes([0x33, 0x04, 127])])
        // A command without a BLE form, when the others failed, reports the failure.
        await #expect(throws: GoveeAPIError.message(Lang.noConnMethod)) { try await plugin.sendDeviceUpdate(id: leakID, .stateOutlet(true)) }
    }

    @Test func queuedBLECommandsOfAKindCollapseToTheLatest() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start(["username": "user@example.com", "password": "pw", "lanDisable": true, "awsDisable": true])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        await plugin.commandQueue.pause()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in [10, 20, 30] {
                group.addTask { try await plugin.sendDeviceUpdate(id: lightID, .brightness(value)) }
                try await Task.sleep(for: .milliseconds(20))
            }
            for code in ["MwUBAA==", "MwUCAA=="] {
                group.addTask { try await plugin.sendDeviceUpdate(id: lightID, .ptReal(code)) }
                try await Task.sleep(for: .milliseconds(20))
            }
            await plugin.commandQueue.start()
            try await group.waitForAll()
        }
        let written = await environment.central.written.map(Array.init)
        #expect(written.filter { $0[1] == 0x04 } == [Govee.codeBytes([0x33, 0x04, Int(0.3 * 255)])])
        #expect(written.filter { $0[0] == 0x33 && $0[1] == 0x05 }.count == 2)
    }

    @Test func sensorsReportThroughTheDeviceList() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let thermometer = try #require(host.accessory(thermoID)?.service(.temperatureSensor))
        let humidity = try #require(host.accessory(thermoID)?.service(.humiditySensor))
        #expect(await eventually { thermometer[.currentTemperature]?.value.doubleValue == 22.1 && humidity[.currentRelativeHumidity]?.value.doubleValue == 52 })
        #expect(host.accessory(thermoID)?.service(.battery)?[.batteryLevel]?.value.intValue == 94)
        // 65535 is "no reading": the pool sensor keeps its humidity.
        #expect(host.accessory(poolID)?.service(.temperatureSensor)?[.currentTemperature]?.value.doubleValue == 28.5)
        #expect(host.accessory(poolID)?.service(.humiditySensor)?[.currentRelativeHumidity]?.value.doubleValue == 0)
        #expect(await eventually { host.accessory(leakID)?.service(.battery)?[.batteryLevel]?.value.intValue == 80 })
        #expect(host.accessory(leakID)?.service(.leakSensor)?[.leakDetected]?.value == .int(0))
    }

    @Test func leakAlertsAreFetchedForNewEventsOnly() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let warnings = "app2.govee.com/leak/rest/device/v1/warnMessage"
        _ = await eventually { environment.govee.requests(to: warnings).count == 1 }
        await plugin.httpSync()
        #expect(environment.govee.requests(to: warnings).count == 1)

        // An unread alert after a new event.
        var devices = GoveeEnvironment.devices
        if case .object(var leak) = devices[2] {
            leak["deviceExt"] = ["deviceSettings": .string(jsonText(["battery": 80])), "lastDeviceData": .string(jsonText(["lastTime": 1_700_000_500, "online": true, "gwonline": true]))]
            devices[2] = .object(leak)
        }
        environment.govee.answer("app2.govee.com/device/rest/devices/v1/list", ["devices": .array(devices)])
        environment.govee.answer(warnings, ["data": [["read": false, "message": "Leakage Alert"]]])
        await plugin.httpSync()
        await plugin.httpSync()
        #expect(environment.govee.requests(to: warnings).count == 2)
        #expect(host.accessory(leakID)?.service(.leakSensor)?[.leakDetected]?.value == .int(1))
        #expect(environment.govee.requests(to: warnings).last?.body?["device"] == .string(leakID.replacingOccurrences(of: ":", with: "")))

        // A failed check keeps the alert.
        await plugin.resetLeakCheck(leakID)
        environment.govee.fail(warnings)
        await plugin.httpSync()
        #expect(host.accessory(leakID)?.service(.leakSensor)?[.leakDetected]?.value == .int(1))
    }

    @Test func bleReadingsAreThrottled() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let reading = BLESensorReading(identifier: "x", address: nil, model: "GVH5179_5678", battery: 87, humidity: 45.6, tempInC: 21.37, tempInF: 70.5, rssi: -60)
        await plugin.receiveBLEReading(reading)
        var second = reading
        second.tempInC = 30
        await plugin.receiveBLEReading(second)
        let thermometer = try #require(host.accessory(thermoID)?.service(.temperatureSensor))
        #expect(thermometer[.currentTemperature]?.value.doubleValue == 21.4)
        #expect(host.accessory(thermoID)?.service(.battery)?[.batteryLevel]?.value.intValue == 87)
    }

    @Test func reportsFromAWSAndTheLAN() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let lightbulb = try #require(host.accessory(lightID)?.service(.lightbulb))
        environment.mqtt.broker.receive("account-topic", payload: jsonData(["device": .string(lightID), "state": ["onOff": 1, "brightness": 30, "color": ["r": 255, "g": 0, "b": 0]]]))
        #expect(await eventually { lightbulb[.brightness]?.value == .int(30) })
        #expect(lightbulb[.on]?.value == .bool(true))
        environment.lan.deliver(["msg": ["cmd": "devStatus", "data": ["onOff": 0, "brightness": 75]]], from: "192.168.1.20")
        #expect(await eventually { lightbulb[.on]?.value == .bool(false) })
        #expect(lightbulb[.brightness]?.value == .int(75))
    }

    @Test func ignoredAndMatterDevicesStayOut() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start(["username": "user@example.com", "password": "pw", "thermoDevices": [["deviceId": thermoID, "ignoreDevice": true]]])
        defer { Task { await host.stop() } }
        #expect(host.accessory(thermoID) == nil)
        #expect(host.accessory(lightID) != nil)
        let plugin = try #require(environment.plugin)
        #expect(await !plugin.isIgnored("X", model: "H6022"))
        let matter = GoveePlugin(configuration: GoveePlugin.Configuration(["ignoreMatter": true]), context: plugin.context)
        #expect(await matter.isIgnored("X", model: "H6022"))
        #expect(await !matter.isIgnored("X", model: "H6008"))
    }

    @Test func runsWithoutAnAccount() async throws {
        let environment = GoveeEnvironment()
        environment.lan.scanReplies = [(lightID, "H6008", "192.168.1.20")]
        let host = try await environment.start(["lightDevices": [["deviceId": lightID, "label": "Desk"]]])
        defer { Task { await host.stop() } }
        #expect(host.accessory(lightID)?.name == "Desk")
        #expect(environment.govee.requests.isEmpty)
    }

    @Test func settingsPageRequests() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        func request(_ path: String, _ body: JSONValue = .null) async throws -> PluginWebResponse {
            try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: path, body: body, user: "me"))
        }
        let login: JSONValue = ["username": "user@example.com", "password": "pw"]
        #expect(try await request("test-login", login).json == ["success": true, "message": "Login successful. Account ID: acc"])
        #expect(try await request("test-login", ["username": "u"]).status == 400)
        let found = try await request("discover", login)
        #expect(found.json["devices"]?[0]?["deviceId"] == .string(lightID))
        #expect(found.json["devices"]?[0]?["deviceType"] == "lightDevices")

        // Scenes: Govee's library when it answers, the bundled one otherwise.
        let offline = try await request("scenes", ["deviceId": .string(lightID), "model": "H6173"])
        #expect(offline.json["source"] == "offline")
        #expect(offline.json["warning"] != nil)
        environment.govee.answer("app2.govee.com/appsku/v2/scences", ["data": ["categories": categories()]])
        let cloud = try await request("scenes", ["deviceId": .string(lightID), "model": "h6173", "goodsType": 7, "username": "user@example.com", "password": "pw"])
        #expect(cloud.json["source"] == "cloud")
        #expect(cloud.json["categories"]?[0]?["scenes"]?[0]?["name"] == "Forest")
        #expect(environment.govee.requests(to: "app2.govee.com/appsku/v2/scences").last?.query == ["sku": "H6173", "device": lightID, "goodsType": "7", "source": "0"])
        #expect(try await request("scenes", ["model": "H6173"]).status == 400)
        environment.govee.answer("app2.govee.com/bff-app/v1/devices/detail/function-support", ["data": ["modes": [10, 8]]])
        #expect(try await request("device-capabilities", ["deviceId": .string(lightID), "model": "H6173", "username": "user@example.com", "password": "pw"]).json["modes"] == ["scene", "music"])
        #expect(try await request("device-capabilities", ["deviceId": .string(lightID), "model": "H6173"]).json["modes"] == .null)

        // Icons: Govee's hosts only, images only, inlined.
        environment.icons.answer("d1f2504ijhdyjw.cloudfront.net/a.png", .string("raw:PNG"), headers: [("Content-Type", "image/png")])
        environment.icons.answer("d1f2504ijhdyjw.cloudfront.net/page.html", .string("raw:<html>"), headers: [("Content-Type", "text/html")])
        let icons = try await request("scene-icons", ["urls": [
            "https://d1f2504ijhdyjw.cloudfront.net/a.png", "https://evil.example/a.png", "http://d1f2504ijhdyjw.cloudfront.net/a.png",
            "https://d1f2504ijhdyjw.cloudfront.net/page.html",
        ]])
        #expect(icons.json["icons"] == ["https://d1f2504ijhdyjw.cloudfront.net/a.png": .string("data:image/png;base64,\(Data("PNG".utf8).base64EncodedString())")])
        #expect(environment.icons.requests.count == 2)

        let status = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "devices", user: "me"))
        #expect(status.json["devices"]?.arrayValue?.contains { $0["deviceId"] == .string(lightID) && $0["lan"] == "enabled" } == true)

        let cleared = try await request("clear-cache", [:])
        #expect(cleared.json["success"] == true)
        let storage = environment.directory.appendingPathComponent("plugins/Govee-Govee")
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("govee.pfx").path))
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("credentials.json").path))
    }
}
