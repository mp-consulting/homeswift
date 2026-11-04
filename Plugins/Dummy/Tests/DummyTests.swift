import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDummy

/// A bridge with one `HomebridgeDummy` block.
final class TestEnvironment: Sendable {
    let directory = temporaryDirectory()
    let logs = LogBuffer()
    private let plugins = NIOLockedValueBox<[DummyPlugin]>([])

    var plugin: DummyPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let logs = logs
        registry.register(platform: DummyPlugin.platform, name: DummyPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(DummyPlugin.Configuration.self, from: json)
            var dependencies = DummyPlugin.Dependencies()
            dependencies.logs = logs
            dependencies.defaultWebhookPort = 0
            dependencies.engine.notifier = FakeNotifier()
            let plugin = DummyPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: DummyPlugin.platform, name: DummyPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DummyTests {
    let environment = TestEnvironment()

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(DummyPlugin.Configuration.self, from: Data(#"{"platform":"HomebridgeDummy","verbose":"yes"}"#.utf8))
        #expect(configuration.accessories == nil)
    }

    /// TV1's identity and information.
    @Test func eachEntryBecomesAnAccessory() async throws {
        let host = try await environment.start(settings: ["accessories": [
            ["name": "My Switch", "type": "Switch"],
            ["id": "lamp", "name": "Lamp", "type": "Lightbulb", "isDimmer": true],
            ["name": "Nameless type"],
            ["name": "Toaster", "type": "Toaster"],
        ]])
        defer { Task { await host.stop() } }
        let id = "HomebridgeDummy:Switch:MySwitch"
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == id })
        #expect(accessory.information[.serialNumber]?.value == .string("HomebridgeDummy:Switch:MySwitch"))
        #expect(accessory.information[.model]?.value == .string("Switch"))
        #expect(accessory.information[.manufacturer]?.value == .string("Homebridge Dummy"))
        let switchService = try #require(accessory.service(.switch))
        #expect(switchService.isPrimary)
        let lamp = try #require(host.mainBridge.server.accessories.first { $0.id == "HomebridgeDummy:lamp" })
        #expect(lamp.service(.lightbulb)?[.brightness] != nil)
        #expect(host.mainBridge.server.accessories.count == 3)

        // A write from HomeKit reaches the engine and is stored.
        let on = try #require(switchService[.on])
        try await on.write(.bool(true))
        #expect(on.value == .bool(true))
        let devices = try await #require(environment.plugin).discover()
        #expect(Set(devices.map(\.deviceID)) == ["Switch:MySwitch", "lamp"])
        await host.stop()
    }

    /// TV3: one accessory for the group, a service of each member.
    @Test func aGroupIsOneAccessory() async throws {
        let host = try await environment.start(settings: ["accessories": [
            ["id": "a1", "name": "Lamp", "type": "Lightbulb", "groupName": "Living Room"],
            ["id": "b2", "name": "Fan", "type": "Switch", "groupName": "Living Room", "enableWebhook": true],
        ], "webhookConfig": ["disableSSL": true, "bindAddress": "127.0.0.1"]])
        defer { Task { await host.stop() } }
        let id = "HomebridgeDummy:Group:LivingRoom)}"
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == id })
        #expect(accessory.information[.model]?.value == .string("GroupAccessory"))
        #expect(accessory.information[.serialNumber]?.value == .string("c2d8b53c-f535-47da-973d-eee490dcbff7"))
        #expect(accessory.name == "Living Room")
        let lamp = try #require(accessory.services.first { $0.subtype == "a1" })
        #expect(lamp.type == .lightbulb)
        #expect(lamp[.configuredName]?.value == .string("Lamp"))
        #expect(accessory.services.first { $0.subtype == "b2" }?.type == .switch)
        let plugin = try #require(environment.plugin)
        #expect(await plugin.webhookServer?.port != nil)
        await host.stop()
    }

    @Test func logConditionsFollowTheBridgesLog() async throws {
        let host = try await environment.start(settings: ["accessories": [
            ["id": "bell", "name": "Bell", "type": "Switch", "conditions": ["operator": "or", "operands": [["type": "LOG", "pattern": "Doorbell rang"]]]],
        ]])
        defer { Task { await host.stop() } }
        let accessory = try #require(await eventually { host.mainBridge.server.accessories.contains { $0.id == "HomebridgeDummy:bell" } } ? host.mainBridge.server.accessories.first { $0.id == "HomebridgeDummy:bell" } : nil)
        environment.logs.append(LogBuffer.Line(level: .info, label: "Other plugin", text: "Doorbell rang at the front"))
        #expect(await eventually { accessory.service(.switch)?[.on]?.value == .bool(true) })
        await host.stop()
    }

    @Test func canonicalSettingsRewriteTheDeprecatedKeys() throws {
        let block = try JSONValue(string: """
            {"platform":"HomebridgeDummy","webhookPort":8080,"accessories":[
              {"name":"A","type":"Switch","defaultOn":true,"enableWebook":true,"sensor":{"type":"MotionSensor","timerControlled":true}},
              {"name":"B","type":"Lightbulb","defaultBrightness":40,"fadeOut":true,"autoReset":{"type":"TIMEOUT","time":5,"units":"MINUTES"}},
              {"name":"C","type":"Switch","conditions":{"operator":"or","operands":[{"type":"PING","pingHost":"x","pingInterval":5,"pingUnits":"MINUTES"}]}},
              {"id":"m","name":"M","type":"Outlet","protocol":"Matter"}]}
            """)
        let canonical = DummyPlugin.canonical(block)
        #expect(canonical["webhookConfig"]?["port"] == 8080)
        #expect(canonical["webhookPort"] == nil)
        let entries = try #require(canonical["accessories"]?.arrayValue)
        #expect(entries[0]["defaultState"] == "on")
        #expect(entries[0]["enableWebhook"] == true)
        #expect(entries[0]["sensor"]?["behavior"] == "TIMER")
        #expect(entries[1]["isDimmer"] == true)
        #expect(entries[1]["fadeOut"] == ["type": "FIXED", "time": 5, "units": "MINUTES"])
        #expect(entries[1]["autoReset"] == nil)
        #expect(entries[2]["conditions"]?["operands"]?[0]?["checkInterval"] == 5)
        #expect(canonical["_accessories"]?["m"]?["notInHome"] == true)
        #expect(DummyPlugin.canonical(canonical) == canonical)
    }

    @Test func secretsMoveToTheVault() async throws {
        let host = try await environment.start(settings: [
            "webhookConfig": ["token": "hook-token", "bindAddress": "127.0.0.1"],
            "accessories": [["id": "n", "name": "N", "type": "Switch", "enableWebhook": true,
                             "notification": ["api": "PUSHOVER", "token": "user-key", "id": "app-token", "text": "On"]]],
        ])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let block = try JSONValue(any: [
            "platform": "HomebridgeDummy", "webhookConfig": ["token": "hook-token"],
            "accessories": [["id": "n", "name": "N", "type": "Switch", "notification": ["api": "PUSHOVER", "token": "user-key", "id": "app-token", "text": "On"]]],
        ])
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["webhookConfig"]?["token"] == nil)
        #expect(canonical["accessories"]?[0]?["notification"]?["token"] == nil)
        #expect(canonical["accessories"]?[0]?["notification"]?["id"] == nil)
        #expect(canonical["accessories"]?[0]?["notification"]?["text"] == "On")
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(DummyPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Dummy DummyPlugin")
        let schema = try JSONValue(string: try #require(DummyPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "HomebridgeDummy")
    }
}
