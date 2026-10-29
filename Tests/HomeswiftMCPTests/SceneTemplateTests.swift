import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// Templates and scenes the Assistant writes: plans for a room's lights, tried with undo, saved when liked
/// (docs/scenes-design.md, "Surfaces").
@Suite struct SceneTemplateTests {
    private func hue(_ environment: MCPTestEnvironment, _ id: String) -> HAPValue? {
        environment.catalog.find(id: id)?.accessory.services.first { $0.type.uuid == ServiceType.lightbulb.uuid }?[.hue]?.value
    }

    /// The templates say what kind of plan each makes: values set once, an effect, or a timed sequence.
    @Test func templatesSayTheirKind() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let templates = try await client.tool("list_scene_templates")["structuredContent"]?["templates"]?.arrayValue ?? []
        let kind = { (id: String) in templates.first { $0["id"] == .string(id) }?["kind"]?.stringValue }
        #expect(kind("candlelight") == "static")
        #expect(kind("fireplace") == "effect")
        #expect(kind("police") == "sequence")
        #expect(templates.contains { $0["category"] == "gallery" })
    }

    /// A template tried on a room sets its lights, shows among the tries with its plan, and is undone by its run.
    @Test func aTemplateIsTriedAndUndone() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let ran = try await client.tool("run_scene", ["template": "romantic", "room": "Den"])["structuredContent"]
        #expect(ran?["ok"] == true)
        #expect(ran?["template"] == "romantic")
        // Romantic's two colours, spread over the room's lights in order.
        #expect([340, 355].contains(hue(environment, "Devices:bulb1")?.doubleValue ?? 0))
        let tries = environment.catalog.sceneTemplatesJSON()["tries"]?.arrayValue ?? []
        #expect(tries.count == 1)
        #expect(tries.first?["room"] == "Den")
        #expect(tries.first?["plan"]?["actions"]?.arrayValue?.isEmpty == false)
        let run = try #require(ran?["run"]?.stringValue)
        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        #expect(hue(environment, "Devices:bulb1")?.doubleValue == 10)
        #expect(environment.catalog.sceneTemplatesJSON()["tries"] == [])
    }

    /// An effect template becomes an animation each brand plays its own way; a signal is a sequence that puts the
    /// lights back at its end; save_scene keeps a template as a scene.
    @Test func animatedTemplatesAndSaving() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let candle = try await client.tool("run_scene", ["template": "candle-flicker", "room": "Den"])["structuredContent"]
        #expect(candle?["plan"]?["animation"]?["effect"]?["style"] == "candle")
        #expect(candle?["animation"]?["native"] == ["Devices:bulb1"])
        _ = try await client.tool("stop_scene", ["scene": .string(try #require(candle?["run"]?.stringValue))])

        let alert = environment.catalog.templatePlan(try #require(MoodLibrary.find("alert")), lights: try environment.catalog.moodLights(ids: ["Devices:bulb1"], filter: HomeswiftCatalog.AccessoryFilter(nil)))
        #expect(alert["animation"]?["restore"] == true)
        #expect(alert["animation"]?["steps"]?.arrayValue?.isEmpty == false)

        _ = try await client.tool("save_scene", ["name": "Fire in the den", "template": "fireplace", "room": "Den"])
        let saved = environment.catalog.scenesJSON()["scenes"]?[0]
        #expect(saved?["name"] == "Fire in the den")
        #expect(saved?["animation"]?["effect"]?["style"] == "fire")
        #expect(saved?["artworkId"]?.stringValue != nil)
    }

    /// The Assistant writes a scene from a description, from what the lights take and never their names.
    @Test func theAssistantWritesAScene() async throws {
        let model = MoodModel()
        let (environment, client) = try await den(model: model)
        defer { Task { await environment.stop() } }
        let ran = try await client.tool("run_scene", ["description": "a calm sea at night", "room": "Den"])["structuredContent"]
        #expect(ran?["designed"] == true)
        #expect(ran?["name"] == "Calm sea")
        #expect(hue(environment, "Devices:bulb1")?.doubleValue == 200)
        #expect(!model.sent.contains("Bulb") && !model.sent.contains("Den"))
    }
}
