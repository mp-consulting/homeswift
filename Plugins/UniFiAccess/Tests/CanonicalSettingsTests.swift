import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiAccess

/// The canonical shape (AccessCanonicalSettings.swift): feature options as Accessory Settings and Plugin Settings, a
/// running controller's `controllers` entry as its Accessory Settings and its login in the vault, and the Device Kinds.
@Suite struct CanonicalSettingsTests {
    let environment = AccessTestEnvironment()
    let controllerMAC = "001122334455"

    static let known = [
        UniFiAccessPlugin.KnownController(
            mac: "001122334455", address: "10.0.0.1",
            devices: [(id: "AABBCCDDEEFF", kind: "hub"), (id: "112233445566", kind: "hub"), (id: "AA0000000002", kind: "reader")]),
    ]

    /// Each kind of option goes where it belongs; what no setting says stays in `options`, and a later entry that never
    /// applied goes.
    @Test func optionsBecomeSettings() throws {
        let block = try JSONValue(any: [
            "platform": "UniFi Access", "name": "UniFi Access", "ringDelay": 5,
            "controllers": [["address": "10.0.0.1", "username": "homeswift", "password": "secret", "name": "UDM", "mqttUrl": "mqtt://broker"], ["address": "10.0.0.8"]],
            "options": [
                "Disable.Device.AABBCCDDEEFF", "Disable.Hub.DPS.112233445566", "Enable.Hub.LockDelayInterval.112233445566.5", "Enable.Hub.Lock.Trigger",
                "Disable.Hub.Lock.Trigger", "Disable.Hub.Doorbell.001122334455", "Enable.Hub.Doorbell.AABBCCDDEEFF", "Enable.Controller.Publish.Telemetry.001122334455",
                "Enable.AccessMethod.Face.001122334455", "Disable.AccessMethod.Face.AA0000000002", "Enable.Controller.DelayDeviceRemoval.30",
                "Enable.Hub.LockDelayInterval.AABBCCDDEEFF", "Disable.Device", "Enable.Device.112233445566", "Enable.Nothing.Here", "Enable.Hub.LockDelayInterval.x.y.z",
            ],
            "_accessories": ["112233445566": ["lockDelayInterval": 2, "room": "Garden"]],
        ] as [String: Any])
        let canonical = UniFiAccessPlugin.canonical(block, controllers: Self.known, logins: [controllerMAC])
        #expect(canonical == (try JSONValue(any: [
            "platform": "UniFi Access", "name": "UniFi Access", "ringDelay": 5,
            "controllers": [["address": "10.0.0.8"]],
            "lockTrigger": true, "delayDeviceRemoval": 30,
            "options": ["Enable.Hub.LockDelayInterval.AABBCCDDEEFF", "Disable.Device", "Enable.Device.112233445566", "Enable.Nothing.Here", "Enable.Hub.LockDelayInterval.x.y.z"],
            "_accessories": [
                "001122334455": ["address": "10.0.0.1", "mqttUrl": "mqtt://broker", "name": "UDM", "publishTelemetry": true],
                "AABBCCDDEEFF": ["excluded": true, "parts": ["Doorbell": true], "accessMethodFace": true],
                "112233445566": ["lockDelayInterval": 2, "room": "Garden", "parts": ["DPS": false, "Doorbell": false], "accessMethodFace": true],
                "AA0000000002": ["accessMethodFace": false],
            ],
        ] as [String: Any])))
        // A controller the instance does not run, or whose login the vault does not keep, stays in `controllers`, and an
        // option scoped to it stays in `options`.
        let alone = UniFiAccessPlugin.canonical(block, controllers: [], logins: [])
        #expect(alone["controllers"] == block["controllers"])
        #expect(alone["options"]?.arrayValue?.contains("Disable.Hub.Doorbell.001122334455") == true)
        // The canonical shape is a fixed point.
        #expect(UniFiAccessPlugin.canonical(canonical, controllers: Self.known, logins: [controllerMAC]) == canonical)
    }

    /// A device turned back on under a controller an option leaves out stays an option, wherever the controller's comes.
    @Test func aDeviceOnUnderAControllerOffStaysWhereverItComes() throws {
        for options in [["Enable.Device.112233445566", "Disable.Device.001122334455"], ["Disable.Device.001122334455", "Enable.Device.112233445566"]] {
            let block = try JSONValue(any: ["platform": "UniFi Access", "name": "UniFi Access", "options": options] as [String: Any])
            let canonical = UniFiAccessPlugin.canonical(block, controllers: Self.known, logins: [controllerMAC])
            #expect(canonical["options"] == ["Enable.Device.112233445566"])
            #expect(canonical["_accessories"]?["001122334455"]?["excluded"] == true)
        }
    }

    /// The settings mean what the options meant: a Plugin Setting is the option without a scope, a device's own setting
    /// the option scoped to it, and both come before the block's own options.
    @Test func settingsAreReadAsOptions() {
        let options = UniFiAccessPlugin.settingOptions(
            plugin: ["lockTrigger": true, "lockDelayInterval": 3, "dps": false, "ringDelay": 5],
            accessories: ["AABBCCDDEEFF": AccessorySettings(plugin: ["lockDelayInterval": 0, "accessMethodFace": false]), "not-an-id": AccessorySettings(plugin: ["lockTrigger": false])])
        #expect(options == [
            "Enable.Hub.LockDelayInterval.AABBCCDDEEFF.0", "Disable.AccessMethod.Face.AABBCCDDEEFF", "Enable.Hub.LockDelayInterval.3", "Enable.Hub.Lock.Trigger", "Disable.Hub.DPS",
        ])
        let engine = AccessOptions.make(options + ["Disable.Hub.Lock.Trigger", "Enable.Hub.LockDelayInterval.AABBCCDDEEFF.9"])
        #expect(engine.test("Hub.Lock.Trigger", device: "112233445566"))
        #expect(engine.integer("Hub.LockDelayInterval", device: "AABBCCDDEEFF").value == 0)
        #expect(engine.integer("Hub.LockDelayInterval", device: "112233445566").value == 3)
    }

    /// A block with only the canonical settings runs as the options did: a Plugin Setting for every hub, a hub's own.
    @Test func canonicalSettingsRun() async throws {
        environment.controller.setDevices([uah(), ugt()])
        let host = try environment.host(settings: [
            "controllers": [AccessTestEnvironment.controllerBlock], "lockTrigger": true,
            "options": ["Disable.Hub.Sensors.SeparateAccessory", "Disable.Hub.SideDoor.SeparateAccessory"],
            "_accessories": ["AABBCCDDEEFF": ["lockTrigger": false], "112233445566": ["sideDoorLockTrigger": true]],
        ])
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { accessory(host, gateID) != nil && accessory(host, hubID) != nil })
        let gate = try #require(accessory(host, gateID))
        #expect(gate.service(.switch, "LockTrigger") != nil)
        #expect(gate.service(.switch, "Switch.Lock.Door.Side.Trigger") != nil)
        #expect(accessory(host, hubID)?.service(.switch, "LockTrigger") == nil)
    }

    /// The running instance moves its controller's login into the vault and the entry into its Accessory Settings.
    @Test func theRunningInstanceMovesTheController() async throws {
        let host = try await environment.start(devices: [uah(), ultra()], options: ["Disable.Hub.DPS.001122334455"])
        defer { Task { await host.stop() } }
        let block = try JSONValue(any: [
            "platform": "UniFi Access", "name": "UniFi Access", "controllers": [AccessTestEnvironment.controllerBlock],
            "options": ["Disable.Hub.DPS.001122334455"],
        ] as [String: Any])
        let (canonical, whenWritten) = await host.canonicalSettings(platform: UniFiAccessPlugin.platform, name: "UniFi Access", block: block)
        #expect(canonical["controllers"] == nil && canonical["options"] == nil)
        #expect(canonical["_accessories"]?[controllerMAC]?["address"] == "10.0.0.1")
        #expect(canonical["_accessories"]?["AABBCCDDEEFF"]?["parts"]?["DPS"] == false)
        #expect(canonical["_accessories"]?["AA0000000001"]?["parts"]?["DPS"] == false)
        let context = try #require(host.context(platform: UniFiAccessPlugin.platform, name: "UniFi Access"))
        // The login goes into the vault when the block is written.
        #expect(context.credentials(for: controllerMAC) == nil)
        try await whenWritten.run()
        #expect(context.credentials(for: controllerMAC, as: UniFiAccessPlugin.ControllerLogin.self) == .init(username: "homeswift", password: "secret"))
        await host.stop()

        // The moved block runs the same controller.
        var settings = try #require(try JSONSerialization.jsonObject(with: Data(canonical.text().utf8)) as? [String: Any])
        settings["platform"] = nil
        settings["name"] = nil
        let moved = try environment.host(settings: settings)
        try await moved.start()
        defer { Task { await moved.stop() } }
        #expect(await eventually { accessory(moved, hubID) != nil })
        #expect(accessory(moved, hubID)?.service(.contactSensor, "ContactSensor.DPS") == nil)
    }

    /// Every device has its Device Kind, in discovery and from the running instance.
    @Test func devicesHaveTheirKinds() async throws {
        let host = try await environment.start(devices: [uah(), ultra()])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let kinds = Dictionary(try await plugin.discover().map { ($0.deviceID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds[controllerMAC] == "controller" && kinds["AABBCCDDEEFF"] == "hub" && kinds["AA0000000001"] == "hub")
        #expect(await plugin.deviceKind(of: controllerMAC) == "controller")
        #expect(await plugin.deviceKind(of: "aabbccddeeff") == "hub")
        #expect(await plugin.deviceKind(of: "FFFFFFFFFFFF") == nil)
    }

    /// The schema declares every setting of the table: each one a Plugin Setting, each with an accessory field its own
    /// default, of the table's Device Kinds, but the Parts, which `parts` keeps; and a controller's own.
    @Test func theSchemaMatchesTheOptions() throws {
        let schema = try JSONValue(string: UniFiAccessPlugin.configurationSchemaJSON ?? "")
        let plugin = try #require(schema["schema"]?["properties"]?.objectValue)
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        #expect(UniFiAccessPlugin.optionSettings.count == UniFiAccessPlugin.optionNames.count - 1)
        #expect(Set(UniFiAccessPlugin.optionSettings.map(\.option)) == Set(UniFiAccessPlugin.optionNames).subtracting(["Device"]))
        for setting in UniFiAccessPlugin.optionSettings {
            let declared = try #require(plugin[setting.key], "\(setting.key) is not a Plugin Setting")
            #expect(declared["type"] == (setting.isNumber ? "integer" : "boolean"))
            if let kinds = setting.kinds {
                let field = try #require(fields[setting.key], "\(setting.key) has no accessory field")
                #expect(field["x-kinds"] == JSONValue.array(kinds.map(JSONValue.string)))
                #expect(field["x-default"] == JSONValue.string(setting.key))
            } else {
                #expect(fields[setting.key] == nil)
            }
        }
        let controllerFields = fields.filter { $0.value["x-kinds"] == ["controller"] && $0.value["x-default"] == nil }.keys
        #expect(Set(controllerFields) == Set(UniFiAccessPlugin.controllerKeys))
        #expect(plugin["controllers"]?["items"]?["properties"]?["password"] == nil)
    }
}
