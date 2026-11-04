import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftRing

typealias NetworkRequest = HomeswiftNetwork.HTTPRequest
typealias NetworkResponse = HomeswiftNetwork.HTTPResponse

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// docs/clean-room/Ring.md's fixtures (8.3, 8.4), invented data.
enum Fixtures {
    static let hardwareID = "11111111-2222-5333-8444-555555555555"
    static let wrapper = "eyJydCI6IkVYQU1QTEUtUlQiLCJoaWQiOiIxMTExMTExMS0yMjIyLTUzMzMtODQ0NC01NTU1NTU1NTU1NTUifQ=="

    static let locations = #"""
        {"user_locations":[{"location_id":"loc-alarm-001","name":"Home","owner_id":1,
          "address":{"address1":"1 Example St","city":"Exampleville","state":"CA","timezone":"America/Los_Angeles","zip_code":"00000"}}]}
        """#

    static let devices = #"""
        {"doorbots":[{"id":1001,"description":"Front Door","device_id":"aa:bb:cc:dd:ee:01","kind":"lpd_v1",
           "location_id":"loc-alarm-001","alerts":{"connection":"online"},"battery_life":null,"external_connection":true,
           "settings":{"chime_settings":{"type":0,"enable":true,"duration":0},"motion_detection_enabled":true,
             "live_view_disabled":false,"sheila_settings":{"cv_processing_enabled":false,"local_storage_enabled":false}},
           "health":{"device_type":"lpd_v1","connected":true},"subscribed":true,"subscribed_motions":true}],
         "stickup_cams":[{"id":1002,"description":"Garage Cam","device_id":"aa:bb:cc:dd:ee:02","kind":"stickup_cam_mini",
           "location_id":"loc-alarm-001","alerts":{"connection":"online","battery":"ok"},"battery_life":"87",
           "external_connection":false,"led_status":"off","siren_status":{"seconds_remaining":0},
           "settings":{"power_mode":"battery","motion_detection_enabled":true,
             "sheila_settings":{"local_storage_enabled":false}},"health":{"battery_percentage":87}}],
         "authorized_doorbots":[],
         "chimes":[{"id":2001,"description":"Hall Chime","device_id":"chime-hw-1","kind":"chime_pro_v2",
           "location_id":"loc-alarm-001","settings":{"volume":6,"night_light_settings":{"light_sensor_enabled":false}},
           "do_not_disturb":{"seconds_left":0},"alerts":{"connection":"online"}}],
         "base_stations":[{"id":3001,"kind":"base_station_v1","location_id":"loc-alarm-001","description":"Alarm Base Station"}],
         "beams_bridges":[{"id":4001,"kind":"beams_bridge_v1","location_id":"loc-alarm-001","description":"Lighting Bridge"}],
         "other":[{"id":5001,"kind":"intercom_handset_audio","description":"Lobby Intercom","device_id":"ic-hw-1",
           "location_id":"loc-alarm-001","battery_life":"100","subscribed":true,"alerts":{"connection":"online"}},
          {"id":1003,"kind":"onvif_camera","description":"ONVIF Cam","device_id":"onvif-1","location_id":"loc-alarm-001",
           "metadata":{"third_party_manufacturer":"Acme","third_party_model":"X1"}}]}
        """#

    static let ticket = #"""
        {"assets":[{"uuid":"asset-base-uuid-0001","kind":"base_station_v1","doorbotId":3001,"onBattery":false,"status":"online"},
                   {"uuid":"asset-beam-uuid-0001","kind":"beams_bridge_v1","doorbotId":4001,"onBattery":false,"status":"online"}],
         "host":"hub.example.invalid","ticket":"TICKET","subscriptionTopics":[]}
        """#

    static let baseList = #"""
        {"channel":"message","msg":{"msg":"DeviceInfoDocGetList","datatype":"DeviceInfoDocType","src":"asset-base-uuid-0001",
         "body":[
          {"general":{"v2":{"zid":"zid-security-panel","name":"Security Panel","deviceType":"security-panel","categoryId":22,
             "batteryStatus":"none","tamperStatus":"ok","tags":[]}},"device":{"v1":{"mode":"none"}}},
          {"general":{"v2":{"zid":"zid-base-station","name":"Base Station","deviceType":"hub.redsky","categoryId":22,
             "batteryStatus":"none","tamperStatus":"ok","tags":[],"volume":0.5}},"device":{"v1":{}}},
          {"general":{"v2":{"zid":"zid-contact","name":"Front Door Contact","deviceType":"sensor.contact","categoryId":5,
             "batteryStatus":"ok","tamperStatus":"ok","tags":[]}},"device":{"v1":{"faulted":false}}},
          {"general":{"v2":{"zid":"zid-thermostat","name":"Living Thermostat","deviceType":"temperature-control.thermostat",
             "categoryId":11,"batteryStatus":"none","tamperStatus":"ok","tags":[]}},
             "device":{"v1":{"mode":"heat","setPoint":21,"setPointMin":7,"setPointMax":30}}},
          {"general":{"v2":{"zid":"zid-thermo-temp","name":"Living Thermostat Temperature","deviceType":"sensor.temperature",
             "categoryId":5,"batteryStatus":"none","tamperStatus":"ok","tags":[],"parentZid":"zid-thermostat"}},
             "device":{"v1":{"celsius":19.94}}}
         ]}}
        """#

    static let beamList = #"""
        {"channel":"message","msg":{"msg":"DeviceInfoDocGetList","datatype":"DeviceInfoDocType","src":"asset-beam-uuid-0001",
         "body":[{"general":{"v2":{"zid":"zid-beam-dimmer","name":"Path Light","deviceType":"switch.multilevel.beams","categoryId":2,
             "batteryStatus":"none","tamperStatus":"ok"}},"device":{"v1":{"on":false,"level":0.2,"motionStatus":"clear"}}}]}}
        """#

    static func update(_ zid: String, _ device: String) -> String {
        #"{"channel":"DataUpdate","msg":{"msg":"DeviceInfoDocGetList","datatype":"DeviceInfoDocType","src":"asset-base-uuid-0001","body":[{"general":{"v2":{"zid":"\#(zid)"}},"device":{"v1":\#(device)}}]}}"#
    }

    /// A JPEG's first bytes, enough for a snapshot.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
}

/// Ring's cloud in memory: OAuth that rotates the refresh token, a session made lazily (`Session not found` before),
/// and the fixtures.
final class FakeRingCloud: HTTPSending {
    struct State {
        var requests: [(method: String, url: String, body: JSONValue?)] = []
        var sessions = 0
        var tokens = 0
        var devices = Fixtures.devices
        var oauth: (@Sendable (NetworkRequest) -> NetworkResponse)?
        /// Snapshots wait while this is set.
        var holdSnapshots = false
    }

    let state = NIOLockedValueBox(State())

    var requests: [(method: String, url: String, body: JSONValue?)] { state.withLockedValue { $0.requests } }
    func count(_ fragment: String) -> Int { requests.filter { $0.url.contains(fragment) }.count }

    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        let url = request.url.absoluteString
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let (oauth, hasSession) = state.withLockedValue { state -> ((@Sendable (NetworkRequest) -> NetworkResponse)?, Bool) in
            state.requests.append((request.method, url, body))
            return (state.oauth, state.sessions > 0)
        }
        func json(_ text: String, status: Int = 200) -> NetworkResponse { NetworkResponse(status: status, body: Data(text.utf8)) }
        if url == "https://oauth.ring.com/oauth/token" {
            if let oauth { return oauth(request) }
            let n = state.withLockedValue { $0.tokens += 1; return $0.tokens }
            return json(#"{"access_token":"AT-\#(n)","expires_in":3600,"refresh_token":"EXAMPLE-RT-\#(n + 1)","scope":"client","token_type":"Bearer"}"#)
        }
        if url.hasSuffix("clients_api/session") {
            state.withLockedValue { $0.sessions += 1 }
            return json(#"{"profile":{"id":1}}"#)
        }
        if url.hasPrefix("https://api.ring.com/clients_api/"), !hasSession {
            return json(#"{"error":"Session not found for \#(request.header("hardware_id") ?? "")"}"#, status: 404)
        }
        if url.hasSuffix("devices/v1/locations") { return json(Fixtures.locations) }
        if url.hasSuffix("clients_api/ring_devices") { return json(state.withLockedValue { $0.devices }) }
        if url.contains("clap/tickets") { return json(Fixtures.ticket) }
        if url.contains("app-snaps.ring.com") {
            while state.withLockedValue({ $0.holdSnapshots }) { try await Task.sleep(for: .milliseconds(5)) }
            return NetworkResponse(status: 200, headers: [("x-time-millis", "1700000000000"), ("date", "Tue, 14 Nov 2023 22:13:20 GMT")], body: Fixtures.jpeg)
        }
        if url.contains("mode/location/") { return json(#"{"mode":"home","readOnly":false}"#) }
        return json("{}")
    }
}

/// Pushes in memory.
final class FakePush: RingPushSource {
    let events: AsyncStream<FCMReceiver.Event>
    let continuation: AsyncStream<FCMReceiver.Event>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: FCMReceiver.Event.self) }

    var token: String? { "fcm-token" }
    func start() async {}
    func stop() async { continuation.finish() }
    func send(_ event: FCMReceiver.Event) { continuation.yield(event) }

    /// A push whose `data` holds these values.
    func push(_ data: [String: String]) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["data": data])
        send(.message(FCMMessage(persistentID: UUID().uuidString, payload: payload)!))
    }
}

/// A host with the Ring block, its cloud, its hub socket and its pushes faked.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Ring-tests-\(UUID().uuidString)")
    let cloud = FakeRingCloud()
    let socket = FakeWebSocket()
    let push = FakePush()
    private let plugins = NIOLockedValueBox<[RingPlugin]>([])
    let socketURLs = NIOLockedValueBox<[URL]>([])

    var plugin: RingPlugin? { plugins.withLockedValue { $0.last } }

    static var timing: RingTiming {
        var timing = RingTiming()
        timing.transportRetry = .milliseconds(10)
        timing.gatewayRetry = .milliseconds(10)
        timing.knownErrorRetry = .milliseconds(10)
        timing.hubReconnect = .milliseconds(10)
        timing.notificationLifetime = .milliseconds(400)
        timing.pushQuiet = .zero
        timing.levelDebounce = .milliseconds(20)
        timing.snapshotUUIDWait = .milliseconds(50)
        timing.intercomUnlocked = .milliseconds(100)
        timing.playSwitchReset = .milliseconds(20)
        timing.refreshThrottle = .zero
        timing.resubscribeThrottle = .zero
        return timing
    }

    init() {
        // The hubs answer a list request with their fixtures.
        socket.onSend { [socket] message in
            guard let text = message.text, text.contains("DeviceInfoDocGetList") else { return }
            if text.contains("asset-base-uuid-0001") { socket.receive(text: Fixtures.baseList) }
            if text.contains("asset-beam-uuid-0001") { socket.receive(text: Fixtures.beamList) }
        }
    }

    func start(settings: [String: Any] = ["refreshToken": Fixtures.wrapper], timing: RingTiming = TestEnvironment.timing) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: RingPlugin.platform, name: RingPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(RingPlugin.Configuration.self, from: json)
            var dependencies = RingPlugin.Dependencies()
            dependencies.http = self.cloud
            dependencies.connectWebSocket = { [socket = self.socket, socketURLs = self.socketURLs] url in
                socketURLs.withLockedValue { $0.append(url) }
                return socket
            }
            dependencies.push = { [push = self.push] _, _ in push }
            dependencies.timing = timing
            let plugin = RingPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: RingPlugin.platform, name: RingPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

extension PluginHost {
    /// Every accessory, on the bridge and on the cameras' own servers.
    var allAccessories: [Accessory] { bridges.flatMap { $0.server.accessories } }

    func accessory(_ seed: String) -> Accessory? { allAccessories.first { $0.id == "Ring:\(seed)" } }
}

/// A write from HomeKit through the characteristic's handler.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    let characteristic = try #require(characteristic)
    let handler = try #require(characteristic.writeHandler(for: value))
    try await handler(value)
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
