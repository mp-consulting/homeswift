import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

/// The canonical shape (EWeLinkSettings.swift): the typed lists and `ignoredDevices` in `_accessories`, the account in
/// the vault, each device's Device Kind its category.
@Suite(.timeLimit(.minutes(1)))
struct SettingsTests {
    let environment = EWeLinkTestEnvironment()

    /// The seven lists move into `_accessories` by device id, the keys the plugin reads typed and the others dropped;
    /// a device's category list wins; `ignoredDevices` becomes Excluded, but a channel's id, which never matched, stays.
    @Test func canonicalSettingsMovesTheTypedLists() throws {
        let block = try JSONValue(any: [
            "platform": "eWeLink", "name": "eWeLink", "mode": "lan", "groups": [["type": "blind", "deviceIds": ["1000aaaaaa"]]],
            "singleDevices": [
                ["deviceId": "1000aaaaaa", "label": "Hall", "showAs": "valve", "disableTimer": "true", "ipAddress": "10.0.0.2", "ignoreDevice": true, "inUsePowerThreshold": "5"],
                ["deviceId": "1000dddddd", "showAs": "heater", "tempSource": "1000eeeeee"],
                ["label": "No id"],
            ],
            "multiDevices": [["deviceId": "1000bbbbbb", "showAs": "blind", "operationTime": 12, "hideChannels": "2", "overrideLogging": "debug"]],
            "thDevices": [
                ["deviceId": "1000dddddd", "showAs": "thermostat", "minTarget": 15],
                ["deviceId": "1000eeeeee", "tempOffset": "-1.5", "disableDeviceLogging": true],
            ],
            "rfDevices": [["deviceId": "1000ffffff", "subdevices": [["index": "1", "label": "Door", "showAs": "contact", "resetTime": 30, "type": "x"]]]],
            "ignoredDevices": ["1000cccccc", "1000bbbbbbSW1"],
            "_accessories": ["1000aaaaaa": ["showAs": "lock"]],
        ] as [String: Any])
        let canonical = EWeLinkPlugin.canonical(block, categories: ["1000dddddd": .thermostat])
        #expect(canonical == (try JSONValue(any: [
            "platform": "eWeLink", "name": "eWeLink", "mode": "lan", "groups": [["type": "blind", "deviceIds": ["1000aaaaaa"]]],
            "singleDevices": [["label": "No id"]],
            "ignoredDevices": ["1000bbbbbbSW1"],
            "_accessories": [
                "1000aaaaaa": ["showAs": "lock", "disableTimer": true, "inUsePowerThreshold": 5],
                "1000bbbbbb": ["showAs": "blind", "operationTime": 12, "hideChannels": "2"],
                "1000cccccc": ["excluded": true],
                // A thermostat: its thDevices entry's showAs wins over its singleDevices entry's.
                "1000dddddd": ["showAs": "thermostat", "minTarget": 15, "tempSource": "1000eeeeee"],
                "1000eeeeee": ["tempOffset": -1.5, "disableDeviceLogging": true],
                "1000ffffff": ["subdevices": [["index": 1, "label": "Door", "showAs": "contact", "resetTime": 30]]],
            ],
        ] as [String: Any])))
        // Canonical already: unchanged.
        #expect(EWeLinkPlugin.canonical(canonical) == canonical)
    }

    /// The canonical block runs as the Homebridge one did: the same accessories, by the same ids, with the same services.
    @Test func theCanonicalBlockRunsAsTheHomebridgeOne() async throws {
        let switches: JSONValue = [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "off"], ["outlet": 3, "switch": "off"]]
        let devices = [
            device("1000bbbbbb", uiid: 4, name: "Four", params: ["switches": switches]),
            device("1000cccccc", uiid: 126, name: "Shade", params: ["switches": [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"]]]),
            device("1000aaaaaa", uiid: 15, params: ["switch": "off", "currentTemperature": 21, "currentHumidity": 40]),
            device("1000dddddd", uiid: 1, name: "Gone"),
        ]
        let legacy: [String: Any] = [
            "mode": "wan",
            "multiDevices": [["deviceId": "1000bbbbbb", "hideChannels": "4"], ["deviceId": "1000cccccc", "showAs": "blind", "operationTime": 10]],
            "thDevices": [["deviceId": "1000aaaaaa", "showAs": "heater", "targetTempThreshold": 1]],
            "ignoredDevices": ["1000dddddd"],
        ]
        let before = try await environment.start(devices: devices, settings: legacy)
        let ids = Set(before.mainBridge.server.accessories.map(\.id))
        let shape = before.mainBridge.server.accessories.map { "\($0.id) \($0.services.map { "\($0.type.uuid)/\($0.subtype ?? "")" })" }.sorted()
        #expect(ids.contains("eWeLink:1000cccccc") && ids.contains("eWeLink:1000bbbbbbSW3") && !ids.contains("eWeLink:1000bbbbbbSW4") && !ids.contains("eWeLink:1000dddddd"))
        let block = try JSONValue(any: EWeLinkTestEnvironment.account.merging(legacy) { $1 }.merging(["platform": "eWeLink", "name": "eWeLink"]) { $1 })
        let (canonical, _) = await before.canonicalSettings(platform: EWeLinkPlugin.platform, name: "eWeLink", block: block)
        #expect(canonical["multiDevices"] == nil && canonical["thDevices"] == nil && canonical["ignoredDevices"] == nil)
        #expect(await before.deviceKind(platform: EWeLinkPlugin.platform, name: "eWeLink", deviceID: "1000bbbbbbSW1") == "multi")
        #expect(await before.deviceKind(platform: EWeLinkPlugin.platform, name: "eWeLink", deviceID: "1000aaaaaa") == "thermostat")
        await before.stop()

        let next = EWeLinkTestEnvironment()
        var settings = try #require(try JSONSerialization.jsonObject(with: canonical.encoded()) as? [String: Any])
        settings["platform"] = nil
        settings["name"] = nil
        let after = try await next.start(devices: devices, settings: settings)
        #expect(Set(after.mainBridge.server.accessories.map(\.id)) == ids)
        #expect(after.mainBridge.server.accessories.map { "\($0.id) \($0.services.map { "\($0.type.uuid)/\($0.subtype ?? "")" })" }.sorted() == shape)
        await after.stop()
    }

    /// The account's username and password move into the vault once the block is written, and leave it.
    @Test func theAccountMovesIntoTheVault() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)])
        defer { Task { await host.stop() } }
        let block = try JSONValue(any: EWeLinkTestEnvironment.account.merging(["platform": "eWeLink", "name": "eWeLink"]) { $1 })
        let (canonical, whenWritten) = await host.canonicalSettings(platform: EWeLinkPlugin.platform, name: "eWeLink", block: block)
        #expect(canonical == ["platform": "eWeLink", "name": "eWeLink", "countryCode": "+351"])
        let context = try #require(host.context(platform: EWeLinkPlugin.platform, name: "eWeLink"))
        #expect(context.credentials() == nil)
        try await whenWritten.run()
        #expect(context.credentials() == ["password": "secret", "username": "user@example.com"])
        // A block without them signs in from the vault.
        let plugin = EWeLinkPlugin(configuration: EWeLinkPlugin.Configuration(), context: context)
        let username = await plugin.configuration.username
        #expect(await plugin.accountAuthorized() == true && username == "user@example.com")
    }

    /// A device's own `disableDeviceLogging` overrules the plugin's.
    @Test func aDevicesLoggingOverrulesThePlugins() throws {
        var configuration = EWeLinkPlugin.Configuration()
        configuration.disableDeviceLogging = true
        let merged = EWeLinkPlugin.withAccessorySettings(configuration, ["1000aaaaaa": AccessorySettings(plugin: ["disableDeviceLogging": false, "hideChannels": "1"])])
        #expect(!EWeLinkPlugin.deviceLoggingDisabled(merged, "1000aaaaaaSW1") && EWeLinkPlugin.deviceLoggingDisabled(merged, "1000bbbbbb"))
        #expect(merged.multi("1000aaaaaa")?.hideChannels == "1" && merged.single("1000aaaaaa")?.disableDeviceLogging == false)
    }

    /// The schema declares each device's settings by Device Kind (the categories), and no longer the account or the lists.
    @Test func theSchemaDeclaresTheAccessorySettings() throws {
        let schema = try JSONValue(string: try #require(EWeLinkPlugin.configurationSchemaJSON))
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        let kinds = Set(["single", "multi", "thermostat", "fan", "light", "sensor", "rf_bridge", "outlet", "air_conditioner", "panel"])
        #expect(kinds.allSatisfy { DeviceCategory(rawValue: $0) != nil })
        for (key, field) in fields {
            let declared = Set(field["x-kinds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(declared.isSubset(of: kinds), "\(key)")
        }
        let read = EWeLinkPlugin.booleanKeys.union(EWeLinkPlugin.numberKeys).union(EWeLinkPlugin.stringKeys).union(["subdevices"])
        #expect(Set(fields.keys) == read)
        #expect(fields["disableDeviceLogging"]?["x-default"] == "disableDeviceLogging")
        let properties = try #require(schema["schema"]?["properties"]?.objectValue)
        for key in ["username", "password", "ignoredDevices"] + EWeLinkPlugin.deviceLists { #expect(properties[key] == nil, "\(key)") }
        #expect(properties["groups"] != nil && properties["bridgeSensors"] != nil && properties["countryCode"] != nil)
    }
}
