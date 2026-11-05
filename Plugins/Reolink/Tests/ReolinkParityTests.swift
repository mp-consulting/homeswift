import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftReolink

/// PTZ, privacy, the floodlight's colour, chimes, recording and sensitivity (the spec's addendum), against the fakes.
@Suite(.timeLimit(.minutes(1))) struct ReolinkParityTests {
    static let cameraID = "Reolink:95270000ABCDEFGH"
    static let address = "192.168.1.20"

    static func block(_ options: [String: Any] = [:]) -> [String: Any] {
        ["devices": [["host": address, "password": "secret", "cameras": ["0": options]]]]
    }

    static func camera(_ environment: ReolinkEnvironment) async -> ReolinkCamera? {
        guard await eventually({ await environment.plugin?.camera(host: address, channel: 0) != nil }) else { return nil }
        return await environment.plugin?.camera(host: address, channel: 0)
    }

    // MARK: PTZ

    /// A pan-tilt-zoom camera (`ptzType` 2) with the addendum's presets, a patrol, a guard and the zoom range.
    static func ptzAnswers(ptzType: Int = 2) -> [String: @Sendable (JSONValue?) -> JSONValue] {
        var answers = answers(adding: ["ptzType": ptzType, "ptzPreset": 1])
        answers["GetPtzPreset"] = okAnswer("GetPtzPreset", ["PtzPreset": [
            ["channel": 0, "enable": 1, "id": 1, "name": "Gate"], ["channel": 0, "enable": 0, "id": 2, "name": ""],
            ["channel": 0, "enable": 1, "id": 5, "name": "Drive"],
        ]])
        answers["GetPtzPatrol"] = okAnswer("GetPtzPatrol", ["PtzPatrol": [["channel": 0, "enable": 1, "id": 1, "name": ""], ["channel": 0, "enable": 0, "id": 2]]])
        answers["GetPtzGuard"] = okAnswer("GetPtzGuard", ["PtzGuard": ["channel": 0, "benable": 0, "timeout": 60]])
        answers["GetZoomFocus"] = okAnswer(
            "GetZoomFocus", ["ZoomFocus": ["channel": 0, "focus": ["pos": 23], "zoom": ["pos": 0]]],
            range: ["ZoomFocus": ["focus": ["pos": ["min": 0, "max": 223]], "zoom": ["pos": ["min": 0, "max": 33]]]])
        for cmd in ["PtzCtrl", "StartZoomFocus", "SetPtzGuard"] { answers[cmd] = okAnswer(cmd, ["rspCode": 200]) }
        return answers
    }

    @Test func ptzTypeDecidesTheMoves() {
        // The addendum's fixture: type 2 with ptzPreset and no supportPtzSpeed pans, tilts, zooms and takes a speed.
        let full = ReolinkPTZ.capabilities(ptzType: 2, speedAbility: nil)
        #expect(full?.pan == true && full?.tilt == true && full?.zoom == true && full?.speed == true)
        let panOnly = ReolinkPTZ.capabilities(ptzType: 7, speedAbility: nil)
        #expect(panOnly?.pan == true && panOnly?.tilt == false && panOnly?.zoom == false && panOnly?.speed == false)
        #expect(ReolinkPTZ.capabilities(ptzType: 2, speedAbility: 0)?.speed == false)
        #expect(ReolinkPTZ.capabilities(ptzType: 0, speedAbility: nil) == nil)
        #expect(panOnly?.allows("left") == true)
        #expect(panOnly?.allows("up") == false)
        #expect(panOnly?.allows("zoomIn") == false)
        // reolink-aio's direction (the addendum's recommendation): ZoomInc zooms in.
        #expect(ReolinkPTZ.moves["zoomIn"] == "ZoomInc")
        #expect(ReolinkPTZ.moves["zoomOut"] == "ZoomDec")
    }

    @Test func presetsAreTheEnabledOnes() {
        let list: JSONValue = [["channel": 0, "enable": 1, "id": 1, "name": "Gate"], ["channel": 0, "enable": 0, "id": 2, "name": ""],
                               ["channel": 0, "enable": 1, "id": 5, "name": "Drive"]]
        let presets = ReolinkPTZ.entries(list, fallback: "Preset")
        #expect(Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0.id) }) == ["Gate": 1, "Drive": 5])
        #expect(ReolinkPTZ.entries([["enable": 1, "id": 3]], fallback: "patrol").first?.name == "patrol 3")
    }

    @Test func aCameraWithoutPTZGetsNothingNew() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start(Self.block(["presetSwitches": true, "patrolSwitch": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.ptzServices.presets.isEmpty)
        #expect(camera.ptzServices.patrol == nil)
        for cmd in ["GetPtzPreset", "GetPtzPatrol", "GetPtzGuard", "GetZoomFocus"] { #expect(environment.http.count(cmd) == 0) }
        let plugin = try #require(environment.plugin)
        let list = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "ptz", user: "admin"))
        #expect(list.json["cameras"] == [])
        let move = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "ptz/move", body: ["camera": .string(Self.cameraID), "direction": "left"], user: "admin"))
        #expect(move.status == 404)
    }

    @Test func ptzThroughTheAssistantActions() async throws {
        let environment = ReolinkEnvironment(Self.ptzAnswers(), scale: 0.01)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        let plugin = try #require(environment.plugin)
        func post(_ path: String, _ body: JSONValue) async throws -> PluginWebResponse {
            try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: path, body: body, user: "admin"))
        }
        let list = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "ptz", user: "admin"))
        let entry = try #require(list.json["cameras"]?[0])
        #expect(entry["camera"] == .string(Self.cameraID))
        #expect(entry["presets"] == [["id": 1, "name": "Gate"], ["id": 5, "name": "Drive"]])
        #expect(entry["patrols"] == [["id": 1, "name": "patrol 1"]])
        #expect(entry["zoomRange"] == ["min": 0, "max": 33])
        #expect(entry["guard"] == true)

        #expect(try await post("ptz/preset", ["camera": .string(Self.cameraID), "preset": "drive"]).status == 200)
        #expect(sentItems(environment.http, "PtzCtrl").last == ["cmd": "PtzCtrl", "action": 0, "param": ["channel": 0, "op": "ToPos", "id": 5]])
        #expect(try await post("ptz/patrol", ["camera": .string(Self.cameraID), "run": true]).status == 200)
        #expect(sentItems(environment.http, "PtzCtrl").last == ["cmd": "PtzCtrl", "action": 0, "param": ["channel": 0, "op": "StartPatrol", "id": 1]])

        // A move goes on until Stop: the plugin sends it after the seconds asked.
        #expect(try await post("ptz/move", ["camera": .string(Self.cameraID), "direction": "zoomIn", "seconds": 1, "speed": 32]).status == 200)
        let moves = sentItems(environment.http, "PtzCtrl").suffix(2).map { $0["param"] }
        #expect(moves == [["channel": 0, "op": "ZoomInc", "speed": 32], ["channel": 0, "op": "Stop"]])

        // The addendum's zoom vector: 34 is above the range's 33, refused before it is sent.
        let zoom = try await post("ptz/zoom", ["camera": .string(Self.cameraID), "zoom": 34])
        #expect(zoom.status == 400)
        #expect(environment.http.count("StartZoomFocus") == 0)
        #expect(try await post("ptz/zoom", ["camera": .string(Self.cameraID), "zoom": 6]).status == 200)
        #expect(sentItems(environment.http, "StartZoomFocus") == [["cmd": "StartZoomFocus", "action": 0, "param": ["ZoomFocus": ["channel": 0, "op": "ZoomPos", "pos": 6]]]])

        #expect(try await post("ptz/guard", ["camera": .string(Self.cameraID), "action": "setHome"]).status == 200)
        #expect(sentItems(environment.http, "SetPtzGuard").last?["param"] == ["PtzGuard": ["channel": 0, "cmdStr": "setPos", "bSaveCurrentPos": 1]])
        #expect(try await post("ptz/guard", ["camera": .string(Self.cameraID), "action": "goHome"]).status == 200)
        #expect(sentItems(environment.http, "SetPtzGuard").last?["param"] == ["PtzGuard": ["channel": 0, "cmdStr": "toPos"]])
    }

    @Test func aPanOnlyCameraRefusesTiltAndZoom() async throws {
        let environment = ReolinkEnvironment(Self.ptzAnswers(ptzType: 7), scale: 0.01)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        let plugin = try #require(environment.plugin)
        let up = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "ptz/move", body: ["camera": .string(Self.cameraID), "direction": "up"], user: "admin"))
        #expect(up.status == 400)
        // Neither speed (type 7 takes none) nor the zoom's range is read.
        #expect(environment.http.count("GetZoomFocus") == 0)
        #expect(try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "ptz/move", body: ["camera": .string(Self.cameraID), "direction": "left", "speed": 10], user: "admin")).status == 200)
        #expect(sentItems(environment.http, "PtzCtrl").first?["param"] == ["channel": 0, "op": "Left"])
    }

    @Test func presetAndPatrolSwitches() async throws {
        let environment = ReolinkEnvironment(Self.ptzAnswers(), scale: 0.01)
        let running = NIOLockedValueBox(false)
        environment.prepareCamera.withLockedValue {
            $0 = { camera in
                camera.answer(64) { _, _ in
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<PtzPatrolState version=\"1.1\">\n<cruising>\(running.withLockedValue { $0 } ? 1 : 0)</cruising>\n</PtzPatrolState>\n</body>\n"
                }
            }
        }
        let host = try await environment.start(Self.block(["presetSwitches": true, "patrolSwitch": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(await eventually { await environment.plugin?.runtimes[Self.address]?.host.baichuan?.isConnected == true })
        let presets = camera.ptzServices.presets
        #expect(presets.keys.sorted() == [1, 5])
        #expect(presets[5]?.subtype == "preset5")
        #expect(presets[5]?.characteristic(.name).value.stringValue?.hasSuffix("Go to Drive") == true)
        let drive = try #require(presets[5]?.characteristic(.on))
        try await drive.writeHandler(for: .bool(true))?(.bool(true))
        drive.value = true
        #expect(sentItems(environment.http, "PtzCtrl").last?["param"] == ["channel": 0, "op": "ToPos", "id": 5])
        // Momentary: off again by itself.
        #expect(await eventually { drive.value == false })

        let patrol = try #require(camera.ptzServices.patrol?.characteristic(.on))
        running.withLockedValue { $0 = true }
        try await patrol.writeHandler(for: .bool(true))?(.bool(true))
        #expect(sentItems(environment.http, "PtzCtrl").last?["param"] == ["channel": 0, "op": "StartPatrol", "id": 1])
        // Read back over Baichuan a second later: it runs.
        #expect(await eventually { environment.camera?.commands.contains(64) == true })
        #expect(await eventually { patrol.value == true })
        // The camera stops on its own: the next read after a stop says so.
        running.withLockedValue { $0 = false }
        try await patrol.writeHandler(for: .bool(false))?(.bool(false))
        #expect(await eventually { patrol.value == false })
    }
}
