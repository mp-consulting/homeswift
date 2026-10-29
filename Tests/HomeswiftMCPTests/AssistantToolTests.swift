import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftMCP

@Suite(.timeLimit(.minutes(1)))
struct AssistantToolTests {
    /// Emptying the log asks first, needs an admin token, and takes the lines in memory and the files on disk.
    @Test func truncatesTheLogAfterConfirmation() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let archiveDirectory = environment.directory.appendingPathComponent("logs")
        let archive = LogArchive(directory: archiveDirectory)
        let logs = LogBuffer(archive: archive)
        let catalog = HomeswiftCatalog(host: environment.host, logs: logs, configURL: environment.configURL, logger: testLogger)
        let server = MCPServer(options: MCPServer.Options(version: "test", instructions: ""), tools: catalog.tools)
        logs.append(LogBuffer.Line(level: .error, label: "Devices", text: "Lamp unreachable"))
        archive.flush()
        #expect(try !FileManager.default.contentsOfDirectory(atPath: archiveDirectory.path).isEmpty)

        let controller = DirectClient(server: server, scope: .control)
        try await controller.initialize()
        #expect(try await controller.tool("truncate_logs")["content"]?[0]?["text"]?.stringValue?.contains("needs admin") == true)
        let admin = DirectClient(server: server)
        try await admin.initialize()
        let declined = try await admin.tool("truncate_logs", [:], answer: ["action": "decline"])
        #expect(declined["isError"] == true)
        #expect(logs.all.count == 1)
        let done = try await admin.tool("truncate_logs", [:], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(done["structuredContent"]?["truncated"] == true)
        #expect(logs.all.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: archiveDirectory.path).isEmpty)
        #expect(catalog.logText().isEmpty)
        // Logging goes on after it.
        logs.append(LogBuffer.Line(level: .info, label: "Devices", text: "Lamp back"))
        // The log is read from the archive, which writes in the background.
        archive.flush()
        #expect(catalog.logText().contains("Lamp back"))
    }

    /// Without a working Assistant: the usage says so (with the counts kept on disk), and the digest refuses.
    @Test func reportsWithoutAnAssistant() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server, scope: .read)
        try await client.initialize()
        let usage = try await client.tool("get_assistant_usage")
        #expect(usage["structuredContent"]?["enabled"] == false)
        #expect(usage["structuredContent"]?["usage"]?["today"]?["requests"] == 0)
        let digest = try await client.tool("get_daily_digest")
        #expect(digest["isError"] == true)
        #expect(digest["content"]?[0]?["text"]?.stringValue?.contains("Assistant is off") == true)
        let tools = try await client.call("tools/list")["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(tools.contains("get_daily_digest") && tools.contains("get_assistant_usage"))
    }

    /// The digest's input: the status, the problem lines only, the accessories with their values.
    @Test func buildsTheDigestInput() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .info, label: "Devices", text: "Lamp turned on"))
        environment.logs.append(LogBuffer.Line(level: .warning, label: "Devices", text: "Lamp slow to answer"))
        environment.logs.append(LogBuffer.Line(level: .error, label: "Devices", text: "Lamp unreachable"))
        // A one-time code is a warning line: the digest, which goes back to clients, never carries it.
        environment.logs.append(LogBuffer.Line(level: .warning, label: "homeswift", text: "Confirmation needed for reset_pairings {}: tell the assistant the confirmation code 482913 to allow it"))
        let input = environment.catalog.digestInput()
        #expect(input.logs.count == 3)
        #expect(input.logs.allSatisfy { !$0.contains("482913") })
        #expect(input.logs.allSatisfy { !$0.contains("turned on") })
        #expect(input.status?["bridges"]?.arrayValue?.isEmpty == false)
        #expect(input.accessories?.arrayValue?.isEmpty == false)
        #expect(input.date == DailyDigestInput.today())
    }
}
