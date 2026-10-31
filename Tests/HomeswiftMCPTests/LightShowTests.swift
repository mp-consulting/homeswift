import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftMCP

/// A bridge with the devices plugin's lamp and lock and `bulbs` colour bulbs, the last failing every write when
/// `failing`; with `assistant`, an OpenAI-compatible provider the test answers for.
func sceneConfig(bulbs: Int = 2, failing: Bool = false, slow: Bool = false, assistant: Bool = false) -> String {
    let ai = assistant ? #""provider": "openai-compatible", "model": "llama3.1", "baseUrl": "http://127.0.0.1:9/v1", "maxRetries": 0, "# : ""
    return """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:57", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "colourBulbs": \(bulbs), "failingBulb": \(failing), "slowBulbs": \(slow) },
            { "platform": "HomeswiftAiKit", \(ai)"mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """
}

/// A started environment whose lights (and lock) are in the room Den.
func den(bulbs: Int = 2, failing: Bool = false, slow: Bool = false, model: (any HTTPTransport)? = nil) async throws -> (MCPTestEnvironment, DirectClient) {
    let environment = try MCPTestEnvironment(config: sceneConfig(bulbs: bulbs, failing: failing, slow: slow, assistant: model != nil), aiTransport: model)
    try await environment.start()
    let client = DirectClient(server: environment.server)
    try await client.initialize()
    let ids = ["Devices:lamp", "Devices:lock"] + (1...bulbs).map { "Devices:bulb\($0)" }
    let layout = try await client.tool("set_accessory_layout", ["accessories": .array(ids.map { ["id": .string($0), "room": "Den"] })])
    #expect(layout["isError"] != true)
    return (environment, client)
}

private func value(_ environment: MCPTestEnvironment, _ id: String, _ type: CharacteristicType) -> HAPValue? {
    environment.catalog.find(id: id)?.accessory.services.first { $0.type.uuid == ServiceType.lightbulb.uuid }?[type]?.value
}

/// Two colours swapping every half second, for a minute: the steps of an animation.
private let blinkSteps: JSONValue = [
    ["colors": [["hue": 0, "saturation": 100, "brightness": 90], ["hue": 240, "saturation": 100, "brightness": 90]], "seconds": 0.5],
    ["colors": [["hue": 240, "saturation": 100, "brightness": 90], ["hue": 0, "saturation": 100, "brightness": 90]], "seconds": 0.5],
]

/// A plan that blinks these lights for a minute.
private func blink(_ lights: [String]) -> JSONValue {
    ["name": "Blink", "animation": ["lights": .array(lights.map(JSONValue.string)), "steps": blinkSteps, "loop": true, "durationSeconds": 60]]
}

private let denBulbs = ["Devices:bulb1", "Devices:bulb2"]

/// An OpenAI-compatible server in memory that answers every request with a scene the Assistant wrote, and keeps what
/// it was sent.
final class SceneModel: HTTPTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private var bodies: [String] = []
    var sent: String { lock.withLock { bodies.joined(separator: "\n") } }

    private let scene = #"{"name": "Calm sea", "steps": [{"colors": [{"hue": 200, "saturation": 60, "brightness": 35}], "seconds": 1}]}"#

    private func reply(_ request: HTTPRequest) -> Data {
        lock.withLock { bodies.append(String(decoding: request.body, as: UTF8.self)) }
        let answer: [String: Any] = [
            "model": "llama3.1", "usage": ["prompt_tokens": 120, "completion_tokens": 40],
            "choices": [["index": 0, "message": ["role": "assistant", "content": scene], "finish_reason": "stop"]],
        ]
        return try! JSONSerialization.data(withJSONObject: answer)
    }

    func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: reply(request))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let chunk: [String: Any] = ["model": "llama3.1", "choices": [["index": 0, "delta": ["content": scene], "finish_reason": "stop"]],
                                    "usage": ["prompt_tokens": 120, "completion_tokens": 40]]
        _ = reply(request)
        let data = try JSONSerialization.data(withJSONObject: chunk)
        return HTTPStream(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { continuation in
            continuation.yield(Data("data: ".utf8) + data + Data("\n\ndata: [DONE]\n\n".utf8))
            continuation.finish()
        })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LightShowTests {
    /// Every template is valid, described and drawn, and the web UI names each one (so it translates them).
    @Test func theTemplatesAreValidAndTranslated() throws {
        var ids: Set<String> = []
        for template in SceneTemplateLibrary.all {
            try LightShowRules.check(template)
            let id = try #require(template.id)
            #expect(ids.insert(id).inserted, "\(id) twice")
            #expect(["calm", "animated", "party", "signal", "gallery"].contains(template.category ?? ""))
            #expect(template.description?.isEmpty == false)
            #expect(!SceneTemplateLibrary.swatch(template).isEmpty)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/HomeswiftUI/Web/home.js"), encoding: .utf8)
        for id in ids where !id.hasPrefix("gallery-") { #expect(page.contains("\"\(id)\": [t("), "home.js does not name \(id)") }
    }

    /// A gallery template saved as a scene keeps its picture, which is checked against the catalogue.
    @Test func galleryArtworkPersistsAndValidates() async throws {
        #expect(SceneArtwork.all.count == 143)
        #expect(Set(SceneArtwork.all.map(\.id)).count == 143)
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        _ = try await client.tool("save_scene", ["name": "Aurora", "template": "gallery-arctic-aurora", "room": "Den"])
        let saved = try #require(environment.catalog.scenesJSON()["scenes"]?[0])
        #expect(saved["artworkId"] == "arctic-aurora")
        let id = try #require(saved["id"]?.stringValue)
        let scene = try environment.catalog.scene(id)
        #expect(try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(scene)).artworkId == "arctic-aurora")
        let actions = JSONValue.array((saved["actions"]?.arrayValue ?? []).map { action in
            var entry = action.objectValue ?? [:]
            entry.removeValue(forKey: "name")
            return .object(entry)
        })
        let body: JSONValue = ["name": "Renamed", "actions": actions]
        #expect(try environment.catalog.updateScene(id: id, body)["artworkId"] == "arctic-aurora")
        var changed = try #require(body.objectValue)
        changed["artworkId"] = "../outside"
        #expect(throws: (any Error).self) { try environment.catalog.updateScene(id: id, .object(changed)) }
        changed["artworkId"] = .null
        #expect(try environment.catalog.updateScene(id: id, .object(changed))["artworkId"] == nil)
    }

    @Test func dedicatedTemplatePhotographsResolve() throws {
        for id in ["disco", "police", "lightning", "alert", "cinema", "fireplace", "rainbow-wave", "candle-flicker"] {
            let artwork = try #require(SceneArtwork.forTemplate(id))
            #expect(artwork.id == "mood-" + id)
            #expect(SceneArtwork.find(artwork.id) != nil)
        }
    }

    @Test func showsAreChecked() throws {
        let good: JSONValue = ["name": "Test", "steps": [["colors": [["hue": 120, "saturation": 100, "brightness": 50]], "seconds": 1]]]
        #expect(try LightShowRules.show(from: good).name == "Test")
        let bad: [(JSONValue, String)] = [
            (["name": "x", "steps": [["colors": [["hue": 120]], "seconds": 0.2]]], "seconds"),
            (["name": "x", "steps": [["colors": [["hue": 400]], "seconds": 1]]], "hue"),
            (["name": "x", "steps": []], "steps"),
            (["name": "x", "steps": [["colors": [[:]], "seconds": 1]]], "at least one"),
            (["steps": [["colors": [["hue": 1]], "seconds": 1]]], "name"),
            (["name": "x", "durationSeconds": 7200, "steps": [["colors": [["hue": 1]], "seconds": 1]]], "durationSeconds"),
        ]
        for (plan, word) in bad {
            let error = #expect(throws: CatalogError.self) { try LightShowRules.show(from: plan) }
            #expect(error?.description.contains(word) == true, "\(error?.description ?? "no error") should mention \(word)")
        }
    }

    @Test func valuesFitTheCharacteristic() {
        #expect(LightShowRules.hapNumber(140, for: Characteristic(.brightness, value: .int(0))) == .int(100))
        #expect(LightShowRules.hapNumber(-3, for: Characteristic(.hue, value: .double(0))) == .double(0))
        #expect(LightShowRules.hapNumber(37.4, for: Characteristic(.hue, value: .double(0))) == .double(37))
        #expect(LightShowRules.hapNumber(90, for: Characteristic(.colorTemperature, value: .int(140))) == .int(140))
    }

    /// A calm template sets every light of the room once (the lock is no light); stop_scene with its run puts every
    /// light back, the lamp included.
    @Test func aCalmTemplateSetsTheRoomAndIsUndone() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let lampBefore = value(environment, "Devices:lamp", .brightness)

        let result = try await client.tool("run_scene", ["template": "focus", "room": "den"])
        #expect(result["structuredContent"]?["ok"] == true)
        #expect(value(environment, "Devices:bulb1", .colorTemperature) == .int(200))
        #expect(value(environment, "Devices:bulb2", .brightness) == .int(100))
        #expect(value(environment, "Devices:bulb1", .on) == .bool(true))
        #expect(environment.written.contains { $0.0 == "lamp.brightness" && $0.1 == .int(100) })
        #expect(!environment.written.contains { $0.0.hasPrefix("lock") || $0.0.hasPrefix("trigger") })

        let run = try #require(result["structuredContent"]?["run"]?.stringValue)
        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        for bulb in denBulbs {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .colorTemperature) == .int(300))
        }
        #expect(value(environment, "Devices:lamp", .brightness) == lampBefore)
    }

    /// A scene a plugin action recalls on its own bridge is held: the lights it changed, and only those, go back with
    /// stop_scene and the run the answer gives.
    @Test func aPluginActionsSceneIsUndone() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let lampBefore = value(environment, "Devices:lamp", .brightness)

        let recalled = try await client.tool("Devices_scene")
        let text = try #require(recalled["content"]?[0]?["text"]?.stringValue)
        #expect(value(environment, "Devices:bulb1", .hue)?.doubleValue == 300)
        let run = try #require(text.range(of: #"stop_scene with scene (\S+)"#, options: .regularExpression).map { String(text[$0].split(separator: " ").last ?? "") })
        let held = environment.catalog.home.lightRuns.withLockedValue { Array($0.values) }
        #expect(held.count == 1)
        #expect(held.first?.lights.map(\.located.accessory.id).sorted() == denBulbs)

        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        for bulb in denBulbs {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .hue)?.doubleValue == 10)
        }
        #expect(value(environment, "Devices:lamp", .brightness) == lampBefore)
    }

    /// What a scene changed outlives a restart: held-lights.json brings it back, and stop_scene still puts the lights
    /// back.
    @Test func heldLightsSurviveARestart() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let set = try await client.tool("run_scene", ["template": "romantic", "room": "Den"])
        let run = try #require(set["structuredContent"]?["run"]?.stringValue)
        let file = environment.directory.appendingPathComponent("held-lights.json")
        #expect(try String(contentsOf: file, encoding: .utf8).contains(run))

        // The process ends: what it held in memory is gone, the file stays.
        environment.catalog.home.lightRuns.withLockedValue { $0 = [:] }
        environment.catalog.restoreHeldLights()
        #expect(environment.catalog.home.lightRuns.withLockedValue { $0.values.contains { $0.show.id == "scene:" + run } })

        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        for bulb in denBulbs {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
        }
        #expect(await eventually { (try? String(contentsOf: file, encoding: .utf8))?.contains(run) == false })
    }

    /// After a restart, a run past its 12 hours is dropped; a light the bridge does not have yet is kept in the file,
    /// for a later start, without holding the run.
    @Test func aRestartDropsWhatExpiredAndKeepsWhatIsMissing() async throws {
        let (environment, _) = try await den()
        defer { Task { await environment.stop() } }
        let snapshot = LightSnapshot(on: .bool(false), brightness: .int(40), adaptive: false)
        let old = SavedHeldLights(id: "old", show: LightShow(name: "Old", steps: []), startedAt: Date().addingTimeInterval(-13 * 3600), by: "test",
                                  snapshots: ["Devices:bulb1#0": snapshot])
        let pending = SavedHeldLights(id: "pending", show: LightShow(name: "Pending", steps: []), startedAt: Date(), by: "test",
                                      snapshots: ["Devices:bulb1#0": snapshot, "Devices:later#0": snapshot])
        try environment.catalog.home.heldLights.update { $0 = [old, pending] }

        environment.catalog.restoreHeldLights()
        let running = environment.catalog.home.lightRuns.withLockedValue { $0 }
        #expect(Set(running.keys) == ["pending"])
        #expect(running["pending"]?.lights.map(\.key) == ["Devices:bulb1#0"])
        let saved = environment.catalog.home.heldLights.value
        #expect(saved.map(\.id) == ["pending"])
        #expect(saved.first?.snapshots.keys.sorted() == ["Devices:bulb1#0", "Devices:later#0"])
    }

    /// A scene the hub refuses changes nothing: no run is held, and the answer comes without waiting for the lights.
    @Test func aFailedPluginSceneHoldsNothing() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let started = ContinuousClock.now
        let failed = try await client.tool("Devices_scene", ["fail": true])
        #expect(failed["isError"] == true)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(environment.catalog.home.lightRuns.withLockedValue { $0.isEmpty })
    }

    /// A scene on some of another's lights takes only those: the others stay as the first set them, still to undo,
    /// and undoing both brings everything back to how it was before the first.
    @Test func aNewSceneTakesSomeOfTheLights() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let calm = try await client.tool("run_scene", ["template": "focus", "room": "Den"])
        let calmRun = try #require(calm["structuredContent"]?["run"]?.stringValue)
        let blinking = try await client.tool("run_scene", ["plan": blink(["Devices:bulb1"])])
        let blinkRun = try #require(blinking["structuredContent"]?["run"]?.stringValue)
        // bulb2 is still focus's white, and focus still holds it (and the lamp) to undo.
        #expect(value(environment, "Devices:bulb2", .colorTemperature) == .int(200))
        let held = environment.catalog.home.lightRuns.withLockedValue { $0.values.first { $0.show.id == "scene:" + calmRun } }
        #expect(held?.json["lights"]?.arrayValue?.compactMap { $0["id"]?.stringValue }.sorted() == ["Devices:bulb2", "Devices:lamp"])

        _ = try await client.tool("stop_scene", ["scene": .string(blinkRun)])
        _ = try await client.tool("stop_scene", ["scene": .string(calmRun)])
        for bulb in denBulbs {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .colorTemperature) == .int(300))
        }
    }

    /// An animated scene plays in the background until it is stopped, then every light is as it was.
    @Test func anAnimationPlaysAndPutsTheLightsBack() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let started = try await client.tool("run_scene", ["plan": blink(denBulbs)])
        let run = try #require(started["structuredContent"]?["run"]?.stringValue)
        #expect(await eventually { environment.written.filter { $0.0 == "bulb1.hue" }.count >= 2 })
        #expect(value(environment, "Devices:bulb1", .on) == .bool(true))
        #expect(environment.catalog.isPlaying(run))

        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        #expect(!environment.catalog.isPlaying(run))
        for bulb in denBulbs {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .hue)?.doubleValue == 10)
            #expect(value(environment, bulb, .saturation)?.doubleValue == 20)
        }
    }

    /// A scene started on lights another one plays on takes them over: one plays, and stopping both brings back the
    /// values from before the first.
    @Test func aNewSceneTakesTheLightsOver() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let first = try await client.tool("run_scene", ["plan": blink(denBulbs)])
        let firstRun = try #require(first["structuredContent"]?["run"]?.stringValue)
        #expect(await eventually { environment.written.contains { $0.0 == "bulb1.hue" } })
        let police = try await client.tool("run_scene", ["template": "police", "room": "Den"])
        let run = try #require(police["structuredContent"]?["run"]?.stringValue)
        #expect(environment.catalog.isPlaying(run))
        #expect(!environment.catalog.isPlaying(firstRun))

        _ = try await client.tool("stop_scene", ["scene": .string(run)])
        #expect(value(environment, "Devices:bulb1", .on) == .bool(false))
        #expect(value(environment, "Devices:bulb1", .brightness) == .int(40))
        #expect(value(environment, "Devices:bulb1", .hue)?.doubleValue == 10)
    }

    /// Every light of a step is written at the same time, and a light's values together, as the Home app writes them:
    /// four lights whose writes take 300 ms each are set in about 0.6 s (the values, then On), where one write after
    /// another took almost 5 s. What is counted is how many writes were under way at once, not the time, which a
    /// loaded machine stretches: 12 (four lights' three values) when nothing holds them up, 1 one after another.
    @Test func theLightsAreWrittenTogether() async throws {
        let (environment, client) = try await den(bulbs: 4, slow: true)
        defer { Task { await environment.stop() } }

        let lights = (1...4).map { "Devices:bulb\($0)" }
        let plan: JSONValue = ["name": "Teal", "animation": ["lights": .array(lights.map(JSONValue.string)),
                                                            "steps": [["colors": [["hue": 180, "saturation": 90, "brightness": 70]], "seconds": 1]]]]
        let set = try await client.tool("run_scene", ["plan": plan])
        #expect(set["isError"] != true)
        #expect(await eventually { lights.allSatisfy { value(environment, $0, .hue)?.doubleValue == 180 && value(environment, $0, .on) == .bool(true) } })
        // The four lights at least were written together.
        #expect(environment.mostSlowWritesAtOnce >= 4)
        for bulb in 1...4 {
            let keys = environment.written.map(\.0).filter { $0.hasPrefix("bulb\(bulb).") }
            #expect(Set(keys.dropLast()) == ["bulb\(bulb).brightness", "bulb\(bulb).saturation", "bulb\(bulb).hue"])
            #expect(keys.last == "bulb\(bulb).on")
        }
    }

    /// A light that fails its writes leaves the show; the others keep playing.
    @Test func aFailingLightLeavesTheShow() async throws {
        let (environment, client) = try await den(failing: true)
        defer { Task { await environment.stop() } }

        let started = try await client.tool("run_scene", ["plan": blink(denBulbs)])
        let run = try #require(started["structuredContent"]?["run"]?.stringValue)
        // The show goes on past the failure: a step after the first loop's end.
        #expect(await eventually { environment.written.filter { $0.0 == "bulb1.hue" }.count >= 3 })
        #expect(!environment.written.contains { $0.0.hasPrefix("bulb2") })
        #expect(environment.catalog.isPlaying(run))
        _ = try await client.tool("stop_scene", ["scene": .string(run)])
    }

    /// A template or a description needs lights: a room with lights, or ids; an unknown template says where the
    /// templates are.
    @Test func theLightsMustBeNamed() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let none = try await client.tool("run_scene", ["template": "focus"])
        #expect(none["isError"] == true)
        #expect(none["content"]?[0]?["text"]?.stringValue?.contains("Name the lights") == true)
        _ = try await client.tool("set_accessory_layout", ["accessories": [["id": "Devices:lock", "room": "Hall"]]])
        let hall = try await client.tool("run_scene", ["template": "focus", "room": "Hall"])
        #expect(hall["content"]?[0]?["text"]?.stringValue?.contains("No light there") == true)
        let unknown = try await client.tool("run_scene", ["template": "rave", "room": "Den"])
        #expect(unknown["content"]?[0]?["text"]?.stringValue?.contains("list_scene_templates") == true)
    }
}
