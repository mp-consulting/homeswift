import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// Homebridge's accessory blocks: read into the block of their platform, run by a plugin that runs them.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryBlockTests {
    @Test func accessoryBlocksJoinTheirPlatformsBlock() throws {
        let configuration = try HomeswiftConfiguration.decode(Data("""
            {
              "accessories": [
                { "accessory": "mqttthing", "name": "A" },
                { "accessory": "homebridge-mqttthing.mqttthing", "name": "B" },
                { "accessory": "mqttthing", "name": "C", "_bridge": { "username": "0E:AA:BB:CC:DD:EE" } },
                { "accessory": "mqttthing", "name": "D", "_bridge": { "username": "0E:AA:BB:CC:DD:EE" } },
                { "accessory": "Other", "name": "E" }
              ],
              "platforms": [ { "platform": "mqttthing", "name": "MQTT", "accessories": [ { "name": "Own" } ] } ]
            }
            """.utf8))
        #expect(configuration.ignoredAccessoryBlocks == 0)
        #expect(configuration.platforms.map(\.name) == ["MQTT", "mqttthing 0E:AA:BB:CC:DD:EE", "Other"])
        #expect(configuration.platforms.map(\.accessoryBlocks) == [2, 2, 1])
        #expect(configuration.platforms[1].childBridge?.username == "0E:AA:BB:CC:DD:EE")
        let names = try JSONValue(data: configuration.platforms[0].json)["accessories"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["Own", "A", "B"])
        #expect(HomeswiftConfiguration.accessoryPlatform("homebridge-mqttthing.mqttthing") == "mqttthing")
        // A malformed accessory block is left out, the others run: a Homebridge config never stops the bridge for them.
        let malformed = try HomeswiftConfiguration.decode(Data(#"""
            { "accessories": [ { "name": "No accessory" }, { "accessory": "x", "_bridge": { "username": "bad" } }, { "accessory": "x", "name": "Fine" } ] }
            """#.utf8))
        #expect(malformed.ignoredAccessoryBlocks == 2)
        #expect(malformed.platforms.map(\.isAdoptedOnly) == [true])
    }

    /// A plugin that runs accessory blocks: an accessory per block.
    actor BlockPlugin: HomeswiftPlugin {
        struct Configuration: Decodable, Sendable {
            struct Block: Decodable, Sendable { var name: String }
            var accessories: [Block]?
        }

        static let platform = "blocks"
        static let runsAccessoryBlocks = true
        let configuration: Configuration
        let context: PluginContext

        init(configuration: Configuration, context: PluginContext) {
            self.configuration = configuration
            self.context = context
        }

        func start() async throws {
            for block in configuration.accessories ?? [] {
                try context.add(Accessory(id: "blocks:\(block.name)", name: block.name, services: [Service(.switch, name: block.name)]))
            }
        }
    }

    @Test func aPluginRunsTheBlocksNamingIt() async throws {
        var registry = PluginRegistry()
        registry.register(BlockPlugin.self)
        #expect(registry.entry(for: "blocks")?.runsAccessoryBlocks == true)
        let configuration = try HomeswiftConfiguration.decode(Data("""
            { "bridge": { "name": "Test", "port": 0 },
              "accessories": [ { "accessory": "blocks", "name": "One" }, { "accessory": "homebridge-blocks.blocks", "name": "Two" } ] }
            """.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-blocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = PluginHost.Options(advertise: false, logger: Logger(label: "test")) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        #expect(host.platforms.first?.accessoryIDs.sorted() == ["blocks:One", "blocks:Two"])
        #expect(host.platforms.map(\.name) == ["blocks"])
        await host.stop()
    }

    /// A client that may not add `env:` or `file:` references cannot add them in an accessory block either: those are
    /// resolved as their platform's.
    @Test func externalReferencesInAccessoryBlocksCount() throws {
        let current = try JSONValue(string: #"{ "accessories": [ { "accessory": "mqttthing", "name": "A" } ] }"#)
        let next = try JSONValue(string: #"{ "accessories": [ { "accessory": "mqttthing", "name": "A", "password": "file:/etc/secret" } ] }"#)
        #expect(ConfigurationSecrets.newExternalReferences(in: next, comparedWith: current) == ["accessories/0:password"])
        // A block of the same name put in front, with a reference the other already has, is still new.
        let other = try JSONValue(string: #"{ "accessories": [ { "accessory": "mqttthing", "name": "A", "password": "env:PASS" } ] }"#)
        let prepended = try JSONValue(string: #"{ "accessories": [ { "accessory": "mqttthing", "name": "A", "password": "file:/etc/secret" }, { "accessory": "mqttthing", "name": "A", "password": "env:PASS" } ] }"#)
        #expect(ConfigurationSecrets.newExternalReferences(in: prepended, comparedWith: other) == ["accessories/0:password", "accessories/1:password"])
        #expect(ConfigurationSecrets.newExternalReferences(in: next, comparedWith: next).isEmpty)
    }

    /// The vault migration moves an accessory block's secrets, read as the block it runs in.
    @Test func theMigrationMovesAccessoryBlocksSecrets() throws {
        let config: JSONValue = [
            "platforms": [["platform": "mqttthing", "name": "MQTT", "password": "shared-pass"]],
            "accessories": [["accessory": "mqttthing", "name": "Desk Lamp", "password": "lamp-pass"], ["accessory": "Other", "name": "X", "token": "t-1"]],
        ]
        let plan = try VaultMigration.plan(stored: config, opened: config, existing: [:])
        let found = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.entry) })
        #expect(found["mqttthing/MQTT@accessories[0]:password"] == "mqttthing-desk-lamp-password")
        #expect(found["Other/Other@accessories[1]:token"] != nil)
        #expect(plan.config["accessories"]?.arrayValue?.first?["password"] == .string("vault:mqttthing-desk-lamp-password"))
        #expect(plan.newEntries["mqttthing-desk-lamp-password"]?.value(field: nil) == "lamp-pass")
        let uses = VaultMigration.uses(in: plan.config).map(\.block)
        #expect(uses.contains("mqttthing/MQTT"))
    }

    /// A save seals an accessory block's secrets as it does a platform block's, and the runtime opens them.
    @Test func sealedAccessorySecretsOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try SecretBox.load(storage: directory, create: true)
        let config: JSONValue = ["accessories": [["accessory": "mqttthing", "name": "A", "password": "plain-pass"]]]
        let sealed = try SecretBox.sealingSecrets(config) { try box.seal($0) }
        let stored = try #require(sealed["accessories"]?.arrayValue?.first?["password"]?.stringValue)
        #expect(SecretBox.isSealed(stored))
        let opened = try ConfigurationSecrets.opening(HomeswiftConfiguration.decode(sealed.encoded()), storage: directory)
        #expect(try JSONValue(data: opened.platforms[0].json)["accessories"]?.arrayValue?.first?["password"] == "plain-pass")
    }

    /// The settings writers find the block an instance of accessory blocks runs in, and add only the one they change.
    @Test func settingsWritersSeeTheBlocksMadeForAccessoryBlocks() throws {
        let config = try JSONValue(string: #"""
            { "platforms": [ { "platform": "Other", "name": "Other" } ],
              "accessories": [ { "accessory": "mqttthing", "name": "A", "_bridge": { "username": "0E:AA:BB:CC:DD:EE", "name": "Lights" } },
                               { "accessory": "other", "name": "B" } ] }
            """#)
        let blocks = AccessoryAdoption.platformBlocks(of: config)
        #expect(blocks.map { $0["name"]?.stringValue } == ["Other", "Lights", "other"])
        #expect(blocks[1]["_bridge"]?["username"] == "0E:AA:BB:CC:DD:EE" && blocks[1]["accessories"] == nil)
        var edited = blocks
        edited[1] = .object((blocks[1].objectValue ?? [:]).merging(["_accessories": ["A": ["room": "Hall"]]]) { $1 })
        #expect(AccessoryAdoption.keepingEdited(edited, of: config).map { $0["name"]?.stringValue } == ["Other", "Lights"])
        // Written back, the block takes the accessories in again: one instance, on its child bridge.
        var root = config.objectValue ?? [:]
        root["platforms"] = .array(AccessoryAdoption.keepingEdited(edited, of: config))
        let decoded = try HomeswiftConfiguration.decode(JSONValue.object(root).encoded())
        #expect(decoded.platforms.map(\.name) == ["Other", "Lights", "other"])
        #expect(decoded.platforms[1].accessoryBlocks == 1 && !decoded.platforms[1].isAdoptedOnly)
    }

    @Test func theImportKeepsTheBlocksOfAPluginThatRunsThem() throws {
        var registry = PluginRegistry()
        registry.register(
            platform: "mqttthing", name: "MQTT Thing",
            configurationSchemaJSON: #"{ "schema": { "properties": { "name": { "type": "string" }, "accessories": { "type": "array", "items": { "type": "object" } } } } }"#,
            runsAccessoryBlocks: true
        ) { _, _ in fatalError("not run") }
        let result = try HomebridgeImport.check(Data("""
            { "accessories": [
                { "accessory": "mqttthing", "type": "switch", "name": "Lamp", "password": "secret", "topics": { "getOn": "a" } },
                { "accessory": "homebridge-dummy.dummy", "name": "Dummy" }
              ] }
            """.utf8), registry: registry, seal: { "sealed(\($0))" })
        #expect(result.report.warnings.contains(.init("accessoriesSkipped", ["count": "1"])))
        let block = try #require(result.additions?["platforms"]?.arrayValue?.first)
        #expect(block["platform"] == "mqttthing")
        #expect(block["accessories"]?.arrayValue?.first?["topics"]?["getOn"] == "a")
        #expect(block["accessories"]?.arrayValue?.first?["password"] == "sealed(secret)")
    }
}
