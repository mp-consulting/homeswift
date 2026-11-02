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

/// A Hue Bridge in memory: pairing (refused until `pressLinkButton`), every resource, the PUTs it was sent, and its
/// event stream, which a test feeds with `emit`.
final class FakeBridge: HueTransport, @unchecked Sendable {
    struct Sent: Equatable {
        var method: String
        var path: String
        var body: JSONValue
        /// Where it went, and the application key it carried: not part of what tests compare a request with.
        var host: String? = nil
        var key: String? = nil

        static func == (a: Sent, b: Sent) -> Bool { a.method == b.method && a.path == b.path && a.body == b.body }
    }

    private let state = NIOLockedValueBox<(linkButton: Bool, key: String, resources: [JSONValue], sent: [Sent], refuseKey: Bool, bridgeID: String)>(
        (false, "app-key-1", FakeBridge.resources, [], false, "C42996FFFEC76C08"))

    /// How long a read of every resource takes, to have one still on its way when an event lands.
    let readDelay = NIOLockedValueBox(Duration.zero)

    /// The open event streams' continuations.
    private let streams = NIOLockedValueBox<[AsyncThrowingStream<[UInt8], any Error>.Continuation]>([])
    var openStreams: Int { streams.withLockedValue { $0.count } }

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    var puts: [Sent] { sent.filter { $0.method == "PUT" } }
    func pressLinkButton() { state.withLockedValue { $0.linkButton = true } }
    func releaseLinkButton() { state.withLockedValue { $0.linkButton = false } }
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

    /// Sends an event to every open stream: `changes` is the event's data, the bridge's array of changes.
    func emit(_ changes: JSONValue) {
        let text = "id: 1\ndata: \(String(decoding: changes.encoded(), as: UTF8.self))\n\n"
        for continuation in streams.withLockedValue({ $0 }) { continuation.yield(Array(text.utf8)) }
    }

    /// Ends every open stream, as a bridge that restarts does.
    func dropStreams() {
        for continuation in streams.withLockedValue({ list in defer { list = [] }; return list }) { continuation.finish(throwing: HTTPClientError.connectionClosed) }
    }

    func stream(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HTTPStreamingResponse {
        let refused = state.withLockedValue { request.header("hue-application-key") != $0.key || $0.refuseKey }
        let (body, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        if refused {
            continuation.finish()
            return HTTPStreamingResponse(status: 403, body: .init(body))
        }
        guard request.url.path == "/eventstream/clip/v2" else { continuation.finish(); return HTTPStreamingResponse(status: 404, body: .init(body)) }
        streams.withLockedValue { $0.append(continuation) }
        // A keep-alive comment first, as the bridge sends.
        continuation.yield(Array(": hi\n\n".utf8))
        return HTTPStreamingResponse(status: 200, headers: [("Content-Type", "text/event-stream")], body: .init(body))
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let body = request.body.flatMap { try? JSONValue(data: $0) } ?? .null
        let snapshot = state.withLockedValue { state in
            state.sent.append(Sent(method: request.method, path: path, body: body, host: request.url.host, key: request.header("hue-application-key")))
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
        if request.method == "GET", path == "/clip/v2/resource" {
            let delay = readDelay.withLockedValue { $0 }
            if delay > .zero { try await Task.sleep(for: delay) }
            return json(["errors": [], "data": .array(snapshot.resources)])
        }
        if request.method == "PUT", path.hasPrefix("/clip/v2/resource/") {
            let parts = path.split(separator: "/")
            return json(["errors": [], "data": [["rid": .string(String(parts.last ?? "")), "rtype": .string(String(parts[parts.count - 2]))]]])
        }
        // A new resource is kept as sent, with an id; a removed one is gone.
        if request.method == "POST", path.hasPrefix("/clip/v2/resource/") {
            let type = String(path.split(separator: "/").last ?? "")
            let id = "\(type)-new-\(snapshot.sent.count)"
            var object = body.objectValue ?? [:]
            (object["id"], object["type"]) = (.string(id), .string(type))
            state.withLockedValue { $0.resources.append(.object(object)) }
            return json(["errors": [], "data": [["rid": .string(id), "rtype": .string(type)]]])
        }
        if request.method == "DELETE", path.hasPrefix("/clip/v2/resource/") {
            let id = String(path.split(separator: "/").last ?? "")
            state.withLockedValue { $0.resources.removeAll { $0["id"]?.stringValue == id } }
            return json(["errors": [], "data": [["rid": .string(id), "rtype": "scene"]]])
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
        // A motion sensor (motion, temperature, light level, battery) and a dimmer switch (four buttons, battery).
        ["id": "dev-3", "type": "device", "metadata": ["name": "Hall sensor"],
         "product_data": ["model_id": "SML003", "manufacturer_name": "Signify Netherlands B.V.", "product_name": "Hue motion sensor", "software_version": "2.53.6"],
         "services": [["rid": "motion-3", "rtype": "motion"], ["rid": "temp-3", "rtype": "temperature"], ["rid": "lux-3", "rtype": "light_level"],
                      ["rid": "power-3", "rtype": "device_power"], ["rid": "zc-3", "rtype": "zigbee_connectivity"]]],
        ["id": "motion-3", "type": "motion", "owner": ["rid": "dev-3", "rtype": "device"], "enabled": true,
         "motion": ["motion": false, "motion_valid": true, "motion_report": ["changed": "2026-10-28T08:00:00.000Z", "motion": false]]],
        ["id": "temp-3", "type": "temperature", "owner": ["rid": "dev-3", "rtype": "device"], "enabled": true,
         "temperature": ["temperature": 21.37, "temperature_valid": true, "temperature_report": ["changed": "2026-10-28T08:00:00.000Z", "temperature": 21.37]]],
        ["id": "lux-3", "type": "light_level", "owner": ["rid": "dev-3", "rtype": "device"], "enabled": true,
         "light": ["light_level": 20001, "light_level_valid": true, "light_level_report": ["changed": "2026-10-28T08:00:00.000Z", "light_level": 20001]]],
        ["id": "power-3", "type": "device_power", "owner": ["rid": "dev-3", "rtype": "device"], "power_state": ["battery_state": "normal", "battery_level": 87]],
        ["id": "zc-3", "type": "zigbee_connectivity", "owner": ["rid": "dev-3", "rtype": "device"], "status": "connected"],
        ["id": "dev-4", "type": "device", "metadata": ["name": "Bedroom dimmer"],
         "product_data": ["model_id": "RWL022", "manufacturer_name": "Signify Netherlands B.V.", "product_name": "Hue dimmer switch", "software_version": "2.45.2"],
         "services": [["rid": "button-1", "rtype": "button"], ["rid": "button-2", "rtype": "button"], ["rid": "button-3", "rtype": "button"],
                      ["rid": "button-4", "rtype": "button"], ["rid": "power-4", "rtype": "device_power"]]],
        ["id": "button-1", "type": "button", "owner": ["rid": "dev-4", "rtype": "device"], "metadata": ["control_id": 1],
         "button": ["button_report": ["updated": "2026-10-28T07:00:00.000Z", "event": "short_release"]]],
        ["id": "button-2", "type": "button", "owner": ["rid": "dev-4", "rtype": "device"], "metadata": ["control_id": 2], "button": [:]],
        ["id": "button-3", "type": "button", "owner": ["rid": "dev-4", "rtype": "device"], "metadata": ["control_id": 3], "button": [:]],
        ["id": "button-4", "type": "button", "owner": ["rid": "dev-4", "rtype": "device"], "metadata": ["control_id": 4], "button": [:]],
        ["id": "power-4", "type": "device_power", "owner": ["rid": "dev-4", "rtype": "device"], "power_state": ["battery_state": "low", "battery_level": 9]],
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
            let dependencies = PhilipsHuePlugin.Dependencies(transport: { _ in bridge }, discover: { ["192.0.2.10"] }, pairingRetryDelay: .milliseconds(50), settleTime: hueSettleTime)
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


/// How long a light's values are left alone after a command in these tests: a tenth of the plugin's.
let hueSettleTime = PhilipsHuePlugin.settleTime / 10
@Suite(.timeLimit(.minutes(1)))
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

    /// The plugin asks for a key until the link button is pressed, and keeps it in the vault, not config.json.
    @Test func pairsWhenTheLinkButtonIsPressed() async throws {
        let host = try await environment.start(paired: false)
        #expect(await eventually { environment.bridge.sent.contains { $0.method == "POST" && $0.path == "/api" } })
        #expect(await environment.plugin?.storedBridge.applicationKey == nil)
        environment.bridge.pressLinkButton()
        let pairing = try #require(environment.bridge.sent.first { $0.path == "/api" })
        #expect(pairing.body["generateclientkey"] == true)
        #expect(pairing.body["devicetype"]?.stringValue?.hasPrefix("homeswift#") == true)
        let vault = CredentialVault(storage: environment.directory)
        #expect(await eventually(timeout: .seconds(10)) {
            (try? vault.entries())?.contains { $0.key.hasSuffix(".account") && $0.value.fields.values.contains { $0.contains("app-key-1") } } == true
        })
        _ = try await accessory(host, stripID)
        await host.stop()
    }

    /// Setup asks for the link button while it is not pressed, then hands the key to the bridge's vault, and lists the
    /// lights and sensors as devices that need nothing more.
    @Test func setUpAsksForTheLinkButtonThenListsTheLights() async throws {
        let host = try await environment.start(paired: false)
        let plugin = try #require(await environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, let state) = first else { Issue.record("expected the link button"); return }
        #expect(prompt.waitSeconds == 60)
        environment.bridge.pressLinkButton()
        let done = try await plugin.authorize(SetupRequest(target: .account, state: state))
        guard case .done(let outcome) = done else { Issue.record("expected done"); return }
        #expect(outcome.credentials?["applicationKey"]?.stringValue?.isEmpty == false)
        #expect(outcome.settings.isEmpty)
        try host.context(platform: PhilipsHuePlugin.platform, name: PhilipsHuePlugin.name)?.saveCredentials(outcome.credentials ?? .null)
        let devices = try await plugin.discover()
        #expect(devices.contains { $0.deviceID == "light-1" && $0.isSetUp })
        await host.stop()
    }

    /// At a new address the key goes only to the same bridge: another one there loses it, and pairing starts over.
    /// A bridge ID is public, so an address that changes never gets the key: it is dropped, and no resource is read
    /// with it until Setup pairs again.
    @Test func aMovedBridgeLosesItsKeyUntilPairedAgain() async throws {
        let first = try await environment.start()
        _ = try await accessory(first, stripID)
        #expect(await eventually { await environment.plugin?.storedBridge.bridgeID != nil })
        await first.stop()
        environment.bridge.releaseLinkButton()
        let host = try await environment.start(settings: ["host": "192.0.2.11"], paired: false)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.storedBridge.host == "192.0.2.11" })
        #expect(await plugin.storedBridge.applicationKey == nil)
        // Nothing the plugin sends to the new address carries the dropped key (it waits for the link button). The
        // window can miss a late request, never fail on an early one.
        try await Task.sleep(for: .milliseconds(500))
        #expect(!environment.bridge.sent.contains { $0.host == "192.0.2.11" && $0.key != nil })
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
        try await Task.sleep(for: hueSettleTime + .milliseconds(100))
        await environment.plugin?.refresh()
        #expect(bulb[.hue]?.value == .double(240))
        #expect(bulb[.saturation]?.value == .double(100))
        await host.stop()
    }

    /// A light with brightness and white temperature has Adaptive Lighting: the controller sets the white through the
    /// bridge, a read that finds that white keeps it, a colour set in the Hue app stops it.
    @Test func adaptiveLightingFollowsTheBridgeAndStopsOnChangesElsewhere() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "transitionMs": 0])
        let bulb = try #require(try await accessory(host, deskID).service(.lightbulb))
        let controller = try #require(bulb.adaptiveLighting)
        try controller.activateForTesting()
        #expect(await eventually { environment.bridge.puts.contains { $0.path == "/clip/v2/resource/light/light-2" && $0.body["color_temperature"]?["mirek"] == 300 } })
        // The bridge takes the white at once, as a real one does: a refresh that comes meanwhile reads it.
        environment.bridge.change("light-2") { $0["color_temperature"] = ["mirek": 300, "mirek_valid": true, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 454]] }
        try await Task.sleep(for: hueSettleTime + .milliseconds(100))
        await environment.plugin?.refresh()
        #expect(controller.isAdaptiveLightingActive)
        environment.bridge.change("light-2") { $0["color_temperature"] = ["mirek": .null, "mirek_valid": false, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 454]] }
        await environment.plugin?.refresh()
        #expect(!controller.isAdaptiveLightingActive)
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

    /// Homeswift's Scenes page lists the bridge's scenes by room, without the excluded ones, and recalls them as their
    /// switches do.
    @Test func scenesReachHomeswiftsScenesPage() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "excludeScenes": ["Living room/Concentrate"]])
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let scenes = await plugin.scenes()
        #expect(scenes.map(\.id) == ["smart-1", "scene-1"])
        #expect(scenes.allSatisfy { $0.room == "Living room" })
        #expect(scenes.first { $0.id == "smart-1" }?.capabilities == [.recall])
        #expect(scenes.first { $0.id == "scene-1" }?.capabilities == [.recall, .rename, .update, .delete])
        #expect(scenes.first { $0.id == "scene-1" }?.colours.isEmpty == false)
        try await plugin.recallScene(id: "scene-1")
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/scene/scene-1", body: ["recall": ["action": "active", "duration": 100]]))
        await host.stop()
    }

    /// Homeswift writes scenes to the bridge: a new one in the room or zone that holds just its lights, with each
    /// light's colour in its gamut and white in its range; renamed, changed and removed.
    @Test func scenesAreWrittenToTheBridge() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let strip = PhilipsHuePlugin.accessoryID(lightID: "light-1"), desk = PhilipsHuePlugin.accessoryID(lightID: "light-2")
        #expect(await plugin.sceneTarget(accessoryIDs: [strip]) == "Living room")
        #expect(await plugin.sceneTarget(accessoryIDs: [desk]) == "Upstairs")
        #expect(await plugin.sceneTarget(accessoryIDs: [strip, desk]) == nil)
        #expect(await plugin.sceneTarget(accessoryIDs: ["Other:lamp"]) == nil)

        let id = try await plugin.createScene(name: "Reading nook", lights: [PluginSceneLight(accessoryID: strip, on: true, brightness: 0.1, hue: 30, saturation: 80)])
        let created = try #require(environment.bridge.sent.last { $0.method == "POST" })
        #expect(created.path == "/clip/v2/resource/scene")
        #expect(created.body["metadata"] == ["name": "Reading nook"])
        #expect(created.body["group"] == ["rid": "room-1", "rtype": "room"])
        let action = created.body["actions"]?[0]
        #expect(action?["target"] == ["rid": "light-1", "rtype": "light"])
        #expect(action?["action"]?["dimming"]?["brightness"] == 0.2)
        #expect(action?["action"]?["color"]?["xy"]?["x"]?.doubleValue != nil)
        #expect(await plugin.scenes().first { $0.id == id }?.accessoryIDs == [strip])

        try await plugin.updateScene(id: id, name: String(repeating: "x", count: 40), lights: [PluginSceneLight(accessoryID: strip, on: true, colorTemperature: 600)])
        let changed = try #require(environment.bridge.puts.last)
        #expect(changed.path == "/clip/v2/resource/scene/\(id)")
        #expect(changed.body["metadata"]?["name"]?.stringValue?.count == 32)
        #expect(changed.body["actions"]?[0]?["action"]?["color_temperature"] == ["mirek": 500])
        await #expect(throws: (any Error).self) { try await plugin.updateScene(id: "smart-1", name: "No", lights: nil) }
        // The desk is upstairs, not in the living room the scene belongs to.
        await #expect(throws: PluginSceneError.self) { try await plugin.updateScene(id: id, name: nil, lights: [PluginSceneLight(accessoryID: desk, on: true)]) }

        try await plugin.deleteScene(id: id)
        #expect(environment.bridge.sent.contains(.init(method: "DELETE", path: "/clip/v2/resource/scene/\(id)", body: .null)))
        #expect(await plugin.scenes().contains { $0.id == id } == false)
        await host.stop()
    }

    /// Homeswift renames the bridge's rooms (not its zones) with `PUT /clip/v2/resource/room/<id>`, the name at most
    /// 32 characters.
    @Test func roomsAreRenamedOnTheBridge() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        #expect(await plugin.rooms() == [PluginRoom(id: "room-1", name: "Living room")])

        try await plugin.renameRoom(id: "room-1", name: " Lounge ")
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/room/room-1", body: ["metadata": ["name": "Lounge"]]))
        try await plugin.renameRoom(id: "room-1", name: String(repeating: "x", count: 40))
        #expect(environment.bridge.puts.last?.body["metadata"]?["name"]?.stringValue?.count == 32)
        await #expect(throws: PluginRoomError.self) { try await plugin.renameRoom(id: "zone-1", name: "Upstairs too") }
        await host.stop()
    }

    /// An animated scene's effect plays as the Hue app's on the lights that have it, with its colour, speed and
    /// brightness; a light without it, or a palette, is left to Homeswift; stopping sends no_effect.
    @Test func effectsPlayNatively() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let strip = PhilipsHuePlugin.accessoryID(lightID: "light-1"), desk = PhilipsHuePlugin.accessoryID(lightID: "light-2")
        let fire = LightEffect(style: .fire, colors: [.init(hue: 0, saturation: 100)], speed: 0.25, brightness: 60)
        #expect(await plugin.animate(fire, accessoryIDs: [strip, desk]) == [strip])
        let put = try #require(environment.bridge.puts.last)
        #expect(put.path == "/clip/v2/resource/light/light-1")
        #expect(put.body["effects_v2"]?["action"]?["effect"] == "fire")
        #expect(put.body["effects_v2"]?["action"]?["parameters"]?["speed"] == 0.25)
        #expect(put.body["effects_v2"]?["action"]?["parameters"]?["color"]?["xy"]?["x"]?.doubleValue != nil)
        #expect(put.body["dimming"] == ["brightness": 60])
        #expect(put.body["on"] == ["on": true])
        #expect(await plugin.animate(LightEffect(style: .palette, colors: [.init(hue: 0), .init(hue: 120)]), accessoryIDs: [strip]).isEmpty)
        #expect(await plugin.animate(LightEffect(style: .sparkle), accessoryIDs: [strip]).isEmpty)
        await plugin.stopAnimation(accessoryIDs: [strip])
        #expect(environment.bridge.puts.last == .init(method: "PUT", path: "/clip/v2/resource/light/light-1", body: ["effects_v2": ["action": ["effect": "no_effect"]]]))
        await host.stop()
    }

    /// A light with timed effects plays a sunrise for the scene's duration; one without has none.
    @Test func sunriseIsATimedEffect() {
        var light = HueLight(id: "l", deviceID: "d", name: "Bedside", model: "", manufacturer: "", product: "", firmware: "", on: false)
        #expect(PhilipsHuePlugin.effectBody(LightEffect(style: .sunrise), for: light) == nil)
        light.timedEffects = ["sunrise", "sunset"]
        #expect(PhilipsHuePlugin.effectBody(LightEffect(style: .sunrise, durationSeconds: 600), for: light) == ["timed_effects": ["effect": "sunrise", "duration": 600_000]])
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
        // Pairing is Setup's: the page has no route of its own for it.
        for (method, path) in [("POST", "pair"), ("POST", "host"), ("GET", "discover")] {
            #expect(try await plugin.handleWebRequest(PluginWebRequest(method: method, path: path, body: ["host": "192.0.2.11"], user: "admin")).status == 404)
        }
        let lights = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "lights", user: "admin"))
        let strip = try #require(lights.json["lights"]?.arrayValue?.first { $0["id"] == "light-1" })
        #expect(strip["kind"] == "colour")
        #expect(strip["effects"] == ["candle", "fire"])
        #expect(strip["gradient"]?.arrayValue?.count == 2)
        // A light's room is the room its device is in; a zone does not count.
        #expect(strip["room"] == "Living room")
        #expect(strip["roomID"] == "room-1")
        #expect(lights.json["lights"]?.arrayValue?.first { $0["id"] == "light-2" }?["room"] == .null)
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

@Suite(.timeLimit(.minutes(1)))
struct HueSensorTests {
    let environment = TestEnvironment()
    let sensorID = PhilipsHuePlugin.sensorAccessoryID(deviceID: "dev-3")
    let dimmerID = PhilipsHuePlugin.sensorAccessoryID(deviceID: "dev-4")

    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
        return try #require(host.mainBridge.server.accessories.first { $0.id == id })
    }

    @Test func readsHuesLightLevelAndButtonEvents() {
        #expect(abs(HueSensorDevice.lux(lightLevel: 20001) - 100) < 0.001)
        #expect(HueSensorDevice.lux(lightLevel: 0) == 0.0001)
        #expect(HueSensorDevice.switchEvent("short_release") == 0)
        #expect(HueSensorDevice.switchEvent("double_short_release") == 1)
        #expect(HueSensorDevice.switchEvent("long_press") == 2)
        #expect(HueSensorDevice.switchEvent("initial_press") == nil && HueSensorDevice.switchEvent("repeat") == nil)
        // A device with a light belongs to the light, and one without a sensor or button is no sensor.
        let snapshot = HueSnapshot(resources: FakeBridge.resources)
        #expect(snapshot.sensors.map(\.id) == ["dev-4", "dev-3"])
    }

    @Test func sensorsAndSwitchesBecomeAccessories() async throws {
        let host = try await environment.start()
        let sensor = try await accessory(host, sensorID)
        #expect(sensor.category == .sensor)
        #expect(sensor.service(.motionSensor)?[.motionDetected]?.value == false)
        #expect(sensor.service(.temperatureSensor)?[.currentTemperature]?.value == 21.4)
        #expect(sensor.service(.lightSensor)?[.currentAmbientLightLevel]?.value.doubleValue.map { abs($0 - 100) < 0.01 } == true)
        #expect(sensor.service(.battery)?[.batteryLevel]?.value == 87)
        #expect(sensor.service(.battery)?[.statusLowBattery]?.value == 0)
        let dimmer = try await accessory(host, dimmerID)
        #expect(dimmer.category == .programmableSwitch)
        let buttons = dimmer.services.filter { $0.type == .statelessProgrammableSwitch }
        #expect(buttons.map { $0[.serviceLabelIndex]?.value } == [1, 2, 3, 4])
        #expect(dimmer.service(.serviceLabel)?[.serviceLabelNamespace]?.value == 1)
        #expect(dimmer.service(.battery)?[.statusLowBattery]?.value == 1)
        await host.stop()
    }

    @Test func theSensorsOptionAndExclusionsLeaveThemOut() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "excludeSensors": ["Bedroom dimmer"]])
        _ = try await accessory(host, sensorID)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == dimmerID })
        await host.stop()
        let other = TestEnvironment()
        let none = try await other.start(settings: ["host": "192.0.2.10", "sensors": false])
        _ = try await accessory(none, PhilipsHuePlugin.accessoryID(lightID: "light-1"))
        #expect(!none.mainBridge.server.accessories.contains { $0.id == sensorID })
        await none.stop()
    }

    /// A press on the event stream fires its switch once, the same press twice fires twice, and a read that sees the
    /// press again fires nothing more.
    @Test func theEventStreamFiresButtonsAndShowsMotion() async throws {
        // No poll of its own: one landing after an event, on a slow machine, would undo the motion it brought.
        let host = try await environment.start(settings: ["host": "192.0.2.10", "pollingInterval": 60])
        let dimmer = try await accessory(host, dimmerID)
        let sensor = try await accessory(host, sensorID)
        #expect(await eventually { environment.bridge.openStreams > 0 })
        let first = try #require(dimmer.services.first { $0[.serviceLabelIndex]?.value == 1 })
        let presses = NIOLockedValueBox<[HAPValue]>([])
        _ = first.characteristic(.programmableSwitchEvent).observe { change in
            if change.reason == .event { presses.withLockedValue { $0.append(change.newValue) } }
        }
        func press(_ event: String, at time: String) -> JSONValue {
            [["type": "update", "id": "e", "data": [["id": "button-1", "type": "button", "owner": ["rid": "dev-4", "rtype": "device"],
                                                    "button": ["button_report": ["updated": .string(time), "event": .string(event)], "last_event": .string(event)]]]]]
        }
        environment.bridge.emit(press("initial_press", at: "2026-10-28T09:00:00.000Z"))
        environment.bridge.emit(press("short_release", at: "2026-10-28T09:00:00.200Z"))
        environment.bridge.emit(press("short_release", at: "2026-10-28T09:00:01.000Z"))
        environment.bridge.emit(press("long_press", at: "2026-10-28T09:00:02.000Z"))
        #expect(await eventually { presses.withLockedValue { $0 } == [0, 0, 2] })
        // Motion, in part, as the bridge sends only what changed.
        environment.bridge.emit([["type": "update", "id": "e", "data": [["id": "motion-3", "type": "motion", "motion": ["motion": true, "motion_report": ["motion": true]]]]]])
        #expect(await eventually { sensor.service(.motionSensor)?[.motionDetected]?.value == true })
        // The next read sees the bridge's resources (press long gone from them, motion back off): no press fires.
        let plugin = try #require(environment.plugin)
        await plugin.refresh()
        #expect(presses.withLockedValue { $0 } == [0, 0, 2])
        #expect(sensor.service(.motionSensor)?[.motionDetected]?.value == false)
        await host.stop()
    }

    /// A change to a light on the stream reads the bridge again at once, before the next poll.
    @Test func aLightChangedElsewhereShowsAtOnce() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "pollingInterval": 60])
        let desk = try await accessory(host, PhilipsHuePlugin.accessoryID(lightID: "light-2"))
        #expect(await eventually { environment.bridge.openStreams > 0 })
        environment.bridge.change("light-2") { $0["on"] = ["on": true] }
        environment.bridge.emit([["type": "update", "id": "e", "data": [["id": "light-2", "type": "light", "on": ["on": true]]]]])
        #expect(await eventually { desk.service(.lightbulb)?[.on]?.value == true })
        await host.stop()
    }

    /// While the stream is down, a read that finds a newer report fires it.
    @Test func withoutTheStreamAReadFiresANewPress() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "pollingInterval": 60])
        let dimmer = try await accessory(host, dimmerID)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { environment.bridge.openStreams > 0 })
        environment.bridge.dropStreams()
        #expect(await eventually { await !plugin.streaming })
        let first = try #require(dimmer.services.first { $0[.serviceLabelIndex]?.value == 1 })
        let presses = NIOLockedValueBox(0)
        _ = first.characteristic(.programmableSwitchEvent).observe { change in if change.reason == .event { presses.withLockedValue { $0 += 1 } } }
        environment.bridge.change("button-1") { $0["button"] = ["button_report": ["updated": "2026-10-28T10:00:00.000Z", "event": "double_short_release"]] }
        await plugin.refresh()
        #expect(presses.withLockedValue { $0 } == 1)
        #expect(first[.programmableSwitchEvent]?.value == 1)
        await host.stop()
    }

    /// A read taken before an event and landing after it is dropped, not shown: the event's state stays.
    @Test func aReadOlderThanAnEventIsDropped() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "pollingInterval": 60])
        let desk = try await accessory(host, PhilipsHuePlugin.accessoryID(lightID: "light-2"))
        let plugin = try #require(environment.plugin)
        #expect(await eventually { environment.bridge.openStreams > 0 })
        environment.bridge.readDelay.withLockedValue { $0 = .milliseconds(400) }
        let read = Task { await plugin.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        // The bridge's resources still say off (the read was taken before); the event says on.
        environment.bridge.emit([["type": "update", "id": "e", "data": [["id": "light-2", "type": "light", "on": ["on": true]]]]])
        #expect(await eventually { desk.service(.lightbulb)?[.on]?.value == true })
        await read.value
        #expect(desk.service(.lightbulb)?[.on]?.value == true)
        await host.stop()
    }

    /// A change to a light left out of the Home app brings it back for no moment.
    @Test func anEventForAnExcludedLightAddsNothing() async throws {
        let host = try await environment.start(settings: ["host": "192.0.2.10", "excludeLights": ["Desk"]])
        _ = try await accessory(host, PhilipsHuePlugin.accessoryID(lightID: "light-1"))
        #expect(await eventually { environment.bridge.openStreams > 0 })
        environment.bridge.emit([["type": "update", "id": "e", "data": [["id": "light-2", "type": "light", "on": ["on": true]]]]])
        try await Task.sleep(for: .milliseconds(300))
        #expect(!host.mainBridge.server.accessories.contains { $0.id == PhilipsHuePlugin.accessoryID(lightID: "light-2") })
        await host.stop()
    }
}
