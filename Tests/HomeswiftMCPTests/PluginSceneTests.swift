import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// The scenes plugins' hubs keep, listed and run with Homeswift's own (docs/scenes-design.md).
@Suite struct PluginSceneTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
          "platforms": [ { "platform": "Devices", "name": "Devices", "colourBulbs": 2, "mirroredBulb": true } ]
        }
        """

    /// list_scenes lists the hub's scene with its source, in the Homeswift room named as the hub's room (case aside).
    @Test func listsHubScenesInTheirRoom() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let listed = try await client.tool("list_scenes")["structuredContent"]
        let scene = try #require(listed?["pluginScenes"]?[0])
        #expect(scene["id"] == "Devices:Devices:magenta")
        #expect(scene["name"] == "Magenta")
        #expect(scene["room"] == "Salon")
        #expect(scene["hubRoom"] == "salon")
        #expect(scene["active"] == false)
        #expect(scene["colours"] == ["#ff00ff"])
        #expect(scene["capabilities"] == ["recall"])
        #expect(scene["source"]?["pluginName"] == "Devices Plugin")
    }

    /// run_scene recalls a hub scene by id or by name; the lights it changed are held, and stopping that run puts
    /// them back.
    @Test func runsHubScenesAndHoldsTheirLights() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let bulb = try #require(environment.catalog.find(id: "Devices:bulb1"))
        let hue = try environment.catalog.characteristic(in: bulb, service: nil, characteristic: "Hue")

        let ran = try await client.tool("run_scene", ["scene": "Devices:Devices:magenta"])["structuredContent"]
        #expect(ran?["ok"] == true)
        #expect(hue.value == .double(300))
        let run = try #require(ran?["run"]?.stringValue)
        _ = try await client.tool("stop_mood", ["run": .string(run)])
        #expect(hue.value == .double(10))

        let byName = try await environment.catalog.runScene("magenta")
        #expect(byName["sceneId"] == "Devices:Devices:magenta")
        #expect(hue.value == .double(300))
    }

    /// A Homeswift scene is active while every value it sets is what its accessory shows.
    @Test func homeswiftScenesKnowWhenTheyAreActive() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        _ = try catalog.createScene(["name": "Reading", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 40]]])
        _ = try catalog.createScene(["name": "Bright", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 90]]])
        let scenes = await catalog.allScenesJSON()["scenes"]?.arrayValue ?? []
        #expect(scenes.first { $0["name"] == "Reading" }?["active"] == true)
        #expect(scenes.first { $0["name"] == "Bright" }?["active"] == false)
        #expect(await catalog.allScenesJSON()["pluginScenes"] == [])
    }
}
