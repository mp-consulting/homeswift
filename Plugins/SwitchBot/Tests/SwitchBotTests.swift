import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSwitchBot

/// The protocol and the conversions, against the vectors of docs/clean-room/SwitchBot.md §10.
@Suite struct SwitchBotUnitTests {
    @Test func signsAsTheDocumentationsExamples() {
        #expect(OpenAPI.sign(token: "yourtoken", secret: "yoursecret", time: "1700000000000", nonce: "requestID") == "uUH4nmWS7lFu1itiq+wV9g7vvAp3vFHLkWpjmRpYPG0=")
        #expect(OpenAPI.sign(token: "yourtoken", secret: "yoursecret", time: "1700000000000", nonce: "requestID") != "UUH4NMWS7LFU1ITIQ+WV9G7VVAP3VFHLKWPJMRPYPG0=")
        let token = String(repeating: "0123456789abcdef", count: 6)
        #expect(OpenAPI.sign(token: token, secret: "fedcba9876543210fedcba9876543210", time: "1730700000123", nonce: "5f1c2b9e-1d2a-4c3b-9e8f-7a6b5c4d3e2f")
            == "+jlbLobGbUq+SbSLtlsBUcyWs/Ysm0YhD+ruIoQ8X2o=")
        let headers = OpenAPI.headers(token: "yourtoken", secret: "yoursecret", time: "1700000000000", nonce: "requestID")
        #expect(headers.map(\.name) == ["Authorization", "t", "nonce", "sign", "Content-Type"])
        #expect(headers.map(\.value) == ["yourtoken", "1700000000000", "requestID", "uUH4nmWS7lFu1itiq+wV9g7vvAp3vFHLkWpjmRpYPG0=", "application/json"])
    }

    @Test func requestsCarryTheSignedHeaders() async throws {
        let cloud = FakeCloud()
        let client = OpenAPIClient(
            token: "yourtoken", secret: "yoursecret", settings: .init(), http: cloud,
            budget: RequestBudget(limit: 10_000, reserve: 1_000, localMidnight: false, file: nil), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let list = try await client.deviceList()
        #expect(list.devices.count == 5 && list.remotes.count == 2)
        let request = try #require(cloud.state.withLockedValue { $0.requests.first })
        #expect(request.url.absoluteString == "https://api.switch-bot.com/v1.1/devices")
        #expect(request.header("t") == "1700000000000")
        let nonce = try #require(request.header("nonce"))
        #expect(UUID(uuidString: nonce) != nil && nonce == nonce.lowercased())
        #expect(request.header("sign") == OpenAPI.sign(token: "yourtoken", secret: "yoursecret", time: "1700000000000", nonce: nonce))
        #expect(await client.budget.used == 1)
    }

    @Test func retriesOnlyWhatThrows() async throws {
        let cloud = FakeCloud()
        cloud.state.withLockedValue { $0.unreachable = ["X"] }
        var settings = OpenAPIClient.Settings()
        settings.attempts = 3
        settings.retryDelay = .milliseconds(1)
        let client = OpenAPIClient(token: "t", secret: "s", settings: settings, http: cloud, budget: RequestBudget(limit: 10_000, reserve: 1_000, localMidnight: false, file: nil))
        await #expect(throws: OpenAPI.Unreachable.self) { _ = try await client.status("X") }
        #expect(cloud.state.withLockedValue { $0.requests.count } == 3)
        cloud.state.withLockedValue { $0.commandCode = 161 }
        let refused = try await client.send(Command(command: "turnOn"), to: "Y")
        #expect(!refused.succeeded && refused.failure.contains("offline"))
        #expect(cloud.state.withLockedValue { $0.requests.count } == 4)
    }

    @Test func theBudgetKeepsTheReserveForCommands() async {
        let budget = RequestBudget(limit: 1_000, reserve: 998, localMidnight: false, file: nil)
        #expect(await budget.allowsPoll())
        await budget.record()
        await budget.record()
        #expect(await !budget.allowsPoll())
        // 288 polls a day per device at 300 s: 40 devices need more than 9,000.
        #expect(RequestBudget.pollSeconds(devices: 10, limit: 10_000, reserve: 1_000) == 96)
        #expect(RequestBudget.pollSeconds(devices: 40, limit: 10_000, reserve: 1_000) == 384)
    }

    @Test func blindTiltMappings() {
        #expect(BlindMapping.onlyUp.homeKit(slide: 75).position == 50)
        #expect(BlindMapping.onlyUp.homeKit(slide: 20).position == 100)
        #expect(BlindMapping.onlyDown.homeKit(slide: 30).position == 60)
        #expect(BlindMapping.upAndDown.command(position: 80, tilt: 90) == ("down", 40))
        #expect(BlindMapping.downAndUp.command(position: 30, tilt: 90) == ("down", 40))
        #expect(BlindMapping.tiltForDirection.homeKit(slide: 30) == (60, -90))
        #expect(BlindMapping.command(direction: "up", position: 100) == Command(command: "fullyOpen"))
        #expect(BlindMapping.command(direction: "up", position: 40) == Command(command: "setPosition", parameter: "up;40"))
        #expect(BlindMapping.command(direction: "up", position: 41) == Command(command: "setPosition", parameter: "up;42"))
        #expect(BlindMapping.command(direction: "down", position: 0) == Command(command: "closeDown"))
    }

    @Test func conversions() {
        #expect(DeviceAccessory.lux(level: 1, steps: 19, range: 1...6001) == 1)
        #expect(DeviceAccessory.lux(level: 20, steps: 19, range: 1...6001) == 6001)
        #expect(abs(DeviceAccessory.lux(level: 11, steps: 19, range: 1...6001) - 6000.0 / 19 * 10) < 0.001)
        #expect(normalizedVersion("V31") == "3.1")
        #expect(normalizedVersion("V4.2-1") == "4.2")
        #expect(cleanedName("Living-Room Curtain!") == "LivingRoom Curtain")
        #expect(cleanedName("Kid's Lamp") == "Kid's Lamp")
        #expect(ColorConversion.hueSaturation(rgb: "255:0:0")! == (0, 100))
        #expect(ColorConversion.hueSaturation(rgb: "0:0:255")! == (240, 100))
        #expect(ColorConversion.rgb(hue: 120, saturation: 100) == "0:255:0")
        #expect(ColorConversion.rgb(hue: 0, saturation: 100) == "255:0:0")
        #expect(normalizedID("c2:71:11:1e:c0:ab") == "C271111EC0AB")
        #expect(ControlKind(type: "GarageDoor") == .garagedoor)
        #expect(ControlKind(type: nil) == .switch)
        #expect(RemoteFamily(remoteType: "DIY Fan") == .fan)
        #expect(RemoteFamily(remoteType: "DIY Others") == nil)
    }

    @Test func airConditionerSetAll() {
        #expect(RemoteAccessory.setAllParameter(active: true, mode: 2, threshold: 23, speed: 2) == "23,2,3,on")
        #expect(RemoteAccessory.setAllParameter(active: true, mode: 0, threshold: 20, speed: 4) == "25,1,1,on")
        #expect(RemoteAccessory.setAllParameter(active: false, mode: 1, threshold: 21.5, speed: 1) == "21.5,5,2,off")
    }

    @Test func aMinimalBlockAndBothShapesDecode() throws {
        let minimal = try JSONDecoder().decode(SwitchBotPlugin.Configuration.self, from: Data(#"{"platform":"SwitchBot"}"#.utf8))
        #expect(minimal.token == nil && minimal.refreshRate == 300 && minimal.debounceSeconds == 0.1)
        let four = try JSONDecoder().decode(SwitchBotPlugin.Configuration.self, from: Data("""
            {"platform":"SwitchBot","credentials":{"token":"a","secret":"b"},"options":{"refreshRate":"120","pushRate":0.5,
             "devices":[{"deviceId":"C271111EC0AB","configDeviceType":"Meter","webhook":true}]}}
            """.utf8))
        #expect(four.token == "a" && four.secret == "b" && four.refreshRate == 120 && four.debounceSeconds == 0.5)
        #expect(four.deviceEntries?.first?.flag("webhook") == true)
        let five = try JSONDecoder().decode(SwitchBotPlugin.Configuration.self, from: Data("""
            {"platform":"SwitchBot","openApiToken":"c","openApiSecret":"d","credentials":{"token":"a","secret":"b"},
             "devices":[{"deviceId":"D1A2B3C4D5E6","botDisplay":"outlet","enabled":false}],"writeDebounceMs":250}
            """.utf8))
        #expect(five.token == "c" && five.secret == "d" && five.debounceSeconds == 0.25)
        #expect(five.deviceEntries?.first?.string("type") == "outlet" && five.deviceEntries?.first?.flag("hide_device") == true)
    }

    @Test func canonicalSettingsMovesTheListsAndExcludesWhatTheyLeftOut() throws {
        let block = try JSONValue(string: """
            {"platform":"SwitchBot","options":{"refreshRate":300,
              "devices":[{"deviceId":"C271111EC0AB","configDeviceType":"Meter","webhook":true,"configDeviceName":"Office","set_minlux":2},
                         {"deviceId":"d1a2b3c4d5e6","type":"Switch","mode":"press","mqttURL":"mqtt://broker"}],
              "irdevices":[{"deviceId":"02-202008110034-13","configRemoteType":"TV","external":true}]}}
            """)
        let list = DeviceList(specList["body"]!)
        let canonical = SwitchBotPlugin.canonical(block, list: list)
        let entries = try #require(canonical["_accessories"])
        #expect(entries["C271111EC0AB-Meter"]?["webhook"] == true)
        #expect(entries["C271111EC0AB-Meter"]?["name"] == "Office")
        #expect(entries["C271111EC0AB-Meter"]?["set_minLux"] == 2)
        // The listed spelling stays the Device Id; a value the schema has no key for stays listed.
        #expect(entries["d1a2b3c4d5e6-Bot"]?["type"] == "switch")
        #expect(canonical["options"]?["devices"] == [["deviceId": "d1a2b3c4d5e6", "mqttURL": "mqtt://broker"]])
        #expect(entries["02-202008110034-13-TV"]?["external"] == true)
        #expect(canonical["options"]?["irdevices"] == nil)
        // The list exposed only what it named.
        #expect(entries["E2F6032048AB-Curtain"]?["excluded"] == true)
        #expect(entries["FA7310762361-Hub 2"]?["excluded"] == true)
        #expect(entries["02-202102220012-55-Air Conditioner"]?["excluded"] == true)
        #expect(entries["C271111EC0AB-Meter"]?["excluded"] == nil)
        #expect(SwitchBotPlugin.canonical(canonical, list: list) == canonical)
        // Without the cloud's list nothing moves.
        #expect(SwitchBotPlugin.canonical(block, list: nil) == block)
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(SwitchBotPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/SwitchBot SwitchBotPlugin")
        let schema = try JSONValue(string: try #require(SwitchBotPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "SwitchBot")
        // Every key canonicalSettings moves is declared.
        let declared = Set(schema["accessorySchema"]?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        #expect(SwitchBotPlugin.deviceKeys.union(SwitchBotPlugin.remoteKeys).subtracting(declared).isEmpty)
    }
}
