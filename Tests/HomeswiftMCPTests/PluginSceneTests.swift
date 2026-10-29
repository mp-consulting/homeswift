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
        _ = run
        _ = try await client.tool("stop_scene", ["scene": "Devices:Devices:magenta"])
        #expect(hue.value == .double(10))

        let byName = try await environment.catalog.runScene("magenta")
        #expect(byName["sceneId"] == "Devices:Devices:magenta")
        #expect(hue.value == .double(300))
    }

    /// stop_scene puts back what a hub's scene changed, by the hub scene's id; the list says it can until then.
    @Test func stopSceneUndoesAHubScene() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let hue = try environment.catalog.characteristic(in: try #require(environment.catalog.find(id: "Devices:bulb1")), service: nil, characteristic: "Hue")
        _ = try await client.tool("run_scene", ["scene": "Devices:Devices:magenta"])
        #expect(await environment.catalog.allScenesJSON()["pluginScenes"]?[0]?["stoppable"] == true)
        let stopped = try await client.tool("stop_scene", ["scene": "Devices:Devices:magenta"])["structuredContent"]
        #expect(stopped?["ok"] == true)
        #expect(hue.value == .double(10))
        #expect(await environment.catalog.allScenesJSON()["pluginScenes"]?[0]?["stoppable"] == false)
    }

    /// A saved scene can recall a hub's scene among its values; stopping the scene puts those lights back too.
    @Test func aSceneRecallsAHubScene() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let hue = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:bulb1")), service: nil, characteristic: "Hue")
        let lamp = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:lamp")), service: nil, characteristic: "Brightness")
        let saved = try catalog.createScene(["name": "Evening", "actions": [["recall": "Devices:Devices:magenta"], ["id": "Devices:lamp", "characteristic": "Brightness", "value": 70]]])
        let id = try #require(saved["id"]?.stringValue)
        let listed = await catalog.allScenesJSON()["scenes"]?[0]?["actions"]?[0]
        #expect(listed?["recall"] == "Devices:Devices:magenta")
        #expect(listed?["name"] == "Magenta")
        let ran = try await catalog.runScene(id)
        #expect(ran["ok"] == true)
        #expect(hue.value == .double(300))
        #expect(lamp.value == .int(70))
        #expect(catalog.scenesJSON()["scenes"]?[0]?["stoppable"] == true)
        #expect(try await catalog.stopScene(id)["ok"] == true)
        #expect(hue.value == .double(10))
        #expect(lamp.value == .int(40))
        // A hub's scene that went away is skipped and reported.
        let gone = try catalog.createScene(["name": "Gone", "actions": [["recall": "Devices:Devices:nope"]]])
        let result = try await catalog.runScene(try #require(gone["id"]?.stringValue))
        #expect(result["ok"] == false)
        #expect(await catalog.allScenesJSON()["scenes"]?[1]?["actions"]?[0]?["missing"] == true)
    }

    /// An MCP client composes a scene and runs it without saving it; stop_scene with its run puts it back, and
    /// save_scene keeps a plan. A plan that unlocks is refused.
    @Test func plansRunUndoAndSave() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let catalog = environment.catalog
        let lamp = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:lamp")), service: nil, characteristic: "Brightness")
        let hue = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:bulb1")), service: nil, characteristic: "Hue")
        let plan: JSONValue = ["name": "Cozy", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 25], ["recall": "Devices:Devices:magenta"]]]

        let ran = try await client.tool("run_scene", ["plan": plan])["structuredContent"]
        #expect(ran?["ok"] == true)
        #expect(ran?["plan"]?["actions"]?.arrayValue?.count == 2)
        #expect(lamp.value == .int(25))
        #expect(hue.value == .double(300))
        #expect(catalog.scenesJSON()["scenes"] == [])
        let run = try #require(ran?["run"]?.stringValue)
        #expect(try await client.tool("stop_scene", ["scene": .string(run)])["structuredContent"]?["ok"] == true)
        #expect(lamp.value == .int(40))
        #expect(hue.value == .double(10))

        let dry = try await client.tool("save_scene", ["name": "Cozy", "plan": plan, "dryRun": true])["structuredContent"]
        #expect(dry?["dryRun"] == true)
        #expect(catalog.scenesJSON()["scenes"] == [])
        _ = try await client.tool("save_scene", ["name": "Cozy", "plan": plan])
        #expect(catalog.scenesJSON()["scenes"]?[0]?["name"] == "Cozy")

        let unlock = try await client.tool("run_scene", ["plan": ["actions": [["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0]]]])
        #expect(unlock["isError"] == true)
        #expect(!environment.written.contains { $0.0 == "lock.target" })
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

    /// A scene's picture is the core's, a hub's scene's too: listed by version, refused for a scene that does not
    /// exist, and gone with the scene.
    @Test func scenesHavePicturesOfTheirOwn() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let jpeg = "data:image/jpeg;base64," + (Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 16)).base64EncodedString()
        let hub = try await catalog.setScenePicture("Devices:Devices:magenta", dataURL: jpeg)
        #expect(await catalog.allScenesJSON()["pluginScenes"]?[0]?["picture"] == hub["picture"])
        #expect(catalog.scenePicture("Devices:Devices:magenta")?.type == "image/jpeg")
        let saved = try catalog.createScene(["name": "Reading", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 40]]])
        let id = try #require(saved["id"]?.stringValue)
        _ = try await catalog.setScenePicture(id, dataURL: jpeg)
        #expect(catalog.scenesJSON()["scenes"]?[0]?["picture"]?.stringValue != nil)
        await #expect(throws: CatalogError.self) { try await catalog.setScenePicture("nope", dataURL: jpeg) }
        await #expect(throws: CatalogError.self) { try await catalog.setScenePicture(id, dataURL: "data:image/png;base64,PHN2Zz4=") }
        try catalog.deleteScene(id: id)
        #expect(catalog.scenePicture(id) == nil)
        try await catalog.removeScenePicture("Devices:Devices:magenta")
        #expect(await catalog.allScenesJSON()["pluginScenes"]?[0]?["picture"] == .null)
    }

    /// save_scene keeps a plan on a hub that has every light (its dry run says which can), update_hub_scene renames a
    /// hub's scene and keeps its lights as they are, delete_hub_scene asks first and removes it. What a hub cannot keep
    /// is refused.
    @Test func scenesAreWrittenToHubs() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let plugin = environment
        let plan: JSONValue = ["actions": [
            ["id": "Devices:bulb1", "characteristic": "On", "value": true], ["id": "Devices:bulb1", "characteristic": "Brightness", "value": 30],
            ["id": "Devices:bulb1", "characteristic": "Hue", "value": 120], ["id": "Devices:bulb1", "characteristic": "Saturation", "value": 90],
        ]]
        let dry = try await client.tool("save_scene", ["name": "Green", "plan": plan, "dryRun": true])["structuredContent"]
        #expect(dry?["hubs"] == [["hub": "Devices:Devices", "name": "Devices", "label": "salon"]])

        let saved = try await client.tool("save_scene", ["name": "Green", "plan": plan, "hub": "Devices:Devices"])["structuredContent"]
        let id = try #require(saved?["created"]?["id"]?.stringValue)
        #expect(id == "Devices:Devices:written-1")
        #expect(environment.catalog.scenesJSON()["scenes"] == [])
        let kept = try #require(plugin.hubScenes.withLockedValue { $0["written-1"] })
        #expect(kept.lights == [PluginSceneLight(accessoryID: "Devices:bulb1", on: true, brightness: 30, hue: 120, saturation: 90)])

        // A lamp the hub does not have, a lock, a trigger-less recall: refused.
        let lamp = try await client.tool("save_scene", ["name": "Lamp", "plan": ["actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 10]]], "hub": "Devices:Devices"])
        #expect(lamp["isError"] == true)
        let recall = try await client.tool("save_scene", ["name": "Recall", "plan": ["actions": [["recall": "Devices:Devices:magenta"]]], "hub": "Devices:Devices"])
        #expect(recall["isError"] == true)

        let renamed = try await client.tool("update_hub_scene", ["scene": .string(id), "name": "Emerald", "fromCurrent": true])["structuredContent"]
        #expect(renamed?["updated"] == true)
        #expect(plugin.hubScenes.withLockedValue { $0["written-1"]?.name } == "Emerald")
        #expect(plugin.hubScenes.withLockedValue { $0["written-1"]?.lights.first?.hue } == 10)
        let magenta = try await client.tool("update_hub_scene", ["scene": "Devices:Devices:magenta", "name": "Pink"])
        #expect(magenta["isError"] == true)

        // A client that cannot ask gets a code in the log; the scene stays until it is given.
        let unconfirmed = try await client.tool("delete_hub_scene", ["scene": .string(id)])
        #expect(unconfirmed["isError"] == true)
        #expect(plugin.hubScenes.withLockedValue { $0["written-1"] } != nil)
        _ = try await environment.catalog.deleteHubScene(id)
        #expect(plugin.hubScenes.withLockedValue { $0.isEmpty })
    }

    /// A scene chosen for HomeKit is a switch of the Homeswift Scenes accessory: on runs it, off puts the lights back,
    /// and it goes when no scene is chosen. Its iid stays while the scene does.
    @Test func scenesBecomeHomeKitSwitches() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let server = environment.host.mainBridge.server
        let lamp = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:lamp")), service: nil, characteristic: "Brightness")
        let saved = try catalog.createScene(["name": "Reading", "homeKit": true, "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 75]]])
        let id = try #require(saved["id"]?.stringValue)
        _ = try catalog.createScene(["name": "Other", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 10]]])
        let accessory = try #require(server.accessories.first { $0.id == "Homeswift:scenes" })
        #expect(accessory.services.compactMap(\.subtype) == ["scene:" + id])
        let on = try #require(accessory.services.first { $0.subtype == "scene:" + id }?[.on])
        let iid = on.iid
        #expect(on.value == .bool(false))

        try await on.write(true)
        #expect(await eventually { lamp.value == .int(75) })
        #expect(await eventually { on.value == .bool(true) })
        try await on.write(false)
        #expect(await eventually { lamp.value == .int(40) })
        #expect(catalog.scenesJSON()["scenes"]?[0]?["lastRun"]?["trigger"] == "homeKit")

        // Renamed, it keeps its iid; chosen for nothing, the accessory goes.
        _ = try catalog.updateScene(id: id, ["name": "Reading time", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 75]]])
        #expect(server.accessories.first { $0.id == "Homeswift:scenes" }?.services.first { $0.subtype == "scene:" + id }?[.on]?.iid == iid)
        _ = try catalog.updateScene(id: id, ["name": "Reading time", "homeKit": false, "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 75]]])
        #expect(!server.accessories.contains { $0.id == "Homeswift:scenes" })
    }

    /// Characteristic names compare by letters and digits, case aside, ASCII or not.
    @Test func namesNormalizeAsBefore() {
        for name in ["Target Lock State", "targetLockState", "target-lock-state", "PM2.5 Density", "Température", "Ünïcode Näme 2", ""] {
            let normal = name.lowercased().filter { $0.isLetter || $0.isNumber }
            #expect(HomeswiftCatalog.normalized(name) == normal)
            #expect(HomeswiftCatalog.name(name, normalizesTo: normal))
            #expect(!HomeswiftCatalog.name(name + "x", normalizesTo: normal))
        }
        #expect(!HomeswiftCatalog.name("Brightness", normalizesTo: "bright"))
        #expect(SceneArtwork.matching(name: "arctic AURORA!")?.id == "arctic-aurora")
    }
}
