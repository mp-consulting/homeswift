import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// Animated scenes: each plugin plays the lights it can natively, Homeswift's player the rest; stopping puts every
/// light back (docs/scenes-design.md, "Animation").
@Suite struct SceneAnimationTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
          "platforms": [ { "platform": "Devices", "name": "Devices", "colourBulbs": 2 } ]
        }
        """

    /// The plugin plays the candle on the light it can; the player plays the other; the scene is active while they
    /// play, and stopping it tells the plugin to stop and puts both lights back.
    @Test func nativeWhereThePluginCanPlayerElsewhere() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let hue2 = try catalog.characteristic(in: try #require(catalog.find(id: "Devices:bulb2")), service: nil, characteristic: "Hue")
        let saved = try catalog.createScene(["name": "Dinner", "animation": ["lights": ["Devices:bulb1", "Devices:bulb2"], "effect": ["style": "candle", "speed": 0.8]]])
        let id = try #require(saved["id"]?.stringValue)
        #expect(saved["actions"] == [])

        let ran = try await catalog.runScene(id)
        #expect(ran["animation"]?["native"] == ["Devices:bulb1"])
        #expect(ran["animation"]?["played"] == ["Devices:bulb2"])
        #expect(environment.written.contains { $0.0 == "bulb1.effect" && $0.1 == .string("candle") })
        #expect(await eventually { hue2.value != .double(10) })
        #expect(catalog.scenesJSON()["scenes"]?[0]?["active"] == true)
        #expect(catalog.scenesJSON()["scenes"]?[0]?["animation"]?["effect"]?["style"] == "candle")

        #expect(try await catalog.stopScene(id)["ok"] == true)
        #expect(environment.written.contains { $0.0 == "Devices:bulb1.effect" && $0.1 == .string("stop") })
        #expect(await eventually { hue2.value == .double(10) })
        #expect(catalog.scenesJSON()["scenes"]?[0]?["active"] == false)
    }

    /// An MCP client composes an animated plan; a timed sequence plays on every light, natively or not.
    @Test func plansAndSequencesAnimate() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let plan: JSONValue = ["animation": ["lights": ["Devices:bulb1", "Devices:bulb2"], "steps": [
            ["colors": [["hue": 0, "saturation": 100, "brightness": 100], ["hue": 235, "saturation": 100, "brightness": 100]], "seconds": 0.5],
            ["colors": [["hue": 235, "saturation": 100, "brightness": 100], ["hue": 0, "saturation": 100, "brightness": 100]], "seconds": 0.5],
        ], "loop": true, "durationSeconds": 30]]
        let ran = try await client.tool("run_scene", ["plan": plan])["structuredContent"]
        #expect(ran?["animation"]?["kind"] == "sequence")
        #expect(ran?["animation"]?["native"] == [])
        #expect(ran?["animation"]?["played"] == ["Devices:bulb1", "Devices:bulb2"])
        let run = try #require(ran?["run"]?.stringValue)
        #expect(environment.catalog.isPlaying(run))
        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        #expect(!environment.catalog.isPlaying(run))
    }

    /// An animation is checked: lights, an effect or steps (not both), a palette of two colours or more, ranges.
    @Test func animationsAreChecked() throws {
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": [], "effect": ["style": "fire"]]) }
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": ["a"]]) }
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": ["a"], "effect": ["style": "fire"], "steps": []]) }
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": ["a"], "effect": ["style": "palette", "colors": [["hue": 10]]]]) }
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": ["a"], "effect": ["style": "fire", "speed": 2]]) }
        #expect(throws: CatalogError.self) { try SceneAnimation.checked(["lights": ["a"], "effect": ["style": "lava"]]) }
        #expect(try SceneAnimation.checked(["lights": ["a"], "effect": ["style": "sunrise", "durationSeconds": 600]]).kind == "effect")
    }

    /// The player's version of each style: music is left to devices that hear it; a sunrise does not loop and lasts
    /// its duration; a tint colours the style.
    @Test func fallbackMoods() throws {
        #expect(HomeswiftCatalog.fallbackMood(LightEffect(style: .music), id: "x", name: "x") == nil)
        for style in LightEffect.Style.allCases where style != .music && style != .palette {
            let mood = try #require(HomeswiftCatalog.fallbackMood(LightEffect(style: style), id: "x", name: "x"), "\(style)")
            try MoodRules.check(mood)
        }
        let sunrise = try #require(HomeswiftCatalog.fallbackMood(LightEffect(style: .sunrise, durationSeconds: 600), id: "x", name: "x"))
        #expect(sunrise.loop == false)
        #expect(abs(sunrise.steps.reduce(0) { $0 + $1.seconds } - 600) < 1)
        let blueFire = try #require(HomeswiftCatalog.fallbackMood(LightEffect(style: .fire, colors: [.init(hue: 230, saturation: 90)]), id: "x", name: "x"))
        #expect(blueFire.steps.flatMap(\.colors).filter { !$0.isOff }.allSatisfy { $0.hue == 230 })
        let palette = try #require(HomeswiftCatalog.fallbackMood(LightEffect(style: .palette, colors: [.init(hue: 0, saturation: 100), .init(hue: 120, saturation: 100)]), id: "x", name: "x"))
        #expect(palette.loop == true)
    }
}
