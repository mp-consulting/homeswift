import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftDysonPureCool

/// Settings: a Homebridge block's `devices` moves into `_accessories` by serial, its inverse switches turned into the
/// positive ones whose defaults are the plugin-wide switches, its credentials into the vault; both shapes load, with the
/// same accessories.
@Suite(.timeLimit(.minutes(1)))
struct SettingsTests {
    func subtypes(_ host: PluginHost) -> [String] {
        (host.mainBridge.server.accessories.first { $0.id == accessoryID }?.services.compactMap(\.subtype) ?? []).sorted()
    }

    /// Each entry's settings under its serial, typed, the inverse keys as their switches (`isTemperatureIgnored: true` is
    /// `enableTemperature: false`), `name` as the Name; its credential answered for the vault where it has none. What
    /// `_accessories` has stays; an entry without a serial, or whose credential cannot be read, stays in `devices`.
    @Test func theDevicesListMovesIntoAccessorySettings() throws {
        let block = try JSONValue(any: [
            "platform": "DysonPureCool", "name": "Dyson", "enableTemperature": true,
            "devices": [
                ["serial": serial, "name": "Living Room", "productType": "527", "localCredentials": "secret", "ipAddress": "192.168.1.50",
                 "firmwareVersion": "1.0", "temperatureOffset": "1.5", "isTemperatureIgnored": true, "isHumidityIgnored": "false",
                 "isHeatingDisabled": true, "isNightModeEnabled": false, "isContinuousMonitoringEnabled": true, "isFilterStatusDisabled": false,
                 "heatingServiceType": "both", "isHeatingSafetyIgnored": true, "enableOscillationWhenActivating": true],
                ["serial": "AAA-AA-00000002", "productType": "358", "credentials": "kept", "isHumidifierDisabled": true, "fullRangeHumidity": true],
                ["serial": "AAA-AA-00000003", "productType": "438", "localCredentials": "vault:somewhere"],
                ["name": "No serial", "productType": "438"],
            ],
            "_accessories": [serial: ["temperatureOffset": 2]],
        ] as [String: Any])
        let (canonical, credentials) = DysonPureCoolPlugin.canonical(block, hasCredential: { $0 == "AAA-AA-00000002" }) { _, written in
            DysonPureCoolPlugin.isReference(written) ? nil : written
        }
        #expect(canonical == (try JSONValue(any: [
            "platform": "DysonPureCool", "name": "Dyson", "enableTemperature": true,
            "devices": [
                ["serial": "AAA-AA-00000003", "productType": "438", "localCredentials": "vault:somewhere"],
                ["name": "No serial", "productType": "438"],
            ],
            "_accessories": [
                serial: [
                    "name": "Living Room", "productType": "527", "ipAddress": "192.168.1.50", "firmwareVersion": "1.0", "temperatureOffset": 2,
                    "enableTemperature": false, "enableHumidity": true, "enableHeater": false, "enableNightMode": false,
                    "enableContinuousMonitoring": true, "enableFilterStatus": true, "heatingServiceType": "both", "enableOscillationWhenActivating": true,
                ],
                "AAA-AA-00000002": ["productType": "358", "enableHumidifier": false, "fullRangeHumidity": true],
            ],
        ] as [String: Any])))
        #expect(credentials == [serial: "secret"])
        // Canonical already: the entries left are still left, nothing more moves.
        let again = DysonPureCoolPlugin.canonical(canonical, hasCredential: { _ in false }) { _, _ in nil }
        #expect(again.block["_accessories"] == canonical["_accessories"] && again.credentials.isEmpty)
    }

    /// The running instance moves the block's credential into the vault once the settings are written; the canonical
    /// block then runs the same device, with the same accessory, its services and the credential from the vault.
    @Test func theCanonicalBlockKeepsTheAccessory() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.hp04)
        let legacy: [String: Any] = ["devices": [deviceBlock("527", extra: ["isTemperatureIgnored": true, "isNightModeEnabled": false])]]
        let first = try await environment.start(settings: legacy)
        let accessory = try #require(first.mainBridge.server.accessories.first { $0.id == accessoryID })
        let aid = accessory.aid
        let services = subtypes(first)
        #expect(!services.contains("temperature-sensor") && !services.contains("night-mode"))
        #expect(await first.deviceKind(platform: DysonPureCoolPlugin.platform, name: "Dyson", deviceID: serial) == "heater")

        let block = try JSONValue(any: legacy.merging(["platform": "DysonPureCool", "name": "Dyson"]) { $1 })
        let canonical = await first.canonicalSettings(platform: DysonPureCoolPlugin.platform, name: "Dyson", block: block)
        #expect(canonical["devices"] == nil)
        #expect(canonical["_accessories"] == [serial: [
            "name": "Living Room", "productType": "527", "ipAddress": "192.168.1.50", "enableTemperature": false, "enableNightMode": false,
        ]])
        let context = try #require(first.context(platform: DysonPureCoolPlugin.platform, name: "Dyson"))
        #expect(context.credentials(for: serial) == ["localCredentials": "secret"])
        await first.stop()

        var settings = try #require(try JSONSerialization.jsonObject(with: canonical.encoded()) as? [String: Any])
        settings.removeValue(forKey: "platform")
        settings.removeValue(forKey: "name")
        let second = try await environment.start(settings: settings)
        defer { Task { await second.stop() } }
        let again = try #require(second.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(again.aid == aid && again.name == "Living Room")
        #expect(subtypes(second) == services)
        #expect(environment.dyson.connects.last?.password == "secret")
    }

    /// A device's own switch overrules the plugin-wide one it defaults to, and a Homebridge entry's inverse key.
    @Test func aDevicesOwnSwitchOverrulesTheDefault() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.tp04)
        let host = try await environment.start(settings: [
            "devices": [deviceBlock(extra: ["isHumidityIgnored": true])], "enableTemperature": false, "enableAirQuality": false,
            "_accessories": [serial: ["enableTemperature": true, "enableHumidity": true]],
        ])
        defer { Task { await host.stop() } }
        let services = subtypes(host)
        #expect(services.contains("temperature-sensor") && services.contains("humidity-sensor") && !services.contains("air-quality-sensor"))
        #expect(await host.deviceKind(platform: DysonPureCoolPlugin.platform, name: "Dyson", deviceID: serial) == "purifier")
    }

    /// Device Kinds follow the product type.
    @Test func deviceKinds() {
        #expect(DysonPureCoolPlugin.kind(ofProductType: "438") == "purifier")
        #expect(DysonPureCoolPlugin.kind(ofProductType: "455") == "heater" && DysonPureCoolPlugin.kind(ofProductType: "527K") == "heater")
        #expect(DysonPureCoolPlugin.kind(ofProductType: "358E") == "humidifier")
        #expect(DysonPureCoolPlugin.kind(ofProductType: "664") == "purifier" && DysonPureCoolPlugin.kind(ofProductType: nil) == nil)
    }

    /// The schema declares the devices' settings, each switch defaulting to the plugin-wide one of its name, and no
    /// longer the devices list or its credentials.
    @Test func theSchemaDeclaresTheAccessorySettings() throws {
        let schema = try JSONValue(string: try #require(DysonPureCoolPlugin.configurationSchemaJSON))
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        #expect(Set(fields.keys) == DysonPureCoolPlugin.accessoryKeys)
        let properties = try #require(schema["schema"]?["properties"]?.objectValue)
        #expect(properties["devices"] == nil && properties["discoveryTimeout"] != nil)
        for item in DysonPureCoolPlugin.switches {
            #expect(fields[item.setting]?["x-default"]?.stringValue == item.setting && properties[item.setting] != nil, "\(item.setting)")
        }
        #expect(fields["enableHeater"]?["x-kinds"] == ["heater"] && fields["fullRangeHumidity"]?["x-kinds"] == ["humidifier"])
        // Every model the plugin knows is a choice of productType: Setup writes it.
        let choices = Set((fields["productType"]?["oneOf"]?.arrayValue ?? []).compactMap { $0["enum"]?[0]?.stringValue })
        #expect(Set(DeviceCatalog.models.map(\.productType)).isSubset(of: choices))
    }
}
