import Crypto
import Foundation
import HomeswiftAI
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftImou

/// A JPEG's first bytes, and some more.
let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

/// The documented signature (addendum, section 0): Base64 of an HMAC-SHA256 keyed with the hex SHA-256 of the secret.
func hmacSign(_ text: String, secret: String) -> String {
    let key = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8)))).base64EncodedString()
}

/// The IMOU Open Platform in memory: it checks each request's signature, answers the methods the plugin calls from what
/// a test put in it, and counts the calls.
final class FakeImouCloud: HTTPSending, Sendable {
    static let appID = "lcaa11bb22cc33dd44"
    static let appSecret = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    struct Call: Sendable {
        var url: URL
        var method: String
        var params: JSONValue
        var body: JSONValue
    }

    struct State {
        var devices: [JSONValue] = []
        var online: [String: String] = [:]
        var statuses: [String: Bool] = [:]
        var alarms: [String: JSONValue] = [:]
        var calls: [Call] = []
        var tokens = 0
        /// Errors to answer, in order, by method.
        var errors: [String: [String]] = [:]
        var currentDomain: String?
        var badSignatures = 0
        /// `setDeviceCameraStatus` waits while this is set.
        var holdSetStatus = false
        /// An account that takes only the MD5 signature, as the libraries send it.
        var refusesHMAC = false
        /// enableTypes and methods the camera lacks: `DV1019`.
        var unsupported: Set<String> = []
        /// enableTypes whose reads fail (the channel offline, `DV1020`).
        var failing: Set<String> = []
        var nightVision: (mode: String, modes: [String]) = ("Intelligent", ["Intelligent", "FullColor", "Infrared", "Off"])
        /// `controlMovePTZ` answers `OP1003` to an `operation` sent as a string, as a cloud might.
        var ptzWantsNumbers = false
        var presets: [String] = []
        var sdStatus = "normal"
    }

    let state = NIOLockedValueBox(State())

    var calls: [Call] { state.withLockedValue { $0.calls } }
    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }
    var tokenFetches: Int { state.withLockedValue { $0.tokens } }

    func addCamera(_ id: String = "TEST000CAM1", name: String = "Garden", abilities: String = "WLAN,AlarmMD,CloseCamera,Siren,WhiteLight,SCCode,Auth",
                   channelAbilities: String = "AlarmMD,HeaderDetect", extra: [String: JSONValue] = [:]) {
        var device: [String: JSONValue] = [
            "deviceId": .string(id), "deviceName": .string(name), "deviceStatus": "1", "brand": "Imou", "deviceModel": "IPC-F42P",
            "deviceVersion": "2.840.0000000.12.R", "channelNum": 1, "multiFlag": false, "accessType": "PaaS", "deviceAbility": .string(abilities),
            "channelList": [["channelId": "0", "channelName": .string(name), "channelStatus": "online", "channelAbility": .string(channelAbilities)]],
        ]
        device.merge(extra) { $1 }
        state.withLockedValue {
            $0.devices.append(.object(device))
            $0.online[id] = "1"
        }
    }

    func fail(_ method: String, with codes: String...) {
        state.withLockedValue { $0.errors[method, default: []] += codes }
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let method = request.url.lastPathComponent
        let body = try JSONValue(data: request.body ?? Data())
        let params = body["params"] ?? [:]
        if method == "setDeviceCameraStatus" {
            while state.withLockedValue({ $0.holdSetStatus }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        let answer: JSONValue = state.withLockedValue { state in
            state.calls.append(Call(url: request.url, method: method, params: params, body: body))
            // The signature: MD5 of time, nonce and the secret.
            let system = body["system"]
            let time = system?["time"]?.intValue ?? 0, nonce = system?["nonce"]?.stringValue ?? ""
            let signed = "time:\(time),nonce:\(nonce),appSecret:\(Self.appSecret)", sign = system?["sign"]?.stringValue
            guard sign == md5(signed) || !state.refusesHMAC && sign == hmacSign(signed, secret: Self.appSecret), system?["appId"]?.stringValue == Self.appID else {
                state.badSignatures += 1
                return Self.error("SN1001", "invalid sign")
            }
            // Errors by method, or by method and device (`deviceOnline:TEST000CAM1`).
            for key in ["\(method):\(params["deviceId"]?.stringValue ?? "")", method] {
                if var queued = state.errors[key], !queued.isEmpty {
                    let code = queued.removeFirst()
                    state.errors[key] = queued
                    return Self.error(code, "failed")
                }
            }
            if method != "accessToken" {
                guard let token = params["token"]?.stringValue, token == "At_\(state.tokens)" else { return Self.error("TK1002", "Token expired or does not exist, please get token again.") }
            }
            let device = params["deviceId"]?.stringValue ?? ""
            // A device-level switch has no channel.
            let channel = params["channelId"]?.stringValue ?? "device"
            if state.unsupported.contains(method) || state.unsupported.contains(params["enableType"]?.stringValue ?? "-") { return Self.error("DV1019", "not supported") }
            if method == "getDeviceCameraStatus", state.failing.contains(params["enableType"]?.stringValue ?? "-") { return Self.error("DV1020", "channel offline") }
            switch method {
            case "accessToken":
                state.tokens += 1
                var data: [String: JSONValue] = ["accessToken": .string("At_\(state.tokens)"), "expireTime": 190805]
                if let domain = state.currentDomain { data["currentDomain"] = .string(domain) }
                return Self.ok(.object(data))
            case "listDeviceDetailsByPage":
                let page = params["page"]?.intValue ?? 1, size = params["pageSize"]?.intValue ?? 10
                let slice = Array(state.devices.dropFirst((page - 1) * size).prefix(size))
                return Self.ok(["count": .number(Double(state.devices.count)), "deviceList": .array(slice)])
            case "deviceOnline":
                let online = state.online[device] ?? "0"
                return Self.ok(["deviceId": .string(device), "onLine": .string(online), "channels": [["channelId": "0", "onLine": .string(online)]]])
            case "getDeviceCameraStatus":
                let type = params["enableType"]?.stringValue ?? ""
                return Self.ok(["enableType": .string(type), "status": .string(state.statuses["\(device):\(channel):\(type)"] == true ? "on" : "off")])
            case "setDeviceCameraStatus":
                state.statuses["\(device):\(channel):\(params["enableType"]?.stringValue ?? "")"] = params["enable"]?.boolValue ?? false
                return Self.ok([:])
            case "modifyDeviceAlarmStatus":
                state.statuses["\(device):\(channel):motionDetect"] = params["enable"]?.boolValue ?? false
                return Self.ok([:])
            case "sirenStart", "sirenStop", "wakeUpDevice":
                return Self.ok([:])
            case "getAlarmMessage":
                return Self.ok(["alarms": state.alarms[device].map { [$0] } ?? [], "count": 1])
            case "setDeviceSnapEnhanced":
                return Self.ok(["url": "https://oss.example.com/snap.jpg?Expires=1&OSSAccessKeyId=KEYID&Signature=SIGNATURE"])
            case "getStreamUrl":
                return Self.ok(["url": "rtsp://proxy.example.com:8554/live/secretpath"])
            case "breathingLightStatus":
                return Self.ok(["status": .string(state.statuses["\(device):device:breathingLight"] == true ? "on" : "off")])
            case "getNightVisionMode":
                return Self.ok(["mode": .string(state.nightVision.mode), "modes": .array(state.nightVision.modes.map(JSONValue.string))])
            case "setNightVisionMode":
                state.nightVision.mode = params["mode"]?.stringValue ?? ""
                return Self.ok([:])
            case "controlMovePTZ":
                if state.ptzWantsNumbers, params["operation"]?.stringValue != nil { return Self.error("OP1003", "invalid parameter") }
                return Self.ok([:])
            case "controlLocationPTZ", "turnCollection", "restartDevice":
                return Self.ok([:])
            case "getCollection":
                return Self.ok(["collections": .array(state.presets.map { ["name": .string($0)] })])
            case "deviceSdcardStatus":
                return Self.ok(["status": .string(state.sdStatus)])
            case "deviceStorage":
                return Self.ok(["totalBytes": 31_254_904_832, "usedBytes": 27_553_759_232])
            case "getDevicePowerInfo":
                return Self.ok(["electricitys": [["type": "battery", "electric": "89", "litElec": "77"]]])
            default:
                return Self.error("200", "Error.")
            }
        }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: answer.encoded())
    }

    static func ok(_ data: JSONValue) -> JSONValue { ["result": ["code": "0", "msg": "Operation is successful.", "data": data], "id": "1"] }
    static func error(_ code: String, _ message: String) -> JSONValue { ["result": ["code": .string(code), "msg": .string(message)], "id": "1"] }
}

/// The object storage a cloud snapshot downloads from.
final class FakeDownload: HTTPSending, Sendable {
    let urls = NIOLockedValueBox<[URL]>([])
    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        urls.withLockedValue { $0.append(request.url) }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: jpeg)
    }
}

/// A Dahua camera's CGI in memory: Digest with `admin` and a safety code, its serial, snapshots, and an event stream the
/// test writes to.
final class FakeCamera: DahuaTransport, Sendable {
    let serial: String
    let password: String
    let nonce = "211955164"

    struct State {
        var targets: [String] = []
        var streams: [AsyncThrowingStream<[UInt8], any Error>.Continuation] = []
        var refuseCodes = false
        var reachable = true
        var snapshots = true
        var streamOpens = 0
    }

    let state = NIOLockedValueBox(State())

    init(serial: String = "TEST000CAM1", password: String = "L2A3B4C5") {
        self.serial = serial
        self.password = password
    }

    var targets: [String] { state.withLockedValue { $0.targets } }
    var streamOpens: Int { state.withLockedValue { $0.streamOpens } }

    /// Sends a part on the open event streams.
    func push(_ text: String) {
        let part = "--myboundary\r\nContent-Type: text/plain\r\nContent-Length:\(text.utf8.count)\r\n\r\n\(text)\r\n"
        for stream in state.withLockedValue({ $0.streams }) { stream.yield(Array(part.utf8)) }
    }

    /// Ends the open event streams, as a camera that restarts.
    func dropStreams() {
        let streams = state.withLockedValue { state -> [AsyncThrowingStream<[UInt8], any Error>.Continuation] in
            defer { state.streams = [] }
            return state.streams
        }
        for stream in streams { stream.finish() }
    }

    private var challenge: String { "Digest realm=\"Login to \(serial)\",qop=\"auth\",nonce=\"\(nonce)\",opaque=\"abcd\"" }

    /// Whether the request answers the challenge with the right password, for the target it was sent with.
    private func authorized(_ request: HomeswiftNetwork.HTTPRequest) -> Bool {
        guard let header = request.header("Authorization"), header.hasPrefix("Digest ") else { return false }
        var fields: [String: String] = [:]
        for part in header.dropFirst(7).components(separatedBy: ", ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        let target = request.target ?? request.url.path
        guard fields["uri"] == target, let nc = fields["nc"], let cnonce = fields["cnonce"] else { return false }
        let ha1 = md5("\(fields["username"] ?? ""):Login to \(serial):\(password)")
        let ha2 = md5("GET:\(target)")
        return fields["response"] == md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let target = request.target ?? request.url.path
        let (reachable, snapshots) = state.withLockedValue { state in
            state.targets.append(target)
            return (state.reachable, state.snapshots)
        }
        guard reachable else { throw HTTPClientError.cannotConnect(host: "camera", port: 80, code: 61, reason: "refused") }
        guard authorized(request) else { return HomeswiftNetwork.HTTPResponse(status: 401, headers: [("WWW-Authenticate", challenge)]) }
        if target.hasPrefix("/cgi-bin/magicBox.cgi?action=getSerialNo") { return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("sn=\(serial)\r\n".utf8)) }
        if target.hasPrefix("/cgi-bin/snapshot.cgi") { return snapshots ? HomeswiftNetwork.HTTPResponse(status: 200, body: jpeg) : HomeswiftNetwork.HTTPResponse(status: 500) }
        return HomeswiftNetwork.HTTPResponse(status: 404)
    }

    func stream(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HTTPStreamingResponse {
        let target = request.target ?? request.url.path
        let (reachable, refuse) = state.withLockedValue { state in
            state.targets.append(target)
            return (state.reachable, state.refuseCodes)
        }
        guard reachable else { throw HTTPClientError.cannotConnect(host: "camera", port: 80, code: 61, reason: "refused") }
        let empty = HTTPStreamingResponse.Body(AsyncThrowingStream { $0.finish() })
        guard authorized(request) else { return HTTPStreamingResponse(status: 401, headers: [("WWW-Authenticate", challenge)], body: empty) }
        if refuse, !target.contains("codes=[All]") { return HTTPStreamingResponse(status: 400, body: empty) }
        let (body, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        state.withLockedValue {
            $0.streams.append(continuation)
            $0.streamOpens += 1
        }
        return HTTPStreamingResponse(status: 200, headers: [("Content-Type", "multipart/x-mixed-replace; boundary=myboundary")], body: HTTPStreamingResponse.Body(body))
    }
}

/// FFmpeg known in advance: libfdk_aac, nothing probed, nothing run.
func testFFmpeg(_ logger: Logger) -> RTSPCameraFFmpeg {
    let codecs = FfmpegCodecs(log: logger, ffmpegVersion: "7.0", encoders: ["aac": ["libfdk_aac", "aac"]])
    let config = FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: logger, name: { "test" })
    return RTSPCameraFFmpeg(options: FfmpegOptions(config), codecs: codecs)
}

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Collects log lines, to check what never reaches them.
final class LogCollector: LogHandler, @unchecked Sendable {
    let lines = NIOLockedValueBox<[String]>([])
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        lines.withLockedValue { $0.append("\(event.message) \(event.metadata ?? [:])") }
    }
}

/// A host with one `Imou` block, its cloud and cameras in memory, every timer a thousandth of the real one.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Imou-tests-\(UUID().uuidString)")
    let cloud = FakeImouCloud()
    let camera: FakeCamera
    let download = FakeDownload()
    let log = LogCollector()
    let timeScale: Double
    private let plugins = NIOLockedValueBox<[ImouPlugin]>([])

    init(camera: FakeCamera = FakeCamera(), timeScale: Double = 0.001) {
        self.camera = camera
        self.timeScale = timeScale
    }

    var plugin: ImouPlugin? { plugins.withLockedValue { $0.last } }

    static var account: [String: Any] { ["appId": FakeImouCloud.appID, "appSecret": FakeImouCloud.appSecret, "region": "eu"] }

    func start(_ settings: [String: Any] = account) async throws -> PluginHost {
        var registry = PluginRegistry()
        let (cloud, camera, download, timeScale, log) = (cloud, camera, download, timeScale, log)
        // The plugin's own lines, which the host's logger does not carry: the never-logged checks read them.
        let pluginLogger: Logger = {
            var logger = Logger(label: "homeswift.Imou") { _ in log }
            logger.logLevel = .trace
            return logger
        }()
        registry.register(platform: ImouPlugin.platform, name: ImouPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(ImouPlugin.Configuration.self, from: json)
            let plugin = ImouPlugin(
                configuration: configuration, context: context,
                dependencies: .init(cloudTransport: cloud, download: download, local: camera, timeScale: timeScale, ffmpeg: { _, logger in testFFmpeg(logger) },
                                    eventSilence: .seconds(5), logger: pluginLogger))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let platform = try HomeswiftConfiguration.Platform(platform: ImouPlugin.platform, name: "Imou", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [platform])
        var logger = Logger(label: "homeswift") { _ in log }
        logger.logLevel = .trace
        let options = PluginHost.Options(advertise: false, logger: logger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// The camera accessory published on its own server.
    func accessory(_ host: PluginHost, _ id: String) -> Accessory? {
        host.bridges.dropFirst().flatMap { $0.server.accessories }.first { $0.id == id }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
