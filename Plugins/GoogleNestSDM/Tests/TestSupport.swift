import Foundation
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftGoogleNestSDM

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The device list of the specification's test vectors (9.1).
let deviceList: JSONValue = try! JSONValue(string: #"""
{"devices": [
  {"name": "enterprises/PROJECT-UUID/devices/THERMOSTAT-ID", "type": "sdm.devices.types.THERMOSTAT",
   "traits": {
     "sdm.devices.traits.Info": {"customName": ""}, "sdm.devices.traits.Humidity": {"ambientHumidityPercent": 42},
     "sdm.devices.traits.Connectivity": {"status": "ONLINE"}, "sdm.devices.traits.Fan": {"timerMode": "OFF"},
     "sdm.devices.traits.ThermostatMode": {"mode": "HEAT", "availableModes": ["HEAT", "COOL", "HEATCOOL", "OFF"]},
     "sdm.devices.traits.ThermostatEco": {"availableModes": ["OFF", "MANUAL_ECO"], "mode": "OFF", "heatCelsius": 9.7, "coolCelsius": 29.4},
     "sdm.devices.traits.ThermostatHvac": {"status": "HEATING"}, "sdm.devices.traits.Settings": {"temperatureScale": "FAHRENHEIT"},
     "sdm.devices.traits.ThermostatTemperatureSetpoint": {"heatCelsius": 20.5},
     "sdm.devices.traits.Temperature": {"ambientTemperatureCelsius": 19.8}},
   "parentRelations": [{"parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-1", "displayName": "Hallway"}]},
  {"name": "enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID", "type": "sdm.devices.types.CAMERA",
   "traits": {"sdm.devices.traits.CameraLiveStream": {"maxVideoResolution": {"width": 1920, "height": 1080}, "videoCodecs": ["H264"],
     "audioCodecs": ["AAC"], "supportedProtocols": ["RTSP"]}, "sdm.devices.traits.CameraMotion": {}, "sdm.devices.traits.CameraEventImage": {}},
   "parentRelations": [{"parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-2", "displayName": "Garage"}]},
  {"name": "enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID", "type": "sdm.devices.types.DOORBELL",
   "traits": {"sdm.devices.traits.CameraLiveStream": {"videoCodecs": ["H264"], "audioCodecs": ["OPUS"], "supportedProtocols": ["WEB_RTC"]},
     "sdm.devices.traits.DoorbellChime": {}, "sdm.devices.traits.CameraClipPreview": {}},
   "parentRelations": [{"parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-3", "displayName": "Front Door"}]},
  {"name": "enterprises/PROJECT-UUID/devices/DISPLAY-ID", "type": "sdm.devices.types.DISPLAY",
   "traits": {"sdm.devices.traits.CameraLiveStream": {"supportedProtocols": ["RTSP"]}, "sdm.devices.traits.CameraMotion": {}},
   "parentRelations": [{"parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-4", "displayName": "Kitchen"}]},
  {"name": "enterprises/PROJECT-UUID/devices/OTHER-ID", "type": "sdm.devices.types.LOCK", "traits": {}, "parentRelations": []}
]}
"""#)

let thermostatName = "enterprises/PROJECT-UUID/devices/THERMOSTAT-ID"
let cameraName = "enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID"
let doorbellName = "enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID"
let displayName = "enterprises/PROJECT-UUID/devices/DISPLAY-ID"

/// Google in memory: OAuth, SDM and Pub/Sub, recording each request.
final class FakeGoogle: HTTPSending, @unchecked Sendable {
    struct State {
        var requests: [HomeswiftNetwork.HTTPRequest] = []
        var devices = deviceList
        var results: [String: JSONValue] = [:]
        var failures: [String: (Int, String)] = [:]
        var messages: [JSONValue] = []
        var listFailures = 0
    }

    let state = NIOLockedValueBox(State())

    var requests: [HomeswiftNetwork.HTTPRequest] { state.withLockedValue { $0.requests } }

    /// The bodies of the commands sent, in order.
    var commands: [JSONValue] {
        requests.filter { $0.url.absoluteString.hasSuffix(":executeCommand") }.compactMap { $0.body.flatMap { try? JSONValue(data: $0) } }
    }

    func command(_ name: String) -> [JSONValue] { commands.filter { $0["command"]?.stringValue == "sdm.devices.commands.\(name)" } }

    /// A Pub/Sub message for the next pull.
    func publish(_ event: String) {
        let data = Data(event.utf8).base64EncodedString()
        state.withLockedValue { state in
            state.messages.append(["ackId": .string("ACK-\(state.messages.count + 1)"), "message": ["data": .string(data), "messageId": "1"]])
        }
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        state.withLockedValue { $0.requests.append(request) }
        let url = request.url.absoluteString
        func json(_ value: JSONValue, status: Int = 200) -> HomeswiftNetwork.HTTPResponse { HomeswiftNetwork.HTTPResponse(status: status, body: value.encoded()) }
        if url == GoogleOAuth.tokenURL.absoluteString {
            let form = URLEncoding.fields(String(decoding: request.body ?? Data(), as: UTF8.self))
            if form["refresh_token"] == "REVOKED" { return json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."], status: 400) }
            var answer: JSONValue = ["access_token": "ACCESS-TOKEN", "expires_in": 3599, "token_type": "Bearer"]
            if form["grant_type"] == "authorization_code" { answer = ["access_token": "ACCESS-TOKEN", "expires_in": 3599, "refresh_token": "NEW-REFRESH"] }
            return json(answer)
        }
        if url.hasSuffix("enterprises/PROJECT-UUID/devices") {
            let fail = state.withLockedValue { state -> Bool in
                guard state.listFailures > 0 else { return false }
                state.listFailures -= 1
                return true
            }
            if fail { return json(["error": ["code": 429, "message": "Rate limited.", "status": "RESOURCE_EXHAUSTED"]], status: 429) }
            return json(state.withLockedValue { $0.devices })
        }
        if url.hasSuffix(":executeCommand") {
            let body = try JSONValue(data: request.body ?? Data())
            let name = body["command"]?.stringValue?.replacingOccurrences(of: "sdm.devices.commands.", with: "") ?? ""
            let (failure, result) = state.withLockedValue { ($0.failures[name], $0.results[name]) }
            if let failure { return json(["error": ["code": .number(Double(failure.0)), "message": .string(failure.1), "status": "FAILED_PRECONDITION"]], status: failure.0) }
            return json(["results": result ?? [:]])
        }
        if url.hasSuffix(":pull") {
            let messages = state.withLockedValue { state -> [JSONValue] in
                defer { state.messages = [] }
                return state.messages
            }
            if messages.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                return json([:])
            }
            return json(["receivedMessages": .array(messages)])
        }
        if url.hasSuffix(":acknowledge") { return json([:]) }
        if url.contains("sdm_event_snapshot") { return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("EVENT-JPEG".utf8)) }
        if url.hasPrefix("https://smartdevicemanagement.googleapis.com/v1/enterprises/PROJECT-UUID/devices/") {
            let name = String(url.dropFirst(SDMClient.base.count))
            let device = state.withLockedValue { $0.devices }["devices"]?.arrayValue?.first { $0["name"]?.stringValue == name }
            return device.map { json($0) } ?? json(["error": ["code": 404, "message": "Not found"]], status: 404)
        }
        return HomeswiftNetwork.HTTPResponse(status: 404)
    }
}

/// FFmpeg known in advance: libfdk_aac, nothing probed.
func testFFmpeg(_ logger: Logger) -> NestFFmpeg {
    let codecs = FfmpegCodecs(log: logger, ffmpegVersion: "7.0", encoders: ["aac": ["libfdk_aac", "aac"]])
    let config = FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: logger, name: { "test" })
    return NestFFmpeg(options: FfmpegOptions(config), codecs: codecs)
}

/// The block of the specification's account.
var accountBlock: [String: Any] {
    [
    "projectId": "PROJECT-UUID", "clientId": "CLIENT.apps.googleusercontent.com", "clientSecret": "CLIENT-SECRET", "refreshToken": "REFRESH-TOKEN",
    "subscriptionId": "projects/gcp/subscriptions/nest", "showFan": true,
    ]
}

/// A host with one platform block whose plugin talks to `google`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-GoogleNestSDM-tests-\(UUID().uuidString)")
    let google = FakeGoogle()
    private let plugins = NIOLockedValueBox<[GoogleNestSDMPlugin]>([])

    var plugin: GoogleNestSDMPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: GoogleNestSDMPlugin.Dependencies {
        GoogleNestSDMPlugin.Dependencies(transport: google, ffmpeg: { logger, _ in testFFmpeg(logger) }, timeScale: 0.01)
    }

    func start(settings: [String: Any] = accountBlock) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies
        registry.register(platform: GoogleNestSDMPlugin.platform, name: GoogleNestSDMPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(GoogleNestSDMPlugin.Configuration.self, from: json)
            let plugin = GoogleNestSDMPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: GoogleNestSDMPlugin.platform, name: GoogleNestSDMPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// Started, with the devices loaded.
    func loaded(settings: [String: Any] = accountBlock) async throws -> PluginHost {
        let host = try await start(settings: settings)
        _ = await eventually { await self.plugin?.devicesLoaded == true }
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

/// An event's JSON with the timestamp of now.
func freshEvent(_ json: String) -> String {
    json.replacingOccurrences(of: "<now>", with: ISO8601DateFormatter().string(from: Date()))
}
