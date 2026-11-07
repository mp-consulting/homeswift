import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    func decode(_ text: String) throws -> SmartThingsSettings {
        let configuration = try JSONDecoder().decode(SmartThingsPlugin.Configuration.self, from: Data(text.utf8))
        return SmartThingsSettings(configuration.raw)
    }

    @Test func aMinimalBlockDecodes() throws {
        let settings = try decode(#"{"platform":"HomeBridgeSmartThings","name":"SmartThings"}"#)
        #expect(settings.clientID == nil)
        #expect(settings.baseURL == SmartThingsSettings.defaultBaseURL)
        #expect(settings.pollSeconds() == 300)
        #expect(settings.callbackServerPort == 8583)
        #expect(settings.exposeRobotVacuum && settings.enableTelevisionService && settings.publishTVsAsExternal)
        #expect(settings.optionalModeForAirConditioners == "None")
    }

    /// The aziz66 block of section 2.5, as its wizard leaves it.
    @Test func anAziz66BlockDecodes() throws {
        let settings = try decode("""
            { "platform": "HomeBridgeSmartThings", "name": "SmartThings", "BaseURL": "https://api.smartthings.com/v1/",
              "client_id": "7a850484-0000-4000-8000-000000000001", "client_secret": "3581f317-0000-4000-8000-000000000002",
              "oauth_access_token": "00000000-aaaa-4000-8000-000000000003", "oauth_refresh_token": "00000000-bbbb-4000-8000-000000000004",
              "oauth_expires_in": 86399, "PollSwitchesAndLightsSeconds": 10, "PollSensorsSeconds": 5, "ExposeHumiditySensorForAirConditioners": true,
              "OptionalModeForAirConditioners": "WindFree", "IgnoreDevices": ["Hallway Hub", "Kitchen Plug"],
              "thermostatModeOverrides": [{ "deviceName": "Floor Heating", "heatMode": "radiatingfloor" }],
              "tvApps": ["3201907018807", "111299001912"], "server_url": "https://example.invalid", "webhook_port": 3000 }
            """)
        #expect(settings.clientID == "7a850484-0000-4000-8000-000000000001")
        #expect(settings.clientSecret == "3581f317-0000-4000-8000-000000000002")
        #expect(settings.text("oauth_refresh_token") == "00000000-bbbb-4000-8000-000000000004")
        // The smallest poll, floored at 60 s (section 5.3).
        #expect(settings.pollSeconds() == 60)
        #expect(settings.exposeHumidityForAirConditioners)
        #expect(settings.optionalModeForAirConditioners == "WindFree")
        #expect(settings.ignoreDevices == ["Hallway Hub", "Kitchen Plug"])
        #expect(settings.thermostatModeOverrides == [.init(deviceName: "Floor Heating", heatMode: "radiatingfloor", coolMode: nil)])
        #expect(settings.tvApps == ["3201907018807", "111299001912"])
        #expect(settings.hasWebhookOptions)
        let options = DeviceOptions(settings: settings, plugin: [:], deviceName: "floor heating")
        #expect(options.heatMode == "radiatingfloor" && options.coolMode == "cool" && options.exposeHumidity)
    }

    /// The ik block of section 2.5.
    @Test func anIkBlockDecodes() throws {
        let settings = try decode("""
            { "platform": "HomeBridgeSmartThings", "name": "Smartthings Plug (IK)", "BaseURL": "https://api.smartthings.com/v1/",
              "AccessToken": "00000000-cccc-4000-8000-000000000005", "WebhookToken": "", "GarageDoorMaxPoll": 40,
              "IgnoreLocations": ["Cabin"], "IgnoreDevices": ["Garage Light"] }
            """)
        #expect(settings.text("AccessToken") == "00000000-cccc-4000-8000-000000000005")
        #expect(settings.ignoreLocations == ["Cabin"])
        #expect(settings.presentIgnoredKeys.contains("GarageDoorMaxPoll"))
        #expect(!settings.hasWebhookOptions)
        #expect(settings.pollSeconds() == 300)
    }

    @Test func zeroPollsMeanTheSlowSafetyReadOnly() throws {
        #expect(try decode(#"{"PollSensorsSeconds":0,"PollLocksSeconds":0}"#).pollSeconds() == nil)
        #expect(try decode(#"{"PollSensorsSeconds":0,"PollLocksSeconds":120}"#).pollSeconds() == 120)
    }

    @Test func aBaseURLOffSmartThingsIsRefused() throws {
        #expect(try decode(#"{"BaseURL":"https://api.samsungiotcloud.cn/v1"}"#).checkedBaseURL().absoluteString == "https://api.samsungiotcloud.cn/v1/")
        #expect(throws: SmartThingsSettings.SettingsError.self) { try decode(#"{"BaseURL":"http://api.smartthings.com/v1/"}"#).checkedBaseURL() }
        #expect(throws: SmartThingsSettings.SettingsError.self) { try decode(#"{"BaseURL":"https://evil.example/v1/"}"#).checkedBaseURL() }
    }

    @Test func namesAreComparedWithPlainQuotes() throws {
        let settings = try decode(#"{"IgnoreDevices":["Kid's Lamp"]}"#)
        let device = try #require(SmartThingsDevice(["deviceId": "x", "label": "Kid\u{2019}s Lamp ", "components": []]))
        #expect(settings.excludedByLists(device, locationNames: [:]))
    }

    /// The Homebridge lists become Accessory Settings by the devices known (section 2.4).
    @Test func canonicalSettingsMovesTheListsToAccessorySettings() throws {
        let devices = [Fixture.page1["items"]?.arrayValue ?? [], Fixture.page2["items"]?.arrayValue ?? []].joined().compactMap(SmartThingsDevice.init)
        let block: [String: JSONValue] = [
            "IgnoreDevices": ["Hallway Hub", "Nothing Of That Name"],
            "thermostatModeOverrides": [["deviceName": "floor heating", "heatMode": "radiatingfloor"]],
        ]
        let canonical = SmartThingsPlugin.canonical(block, devices: devices, locationNames: [Fixture.location: "Home"])
        #expect(canonical["_accessories"]?[Fixture.hub]?["excluded"] == true)
        #expect(canonical["_accessories"]?[Fixture.thermostat]?["heatMode"] == "radiatingfloor")
        #expect(canonical["IgnoreDevices"] == ["Nothing Of That Name"])
        #expect(canonical["thermostatModeOverrides"] == nil)
        // Written again, it changes nothing.
        #expect(SmartThingsPlugin.canonical(canonical, devices: devices, locationNames: [:]) == canonical)

        let shown = SmartThingsPlugin.canonical(["ShowOnlyDevices": ["Living Room Lamp"], "IgnoreLocations": ["Home"]], devices: devices, locationNames: [Fixture.location: "Home"])
        #expect(shown["_accessories"]?[Fixture.lamp]?["excluded"] == true)  // its location is ignored
        #expect(shown["_accessories"]?[Fixture.thermostat]?["excluded"] == true)
        #expect(shown["ShowOnlyDevices"] == nil && shown["IgnoreLocations"] == nil)
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(SmartThingsPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/SmartThings SmartThingsPlugin")
        let schema = try JSONValue(string: try #require(SmartThingsPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "HomeBridgeSmartThings")
        // Every option the Homebridge plugins have is declared (docs/adr/0002), but the secrets, which the vault keeps.
        let properties = try #require(schema["schema"]?["properties"]?.objectValue)
        for key in SmartThingsSettings.pollKeys + SmartThingsSettings.ignoredKeys + ["client_id", "BaseURL", "oauth_expires_in", "IgnoreDevices", "ShowOnlyDevices",
                                                                                    "IgnoreLocations", "tvApps", "thermostatModeOverrides"]
        where !["WebhookToken", "verifyWebhookSignatures"].contains(key) {
            #expect(properties[key] != nil, "\(key) is not declared")
        }
        for key in ["client_secret", "AccessToken", "oauth_access_token", "oauth_refresh_token", "WebhookToken", "verifyWebhookSignatures"] { #expect(properties[key] == nil) }
    }

    @Test func webFilesAreCurrent() throws {
        let directory = Self.root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let file = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(SmartThingsPlugin.webFiles[name]?.body == file, "run: swift Scripts/embed-assets.swift web Plugins/SmartThings/Web Plugins/SmartThings/Sources/WebFiles.swift SmartThingsPlugin")
        }
    }
}
