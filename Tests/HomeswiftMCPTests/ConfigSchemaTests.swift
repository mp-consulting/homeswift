import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

private let accept: JSONValue = ["action": "accept", "content": ["confirm": true]]

/// A save checks what it changes in a plugin block against the plugin's config.schema.json.
@Suite struct ConfigSchemaTests {
    /// Homebridge's shape: `required: true` on a property, a select as a oneOf of titled enums, a password type.
    static let schema = """
        {
          "pluginAlias": "Devices",
          "schema": {
            "type": "object",
            "properties": {
              "name": { "type": "string", "required": true, "default": "Devices" },
              "host": { "type": "string", "required": true },
              "token": { "type": "password" },
              "pollingRate": { "type": "integer", "minimum": 250 },
              "mode": { "type": "string", "oneOf": [{ "title": "A", "enum": ["a"] }, { "title": "B", "enum": ["b"] }] },
              "devices": { "type": "array", "items": { "type": "object", "properties": { "mac": { "type": "string", "required": true } } } }
            }
          }
        }
        """

    /// The block starts with two old mistakes: no host, and a mode outside the list.
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "token": "secret-token", "mode": "z", "_paused": false },
            { "platform": "Ghost", "name": "Nobody" }
          ]
        }
        """

    func environment() throws -> MCPTestEnvironment {
        try MCPTestEnvironment(config: Self.config, schema: Self.schema, blockSchemas: ["Ghost": #"{ "schema": { "properties": { "level": { "type": "integer" } } } }"#])
    }

    func problems(_ body: () async throws -> JSONValue) async -> [String] {
        do {
            _ = try await body()
            return []
        } catch let error as ConfigSchemaError {
            return error.problems.map { "\(JSONSchema.Problem.location($0.path)) \($0.message)" }
        } catch {
            return ["unexpected \(error)"]
        }
    }

    @Test func checksWhatASaveChanges() async throws {
        let environment = try environment()
        let catalog = environment.catalog
        let devices = { (edit: @escaping (inout [String: JSONValue]) -> Void) in
            { try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false) { edit(&$0) } }
        }

        // The old mistakes stay out of it: only the setting changed is checked.
        #expect(await problems(devices { $0["pollingRate"] = 100 }) == ["platforms[0].pollingRate must be >= 250"])
        #expect(await problems(devices { $0["pollingRate"] = 500 }).isEmpty)
        #expect(await problems(devices { $0["mode"] = "c" }) == [#"platforms[0].mode must be one of "a", "b""#])
        #expect(await problems(devices { $0["mode"] = "b" }).isEmpty)
        #expect(await problems(devices { $0["pollingRate"] = "fast" }) == ["platforms[0].pollingRate must be integer"])
        #expect(await problems(devices { $0["token"] = 12 }) == ["platforms[0].token must be string"])
        #expect(await problems(devices { $0["devices"] = [["mac": "AA"], ["name": "no mac"]] }) == ["platforms[0].devices[1].mac is required"])
        // Removing a required setting is a change; pausing (the runtime's own key) is not the plugin's.
        #expect(await problems(devices { $0["name"] = nil }).isEmpty)
        #expect(await problems(devices { $0["_paused"] = true }).isEmpty)
        let written = try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]
        #expect(written?["pollingRate"] == 500 && written?["mode"] == "b" && written?["_paused"] == true)

        // A new block is checked whole; the runtime's own blocks against the schemas the catalog was given.
        let added = { try await catalog.editBlock(platform: "Devices", name: "Second", dryRun: false) { $0["pollingRate"] = 1 } }
        #expect(await problems(added) == ["platforms[2].host is required", "platforms[2].pollingRate must be >= 250"])
        #expect(await problems { try await catalog.editBlock(platform: "Ghost", name: "Nobody", dryRun: false) { $0["level"] = "high" } } == ["platforms[1].level must be integer"])
        // A block no schema describes is not checked.
        #expect(await problems { try await catalog.editBlock(platform: "Unknown", name: "U", dryRun: false) { $0["level"] = "high" } }.isEmpty)

        // Saving anyway, a dry run, a restored backup.
        #expect(await problems { try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false, checkSchemas: false) { $0["pollingRate"] = 100 } }.isEmpty)
        #expect(await problems { try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: true) { $0["pollingRate"] = 1 } } == ["platforms[0].pollingRate must be >= 250"])
        let backup = try #require(catalog.backups().last)
        #expect(await problems { try await catalog.restoreConfigBackup(backup) }.isEmpty)
    }

    @Test func describesTheProblemsForThePageAndTheModel() async throws {
        let environment = try environment()
        do {
            _ = try await environment.catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false) { $0["pollingRate"] = 100; $0["devices"] = [[:]] }
            Issue.record("saved")
        } catch let error as ConfigSchemaError {
            #expect(error.description == "The settings do not match the plugin's schema: Devices: devices[0].mac is required; Devices: pollingRate must be >= 250")
            #expect(error.problems[1].json == ["platform": "Devices", "path": ["platforms", 0, "pollingRate"], "message": "must be >= 250", "text": "pollingRate must be >= 250"])
        }
    }

    @Test func toolsCheckUnlessToldToIgnoreTheSchema() async throws {
        let environment = try environment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let refused = try await client.tool("patch_config", ["platform": "Devices", "settings": ["pollingRate": 100]], answer: accept)
        #expect(refused["isError"] == true)
        #expect(refused["content"]?[0]?["text"]?.stringValue?.contains("pollingRate must be >= 250") == true)
        let saved = try await client.tool("patch_config", ["platform": "Devices", "settings": ["pollingRate": 100], "ignoreSchema": true], answer: accept)
        #expect(saved["isError"] == nil)
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]?["pollingRate"] == 100)
    }
}
