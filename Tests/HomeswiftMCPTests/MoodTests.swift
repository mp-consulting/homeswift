import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftMCP

/// A bridge with the devices plugin's lamp and lock and `bulbs` colour bulbs, the last failing every write when
/// `failing`; with `assistant`, an OpenAI-compatible provider the test answers for.
private func moodConfig(bulbs: Int = 2, failing: Bool = false, slow: Bool = false, assistant: Bool = false) -> String {
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
private func den(bulbs: Int = 2, failing: Bool = false, slow: Bool = false, model: (any HTTPTransport)? = nil) async throws -> (MCPTestEnvironment, DirectClient) {
    let environment = try MCPTestEnvironment(config: moodConfig(bulbs: bulbs, failing: failing, slow: slow, assistant: model != nil), aiTransport: model)
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

/// Two colours swapping every half second, for a minute.
private let blink: JSONValue = [
    "name": "Blink", "loop": true, "durationSeconds": 60,
    "steps": [
        ["colors": [["hue": 0, "saturation": 100, "brightness": 90], ["hue": 240, "saturation": 100, "brightness": 90]], "seconds": 0.5],
        ["colors": [["hue": 240, "saturation": 100, "brightness": 90], ["hue": 0, "saturation": 100, "brightness": 90]], "seconds": 0.5],
    ],
]

/// An OpenAI-compatible server in memory that answers every request with a mood, and keeps what it was sent.
private final class MoodModel: HTTPTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private var bodies: [String] = []
    var sent: String { lock.withLock { bodies.joined(separator: "\n") } }

    private let mood = #"{"name": "Calm sea", "steps": [{"colors": [{"hue": 200, "saturation": 60, "brightness": 35}], "seconds": 1}]}"#

    private func reply(_ request: HTTPRequest) -> Data {
        lock.withLock { bodies.append(String(decoding: request.body, as: UTF8.self)) }
        let answer: [String: Any] = [
            "model": "llama3.1", "usage": ["prompt_tokens": 120, "completion_tokens": 40],
            "choices": [["index": 0, "message": ["role": "assistant", "content": mood], "finish_reason": "stop"]],
        ]
        return try! JSONSerialization.data(withJSONObject: answer)
    }

    func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: reply(request))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let chunk: [String: Any] = ["model": "llama3.1", "choices": [["index": 0, "delta": ["content": mood], "finish_reason": "stop"]],
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
struct MoodTests {
    /// Every mood of the collection is valid, described and drawn, and the web UI names each one (so it translates them).
    @Test func theCollectionIsValidAndTranslated() throws {
        var ids: Set<String> = []
        for mood in MoodLibrary.all {
            try MoodRules.check(mood)
            let id = try #require(mood.id)
            #expect(ids.insert(id).inserted, "\(id) twice")
            #expect(["calm", "animated", "party", "signal"].contains(mood.category ?? ""))
            #expect(mood.description?.isEmpty == false)
            #expect(!MoodLibrary.swatch(mood).isEmpty)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/HomeswiftUI/Web/home.js"), encoding: .utf8)
        for id in ids { #expect(page.contains("\"\(id)\": [t("), "home.js does not name \(id)") }
    }

    @Test func plansAreChecked() throws {
        let good: JSONValue = ["name": "Test", "steps": [["colors": [["hue": 120, "saturation": 100, "brightness": 50]], "seconds": 1]]]
        #expect(try MoodRules.mood(from: good).name == "Test")
        let bad: [(JSONValue, String)] = [
            (["name": "x", "steps": [["colors": [["hue": 120]], "seconds": 0.2]]], "seconds"),
            (["name": "x", "steps": [["colors": [["hue": 400]], "seconds": 1]]], "hue"),
            (["name": "x", "steps": []], "steps"),
            (["name": "x", "steps": [["colors": [[:]], "seconds": 1]]], "at least one"),
            (["steps": [["colors": [["hue": 1]], "seconds": 1]]], "name"),
            (["name": "x", "durationSeconds": 7200, "steps": [["colors": [["hue": 1]], "seconds": 1]]], "durationSeconds"),
        ]
        for (plan, word) in bad {
            let error = #expect(throws: CatalogError.self) { try MoodRules.mood(from: plan) }
            #expect(error?.description.contains(word) == true, "\(error?.description ?? "no error") should mention \(word)")
        }
    }

    @Test func valuesFitTheCharacteristic() {
        #expect(MoodRules.hapNumber(140, for: Characteristic(.brightness, value: .int(0))) == .int(100))
        #expect(MoodRules.hapNumber(-3, for: Characteristic(.hue, value: .double(0))) == .double(0))
        #expect(MoodRules.hapNumber(37.4, for: Characteristic(.hue, value: .double(0))) == .double(37))
        #expect(MoodRules.hapNumber(90, for: Characteristic(.colorTemperature, value: .int(140))) == .int(140))
    }

    /// A calm mood sets every light of the room once (the lock is no light) and is kept to undo; a dry run writes
    /// nothing.
    @Test func aCalmMoodSetsTheRoomsLights() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let dry = try await client.tool("start_mood", ["mood": "focus", "room": "Den", "dryRun": true])
        #expect(dry["structuredContent"]?["lights"]?.arrayValue?.count == 3)
        #expect(environment.written.isEmpty)

        let result = try await client.tool("start_mood", ["mood": "Focus", "room": "den"])
        #expect(result["structuredContent"]?["ok"] == true)
        #expect(result["structuredContent"]?["run"]?["held"] == true)
        #expect(result["structuredContent"]?["run"]?["undoUntil"]?.stringValue != nil)
        #expect(value(environment, "Devices:bulb1", .colorTemperature) == .int(200))
        #expect(value(environment, "Devices:bulb2", .brightness) == .int(100))
        #expect(value(environment, "Devices:bulb1", .on) == .bool(true))
        #expect(environment.written.contains { $0.0 == "lamp.brightness" && $0.1 == .int(100) })
        #expect(!environment.written.contains { $0.0.hasPrefix("lock") || $0.0.hasPrefix("trigger") })
        let list = try await client.tool("list_moods")
        #expect(list["structuredContent"]?["running"]?.arrayValue?.count == 1)
        #expect(list["structuredContent"]?["moods"]?.arrayValue?.count == MoodLibrary.all.count)
    }

    /// stop_mood undoes a calm mood: every light as it was before, the lamp included; then nothing is left to undo.
    @Test func aCalmMoodIsUndone() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let lampBefore = value(environment, "Devices:lamp", .brightness)

        let set = try await client.tool("start_mood", ["mood": "romantic", "room": "Den"])
        let run = try #require(set["structuredContent"]?["run"]?["id"]?.stringValue)
        // The lamp takes the first colour of the spread, the bulbs the next ones.
        #expect([340, 355].contains(value(environment, "Devices:bulb1", .hue)?.doubleValue ?? 0))
        #expect(value(environment, "Devices:bulb1", .on) == .bool(true))

        let undone = try await client.tool("stop_mood", ["run": .string(run)])
        #expect(undone["structuredContent"]?["stopped"]?[0]?["held"] == true)
        for bulb in ["Devices:bulb1", "Devices:bulb2"] {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .hue)?.doubleValue == 10)
            #expect(value(environment, bulb, .saturation)?.doubleValue == 20)
        }
        #expect(value(environment, "Devices:lamp", .brightness) == lampBefore)
        let list = try await client.tool("list_moods")
        #expect(list["structuredContent"]?["running"]?.arrayValue?.isEmpty == true)
    }

    /// A scene a plugin recalls on its own bridge is held like a calm mood: the lights it changed, and only those,
    /// go back with stop_mood.
    @Test func aPluginSceneIsUndone() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let lampBefore = value(environment, "Devices:lamp", .brightness)

        let recalled = try await client.tool("Devices_scene")
        #expect(recalled["isError"] != true)
        #expect(recalled["content"]?[0]?["text"]?.stringValue?.contains("stop_mood with run") == true)
        #expect(value(environment, "Devices:bulb1", .hue)?.doubleValue == 300)
        let held = try #require(try await client.tool("list_moods")["structuredContent"]?["running"]?[0])
        #expect(held["held"] == true)
        #expect(held["name"]?.stringValue?.hasSuffix("Recall a scene") == true)
        #expect(held["lights"]?.arrayValue?.compactMap { $0["id"]?.stringValue }.sorted() == ["Devices:bulb1", "Devices:bulb2"])

        _ = try await client.tool("stop_mood", ["run": try #require(held["id"])])
        for bulb in ["Devices:bulb1", "Devices:bulb2"] {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .hue)?.doubleValue == 10)
        }
        #expect(value(environment, "Devices:lamp", .brightness) == lampBefore)
    }

    /// A held mood outlives a restart: its run and what the lights were come back from held-moods.json, and
    /// stop_mood still puts the lights back.
    @Test func aHeldMoodSurvivesARestart() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let set = try await client.tool("start_mood", ["mood": "romantic", "room": "Den"])
        let run = try #require(set["structuredContent"]?["run"]?["id"]?.stringValue)
        let file = environment.directory.appendingPathComponent("held-moods.json")
        #expect(try String(contentsOf: file, encoding: .utf8).contains(run))

        // The process ends: what it held in memory is gone, the file stays.
        environment.catalog.home.runningMoods.withLockedValue { $0 = [:] }
        environment.catalog.restoreHeldMoods()
        let held = try await client.tool("list_moods")["structuredContent"]?["running"]?.arrayValue ?? []
        #expect(held.map { $0["id"]?.stringValue } == [run])
        #expect(held.first?["held"] == true)

        _ = try await client.tool("stop_mood", ["run": .string(run)])
        for bulb in ["Devices:bulb1", "Devices:bulb2"] {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
        }
        #expect(await eventually { (try? String(contentsOf: file, encoding: .utf8))?.contains(run) == false })
    }

    /// A scene the hub refuses changes nothing: no run is held, and the answer comes without waiting for the lights.
    @Test func aFailedPluginSceneHoldsNothing() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }
        let started = ContinuousClock.now
        let failed = try await client.tool("Devices_scene", ["fail": true])
        #expect(failed["isError"] == true)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(try await client.tool("list_moods")["structuredContent"]?["running"]?.arrayValue?.isEmpty == true)
    }

    /// A mood on some of a calm mood's lights takes only those: the others stay as the calm mood set them, still to
    /// undo, and undoing both brings everything back to how it was before the first.
    @Test func aNewMoodTakesSomeOfACalmMoodsLights() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let calm = try await client.tool("start_mood", ["mood": "focus", "room": "Den"])
        let calmRun = try #require(calm["structuredContent"]?["run"]?["id"]?.stringValue)
        _ = try await client.tool("start_mood", ["plan": blink, "ids": ["Devices:bulb1"]])
        // bulb2 is still focus's white, and focus still holds it (and the lamp) to undo.
        #expect(value(environment, "Devices:bulb2", .colorTemperature) == .int(200))
        let list = try await client.tool("list_moods")
        let held = list["structuredContent"]?["running"]?.arrayValue?.first { $0["id"]?.stringValue == calmRun }
        #expect(held?["lights"]?.arrayValue?.compactMap { $0["id"]?.stringValue }.sorted() == ["Devices:bulb2", "Devices:lamp"])

        _ = try await client.tool("stop_mood")
        for bulb in ["Devices:bulb1", "Devices:bulb2"] {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .colorTemperature) == .int(300))
        }
    }

    /// An animated mood plays in the background until it is stopped, then every light is as it was.
    @Test func anAnimatedMoodPlaysAndPutsTheLightsBack() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let started = try await client.tool("start_mood", ["plan": blink, "room": "Den"])
        let run = try #require(started["structuredContent"]?["run"]?["id"]?.stringValue)
        #expect(started["structuredContent"]?["run"]?["room"] == "Den")
        #expect(await eventually { environment.written.filter { $0.0 == "bulb1.hue" }.count >= 2 })
        #expect(value(environment, "Devices:bulb1", .on) == .bool(true))
        let list = try await client.tool("list_moods")
        #expect(list["structuredContent"]?["running"]?[0]?["id"]?.stringValue == run)

        let stopped = try await client.tool("stop_mood", ["run": .string(run)])
        #expect(stopped["structuredContent"]?["stopped"]?.arrayValue?.count == 1)
        for bulb in ["Devices:bulb1", "Devices:bulb2"] {
            #expect(value(environment, bulb, .on) == .bool(false))
            #expect(value(environment, bulb, .brightness) == .int(40))
            #expect(value(environment, bulb, .hue)?.doubleValue == 10)
            #expect(value(environment, bulb, .saturation)?.doubleValue == 20)
        }
        let after = try await client.tool("list_moods")
        #expect(after["structuredContent"]?["running"]?.arrayValue?.isEmpty == true)
    }

    /// A mood started on lights another one plays on takes them over: one plays, and stopping it brings back the
    /// values from before the first.
    @Test func aNewMoodTakesTheLightsOver() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        _ = try await client.tool("start_mood", ["plan": blink, "room": "Den"])
        #expect(await eventually { environment.written.contains { $0.0 == "bulb1.hue" } })
        let police = try await client.tool("start_mood", ["mood": "police", "room": "Den", "durationSeconds": 60])
        let run = try #require(police["structuredContent"]?["run"]?["id"]?.stringValue)
        let list = try await client.tool("list_moods")
        #expect(list["structuredContent"]?["running"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [run])

        _ = try await client.tool("stop_mood")
        #expect(value(environment, "Devices:bulb1", .on) == .bool(false))
        #expect(value(environment, "Devices:bulb1", .brightness) == .int(40))
        #expect(value(environment, "Devices:bulb1", .hue)?.doubleValue == 10)
    }

    /// Every light of a step is written at the same time, and a light's values together, as the Home app writes them:
    /// four lights whose writes take 300 ms each are set in about 0.6 s (the values, then On), where one write after
    /// another took almost 5 s.
    @Test func theLightsAreWrittenTogether() async throws {
        let (environment, client) = try await den(bulbs: 4, slow: true)
        defer { Task { await environment.stop() } }

        let plan: JSONValue = ["name": "Teal", "steps": [["colors": [["hue": 180, "saturation": 90, "brightness": 70]], "seconds": 1]]]
        let start = ContinuousClock.now
        let set = try await client.tool("start_mood", ["plan": plan, "room": "Den"])
        #expect(set["isError"] != true)
        #expect(ContinuousClock.now - start < .seconds(2))
        for bulb in 1...4 {
            let keys = environment.written.map(\.0).filter { $0.hasPrefix("bulb\(bulb).") }
            #expect(Set(keys.dropLast()) == ["bulb\(bulb).brightness", "bulb\(bulb).saturation", "bulb\(bulb).hue"])
            #expect(keys.last == "bulb\(bulb).on")
            #expect(value(environment, "Devices:bulb\(bulb)", .hue)?.doubleValue == 180)
        }
        _ = try await client.tool("stop_mood")
    }

    /// A light that fails its writes leaves the show; the others keep playing.
    @Test func aFailingLightLeavesTheShow() async throws {
        let (environment, client) = try await den(failing: true)
        defer { Task { await environment.stop() } }

        _ = try await client.tool("start_mood", ["plan": blink, "room": "Den"])
        #expect(await eventually { environment.written.filter { $0.0 == "bulb1.hue" }.count >= 6 })
        #expect(!environment.written.contains { $0.0.hasPrefix("bulb2") })
        let list = try await client.tool("list_moods")
        #expect(list["structuredContent"]?["running"]?.arrayValue?.count == 1)
        _ = try await client.tool("stop_mood")
    }

    @Test func theLightsMustBeNamed() async throws {
        let (environment, client) = try await den()
        defer { Task { await environment.stop() } }

        let none = try await client.tool("start_mood", ["mood": "focus"])
        #expect(none["isError"] == true)
        #expect(none["content"]?[0]?["text"]?.stringValue?.contains("Name the lights") == true)
        _ = try await client.tool("set_accessory_layout", ["accessories": [["id": "Devices:lock", "room": "Hall"]]])
        let hall = try await client.tool("start_mood", ["mood": "focus", "room": "Hall"])
        #expect(hall["content"]?[0]?["text"]?.stringValue?.contains("No light there") == true)
        let unknown = try await client.tool("start_mood", ["mood": "rave", "room": "Den"])
        #expect(unknown["content"]?[0]?["text"]?.stringValue?.contains("Moods: candlelight") == true)
    }

    /// The Assistant writes a mood from a description; it learns how many lights there are and what they take, never
    /// their names.
    @Test func theAssistantWritesAMoodFromADescription() async throws {
        let model = MoodModel()
        let (environment, client) = try await den(model: model)
        defer { Task { await environment.stop() } }

        let result = try await client.tool("start_mood", ["description": "a calm sea at night", "room": "Den"])
        #expect(result["isError"] != true)
        #expect(result["structuredContent"]?["designed"] == true)
        #expect(result["structuredContent"]?["mood"]?["name"] == "Calm sea")
        #expect(value(environment, "Devices:bulb1", .hue)?.doubleValue == 200)
        #expect(model.sent.contains("a calm sea at night"))
        #expect(!model.sent.contains("Bulb") && !model.sent.contains("Desk Lamp") && !model.sent.contains("Den"))
    }
}
