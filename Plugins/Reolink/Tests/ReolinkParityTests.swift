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

    // MARK: Privacy

    /// A camera with privacy mode: its login reply has `sleep`, 574 reads `on` and 575 sets it.
    static func privacyCamera(_ environment: ReolinkEnvironment, on: NIOLockedValueBox<Bool>) {
        environment.prepareCamera.withLockedValue {
            $0 = { camera in
                camera.state.withLockedValue { $0.deviceInfo = "<sleep>\(on.withLockedValue { $0 } ? 1 : 0)</sleep>\n" }
                camera.answer(574) { _, _ in
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<sleepState version=\"1.1\">\n<sleep>\(on.withLockedValue { $0 } ? 1 : 0)</sleep>\n</sleepState>\n</body>\n"
                }
                camera.answer(575) { _, body in
                    on.withLockedValue { $0 = body.contains("<sleep>1</sleep>") }
                    return nil
                }
            }
        }
    }

    static let privacyOff = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<status>\n<channelId>0</channelId>\n<sleep>0</sleep>\n</status>\n</body>\n"
    static let privacyOn = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<status>\n<channelId>0</channelId>\n<sleep>1</sleep>\n</status>\n</body>\n"

    @Test func privacyVectors() throws {
        // The addendum's headers (F): abilities 199 of the host, privacy read 574 and write 575 on channel 2.
        #expect(hex(Baichuan.header(command: 199, bodyLength: 0, channel: 250, counter: 6, extensionLength: 0)) == "f0 de bc 0a c7 00 00 00 00 00 00 00 fa 06 00 00 00 00 14 64 00 00 00 00")
        let ext = Baichuan.channelExtension(2).utf8.count
        #expect(hex(Baichuan.header(command: 574, bodyLength: ext, channel: 3, counter: 7, extensionLength: ext)) == "f0 de bc 0a 3e 02 00 00 68 00 00 00 03 07 00 00 00 00 14 64 68 00 00 00")
        let body = Baichuan.privacyBody(true)
        #expect(body.utf8.count == 134)
        #expect(body == "\n<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<sleepState version=\"1.1\">\n<operate>2</operate>\n<sleep>1</sleep>\n</sleepState>\n</body>")
        #expect(hex(Baichuan.header(command: 575, bodyLength: ext + body.utf8.count, channel: 3, counter: 8, extensionLength: ext)) == "f0 de bc 0a 3f 02 00 00 ee 00 00 00 03 08 00 00 00 00 14 64 68 00 00 00")
        // A reply's channel is its full message id's low byte, minus one: 0x803 is channel 2.
        #expect(BaichuanMessage.messageID(channel: 3, counter: 8) == 0x803)
        var unknown: Set<String> = []
        #expect(BaichuanEvents.parse(command: 623, xml: "<?xml version=\"1.0\" ?><body><status><channelId>1</channelId><sleep>0</sleep></status></body>", unknown: &unknown)
            == [.privacy(channel: 1, on: false)])
        #expect(BaichuanEvents.parse(command: 623, xml: "<?xml version=\"1.0\" ?><body><sleep>1</sleep></body>", unknown: &unknown) == [.privacy(channel: 0, on: true)])
    }

    @Test func privacyAndCameraActiveFollowEachOther() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let on = NIOLockedValueBox(false)
        Self.privacyCamera(environment, on: on)
        let host = try await environment.start(Self.block(["recording": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        let privacy = try #require(camera.privacyControls.privacy?.characteristic(.on))
        let active = try #require(camera.privacyControls.cameraActive)
        // It blinds the camera: MCP clients confirm before they change it.
        #expect(privacy.isSecurityControl)
        #expect(active.isSecurityControl)
        #expect(privacy.value == false)
        #expect(active.value.intValue == 1)

        // The switch on: privacy mode on (575 with the addendum's template), HomeKit's camera off.
        try await privacy.write(.bool(true))
        #expect(environment.camera?.bodies(575).last == Baichuan.privacyBody(true))
        #expect(await eventually { active.value.intValue == 0 })

        // HomeKit's camera on: privacy mode off, the switch off.
        try await active.write(.int(1))
        #expect(await eventually { environment.camera?.bodies(575).last == Baichuan.privacyBody(false) })
        #expect(await eventually { privacy.value == false })
        #expect(on.withLockedValue { $0 } == false)

        // The device turns it on itself (the Reolink app): the 623 push.
        on.withLockedValue { $0 = true }
        environment.camera?.push(Self.privacyOn, command: 623)
        #expect(await eventually { privacy.value == true && active.value.intValue == 0 })
    }

    @Test func noLoginWhilePrivate() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let on = NIOLockedValueBox(true)
        Self.privacyCamera(environment, on: on)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.camera?.commands.contains(574) == true })
        // Asked again over Baichuan (each minute, at a hundredth): never over HTTP, where a login would fail.
        #expect(await eventually { (environment.camera?.commands.filter { $0 == 574 }.count ?? 0) >= 3 })
        #expect(environment.http.logins == 0)
        #expect(environment.http.requestCount == 0)
        on.withLockedValue { $0 = false }
        environment.camera?.push(Self.privacyOff, command: 623)
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        #expect(environment.http.logins == 1)
    }

    @Test func aFailedRefreshInPrivacyModeIsNoOutage() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let on = NIOLockedValueBox(false)
        Self.privacyCamera(environment, on: on)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        let accessory = camera.accessory
        let privacy = try #require(camera.privacyControls.privacy?.characteristic(.on))
        // Privacy mode turns on, and the HTTP API off, before a push says so: the next poll fails.
        on.withLockedValue { $0 = true }
        environment.http.state.withLockedValue { $0.unreachable = true }
        #expect(await eventually { privacy.value == true })
        let requests = environment.http.state.withLockedValue { $0.requests.count }
        let host_ = try #require(await environment.plugin?.runtimes[Self.address]?.host)
        #expect(await host_.isPrivate)
        // Not an outage: no No Response, and nothing more is asked over HTTP (polls every 50 ms, refreshes every 600 ms).
        try await Task.sleep(for: .milliseconds(300))
        #expect(!accessory.isUnavailable)
        #expect(environment.http.state.withLockedValue { $0.requests.count } == requests)
        // It ends: polling resumes.
        on.withLockedValue { $0 = false }
        environment.http.state.withLockedValue { $0.unreachable = false }
        environment.camera?.push(Self.privacyOff, command: 623)
        #expect(await eventually { environment.http.state.withLockedValue { $0.requests.count } > requests })
        #expect(await eventually { privacy.value == false })
        #expect(!accessory.isUnavailable)
    }

    @Test func aCameraWithoutPrivacyModeHasNoSwitch() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start(Self.block(["recording": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.privacyControls.privacy == nil)
        #expect(camera.privacyControls.cameraActive == nil)
        #expect(environment.camera?.commands.contains(574) != true)
    }

    // MARK: Floodlight

    /// `ledCtrl`: floodlight (bits 1 and 2), on at night (bit 4), colour temperature (bit 17).
    static let ledCtrl = 0b110 | 1 << 4 | 1 << 17

    static func abilitiesXML(ledCtrl: Int) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<AbilityInfo version=\"1.1\">\n<userName>admin</userName>\n<system>\n"
            + "<item>\n<chnID>0</chnID>\n<ledCtrl>\(ledCtrl)</ledCtrl>\n<subItem>\n<chnID>0</chnID>\n<ledCtrl>0</ledCtrl>\n</subItem>\n</item>\n</system>\n</AbilityInfo>\n</body>\n"
    }

    static let floodlightTask = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<FloodlightTask version=\"1.1\">\n<channel>0</channel>\n<alarmMode>1</alarmMode>\n"
        + "<enable>1</enable>\n<brightness_cur>80</brightness_cur>\n<newColorTemperature>40</newColorTemperature>\n<duration>180</duration>\n</FloodlightTask>\n</body>\n"

    static func colourCamera(_ environment: ReolinkEnvironment, ledCtrl: Int = ledCtrl) {
        environment.prepareCamera.withLockedValue {
            $0 = { camera in
                camera.answer(199) { _, _ in abilitiesXML(ledCtrl: ledCtrl) }
                camera.answer(289) { _, _ in floodlightTask }
            }
        }
    }

    static func whiteLed(colour: Int, mode: Int = 1) -> @Sendable (JSONValue?) -> JSONValue {
        okAnswer("GetWhiteLed", ["WhiteLed": ["channel": 0, "state": 1, "bright": 80, "mode": .number(Double(mode)), "ColorTemp": .number(Double(colour))]])
    }

    @Test func colourTemperatureAndModes() throws {
        // The addendum's vectors: ColorTemp 40 is 4800 K; 4500 K is 50.
        #expect(ReolinkFloodlight.kelvin(40) == 4800)
        #expect(ReolinkFloodlight.value(kelvin: 4500) == 50)
        #expect(ReolinkFloodlight.value(kelvin: 2900) == nil)
        #expect(ReolinkFloodlight.mireds(kelvin: 4800) == 208)
        #expect(ReolinkFloodlight.offeredModes(ledCtrl: Self.ledCtrl, flSchedule: false, flKeepOn: false, autoBrightness: false) == ["off", "auto", "night"])
        // Bit 6 set: no automatic mode; bit 14 adaptive, and auto-adaptive with bit 13.
        #expect(ReolinkFloodlight.offeredModes(ledCtrl: 1 << 6 | 1 << 14, flSchedule: true, flKeepOn: false, autoBrightness: false) == ["off", "schedule", "adaptive"])
        #expect(ReolinkFloodlight.offeredModes(ledCtrl: 1 << 6 | 1 << 13 | 1 << 14, flSchedule: false, flKeepOn: false, autoBrightness: false) == ["off", "autoAdaptive", "adaptive"])
        let root = try BXParser.parse(Self.abilitiesXML(ledCtrl: 5))
        #expect(BaichuanEvents.abilities(root) == [0: ["ledCtrl": 5]])
        let changed = Baichuan.replacingText(of: "newColorTemperature", with: "50", in: Self.floodlightTask)
        #expect(changed == Self.floodlightTask.replacingOccurrences(of: "<newColorTemperature>40<", with: "<newColorTemperature>50<"))
    }

    @Test func floodlightColourGoesOverBaichuanWithAdaptiveLighting() async throws {
        var answers = cameraAnswers()
        let colour = NIOLockedValueBox(40)
        answers["GetWhiteLed"] = { param in Self.whiteLed(colour: colour.withLockedValue { $0 })(param) }
        // The echo window is 10 s at a twentieth: 500 ms; refreshes are asked for rather than waited for.
        let environment = ReolinkEnvironment(answers, scale: 0.05)
        Self.colourCamera(environment)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        let device = try #require(await environment.plugin?.runtimes[Self.address]?.host)
        let light = try #require(camera.services.floodlight)
        let temperature = try #require(light[.colorTemperature])
        // GetWhiteLed's 40: 4800 K.
        #expect(await eventually { temperature.value == .int(208) })
        let adaptive = try #require(camera.adaptiveLighting)

        // 222 mireds is 4500 K: 50, sent back in the whole task, the rest kept.
        let handler = try #require(temperature.writeHandler(for: .int(222)))
        try await handler(.int(222))
        #expect(environment.camera?.bodies(290) == [Self.floodlightTask.replacingOccurrences(of: "<newColorTemperature>40<", with: "<newColorTemperature>50<")])
        // A drag: one more 289 read and 290 write.
        await withTaskGroup(of: Void.self) { group in
            for mireds in [300, 280, 260, 240, 230] { group.addTask { try? await handler(.int(mireds)) } }
        }
        #expect(environment.camera?.bodies(290).count == 2)
        #expect(environment.camera?.bodies(289).count == 2)

        // Adaptive Lighting: its own write's echo leaves it on; a colour set in the Reolink app turns it off.
        try adaptive.activateForTesting(mireds: 300)
        #expect(await eventually { environment.camera?.bodies(290).count == 3 })
        #expect(await eventually { temperature.value == .int(300) })
        colour.withLockedValue { $0 = 89 }
        await device.refresh()
        #expect(temperature.value == .int(300))
        #expect(adaptive.isAdaptiveLightingActive)
        try await Task.sleep(for: .milliseconds(600))
        colour.withLockedValue { $0 = 0 }
        await device.refresh()
        #expect(await eventually { !adaptive.isAdaptiveLightingActive && temperature.value == .int(167) })
    }

    @Test func floodlightModeSettingIsWrittenOnceWhenItDiffers() async throws {
        var answers = cameraAnswers()
        answers["GetWhiteLed"] = Self.whiteLed(colour: 40, mode: 1)
        let environment = ReolinkEnvironment(answers, scale: 0.01)
        Self.colourCamera(environment)
        let host = try await environment.start(Self.block(["floodlightMode": "night"]))
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        #expect(await eventually { sentItems(environment.http, "SetWhiteLed").count == 1 })
        #expect(sentItems(environment.http, "SetWhiteLed").first?["param"] == ["WhiteLed": ["channel": 0, "mode": 2]])
    }

    @Test func aModeTheCameraDoesNotOfferIsNotWritten() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        Self.colourCamera(environment)
        let host = try await environment.start(Self.block(["floodlightMode": "adaptive"]))
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.http.count("SetWhiteLed") == 0)
    }

    @Test func aFloodlightWithoutColourHasNoColourTemperature() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        Self.colourCamera(environment, ledCtrl: 0b110)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.services.floodlight?[.colorTemperature] == nil)
        #expect(camera.adaptiveLighting == nil)
    }

    // MARK: Chime

    static func chimeAnswers() -> [String: @Sendable (JSONValue?) -> JSONValue] {
        var answers = answers(adding: ["supportDingDongCtrl": 1], to: cameraAnswers(model: "Reolink Video Doorbell PoE", doorbell: true))
        answers["GetDingDongList"] = okAnswer("GetDingDongList", ["DingDongList": ["pairedlist": [["deviceId": 7, "deviceName": "Hall", "netState": 1]]]])
        answers["DingDongOpt"] = okAnswer("DingDongOpt", ["rspCode": 200])
        return answers
    }

    @Test func aChimeSwitchPlaysTheTone() async throws {
        let environment = ReolinkEnvironment(Self.chimeAnswers(), scale: 0.01)
        let host = try await environment.start(Self.block(["chimeSwitch": true, "chimeTone": "loop"]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        let chime = try #require(camera.chimeServices[7]?.characteristic(.on))
        #expect(camera.chimeServices[7]?.subtype == "chime7")
        try await chime.write(.bool(true))
        // The addendum's vector: tone 3 (loop) on chime 7.
        #expect(sentItems(environment.http, "DingDongOpt") == [["cmd": "DingDongOpt", "action": 0, "param": ["DingDong": ["channel": 0, "id": 7, "option": 4, "musicId": 3]]]])
        #expect(await eventually { chime.value == false })
        // The hardwired chime (Baichuan 483) is never asked: reading it makes the chime rattle.
        #expect(environment.camera?.commands.contains(483) != true)
    }

    @Test func chimesAreOptInAndNeedTheAbility() async throws {
        // The ability but no switch asked for: the list is read, no service.
        let environment = ReolinkEnvironment(Self.chimeAnswers(), scale: 0.01)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.chimeServices.isEmpty)
        // No ability: not even read.
        let plain = ReolinkEnvironment(scale: 0.01)
        let other = try await plain.start(Self.block(["chimeSwitch": true]))
        defer { Task { await other.stop() } }
        let second = try #require(await Self.camera(plain))
        #expect(second.chimeServices.isEmpty)
        #expect(plain.http.count("GetDingDongList") == 0)
    }

    @Test func pairedChimesParse() {
        let value: JSONValue = ["DingDongList": ["pairedlist": [["deviceId": 7, "deviceName": "Hall", "netState": 1], ["deviceId": 2, "deviceName": ""]]]]
        #expect(ReolinkChime.paired(value) == [.init(id: 2, name: "Chime 2"), .init(id: 7, name: "Hall")])
    }

    // MARK: Recording

    static func recordingAnswers(scheduleEnable: NIOLockedValueBox<Int>) -> [String: @Sendable (JSONValue?) -> JSONValue] {
        var answers = cameraAnswers()
        answers["GetAbility"] = okAnswer("GetAbility", ["Ability": ["rtsp": ["permit": 0, "ver": 1], "scheduleVersion": ["permit": 0, "ver": 1], "abilityChn": [[
            "floodLight": ["permit": 0, "ver": 1],
        ]]]])
        answers["GetRecV20"] = { _ in ["cmd": "GetRecV20", "code": 0, "value": ["Rec": ["channel": 0, "scheduleEnable": .number(Double(scheduleEnable.withLockedValue { $0 }))]]] }
        answers["SetRecV20"] = { param in
            scheduleEnable.withLockedValue { $0 = param?["Rec"]?["scheduleEnable"]?.saturatingIntValue ?? $0 }
            return ["cmd": "SetRecV20", "code": 0, "value": ["rspCode": 200]]
        }
        return answers
    }

    @Test func recordingSwitchSendsTheWholeRecBack() async throws {
        let flag = NIOLockedValueBox(1)
        // A tenth: switches 30 ms apart still count as one; refreshes are asked for.
        let environment = ReolinkEnvironment(Self.recordingAnswers(scheduleEnable: flag), scale: 0.1)
        let host = try await environment.start(Self.block(["recordingSwitch": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        let recording = try #require(camera.recordingService?.characteristic(.on))
        #expect(recording.isSecurityControl)
        #expect(await eventually { recording.value == true })
        // Read with action 1 in the start-up batch.
        #expect(sentItems(environment.http, "GetRecV20").first == ["cmd": "GetRecV20", "action": 1, "param": ["channel": 0]])
        try await recording.write(.bool(false))
        // The addendum's vector.
        #expect(sentItems(environment.http, "SetRecV20") == [["cmd": "SetRecV20", "action": 0, "param": ["Rec": ["channel": 0, "scheduleEnable": 0]]]])
        #expect(recording.value == false)
        // Switched quickly: the last only.
        let handler = try #require(recording.writeHandler(for: .bool(true)))
        await withTaskGroup(of: Void.self) { group in
            for on in [true, false, true] { group.addTask { try? await handler(.bool(on)) } }
        }
        #expect(sentItems(environment.http, "SetRecV20").count == 2)
        // The device turns it on itself: the refresh shows it.
        flag.withLockedValue { $0 = 1 }
        await environment.plugin?.runtimes[Self.address]?.host.refresh()
        #expect(await eventually { recording.value == true })
    }

    @Test func recordingRules() {
        #expect(ReolinkRecording.isOn(["Rec": ["scheduleEnable": 1, "enable": 0]], v20: true, multiChannel: false) == false)
        #expect(ReolinkRecording.isOn(["Rec": ["scheduleEnable": 1, "enable": 0]], v20: true, multiChannel: true) == true)
        #expect(ReolinkRecording.isOn(["Rec": ["schedule": ["enable": 1]]], v20: false, multiChannel: false) == true)
        #expect(ReolinkRecording.isOn(["Rec": [:]], v20: true, multiChannel: false) == nil)
        // A camera's master switch turns on with its schedule; an old Rec keeps the rest of its schedule.
        #expect(ReolinkRecording.changed(["channel": 0, "scheduleEnable": 0, "enable": 0], on: true, v20: true, multiChannel: false)
            == ["channel": 0, "scheduleEnable": 1, "enable": 1])
        #expect(ReolinkRecording.changed(["channel": 0, "schedule": ["enable": 1, "table": "111"]], on: false, v20: false, multiChannel: false)
            == ["channel": 0, "schedule": ["enable": 0, "table": "111"]])
    }

    @Test func noRecordingSwitchWithoutTheReply() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let host = try await environment.start(Self.block(["recordingSwitch": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.recordingService == nil)
    }

    // MARK: Sensitivity

    @Test func sensitivitiesAreWrittenInOneBatchWhereTheyDiffer() async throws {
        #expect(ReolinkHost.sensDef(30) == 21)
        var answers = cameraAnswers()
        answers["GetMdAlarm"] = okAnswer("GetMdAlarm", ["MdAlarm": ["channel": 0, "useNewSens": 1, "newSens": ["sensDef": 10]]])
        answers["GetAiAlarm"] = { param in
            let type = param?["ai_type"]?.stringValue ?? ""
            return ["cmd": "GetAiAlarm", "code": 0, "value": ["AiAlarm": ["channel": 0, "ai_type": .string(type), "sensitivity": type == "vehicle" ? 60 : 50]]]
        }
        for cmd in ["SetMdAlarm", "SetAiAlarm"] { answers[cmd] = okAnswer(cmd, ["rspCode": 200]) }
        let environment = ReolinkEnvironment(answers, scale: 0.01)
        let host = try await environment.start(Self.block(["motionSensitivity": 30, "aiSensitivity": 60]))
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        #expect(await eventually { environment.http.count("SetMdAlarm") == 1 })
        // The addendum's vector: sensitivity 30 is sensDef 21; vehicle is already at 60, people is not.
        let writes = environment.http.state.withLockedValue { $0.requests.first { $0.cmd == "SetMdAlarm" }?.body }
        #expect(writes == [
            ["cmd": "SetMdAlarm", "action": 0, "param": ["MdAlarm": ["channel": 0, "useNewSens": 1, "newSens": ["sensDef": 21]]]],
            ["cmd": "SetAiAlarm", "action": 0, "param": ["AiAlarm": ["channel": 0, "ai_type": "people", "sensitivity": 60]]],
        ])
        // The reads were one request too.
        let reads = environment.http.state.withLockedValue { $0.requests.filter { $0.cmd == "GetMdAlarm" }.count }
        #expect(reads == 1)
    }

    @Test func noSensitivityNoRead() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = try #require(await Self.camera(environment))
        try await Task.sleep(for: .milliseconds(50))
        #expect(environment.http.count("GetMdAlarm") == 0)
        #expect(environment.http.count("GetAiAlarm") == 0)
    }

    // MARK: Cost

    /// Every new feature at once: PTZ, a chime, recording, without push (polling).
    @Test func newFeaturesAddNoRequestPerCycleAndNeverOverlap() async throws {
        let flag = NIOLockedValueBox(1)
        var answers = Self.ptzAnswers()
        for (cmd, answer) in Self.recordingAnswers(scheduleEnable: flag) where cmd.hasSuffix("RecV20") { answers[cmd] = answer }
        for (cmd, answer) in Self.chimeAnswers() where cmd.contains("DingDong") { answers[cmd] = answer }
        let base = answers["GetAbility"]
        answers["GetAbility"] = { param in
            var reply = base?(param) ?? [:]
            var ability = reply["value"]?["Ability"]?.objectValue ?? [:]
            ability["scheduleVersion"] = ["permit": 0, "ver": 1]
            var channel = ability["abilityChn"]?[0]?.objectValue ?? [:]
            channel["supportDingDongCtrl"] = ["permit": 0, "ver": 1]
            ability["abilityChn"] = [.object(channel)]
            reply = ["cmd": "GetAbility", "code": 0, "value": ["Ability": .object(ability)]]
            return reply
        }
        let environment = ReolinkEnvironment(answers, baichuanFails: true)
        let host = try await environment.start(Self.block(["presetSwitches": true, "patrolSwitch": true, "recordingSwitch": true, "chimeSwitch": true]))
        defer { Task { await host.stop() } }
        let camera = try #require(await Self.camera(environment))
        #expect(camera.recordingService != nil && !camera.chimeServices.isEmpty && !camera.ptzServices.presets.isEmpty)
        let start = environment.http.requestCount
        let events = environment.http.count("GetEvents")
        #expect(await eventually { environment.http.count("GetEvents") - events > 20 })
        let requests = environment.http.requestCount - start
        let polls = environment.http.count("GetEvents") - events
        // One POST per cycle still: the recording state rides in the refresh batch, PTZ and chimes are read once at start.
        #expect(requests <= polls + 2)
        #expect(environment.http.count("GetRecV20") >= 2)
        for cmd in ["GetPtzPreset", "GetPtzPatrol", "GetDingDongList"] { #expect(environment.http.count(cmd) == 1) }

        // Writes from everywhere at once: one request in flight at a time.
        let plugin = try #require(environment.plugin)
        let recording = try #require(camera.recordingService?.characteristic(.on))
        let chime = try #require(camera.chimeServices.values.first?.characteristic(.on))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await recording.write(.bool(false)) }
            group.addTask { try? await chime.write(.bool(true)) }
            group.addTask {
                _ = try? await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "ptz/preset", body: ["camera": .string(Self.cameraID), "preset": 1], user: "admin"))
            }
        }
        #expect(environment.http.state.withLockedValue { $0.overlapped } == false)
    }
}
