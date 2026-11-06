import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftMCP

/// Diagnostics: a plugin instance's or an accessory's bundle, secrets masked and the log redacted, names kept; the
/// administrators' get_diagnostics.
@Suite(.timeLimit(.minutes(1)))
struct DiagnosticsTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:56", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "token": "secret-token", "applicationKey": "hub-application-key", "host": "http://admin:hunter2@192.0.2.10/",
              "_accessories": { "lamp": { "room": "Office", "password": "lamp-password" }, "lock": { "name": "Front" } } },
            { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """

    func environment() async throws -> MCPTestEnvironment {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        return environment
    }

    @Test func aPluginsBundleMasksItsSecrets() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .error, label: "Devices", text: "Could not reach 192.0.2.10 with token=abc123def456"))
        environment.logs.append(LogBuffer.Line(level: .warning, label: "Devices", text: "Slow answer"))
        environment.logs.append(LogBuffer.Line(level: .info, label: "Another", text: "Not this plugin's"))

        let bundle = try await environment.catalog.diagnosticsJSON(.plugin(platform: "Devices", name: nil))
        let text = bundle.text(pretty: true)
        #expect(bundle["about"] == "plugin")
        #expect(bundle["homeswift"]?["version"] == .string(PluginHost.version))
        #expect(bundle["homeswift"]?["platform"]?.stringValue?.isEmpty == false)
        #expect(bundle["plugin"]?["running"] == true)
        #expect(bundle["plugin"]?["name"] == "Devices")
        // Secrets are masked wherever they are: a secret-named key, a credential in a URL, an Accessory Setting.
        for secret in ["hub-application-key", "secret-token", "hunter2", "lamp-password", "031-45-154", "abc123def456", "mcp-token"] { #expect(!text.contains(secret), "\(secret) leaked") }
        #expect(bundle["pluginSettings"]?["token"] == .string(Redaction.placeholder))
        #expect(bundle["pluginSettings"]?["_accessories"] == nil)
        #expect(bundle["accessorySettings"]?["lamp"]?["room"] == "Office")
        #expect(bundle["accessorySettings"]?["lock"]?["name"] == "Front")
        // The accessories with their services and values; names kept.
        let accessories = try #require(bundle["accessories"]?.arrayValue)
        #expect(accessories.contains { $0["id"] == "Devices:lamp" && $0["name"] == "Desk Lamp" })
        #expect(accessories.first { $0["id"] == "Devices:lamp" }?["services"]?.arrayValue?.isEmpty == false)
        // Its own log only, and what it counts.
        let lines = try #require(bundle["log"]?["lines"]?.arrayValue)
        #expect(lines.count == 2)
        #expect(!lines.contains { $0.stringValue?.contains("Not this plugin's") == true })
        #expect(bundle["errors"]?["errors"] == 1)
        #expect(bundle["errors"]?["warnings"] == 1)
        #expect(bundle["errors"]?["lastError"]?["text"]?.stringValue?.contains("Could not reach") == true)
    }

    @Test func anAccessorysBundleHasItsOwnSettings() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let bundle = try await environment.catalog.diagnosticsJSON(.accessory(id: "Devices:lamp"))
        #expect(bundle["about"] == "accessory")
        #expect(bundle["accessory"] == "Devices:lamp")
        #expect(bundle["accessories"]?.arrayValue?.map { $0["id"] } == ["Devices:lamp"])
        #expect(bundle["accessorySettings"]?.objectValue?.keys.sorted() == ["lamp"])
        #expect(bundle["accessorySettings"]?["lamp"]?["password"] == .string(Redaction.placeholder))
        await #expect(throws: CatalogError.self) { try await environment.catalog.diagnosticsJSON(.accessory(id: "Nowhere")) }
        await #expect(throws: CatalogError.self) { try await environment.catalog.diagnosticsJSON(.plugin(platform: "Nothing", name: nil)) }
    }

    @Test func keepsTheLastThousandLines() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        for index in 0..<1_200 { environment.logs.append(LogBuffer.Line(level: .info, label: "Devices", text: "line \(index)")) }
        let lines = try #require(try await environment.catalog.diagnosticsJSON(.plugin(platform: "Devices", name: "Devices"))["log"]?["lines"]?.arrayValue)
        #expect(lines.count == HomeswiftCatalog.diagnosticsLogLines)
        #expect(lines.last?.stringValue?.hasSuffix("line 1199") == true)
    }

    @Test func getDiagnosticsIsForAdministrators() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        #expect(HomeswiftCatalog.administratorOnly.contains("get_diagnostics"))
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let result = try await client.tool("get_diagnostics", ["accessory": "Devices:lamp"])
        #expect(result["structuredContent"]?["accessory"] == "Devices:lamp")
        #expect(result["content"]?[0]?["text"]?.stringValue?.hasPrefix("<untrusted-data source=\"diagnostics\">") == true)
        #expect(try await client.tool("get_diagnostics", [:])["isError"] == true)
        #expect(HomeswiftCatalog.diagnosticsFileName(.plugin(platform: "Devices", name: "Desk Lights"), now: Date(timeIntervalSince1970: 1_800_000_000))
            == "homeswift-diagnostics-desk-lights-2027-01-15.json")
    }
}
