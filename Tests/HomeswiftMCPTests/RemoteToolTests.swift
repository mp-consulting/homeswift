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
        #expect(targets.contains("Devices:lamp") && !targets.contains("Devices:lock"))
        // The door's trigger (a switch marked a security control) powers nothing.
        #expect(!(listed["power"]?.arrayValue?.contains { $0["id"] == "Devices:lock" } ?? true))

        let press: JSONValue = ["gesture": "press", "action": "toggle", "targets": ["Devices:lamp"]]
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "top", "controls": [press]])
        _ = try await client.tool("set_remote_controls", ["remote": "Devices:remote", "part": "bottom",
                                                          "controls": [["gesture": "hold", "action": "dim", "direction": "down", "targets": ["Devices:lamp"]]]])
        let controls = environment.host.remote(of: "Devices:remote")?.controls ?? []
        #expect(controls.map(\.part) == ["top", "bottom"] && controls[1].direction == .down)

        // Refused: a security control as power, a gesture the part does not have, a part it does not have.
        let refusals: [JSONValue] = [
            ["remote": "Devices:remote", "part": "top", "controls": [["gesture": "press", "action": "on", "targets": ["Devices:lamp"], "power": ["Devices:lock"]]]],
            ["remote": "Devices:remote", "part": "top", "controls": [["gesture": "turn", "action": "step", "targets": ["Devices:lamp"]]]],
            ["remote": "Devices:remote", "part": "middle", "controls": [press]],
        ]
        for arguments in refusals {
            let answer = try await client.tool("set_remote_controls", arguments)
            #expect(answer["isError"] == true)
        }
        // The same security refusal through update_settings.
        let direct = try await client.tool("update_settings", ["accessory": "Devices:remote", "settings": ["controls": [
            ["part": "top", "gesture": "press", "action": "on", "targets": ["Devices:lamp"], "power": ["Devices:lock"]]]]])
        #expect(direct["isError"] == true)
        #expect(environment.host.remote(of: "Devices:remote")?.controls.count == 2)
    }
}
