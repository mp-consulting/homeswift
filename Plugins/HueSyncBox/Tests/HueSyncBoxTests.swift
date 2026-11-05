import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftHueSyncBox

typealias HTTPRequest = HomeswiftNetwork.HTTPRequest
typealias HTTPResponse = HomeswiftNetwork.HTTPResponse

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// The state of section 8 (invented ids).
let vectorState = """
    { "device": { "name": "Lounge Sync Box", "deviceType": "HSB2", "uniqueId": "A1B2C3D4E5F6",
                  "apiLevel": 10, "firmwareVersion": "2.4.2", "ipAddress": "192.0.2.50",
                  "wifi": { "ssid": "ExampleNet", "strength": 3 } },
      "hue": { "bridgeUniqueId": "B00000000001", "bridgeIpAddress": "192.0.2.10",
               "groupId": "22222222-0000-4000-8000-000000000002",
               "groups": { "11111111-0000-4000-8000-000000000001": { "name": "TV area", "numLights": 3, "active": false },
                           "22222222-0000-4000-8000-000000000002": { "name": "cinema", "numLights": 5, "active": true } },
               "connectionState": "streaming" },
      "execution": { "mode": "music", "syncActive": true, "hdmiActive": true, "hdmiSource": "input3",
                     "hueTarget": "22222222-0000-4000-8000-000000000002", "brightness": 150,
                     "lastSyncMode": "music",
                     "video": { "intensity": "moderate", "backgroundLighting": true },
                     "game":  { "intensity": "intense",  "backgroundLighting": false },
                     "music": { "intensity": "high", "palette": "happyEnergetic" }, "preset": null },
      "hdmi": { "input1": { "name": "Apple TV", "type": "appletv", "status": "linked", "lastSyncMode": "video" },
                "input2": { "name": "HDMI 2", "type": "generic", "status": "unplugged", "lastSyncMode": "video" },
                "input3": { "name": "console", "type": "playstation", "status": "linked", "lastSyncMode": "game" },
                "input4": { "name": "HDMI 4", "type": "generic", "status": "unplugged", "lastSyncMode": "video" } } }
    """

/// A Sync Box in memory: the state, the writes it takes (merged into the state as the box merges them), its button.
final class FakeSyncBox: HTTPSending, Sendable {
    struct Sent: Sendable {
        var method: String
        var path: String
        var body: JSONValue?
        var authorization: String?
    }

    private struct State {
        var json: JSONValue
        var sent: [Sent] = []
        var failing = false
        var buttonPressed = false
        var token = "EXAMPLE-TOKEN-0123456789abcdef"
    }

    private let box: NIOLockedValueBox<State>

    init(state: String = vectorState) {
        box = NIOLockedValueBox(State(json: try! JSONValue(string: state)))
    }

    var sent: [Sent] { box.withLockedValue { $0.sent } }
    var reads: Int { sent.filter { $0.method == "GET" }.count }
    var writes: [Sent] { sent.filter { $0.method == "PUT" } }
    func failing(_ failing: Bool) { box.withLockedValue { $0.failing = failing } }
    func pressButton() { box.withLockedValue { $0.buttonPressed = true } }
    func update(_ change: (inout JSONValue) -> Void) { box.withLockedValue { change(&$0.json) } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let path = request.url.path
        let authorization = request.headers.first { $0.name.lowercased() == "authorization" }?.value
        return try box.withLockedValue { state in
            state.sent.append(Sent(method: request.method, path: path, body: body, authorization: authorization))
            if state.failing { throw HTTPClientError.timeout }
            if request.method == "POST", path == "/api/v1/registrations" {
                guard state.buttonPressed else { return Self.error(400, code: 16, "Invalid State") }
                return HTTPResponse(status: 200, body: JSONValue.object(["registrationId": "7", "accessToken": .string(state.token)]).encoded())
            }
            guard authorization == "Bearer \(state.token)" else { return Self.error(401, code: 2, "Unauthorized") }
            switch (request.method, path) {
            case ("GET", "/api/v1"), ("GET", "/api/v1/"):
                return HTTPResponse(status: 200, body: state.json.encoded())
            case ("PUT", "/api/v1/execution"):
                Self.merge(body ?? [:], into: &state.json, at: "execution")
                return HTTPResponse(status: 200, body: Data("{}".utf8))
            case ("PUT", "/api/v1/hue"):
                Self.merge(body ?? [:], into: &state.json, at: "hue")
                return HTTPResponse(status: 200, body: Data("{}".utf8))
            default:
                return Self.error(404, code: 10, "Not found")
            }
        }
    }

    static func error(_ status: Int, code: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: JSONValue.object(["code": .number(Double(code)), "message": .string(message)]).encoded())
    }

    static func merge(_ change: JSONValue, into json: inout JSONValue, at key: String) {
        guard var root = json.objectValue, var section = root[key]?.objectValue else { return }
        for (field, value) in change.objectValue ?? [:] {
            if let inner = value.objectValue, var existing = section[field]?.objectValue {
                existing.merge(inner) { $1 }
                section[field] = .object(existing)
            } else {
                section[field] = value
            }
        }
        root[key] = .object(section)
        json = .object(root)
    }
}

/// A host with one block whose plugin talks to `box`, its timings a hundredth of the real ones.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-HueSyncBox-tests-\(UUID().uuidString)")
    let box = FakeSyncBox()
    let found = NIOLockedValueBox<[SyncBoxDiscovery.Box]>([])
    let tls = NIOLockedValueBox<[HTTPClient.TLS]>([])
    private let plugins = NIOLockedValueBox<[HueSyncBoxPlugin]>([])
    /// The brightness guard's wait, when a test needs one longer than its writes take on a loaded machine.
    let sliderRest: Duration?

    init(sliderRest: Duration? = nil) { self.sliderRest = sliderRest }

    static var block: [String: Any] { [
        "syncBoxIpAddress": "192.0.2.50", "syncBoxApiAccessToken": "EXAMPLE-TOKEN-0123456789abcdef",
        "powerSwitchAccessory": true, "tvAccessory": true, "modeTvAccessory": true, "intensityTvAccessory": true,
        "entertainmentTvAccessory": true, "tvAccessoryLightbulb": true, "updateIntervalInSeconds": 5,
    ] }

    var plugin: HueSyncBoxPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: HueSyncBoxPlugin.Dependencies {
        let box = box, found = found, tls = tls
        return HueSyncBoxPlugin.Dependencies(
            transport: { mode in
                tls.withLockedValue { $0.append(mode) }
                return box
            },
            browse: { _ in
                AsyncStream { continuation in
                    for box in found.withLockedValue({ $0 }) { continuation.yield(box) }
                    continuation.finish()
                }
            },
            discoveryWindow: .milliseconds(100), timeScale: 0.01, sliderRest: sliderRest)
    }

    func start(settings: [String: Any] = TestEnvironment.block, credentials: HueSyncBoxPlugin.Registration? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies
        registry.register(platform: HueSyncBoxPlugin.platform, name: HueSyncBoxPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(HueSyncBoxPlugin.Configuration.self, from: json)
            let plugin = HueSyncBoxPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: HueSyncBoxPlugin.platform, name: HueSyncBoxPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        if let credentials {
            try host.context(platform: HueSyncBoxPlugin.platform, name: HueSyncBoxPlugin.name)?.saveCredentials(credentials)
        }
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func id(_ kind: SyncBoxKind, seed: String = "") -> String { HueSyncBoxPlugin.accessoryID(deviceID: kind.deviceID(seed: seed)) }

/// Every accessory of the host, bridged or on a server of its own.
func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
    #expect(await eventually { host.bridges.contains { $0.server.accessories.contains { $0.id == id } } }, "no \(id)")
    return try #require(host.bridges.lazy.compactMap { $0.server.accessories.first { $0.id == id } }.first)
}

/// Writes `value` as HomeKit would.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    let characteristic = try #require(characteristic)
    if let handler = characteristic.writeHandler(for: value) { try await handler(value) }
    characteristic.value = value
}

@Suite(.timeLimit(.minutes(1)))
struct HueSyncBoxStateTests {
    let state = try! SyncBoxState.parse(Data(vectorState.utf8))

    @Test func readsTheStateOfSection8() {
        #expect(state.name == "Lounge Sync Box" && state.uniqueID == "A1B2C3D4E5F6" && state.firmwareVersion == "2.4.2")
        #expect(state.mode == "music" && state.isSyncing && state.hdmiSource == 3 && state.brightness == 150)
        #expect(state.intensities == ["video": "moderate", "game": "intense", "music": "high"])
        #expect(state.areas.map(\.name) == ["TV area", "cinema"])
        #expect(state.inputNames == ["Apple TV", "HDMI 2", "console", "HDMI 4"])
    }

    /// The areas keep the order of the keys as the box sent them, not a sorted one.
    @Test func keepsTheAreasInTheBoxsOrder() throws {
        let reversed = vectorState.replacingOccurrences(
            of: #""11111111-0000-4000-8000-000000000001": { "name": "TV area", "numLights": 3, "active": false },"#, with: "")
            .replacingOccurrences(of: #""active": true } },"#, with: #""active": true }, "11111111-0000-4000-8000-000000000001": { "name": "TV \"area\"", "numLights": 3, "active": false } },"#)
        let state = try SyncBoxState.parse(Data(reversed.utf8))
        #expect(state.areas.map(\.name) == ["cinema", "TV \"area\""])
        #expect(SyncBoxKind.entertainmentTV.activeIdentifier(in: state) == 1)
    }

    /// The key-order scan reads only the top-level `hue.groups`, and ends on anything: truncated, nested, escaped.
    @Test func theGroupScanIsBounded() {
        let decoy = #"{"device": {"x": {"hue": {"groups": {"b": 1}}}}, "hue": {"groups": {"a": {}, "b\"\\": {}}}, "arr": [{"hue": {"groups": {"c": 1}}}]}"#
        #expect(GroupOrder.keys(in: Data(decoy.utf8)) == ["a", "b\"\\"])
        let bytes = Array(vectorState.utf8)
        for end in stride(from: 0, to: bytes.count, by: 7) {
            _ = GroupOrder.keys(in: Data(bytes[..<end]))
        }
        for broken in ["", "{", "{\"", "\"\\", "{\"hue\":{\"groups\":{\"a\"", "[,,,]", "{\"a\":}", String(repeating: "[", count: 10_000), String(repeating: "{\"a\":", count: 10_000)] {
            _ = GroupOrder.keys(in: Data(broken.utf8))
        }
    }

    @Test func refusesWhatDoesNotValidate() {
        for broken in [
            vectorState.replacingOccurrences(of: #""hdmiSource": "input3""#, with: #""hdmiSource": "input5""#),
            vectorState.replacingOccurrences(of: #""brightness": 150"#, with: #""brightness": 250"#),
            vectorState.replacingOccurrences(of: #""name": "console""#, with: #""name": """#),
            vectorState.replacingOccurrences(of: #""uniqueId": "A1B2C3D4E5F6","#, with: ""),
            "[]", "not json",
        ] {
            #expect(throws: SyncBoxError.self) { try SyncBoxState.parse(Data(broken.utf8)) }
        }
        #expect(throws: SyncBoxError.self) { try SyncBoxState.parse(Data(repeating: 0x20, count: 100_001)) }
    }

    @Test func convertsBrightness() {
        #expect([0, 1, 50, 100].map(SyncBoxMapping.boxBrightness) == [0, 2, 100, 200])
        #expect([0, 1, 99, 100, 150, 199, 200].map(SyncBoxMapping.homeKitBrightness) == [0, 1, 50, 50, 75, 100, 100])
    }

    /// The remote's keys from the state of section 8, and the arrows in passthrough.
    @Test func remoteKeys() throws {
        let mapping = SyncBoxMapping()
        #expect(mapping.remoteKey(4, state: state) == .execution(["brightness": 200]))
        #expect(mapping.remoteKey(5, state: state) == .execution(["brightness": 100]))
        #expect(mapping.remoteKey(7, state: state) == .execution(["music": ["intensity": "intense"]]))
        #expect(mapping.remoteKey(6, state: state) == .execution(["music": ["intensity": "moderate"]]))
        #expect(mapping.remoteKey(8, state: state) == .execution(["mode": "game"]))
        #expect(mapping.remoteKey(11, state: state) == .execution(["mode": "passthrough"]))
        #expect(mapping.remoteKey(15, state: state) == .execution(["hdmiSource": "input4"]))
        #expect(mapping.remoteKey(9, state: state) == nil)

        var passthrough = state
        passthrough.mode = "passthrough"
        passthrough.lastSyncMode = "video"
        #expect(mapping.remoteKey(7, state: passthrough) == .execution(["video": ["intensity": "high"]]))
        #expect(mapping.remoteKey(8, state: passthrough) == .execution(["mode": "video"]))
        var powersave = state
        powersave.mode = "powersave"
        #expect(mapping.remoteKey(8, state: powersave) == .execution(["mode": "music"]))
        var top = state
        top.intensities["music"] = "intense"
        #expect(mapping.remoteKey(7, state: top) == nil)
    }

    @Test func modesAndActive() {
        var state = state
        state.mode = "passthrough"
        state.lastSyncMode = ""
        #expect(SyncBoxMapping(onMode: "lastSyncMode").write(on: true, state: state) == .mode("video"))
        state.lastSyncMode = "music"
        #expect(SyncBoxMapping(onMode: "lastSyncMode").write(on: true, state: state) == .mode("music"))
        #expect(SyncBoxMapping(offMode: "powersave").write(on: false, state: state) == .mode("powersave"))
        #expect(SyncBoxMapping().isActive(state))
        #expect(!SyncBoxMapping(treatPassthroughAsOffForTV: true).isActive(state))
        state.mode = "powersave"
        #expect(!SyncBoxMapping().isActive(state))
    }

    @Test func theRootCertificateIsPhilipss() throws {
        let base64 = SyncBoxCertificate.rootPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try #require(Data(base64Encoded: base64))
        #expect(HTTPClient.fingerprint(der: [UInt8](der)) == HTTPClient.normalizeFingerprint(SyncBoxCertificate.rootFingerprint))
        #expect(SyncBoxCertificate.tls(uniqueID: "A1B2C3D4E5F6") == .authority(pem: SyncBoxCertificate.rootPEM, serverName: "A1B2C3D4E5F6"))
        #expect(SyncBoxCertificate.tls(uniqueID: "") == .authority(pem: SyncBoxCertificate.rootPEM, serverName: nil))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SyncBoxClientTests {
    final class Flaky: HTTPSending, Sendable {
        let answers: NIOLockedValueBox<[Result<HTTPResponse, HTTPClientError>]>
        let count = NIOLockedValueBox(0)
        init(_ answers: [Result<HTTPResponse, HTTPClientError>]) { self.answers = NIOLockedValueBox(answers) }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            count.withLockedValue { $0 += 1 }
            return try answers.withLockedValue { $0.isEmpty ? .failure(.timeout) : $0.removeFirst() }.get()
        }
    }

    @Test func retriesTransportFailuresButNotAnswers() async throws {
        // A budget no machine runs out of: the fakes fail at once, and what this proves is which failures are retried and
        // how often (the budget has its own test).
        let timing = SyncBoxClient.Timing(attempt: .milliseconds(100), budget: .seconds(50), retryDelays: [.milliseconds(1), .milliseconds(2), .milliseconds(4)], lockWait: .seconds(1))
        let flaky = Flaky([.failure(.timeout), .failure(.connectionClosed), .success(HTTPResponse(status: 200, body: Data(vectorState.utf8)))])
        let client = try #require(SyncBoxClient(address: "192.0.2.50", token: "t", transport: flaky, timing: timing, logger: testLogger))
        #expect(try await client.state().name == "Lounge Sync Box")
        #expect(flaky.count.withLockedValue { $0 } == 3)

        let refused = Flaky([.success(FakeSyncBox.error(401, code: 1, "Unauthorized"))])
        let other = try #require(SyncBoxClient(address: "192.0.2.50", token: "t", transport: refused, timing: timing, logger: testLogger))
        await #expect { try await other.state() } throws: { ($0 as? SyncBoxError)?.isUnauthorized == true }
        #expect(refused.count.withLockedValue { $0 } == 1)

        // Three retries at most.
        let down = Flaky([])
        let gone = try #require(SyncBoxClient(address: "192.0.2.50", token: "t", transport: down, timing: timing, logger: testLogger))
        await #expect(throws: HTTPClientError.timeout) { try await gone.state() }
        #expect(down.count.withLockedValue { $0 } == 4)
    }

    /// No retry that would start past the budget.
    @Test func retriesWithinTheBudget() async throws {
        let timing = SyncBoxClient.Timing(attempt: .milliseconds(100), budget: .milliseconds(50), retryDelays: [.seconds(10)], lockWait: .seconds(1))
        let down = Flaky([])
        let client = try #require(SyncBoxClient(address: "192.0.2.50", token: "t", transport: down, timing: timing, logger: testLogger))
        await #expect(throws: HTTPClientError.timeout) { try await client.state() }
        #expect(down.count.withLockedValue { $0 } == 1)
    }

    @Test func buildsTheBaseURL() {
        #expect(SyncBoxClient.baseURL("192.0.2.50")?.absoluteString == "https://192.0.2.50/api/v1/")
        #expect(SyncBoxClient.baseURL("192.0.2.50:8443")?.absoluteString == "https://192.0.2.50:8443/api/v1/")
        #expect(SyncBoxClient.baseURL("fe80::1")?.absoluteString == "https://[fe80::1]/api/v1/")
        #expect(SyncBoxClient.baseURL("") == nil)
        #expect(SyncBoxClient.baseURL("a/b") == nil)
        #expect(SyncBoxClient.baseURL("192.0.2.50#x") == nil && SyncBoxClient.baseURL("192.0.2.50?x") == nil && SyncBoxClient.baseURL("u@192.0.2.50") == nil)
    }

    /// Requests go one at a time: the second waits for the first.
    @Test func sendsOneRequestAtATime() async throws {
        final class Slow: HTTPSending, Sendable {
            let inFlight = NIOLockedValueBox((now: 0, most: 0))
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                inFlight.withLockedValue { $0.now += 1; $0.most = max($0.most, $0.now) }
                try await Task.sleep(for: .milliseconds(20))
                inFlight.withLockedValue { $0.now -= 1 }
                return HTTPResponse(status: 200, body: Data(vectorState.utf8))
            }
        }
        let slow = Slow()
        let client = try #require(SyncBoxClient(address: "192.0.2.50", token: "t", transport: slow, logger: testLogger))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try? await client.state() } }
        }
        #expect(slow.inFlight.withLockedValue { $0.most } == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HueSyncBoxTests {
    let environment = TestEnvironment()

    @Test func theExampleBlockDecodes() throws {
        let json = #"""
            { "platform": "PhilipsHueSyncBoxPlatform", "name": "Living Room Sync Box",
              "syncBoxIpAddress": "192.168.1.50", "syncBoxApiAccessToken": "<token>",
              "defaultOnMode": "lastSyncMode", "defaultOffMode": "passthrough",
              "baseAccessory": "lightbulb", "powerSwitchAccessory": true,
              "tvAccessory": true, "tvAccessoryType": "settopbox", "tvAccessoryLightbulb": false,
              "modeTvAccessory": true, "intensityTvAccessory": false, "entertainmentTvAccessory": true,
              "treatPassthroughAsOffForTv": false, "updateIntervalInSeconds": 5, "uuidSeed": "LivingRoom" }
            """#
        let configuration = try JSONDecoder().decode(HueSyncBoxPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.kinds == [.lightbulb, .power, .hdmiTV, .modeTV, .entertainmentTV])
        #expect(configuration.mapping == SyncBoxMapping(onMode: "lastSyncMode", offMode: "passthrough"))
        #expect(SyncBoxKind.lightbulb.deviceID(seed: configuration.uuidSeed) == "LightBulbAccessoryLivingRoom")
        let minimal = try JSONDecoder().decode(HueSyncBoxPlugin.Configuration.self, from: Data(#"{"platform":"PhilipsHueSyncBoxPlatform","baseAccessory":"none"}"#.utf8))
        #expect(minimal.kinds.isEmpty && minimal.syncBoxIpAddress == nil)
    }

    /// A block without a box costs nothing: no request, no accessory.
    @Test func anEmptyBlockDoesNothing() async throws {
        let host = try await environment.start(settings: [:])
        try await Task.sleep(for: .milliseconds(200))
        #expect(environment.box.sent.isEmpty)
        #expect(host.bridges.count == 1 && host.mainBridge.server.accessories.count == 1)
        #expect(await environment.plugin?.accountAuthorized() == false)
        await host.stop()
    }

    /// Section 8's expected values, with the defaults.
    @Test func showsTheStateOfSection8() async throws {
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.state != nil })
        let light = try await accessory(host, id(.lightbulb))
        #expect(light.service(.lightbulb)?[.on]?.value == true)
        #expect(light.service(.lightbulb)?[.brightness]?.value == 75)
        #expect(light.information[.serialNumber]?.value == "A1B2C3D4E5F6")
        #expect(light.information[.manufacturer]?.value == "Philips" && light.information[.model]?.value == "Sync Box")
        let power = try await accessory(host, id(.power))
        #expect(power.service(.switch)?[.on]?.value == true)
        #expect(power.information[.serialNumber]?.value == "A1B2C3D4E5F6-power")
        #expect(power.name == "Lounge Sync Box Power")

        let hdmi = try await accessory(host, id(.hdmiTV))
        #expect(host.mainBridge.server.accessories.first { $0.id == id(.hdmiTV) } == nil, "a television has its own server")
        let tv = try #require(hdmi.service(.television, subtype: "TV"))
        #expect(tv[.active]?.value == 1 && tv[.activeIdentifier]?.value == 3)
        #expect(tv.linked.map { $0.subtype } == ["HDMI 1", "HDMI 2", "HDMI 3", "HDMI 4"])
        #expect(tv.linked.map { $0[.configuredName]?.value } == ["Apple TV", "HDMI 2", "Console", "HDMI 4"])
        #expect(tv.linked.map { $0[.name]?.value } == ["hdmi1", "hdmi2", "hdmi3", "hdmi4"])
        #expect(hdmi.service(.lightbulb)?[.brightness]?.value == 75)
        #expect(hdmi.information[.serialNumber]?.value == "A1B2C3D4E5F6-T")

        let mode = try #require(try await accessory(host, id(.modeTV)).service(.television, subtype: "ModeAccessory"))
        #expect(mode[.activeIdentifier]?.value == 2)
        #expect(mode.linked.map { $0.subtype } == ["MODE 1", "MODE 2", "MODE 3", "MODE 4", "MODE 5"])
        let intensity = try #require(try await accessory(host, id(.intensityTV)).service(.television, subtype: "IntensityTVAccessory"))
        #expect(intensity[.activeIdentifier]?.value == 3)
        let area = try await accessory(host, id(.entertainmentTV))
        let areas = try #require(area.service(.television, subtype: "EntertainmentTVAccessory"))
        #expect(areas.linked.map { $0[.configuredName]?.value } == ["TV area", "Cinema"])
        #expect(areas[.activeIdentifier]?.value == 2)
        #expect(area.information[.serialNumber]?.value == "A1B2C3D4E5F6-E")
        #expect(area.category == .television)
        await host.stop()
    }

    /// The writes of section 8's table reach the box with their bodies, and a write is followed by a read.
    @Test func writesReachTheBox() async throws {
        var settings = TestEnvironment.block
        settings["defaultOnMode"] = "lastSyncMode"
        let host = try await environment.start(settings: settings)
        let box = environment.box
        let light = try await accessory(host, id(.lightbulb))
        #expect(await eventually { await environment.plugin?.state != nil })
        func lastWrite(_ count: Int) async -> FakeSyncBox.Sent? {
            guard await eventually({ box.writes.count >= count }) else { return nil }
            return box.writes[count - 1]
        }

        try await write(light.service(.lightbulb)?[.on], false)
        #expect(await lastWrite(1)?.body == ["mode": "passthrough"])
        #expect(await eventually { await environment.plugin?.state?.mode == "passthrough" })
        try await write(light.service(.lightbulb)?[.on], true)
        #expect(await lastWrite(2)?.body == ["mode": "music"])
        try await write(light.service(.lightbulb)?[.brightness], 40)
        #expect(await lastWrite(3)?.body == ["brightness": 80])

        let hdmi = try #require(try await accessory(host, id(.hdmiTV)).service(.television, subtype: "TV"))
        try await write(hdmi[.activeIdentifier], 1)
        #expect(await lastWrite(4)?.body == ["hdmiSource": "input1"])
        try await write(hdmi[.activeIdentifier], 7)
        let mode = try #require(try await accessory(host, id(.modeTV)).service(.television, subtype: "ModeAccessory"))
        try await write(mode[.activeIdentifier], 3)
        #expect(await lastWrite(5)?.body == ["mode": "game"], "7 sends nothing")
        let areas = try #require(try await accessory(host, id(.entertainmentTV)).service(.television, subtype: "EntertainmentTVAccessory"))
        try await write(areas[.activeIdentifier], 1)
        let area = await lastWrite(6)
        #expect(area?.path == "/api/v1/hue" && area?.body == ["groupId": "11111111-0000-4000-8000-000000000001"])
        #expect(box.writes.allSatisfy { $0.authorization == "Bearer EXAMPLE-TOKEN-0123456789abcdef" })

        let power = try await accessory(host, id(.power))
        try await write(power.service(.switch)?[.on], false)
        #expect(await lastWrite(7)?.body == ["mode": "powersave"])
        // The read after it shows what follows from it: every television is off.
        #expect(await eventually { hdmi[.active]?.value == 0 })
        await host.stop()
    }

    /// One read per cycle for all the accessories, and a brightness drag is one request.
    @Test func pollsOncePerCycleAndCoalescesSliders() async throws {
        // A slider's rest longer than the gap between two of six writes on a loaded machine: a gap longer than the rest
        // sends the value before it.
        let environment = TestEnvironment(sliderRest: .seconds(1))
        let host = try await environment.start()
        let box = environment.box
        let light = try await accessory(host, id(.lightbulb))
        #expect(await eventually { await environment.plugin?.state != nil })
        let interval = try #require(await environment.plugin?.interval)
        let clock = ContinuousClock()
        let started = clock.now
        let start = box.reads
        #expect(await eventually { box.reads - start >= 3 })
        let elapsed = clock.now - started
        let reads = box.reads - start
        // A cycle at most every interval (50 ms): one read each, however slow the machine; one per accessory would be
        // seven at once.
        let cycles = Int(elapsed / interval) + 1
        #expect(reads <= cycles, "\(reads) reads in \(elapsed), \(cycles) cycles at most")
        let brightness = light.service(.lightbulb)?[.brightness]
        for value in stride(from: 10, through: 60, by: 10) { try await write(brightness, .int(value)) }
        #expect(await eventually { box.writes.count == 1 })
        // The first write to go out is the last value: the earlier ones are no longer the latest when their turns come.
        #expect(box.writes.map(\.body) == [["brightness": 120]])
        await host.stop()
    }

    /// Unreachable after three failed polls, logged once; back when the box answers.
    @Test func showsNoResponseWhileTheBoxIsGone() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, id(.lightbulb))
        #expect(await eventually { await environment.plugin?.state != nil })
        environment.box.failing(true)
        #expect(await eventually { light.isUnreachable })
        environment.box.failing(false)
        environment.box.update { FakeSyncBox.merge(["mode": "passthrough"], into: &$0, at: "execution") }
        #expect(await eventually { !light.isUnreachable && light.service(.lightbulb)?[.on]?.value == false })
        await host.stop()
    }

    /// The certificate is checked against the root, and against the box's name once the state told it.
    @Test func learnsTheBoxsNameForItsCertificate() async throws {
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.learnedUniqueID == "A1B2C3D4E5F6" })
        let modes = environment.tls.withLockedValue { $0 }
        #expect(modes.first == .authority(pem: SyncBoxCertificate.rootPEM, serverName: nil))
        #expect(modes.last == .authority(pem: SyncBoxCertificate.rootPEM, serverName: "A1B2C3D4E5F6"))
        let block = await environment.plugin?.canonicalSettings(["platform": "PhilipsHueSyncBoxPlatform"])
        #expect(block?["syncBoxUniqueId"] == "A1B2C3D4E5F6")
        await host.stop()
    }

    /// Setup asks for the button until the box takes the registration, sent without a token; the token goes to the
    /// vault, the address and the box's name to the block, and the plugin then runs on them.
    @Test func setUpPressesTheButton() async throws {
        environment.found.withLockedValue { $0 = [SyncBoxDiscovery.Box(name: "Lounge Sync Box", uniqueID: "A1B2C3D4E5F6", address: "192.0.2.50")] }
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, let state) = first else { Issue.record("expected the button"); return }
        #expect(prompt.waitSeconds == 60 && prompt.retryAfter == 1)
        #expect(state["address"] == "192.0.2.50" && state["uniqueId"] == "A1B2C3D4E5F6")
        let registration = try #require(environment.box.sent.first)
        #expect(registration.method == "POST" && registration.path == "/api/v1/registrations" && registration.authorization == nil)
        #expect(registration.body == ["appName": "homeswift", "instanceName": "Homeswift"])
        #expect(environment.tls.withLockedValue { $0.last } == .authority(pem: SyncBoxCertificate.rootPEM, serverName: "A1B2C3D4E5F6"))

        environment.box.pressButton()
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, state: state)) else {
            Issue.record("expected done")
            return
        }
        #expect(outcome.credentials?["accessToken"] == "EXAMPLE-TOKEN-0123456789abcdef")
        #expect(outcome.credentials?["registrationId"] == "7")
        #expect(outcome.settings["syncBoxIpAddress"] == "192.0.2.50")
        #expect(outcome.settings["syncBoxUniqueId"] == "A1B2C3D4E5F6")
        #expect(outcome.settings["uuidSeed"] == "A1B2C3D4E5F6")
        #expect(outcome.settings["syncBoxApiAccessToken"] == .null)
        await host.stop()

        // The plugin as the bridge starts it after Setup.
        let settings: [String: Any] = ["syncBoxIpAddress": "192.0.2.50", "syncBoxUniqueId": "A1B2C3D4E5F6", "uuidSeed": "A1B2C3D4E5F6"]
        let next = try await environment.start(settings: settings, credentials: .init(accessToken: "EXAMPLE-TOKEN-0123456789abcdef", registrationId: "7"))
        _ = try await accessory(next, id(.lightbulb, seed: "A1B2C3D4E5F6"))
        #expect(await environment.plugin?.accountAuthorized() == true)
        #expect(try await environment.plugin?.discover().map(\.deviceID) == ["LightBulbAccessoryA1B2C3D4E5F6"])
        await next.stop()
    }

    @Test func setUpAsksForAnAddressWhenNoBoxAnswers() async throws {
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected a question"); return }
        #expect(prompt.fields.map(\.key) == ["address"])
        #expect(environment.box.sent.isEmpty)
        await host.stop()
    }

    @Test func canonicalSettingsMovesTheTelevisionsOptions() throws {
        let block = try JSONValue(string: #"""
            {"platform":"PhilipsHueSyncBoxPlatform","uuidSeed":"LivingRoom","tvAccessory":true,"tvAccessoryType":"TV",
             "tvAccessoryLightbulb":true,"tvAccessoryConfiguredName":"Sync TV","modeTvAccessoryType":"settopbox",
             "intensityTvAccessoryConfiguredName":"",
             "_accessories":{"ModeTVAccessoryLivingRoom":{"accessoryType":"tvstick"}}}
            """#)
        let canonical = HueSyncBoxPlugin.canonical(block)
        #expect(canonical["_accessories"]?["TVAccessoryLivingRoom"] == ["accessoryType": "tv", "lightbulb": true, "name": "Sync TV"])
        #expect(canonical["_accessories"]?["ModeTVAccessoryLivingRoom"] == ["accessoryType": "tvstick"])
        #expect(canonical["tvAccessoryType"] == nil && canonical["tvAccessoryLightbulb"] == nil && canonical["intensityTvAccessoryConfiguredName"] == nil)
        #expect(canonical["tvAccessory"] == true)
        #expect(HueSyncBoxPlugin.canonical(canonical) == canonical)
    }

    /// A television's Accessory Settings pick its icon and its Lightbulb.
    @Test func aTelevisionsSettingsShapeIt() async throws {
        var settings = TestEnvironment.block
        settings["_accessories"] = ["TVAccessory": ["accessoryType": "audioreceiver", "lightbulb": false]]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { await environment.plugin?.state != nil })
        let hdmi = try await accessory(host, id(.hdmiTV))
        #expect(hdmi.category == .audioReceiver)
        #expect(hdmi.service(.lightbulb) == nil)
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(HueSyncBoxPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/HueSyncBox HueSyncBoxPlugin")
        let schema = try JSONValue(string: try #require(HueSyncBoxPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "PhilipsHueSyncBoxPlatform")
    }
}
