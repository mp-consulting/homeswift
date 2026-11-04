import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftWingman

/// The canonical shape (WingmanSettings.swift): the mirrored accessories and the bridges are Discovered Devices Excluded
/// through their Accessory Settings, and the Homebridge-shaped lists and `devices` entries move there.
@Suite(.timeLimit(.minutes(1)))
struct WingmanSettingsTests {
    let environment = TestEnvironment()

    func mirrored(_ host: PluginHost) async -> Set<String> {
        Set(host.mainBridge.server.accessories.map(\.id).filter { $0.hasPrefix("Wingman:") })
    }

    /// Each Wingman, mirrored accessory and bridge is a device of its Device Kind.
    @Test func devicesHaveTheirKinds() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await mirrored(host).contains("Wingman:light-1") })
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.discover()
        let kinds = Dictionary(devices.map { ($0.deviceID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["wm-1"] == "wingman" && kinds["light-1"] == "mirroredAccessory" && kinds["bridge:Hue Bridge"] == "bridge")
        #expect(kinds["homeswift-switch"] == nil)
        #expect(devices.first { $0.deviceID == "light-1" }?.isSetUp == true)
        #expect(await plugin.deviceKind(of: "wm-1") == "wingman")
        #expect(await plugin.deviceKind(of: "lock-1") == "mirroredAccessory")
        #expect(await plugin.deviceKind(of: "bridge:Anything") == "bridge")
        #expect(await plugin.deviceKind(of: "nothing") == nil)
    }

    /// An accessory Excluded in its Accessory Settings is not mirrored, nor are a bridge's accessories when it is; both
    /// stay Discovered Devices to include again.
    @Test func excludedAccessoriesAndBridgesAreNotMirrored() async throws {
        let host = try await environment.start(settings: [
            "devices": [TestEnvironment.paired], "_accessories": ["lock-1": ["excluded": true], "bridge:hue bridge": ["excluded": true]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { await mirrored(host).contains("Wingman:sensor-1") })
        let ids = await mirrored(host)
        #expect(!ids.contains("Wingman:lock-1") && !ids.contains("Wingman:light-1"))
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        #expect(devices.contains { $0.deviceID == "lock-1" && $0.status == .excluded })
        #expect(devices.contains { $0.deviceID == "light-1" })
    }

    /// The Homebridge-shaped lists still leave accessories out, and show as left out by the plugin's own settings.
    @Test func theListsStillLeaveAccessoriesOut() async throws {
        let host = try await environment.start(settings: ["devices": [TestEnvironment.paired], "exclude": ["porte"], "excludeBridges": ["HUE BRIDGE"]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await mirrored(host).contains("Wingman:sensor-1") })
        let ids = await mirrored(host)
        #expect(!ids.contains("Wingman:lock-1") && !ids.contains("Wingman:light-1"))
        let devices = try await #require(environment.plugin).discover()
        #expect(devices.first { $0.deviceID == "lock-1" }?.excludedBySettings == true)
        #expect(devices.first { $0.deviceID == "bridge:Hue Bridge" }?.excludedBySettings == true)
    }

    /// `exclude` by name or id, `excludeBridges` by name and a paired `devices` entry move into `_accessories`; what no
    /// device answers to stays.
    @Test func canonicalSettingsMovesTheLists() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await mirrored(host).contains("Wingman:light-1") })
        let block = try JSONValue(any: [
            "platform": "Wingman", "name": "Wingman", "homes": ["Maison"],
            "devices": [TestEnvironment.paired, ["host": "10.0.0.9"]],
            "exclude": ["porte", "tv-1", "Gone"], "excludeBridges": ["hue bridge", "Other Hub"],
            "_accessories": ["tv-1": ["room": "Salon"]],
        ] as [String: Any])
        let canonical = await host.canonicalSettings(platform: WingmanPlugin.platform, name: WingmanPlugin.name, block: block).block
        #expect(canonical == (try JSONValue(any: [
            "platform": "Wingman", "name": "Wingman", "homes": ["Maison"],
            "devices": [["host": "10.0.0.9"]], "exclude": ["Gone"],
            "_accessories": [
                "tv-1": ["room": "Salon", "excluded": true], "lock-1": ["excluded": true], "bridge:Hue Bridge": ["excluded": true],
                "bridge:Other Hub": ["excluded": true], "wm-1": ["name": "Mac mini", "host": "10.0.0.5"],
            ],
        ] as [String: Any])))
        // A Wingman whose token the vault does not keep stays in `devices`.
        #expect(WingmanPlugin.canonical(block, accessories: [], bridges: [], paired: [])["devices"] == block["devices"])
    }

    /// What canonicalSettings wrote runs the same Wingman, from the vault.
    @Test func theMovedWingmanRuns() async throws {
        let first = try await environment.start()
        await first.stop()
        let host = try await environment.start(settings: ["_accessories": ["wm-1": ["name": "Mac mini", "host": "10.0.0.5"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await mirrored(host).contains("Wingman:light-1") })
    }

    /// The schema keeps no token, and declares a Wingman's address for its Device Kind.
    @Test func theSchemaDeclaresTheSettings() throws {
        let schema = try JSONValue(string: try #require(WingmanPlugin.configurationSchemaJSON))
        #expect(schema["schema"]?["properties"]?["devices"]?["items"]?["properties"]?["token"] == nil)
        #expect(schema["schema"]?["properties"]?["exclude"] == nil)
        #expect(schema["accessorySchema"]?["properties"]?["host"]?["x-kinds"] == ["wingman"])
        #expect(schema["accessorySchema"]?["properties"]?["port"]?["x-kinds"] == ["wingman"])
    }
}
