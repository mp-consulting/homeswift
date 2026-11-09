import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// SmartThings' cloud in memory: canned answers by method and path (a `page` query its own route), every request
/// recorded with when it came, and event streams the test writes to.
final class FakeSmartThings: HTTPSending, HTTPStreaming, Sendable {
    struct Sent: Sendable {
        var method: String
        var path: String
        var query: String?
        var body: JSONValue?
        var form: [String: String]
        var authorization: String?
        var userAgent: String?
        var accept: String?
        var at: ContinuousClock.Instant
    }

    private struct State {
        var routes: [String: [HomeswiftNetwork.HTTPResponse]] = [:]
        var sent: [Sent] = []
        var streams: [AsyncThrowingStream<[UInt8], any Error>.Continuation] = []
        var streamStatus = 200
        var onRequest: (@Sendable (HomeswiftNetwork.HTTPRequest) -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    /// Answers `method path` with `json`; several answers are given in turn, the last one staying.
    func answer(_ method: String, _ path: String, status: Int = 200, _ json: JSONValue = .object([:]), headers: [(name: String, value: String)] = []) {
        state.withLockedValue { $0.routes["\(method) \(path)", default: []].append(HomeswiftNetwork.HTTPResponse(status: status, headers: headers, body: json.encoded())) }
    }

    func reset(_ method: String, _ path: String) { state.withLockedValue { $0.routes["\(method) \(path)"] = nil } }
    func onRequest(_ hook: (@Sendable (HomeswiftNetwork.HTTPRequest) -> Void)?) { state.withLockedValue { $0.onRequest = hook } }
    func setStreamStatus(_ status: Int) { state.withLockedValue { $0.streamStatus = status } }

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    func sent(_ method: String, _ path: String) -> [Sent] { sent.filter { $0.method == method && $0.path == path } }
    func clear() { state.withLockedValue { $0.sent.removeAll() } }
    var streamCount: Int { state.withLockedValue { $0.streams.count } }

    /// Writes server-sent text to the newest stream.
    func push(_ text: String) {
        state.withLockedValue { $0.streams.last }?.yield(Array(text.utf8))
    }

    func endStream() { state.withLockedValue { $0.streams.last }?.finish() }

    private func record(_ request: HomeswiftNetwork.HTTPRequest) -> String {
        let path = request.url.path
        let query = request.url.query
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let form = request.body.map { URLEncoding.fields(String(decoding: $0, as: UTF8.self)) } ?? [:]
        let hook = state.withLockedValue { state -> (@Sendable (HomeswiftNetwork.HTTPRequest) -> Void)? in
            state.sent.append(Sent(method: request.method, path: path, query: query, body: body, form: form, authorization: request.header("Authorization"),
                                   userAgent: request.header("User-Agent"), accept: request.header("Accept"), at: .now))
            return state.onRequest
        }
        hook?(request)
        var key = "\(request.method) \(path)"
        if let page = query.flatMap({ URLEncoding.fields($0)["page"] }) { key += "?page=\(page)" }
        return key
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let key = record(request)
        return state.withLockedValue { state in
            guard var list = state.routes[key], !list.isEmpty else {
                return HomeswiftNetwork.HTTPResponse(status: 404, body: Data(#"{"error":{"code":"NotFoundError"}}"#.utf8))
            }
            let first = list.count > 1 ? list.removeFirst() : list[0]
            state.routes[key] = list
            return first
        }
    }

    func stream(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HTTPStreamingResponse {
        _ = record(request)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        let status = state.withLockedValue { state -> Int in
            if state.streamStatus == 200 { state.streams.append(continuation) }
            return state.streamStatus
        }
        if status != 200 { continuation.finish() }
        return HTTPStreamingResponse(status: status, headers: [("Content-Type", "text/event-stream")], body: HTTPStreamingResponse.Body(stream))
    }
}

enum Fixture {
    static let location = "5f2a6c1e-0000-4000-8000-0000000000a1"
    static let lamp = "0a1b2c3d-0000-4000-8000-0000000000d1"
    static let thermostat = "9b1c2d3e-0000-4000-8000-0000000000d3"
    static let hub = "3e4f0d2c-0000-4000-8000-0000000000d7"
    static let washer = "4a4a4a4a-0000-4000-8000-0000000000d5"
    static let tv = "6d6d6d6d-0000-4000-8000-0000000000d4"
    static let airConditioner = "7a7a7a7a-0000-4000-8000-0000000000d6"
    static let shade = "8a8a8a8a-0000-4000-8000-0000000000d9"
    static let lock = "8b8b8b8b-0000-4000-8000-0000000000da"
    static let security = "8c8c8c8c-0000-4000-8000-0000000000db"
    static let strip = "8d8d8d8d-0000-4000-8000-0000000000dc"
    static let remote = "1e1e1e1e-0000-4000-8000-0000000000d8"
    static let scene = "dddd0000-0000-4000-8000-0000000000e1"
    static let subscription = "eeee0000-0000-4000-8000-0000000000f1"

    static func json(_ text: String) -> JSONValue { try! JSONValue(string: text) }

    /// Page 1 of the device list (docs/clean-room/SmartThings.md, 15.2).
    static let page1 = json("""
        { "items": [
          { "deviceId": "0a1b2c3d-0000-4000-8000-0000000000d1", "name": "c2c-rgbw-color-bulb", "label": "Living Room Lamp",
            "manufacturerName": "SmartThingsCommunity", "presentationId": "c2c-rgbw-color-bulb",
            "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "roomId": "7c7c7c7c-0000-4000-8000-0000000000r1",
            "type": "ZIGBEE", "healthState": { "state": "ONLINE", "lastUpdatedDate": "2026-11-07T09:00:00.000Z" },
            "components": [ { "id": "main", "label": "main", "categories": [ { "name": "Light", "categoryType": "manufacturer" } ],
              "capabilities": [
                { "id": "switch", "version": 1, "status": { "switch": { "value": "on", "timestamp": "2026-11-07T08:59:00.000Z" } } },
                { "id": "switchLevel", "version": 1, "status": { "level": { "value": 72, "unit": "%", "timestamp": "2026-11-07T08:59:00.000Z" } } },
                { "id": "colorControl", "version": 1, "status": { "hue": { "value": 50 }, "saturation": { "value": 80 }, "color": { "value": null } } },
                { "id": "colorTemperature", "version": 1, "status": { "colorTemperature": { "value": 2700, "unit": "K" },
                  "colorTemperatureRange": { "value": { "minimum": 2200, "maximum": 6500 }, "unit": "K" } } },
                { "id": "healthCheck", "version": 1 }, { "id": "refresh", "version": 1 } ] } ] },
          { "deviceId": "9b1c2d3e-0000-4000-8000-0000000000d3", "name": "Thermostat", "label": "Floor Heating",
            "manufacturerName": "Stelpro", "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "type": "ZIGBEE",
            "healthState": { "state": "ONLINE" },
            "components": [ { "id": "main", "categories": [ { "name": "Thermostat", "categoryType": "manufacturer" } ],
              "capabilities": [
                { "id": "temperatureMeasurement", "version": 1, "status": { "temperature": { "value": 68.5, "unit": "F" } } },
                { "id": "thermostatHeatingSetpoint", "version": 1, "status": { "heatingSetpoint": { "value": 70, "unit": "F" } } },
                { "id": "thermostatMode", "version": 1, "status": { "thermostatMode": { "value": "radiatingfloor" },
                  "supportedThermostatModes": { "value": ["off", "heat", "radiatingfloor"] } } },
                { "id": "thermostatOperatingState", "version": 1, "status": { "thermostatOperatingState": { "value": "heating" } } } ] } ] },
          { "deviceId": "3e4f0d2c-0000-4000-8000-0000000000d7", "name": "SmartThings v3 Hub", "label": "Hallway Hub",
            "manufacturerName": "SmartThings", "type": "HUB", "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1",
            "components": [ { "id": "main", "categories": [ { "name": "Hub", "categoryType": "manufacturer" } ], "capabilities": [] } ] }
        ],
        "_links": { "next": { "href": "https://api.smartthings.com/v1/devices?locationId=5f2a6c1e-0000-4000-8000-0000000000a1&includeStatus=true&includeHealth=true&page=2" } } }
        """)

    /// A device list item from components of `(capability, status)`.
    static func item(_ id: String, _ label: String, type: String = "OCF", category: String? = nil, extra: [String: JSONValue] = [:],
                     components: [(String, [(String, JSONValue)])]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "deviceId": .string(id), "label": .string(label), "manufacturerName": "Samsung Electronics", "type": .string(type),
            "locationId": .string(location), "healthState": ["state": "ONLINE"],
            "components": .array(components.map { component, capabilities in
                var entry: [String: JSONValue] = ["id": .string(component),
                    "capabilities": .array(capabilities.map { ["id": .string($0.0), "version": 1, "status": $0.1] })]
                if component == "main", let category { entry["categories"] = [["name": .string(category), "categoryType": "manufacturer"]] }
                return .object(entry)
            }),
        ]
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }

    /// Page 2: the washer of 15.3, the TV of 15.4, an air conditioner, a shade, a lock, a security system, a power strip, a remote.
    static let page2: JSONValue = ["items": .array([
        item(washer, "Washer", components: [("main", [
            ("switch", json(#"{ "switch": { "value": "on" } }"#)),
            ("remoteControlStatus", json(#"{ "remoteControlEnabled": { "value": "true" } }"#)),
            ("washerOperatingState", json(#"{ "machineState": { "value": "run" }, "washerJobState": { "value": "rinse" }, "supportedMachineStates": { "value": ["stop", "run", "pause"] }, "completionTime": { "value": "2026-11-07T10:42:00Z" } }"#)),
            ("washerMode", json(#"{ "washerMode": { "value": "regular" } }"#)),
            ("samsungce.washerOperatingState", json(#"{ "remainingTime": { "value": 42, "unit": "min" } }"#)),
        ])]),
        item(tv, "Living Room TV", category: "Television",
             extra: ["ocf": ["ocfDeviceType": "oic.d.tv", "modelNumber": "QE55Q80", "firmwareVersion": "T-PTMAKUC-1.0"]],
             components: [("main", [
                ("switch", json(#"{ "switch": { "value": "on" } }"#)),
                ("audioVolume", json(#"{ "volume": { "value": 14, "unit": "%" } }"#)),
                ("audioMute", json(#"{ "mute": { "value": "unmuted" } }"#)),
                ("tvChannel", json(#"{ "tvChannel": { "value": "5" }, "tvChannelName": { "value": "" } }"#)),
                ("mediaPlayback", json(#"{ "playbackStatus": { "value": "playing" } }"#)),
                ("keypadInput", json(#"{ "supportedKeyCodes": { "value": ["UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK", "EXIT", "MENU", "HOME"] } }"#)),
                ("samsungvd.mediaInputSource", json(#"{ "inputSource": { "value": "HDMI2" }, "supportedInputSourcesMap": { "value": [ { "id": "dtv", "name": "TV" }, { "id": "HDMI1", "name": "HDMI1" }, { "id": "HDMI2", "name": "PlayStation" }, { "id": "HDMI2", "name": "HDMI2" } ] } }"#)),
                ("custom.launchapp", .null), ("samsungvd.deviceCategory", .null),
             ])]),
        item(airConditioner, "Bedroom AC", components: [("main", [
            ("switch", json(#"{ "switch": { "value": "off" } }"#)),
            ("airConditionerMode", json(#"{ "airConditionerMode": { "value": "cool" }, "supportedAcModes": { "value": ["auto", "cool", "dry", "wind", "heat"] } }"#)),
            ("airConditionerFanMode", json(#"{ "fanMode": { "value": "low" }, "supportedAcFanModes": { "value": ["auto", "low", "medium", "high", "turbo"] } }"#)),
            ("thermostatCoolingSetpoint", json(#"{ "coolingSetpoint": { "value": 24, "unit": "C" } }"#)),
            ("temperatureMeasurement", json(#"{ "temperature": { "value": 26, "unit": "C" } }"#)),
            ("relativeHumidityMeasurement", json(#"{ "humidity": { "value": 48 } }"#)),
        ])]),
        item(shade, "Office Blind", type: "ZIGBEE", components: [("main", [
            ("windowShade", json(#"{ "windowShade": { "value": "partially open" }, "supportedWindowShadeCommands": { "value": ["open", "close", "pause"] } }"#)),
            ("windowShadeLevel", json(#"{ "shadeLevel": { "value": 40 } }"#)),
            ("battery", json(#"{ "battery": { "value": 15 } }"#)),
        ])]),
        item(lock, "Front Door", type: "ZWAVE", components: [("main", [("lock", json(#"{ "lock": { "value": "locked" } }"#))])]),
        item(security, "Alarm Panel", type: "LAN", components: [("main", [
            ("securitySystem", json(#"{ "securitySystemStatus": { "value": "disarmed" }, "supportedSecuritySystemCommands": { "value": ["armAway", "armStay", "disarm"] } }"#)),
        ])]),
        item(strip, "Power Strip", type: "ZIGBEE", components: [
            ("main", [("switch", json(#"{ "switch": { "value": "on" } }"#))]),
            ("outlet1", [("switch", json(#"{ "switch": { "value": "off" } }"#))]),
            ("outlet2", [("switch", json(#"{ "switch": { "value": "off" } }"#))]),
        ]),
        item(remote, "Hall Remote", type: "ZIGBEE", components: [
            ("main", [("button", json(#"{ "button": { "value": "pushed" } }"#)), ("battery", json(#"{ "battery": { "value": 90 } }"#))]),
            ("button1", [("button", json(#"{ "button": { "value": "pushed", "timestamp": "2026-11-07T08:00:00.000Z" }, "supportedButtonValues": { "value": ["pushed", "double", "held"] } }"#))]),
            ("button2", [("button", json(#"{ "button": { "value": "pushed" }, "supportedButtonValues": { "value": ["pushed", "held"] } }"#))]),
        ]),
    ]), "_links": [:]]

    /// 15.6.
    static let scenes = json("""
        { "items": [ { "sceneId": "dddd0000-0000-4000-8000-0000000000e1", "sceneName": "Good Night", "sceneIcon": "204", "sceneColor": null,
          "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "editable": false, "apiVersion": "" } ], "_links": {} }
        """)

    /// 15.1.
    static let tokens = json("""
        { "access_token": "11111111-1111-4111-8111-111111111111", "token_type": "bearer", "refresh_token": "22222222-2222-4222-8222-222222222222",
          "expires_in": 86399, "scope": "r:devices:* x:devices:* r:locations:* r:scenes:* x:scenes:* sse", "access_tier": 0,
          "installed_app_id": "33333333-3333-4333-8333-333333333333" }
        """)
}

/// A host with the plugin on the fake cloud, signed in.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-SmartThings-tests-\(UUID().uuidString)")
    let cloud = FakeSmartThings()
    let now: Date
    private let plugins = NIOLockedValueBox<[SmartThingsPlugin]>([])
    private let contextBox = NIOLockedValueBox<PluginContext?>(nil)
    /// Tokens put in the vault before the plugin starts; nil leaves it empty.
    let seeded: StoredTokens?
    let deviceLimiter: RateLimiter?
    let watchdogSeconds: Double
    /// The plugin's clock: 0.001 makes a minute 60 ms.
    let scale: Double

    /// `sse`: the seeded tokens grant the event stream. `watchdogSeconds`: a silence that long ends a stream (scaled: 5000
    /// is 5 s).
    init(sse: Bool = false, signedIn: Bool = true, deviceLimiter: RateLimiter? = nil, watchdogSeconds: Double = 5000, scale: Double = 0.001,
         now: Date = SmartThingsDates.parse("2026-11-07T10:00:00Z")!) {
        self.scale = scale
        self.now = now
        self.deviceLimiter = deviceLimiter
        self.watchdogSeconds = watchdogSeconds
        if signedIn {
            var tokens = StoredTokens(accessToken: "11111111-1111-4111-8111-111111111111", refreshToken: "22222222-2222-4222-8222-222222222222",
                                      expiresIn: 86399, now: now)
            tokens.scope = "r:devices:* x:devices:* r:locations:* r:scenes:* x:scenes:*" + (sse ? " sse" : "")
            seeded = tokens
        } else {
            seeded = nil
        }
        cloud.answer("GET", "/v1/locations", ["items": [["locationId": .string(Fixture.location), "name": "Home"]], "_links": [:]])
        cloud.answer("GET", "/v1/devices", Fixture.page1)
        cloud.answer("GET", "/v1/devices?page=2", Fixture.page2)
        cloud.answer("GET", "/v1/scenes", Fixture.scenes)
        cloud.answer("GET", "/v1/locations/\(Fixture.location)/rooms", ["items": [["roomId": "7c7c7c7c-0000-4000-8000-0000000000r1", "name": "Living Room"]]])
        cloud.answer("POST", "/v1/scenes/\(Fixture.scene)/execute", ["status": "success"])
        for id in [Fixture.lamp, Fixture.thermostat, Fixture.washer, Fixture.tv, Fixture.airConditioner, Fixture.shade, Fixture.lock, Fixture.security, Fixture.strip] {
            cloud.answer("POST", "/v1/devices/\(id)/commands", ["results": [["id": "c1", "status": "ACCEPTED"]]])
        }
        cloud.answer("POST", "/v1/sse/subscriptions", [
            "subscriptionId": .string(Fixture.subscription),
            "registrationUrl": .string("https://sse.example.invalid/v1/sse/subscriptions/\(Fixture.subscription)/stream?token=REDACTED"),
            "version": 1, "name": "homeswift-SmartThings",
        ])
        cloud.answer("DELETE", "/v1/sse/subscriptions/\(Fixture.subscription)")
    }

    var plugin: SmartThingsPlugin? { plugins.withLockedValue { $0.last } }
    var context: PluginContext { contextBox.withLockedValue { $0! } }

    nonisolated(unsafe) static let block: [String: Any] = [
        "client_id": "7a850484-0000-4000-8000-000000000001", "client_secret": "3581f317-0000-4000-8000-000000000002", "locationId": Fixture.location,
    ]

    func start(settings: [String: Any] = TestEnvironment.block, accessories: [String: Any]? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        let cloud = cloud, seeded = seeded, now = now, limiter = deviceLimiter, watchdog = watchdogSeconds, scale = scale
        registry.register(platform: SmartThingsPlugin.platform, name: SmartThingsPlugin.name) { json, context in
            self.contextBox.withLockedValue { $0 = context }
            if let seeded { try context.secretFile(SmartThingsPlugin.tokenFileName, as: StoredTokens.self).save(seeded) }
            var dependencies = SmartThingsPlugin.Dependencies()
            dependencies.transport = cloud
            dependencies.streaming = cloud
            dependencies.timing = SmartThingsTiming(scale: scale)
            dependencies.now = { now }
            dependencies.addresses = { ["192.0.2.10"] }
            dependencies.deviceLimiter = limiter
            dependencies.callbackBindAddress = "127.0.0.1"
            dependencies.watchdogSeconds = watchdog
            let configuration = try JSONDecoder().decode(SmartThingsPlugin.Configuration.self, from: json)
            let plugin = SmartThingsPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        var settings = settings
        if let accessories { settings["_accessories"] = accessories }
        let block = try HomeswiftConfiguration.Platform(platform: SmartThingsPlugin.platform, name: SmartThingsPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// The tokens in the vault now.
    var vaultTokens: StoredTokens? { context.secretFile(SmartThingsPlugin.tokenFileName, as: StoredTokens.self).load() }
}

extension PluginHost {
    func accessory(_ deviceID: String) -> Accessory? {
        let id = SmartThingsPlugin.accessoryID(deviceID)
        return bridges.lazy.flatMap(\.server.accessories).first { $0.id == id }
    }
}

extension Accessory {
    func service(subtype: String) -> Service? { services.first { $0.subtype == subtype } }
}

/// Polls `condition` until it holds or `timeout` passes: generous, as a loaded CI runner can stall the whole process (a
/// reconnect after a silent stream took longer than 5 s on one), and a condition that holds returns at once.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Writes a characteristic as HomeKit would, through its handler.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    let characteristic = try #require(characteristic)
    let handler = try #require(characteristic.writeHandler(for: value))
    try await handler(value)
    characteristic.value = value
}
