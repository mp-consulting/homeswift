import Foundation
import HomeswiftAI
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftMCP

@Suite struct ChatTests {
    @Test func offersTheToolsAPageCanConfirm() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let tools = toolbox.agentTools { _ in false }
        let names = Set(tools.map(\.definition.name))
        #expect(names.isSuperset(of: ["list_accessories", "put_list_entry", "patch_config", "Devices_pair"]))
        let patch = try #require(tools.first { $0.definition.name == "patch_config" })
        #expect(patch.definition.inputSchema["properties"]?["confirmationCode"] == nil)
        #expect(patch.definition.inputSchema["properties"]?["dryRun"] != nil)

        let readOnly = await ChatToolbox(server: environment.server, user: "viewer", scope: .read)
        #expect(!readOnly.agentTools { _ in false }.contains { $0.definition.name == "put_list_entry" })
        await environment.stop()
    }

    /// Pair, then add: the password goes from the plugin to config.json as a handle the model never reads.
    @Test func addsAPairedDeviceWithoutShowingItsSecret() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let provider = ScriptedProvider([
            ScriptedProvider.calls([HomeswiftAI.ToolCall(id: "1", name: "Devices_pair", arguments: ["ip": "192.0.2.7"])]),
            { request in
                // The model passes on what it was given: the device entry, with the handle.
                let result = request.messages.last?.content.compactMap { part -> String? in
                    if case .toolResult(_, _, let content, _) = part { content } else { nil }
                }.first ?? ""
                let fenced = result.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
                let device = (try? JSONValue(string: fenced))?["device"] ?? .null
                var entry = device.objectValue ?? [:]
                entry["name"] = "Bedroom TV"
                return ChatResult(
                    model: "scripted-1", text: "",
                    toolCalls: [HomeswiftAI.ToolCall(id: "2", name: "put_list_entry", arguments: ["platform": "Devices", "entry": .object(entry)])],
                    usage: .zero, stopReason: .toolCalls)
            },
            ScriptedProvider.answer("Bedroom TV is added."),
        ])
        let assistant = AssistantService(provider: provider)
        let asked = AskedBox()
        let tools = toolbox.agentTools { confirmation in
            asked.add(confirmation)
            return true
        }
        let events = EventBox()
        let turn = try await assistant.converse(history: [.user("Pair the device at 192.0.2.7")], tools: tools, vault: toolbox.vault) { events.add($0) }

        #expect(turn.text == "Bedroom TV is added.")
        #expect(!provider.sentText.contains("s3cret-pass"))
        #expect(provider.sentText.contains("__SECRET_"))
        let confirmation = try #require(asked.all.first)
        #expect(confirmation.tool == "put_list_entry")
        #expect(confirmation.arguments["entry"]?["password"]?.stringValue.map(SecretVault.isHandle) == true)
        #expect(confirmation.preview != nil)
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        let devices = config["platforms"]?[0]?["devices"]?.arrayValue ?? []
        #expect(devices.count == 1)
        #expect(devices.first?["password"] == "s3cret-pass")
        #expect(devices.first?["name"] == "Bedroom TV")
        #expect(events.started == ["Devices_pair", "put_list_entry"])
        #expect(environment.auditEntries.contains { $0["tool"] == "put_list_entry" && $0["client"] == "web UI chat" && $0["ok"] == true })
        await environment.stop()
    }

    @Test func leavesTheConfigurationWhenTheUserDeclines() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let before = try Data(contentsOf: environment.configURL)
        let tools = toolbox.agentTools { _ in false }
        let put = try #require(tools.first { $0.definition.name == "put_list_entry" })
        let output = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:22", "name": "Lamp"]])
        #expect(output.isError)
        #expect(output.text.contains("did not confirm"))
        #expect(try Data(contentsOf: environment.configURL) == before)
        await environment.stop()
    }

    @Test func replacesTheEntryWithTheSameMAC() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let put = try #require(toolbox.agentTools { _ in true }.first { $0.definition.name == "put_list_entry" })
        _ = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:22", "name": "One"]])
        _ = await put.run(["platform": "Devices", "entry": ["mac": "aa-bb-cc-00-11-22", "name": "Two"]])
        _ = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:33", "name": "Three"]])
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        let names = (config["platforms"]?[0]?["devices"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names == ["Two", "Three"])
        await environment.stop()
    }

    /// A rename changes the fields secrets are matched on: the entry it replaces gives them back.
    @Test func renamesAnEntryAndKeepsItsSecret() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let put = try #require(toolbox.agentTools { _ in true }.first { $0.definition.name == "put_list_entry" })
        _ = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:22", "name": "Old", "password": "kept-secret"]])
        let output = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:22", "name": "New", "password": "__REDACTED__"]])
        #expect(!output.isError, "\(output.text)")
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        #expect(config["platforms"]?[0]?["devices"]?[0]?["name"] == "New")
        #expect(config["platforms"]?[0]?["devices"]?[0]?["password"] == "kept-secret")
        await environment.stop()
    }

    /// What fails in a dry run comes back to the model without asking the user.
    @Test func doesNotAskForAChangeThatCannotWork() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let asked = AskedBox()
        let put = try #require(toolbox.agentTools { confirmation in
            asked.add(confirmation)
            return true
        }.first { $0.definition.name == "put_list_entry" })
        let output = await put.run(["platform": "Devices", "entry": ["mac": "AA:BB:CC:00:11:99", "password": "__REDACTED__"]])
        #expect(output.isError)
        #expect(output.text.contains("no matching value"))
        #expect(asked.all.isEmpty)
        await environment.stop()
    }

    /// Every MCP client gets what a change would do with its question, not only the web UI's chat.
    @Test func asksWithWhatWouldChange() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let session = environment.server.makeSession(principal: Principal(name: "desktop", scope: .admin))
        let initialize: JSONValue = ["protocolVersion": "2025-06-18", "capabilities": ["elicitation": [:]], "clientInfo": ["name": "tests", "version": "1"]]
        for await _ in environment.server.handle(.request(id: 1, method: "initialize", params: initialize), session: session) {}
        var question: JSONValue?
        let call = JSONRPCMessage.request(id: 2, method: "tools/call", params: ["name": "patch_config", "arguments": ["platform": "Devices", "settings": ["pollingRate": 500]]])
        for await message in environment.server.handle(call, session: session) {
            if case .request(let id, "elicitation/create", let params) = message {
                question = params
                for await _ in environment.server.handle(.response(id: id, result: ["action": "decline"]), session: session) {}
            }
        }
        let text = try #require(question?["message"]?.stringValue)
        #expect(text.contains("It would change:"))
        #expect(text.contains("platforms[0].pollingRate → 500"))
        #expect(question?["_meta"]?["homeswift/preview"]?["changes"] == ["platforms[0].pollingRate"])
    }

    /// The reads of one step run at the same time, and their results come back in the order asked.
    @Test func runsReadsAtTheSameTime() async throws {
        // Each read waits until both have started: run one after the other, they would time out apart.
        let started = NIOLockedValueBox(0)
        let slow = { (name: String) in
            AgentTool(definition: ToolDefinition(name: name, inputSchema: ["type": "object"]), title: name, readOnly: true) { _ in
                started.withLockedValue { $0 += 1 }
                let deadline = ContinuousClock.now + .seconds(5)
                while started.withLockedValue({ $0 }) < 2, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return AgentToolOutput(text: started.withLockedValue { $0 } == 2 ? "\(name) done" : "\(name) alone")
            }
        }
        let provider = ScriptedProvider([
            ScriptedProvider.calls([HomeswiftAI.ToolCall(id: "1", name: "first", arguments: [:]), HomeswiftAI.ToolCall(id: "2", name: "second", arguments: [:])]),
            ScriptedProvider.answer("Both done."),
        ])
        let turn = try await AssistantService(provider: provider).converse(history: [.user("Look")], tools: [slow("first"), slow("second")], vault: SecretVault()) { _ in }
        let results = turn.messages.flatMap(\.content).compactMap { part -> String? in
            if case .toolResult(_, _, let content, _) = part { content } else { nil }
        }
        #expect(results == ["first done", "second done"])
    }

    @Test func vaultHandlesSurviveRedaction() throws {
        let vault = SecretVault()
        let concealed = vault.conceal(["password": "hunter2", "nested": ["apiKey": "abc"], "ip": "10.0.0.2"])
        let handle = try #require(concealed["password"]?.stringValue)
        #expect(SecretVault.isHandle(handle))
        #expect(concealed["ip"] == "10.0.0.2")
        #expect(vault.conceal(["token": "hunter2"])["token"] == .string(handle))
        #expect(Redaction.redactSecrets(concealed) == concealed)
        #expect(Redaction.redactText(#"{"password": "\#(handle)"}"#) == #"{"password": "\#(handle)"}"#)
        #expect(vault.reveal(concealed)["nested"]?["apiKey"] == "abc")
        // Only under a secret's key, and only this vault's.
        #expect(vault.reveal(["name": .string(handle)])["name"] == .string(handle))
        #expect(SecretVault().reveal(["password": .string(handle)])["password"] == .string(handle))
        #expect(SecretVault.containsHandle(["a": [["b": .string(handle)]]]))
    }

    /// A secret cannot be moved into a field that shows it, nor a handle from elsewhere written as is.
    @Test func refusesHandlesOutOfPlace() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let tools = toolbox.agentTools { _ in true }
        let pair = try #require(tools.first { $0.definition.name == "Devices_pair" })
        let paired = await pair.run(["ip": "192.0.2.7"])
        #expect(paired.text.hasPrefix("<untrusted-data source=\"Devices\">"))
        let json = paired.text.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        let handle = try #require(try JSONValue(string: json)["device"]?["password"]?.stringValue)
        let patch = try #require(tools.first { $0.definition.name == "patch_config" })
        let moved = await patch.run(["platform": "Devices", "settings": ["name": .string(handle)]])
        #expect(moved.isError)
        #expect(moved.text.contains("__SECRET_"))
        let config = try String(contentsOf: environment.configURL, encoding: .utf8)
        #expect(!config.contains("s3cret-pass"))
        await environment.stop()
    }
}

final class AskedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolConfirmation] = []
    func add(_ item: ToolConfirmation) { lock.withLock { items.append(item) } }
    var all: [ToolConfirmation] { lock.withLock { items } }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    func add(_ event: AgentEvent) { lock.withLock { events.append(event) } }
    var started: [String] {
        lock.withLock { events.compactMap { if case .toolStarted(_, let name, _) = $0 { name } else { nil } } }
    }
}
