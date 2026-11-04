import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOCore
import NIOPosix
import Testing

@testable import Homeswift
@testable import HomeswiftIPCameras

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(IPCamerasPlugin.Configuration.self, from: Data("""
            { "platform": "Camera-ffmpeg", "cameras": [ { "name": "Front Door", "videoConfig": { "source": "-i rtsp://u:p@10.0.0.5:554/s1" } } ] }
            """.utf8))
        #expect(configuration.mqttHost == nil && configuration.httpPort == nil)
        let camera = try #require(configuration.cameras.first)
        #expect(camera.name == "Front Door")
        #expect(camera.manufacturer == "Homebridge" && camera.model == "Camera FFmpeg" && camera.serialNumber == "SerialNumber")
        let video = try #require(camera.videoConfig)
        #expect(video.maxStreams == 2 && video.vcodec == "libx264" && video.packetSize == 1316)
        #expect(video.maxWidth == nil && !video.audio && !video.audioExplicitlyOff && !video.prebuffer)
    }

    @Test func theFullAutomationBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(IPCamerasPlugin.Configuration.self, from: Data("""
            { "platform": "Camera-ffmpeg", "mqtt": "127.0.0.1", "portmqtt": 1883, "usermqtt": "hb", "passmqtt": "secret",
              "porthttp": "8080", "localhttp": true, "unbridge": true, "topic": "legacy",
              "cameras": [ { "name": "Front Door", "motion": true, "doorbell": true, "switches": true, "motionTimeout": 15, "motionDoorbell": false,
                             "hflip": true,
                             "videoConfig": { "source": "-rtsp_transport tcp -i rtsp://u:p@10.0.0.5:554/s1", "stillImageSource": "-i http://10.0.0.5/snap.jpg",
                                              "maxStreams": 2, "maxWidth": 1280, "maxHeight": 720, "maxFPS": 30, "audio": true, "recording": true,
                                              "prebuffer": false },
                             "mqtt": { "motionTopic": "home/camera", "motionMessage": "ON", "motionResetTopic": "home/camera",
                                       "motionResetMessage": "OFF", "doorbellTopic": "home/doorbell", "doorbellMessage": "ON" } } ] }
            """.utf8))
        #expect(configuration.mqttHost == "127.0.0.1" && configuration.mqttPort == 1883 && configuration.mqttUsername == "hb")
        #expect(configuration.mqttPassword == "secret")
        #expect(configuration.httpPort == 8080 && configuration.httpLocalOnly)
        let camera = try #require(configuration.cameras.first)
        #expect(camera.motion && camera.doorbell && camera.switches && camera.motionTimeout == 15)
        #expect(camera.videoConfig?.recording == true && camera.videoConfig?.maxWidth == 1280)
        #expect(camera.mqtt?.motionResetMessage == "OFF")
    }

    @Test func optionsAreReadForTheirTruthiness() throws {
        let video = try videoConfig(["source": "-i x", "audio": false, "maxStreams": "3", "vcodec": "", "packetSize": 0, "prebuffer": true])
        #expect(video.audioExplicitlyOff && !video.audio)
        #expect(video.maxStreams == 3 && video.vcodec == "libx264" && video.packetSize == 1316)
        // The prebuffer needs recording.
        #expect(!video.prebuffer)
        let configuration = IPCamerasPlugin.Configuration(json: try JSONValue(any: ["portmqtt": 0, "porthttp": 0, "tlsmqtt": 1, "mqtt": ""]))
        #expect(configuration.mqttPort == 1883 && configuration.httpPort == nil && configuration.mqttTLS && configuration.mqttHost == nil)
    }

    @Test func passmqttLeavesTheBlock() throws {
        let block = try JSONValue(string: #"{"platform":"Camera-ffmpeg","mqtt":"broker","usermqtt":"hb","passmqtt":"secret"}"#)
        let canonical = IPCamerasPlugin.canonical(block)
        #expect(canonical["passmqtt"] == nil && canonical["usermqtt"] == "hb")
        #expect(IPCamerasPlugin.canonical(canonical) == canonical)
    }

    @Test func cameraOptionsMoveIntoAccessorySettings() throws {
        let block = try JSONValue(string: """
            {"platform":"Camera-ffmpeg","_accessories":{"Front Door":{"motionTimeout":30}},
             "cameras":[{"name":"Front Door","motion":true,"motionTimeout":15,"videoConfig":{"source":"-i x"}},{"videoConfig":{"source":"-i y"},"doorbell":true}]}
            """)
        let canonical = IPCamerasPlugin.canonical(block)
        #expect(canonical["_accessories"]?["Front Door"]?["motion"] == true)
        // What the Accessory Settings hold already wins.
        #expect(canonical["_accessories"]?["Front Door"]?["motionTimeout"] == 30)
        #expect(canonical["cameras"]?[0]?["motion"] == nil && canonical["cameras"]?[0]?["videoConfig"]?["source"] == "-i x")
        // An unnamed camera has no Device Id yet: its options stay.
        #expect(canonical["cameras"]?[1]?["doorbell"] == true)
        #expect(IPCamerasPlugin.canonical(canonical) == canonical)
        // Read back, the settings are the camera's.
        let camera = IPCamerasPlugin.Camera(json: try #require(canonical["cameras"]?[0])).with(settings: try #require(canonical["_accessories"]?["Front Door"]?.objectValue))
        #expect(camera.motion && camera.motionTimeout == 30)
    }

    @Test func identityVectors() {
        #expect(IPCamerasPlugin.hapUUID("Front Door") == "4ffef822-6592-43bb-898a-028dd181bd69")
        #expect(IPCamerasPlugin.hapUUID("Camera Name") == "727c22f8-f330-4b78-9226-010e5d64a283")
        #expect(IPCamerasPlugin.hapUUID("Camera 1") == "404d3fda-a266-4712-a3f1-18a7efa9eddf")
    }

    @Test func camerasAreCheckedInOrder() throws {
        let cameras = try [
            ["videoConfig": ["source": "-i a"]],
            ["name": "No video"],
            ["name": "No source", "videoConfig": ["source": ""]],
            ["name": "Camera 1", "videoConfig": ["source": "-i b"]],
            ["name": "Garden", "videoConfig": ["source": "rtsp://c"]],
            [:],
        ].map { IPCamerasPlugin.Camera(json: try JSONValue(any: $0)) }
        let accepted = IPCamerasPlugin.accept(cameras, logger: testLogger)
        // The unnamed first is Camera 1, so the named Camera 1 is a duplicate; a source without -i is kept; the
        // unnamed last one, Camera 3, has no videoConfig.
        #expect(accepted.map(\.name) == ["Camera 1", "Garden"])
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(IPCamerasPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/IPCameras IPCamerasPlugin")
        let schema = try JSONValue(string: try #require(IPCamerasPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Camera-ffmpeg")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AutomationTests {
    func triggers(motion: Bool = true, doorbell: Bool = true, switches: Bool = true, motionTimeout: Int? = 15, motionDoorbell: Bool = false,
                  timeScale: Double = 1) -> (CameraTriggers, motion: Service?, doorbell: Service?, motionSwitch: Service?, doorbellSwitch: Service?) {
        let sensor = motion ? Service(.motionSensor, name: "Front Door") : nil
        let bell = doorbell ? Service(.doorbell) : nil
        let motionSwitch = motion && switches ? Service(.switch, subtype: "MotionTrigger") : nil
        let doorbellSwitch = doorbell && switches ? Service(.switch, subtype: "DoorbellTrigger") : nil
        let log = CameraLog(logger: testLogger, name: "Front Door", promotesDebug: false)
        return (CameraTriggers(log: log, motionTimeout: motionTimeout, motionDoorbell: motionDoorbell, timeScale: timeScale, motionSensor: sensor,
                               motionSwitch: motionSwitch, doorbell: bell, doorbellSwitch: doorbellSwitch), sensor, bell, motionSwitch, doorbellSwitch)
    }

    @Test func theHTTPVectors() async {
        let (front, _, _, _, _) = triggers()
        let (noBell, _, _, _, _) = triggers(doorbell: false)
        let cameras = ["Front Door": front, "Side": noBell]
        func get(_ target: String) async -> (Int, String) {
            let (status, body) = await HTTPAutomation.respond(to: target, cameras: cameras)
            return (status, body)
        }
        #expect(await get("/motion?Front%20Door") == (200, #"{"error":false,"message":"Motion switched on.","cooldownActive":false}"#))
        #expect(await get("/motion?Front%20Door=anything") == (200, #"{"error":false,"message":"Motion switched on.","cooldownActive":true}"#))
        #expect(await get("/motion/reset?Front%20Door=") == (200, #"{"error":false,"message":"Motion switched off."}"#))
        #expect(await get("/doorbell?Front%20Door") == (200, #"{"error":false,"message":"Doorbell switched on."}"#))
        #expect(await get("/motion?Back%20Yard") == (500, #"{"error":true,"message":"Camera \"Back Yard\" not found."}"#))
        #expect(await get("/motion") == (500, #"{"error":true,"message":"Malformed URL."}"#))
        #expect(await get("/motion?a?b") == (500, #"{"error":true,"message":"Malformed URL."}"#))
        #expect(await get("/motion?Front%ZZ") == (500, #"{"error":true,"message":"Malformed URL."}"#))
        #expect(await get("/light?Front%20Door") == (500, #"{"error":true,"message":"First directory level must be \"motion\" or \"doorbell\", got \"light\"."}"#))
        #expect(await get("/?Front%20Door") == (500, #"{"error":true,"message":"First directory level must be \"motion\" or \"doorbell\", got \"undefined\"."}"#))
        #expect(await get("/doorbell?Side") == (500, #"{"error":true,"message":"Doorbell is not enabled for this camera."}"#))
        await front.cancel()
    }

    @Test func motionResetsAfterItsTimeout() async throws {
        let (camera, sensor, _, motionSwitch, _) = triggers(motionTimeout: 15, timeScale: 0.001)
        let detected = try #require(sensor?[.motionDetected])
        await camera.motion(true, minimumTimeout: 0)
        #expect(detected.value == .bool(true) && motionSwitch?[.on]?.value == .bool(true))
        #expect(await eventually { detected.value == .bool(false) })
        #expect(motionSwitch?[.on]?.value == .bool(false))
    }

    @Test func aZeroTimeoutKeepsMotionUntilItIsReset() async throws {
        let (camera, sensor, bell, _, _) = triggers(motionTimeout: 0, motionDoorbell: true, timeScale: 0.001)
        let detected = try #require(sensor?[.motionDetected])
        #expect(await camera.motion(true, minimumTimeout: 0).cooldownActive == false)
        // No timer runs, so the doorbell rings each time and cooldown is never active.
        #expect(await camera.motion(true, minimumTimeout: 0).cooldownActive == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(detected.value == .bool(true))
        _ = bell
        // The trigger switch resets after a second all the same.
        await camera.motion(true, minimumTimeout: 1)
        #expect(await eventually { detected.value == .bool(false) })
    }

    @Test func theDoorbellSwitchTurnsItselfOff() async throws {
        let (camera, _, _, _, doorbellSwitch) = triggers(motionTimeout: 15, timeScale: 0.001)
        let on = try #require(doorbellSwitch?[.on])
        #expect(await camera.doorbell() == TriggerResult(error: false, message: "Doorbell switched on."))
        #expect(on.value == .bool(true))
        #expect(await eventually { on.value == .bool(false) })
        #expect(await camera.motion(false, minimumTimeout: 0) == TriggerResult(error: false, message: "Motion switched off."))
    }

    @Test func disabledSensorsSaySo() async {
        let (camera, _, _, _, _) = triggers(motion: false, doorbell: false)
        #expect(await camera.motion(true, minimumTimeout: 0) == .failure("Motion is not enabled for this camera."))
        #expect(await camera.doorbell() == .failure("Doorbell is not enabled for this camera."))
    }

    @Test func mqttRoutesMatchExactly() throws {
        let (front, _, _, _, _) = triggers()
        let (back, _, _, _, _) = triggers()
        var routes = MQTTRoutes()
        routes.register(camera: "Front Door", mqtt: IPCamerasPlugin.CameraMQTT(json: try JSONValue(any: [
            "motionTopic": "home/camera", "motionMessage": "ON", "motionResetTopic": "home/camera", "motionResetMessage": "OFF", "doorbellTopic": "home/doorbell",
        ])), triggers: front)
        routes.register(camera: "Back", mqtt: IPCamerasPlugin.CameraMQTT(json: try JSONValue(any: ["motionTopic": "homebridge/motion"])), triggers: back)
        #expect(routes.topics == ["home/camera", "home/doorbell", "homebridge/motion"])
        #expect(routes.matching(topic: "home/camera", payload: Data("ON".utf8)).map(\.action) == [.motion])
        #expect(routes.matching(topic: "home/camera", payload: Data("OFF".utf8)).map(\.action) == [.motionReset])
        #expect(routes.matching(topic: "home/camera", payload: Data("on".utf8)).isEmpty)
        #expect(routes.matching(topic: "home/camera", payload: Data(" ON".utf8)).isEmpty)
        // A message left empty is the camera's name.
        #expect(routes.matching(topic: "home/doorbell", payload: Data("Front Door".utf8)).map(\.action) == [.doorbell])
        #expect(routes.matching(topic: "homebridge/motion", payload: Data("Back".utf8)).map(\.action) == [.motion])
    }

    @Test func theHTTPServerAnswersOnTheLoopbackAndSurvivesNonsense() async throws {
        let (front, _, _, _, _) = triggers()
        let server = HTTPAutomationServer()
        let port = try await server.start(port: 0, localOnly: true, handler: { target in
            await HTTPAutomation.respond(to: target, cameras: ["Front Door": front])
        }, logger: testLogger)
        defer { Task { await server.stop() } }
        func get(_ target: String) async throws -> String {
            String(decoding: try await TCPProbe.send(Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8), port: port), as: UTF8.self)
        }

        let rung = try await get("/doorbell?Front%20Door")
        #expect(rung.hasPrefix("HTTP/1.1 200"))
        #expect(rung.hasSuffix(#"{"error":false,"message":"Doorbell switched on."}"#))

        // Garbage on the socket closes that connection, and the server goes on.
        try await TCPProbe.send(Data("NOT HTTP AT ALL\r\n\r\n\u{0}\u{1}".utf8), port: port)
        // An invalid escape, which crashed the original, is a malformed URL.
        let answer = try await get("/motion?Front%ZZ")
        #expect(answer.hasPrefix("HTTP/1.1 500"))
        #expect(answer.hasSuffix(#"{"error":true,"message":"Malformed URL."}"#))
        await server.stop()
    }
}

/// Writes bytes to a local TCP port and returns what comes back until the server closes the connection.
enum TCPProbe {
    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        var received = Data()

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { received.append(contentsOf: bytes) }
        }
    }

    @discardableResult
    static func send(_ data: Data, port: Int) async throws -> Data {
        let collector = Collector()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) } }
            .connect(host: "127.0.0.1", port: port).get()
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: data)).get()
        try await channel.closeFuture.get()
        return try await channel.eventLoop.submit { collector.received }.get()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    let environment = TestEnvironment()

    func block(_ cameras: [[String: Any]], _ more: [String: Any] = [:]) throws -> [String: Any] {
        var settings: [String: Any] = ["cameras": cameras, "videoProcessor": try environment.fakeFFmpeg().path]
        settings.merge(more) { $1 }
        return settings
    }

    @Test func eachCameraIsAnAccessoryOfItsOwn() async throws {
        let host = try await environment.start(try block([
            ["name": "Front Door", "motion": true, "doorbell": true, "switches": true,
             "videoConfig": ["source": "-i rtsp://u:p@10.0.0.5:554/s1", "returnAudioTarget": "-f adts udp://camera:5000", "recording": true, "maxStreams": 3]],
            ["name": "Garden", "videoConfig": ["source": "-i rtsp://garden/s1"]],
        ]))
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil && environment.accessory(host, named: "Garden") != nil })
        let front = try #require(environment.accessory(host, named: "Front Door"))
        #expect(front.id == "Camera-ffmpeg:Front Door")
        #expect(front.category == .videoDoorbell)
        #expect(front.services.filter { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid }.count == 3)
        #expect(front.service(.microphone) != nil && front.service(.speaker) != nil)
        #expect(front.service(.cameraRecordingManagement) != nil && front.service(.cameraOperatingMode) != nil)
        #expect(front.service(.motionSensor) != nil && front.service(.doorbell) != nil)
        let switches = front.services.filter { $0.type.uuid == ServiceType.switch.uuid }.compactMap(\.subtype)
        #expect(Set(switches) == ["MotionTrigger", "DoorbellTrigger"])
        #expect(front.information[.manufacturer]?.value == .string("Homebridge"))

        let garden = try #require(environment.accessory(host, named: "Garden"))
        #expect(garden.category == .ipCamera)
        #expect(garden.services.filter { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid }.count == 2)
        #expect(garden.service(.microphone) != nil && garden.service(.speaker) == nil && garden.service(.cameraRecordingManagement) == nil)
        #expect(garden.service(.motionSensor) == nil && garden.service(.doorbell) == nil)
        #expect(host.mainBridge.server.accessories.allSatisfy { !$0.id.hasPrefix("Camera-ffmpeg:") })

        let devices = try await #require(environment.plugin).discover()
        #expect(devices.map(\.deviceID).sorted() == ["Front Door", "Garden"])
        #expect(devices.allSatisfy { $0.isSetUp && $0.kind == "camera" })
        await host.stop()
    }

    @Test func theMotionTriggerSwitchDrivesTheSensor() async throws {
        let host = try await environment.start(try block([
            ["name": "Front Door", "motion": true, "switches": true, "motionTimeout": 0, "videoConfig": ["source": "-i rtsp://cam/s1"]],
        ]))
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let accessory = try #require(environment.accessory(host, named: "Front Door"))
        let trigger = try #require(accessory.services.first { $0.subtype == "MotionTrigger" }?[.on])
        let detected = try #require(accessory.service(.motionSensor)?[.motionDetected])
        try await trigger.writeHandler(for: .bool(true))?(.bool(true))
        #expect(detected.value == .bool(true))
        // The switch resets after a second (scaled), even with a motion timeout of 0.
        #expect(await eventually { detected.value == .bool(false) })
        await host.stop()
    }

    @Test func mqttMessagesTriggerTheCameras() async throws {
        let host = try await environment.start(try block([
            ["name": "Front Door", "motion": true, "doorbell": true, "switches": true, "motionTimeout": 15,
             "videoConfig": ["source": "-i rtsp://cam/s1"],
             "mqtt": ["motionTopic": "home/camera", "motionMessage": "ON", "motionResetTopic": "home/camera", "motionResetMessage": "OFF",
                      "doorbellTopic": "home/doorbell", "doorbellMessage": "ON"]],
        ], ["mqtt": "127.0.0.1", "usermqtt": "hb", "passmqtt": "secret"]))
        let mqtt = environment.mqtt
        #expect(await eventually { mqtt.isConnected && mqtt.subscriptions.count == 2 })
        let accessory = try #require(environment.accessory(host, named: "Front Door"))
        let detected = try #require(accessory.service(.motionSensor)?[.motionDetected])
        let doorbellSwitch = try #require(accessory.services.first { $0.subtype == "DoorbellTrigger" }?[.on])

        mqtt.receive("home/camera", string: "ON")
        #expect(await eventually { detected.value == .bool(true) })
        mqtt.receive("home/camera", string: "OFF")
        #expect(await eventually { detected.value == .bool(false) })
        mqtt.receive("home/doorbell", string: "ON")
        #expect(await eventually { doorbellSwitch.value == .bool(true) })
        #expect(await eventually { doorbellSwitch.value == .bool(false) })
        await host.stop()
    }

    @Test func snapshotsComeFromFFmpegAndAreCachedBriefly() async throws {
        let environment = TestEnvironment(timeScale: 1)
        let ffmpeg = try environment.fakeFFmpeg()
        let host = try await environment.start([
            "videoProcessor": ffmpeg.path, "cameras": [["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]],
        ])
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let accessory = try #require(environment.accessory(host, named: "Front Door"))
        let controller = try #require(accessory.cameraController)
        let image = try await controller.previewSnapshot(width: 640, height: 360)
        #expect(String(decoding: image, as: UTF8.self) == "IMAGE")
        _ = try await controller.previewSnapshot(width: 320, height: 180)
        let runs = try String(contentsOf: ffmpeg.runs, encoding: .utf8).split(separator: "\n")
        // One fetch for both, each resized for its own size.
        #expect(runs.filter { $0.contains("-frames:v 1 -f image2 - -hide_banner") }.count == 1)
        #expect(runs.filter { $0.hasPrefix("-i pipe:") }.count == 2)
        await host.stop()
    }

    /// Found on real cameras: FFmpeg's RTP input gives up when HomeKit sends no return audio, which ended the whole stream
    /// after ten seconds. The two-way FFmpeg now starts with HomeKit's first packet, and its end leaves the stream running.
    @Test func twoWayAudioStartsWithTheFirstPacketAndLeavesTheStreamAlone() async throws {
        let environment = TestEnvironment(timeScale: 1)
        let ffmpeg = try environment.fakeFFmpeg()
        let host = try await environment.start([
            "videoProcessor": ffmpeg.path,
            "cameras": [["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1", "returnAudioTarget": "-f adts udp://camera:5000"]]],
        ])
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let streamer = try #require(await environment.plugin?.cameras["Front Door"]?.streamer)
        let source = PrepareStreamRequest.Source(port: 50000, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 1, count: 16),
                                                 srtpSalt: Data(repeating: 2, count: 14))
        let prepared = try await streamer.prepareStream(PrepareStreamRequest(
            sessionID: "talk", sourceAddress: "127.0.0.1", targetAddress: "127.0.0.1", addressVersion: .ipv4, video: source, audio: source))
        try await streamer.handleStreamRequest(.start(startRequest(sessionID: "talk")))
        @Sendable func twoWayRuns() -> Int {
            ((try? String(contentsOf: ffmpeg.runs, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("-f sdp") }.count
        }
        #expect(twoWayRuns() == 0)

        // HomeKit talks: an RTP packet (payload type 110) on the audio return port.
        let talker = try await UDPSocket.bind(host: "127.0.0.1", port: 0)
        let port = try #require(prepared.audio?.port)
        try await talker.send(Data([0x80, 110, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]), to: "127.0.0.1", port: port)
        #expect(await eventually { twoWayRuns() == 1 })
        // The fake two-way FFmpeg read its SDP and ended; the stream goes on, and talking again starts another.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await streamer.sessionCount == 1)
        try await talker.send(Data([0x80, 110, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1]), to: "127.0.0.1", port: port)
        #expect(await eventually { twoWayRuns() == 2 })
        await talker.close()
        await host.stop()
        #expect(await eventually { await streamer.sessionCount == 0 })
    }

    @Test func streamsStartOnFFmpegsFirstLineAndStopWithThePlugin() async throws {
        // Real timings: a shortened inactivity timeout could end the stream before it is looked at, under load.
        let environment = TestEnvironment(timeScale: 1)
        let host = try await environment.start([
            "videoProcessor": try environment.fakeFFmpeg().path, "cameras": [["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]],
        ])
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let streamer = try #require(await environment.plugin?.cameras["Front Door"]?.streamer)
        let source = PrepareStreamRequest.Source(port: 50000, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 1, count: 16),
                                                 srtpSalt: Data(repeating: 2, count: 14))
        let prepared = try await streamer.prepareStream(PrepareStreamRequest(
            sessionID: "s1", sourceAddress: "127.0.0.1", targetAddress: "127.0.0.1", addressVersion: .ipv4, video: source, audio: source))
        #expect(prepared.video.srtpKey == source.srtpKey && prepared.video.port > 0 && prepared.audio?.port != prepared.video.port)
        try await streamer.handleStreamRequest(.start(startRequest(sessionID: "s1")))
        #expect(await streamer.sessionCount == 1)
        await host.stop()
        #expect(await eventually { await streamer.sessionCount == 0 })
    }

    @Test func aStreamNobodyWatchesStops() async throws {
        let environment = TestEnvironment(timeScale: 0.02)
        let host = try await environment.start([
            "videoProcessor": try environment.fakeFFmpeg().path, "cameras": [["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]],
        ])
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let streamer = try #require(await environment.plugin?.cameras["Front Door"]?.streamer)
        let source = PrepareStreamRequest.Source(port: 50000, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 1, count: 16),
                                                 srtpSalt: Data(repeating: 2, count: 14))
        _ = try await streamer.prepareStream(PrepareStreamRequest(
            sessionID: "s2", sourceAddress: "127.0.0.1", targetAddress: "127.0.0.1", addressVersion: .ipv4, video: source, audio: source))
        try await streamer.handleStreamRequest(.start(startRequest(sessionID: "s2")))
        // No RTCP comes: after 30 seconds (scaled) the stream stops.
        #expect(await eventually { await streamer.sessionCount == 0 })
        await host.stop()
    }

    @Test func recordingsAreCutIntoFragments() async throws {
        let host = try await environment.start(try block([["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1", "recording": true]]]))
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let recorder = try #require(await environment.plugin?.cameras["Front Door"]?.recorder)
        // Without a configuration from HomeKit, nothing is sent.
        var empty = 0
        for try await _ in recorder.handleRecordingStreamRequest(streamID: 1) { empty += 1 }
        #expect(empty == 0)

        recorder.updateRecordingConfiguration(recordingConfiguration())
        var packets: [RecordingPacket] = []
        for try await packet in recorder.handleRecordingStreamRequest(streamID: 2) { packets.append(packet) }
        func box(_ type: String, _ payload: String = "") -> Data { Data([0, 0, 0, UInt8(8 + payload.utf8.count)]) + Data((type + payload).utf8) }
        #expect(packets.map(\.data) == [box("ftyp") + box("moov"), box("moof") + box("mdat", "1234"), Data()])
        // FFmpeg ended before the hub closed the stream: the last packet says so.
        #expect(packets.map(\.isLast) == [false, false, true])
        await host.stop()
    }

    @Test func theLiveViewRemuxesTheSource() async throws {
        let host = try await environment.start(try block([["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]]))
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let plugin = try #require(environment.plugin)
        let feed = try #require(try await plugin.liveFeed(accessoryID: IPCamerasPlugin.accessoryID(name: "Front Door")))
        func box(_ type: String, _ payload: String = "") -> Data { Data([0, 0, 0, UInt8(8 + payload.utf8.count)]) + Data((type + payload).utf8) }
        #expect(feed.initSegment == box("ftyp") + box("moov"))
        var fragments: [Data] = []
        for try await fragment in feed.fragments { fragments.append(fragment) }
        #expect(fragments == [box("moof") + box("mdat", "1234")])
        feed.cancel()
        #expect(try await plugin.liveFeed(accessoryID: "Camera-ffmpeg:Nobody") == nil)
        await host.stop()
    }

    @Test func anUnknownSessionFails() async throws {
        let host = try await environment.start(try block([["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]]))
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        let streamer = try #require(await environment.plugin?.cameras["Front Door"]?.streamer)
        await #expect(throws: HAPStatusError.self) { try await streamer.handleStreamRequest(.start(startRequest(sessionID: "unknown"))) }
        await host.stop()
    }

    @Test func setupAsksTheBrokersSignIn() async throws {
        let host = try await environment.start(try block([["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]]],
                                                         ["mqtt": "broker", "usermqtt": "hb"]))
        let plugin = try #require(environment.plugin)
        #expect(IPCamerasPlugin.accountAuthorization == .accountLogin)
        #expect(await plugin.accountAuthorized() == false)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else {
            Issue.record("the account's first step asks")
            return
        }
        #expect(prompt.fields.map(\.key) == ["usermqtt", "password"])
        #expect(prompt.fields.last?.kind == .secret)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["usermqtt": "hb", "password": "pw"], state: ["asked": true]))
        else {
            Issue.record("the answers finish it")
            return
        }
        #expect(outcome.credentials?["password"] == "pw" && outcome.settings["usermqtt"] == "hb")
        // A camera asks nothing.
        let camera = try #require(try await plugin.discover().first)
        guard case .done = try await plugin.authorize(SetupRequest(target: .device(camera))) else {
            Issue.record("a camera needs no authorization")
            return
        }
        // Homebridge's passmqtt leaves the block, for the vault.
        let block = try JSONValue(string: #"{"platform":"Camera-ffmpeg","mqtt":"broker","passmqtt":"secret"}"#)
        #expect(await plugin.canonicalSettings(block)["passmqtt"] == nil)
        await host.stop()
    }

    @Test func anExcludedCameraIsLeftOut() async throws {
        var settings = try block([
            ["name": "Front Door", "videoConfig": ["source": "-i rtsp://cam/s1"]], ["name": "Garden", "videoConfig": ["source": "-i rtsp://garden/s1"]],
        ])
        settings["_accessories"] = ["Garden": ["excluded": true]]
        let host = try await environment.start(settings)
        #expect(await eventually { environment.accessory(host, named: "Front Door") != nil })
        #expect(environment.accessory(host, named: "Garden") == nil)
        #expect(await environment.plugin?.cameras["Garden"] == nil)
        await host.stop()
    }
}
