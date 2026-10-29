import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

@Suite(.timeLimit(.minutes(1)))
struct VaultToolTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "token": "shared-secret-1", "devices": [ { "name": "Door", "password": "door-pass-9" } ] },
            { "platform": "Ghost", "name": "Nobody", "apiKey": "shared-secret-1" },
            { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """

    @Test func aClientCannotAddFileOrEnvironmentReferences() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        let catalog = environment.catalog
        for reference in ["file:/run/secrets/key", "env:HOME"] {
            await #expect(throws: CatalogError.self) {
                try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: true, by: .client) { $0["token"] = .string(reference) }
            }
        }
        // A person may; its dry run is told only that the reference does not resolve.
        do {
            _ = try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: true) { $0["token"] = "file:/run/secrets/missing" }
            Issue.record("expected a failure")
        } catch let error as SecretReferenceError {
            #expect(error.description.contains("(does not resolve)"))
        }
    }

    @Test func theConnectionTestSendsASavedKeyOnlyToTheSavedService() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "HomeswiftAiKit", "provider": "anthropic", "apiKey": "sk-ant-saved-key" } ]
            }
            """)
        for apiKey in ["__REDACTED__", "vault:anthropic", "env:ANTHROPIC_API_KEY"] {
            let block: JSONValue = ["platform": "HomeswiftAiKit", "provider": "anthropic", "baseUrl": "http://192.0.2.1:8080", "apiKey": .string(apiKey)]
            let result = await environment.catalog.testAssistantConnection(block: block, user: nil)
            #expect(result["ok"] == false)
            #expect(result["message"]?.stringValue?.hasPrefix("Type the API key to test another provider or address") == true, "\(apiKey)")
        }
    }

    @Test func theDryRunWritesNothing() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        let plan = try await environment.catalog.migrateToVault(dryRun: true)
        let items = try #require(plan["items"]?.arrayValue)
        #expect(items.map { $0["id"]?.stringValue } == ["Devices/Devices:devices[0].password", "Devices/Devices:token", "Ghost/Nobody:apiKey"])
        #expect(plan["moved"] == 3)
        #expect(plan["newEntries"]?.arrayValue?.count == 2)
        // The plan never holds a value.
        #expect(!plan.text().contains("shared-secret-1") && !plan.text().contains("door-pass-9"))
        #expect(try environment.catalog.vault.names().isEmpty)
        #expect(try environment.catalog.readConfig()["platforms"]?[0]?["token"] == "shared-secret-1")
    }

    @Test func migratingMovesTheSecretsAndAppliesTheConfig() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let answer = try await environment.catalog.migrateToVault(.init(excluded: ["Devices/Devices:devices[0].password"]), dryRun: false)
        #expect(answer["applied"]?["backup"]?.stringValue != nil)

        let file = try environment.catalog.readConfig()
        let platforms = try #require(file["platforms"]?.arrayValue)
        let shared = try #require(platforms[0]["token"]?.stringValue)
        #expect(shared.hasPrefix("vault:"))
        #expect(platforms[1]["apiKey"]?.stringValue == shared)
        // Left in config.json, sealed as before; the MCP token is never moved.
        #expect(platforms[0]["devices"]?[0]?["password"]?.stringValue?.hasPrefix(SecretBox.prefix) == true)
        #expect(platforms[2]["mcp"]?["http"]?["token"]?.stringValue?.hasPrefix("vault:") == false)
        #expect(try environment.catalog.vault.names() == [String(shared.dropFirst("vault:".count))])
        // The running bridge has the secret itself.
        let running = try JSONValue(data: environment.host.configuration.platforms[0].json)
        #expect(running["token"] == "shared-secret-1")

        // From now on a new plain secret goes to the vault, one it already holds to its entry; the one left stays.
        _ = try await environment.catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false) { block in
            block["refreshToken"] = "fresh-secret-7"
            block["accessToken"] = "shared-secret-1"
        }
        let saved = try #require(try environment.catalog.readConfig()["platforms"]?[0])
        #expect(saved["refreshToken"]?.stringValue?.hasPrefix("vault:") == true)
        #expect(saved["accessToken"]?.stringValue == shared)
        #expect(saved["devices"]?[0]?["password"]?.stringValue?.hasPrefix(SecretBox.prefix) == true)
        #expect(try environment.catalog.vault.names().count == 2)
        #expect(try !String(contentsOf: environment.configURL, encoding: .utf8).contains("fresh-secret-7"))
    }

    @Test func listVaultShowsHealthAndTheDigestHearsOfIt() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "Devices", "name": "Devices", "token": "vault:devices", "password": "vault:gone" } ]
            }
            """)
        let catalog = environment.catalog
        try catalog.vault.set("devices", VaultEntry(kind: .token, fields: ["token": "listed-secret-5"], expires: Date().addingTimeInterval(86_400)))
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let reply = try await client.tool("list_vault")
        #expect(!reply.text().contains("listed-secret-5"))
        let listed = try #require(reply["structuredContent"])
        let entry = try #require(listed["entries"]?[0])
        #expect(entry["name"] == "devices" && entry["health"] == "expiring" && entry["usedBy"] == ["Devices/Devices:token"])
        #expect(listed["problems"]?.arrayValue?.map { $0["state"] } == ["missing", "expiring"])
        #expect(HomeswiftCatalog.administratorOnly.contains("list_vault"))

        let status = try #require(catalog.digestInput().status)
        #expect(status["vault"]?.arrayValue?.map { $0["entry"] } == ["gone", "devices"])
    }
}
