import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// `rename_accessory` and the web UI's rename: the name goes in the plugin's block (`_accessories`, by Device Id), on the
/// accessory at once, and back on it after a restart; a rename from the Home app (a write of Configured Name) is kept the
/// same way.
@Suite(.timeLimit(.minutes(1)))
struct RenameAccessoryTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:59", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "mirroredBulb": true },
            { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """

    func block(_ environment: MCPTestEnvironment) throws -> JSONValue? {
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        return config["platforms"]?.arrayValue?.first { $0["platform"] == "Devices" }
    }

    @Test func renamesInTheBlockAndKeepsTheNameAcrossARestart() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        // A name the web UI showed instead goes: there is one name now.
        _ = try environment.catalog.updateLayout(["accessories": ["Devices:lamp": ["name": "Old Display Name", "room": "Office"]]])

        let result = try await client.tool("rename_accessory", ["id": "Devices:lamp", "name": "  Reading   Lamp "])
        #expect(result["isError"] != true)
        #expect(result["structuredContent"]?["name"] == "Reading Lamp")
        #expect(try block(environment)?["_accessories"] == ["lamp": ["name": "Reading Lamp"]])
        let lamp = try #require(environment.catalog.find(id: "Devices:lamp")).accessory
        #expect(lamp.name == "Reading Lamp")
        #expect(lamp[.lightbulb]?[.configuredName]?.value == .string("Reading Lamp"))
        #expect(environment.catalog.home.layout.value.accessories["Devices:lamp"] == AccessoryLayout.Entry(room: "Office"))
        #expect(environment.auditEntries.contains { $0["tool"] == "rename_accessory" })

        // Another controller's accessory is renamed there.
        let mirrored = try await client.tool("rename_accessory", ["id": "Devices:mirrored", "name": "Ceiling"])
        #expect(mirrored["isError"] == true)
        await environment.stop()

        // The next run reads the name from its block.
        let saved = try #require(try block(environment)?["_accessories"])
        let restarted = try MCPTestEnvironment(config: Self.config.replacingOccurrences(
            of: #""mirroredBulb": true"#, with: #""mirroredBulb": true, "_accessories": \#(saved.text())"#))
        try await restarted.start()
        let again = try #require(restarted.catalog.find(id: "Devices:lamp")).accessory
        #expect(again.name == "Reading Lamp" && again[.lightbulb]?[.configuredName]?.value == .string("Reading Lamp"))

        // Empty: the plugin's name again, and the block as it was.
        _ = try await restarted.catalog.setAccessoryName(try #require(restarted.catalog.find(id: "Devices:lamp")), name: "")
        #expect(try block(restarted)?["_accessories"] == nil)
        #expect(again.name == "Desk Lamp" && again[.lightbulb]?[.configuredName]?.value == .string("Desk Lamp"))
        await restarted.stop()
    }

    /// The Home app renames an accessory by writing its Configured Name: the catalog keeps the name in config.json, and
    /// the accessory's other names follow.
    @Test func keepsARenameFromTheHomeApp() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        let lock = try #require(environment.catalog.find(id: "Devices:lock")).accessory
        _ = try await environment.catalog.setAccessoryName(try #require(environment.catalog.find(id: "Devices:lock")), name: "Back Door")
        let configuredName = try #require(lock[.lockMechanism]?[.configuredName])

        try await configuredName.write(.string("Garden Door"))
        #expect(await eventually { (try? block(environment)?["_accessories"]?["lock"]?["name"]) == "Garden Door" })
        #expect(await eventually { lock.name == "Garden Door" })
        #expect(configuredName.value == .string("Garden Door"))
        await environment.stop()
    }
}
