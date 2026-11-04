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
        #expect(configuration.accessoryBlockCount == 5)
        #expect(configuration.platforms.map(\.name) == ["MQTT", "mqttthing 0E:AA:BB:CC:DD:EE", "Other"])
        #expect(configuration.platforms.map(\.accessoryBlocks) == [2, 2, 1])
        #expect(configuration.platforms[1].childBridge?.username == "0E:AA:BB:CC:DD:EE")
        let names = try JSONValue(data: configuration.platforms[0].json)["accessories"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["Own", "A", "B"])
        #expect(HomeswiftConfiguration.accessoryPlatform("homebridge-mqttthing.mqttthing") == "mqttthing")
        #expect(throws: ConfigurationError.self) { try HomeswiftConfiguration.decode(Data(#"{ "accessories": [ { "name": "No accessory" } ] }"#.utf8)) }
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
        #expect(ConfigurationSecrets.newExternalReferences(in: next, comparedWith: current) == ["accessory mqttthing/A:password"])
        #expect(ConfigurationSecrets.newExternalReferences(in: next, comparedWith: next).isEmpty)
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
