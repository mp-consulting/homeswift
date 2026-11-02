import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// The automations a plugin's hub keeps (Apple Home's through Wingman), through the MCP tools and the web UI's chat. The
/// devices plugin's hub has "Evening": the desk lamp on at sunset − 15 min on weekdays.
@Suite struct HubAutomationTests {
    func automations(_ environment: MCPTestEnvironment) -> [String: PluginAutomation] { environment.hubAutomations.withLockedValue { $0 } }

    @Test func theToolsDeclareTheirScopeAndWhetherTheyDestroy() async throws {
        let environment = try MCPTestEnvironment()
        let tools = Dictionary(uniqueKeysWithValues: environment.server.tools.map { ($0.name, $0) })
        let list = try #require(tools["list_hub_automations"])
        #expect(list.scope == .read && !list.destructive)
        let update = try #require(tools["update_hub_automation"])
        #expect(update.scope == .admin && !update.destructive)
        let delete = try #require(tools["delete_hub_automation"])
        #expect(delete.scope == .admin && delete.destructive)
        // A chat with less than admin sees the list only.
        let viewer = await ChatToolbox(server: environment.server, user: "viewer", scope: .control)
        let names = Set(viewer.agentTools { _ in false }.map(\.definition.name))
        #expect(names.contains("list_hub_automations"))
        #expect(!names.contains("update_hub_automation") && !names.contains("delete_hub_automation"))
    }

    /// Listed with what starts them and what they do, the hub's words wrapped as data.
    @Test func listsTheHubsAutomationsAsData() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let result = try await client.tool("list_hub_automations")
        let evening = try #require(result["structuredContent"]?["automations"]?[0])
        #expect(evening["id"] == "Devices:Devices:evening")
        #expect(evening["triggers"] == [["kind": "time", "time": ["solarEvent": "sunset", "offsetMinutes": -15, "weekdays": [2, 3, 4, 5, 6]]]])
        #expect(evening["actions"] == [["accessory": "Devices:lamp", "accessoryName": "Desk Lamp", "characteristic": "On", "value": true]])
        #expect(evening["capabilities"] == ["enable", "rename", "time", "scenes", "actions", "delete"])
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        #expect(text.hasPrefix("<untrusted-data source=\"hub-automations\">"))
        // The hub's text cannot close the wrapper.
        #expect(text.components(separatedBy: "<untrusted-data").count == 2)
    }

    /// Changed part by part and audited; a lock is refused; a delete asks first.
    @Test func changesAndRemovesOneAfterAsking() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let dry = try await client.tool("update_hub_automation", ["automation": "Evening", "enabled": false, "dryRun": true])
        #expect(dry["structuredContent"]?["dryRun"] == true)
        #expect(automations(environment)["evening"]?.enabled == true)

        let changed = try await client.tool("update_hub_automation", [
            "automation": "Devices:Devices:evening", "enabled": false, "name": "Soir", "time": ["hour": 19, "minute": 30, "weekdays": [1, 7]],
            "scenes": ["Devices:Devices:magenta"], "actions": [["accessory": "Devices:lamp", "characteristic": "Brightness", "value": 40]],
        ])
        #expect(changed["structuredContent"]?["updated"] == true)
        let evening = try #require(automations(environment)["evening"])
        #expect(!evening.enabled && evening.name == "Soir")
        #expect(evening.triggers == [.time(PluginAutomationTime(hour: 19, minute: 30, weekdays: [1, 7]))])
        #expect(evening.sceneIDs == ["magenta"])
        #expect(evening.actions == [PluginAutomationAction(accessoryID: "Devices:lamp", characteristic: "Brightness", value: 40)])
        #expect(environment.auditEntries.contains { $0["tool"] == "update_hub_automation" })

        let lock = try await client.tool("update_hub_automation", ["automation": "Soir", "actions": [["accessory": "Devices:lock", "characteristic": "Lock Target State", "value": 0]]])
        #expect(lock["isError"] == true)
        let otherHub = try await client.tool("update_hub_automation", ["automation": "Soir", "scenes": ["Hue:Hue:1"]])
        #expect(otherHub["isError"] == true)
        #expect(automations(environment)["evening"]?.actions.first?.characteristic == "Brightness")

        let declined = try await client.tool("delete_hub_automation", ["automation": "Soir"], answer: ["action": "decline"])
        #expect(declined["isError"] == true)
        #expect(automations(environment)["evening"] != nil)
        let deleted = try await client.tool("delete_hub_automation", ["automation": "Soir"], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(deleted["isError"] != true)
        #expect(automations(environment).isEmpty)
    }

    /// The Assistant in the web UI's chat turns an automation off and removes another after the page's confirmation.
    @Test func theAssistantChangesThemFromTheChat() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let toolbox = await ChatToolbox(server: environment.server, user: "admin")
        let provider = ScriptedProvider([
            ScriptedProvider.calls([HomeswiftAI.ToolCall(id: "1", name: "list_hub_automations", arguments: [:])]),
            ScriptedProvider.calls([HomeswiftAI.ToolCall(id: "2", name: "update_hub_automation", arguments: ["automation": "Devices:Devices:evening", "enabled": false])]),
            ScriptedProvider.calls([HomeswiftAI.ToolCall(id: "3", name: "delete_hub_automation", arguments: ["automation": "Devices:Devices:evening"])]),
            ScriptedProvider.answer("Evening is off, then removed."),
        ])
        let asked = AskedBox()
        let tools = toolbox.agentTools { confirmation in
            asked.add(confirmation)
            return true
        }
        let turn = try await AssistantService(provider: provider).converse(history: [.user("Turn off then remove the Evening automation in Apple Home")], tools: tools, vault: toolbox.vault) { _ in }
        #expect(turn.text == "Evening is off, then removed.")
        // What the hub says reaches the model wrapped as data, its own tag defused.
        #expect(provider.sentText.contains("<untrusted-data source=\\\"hub-automations\\\">") || provider.sentText.contains("<untrusted-data source=\"hub-automations\">"))
        #expect(!provider.sentText.contains("instructions <untrusted-data>"))
        #expect(asked.all.map(\.tool).contains("delete_hub_automation"))
        #expect(automations(environment).isEmpty)
    }
}
