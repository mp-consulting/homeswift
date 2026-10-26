import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftPhilipsHue

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A Hue Bridge in memory: pairing (refused until `pressLinkButton`), every resource, and the PUTs it was sent.
final class FakeBridge: HTTPSending, @unchecked Sendable {
    struct Sent: Equatable {
        var method: String
        var path: String
        var body: JSONValue
    }

    private let state = NIOLockedValueBox<(linkButton: Bool, key: String, resources: [JSONValue], sent: [Sent], refuseKey: Bool, bridgeID: String)>(
        (false, "app-key-1", FakeBridge.resources, [], false, "C42996FFFEC76C08"))

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    var puts: [Sent] { sent.filter { $0.method == "PUT" } }
    func pressLinkButton() { state.withLockedValue { $0.linkButton = true } }
    func refuseKey() { state.withLockedValue { $0.refuseKey = true } }
    /// Answers `/api/config` as another bridge would.
    func answer(asBridge id: String) { state.withLockedValue { $0.bridgeID = id } }
    /// Changes a resource as the Hue app would.
    func change(_ id: String, _ edit: @Sendable (inout [String: JSONValue]) -> Void) {
        state.withLockedValue { state in
            for index in state.resources.indices where state.resources[index]["id"]?.stringValue == id {
                var object = state.resources[index].objectValue ?? [:]
                edit(&object)
                state.resources[index] = .object(object)
            }
        }
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let body = request.body.flatMap { try? JSONValue(data: $0) } ?? .null
        let snapshot = state.withLockedValue { state in
            state.sent.append(Sent(method: request.method, path: path, body: body))
            return state
        }
        func json(_ value: JSONValue, status: Int = 200) -> HomeswiftNetwork.HTTPResponse { HomeswiftNetwork.HTTPResponse(status: status, body: value.encoded(), certificateFingerprint: "aa:bb") }
        switch (request.method, path) {
        case ("POST", "/api"):
            guard snapshot.linkButton else { return json([["error": ["type": 101, "address": "", "description": "link button not pressed"]]]) }
            return json([["success": ["username": .string(snapshot.key), "clientkey": "secret"]]])
        case ("GET", "/api/config"):
            return json(["bridgeid": .string(snapshot.bridgeID), "name": "Hue Bridge"])
        default:
            guard request.header("hue-application-key") == snapshot.key, !snapshot.refuseKey else { return json(["errors": [["description": "unauthorized user"]]], status: 403) }
        }
        if request.method == "GET", path == "/clip/v2/resource" { return json(["errors": [], "data": .array(snapshot.resources)]) }
        if request.method == "PUT", path.hasPrefix("/clip/v2/resource/") {
            let parts = path.split(separator: "/")
            return json(["errors": [], "data": [["rid": .string(String(parts.last ?? "")), "rtype": .string(String(parts[parts.count - 2]))]]])
        }
        return json(["errors": [["description": "not found"]]], status: 404)
    }

    /// A colour light with effects and a gradient, a white-only light, a room with two scenes and a smart scene.
    static let resources: [JSONValue] = [
        ["id": "bridge-1", "type": "bridge", "bridge_id": "c42996fffec76c08"],
        ["id": "dev-1", "type": "device", "metadata": ["name": "Lightstrip"],
         "product_data": ["model_id": "LCX004", "manufacturer_name": "Signify Netherlands B.V.", "product_name": "Hue gradient lightstrip", "software_version": "1.104.2"],
         "services": [["rid": "light-1", "rtype": "light"]]],
        ["id": "dev-2", "type": "device", "metadata": ["name": "Desk"],
         "product_data": ["model_id": "LTA001", "manufacturer_name": "Signify Netherlands B.V.", "product_name": "Hue white ambiance", "software_version": "1.0"],
         "services": [["rid": "light-2", "rtype": "light"]]],
        ["id": "light-1", "type": "light", "owner": ["rid": "dev-1", "rtype": "device"], "on": ["on": true],
         "dimming": ["brightness": 50.0, "min_dim_level": 0.2],
         "color_temperature": ["mirek": .null, "mirek_valid": false, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 500]],
         "color": ["xy": ["x": 0.6915, "y": 0.3083], "gamut_type": "C",
                   "gamut": ["red": ["x": 0.6915, "y": 0.3083], "green": ["x": 0.17, "y": 0.7], "blue": ["x": 0.1532, "y": 0.0475]]],
         "effects_v2": ["action": ["effect_values": ["no_effect", "candle", "fire"]], "status": ["effect": "no_effect"]],
         "signaling": ["signal_values": ["no_signal", "on_off", "on_off_color", "alternating"]],
         "gradient": ["points_capable": 5, "points": [["color": ["xy": ["x": 0.6915, "y": 0.3083]]], ["color": ["xy": ["x": 0.17, "y": 0.7]]]]]],
        ["id": "light-2", "type": "light", "owner": ["rid": "dev-2", "rtype": "device"], "on": ["on": false],
         "dimming": ["brightness": 80.0], "color_temperature": ["mirek": 366, "mirek_valid": true, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 454]]],
        ["id": "zc-2", "type": "zigbee_connectivity", "owner": ["rid": "dev-2", "rtype": "device"], "status": "connected"],
        ["id": "room-1", "type": "room", "metadata": ["name": "Living room"], "children": [["rid": "dev-1", "rtype": "device"]],
         "services": [["rid": "group-1", "rtype": "grouped_light"]]],
        ["id": "group-1", "type": "grouped_light", "on": ["on": true], "dimming": ["brightness": 60.0]],
        ["id": "zone-1", "type": "zone", "metadata": ["name": "Upstairs"], "children": [["rid": "light-2", "rtype": "light"]],
         "services": [["rid": "group-2", "rtype": "grouped_light"]]],
        ["id": "group-2", "type": "grouped_light", "on": ["on": false], "dimming": ["brightness": 0.0]],
        ["id": "scene-1", "type": "scene", "metadata": ["name": "Savanna sunset"], "group": ["rid": "room-1", "rtype": "room"],
         "palette": ["color": [["color": ["xy": ["x": 0.6, "y": 0.35]], "dimming": ["brightness": 80]]]], "status": ["active": "static"]],
        ["id": "scene-2", "type": "scene", "metadata": ["name": "Concentrate"], "group": ["rid": "room-1", "rtype": "room"],
         "actions": [["target": ["rid": "light-1", "rtype": "light"], "action": ["color_temperature": ["mirek": 233]]]], "status": ["active": "inactive"]],
        ["id": "smart-1", "type": "smart_scene", "metadata": ["name": "Natural light"], "group": ["rid": "room-1", "rtype": "room"], "state": "inactive"],
    ]
}

/// A host with one PhilipsHue block whose plugin talks to `bridge`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-PhilipsHue-tests-\(UUID().uuidString)")
    let bridge = FakeBridge()
    private let plugins = NIOLockedValueBox<[PhilipsHuePlugin]>([])

    var plugin: PhilipsHuePlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = ["host": "192.0.2.10"], paired: Bool = true) async throws -> PluginHost {
        if paired { bridge.pressLinkButton() }
        var registry = PluginRegistry()
        let bridge = bridge
        registry.register(platform: PhilipsHuePlugin.platform, name: PhilipsHuePlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(PhilipsHuePlugin.Configuration.self, from: json)
            let dependencies = PhilipsHuePlugin.Dependencies(transport: { _ in bridge }, discover: { ["192.0.2.10"] })
            let plugin = PhilipsHuePlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: PhilipsHuePlugin.platform, name: PhilipsHuePlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)), .serialized)
struct PhilipsHueTests {
    let environment = TestEnvironment()
    let stripID = PhilipsHuePlugin.accessoryID(lightID: "light-1")
    let deskID = PhilipsHuePlugin.accessoryID(lightID: "light-2")
    let scenesID = PhilipsHuePlugin.sceneAccessoryID(groupID: "room-1")

    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
        return try #require(host.mainBridge.server.accessories.first { $0.id == id })
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(PhilipsHuePlugin.Configuration.self, from: Data(#"{"platform":"PhilipsHue"}"#.utf8))
        #expect(configuration.host == nil)
        #expect(configuration.transitionMs == nil)
    }

    /// The plugin asks for a key until the link button is pressed, and keeps it in its own file, not config.json.
    @Test func pairsWhenTheLinkButtonIsPressed() async throws {
        let host = try await environment.start(paired: false)
        #expect(await eventually { environment.bridge.sent.contains { $0.method == "POST" && $0.path == "/api" } })
        #expect(await environment.plugin?.storedBridge.applicationKey == nil)
        environment.bridge.pressLinkButton()
        let pairing = try #require(environment.bridge.sent.first { $0.path == "/api" })
        #expect(pairing.body["generateclientkey"] == true)
        #expect(pairing.body["devicetype"]?.stringValue?.hasPrefix("homeswift#") == true)
        let directory = environment.directory
        #expect(await eventually(timeout: .seconds(10)) {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            guard let file = files.first(where: { $0.lastPathComponent == "bridge.json" }) else { return false }
            return (try? String(contentsOf: file, encoding: .utf8))?.contains("app-key-1") == true
        })
        _ = try await accessory(host, stripID)
        await host.stop()
    }

    /// At a new address the key goes only to the same bridge: another one there loses it, and pairing starts over.
    @Test func aMovedBridgeKeepsItsKeyOnlyIfItIsTheSame() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, stripID)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.storedBridge.bridgeID != nil })
        await plugin.use(host: "192.0.2.11")
        #expect(await eventually { environment.bridge.sent.contains { $0.path == "/api/config" } })
        let checked = environment.bridge.sent.count
        #expect(await eventually { environment.bridge.sent.dropFirst(checked).contains { $0.path == "/clip/v2/resource" } })
        #expect(await plugin.storedBridge.applicationKey == "app-key-1")

        environment.bridge.answer(asBridge: "001788FFFE000001")
        await plugin.use(host: "192.0.2.12")
        #expect(await eventually { await plugin.storedBridge.applicationKey == nil })
        let refused = environment.bridge.sent.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(!environment.bridge.sent.dropFirst(refused).contains { $0.path == "/clip/v2/resource" })
        await host.stop()
    }

    @Test func lightsAndScenesBecomeAccessories() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "flashSwitch": true, "gradientPoints": true])
        let strip = try await accessory(host, stripID)
        #expect(strip.information.characteristic(.name).value == .string("Lightstrip"))
        #expect(strip.information.characteristic(.model).value == .string("LCX004"))
        let bulb = try #require(strip.service(.lightbulb, subtype: nil))
        #expect(bulb.isPrimary)
        #expect(bulb[.hue] != nil && bulb[.saturation] != nil && bulb[.brightness] != nil)
        #expect(bulb[.brightness]?.value == .int(50))
        // Gamut C's red corner, which is a little orange of HomeKit's red.
        #expect((5...14).contains(bulb[.hue]?.value.doubleValue ?? -1))
        #expect(strip.service(.switch, subtype: "effect:candle") != nil)
        #expect(strip.service(.switch, subtype: "effect:fire") != nil)
        #expect(strip.service(.switch, subtype: "effect:no_effect") == nil)
        #expect(strip.service(.switch, subtype: "flash") != nil)
        #expect(strip.service(.lightbulb, subtype: "point:4") != nil)

        let desk = try await accessory(host, deskID)
        let white = try #require(desk.service(.lightbulb))
        #expect(white[.hue] == nil)
        #expect(white[.colorTemperature]?.value == .int(366))
        #expect(white[.colorTemperature]?.type.maxValue == 454)

        let scenes = try await accessory(host, scenesID)
        #expect(scenes.information.characteristic(.name).value == .string("Living room Scenes"))
        #expect(scenes.service(.switch, subtype: "scene:scene-1")?[.on]?.value == .bool(true))
        #expect(scenes.service(.switch, subtype: "scene:scene-2")?[.on]?.value == .bool(false))
        #expect(scenes.service(.switch, subtype: "scene:smart-1") != nil)
        // Without roomLights, no room lightbulb, and a zone without scenes has no accessory.
        #expect(scenes.service(.lightbulb) == nil)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == PhilipsHuePlugin.sceneAccessoryID(groupID: "zone-1") })
        await host.stop()
    }

    /// With roomLights, a room's accessory leads with a lightbulb for its lights together: on and brightness go in one
    /// command to its grouped_light, as the Hue app's room controls; a zone without scenes gets an accessory for it.
    @Test func roomLightsDriveARoomAtOnce() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "roomLights": true])
        let room = try await accessory(host, scenesID)
        #expect(room.information.characteristic(.name).value == .string("Living room"))
        let bulb = try #require(room.service(.lightbulb, subtype: "room"))
        #expect(bulb.isPrimary)
        #expect(room.service(.switch, subtype: "scene:scene-1")?.isPrimary == false)
        #expect(bulb[.on]?.value == .bool(true))
        #expect(bulb[.brightness]?.value == .int(60))
        let zone = try await accessory(host, PhilipsHuePlugin.sceneAccessoryID(groupID: "zone-1"))
        #expect(zone.services.filter { $0.type == .switch }.isEmpty)
        #expect(zone.service(.lightbulb, subtype: "room")?[.on]?.value == .bool(false))

        async let on: Void = bulb[.on]!.write(.bool(true))
        async let level: Void = bulb[.brightness]!.write(.int(40))
        _ = try await (on, level)
        #expect(environment.bridge.puts.filter { $0.path.hasSuffix("/grouped_light/group-1") }
            == [.init(method: "PUT", path: "/clip/v2/resource/grouped_light/group-1", body: ["on": ["on": true], "dimming": ["brightness": 40], "dynamics": ["duration": 100]])])
        try await bulb[.on]!.write(.bool(false))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/grouped_light/group-1", body: ["on": ["on": false]]))

        // The bridge's own changes reach it, once a command has settled.
        environment.bridge.change("group-2") { $0["on"] = ["on": true]; $0["dimming"] = ["brightness": 25.0] }
        await environment.plugin?.refresh()
        #expect(zone.service(.lightbulb, subtype: "room")?[.brightness]?.value == .int(25))
        await host.stop()
    }

    /// Brightness, hue and saturation written together go in one PUT, with the transition.
    @Test func aChangeIsOneCommand() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "transitionMs": 0])
        let bulb = try #require(try await accessory(host, stripID).service(.lightbulb))
        async let brightness: Void = bulb[.brightness]!.write(.int(70))
        async let saturation: Void = bulb[.saturation]!.write(.double(100))
        async let hue: Void = bulb[.hue]!.write(.double(240))
        _ = try await (brightness, saturation, hue)
        let puts = environment.bridge.puts.filter { $0.path == "/clip/v2/resource/light/light-1" }
        #expect(puts.count == 1)
        let body = try #require(puts.first?.body)
        #expect(body["dimming"]?["brightness"] == 70)
        #expect(body["dynamics"]?["duration"] == 0)
        let x = try #require(body["color"]?["xy"]?["x"]?.doubleValue), y = try #require(body["color"]?["xy"]?["y"]?.doubleValue)
        // Blue, inside gamut C.
        #expect(abs(x - 0.1532) < 0.02 && abs(y - 0.0475) < 0.02)
        // The poll that follows shows the light at the colour it was sent, which HomeKit keeps as it asked for.
        try await Task.sleep(for: .milliseconds(10))
        environment.bridge.change("light-1") { $0["color"] = ["xy": ["x": .number(x), "y": .number(y)]] }
        try await Task.sleep(for: PhilipsHuePlugin.settleTime + .milliseconds(100))
        await environment.plugin?.refresh()
        #expect(bulb[.hue]?.value == .double(240))
        #expect(bulb[.saturation]?.value == .double(100))
        await host.stop()
    }

    @Test func scenesEffectsAndFlash() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "flashSwitch": true, "dynamicScenes": true])
        let scenes = try await accessory(host, scenesID)
        try await scenes.service(.switch, subtype: "scene:scene-2")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/scene/scene-2", body: ["recall": ["action": "dynamic_palette", "duration": 100]]))
        try await scenes.service(.switch, subtype: "scene:scene-1")![.on]!.write(.bool(false))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/grouped_light/group-1", body: ["on": ["on": false]]))
        try await scenes.service(.switch, subtype: "scene:smart-1")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/smart_scene/smart-1", body: ["recall": ["action": "activate"]]))

        let strip = try await accessory(host, stripID)
        try await strip.service(.switch, subtype: "effect:candle")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last?.body == ["effects_v2": ["action": ["effect": "candle"]]])
        try await strip.service(.switch, subtype: "flash")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last?.body == ["signaling": ["signal": "on_off", "duration": 5000]])
        await host.stop()
    }

    @Test func changesOnTheBridgeReachHomeKit() async throws {
        let host = try await environment.start()
        let desk = try await accessory(host, deskID)
        environment.bridge.change("light-2") { $0["on"] = ["on": true]; $0["dimming"] = ["brightness": 25.0] }
        environment.bridge.change("scene-2") { $0["status"] = ["active": "static"] }
        await environment.plugin?.refresh()
        #expect(desk.service(.lightbulb)?[.on]?.value == .bool(true))
        #expect(desk.service(.lightbulb)?[.brightness]?.value == .int(25))
        let scenes = try await accessory(host, scenesID)
        #expect(scenes.service(.switch, subtype: "scene:scene-2")?[.on]?.value == .bool(true))
        await host.stop()
    }

    /// A refused key shows No Response and is forgotten, so the page offers to pair again.
    @Test func aRefusedKeyShowsNoResponse() async throws {
        let host = try await environment.start()
        let desk = try await accessory(host, deskID)
        environment.bridge.refuseKey()
        await environment.plugin?.refresh()
        #expect(desk.isUnavailable)
        #expect(await environment.plugin?.storedBridge.applicationKey == nil)
        await host.stop()
    }

    @Test func excludedLightsAndScenesStayOut() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "excludeLights": ["desk"], "excludeScenes": ["Living room/Concentrate"]])
        let scenes = try await accessory(host, scenesID)
        #expect(scenes.service(.switch, subtype: "scene:scene-2") == nil)
        #expect(scenes.service(.switch, subtype: "scene:scene-1") != nil)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == deskID })
        await host.stop()
    }

    /// A scene with a transition of its own is recalled with it, from the page and from the Home app; the others keep
    /// `transitionMs`.
    @Test func aSceneTakesItsOwnTransition() async throws {
        let host = try await environment.start(settings: [
            "host": "192.0.2.10", "transitionMs": 400, "sceneTransitions": [["scene": "living room/Concentrate", "transitionMs": 3000]],
        ])
        let scenes = try await accessory(host, scenesID)
        try await scenes.service(.switch, subtype: "scene:scene-2")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/scene/scene-2", body: ["recall": ["action": "active", "duration": 3000]]))
        try await scenes.service(.switch, subtype: "scene:scene-1")![.on]!.write(.bool(true))
        #expect(environment.bridge.puts.last?.body == ["recall": ["action": "active", "duration": 400]])
        let plugin = try #require(environment.plugin)
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "recall", body: ["id": "scene-2"], user: "admin"))
        #expect(environment.bridge.puts.last?.body == ["recall": ["action": "active", "duration": 3000]])
        let list = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scenes", user: "admin"))
        let room = try #require(list.json["groups"]?[0]?["scenes"]?.arrayValue)
        #expect(room.first { $0["id"] == "scene-2" }?["transitionMs"] == 3000)
        #expect(room.first { $0["id"] == "scene-1" }?["transitionMs"] == .null)
        await host.stop()
    }

    /// Whites set as xy (Hue's standard scenes on colour lights) are whites; reds and oranges below 1,600 K, and colours
    /// off the line of whites, are not.
    @Test func whitesAreToldFromColours() {
        let whites = [(0.4575, 0.4099), (0.5019, 0.4152), (0.3690, 0.3719), (0.3143, 0.3301), (0.561, 0.4042), (0.5268, 0.4133)]
        let colours = [(0.6, 0.35), (0.69, 0.31), (0.52, 0.44), (0.42, 0.27), (0.38, 0.31), (0.30, 0.25), (0.20, 0.35), (0.25, 0.27)]
        for (x, y) in whites { #expect(HueColor.isWhite(HueXY(x: x, y: y)), "(\(x), \(y)) is a white") }
        for (x, y) in colours { #expect(!HueColor.isWhite(HueXY(x: x, y: y)), "(\(x), \(y)) is a colour") }
        let bright = HueSnapshot.scene(["metadata": ["name": "Bright"], "actions": [["action": ["color": ["xy": ["x": 0.4575, "y": 0.4099]]]]]], id: "s", group: "g")
        #expect(!bright.colourful)
    }

    /// The bridge keeps a scene active after its room is switched off: the plugin sees it off, so a tap recalls it.
    @Test func aSceneIsOffWithItsRoom() {
        let resources: [JSONValue] = [
            ["id": "room-1", "type": "room", "metadata": ["name": "Bedroom"], "services": [["rid": "grouped-1", "rtype": "grouped_light"]]],
            ["id": "grouped-1", "type": "grouped_light", "on": ["on": false]],
            ["id": "scene-1", "type": "scene", "metadata": ["name": "Tokyo"], "group": ["rid": "room-1", "rtype": "room"], "status": ["active": "dynamic_palette"]],
        ]
        let off = HueSnapshot(resources: resources)
        #expect(off.scenes.first?.active == false)
        #expect(off.scenes.first?.playing == false)
        var on = resources
        on[1] = ["id": "grouped-1", "type": "grouped_light", "on": ["on": true]]
        #expect(HueSnapshot(resources: on).scenes.first?.playing == true)
    }

    /// A scene the bridge plays (`dynamic_palette`) is active and playing; a still one only active.
    @Test func aPlayingSceneSaysSo() {
        let playing = HueSnapshot.scene(["metadata": ["name": "Tropical twilight"], "status": ["active": "dynamic_palette"]], id: "s", group: "g")
        #expect(playing.active && playing.playing)
        let still = HueSnapshot.scene(["metadata": ["name": "Read"], "status": ["active": "static"]], id: "s", group: "g")
        #expect(still.active && !still.playing)
        let autoplay = HueSnapshot.scene(["metadata": ["name": "Arctic aurora"], "auto_dynamic": true], id: "s", group: "g")
        #expect(autoplay.autoplay && !still.autoplay)
    }

    @Test func coloursConvert() {
        let red = HueColor.xy(hue: 0, saturation: 100, gamut: .c)
        #expect(abs(red.x - 0.692) < 0.01 && abs(red.y - 0.308) < 0.01)
        // Back, the gamut has moved it: pure red is about 9° on gamut C, blue about 253°.
        let back = HueColor.hueSaturation(red, gamut: .c)
        #expect((5...14).contains(back.hue))
        #expect(back.saturation > 95)
        let blue = HueColor.hueSaturation(HueColor.xy(hue: 240, saturation: 100), gamut: .c)
        #expect((240...260).contains(blue.hue))
        // A colour inside the gamut comes back as it went.
        let orange = HueColor.hueSaturation(HueColor.xy(hue: 30, saturation: 60), gamut: .c)
        #expect(abs(orange.hue - 30) < 2 && abs(orange.saturation - 60) < 3)
        let white = HueColor.xy(hue: 0, saturation: 0)
        #expect(abs(white.x - 0.3227) < 0.01 && abs(white.y - 0.329) < 0.01)
        // Outside the triangle comes back on its edge.
        let outside = HueColor.clamp(HueXY(x: 0.8, y: 0.2), to: .c)
        #expect(HueColor.contains(outside, .c) || HueColor.distance(outside, HueColor.closest(outside, HueGamut.c.red, HueGamut.c.blue)) < 1e-9)
        #expect(HueDiscovery.cloudHosts(Data(#"[{"id":"c42996fffec76c08","internalipaddress":"192.168.2.243","port":443}]"#.utf8)) == ["192.168.2.243"])
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func webFilesAreCurrent() throws {
        let directory = Self.root.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == PhilipsHuePlugin.webFiles.keys.sorted())
        for name in names {
            let content = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(PhilipsHuePlugin.webFiles[name]?.body == content, "\(name) is stale: run swift Scripts/embed-assets.swift web Plugins/PhilipsHue/Web Plugins/PhilipsHue/Sources/WebFiles.swift PhilipsHuePlugin")
        }
    }

    /// The page's routes answer what it draws.
    @Test func thePageSeesTheBridge() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let status = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "status", user: "admin"))
        #expect(status.json["paired"] == true)
        #expect(status.json["host"] == "192.0.2.10")
        let lights = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "lights", user: "admin"))
        let strip = try #require(lights.json["lights"]?.arrayValue?.first { $0["id"] == "light-1" })
        #expect(strip["kind"] == "colour")
        #expect(strip["effects"] == ["candle", "fire"])
        #expect(strip["gradient"]?.arrayValue?.count == 2)
        let scenes = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scenes", user: "admin"))
        let room = try #require(scenes.json["groups"]?[0])
        #expect(room["name"] == "Living room")
        #expect(room["scenes"]?.arrayValue?.count == 3)
        #expect(room["scenes"]?[0]?["colours"]?.arrayValue?.isEmpty == false)
        #expect(room["scenes"]?[0]?["playing"] == false)
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "recall", body: ["id": "scene-1"], user: "admin"))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/scene/scene-1", body: ["recall": ["action": "active", "duration": 100]]))
        // The tile's play button plays the scene, and stops it, whatever dynamicScenes says.
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "recall", body: ["id": "scene-1", "dynamic": true], user: "admin"))
        #expect(environment.bridge.puts.last?.body == ["recall": ["action": "dynamic_palette", "duration": 100]])
        // Paused, it is recalled still, so a scene with Autoplay does not start playing again.
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "recall", body: ["id": "scene-1", "dynamic": false], user: "admin"))
        #expect(environment.bridge.puts.last?.body == ["recall": ["action": "static", "duration": 100]])
        // Tapped again, an active scene switches its room off, as its switch in the Home app; a smart one stops.
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-off", body: ["id": "scene-1"], user: "admin"))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/grouped_light/group-1", body: ["on": ["on": false]]))
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-off", body: ["id": "smart-1"], user: "admin"))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/smart_scene/smart-1", body: ["recall": ["action": "deactivate"]]))
        // Autoplay is the scene's own on the bridge, as the Hue app's; a smart scene has none.
        let sunset = try #require(room["scenes"]?.arrayValue?.first { $0["id"] == "scene-1" })
        #expect(sunset["autoplay"] == false)
        #expect(sunset["palette"] == true)
        #expect(sunset["colourful"] == true)
        // Concentrate sets a white per light, no palette: it cannot play, and has no colours.
        let concentrate = room["scenes"]?.arrayValue?.first { $0["id"] == "scene-2" }
        #expect(concentrate?["palette"] == false)
        #expect(concentrate?["colourful"] == false)
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "autoplay", body: ["id": "scene-1", "on": true], user: "admin"))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/scene/scene-1", body: ["auto_dynamic": true]))
        let smart = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "autoplay", body: ["id": "smart-1", "on": true], user: "admin"))
        #expect(smart.status == 404)
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "light", body: ["id": "light-2", "on": true, "brightness": 40], user: "admin"))
        #expect(environment.bridge.puts.last?.body == ["on": ["on": true], "dimming": ["brightness": 40], "dynamics": ["duration": 100]])
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "identify", body: ["id": "light-2"], user: "admin"))
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/device/dev-2", body: ["identify": ["action": "identify"]]))
        // HomeKit's Identify goes to the device too.
        let desk = try await accessory(host, deskID)
        try await desk.information.characteristic(.identify).write(.bool(true))
        #expect(environment.bridge.puts.last?.path == "/clip/v2/resource/device/dev-2")
        await host.stop()
    }

    /// A picture dropped on a scene's tile is kept, listed with the scene by version, served back and removed.
    @Test func scenesTakePictures() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let picture = "data:image/jpeg;base64," + (Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 9, count: 64)).base64EncodedString()
        let saved = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-picture", body: ["id": "scene-1", "data": .string(picture)], user: "admin"))
        let version = try #require(saved.json["version"]?.stringValue)
        let scenes = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scenes", user: "admin"))
        #expect(scenes.json["groups"]?[0]?["scenes"]?.arrayValue?.first { $0["id"] == "scene-1" }?["picture"] == .string(version))
        let served = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scene-picture", query: ["id": "scene-1"], user: "admin"))
        #expect(served.json["data"] == .string(picture))
        let refused = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-picture", body: ["id": "scene-2", "data": "data:image/png;base64,PHN2Zz4="], user: "admin"))
        #expect(refused.status == 422)
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-picture-remove", body: ["id": "scene-1"], user: "admin"))
        let gone = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scene-picture", query: ["id": "scene-1"], user: "admin"))
        #expect(gone.status == 404)
        await host.stop()
    }

    /// The Assistant lists the scenes with their look in words, then recalls the one it picked, through the actions.
    @Test func theAssistantPicksAScene() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let actions = Dictionary(uniqueKeysWithValues: PhilipsHuePlugin.assistantActions.map { ($0.name, $0) })
        let list = try #require(actions["list_scenes"]).request(arguments: ["room": "living room"], user: "admin")
        let scenes = try await plugin.handleWebRequest(list).json["scenes"]?.arrayValue ?? []
        #expect(scenes.count == 3)
        let sunset = try #require(scenes.first { $0["name"] == "Savanna sunset" })
        #expect(sunset["room"] == "Living room")
        #expect(sunset["look"]?.stringValue?.hasPrefix("warm") == true)
        #expect(scenes.first { $0["name"] == "Concentrate" }?["look"] == "cool daylight white")
        #expect(scenes.first { $0["smart"] == true }?["look"]?.stringValue?.contains("time of day") == true)
        #expect(try await plugin.handleWebRequest(try #require(actions["list_scenes"]).request(arguments: ["room": "Attic"], user: "admin")).json["scenes"] == [])

        let recall = try #require(actions["recall_scene"]).request(arguments: ["id": "scene-2"], user: "admin")
        #expect(try await plugin.handleWebRequest(recall).status == 200)
        #expect(environment.bridge.puts.last?.path == "/clip/v2/resource/scene/scene-2")
        await host.stop()
    }

    @Test func scenesAreDescribedInWords() {
        #expect(SceneLook.colourName(hue: 25, saturation: 90) == "orange")
        #expect(SceneLook.colourName(hue: 230, saturation: 40) == "pale blue")
        #expect(SceneLook.colourName(hue: 0, saturation: 5) == "soft white")
        #expect(SceneLook.describe(colours: [], whites: [454]) == "warm white")
        let tropical = SceneLook.describe(colours: [HueColor.xy(hue: 240, saturation: 100), HueColor.xy(hue: 280, saturation: 90)], whites: [])
        #expect(tropical.hasPrefix("cool:"))
        #expect(SceneLook.describe(colours: [], whites: []) == "no colours set")
    }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(PhilipsHuePlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/PhilipsHue PhilipsHuePlugin")
        let schema = try JSONValue(string: try #require(PhilipsHuePlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "PhilipsHue")
    }
}
