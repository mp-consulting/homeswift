import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftReolink

/// A bridge with one `Reolink` block, its device's HTTP API and Baichuan side in memory, its timings shortened.
final class ReolinkEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Reolink-tests-\(UUID().uuidString)")
    let http: FakeReolinkHTTP
    let cameras = NIOLockedValueBox<[FakeBaichuanCamera]>([])
    let baichuanFails: Bool
    let scale: Double
    /// An ARP table that does not answer: discovery stops looking after a moment.
    let silentNetwork: Bool
    /// Sets up each fake Baichuan camera before the plugin talks to it (its answers, its login reply).
    let prepareCamera = NIOLockedValueBox<(@Sendable (FakeBaichuanCamera) -> Void)?>(nil)
    /// A standalone battery camera answers Baichuan in place of `FakeBaichuanCamera` when set.
    let batteryCamera = NIOLockedValueBox<FakeBatteryCamera?>(nil)
    private let plugins = NIOLockedValueBox<[ReolinkPlugin]>([])

    init(_ answers: [String: @Sendable (JSONValue?) -> JSONValue] = cameraAnswers(), baichuanFails: Bool = false, scale: Double = 0.002, silentNetwork: Bool = false) {
        http = FakeReolinkHTTP(answers)
        self.baichuanFails = baichuanFails
        self.scale = scale
        self.silentNetwork = silentNetwork
    }

    var plugin: ReolinkPlugin? { plugins.withLockedValue { $0.last } }
    var camera: FakeBaichuanCamera? { cameras.withLockedValue { $0.last } }

    var dependencies: ReolinkPlugin.Dependencies {
        let http = http
        let cameras = cameras
        let fails = baichuanFails
        let prepare = prepareCamera
        let battery = batteryCamera
        var dependencies = ReolinkPlugin.Dependencies()
        dependencies.makeSender = { _ in http }
        dependencies.localAddress = { _ in "192.168.1.10" }
        dependencies.webhookBindHost = "127.0.0.1"
        dependencies.connectBaichuan = { _, _, _ in
            if let camera = battery.withLockedValue({ $0 }) { return try camera.connect() }
            if fails { throw HTTPClientError.cannotConnect(host: "camera", port: 9000, code: 61, reason: "refused") }
            let camera = FakeBaichuanCamera()
            prepare.withLockedValue { $0 }?(camera)
            cameras.withLockedValue { $0.append(camera) }
            return camera
        }
        dependencies.timing = ReolinkTiming(scale: scale)
        dependencies.neighbours = { [("192.168.1.40", "EC:71:DB:12:34:56"), ("192.168.1.41", "00:11:22:33:44:55")] }
        dependencies.accepts = { host, _ in host == "192.168.1.40" }
        if silentNetwork {
            dependencies.neighbours = { try? await Task.sleep(for: .seconds(600)); return [] }
            dependencies.networkSearchTime = .milliseconds(20)
        }
        return dependencies
    }

    func start(_ settings: [String: Any] = ["devices": [["host": "192.168.1.20", "password": "secret"]]]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies
        registry.register(platform: ReolinkPlugin.platform, name: ReolinkPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(ReolinkPlugin.Configuration.self, from: json)
            let plugin = ReolinkPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: ReolinkPlugin.platform, name: ReolinkPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    func accessory(_ host: PluginHost, _ id: String) -> Accessory? {
        host.bridges.dropFirst().flatMap { $0.server.accessories }.first { $0.id == id }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReolinkPluginTests {
    static let cameraID = "Reolink:95270000ABCDEFGH"

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(ReolinkPlugin.Configuration.self, from: Data(#"{"platform": "Reolink"}"#.utf8))
        #expect(configuration.devices.isEmpty)
        #expect(configuration.videoProcessor == "ffmpeg")
        let full = try JSONDecoder().decode(ReolinkPlugin.Configuration.self, from: Data("""
            {"platform": "Reolink", "devices": [{"host": "192.168.1.30", "password": "x", "channels": [0, 1, 3], "port": "8443",
              "cameras": {"0": {"siren": true}, "3": {"doorbell": true, "recording": true, "prebuffer": true}}}]}
            """.utf8))
        let device = try #require(full.devices.first)
        #expect(device.username == "admin")
        #expect(device.port == 8443)
        #expect(device.channels == [0, 1, 3])
        #expect(device.cameras["0"]?.siren == true)
        #expect(device.cameras["3"]?.prebuffer == true)
        #expect(device.refreshInterval(cameras: 8) == 80)
        #expect(device.refreshInterval(cameras: 2) == 60)
    }

    @Test func notConfiguredCostsNothing() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start([:])
        defer { Task { await host.stop() } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(environment.http.requestCount == 0)
        #expect(environment.cameras.withLockedValue { $0.isEmpty })
    }

    @Test func aCameraBecomesAnExternalAccessory() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["siren": true, "irLights": true]]]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        #expect(accessory.category == .ipCamera)
        #expect(accessory.information.characteristic(.manufacturer).value == "Reolink")
        #expect(accessory.information.characteristic(.model).value == "RLC-810A")
        #expect(accessory.information.characteristic(.serialNumber).value == "00000000000001")
        #expect(accessory.information.characteristic(.firmwareRevision).value == "3.1.0.2368")
        let subtypes = Set(accessory.services.compactMap(\.subtype))
        #expect(subtypes.isSuperset(of: ["motion", "person", "vehicle", "floodlight", "siren", "ir"]))
        // No pet sensor: the camera lacks `supportAiAnimal`.
        #expect(!subtypes.contains("pet"))
        #expect(!subtypes.contains("doorbell"))
        #expect(accessory.service(.cameraRTPStreamManagement) != nil)
    }

    @Test func pushEventsReachHomeKitAndStopPolling() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        let motion = try #require(accessory.services.first { $0.subtype == "motion" })
        let person = try #require(accessory.services.first { $0.subtype == "person" })
        #expect(await eventually { await environment.plugin?.runtimes["192.168.1.20"]?.host.baichuan?.isConnected == true })
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let camera = try #require(environment.camera)
        // Before push is active, motion is polled.
        #expect(await eventually { environment.http.count("GetEvents") >= 3 })
        camera.push(alarmXML(status: "MD", ai: "people"))
        #expect(await eventually { motion.characteristic(.motionDetected).value == true })
        #expect(person.characteristic(.motionDetected).value == true)
        #expect(await eventually { await environment.plugin?.runtimes["192.168.1.20"]?.host.pushActive == true })
        try await Task.sleep(for: .milliseconds(30))
        let polled = environment.http.count("GetEvents")
        // Motion polling every 5 s × 0.002 = 10 ms: none while push is active (the full refresh every 60 s is 120 ms).
        try await Task.sleep(for: .milliseconds(80))
        #expect(environment.http.count("GetEvents") - polled <= 1)
        camera.push(alarmXML(status: "none", ai: "none"))
        #expect(await eventually { motion.characteristic(.motionDetected).value == false })
    }

    @Test func pollingWithoutPushAsksOnceACycle() async throws {
        let environment = ReolinkEnvironment(baichuanFails: true)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        let start = environment.http.requestCount
        let events = environment.http.count("GetEvents")
        #expect(await eventually { environment.http.count("GetEvents") - events > 2 })
        // Requests first: a poll between the two reads only adds to `polls`.
        let requests = environment.http.requestCount - start
        let polls = environment.http.count("GetEvents") - events
        // One POST per cycle (10 ms), every channel's GetEvents in it: as many requests as polls, give or take a refresh.
        #expect(requests <= polls + 2)
        #expect(environment.http.logins == 1)
    }

    /// An NVR with two cameras and another brand's: `online` tells which are there now.
    static func nvrAnswers(online: [Int]) -> [String: @Sendable (JSONValue?) -> JSONValue] {
        var answers = cameraAnswers()
        answers["GetDevInfo"] = { _ in ["cmd": "GetDevInfo", "code": 0, "value": ["DevInfo": ["model": "RLN8-410", "name": "NVR", "serial": "00000000000009",
                                                                                              "firmVer": "v3.3.0.226", "exactType": "NVR", "channelNum": 3]]] }
        answers["GetChannelstatus"] = { _ in
            ["cmd": "GetChannelstatus", "code": 0, "value": ["count": 3, "status": [
                ["channel": 0, "name": "Gate", "online": .number(online.contains(0) ? 1 : 0), "typeInfo": "RLC-510A", "uid": "95270000AAAAAAAA"],
                ["channel": 1, "name": "Yard", "online": .number(online.contains(1) ? 1 : 0), "typeInfo": "RLC-520A", "uid": "95270000BBBBBBBB"],
                ["channel": 2, "name": "NVT", "online": 1, "typeInfo": "IPC"],
            ]]]
        }
        answers["GetChnTypeInfo"] = { _ in ["cmd": "GetChnTypeInfo", "code": 0, "value": ["typeInfo": "RLC-5x0A", "firmVer": "v3.1.0"]] }
        return answers
    }

    @Test func anNVRKeepsAnOfflineCameraAndDoesNotReloadForeignOnes() async throws {
        let id = "Reolink:95270000ABCDEFGH:95270000BBBBBBBB"
        let environment = ReolinkEnvironment(Self.nvrAnswers(online: [0, 1]), baichuanFails: true)
        let first = try await environment.start()
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 1) != nil })
        await first.stop()

        // The yard camera is off when the bridge starts again: its accessory stays, not responding.
        environment.http.state.withLockedValue { $0.answers = Self.nvrAnswers(online: [0]) }
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let refreshes = environment.http.count("GetChannelstatus")
        let reads = environment.http.count("GetEnc")
        // Full refreshes every 120 ms: a few, none of which reads the channels again for the other brand's camera
        // or GetChnTypeInfo's model.
        #expect(await eventually { environment.http.count("GetChannelstatus") >= refreshes + 3 })
        #expect(environment.http.count("GetEnc") == reads)
        let plugin = try #require(environment.plugin)
        let yard = try #require(await plugin.context.accessory(id: id))
        #expect(yard.isUnavailable)
    }

    @Test func doorbellRingsOnceOnARisingEdge() async throws {
        let environment = ReolinkEnvironment(cameraAnswers(model: "Reolink Video Doorbell PoE", doorbell: true), scale: 0.01)
        // 300 s at a hundredth: the real 3 s, which a loaded machine's four presses stay inside.
        let host = try await environment.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["ringThrottleSeconds": 300]]]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        #expect(accessory.category == .videoDoorbell)
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let camera = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 0))
        let doorbell = try #require(camera.services.doorbell)
        #expect(doorbell.isPrimary)
        let rings = NIOCounter()
        let characteristic = doorbell.characteristic(.programmableSwitchEvent)
        let observer = characteristic.observe { _ in rings.increment() }
        defer { characteristic.removeObserver(observer) }
        var state = ReolinkChannelState()
        state.visitor = true
        camera.apply(state)
        state.visitor = true
        camera.apply(state)
        state.visitor = false
        camera.apply(state)
        // Pressed again within 3 s: throttled.
        state.visitor = true
        camera.apply(state)
        #expect(await eventually { rings.value >= 1 })
        try await Task.sleep(for: .milliseconds(5))
        #expect(rings.value == 1)
    }

    @Test func floodlightWriteReachesTheDevice() async throws {
        let environment = ReolinkEnvironment(scale: 0.1)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let camera = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 0))
        let light = try #require(camera.services.floodlight)
        try await light.characteristic(.on).writeHandler(for: .bool(true))?(.bool(true))
        let body = environment.http.state.withLockedValue { $0.requests.last { $0.cmd == "SetWhiteLed" }?.body }
        // Only the field that changes (4.4).
        #expect(body == [["cmd": "SetWhiteLed", "param": ["WhiteLed": ["channel": 0, "state": 1]]]])
        // A drag of the brightness slider: one request.
        let before = environment.http.count("SetWhiteLed")
        let handler = try #require(light.characteristic(.brightness).writeHandler(for: .int(10)))
        await withTaskGroup(of: Void.self) { group in
            for level in [10, 20, 30, 40, 50] { group.addTask { try? await handler(.int(level)) } }
        }
        #expect(environment.http.count("SetWhiteLed") - before == 1)
        // It is read back.
        #expect(await eventually { environment.http.count("GetWhiteLed") >= 2 })
    }

    @Test func sirenGoesOverBaichuanAndTurnsItselfOff() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["siren": true]]]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.runtimes["192.168.1.20"]?.host.baichuan?.isConnected == true })
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let camera = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 0))
        let siren = try #require(camera.services.siren)
        #expect(siren.characteristic(.on).isSecurityControl)
        try await siren.characteristic(.on).writeHandler(for: .bool(true))?(.bool(true))
        #expect(environment.camera?.sirenBodies.first?.contains("<onOff>1</onOff>") == true)
        siren.characteristic(.on).value = true
        // 60 s × 0.002.
        #expect(await eventually { siren.characteristic(.on).value == false })
    }

    @Test func unreachableDeviceDoesNotCrash() async throws {
        let environment = ReolinkEnvironment()
        environment.http.state.withLockedValue { $0.unreachable = true }
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        // Baichuan is asked first (privacy mode), HTTP does not answer: no accessory.
        #expect(await eventually { environment.http.requestCount == 0 && environment.camera?.commands.contains(31) == true })
        try await Task.sleep(for: .milliseconds(50))
        #expect(environment.accessory(host, Self.cameraID) == nil)
        // It comes back.
        environment.http.state.withLockedValue { $0.unreachable = false }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
    }

    @Test func offlineHostShowsNoResponse() async throws {
        let environment = ReolinkEnvironment(baichuanFails: true)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.cameraID) != nil })
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        environment.http.state.withLockedValue { $0.unreachable = true }
        #expect(await eventually { accessory.isUnavailable })
        environment.http.state.withLockedValue { $0.unreachable = false }
        #expect(await eventually { !accessory.isUnavailable })
    }

    @Test func snapshotsAreCached() async throws {
        let environment = ReolinkEnvironment(scale: 1)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let camera = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 0))
        let image = try await camera.streamer.handleSnapshotRequest(SnapshotRequest(height: 360, width: 640))
        #expect(String(decoding: image, as: UTF8.self) == "JPEG0sub")
        _ = try await camera.streamer.handleSnapshotRequest(SnapshotRequest(height: 1080, width: 1920))
        #expect(environment.http.count("Snap") == 1)
    }

    @Test func streamArguments() throws {
        let request = StartStreamRequest(
            sessionID: "s",
            video: VideoInfo(codec: 0, profile: 2, level: 2, packetizationMode: 0, cvoId: nil, width: 640, height: 360, fps: 15, pt: 99, ssrc: 1,
                             maxBitRate: 300, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 2, maxBitRate: 24,
                             rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))
        let sub = ReolinkStream(codec: "h264", width: 640, height: 360, fps: 15)
        #expect(ReolinkStreamer.usesSub("auto", request: request.video, sub: sub))
        #expect(!ReolinkStreamer.usesSub("main", request: request.video, sub: sub))
        let codecs = HomeswiftFFmpeg.FfmpegCodecs(ffmpegExec: "ffmpeg", log: testLogger)
        let ffmpeg = HomeswiftFFmpeg.FfmpegOptions(.init(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: testLogger, name: { "test" }))
        let target = (address: "192.168.1.5", isIPv6: false, videoPort: 51000, videoKey: Data(repeating: 1, count: 30), videoSSRC: UInt32(11),
                      audioPort: 51002, audioKey: Data(repeating: 2, count: 30), audioSSRC: UInt32(22))
        var options = ReolinkPlugin.CameraOptions.defaults
        options.vcodec = "copy"
        let copied = ReolinkStreamer.arguments(url: "rtsp://a:b@h/x", stream: sub, request: request, target: target, options: options, ffmpeg: ffmpeg, audioEncoder: nil)
        #expect(copied.contains("copy"))
        #expect(copied.contains("tcp"))
        #expect(copied.last(where: { $0.hasPrefix("srtp://") }) == "srtp://192.168.1.5:51000?rtcpport=51000&pkt_size=1378")
        // H.265 is transcoded whatever the option.
        let main = ReolinkStream(codec: "h265", width: 3840, height: 2160, fps: 25)
        let transcoded = ReolinkStreamer.arguments(url: "rtsp://a:b@h/x", stream: main, request: request, target: target, options: options, ffmpeg: ffmpeg, audioEncoder: nil)
        #expect(transcoded.contains("libx264"))
        #expect(!transcoded.contains("copy"))
    }

    @Test func discoveryDoesNotWaitForASilentNetwork() async throws {
        let environment = ReolinkEnvironment(silentNetwork: true)
        let host = try await environment.start([:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.discover()
        #expect(devices.isEmpty)
    }

    @Test func setupListsTheNetworksDevices() async throws {
        let environment = ReolinkEnvironment()
        let host = try await environment.start([:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.discover()
        #expect(devices.map(\.deviceID) == ["address:192.168.1.40"])
        let found = try #require(devices.first)
        #expect(found.authorization == .accountLogin && found.address == "192.168.1.40" && !found.isSetUp)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(found))) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["username", "password"])
    }

    @Test func addByAddressProbesTheHostAndKeysItByItsDeviceId() async throws {
        #expect(ReolinkPlugin.newDevices == .byAddress)
        let environment = ReolinkEnvironment()
        let host = try await environment.start([:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["host", "username", "password"])
        #expect(prompt.fields[1].value == "admin" && prompt.fields[2].kind == .secret)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.20", "username": "admin", "password": "wrong"]))
        }
        let done = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.20", "username": "admin", "password": "secret"]))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.deviceID == "95270000ABCDEFGH")
        #expect(outcome.settings == ["host": "192.168.1.20"])
        #expect(outcome.credentials?["username"] == "admin" && outcome.credentials?["password"] == "secret")

        environment.http.state.withLockedValue { $0.unreachable = true }
        await #expect(throws: SetupError("No Reolink device answered at 192.168.1.60. A battery camera on its own may be asleep: wake it (press its button, or move in front of it) and try again.")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.60", "password": "secret"]))
        }
        environment.http.state.withLockedValue { $0.unreachable = false }

        // Kept as the bridge keeps it, the host is reached from its Accessory Settings under its Device Id.
        try await plugin.context.saveCredentials(try #require(outcome.credentials), for: "95270000ABCDEFGH")
        await host.stop()
        let again = try await environment.start(["_accessories": ["95270000ABCDEFGH": ["host": "192.168.1.20"]]])
        defer { Task { await again.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let rediscovered = try await #require(environment.plugin).discover()
        #expect(rediscovered.contains { $0.deviceID == "95270000ABCDEFGH" && $0.isSetUp })
        #expect(!rediscovered.contains { $0.deviceID.hasPrefix(ReolinkPlugin.byAddressID) && $0.address == "192.168.1.20" })
    }

    @Test func canonicalSettingsMoveCameraOptions() async throws {
        let environment = ReolinkEnvironment()
        let settings: [String: Any] = ["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["siren": true, "name": "Drive"]]]]]
        let host = try await environment.start(settings)
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let plugin = try #require(environment.plugin)
        let block = try JSONValue(any: settings.merging(["platform": "Reolink"]) { a, _ in a })
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["_accessories"]?["95270000ABCDEFGH"]?["siren"] == true)
        #expect(canonical["_accessories"]?["95270000ABCDEFGH"]?["name"] == "Drive")
        #expect(canonical["devices"]?[0]?["cameras"] == nil)
        #expect(canonical["devices"]?[0]?["host"] == "192.168.1.20")
    }

    @Test func schemaIsCurrent() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.schema.json")
        #expect(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == ReolinkPlugin.configurationSchemaJSON)
    }
}

import HomeswiftFFmpeg
