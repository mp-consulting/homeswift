import Crypto
import Foundation
import HomeswiftAI
import _CryptoExtras
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTuya

/// The plugin on a host, against the fake cloud and MQTT broker.
@Suite(.timeLimit(.minutes(1)))
struct TuyaTests {
    let environment = TestEnvironment()
    let lampID = TuyaPlugin.accessoryID(deviceID: "bf0123456789abcdefgh")
    let stripID = TuyaPlugin.accessoryID(deviceID: "bf9876543210zyxwvuts")

    func started() async throws -> PluginHost {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(lampID) != nil && host.accessory(stripID) != nil })
        return host
    }

    func lightbulb(_ host: PluginHost) throws -> Service {
        try #require(host.accessory(lampID)?.service(.lightbulb))
    }

    func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
        let characteristic = try #require(characteristic)
        let handler = try #require(characteristic.writeHandler(for: value))
        try await handler(value)
    }

    /// The commands sent to a device, as each request's body.
    func commands(_ deviceID: String) -> [String] {
        environment.cloud.sent("POST", "/v1.0/devices/\(deviceID)/commands").compactMap(\.body)
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(TuyaPlugin.Configuration.self, from: Data(#"{"platform":"TuyaPlatform"}"#.utf8))
        #expect(configuration.options == nil)
    }

    @Test func signsInAndSignsItsRequests() async throws {
        let host = try await started()
        let login = try #require(environment.cloud.sent("POST", "/v1.0/iot-01/associated-users/actions/authorized-login").first)
        #expect(login.body == #"{"country_code":33,"username":"user@example.com","password":"e4dac8847254e28266642c1bfe2ea3d2","schema":"smartlife"}"#)
        #expect(login.headers["access_token"] == "")
        #expect(login.headers["client_id"] == "4h3dxjpwamt9gcrkqv8e")
        #expect(login.headers["sign_method"] == "HMAC-SHA256")
        #expect(login.headers["sign"]?.count == 64)
        let homes = try #require(environment.cloud.sent("GET", "/v1.0/users/ay1700000000000abcd/homes").first)
        #expect(homes.headers["access_token"] == "c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4")
        #expect(await eventually { !environment.cloud.sent("POST", "/v1.0/iot-03/open-hub/access-config").isEmpty })
        let config = try #require(environment.cloud.sent("POST", "/v1.0/iot-03/open-hub/access-config").first?.body)
        #expect(config.hasPrefix(#"{"uid":"ay1700000000000abcd","link_id":""#))
        #expect(config.hasSuffix(#""link_type":"mqtt","topics":"device","msg_encrypted_version":"1.0"}"#))
        await host.stop()
    }

    @Test func eachDeviceBecomesAnAccessory() async throws {
        let host = try await started()
        let lamp = try #require(host.accessory(lampID))
        #expect(lamp.information.characteristic(.manufacturer).value == "Tuya Inc.")
        #expect(lamp.information.characteristic(.model).value == "keyabc123")
        #expect(lamp.information.characteristic(.serialNumber).value == "a1b2c3d4e5f60718")
        #expect(lamp.information[.statusActive]?.value == .bool(true))
        let bulb = try lightbulb(host)
        #expect(bulb.subtype == nil)
        #expect(bulb[.on]?.value == .bool(true))
        #expect(bulb[.brightness]?.value == .int(80))
        #expect(bulb[.colorTemperature]?.value == .int(282))
        #expect(bulb[.hue]?.value.doubleValue == 48)
        #expect(bulb[.saturation]?.value.doubleValue == 2)
        #expect(bulb[.statusActive]?.value == .bool(true))
        // Brightness and colour temperature: Adaptive Lighting.
        #expect(bulb.adaptiveLighting != nil)

        let strip = try #require(host.accessory(stripID))
        let outlets = strip.services.filter { $0.type.uuid == ServiceType.outlet.uuid }
        #expect(outlets.map(\.subtype) == ["switch_1", "switch_2", "switch_usb1"])
        #expect(outlets.first?[.configuredName]?.value == "switch_1")
        let first = try #require(outlets.first)
        #expect(first[TuyaEve.amperes]?.value.doubleValue == 0.312)
        #expect(first[TuyaEve.watts]?.value.doubleValue == 68.4)
        #expect(first[TuyaEve.volts]?.value.doubleValue == 230.1)
        #expect(first[TuyaEve.kilowattHours]?.value.doubleValue == 1.25)
        #expect(outlets[1][TuyaEve.watts] == nil)
        // The disabled scene is left out; the other is a switch.
        let scene = try #require(host.accessory(TuyaPlugin.accessoryID(deviceID: "sc1")))
        #expect(scene.service(.switch)?[.on]?.value == .bool(false))
        #expect(host.accessory(TuyaPlugin.accessoryID(deviceID: "sc2")) == nil)
        await host.stop()
    }

    @Test func writesAreCoalescedAsTheSpecSays() async throws {
        let host = try await started()
        let bulb = try lightbulb(host)
        try await write(bulb[.brightness], .int(50))
        #expect(await eventually { commands("bf0123456789abcdefgh").count == 1 })
        #expect(commands("bf0123456789abcdefgh") == [#"{"commands":[{"code":"bright_value_v2","value":500}]}"#])

        try await write(bulb[.colorTemperature], .int(200))
        #expect(await eventually { commands("bf0123456789abcdefgh").count == 2 })
        #expect(commands("bf0123456789abcdefgh").last == #"{"commands":[{"code":"work_mode","value":"white"},{"code":"temp_value_v2","value":583}]}"#)

        try await write(bulb[.hue], .double(120))
        try await write(bulb[.saturation], .double(50))
        #expect(await eventually { commands("bf0123456789abcdefgh").count == 3 })
        #expect(commands("bf0123456789abcdefgh").last
            == #"{"commands":[{"code":"colour_data_v2","value":"{\"h\":120,\"s\":500,\"v\":1000}"},{"code":"work_mode","value":"colour"}]}"#)
        await host.stop()
    }

    @Test func anOfflineDeviceAnswersNoResponse() async throws {
        let host = try await started()
        let strip = try #require(host.accessory(stripID))
        let on = try #require(strip.service(.outlet, subtype: "switch_1")?[.on])
        #expect(strip.service(.outlet, subtype: "switch_1")?[.statusActive]?.value == .bool(false))
        let read = try #require(on.readHandler)
        await #expect(throws: HAPStatusError.self) { _ = try await read() }
        await #expect(throws: HAPStatusError.self) { try await write(on, .bool(false)) }
        #expect(commands("bf9876543210zyxwvuts").isEmpty)
        await host.stop()
    }

    /// A status message as Tuya's MQTT sends it, encrypted with the key of the fake access config.
    func pushStatus(_ plaintext: String) throws {
        // The spec's ECB vector is this plaintext; others are encrypted here the same way.
        let key = try #require(TuyaMessageCrypto.key(fromPassword: "f3a9c1d2e4b5a6978877665544332211"))
        let data = try TuyaTestCrypto.encryptECB(Data(plaintext.utf8), key: key)
        let envelope = #"{"protocol":4,"pv":"2.0","sign":"x","t":\#(Int(Date().timeIntervalSince1970)),"data":"\#(data)"}"#
        environment.mqtt.receive("cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c", string: envelope)
    }

    @Test func pushesReachHomeKit() async throws {
        let host = try await started()
        #expect(await eventually { environment.mqtt.subscriptions["cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"] != nil })
        let bulb = try lightbulb(host)
        // The spec's own ciphertext.
        environment.mqtt.receive("cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c",
                                 string: #"{"protocol":4,"pv":"2.0","sign":"x","t":\#(Int(Date().timeIntervalSince1970)),"data":"\#(TuyaProtocolTests.ecbData)"}"#)
        #expect(await eventually { bulb[.on]?.value == .bool(false) })

        try pushStatus(#"{"devId":"bf0123456789abcdefgh","status":[{"code":"bright_value_v2","value":500}]}"#)
        #expect(await eventually { bulb[.brightness]?.value == .int(50) })

        // A lifecycle message: the strip comes online.
        let key = try #require(TuyaMessageCrypto.key(fromPassword: "f3a9c1d2e4b5a6978877665544332211"))
        let online = try TuyaTestCrypto.encryptECB(Data(#"{"bizCode":"online","bizData":{},"devId":"bf9876543210zyxwvuts"}"#.utf8), key: key)
        environment.mqtt.receive("cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c", string: #"{"protocol":20,"t":1700000000,"data":"\#(online)"}"#)
        let strip = try #require(host.accessory(stripID))
        #expect(await eventually { strip.service(.outlet, subtype: "switch_2")?[.statusActive]?.value == .bool(true) })
        await host.stop()
    }

    @Test func aColourSetElsewhereTurnsAdaptiveLightingOff() async throws {
        let host = try await started()
        #expect(await eventually { environment.mqtt.subscriptions["cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"] != nil })
        let bulb = try lightbulb(host)
        let controller = try #require(bulb.adaptiveLighting)
        try controller.activateForTesting(mireds: 282)
        // Its own white (the echo of a write) keeps it.
        try pushStatus(#"{"devId":"bf0123456789abcdefgh","status":[{"code":"temp_value_v2","value":301},{"code":"bright_value_v2","value":500}]}"#)
        #expect(await eventually { bulb[.brightness]?.value == .int(50) })
        #expect(controller.isAdaptiveLightingActive)
        try pushStatus(#"{"devId":"bf0123456789abcdefgh","status":[{"code":"work_mode","value":"colour"},{"code":"colour_data_v2","value":"{\"h\":10,\"s\":500,\"v\":1000}"}]}"#)
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        #expect(await eventually { bulb[.hue]?.value.doubleValue == 10 })
        await host.stop()
    }

    @Test func aSceneSwitchRunsTheSceneAndTurnsOff() async throws {
        let host = try await started()
        let on = try #require(host.accessory(TuyaPlugin.accessoryID(deviceID: "sc1"))?.service(.switch)?[.on])
        on.value = .bool(true)
        try await write(on, .bool(true))
        #expect(environment.cloud.sent("POST", "/v1.0/homes/12345678/scenes/sc1/trigger").count == 1)
        #expect(await eventually { on.value == .bool(false) })
        await host.stop()
    }

    @Test func aFailedMQTTConfigurationIsTriedAgain() async throws {
        environment.cloud.fail("POST /v1.0/iot-03/open-hub/access-config")
        let host = try await started()
        #expect(await eventually { environment.cloud.sent("POST", "/v1.0/iot-03/open-hub/access-config").count >= 2 })
        environment.cloud.set("POST /v1.0/iot-03/open-hub/access-config", [
            "url": "ssl://m1.tuyaeu.com:8883", "client_id": "c", "username": "u", "password": "f3a9c1d2e4b5a6978877665544332211", "expire_time": 7200,
            "source_topic": ["device": "cloud/token/in/c"],
        ])
        environment.cloud.unfail("POST /v1.0/iot-03/open-hub/access-config")
        #expect(await eventually { environment.mqtt.subscriptions["cloud/token/in/c"] != nil })
        await host.stop()
    }

    @Test func aTokenAboutToExpireIsRefreshedOnce() async throws {
        environment.cloud.set("POST /v1.0/iot-01/associated-users/actions/authorized-login", [
            "access_token": "old", "refresh_token": "r1", "uid": "ay1700000000000abcd", "expire_time": 30,
        ])
        environment.cloud.set("GET /v1.0/token/r1", ["access_token": "new", "refresh_token": "r2", "uid": "ay1700000000000abcd", "expire_time": 7200])
        let host = try await started()
        let refreshes = environment.cloud.sent("GET", "/v1.0/token/r1")
        #expect(refreshes.count == 1)
        #expect(refreshes.first?.headers["access_token"] == "")
        #expect(environment.cloud.sent("GET", "/v1.0/homes/12345678/devices").first?.headers["access_token"] == "new")
        await host.stop()
    }

    @Test func aBlockWithoutOptionsDoesNothing() async throws {
        let host = try await environment.start(settings: [:])
        #expect(environment.cloud.sent.isEmpty)
        await host.stop()
    }

    @Test func overridesChangeTheAccessories() async throws {
        var settings = TestEnvironment.smartHome
        var options = settings["options"] as! [String: Any]
        options["deviceOverrides"] = [
            ["id": "keyxyz789", "category": "hidden"],
            ["id": "bf0123456789abcdefgh", "adaptiveLighting": false, "schema": [["code": "bright_value_v2", "onGet": "(value / 2)"]]],
        ]
        settings["options"] = options
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(lampID) != nil })
        let bulb = try lightbulb(host)
        #expect(bulb[.brightness]?.value == .int(40))
        #expect(bulb.adaptiveLighting == nil)
        #expect(await eventually { host.accessory(TuyaPlugin.accessoryID(deviceID: "sc1")) != nil })
        #expect(host.accessory(stripID) == nil)
        await host.stop()
    }

    @Test func discoversTheAccountsDevices() async throws {
        let host = try await started()
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.discover()
        #expect(devices.map(\.deviceID) == ["bf0123456789abcdefgh", "bf9876543210zyxwvuts", "sc1"])
        #expect(devices.first?.kind == "light")
        #expect(devices[1].isReachable == false)
        #expect(await plugin.accountAuthorized() == true)
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(TuyaPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Tuya TuyaPlugin")
        let schema = try JSONValue(string: try #require(TuyaPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "TuyaPlatform")
    }
}

/// AES-128-ECB with PKCS#7, for the tests' own messages: CBC with a zero IV, block by block.
enum TuyaTestCrypto {
    static func encryptECB(_ plain: Data, key: SymmetricKey) throws -> String {
        let padding = 16 - plain.count % 16
        let padded = [UInt8](plain) + [UInt8](repeating: UInt8(padding), count: padding)
        var out = Data()
        for start in stride(from: 0, to: padded.count, by: 16) {
            let block = try AES._CBC.encrypt(padded[start..<(start + 16)], using: key, iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)), noPadding: true)
            out.append(block)
        }
        return out.base64EncodedString()
    }
}
