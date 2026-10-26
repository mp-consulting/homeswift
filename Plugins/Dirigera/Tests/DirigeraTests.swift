import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDirigera

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A DIRIGERA hub in memory: pairing (403 until `pressButton`), devices, scenes, the requests it was sent, and an
/// event stream the test feeds.
final class FakeHub: HTTPSending, @unchecked Sendable {
    struct Sent: Equatable {
        var method: String
        var path: String
        var body: String
    }

    private let state = NIOLockedValueBox<(button: Bool, challenge: String?, sent: [Sent], refuse: Bool)>((false, nil, [], false))
    let events = AsyncThrowingStream<JSONValue, any Error>.makeStream()
    static let token = "hub-token-1"

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    var patches: [Sent] { sent.filter { $0.method == "PATCH" } }
    func pressButton() { state.withLockedValue { $0.button = true } }
    func refuse() { state.withLockedValue { $0.refuse = true } }
    var challenge: String? { state.withLockedValue { $0.challenge } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let body = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let snapshot = state.withLockedValue { state in
            state.sent.append(Sent(method: request.method, path: path, body: body))
            return state
        }
        func json(_ value: JSONValue, status: Int = 200) -> HomeswiftNetwork.HTTPResponse { .init(status: status, body: value.encoded(), certificateFingerprint: "cc:dd") }
        switch (request.method, path) {
        case ("GET", "/v1/oauth/authorize"):
            let challenge = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge" }?.value
            state.withLockedValue { $0.challenge = challenge }
            return json(["code": "code-1"])
        case ("POST", "/v1/oauth/token"):
            guard snapshot.button else { return json(["error": "button not pressed"], status: 403) }
            // The verifier must hash to the challenge of the authorize request.
            let verifier = body.split(separator: "&").first { $0.hasPrefix("code_verifier=") }.map { String($0.dropFirst(14)) } ?? ""
            guard DirigeraClient.challenge(for: verifier) == snapshot.challenge, body.contains("grant_type=authorization_code"), body.contains("code=code-1") else {
                return json(["error": "bad verifier"], status: 400)
            }
            return json(["access_token": .string(Self.token)])
        default:
            guard request.header("Authorization") == "Bearer \(Self.token)", !snapshot.refuse else { return json(["error": "unauthorized"], status: 401) }
        }
        switch (request.method, path) {
        case ("GET", "/v1/devices"): return json(Self.devices)
        case ("GET", "/v1/scenes"): return json(Self.scenes)
        default: return json([:], status: 202)
        }
    }

    static let devices: JSONValue = [
        ["id": "bulb-1", "type": "light", "deviceType": "light", "isReachable": true,
         "attributes": ["customName": "Sofa Lamp", "model": "TRADFRI bulb E27 CWS 806lm", "manufacturer": "IKEA of Sweden", "firmwareVersion": "1.0.021",
                        "serialNumber": "ABC", "isOn": true, "lightLevel": 60, "colorHue": 30.0, "colorSaturation": 0.5, "colorTemperature": 2801,
                        "colorTemperatureMin": 4000, "colorTemperatureMax": 2202, "colorMode": "color"],
         "capabilities": ["canSend": [], "canReceive": ["customName", "isOn", "lightLevel", "colorTemperature", "colorHue", "colorSaturation"]],
         "room": ["id": "r1", "name": "Living Room"]],
        ["id": "bulb-2", "type": "light", "deviceType": "light", "isReachable": true,
         "attributes": ["customName": "Hallway", "model": "TRADFRI bulb E14 W 470lm", "isOn": false, "lightLevel": 100],
         "capabilities": ["canReceive": ["customName", "isOn", "lightLevel"]]],
        ["id": "plug-1", "type": "outlet", "deviceType": "outlet", "isReachable": true,
         "attributes": ["customName": "Coffee Machine", "model": "TRETAKT", "isOn": false], "capabilities": ["canReceive": ["isOn"]]],
        ["id": "remote-1", "type": "controller", "deviceType": "lightController", "attributes": ["customName": "Remote"]],
        ["id": "door-1", "type": "sensor", "deviceType": "openCloseSensor", "isReachable": true,
         "attributes": ["customName": "Front Door", "model": "PARASOLL Door/Window Sensor", "isOpen": false, "batteryPercentage": 8],
         "capabilities": ["canReceive": ["customName"]]],
    ]

    static let scenes: JSONValue = [
        ["id": "scene-1", "info": ["name": "Movie night", "icon": "scenes_tv"], "type": "userScene", "triggers": [], "actions": []],
        ["id": "scene-2", "info": ["name": "Wake up", "icon": "scenes_sun"], "type": "wakeUpScene"],
    ]
}

final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Dirigera-tests-\(UUID().uuidString)")
    let hub = FakeHub()
    private let plugins = NIOLockedValueBox<[DirigeraPlugin]>([])

    var plugin: DirigeraPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = ["hubs": [["host": "192.0.2.20", "token": FakeHub.token]]]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let hub = hub
        registry.register(platform: DirigeraPlugin.platform, name: DirigeraPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(DirigeraPlugin.Configuration.self, from: json)
            let dependencies = DirigeraPlugin.Dependencies(
                transport: { _ in hub }, events: { _, _, _ in hub.events.stream }, discover: { ["192.0.2.20"] }, reconnectDelay: .milliseconds(50))
            let plugin = DirigeraPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: DirigeraPlugin.platform, name: DirigeraPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct DirigeraTests {
    let environment = TestEnvironment()
    let sofaID = DirigeraPlugin.accessoryID(deviceID: "bulb-1")
    let hallID = DirigeraPlugin.accessoryID(deviceID: "bulb-2")
    let plugID = DirigeraPlugin.accessoryID(deviceID: "plug-1")
    let scenesID = DirigeraPlugin.sceneAccessoryID(host: "192.0.2.20")

    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == id } })
        return try #require(host.mainBridge.server.accessories.first { $0.id == id })
    }

    /// homebridge-dirigera's block decodes as it is.
    @Test func aHomebridgeBlockDecodes() throws {
        let json = #"{"platform":"Dirigera","hubs":[{"host":"192.168.1.30","token":"abc","name":"Home"}]}"#
        let configuration = try JSONDecoder().decode(DirigeraPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.hubs?.first?.host == "192.168.1.30")
        #expect(configuration.hubs?.first?.token == "abc")
    }

    @Test func pkceMatchesRFC7636() {
        // RFC 7636, appendix B.
        #expect(DirigeraClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = DirigeraClient.makeVerifier()
        #expect(verifier.count == 128 && verifier.allSatisfy { $0.isLetter || $0.isNumber })
    }

    /// Pairing waits for the action button, then keeps the token in the plugin's own file and starts the hub.
    @Test func pairsWhenTheButtonIsPressed() async throws {
        let host = try await environment.start(settings: ["hubs": [["host": "192.0.2.20"]]])
        let plugin = try #require(environment.plugin)
        let hub = environment.hub
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            hub.pressButton()
        }
        let answer = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "pair", body: ["host": "192.0.2.20"], user: "admin"))
        #expect(answer.json["paired"] == "192.0.2.20")
        _ = try await accessory(host, sofaID)
        let directory = environment.directory
        #expect(await eventually {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            return files.first { $0.lastPathComponent == "hubs.json" }.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains(FakeHub.token) == true
        })
        await host.stop()
    }

    @Test func devicesAndScenesBecomeAccessories() async throws {
        let host = try await environment.start()
        let sofa = try await accessory(host, sofaID)
        let bulb = try #require(sofa.service(.lightbulb))
        #expect(bulb[.brightness]?.value == .int(60))
        #expect(bulb[.hue]?.value == .double(30))
        #expect(bulb[.saturation]?.value == .double(50))
        #expect(bulb[.colorTemperature]?.value == .int(357))
        #expect(bulb[.colorTemperature]?.type.minValue == 250)
        #expect(bulb[.colorTemperature]?.type.maxValue == 454)
        #expect(sofa.suggestedRoom == "Living Room")
        let hall = try await accessory(host, hallID)
        #expect(hall.service(.lightbulb)?[.hue] == nil)
        #expect(try await accessory(host, plugID).service(.outlet) != nil)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == DirigeraPlugin.accessoryID(deviceID: "remote-1") })
        let scenes = try await accessory(host, scenesID)
        #expect(scenes.service(.switch, subtype: "scene:scene-1") != nil)
        #expect(scenes.service(.switch, subtype: "scene:scene-2") == nil)
        await host.stop()
    }

    /// A change of brightness and colour goes out in the hub's order: On, the level, then hue and saturation together.
    @Test func writesGoOutInOrder() async throws {
        let host = try await environment.start(settings: ["hubs": [["host": "192.0.2.20", "token": FakeHub.token]], "transitionMs": 0])
        let bulb = try #require(try await accessory(host, sofaID).service(.lightbulb))
        bulb.characteristic(.on).value = .bool(false)
        async let on: Void = bulb[.on]!.write(.bool(true))
        async let level: Void = bulb[.brightness]!.write(.int(80))
        async let saturation: Void = bulb[.saturation]!.write(.double(100))
        async let hue: Void = bulb[.hue]!.write(.double(120))
        _ = try await (on, level, saturation, hue)
        let bodies = environment.hub.patches.filter { $0.path == "/v1/devices/bulb-1" }.map(\.body)
        #expect(bodies.count == 3)
        #expect(bodies.first == #"[{"attributes":{"isOn":true}}]"#)
        #expect(bodies.dropFirst().first?.contains(#""lightLevel":80"#) == true)
        #expect(bodies.last?.contains(#""colorHue":120"#) == true && bodies.last?.contains(#""colorSaturation":1"#) == true)
        #expect(bodies.last?.contains(#""transitionTime":0"#) == true)
        await host.stop()
    }

    @Test func scenesTriggerAndUndo() async throws {
        let host = try await environment.start()
        let scene = try #require(try await accessory(host, scenesID).service(.switch, subtype: "scene:scene-1"))
        try await scene[.on]!.write(.bool(true))
        #expect(environment.hub.sent.last == .init(method: "POST", path: "/v1/scenes/scene-1/trigger", body: ""))
        try await scene[.on]!.write(.bool(false))
        #expect(environment.hub.sent.last == .init(method: "POST", path: "/v1/scenes/scene-1/undo", body: ""))
        #expect(await eventually { scene[.on]?.value == .bool(false) })
        await host.stop()
    }

    /// A PARASOLL sensor is a contact sensor with its battery; opening it reaches HomeKit at once.
    @Test func doorSensors() async throws {
        let host = try await environment.start()
        let door = try await accessory(host, DirigeraPlugin.accessoryID(deviceID: "door-1"))
        let contact = try #require(door.service(.contactSensor))
        #expect(contact[.contactSensorState]?.value == .int(0))
        #expect(door.service(.battery)?[.batteryLevel]?.value == .int(8))
        #expect(door.service(.battery)?[.statusLowBattery]?.value == .int(1))
        environment.hub.events.continuation.yield(["type": "deviceStateChanged", "data": ["id": "door-1", "attributes": ["isOpen": true]]])
        #expect(await eventually { contact[.contactSensorState]?.value == .int(1) })
        await host.stop()
    }

    /// The hub's events reach HomeKit at once.
    @Test func eventsReachHomeKit() async throws {
        let host = try await environment.start()
        let plug = try #require(try await accessory(host, plugID).service(.outlet))
        environment.hub.events.continuation.yield(["type": "deviceStateChanged", "data": ["id": "plug-1", "attributes": ["isOn": true]]])
        #expect(await eventually { plug[.on]?.value == .bool(true) })
        await host.stop()
    }

    @Test func aRefusedTokenShowsNoResponse() async throws {
        let host = try await environment.start(settings: ["hubs": [["host": "192.0.2.20"]]])
        // Paired from the page once: the token in the plugin's file.
        let plugin = try #require(environment.plugin)
        environment.hub.pressButton()
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "pair", body: ["host": "192.0.2.20"], user: "admin"))
        let sofa = try await accessory(host, sofaID)
        environment.hub.refuse()
        await plugin.refreshAll()
        #expect(sofa.isUnavailable)
        let hubs = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "hubs", user: "admin"))
        #expect(hubs.json["hubs"]?[0]?["paired"] == false)
        await host.stop()
    }

    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func webFilesAreCurrent() throws {
        let directory = Self.root.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == DirigeraPlugin.webFiles.keys.sorted())
        for name in names {
            let content = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(DirigeraPlugin.webFiles[name]?.body == content, "\(name) is stale: run swift Scripts/embed-assets.swift web Plugins/Dirigera/Web Plugins/Dirigera/Sources/WebFiles.swift DirigeraPlugin")
        }
    }

    /// The page's routes answer what it draws.
    @Test func thePageSeesTheHub() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let hubs = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "hubs", user: "admin"))
        #expect(hubs.json["hubs"]?[0]?["paired"] == true)
        #expect(hubs.json["hubs"]?[0]?["devices"] == 4)
        let devices = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "devices", user: "admin"))
        let sofa = try #require(devices.json["devices"]?.arrayValue?.first { $0["id"] == "bulb-1" })
        #expect(sofa["room"] == "Living Room")
        #expect(sofa["type"] == "colour")
        let scenes = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scenes", user: "admin"))
        #expect(scenes.json["scenes"]?.arrayValue?.map { $0["name"] } == ["Movie night"])
        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "trigger", body: ["host": "192.0.2.20", "id": "scene-1"], user: "admin"))
        #expect(environment.hub.sent.contains { $0.path == "/v1/scenes/scene-1/trigger" })
        // Only an id the hub listed reaches it, as one path segment.
        let sentBefore = environment.hub.sent.count
        for id in ["scene-9", "../devices/bulb-1", "scene-1/../x?y"] {
            await #expect(throws: (any Error).self) {
                _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "trigger", body: ["host": "192.0.2.20", "id": .string(id)], user: "admin"))
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "identify", body: ["host": "192.0.2.20", "id": "../scenes"], user: "admin"))
        }
        #expect(environment.hub.sent.count == sentBefore)
        #expect(DirigeraClient.segment("a/../b?c#d%e.f") == "a%2F%2E%2E%2Fb%3Fc%23d%25e%2Ef")
        let sofaAccessory = try await accessory(host, sofaID)
        try await sofaAccessory.information.characteristic(.identify).write(.bool(true))
        #expect(environment.hub.sent.last == .init(method: "PUT", path: "/v1/devices/bulb-1/identify", body: #"{"period":5}"#))
        await host.stop()
    }

    @Test func scenesTakePictures() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let picture = "data:image/png;base64," + (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 3, count: 32)).base64EncodedString()
        let saved = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "scene-picture", body: ["id": "scene-1", "data": .string(picture)], user: "admin"))
        #expect(saved.status == 200)
        let scenes = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "scenes", user: "admin"))
        #expect(scenes.json["scenes"]?[0]?["picture"] == saved.json["version"])
        await host.stop()
    }

    /// The Assistant lists the scenes and runs the one it picked, through the actions.
    @Test func theAssistantRunsAScene() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, scenesID)
        let plugin = try #require(environment.plugin)
        let actions = Dictionary(uniqueKeysWithValues: DirigeraPlugin.assistantActions.map { ($0.name, $0) })
        let scenes = try await plugin.handleWebRequest(try #require(actions["list_scenes"]).request(arguments: [:], user: "admin")).json["scenes"]?.arrayValue ?? []
        let movie = try #require(scenes.first { $0["name"] == "Movie night" })
        #expect(movie["icon"] == "scenes_tv")
        let run = try #require(actions["run_scene"]).request(arguments: ["host": movie["host"]!, "id": movie["id"]!], user: "admin")
        #expect(try await plugin.handleWebRequest(run).status == 200)
        #expect(environment.hub.sent.last?.path == "/v1/scenes/scene-1/trigger")
        await host.stop()
    }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(DirigeraPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Dirigera DirigeraPlugin")
        let schema = try JSONValue(string: try #require(DirigeraPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Dirigera")
    }
}
