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

    /// A form block without a key, for another address, does not borrow the key in the bridge's environment; the saved
    /// provider and address still may.
    @Test func anotherServiceGetsNoKeyFromTheEnvironment() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "HomeswiftAiKit", "provider": "anthropic" } ]
            }
            """)
        let keys = ["ANTHROPIC_API_KEY": "sk-ant-environment-key"]
        let elsewhere: JSONValue = ["platform": "HomeswiftAiKit", "provider": "anthropic", "baseUrl": "http://192.0.2.1:8080"]
        let request = try environment.catalog.assistantBlock(elsewhere, environment: keys).get()
        #expect(request.environment.isEmpty)
        #expect(try AIConfiguration(block: request.block, environment: request.environment).apiKey == nil)
        // With no key, the models of the other address are not asked for.
        let models = await environment.catalog.assistantModels(block: elsewhere)
        #expect(models["models"] == [] && models["error"]?.stringValue?.isEmpty == false)

        let saved = try environment.catalog.assistantBlock(["platform": "HomeswiftAiKit", "provider": "anthropic"], environment: keys).get()
        #expect(try AIConfiguration(block: saved.block, environment: saved.environment).apiKey == "sk-ant-environment-key")
    }

    /// For the saved provider and address too, the form names no secret of the bridge's that the saved block does not
    /// hold at the same place: no `file:` or `env:` of its own, no other vault entry, no sealed value.
    @Test func theFormBringsNoReferenceOfItsOwn() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "HomeswiftAiKit", "provider": "openai-compatible", "baseUrl": "http://127.0.0.1:9/v1", "apiKey": "vault:assistant" } ]
            }
            """)
        try environment.catalog.vault.set("assistant", VaultEntry(kind: .apiKey, fields: ["key": "sk-vault-key"]))
        try environment.catalog.vault.set("other", VaultEntry(kind: .apiKey, fields: ["key": "sk-other-key"]))
        func form(_ apiKey: String) -> JSONValue {
            ["platform": "HomeswiftAiKit", "provider": "openai-compatible", "baseUrl": "http://127.0.0.1:9/v1", "apiKey": .string(apiKey)]
        }
        for apiKey in ["file:/etc/hosts", "env:HOME", "vault:other", "\(SecretBox.prefix)AAAA"] {
            let block = form(apiKey)
            let result = environment.catalog.assistantBlock(block)
            guard case .failure(let problem) = result else { Issue.record("\(apiKey) was accepted"); continue }
            #expect(problem.description.hasPrefix("apiKey is not the saved block's"), "\(apiKey)")
            let tested = await environment.catalog.testAssistantConnection(block: block, user: nil)
            #expect(tested["ok"] == false)
            #expect(await environment.catalog.assistantModels(block: block)["error"]?.stringValue?.hasPrefix("apiKey is not the saved block's") == true)
        }
        // A sealed value under a key that is not secret-named is opened all the same: refused too.
        let sealedModel: JSONValue = ["platform": "HomeswiftAiKit", "provider": "openai-compatible", "baseUrl": "http://127.0.0.1:9/v1", "model": .string("\(SecretBox.prefix)AAAA")]
        #expect((try? environment.catalog.assistantBlock(sealedModel).get()) == nil)
        let sealedElsewhere: JSONValue = ["platform": "HomeswiftAiKit", "provider": "openai-compatible", "baseUrl": "http://192.0.2.1/v1", "model": .string("\(SecretBox.prefix)AAAA")]
        #expect((try? environment.catalog.assistantBlock(sealedElsewhere).get()) == nil)
        // The saved reference, as the form shows it, is the saved key.
        let opened = environment.catalog.assistantBlock(form("vault:assistant")).map(\.block["apiKey"])
        #expect((try? opened.get()) == "sk-vault-key", "\(opened)")
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
