import Foundation
import Homeswift
import HomeswiftAI
@testable import HomeswiftMCP
@testable import HomeswiftPlugin
import Testing

/// The Remotes over MCP, as the Assistant uses them: list_remotes says each Remote's parts, gestures and what they may
/// drive; set_remote_controls sets one part's Controls, checked (never a security control), the other parts kept.
@Suite(.timeLimit(.minutes(1)))
struct RemoteToolTests {
    func environment() async throws -> MCPTestEnvironment {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Devices", "name": "Devices", "remote": true }]
            }
            """)
        try await environment.start()
        return environment
    }

    /// A light in a Group says so: the page lists the Group's members under it.
    @Test func aTargetSaysItsGroup() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Devices", "name": "Devices", "remote": true, "colourBulbs": 2 }]
            }
            """)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let grouped = try await client.tool("set_wall_layout", ["groups": [["name": "Office lights", "members": ["Devices:lamp", "Devices:bulb1"]]]])
        #expect(grouped["isError"] != true, "\(grouped)")

        let targets = try #require(try await client.tool("list_remotes", [:])["structuredContent"]?["targets"]?.arrayValue)
        let group = { (id: String) in targets.first { $0["id"]?.stringValue == id }?["group"]?["name"] }
        #expect(group("Devices:lamp") == "Office lights")
        #expect(group("Devices:bulb1") == "Office lights")
        #expect(group("Devices:bulb2") == nil)
    }

    @Test func theAssistantSetsARemotesControls() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let listed = try #require(try await client.tool("list_remotes", [:])["structuredContent"])
        let remote = try #require(listed["remotes"]?.arrayValue?.first { $0["id"] == "Devices:remote" })
        #expect(remote["parts"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["top", "bottom"])
        #expect(remote["parts"]?[0]?["gestures"] == ["press", "double", "long", "hold"])
        let targets = listed["targets"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        // A lock is listed too, marked security (docs/adr/0012-a-remote-drives-what-it-is-given.md).
        #expect(targets.contains("Devices:lamp") && targets.contains("Devices:lock"))

        let press: JSONValue = ["gesture": "press", "action": "toggle", "targets": ["Devices:lamp"]]
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "top", "controls": [press]])
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "bottom",
                                                          "controls": [["gesture": "hold", "action": "dim", "direction": "down", "targets": ["Devices:lamp"]]]])
        let controls = environment.host.remote(of: "Devices:remote")?.controls ?? []
        #expect(controls.map(\.part) == ["top", "bottom"] && controls[1].direction == .down)

        // Refused: a security control as power the user did not confirm, a gesture the part does not have, a part it does not have.
        let refusals: [JSONValue] = [
            ["remote": "Devices:remote", "part": "top", "controls": [["gesture": "press", "action": "on", "targets": ["Devices:lamp"], "power": ["Devices:lock"]]]],
            ["remote": "Devices:remote", "part": "top", "controls": [["gesture": "turn", "action": "step", "targets": ["Devices:lamp"]]]],
            ["remote": "Devices:remote", "part": "middle", "controls": [press]],
        ]
        for arguments in refusals {
            let answer = try await client.tool("set_remote_controls", arguments)
            #expect(answer["isError"] == true)
        }
        // update_settings asks the same.
        let direct = try await client.tool("update_settings", ["accessory": "Devices:remote", "settings": ["controls": [
            ["part": "top", "gesture": "press", "action": "on", "targets": ["Devices:lamp"], "power": ["Devices:lock"]]]]])
        #expect(direct["isError"] == true)
        #expect(environment.host.remote(of: "Devices:remote")?.controls.count == 2)
    }
    func relayEnvironment() async throws -> MCPTestEnvironment {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Devices", "name": "Devices", "remote": true, "relay": true }]
            }
            """)
        try await environment.start()
        return environment
    }

    /// A relay is an Appliance, its channels Functions of their own under it; a hold or a turn on it alone is refused.
    @Test func aRemoteDrivesAnAppliancesFunction() async throws {
        let environment = try await relayEnvironment()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let targets = try #require(try await client.tool("list_remotes", [:])["structuredContent"]?["targets"]?.arrayValue)
        let relay = { (id: String) in targets.first { $0["id"]?.stringValue == id } }
        #expect(relay("Devices:relay")?["kind"] == "appliance")
        #expect(relay("Devices:relay#channel2")?["kind"] == "appliance" && relay("Devices:relay#channel2")?["of"] == "Devices:relay")
        #expect(relay("Devices:relay#channel2")?["name"] == "Channel 2")
        // The lamp does one thing: no Function of its own listed.
        #expect(!targets.contains { $0["of"] == "Devices:lamp" })

        let press: JSONValue = ["gesture": "press", "action": "toggle", "targets": ["Devices:relay#channel2"]]
        let saved = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "top", "controls": [press]])
        #expect(saved["isError"] != true, "\(saved)")
        #expect(environment.host.remote(of: "Devices:remote")?.controls.first?.targets == ["Devices:relay#channel2"])
        let refusals: [JSONValue] = [
            // Nothing to dim: appliances only.
            ["remote": "Devices:remote", "part": "bottom", "controls": [["gesture": "hold", "action": "dim", "targets": ["Devices:relay"]]]],
            // Its own power.
            ["remote": "Devices:remote", "part": "bottom", "controls": [["gesture": "press", "action": "on", "targets": ["Devices:relay#channel1"], "power": ["Devices:relay#channel1"]]]],
        ]
        for arguments in refusals {
            #expect(try await client.tool("set_remote_controls", arguments)["isError"] == true)
        }
        // A hold dims the lamp and leaves the relay beside it.
        let mixed = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "bottom",
                                                                  "controls": [["gesture": "hold", "action": "dim", "targets": ["Devices:lamp", "Devices:relay"]]]])
        #expect(mixed["isError"] != true, "\(mixed)")
        // A lock is driven too, once the user confirms (docs/adr/0012-a-remote-drives-what-it-is-given.md).
        #expect(targets.first { $0["id"] == "Devices:lock" }?["security"] == true)
        let unlock: JSONValue = ["remote": "Devices:remote", "part": "bottom", "controls": [["gesture": "press", "action": "toggle", "targets": ["Devices:lock"]]]]
        #expect(try await client.tool("set_remote_controls", unlock)["isError"] == true)
        #expect(environment.host.remote(of: "Devices:remote")?.controls.contains { $0.targets == ["Devices:lock"] } == false)
        let confirmed = try await client.tool("set_remote_controls", unlock, answer: ["action": "accept", "content": ["confirm": true]])
        #expect(confirmed["isError"] != true, "\(confirmed)")
        #expect(environment.host.remote(of: "Devices:remote")?.controls.contains { $0.targets == ["Devices:lock"] } == true)
        // Named already: saved again without asking.
        #expect(try await client.tool("set_remote_controls", unlock)["isError"] != true)
        // Not on the bridge now (a Function's separated id before Separate Functions is on): it cannot be shown not to be a
        // lock, so it asks too.
        let unseen: JSONValue = ["remote": "Devices:remote", "part": "bottom", "controls": [["gesture": "press", "action": "toggle", "targets": ["Devices:relay:channel1"]]]]
        #expect(try await client.tool("set_remote_controls", unseen)["isError"] == true)
        #expect(try await client.tool("update_settings", ["accessory": "Devices:remote", "settings": ["controls": [
            ["part": "bottom", "gesture": "press", "action": "toggle", "targets": ["Devices:relay:channel1"]]]]])["isError"] == true)
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "bottom", "controls": [["gesture": "hold", "action": "dim", "targets": ["Devices:lamp", "Devices:relay"]]]])

        // Separate Functions on: channel 2 is an accessory of its own, and the Control follows it; off, back.
        let separate = try await client.tool("update_settings", ["accessory": "Devices:relay", "settings": ["separateFunctions": true]])
        #expect(separate["isError"] != true, "\(separate)")
        #expect(await eventually { environment.host.remote(of: "Devices:remote")?.controls.first?.targets == ["Devices:relay:channel2"] })
        _ = try await client.tool("update_settings", ["accessory": "Devices:relay", "settings": ["separateFunctions": .null]])
        #expect(await eventually { environment.host.remote(of: "Devices:remote")?.controls.first?.targets == ["Devices:relay#channel2"] })
    }

    /// A Button's presses start Automations as their press Triggers; never a long press while it holds to dim.
    @Test func aButtonStartsAutomations() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let saved = try catalog.saveAutomation(["name": "Evening", "triggers": [["type": "time", "at": "19:00"]],
                                                "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 30]]])
        let id = try #require(saved["id"]?.stringValue)
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let answer = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "top", "controls": [], "automations": ["double": [.string(id)]]])
        #expect(answer["isError"] != true, "\(answer)")
        let triggers = catalog.home.automations.value.automations.first?.triggers ?? []
        #expect(triggers.count == 2 && triggers[1].type == "press" && triggers[1].id == "Devices:remote" && triggers[1].press == "double")
        // The page lists it under the Button, by its gesture.
        let part = try #require(try await client.tool("list_remotes", [:])["structuredContent"]?["remotes"]?[0]?["parts"]?[0])
        #expect(part["automations"]?[0]?["gesture"] == "double" && part["automations"]?[0]?["id"]?.stringValue == id)
        // Its other Button starts nothing.
        #expect(try await client.tool("list_remotes", [:])["structuredContent"]?["remotes"]?[0]?["parts"]?[1]?["automations"] == [])

        // A long press while the Button holds to dim: refused.
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "top",
                                                          "controls": [["gesture": "hold", "action": "dim", "targets": ["Devices:lamp"]]]])
        #expect(throws: CatalogError.self) { try catalog.setRemoteAutomations([.long: [id]], part: "top", of: "Devices:remote") }
        #expect(throws: CatalogError.self) { try catalog.setRemoteAutomations([.hold: [id]], part: "top", of: "Devices:remote") }
        // Taking a long press's Automations away is never refused.
        #expect(try catalog.setRemoteAutomations([.long: []], part: "top", of: "Devices:remote").isEmpty)
        // Taken off, its time Trigger stays.
        try catalog.setRemoteAutomations([.double: []], part: "top", of: "Devices:remote")
        #expect(catalog.home.automations.value.automations.first?.triggers.map(\.type) == ["time"])
        // Its only Trigger is not taken away.
        let pressOnly = try catalog.saveAutomation(["name": "Press only", "triggers": [["type": "press", "id": "Devices:remote", "service": "top", "press": "single"]],
                                                    "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": true]]])
        #expect(throws: CatalogError.self) { try catalog.setRemoteAutomations([.press: []], part: "top", of: "Devices:remote") }
        #expect(catalog.savedAutomation(reference: pressOnly["id"]?.stringValue ?? "")?.triggers.count == 1)
    }
}
