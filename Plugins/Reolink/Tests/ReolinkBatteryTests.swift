import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftReolink

/// Standalone battery cameras (docs/clean-room/ReolinkBattery.md): the spec's vectors, the on-demand connection policy,
/// snapshots, live media and the plugin's Setup and accessory, on `FakeBatteryCamera`.
@Suite(.timeLimit(.minutes(1))) struct ReolinkBatteryTests {
    static let accessoryID = "Reolink:\(FakeBatteryCamera.uid)"

    // MARK: Vectors (12)

    @Test func headersFromTheSpec() {
        let ext = Baichuan.channelExtension(0).utf8.count
        #expect(ext == 104)
        let preview = Baichuan.previewBody(channel: 0, stream: .sub, start: true).utf8.count
        let stop = Baichuan.previewBody(channel: 0, stream: .sub, start: false).utf8.count
        let snap = Baichuan.snapBody(channel: 0, stream: .sub).utf8.count
        let webhook = Baichuan.webhookBody(url: "http://192.168.1.10:51828/reolink/0123456789abcdef").utf8.count
        #expect([preview, stop, snap, webhook] == [Int]([171, 136, 209, 196]))
        let media = Baichuan.MediaStream.sub.code | 0x18 << 8
        #expect(hex(Baichuan.header(command: 3, bodyLength: ext + preview, channel: 1, counter: media, extensionLength: ext))
            == "f0 de bc 0a 03 00 00 00 13 01 00 00 01 01 18 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 4, bodyLength: ext + stop, channel: 1, counter: media, extensionLength: ext))
            == "f0 de bc 0a 04 00 00 00 f0 00 00 00 01 01 18 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 109, bodyLength: ext + snap, channel: 1, counter: 0x19, extensionLength: ext))
            == "f0 de bc 0a 6d 00 00 00 39 01 00 00 01 19 00 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 253, bodyLength: ext, channel: 1, counter: 0x1A, extensionLength: ext))
            == "f0 de bc 0a fd 00 00 00 68 00 00 00 01 1a 00 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 806, bodyLength: 0, channel: 250, counter: 0x1C, extensionLength: 0))
            == "f0 de bc 0a 26 03 00 00 00 00 00 00 fa 1c 00 00 00 00 14 64 00 00 00 00")
        #expect(hex(Baichuan.header(command: 807, bodyLength: webhook, channel: 250, counter: 0x1B, extensionLength: 0))
            == "f0 de bc 0a 27 03 00 00 c4 00 00 00 fa 1b 00 00 00 00 14 64 00 00 00 00")
    }

    static let expectedFrames: [BcMediaFrame] = [
        .info(width: 2304, height: 1296, fps: 15),
        .video(codec: .h264, keyframe: true, timestamp: 123_456_789, payload: MediaVectors.iPayload),
        .video(codec: .h265, keyframe: false, timestamp: 123_490_122, payload: MediaVectors.pPayload),
        .aac(MediaVectors.aacPayload),
    ]

    @Test func mediaFramesFromTheSpec() throws {
        var parser = BcMediaParser()
        #expect(try parser.push(MediaVectors.all) == Self.expectedFrames)
        #expect(parser.pendingCount == 0)
        // Split at every position, across two messages.
        for split in 1..<MediaVectors.all.count {
            var parser = BcMediaParser()
            let frames = try parser.push(Array(MediaVectors.all[..<split])) + parser.push(Array(MediaVectors.all[split...]))
            #expect(frames == Self.expectedFrames, "split at \(split)")
        }
        // Garbage before the first magic is skipped.
        var garbage = BcMediaParser()
        #expect(try garbage.push([1, 2, 3, 4, 5, 6] + MediaVectors.all) == Self.expectedFrames)
        // A duplicate P-frame is dropped.
        var duplicate = BcMediaParser()
        #expect(try duplicate.push(MediaVectors.info + MediaVectors.iFrame + MediaVectors.pFrame + MediaVectors.pFrame) == Array(Self.expectedFrames.prefix(3)))
        // Audio before the first video frame is pre-record audio.
        var early = BcMediaParser()
        #expect(try early.push(MediaVectors.aac + MediaVectors.iFrame) == [Self.expectedFrames[1]])
        // A magic split `30 30 64` | `63 …`.
        var straddling = BcMediaParser()
        let first = try straddling.push([9, 9] + Array(MediaVectors.iFrame.prefix(3)))
        #expect(first.isEmpty)
        #expect(try straddling.push(Array(MediaVectors.iFrame.dropFirst(3))) == [Self.expectedFrames[1]])
    }

    @Test func aFrameTooLargeEndsTheStream() {
        var parser = BcMediaParser()
        let header = Array("00dcH264".utf8) + Baichuan.littleEndian(UInt32(BcMediaParser.maximumFrame + 1)) + [UInt8](repeating: 0, count: 12)
        #expect(throws: BcMediaError.self) { try parser.push(header) }
    }

    @Test func remuxedToMPEGTS() throws {
        var parser = BcMediaParser()
        var muxer = BcMediaMuxer(audio: true)
        var output: [UInt8] = []
        for frame in try parser.push(MediaVectors.stream) { output += muxer.push(frame) }
        #expect(muxer.codec == .h264)
        #expect(muxer.fps == 15)
        #expect(muxer.hasAudio)
        #expect(output.count % 188 == 0 && !output.isEmpty)
        let packets = stride(from: 0, to: output.count, by: 188).map { Array(output[$0..<($0 + 188)]) }
        #expect(packets.allSatisfy { $0[0] == 0x47 })
        let pids = Set(packets.map { UInt16($0[1] & 0x1F) << 8 | UInt16($0[2]) })
        #expect(pids == [0, 0x1000, 0x100, 0x101])
        // The PAT: program 1 on PID 0x1000, its CRC over the section.
        let pat = packets[0]
        #expect(Array(pat[5..<17]) == [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00])
        #expect(BcMediaMuxer.crc32(Array(pat[5..<21])) == 0)
        // The PMT: H.264 and ADTS.
        let pmt = packets[1]
        #expect(pmt[5 + 12] == 0x1B && pmt[5 + 17] == 0x0F)
        #expect(BcMediaMuxer.crc32(Array(pmt[5..<(5 + 3 + Int(pmt[7]))])) == 0)
        // The first PES starts at 90000 (1 s).
        #expect(BcMediaMuxer.ptsBytes(90000) == [0x21, 0x00, 0x05, 0xBF, 0x21])
        // Without audio the header comes with the first I-frame; P-frames before it are dropped.
        var video = BcMediaMuxer(audio: false)
        #expect(video.push(.video(codec: .h264, keyframe: false, timestamp: 0, payload: [1])).isEmpty)
        #expect(!video.push(.video(codec: .h264, keyframe: true, timestamp: 10, payload: [2])).isEmpty)
        #expect(BcMediaMuxer.forward(from: 0xFFFF_FFF0, to: 0x10) == 0x20)
    }

    @Test func framesWaitingForAudioAreCapped() {
        // Audio asked, none comes, timestamps stuck: the header goes without audio once the cap is reached.
        var muxer = BcMediaMuxer(audio: true)
        let frame = BcMediaFrame.video(codec: .h264, keyframe: true, timestamp: 5, payload: [UInt8](repeating: 1, count: 1000))
        for _ in 1..<BcMediaMuxer.pendingFrames { #expect(muxer.push(frame).isEmpty) }
        #expect(!muxer.push(frame).isEmpty)
        #expect(!muxer.hasAudio)
        // And by bytes: three frames of 4 MiB.
        var large = BcMediaMuxer(audio: true)
        let big = BcMediaFrame.video(codec: .h264, keyframe: true, timestamp: 5, payload: [UInt8](repeating: 1, count: 4 * 1024 * 1024))
        #expect(large.push(big).isEmpty)
        #expect(!large.push(big).isEmpty)
    }

    @Test func webhookBodiesFromTheSpec() async throws {
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.asleep = true }
        let host = makeHost(camera)
        let states = NIOLockedValueBox<[ReolinkChannelState]>([])
        await host.setListener { state in states.withLockedValue { $0.append(state) } }
        let bodies = [
            #"{"uid": "95270000AAAAAAAA", "data": {"event": "wake", "reason": "pir"}}"#,
            #"{"uid": "95270000AAAAAAAA", "data": {"event": "sleep"}}"#,
            #"{"uid": "95270000AAAAAAAA", "cmd": 252, "xml": "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<BatteryList version=\"1.1\">\n<BatteryInfo>\n<channelId>0</channelId>\n<chargeStatus>charging</chargeStatus>\n<adapterStatus>solarPanel</adapterStatus>\n<voltage>4083</voltage>\n<current>-396</current>\n<temperature>32</temperature>\n<batteryPercent>87</batteryPercent>\n<lowPower>0</lowPower>\n<batteryVersion>2</batteryVersion>\n</BatteryInfo>\n</BatteryList>\n</body>\n"}"#,
            #"{"uid": "95270000BBBBBBBB", "data": {"event": "wake", "reason": "doorbell"}}"#,
        ].map { try! JSONValue(data: Data($0.utf8)) }
        #expect(await host.handleWebhook(bodies[0]))
        #expect(await host.currentState.motion)
        #expect(await host.handleWebhook(bodies[1]))
        #expect(await host.currentState.asleep)
        #expect(await host.handleWebhook(bodies[2]))
        let state = await host.currentState
        #expect(state.batteryPercent == 87 && state.charging == true && state.batteryLow == false)
        #expect(await host.record.battery?.adapter == "solarPanel")
        #expect(await host.handleWebhook(bodies[3]) == false)
        #expect(!states.withLockedValue { $0 }.contains { $0.visitor })
        // Motion goes off by itself: a sleeping camera says nothing more.
        #expect(await eventually { await host.currentState.motion == false })
        // The wake tried to read the battery and the snapshot, and the camera was asleep: nothing more.
        #expect(camera.connections == 0)
        await host.stop()
    }

    // MARK: The session

    func makeHost(_ camera: FakeBatteryCamera, record: ReolinkBatteryHost.Record? = nil, image: URL? = nil,
                  saved: NIOLockedValueBox<[ReolinkBatteryHost.Record]> = .init([]),
                  toJPEG: (@Sendable (BcMediaCodec, [UInt8]) async -> Data?)? = nil) -> ReolinkBatteryHost {
        let device = ReolinkPlugin.Device(json: ["host": "192.168.1.50", "password": "secret", "batteryCamera": true])!
        let identity = ReolinkBatteryIdentity(uid: FakeBatteryCamera.uid, name: "Garden", model: "Argus 3 Pro", serial: "1", hardware: "", firmware: "")
        return ReolinkBatteryHost(device: device, record: record ?? .init(identity: identity, battery: nil, webhookSupported: nil),
                                  connect: { _, _, _ in try camera.connect() }, log: testLogger, timing: ReolinkTiming(scale: 0.01), motionTimeout: 30,
                                  imageFile: image, saveRecord: { record in saved.withLockedValue { $0.append(record) } }, toJPEG: toJPEG)
    }

    @Test func aSnapshotComesInPartsOnAnyMessageNumber() async throws {
        let camera = FakeBatteryCamera()
        let host = makeHost(camera)
        let image = try await host.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .event))
        #expect(image.count == 23_644)
        #expect(Array(image) == camera.state.withLockedValue { $0.jpeg })
        let snap = try #require(camera.requests.first { $0.command == 109 })
        #expect(snap.body.contains("<streamType>sub</streamType>"))
        // The camera is let sleep: logged out and closed 5 s (scaled) after the last request.
        #expect(await eventually { camera.count(2) == 1 && camera.state.withLockedValue { $0.closed } == 1 })
        #expect(await host.isAwake == false)
        await host.stop()
    }

    @Test func aSleepingCameraIsAnsweredFromTheCache() async throws {
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.asleep = true }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-reolink-battery-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0xFF, 0xD8, 1, 0xFF, 0xD9]).write(to: file)
        let host = makeHost(camera, image: file)
        // Periodic: never a wake, whatever the image's age.
        #expect(try await host.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .periodic)) == Data([0xFF, 0xD8, 1, 0xFF, 0xD9]))
        #expect(camera.connections == 0)
        // An event and an old image: the camera is asked, and asleep: the cache answers.
        #expect(try await host.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .event)) == Data([0xFF, 0xD8, 1, 0xFF, 0xD9]))
        // Awake again: the new image replaces the cache (and is kept on disk).
        camera.state.withLockedValue { $0.asleep = false }
        let fresh = try await host.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .event))
        #expect(fresh.count == 23_644)
        #expect(try Data(contentsOf: file) == fresh)
        // A periodic request with nothing cached and the camera asleep fails without a wake.
        let empty = makeHost(camera)
        camera.state.withLockedValue { $0.asleep = true }
        await #expect(throws: HAPStatusError.self) { try await empty.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .periodic)) }
        await host.stop()
        await empty.stop()
    }

    @Test func aWakingCameraIsAskedAgain() async throws {
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.waking = 2 }
        let host = makeHost(camera)
        // A budget as wide as `eventually`'s: the retries' waits are scaled, a loaded runner's scheduling is not.
        let battery = try await host.use(budget: 30) { session in try await session.battery(channel: 0) }
        #expect(battery?.percent == 87)
        #expect(camera.count(253) == 3)
        await host.stop()
    }

    @Test func liveMediaOverBaichuan() async throws {
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.media = MediaVectors.stream }
        let host = makeHost(camera)
        let feed = try await host.liveFeed(sub: true, audio: true)
        #expect(feed.stream.codec == "h264")
        #expect(feed.stream.width == 2304 && feed.stream.fps == 15)
        var output: [UInt8] = []
        for try await chunk in feed.data {
            output += chunk
            if output.count >= 188 * 30 { break }
        }
        #expect(output.first == 0x47 && output.count % 188 == 0)
        await feed.stop()
        let start = try #require(camera.requests.first { $0.command == 3 })
        let stop = try #require(camera.requests.first { $0.command == 4 })
        // Byte 13 is the stream code (sub: 1); the stop repeats bytes 12 to 15 and has no `streamType`.
        #expect(start.raw[13] == 1)
        #expect(Array(stop.raw[12..<16]) == Array(start.raw[12..<16]))
        #expect(start.body.contains("<streamType>subStream</streamType>") && start.body.contains("<handle>256</handle>"))
        #expect(!stop.body.contains("streamType"))
        // After the stream, a snapshot while the camera is still up; then it sleeps.
        #expect(await eventually { camera.count(109) == 1 })
        #expect(await eventually { camera.count(2) == 1 })
        #expect(camera.connections == 1)
        await host.stop()
    }

    @Test func aBrokenStreamStillStopsTheCamera() async throws {
        // No snapshot command, and the stream's second frame is over the limit: the keyframe fallback fails, and the camera
        // is told to stop sending all the same.
        let camera = FakeBatteryCamera()
        let tooLarge = Array("00dcH264".utf8) + Baichuan.littleEndian(UInt32(BcMediaParser.maximumFrame + 1)) + [UInt8](repeating: 0, count: 12)
        camera.state.withLockedValue {
            $0.snapshotWorks = false
            $0.media = MediaVectors.info + tooLarge
        }
        let host = makeHost(camera, toJPEG: { _, _ in Data([0xFF, 0xD8]) })
        await #expect(throws: HAPStatusError.self) { try await host.snapshot(for: SnapshotRequest(height: 360, width: 640, reason: .event)) }
        #expect(camera.count(3) == 1 && camera.count(4) == 1)
        await host.stop()
    }

    @Test func aFeedNobodyReadsEndsAndStopsTheCamera() async throws {
        // FFmpeg stalled: the feed's chunks are not read; past the buffer it ends, the camera stops, nothing piles up.
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue {
            let frames: [[UInt8]] = (0..<(ReolinkBatteryHost.feedChunks + 200)).map { (index: Int) -> [UInt8] in
                let nal: UInt8 = index == 0 ? 0x65 : 0x41
                var payload: [UInt8] = [0, 0, 0, 1, nal, UInt8(index & 0xFF), UInt8(index >> 8)]
                payload += [UInt8](repeating: 7, count: 200)
                return MediaVectors.h264(keyframe: index == 0, timestamp: UInt32(index * 66_000), payload: payload)
            }
            $0.media = MediaVectors.info + Array(frames.joined())
            $0.mediaChunk = 16_000
        }
        let host = makeHost(camera)
        let feed = try await host.liveFeed(sub: true, audio: true)
        #expect(await eventually { camera.count(4) == 1 })
        await #expect(throws: ReolinkBatteryHost.ReolinkFeedError.self) { for try await _ in feed.data {} }
        await feed.stop()
        #expect(camera.count(4) == 1)
        await host.stop()
    }

    // MARK: The plugin

    @Test func setupFindsABatteryCameraAndItsAccessory() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        environment.http.state.withLockedValue { $0.unreachable = true }
        let camera = FakeBatteryCamera()
        environment.batteryCamera.withLockedValue { $0 = camera }
        let bridge = try await environment.start([:])
        let plugin = try #require(environment.plugin)
        let done = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.50", "username": "admin", "password": "secret"]))
        guard case .done(let outcome) = done else {
            Issue.record("no outcome")
            return
        }
        #expect(outcome.deviceID == FakeBatteryCamera.uid)
        #expect(outcome.settings["batteryCamera"] == true)
        // Its webhook points at the bridge, on the camera's network, with the secret path.
        let url = camera.state.withLockedValue { $0.webhookURL }
        #expect(url.hasPrefix("http://192.168.1.10:") && url.contains("/reolink/"))
        await bridge.stop()

        // A block with the camera: published from what Setup kept, without waking it.
        camera.state.withLockedValue { $0.asleep = true }
        let before = camera.connections
        let host = try await environment.start(["devices": [["host": "192.168.1.50", "password": "secret", "batteryCamera": true]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.accessoryID) != nil })
        let accessory = try #require(environment.accessory(host, Self.accessoryID))
        #expect(accessory.information.characteristic(.model).value == "Argus 3 Pro")
        #expect(accessory.information.characteristic(.serialNumber).value == "00000000000042")
        let battery = try #require(accessory.service(.battery))
        #expect(battery.characteristic(.batteryLevel).value == 87)
        #expect(accessory.service(.motionSensor) != nil)
        #expect(accessory.service(.cameraRTPStreamManagement) != nil)
        #expect(accessory.service(.cameraRecordingManagement) == nil)
        #expect(!accessory.isUnavailable)
        #expect(camera.connections == before)

        // A wake by motion posted to the webhook.
        let plugin2 = try #require(environment.plugin)
        await plugin2.webhookReceived(Data(#"{"uid": "95270000AAAAAAAA", "data": {"event": "wake", "reason": "pir"}}"#.utf8))
        let motion = try #require(accessory.service(.motionSensor))
        #expect(await eventually { motion.characteristic(.motionDetected).value == true })
    }

    @Test func aBatteryDoorbellRings() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.model = "Reolink Video Doorbell Battery" }
        environment.batteryCamera.withLockedValue { $0 = camera }
        let host = try await environment.start(["devices": [["host": "192.168.1.50", "password": "secret", "batteryCamera": true]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.accessoryID) != nil })
        let accessory = try #require(environment.accessory(host, Self.accessoryID))
        #expect(accessory.category == .videoDoorbell)
        let doorbell = try #require(accessory.service(.doorbell))
        let plugin = try #require(environment.plugin)
        let presses = NIOLockedValueBox(0)
        doorbell.characteristic(.programmableSwitchEvent).observe { _ in presses.withLockedValue { $0 += 1 } }
        await plugin.webhookReceived(Data(#"{"uid": "95270000AAAAAAAA", "data": {"event": "wake", "reason": "doorbell"}}"#.utf8))
        #expect(await eventually { presses.withLockedValue { $0 } == 1 })
    }

    @Test func aUDPOnlyCameraIsRefusedAtSetup() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        environment.http.state.withLockedValue { $0.unreachable = true }
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue { $0.netPort = 0x41 }
        environment.batteryCamera.withLockedValue { $0 = camera }
        let bridge = try await environment.start([:])
        defer { Task { await bridge.stop() } }
        let plugin = try #require(environment.plugin)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.168.1.50", "username": "admin", "password": "secret"]))
        }
    }

    @Test func anotherReceiversWebhookIsKept() async throws {
        let camera = FakeBatteryCamera()
        camera.state.withLockedValue {
            $0.webhookURL = "http://192.168.1.5:8123/api/webhook/abc"
            $0.webhookEnabled = true
        }
        let host = makeHost(camera)
        let outcome = try await host.use(budget: 30) { session in
            try await ReolinkBatteryHost.subscribe(session, url: "http://192.168.1.10:1/reolink/x", path: "/reolink/x", takeOver: false)
        }
        #expect(outcome == .taken("192.168.1.5"))
        #expect(camera.count(807) == 0)
        let taken = try await host.use(budget: 30) { session in
            try await ReolinkBatteryHost.subscribe(session, url: "http://192.168.1.10:1/reolink/x", path: "/reolink/x", takeOver: true)
        }
        #expect(taken == .subscribed)
        #expect(camera.state.withLockedValue { $0.webhookURL } == "http://192.168.1.10:1/reolink/x")
        await host.stop()
    }

    @Test func theWebhookPathAndAddress() {
        #expect(ReolinkWebhookServer.matches("/reolink/abc?x=1", path: "/reolink/abc"))
        #expect(!ReolinkWebhookServer.matches("/reolink/abd", path: "/reolink/abc"))
        let networks = [IPv4Network(address: 0x7F00_0001, netmask: 0xFF00_0000), IPv4Network(address: 0x0A00_0005, netmask: 0xFF00_0000),
                        IPv4Network(address: 0xC0A8_010A, netmask: 0xFFFF_FF00)]
        #expect(ReolinkWebhookServer.localAddress(toward: "192.168.1.50", networks: networks) == "192.168.1.10")
        #expect(ReolinkWebhookServer.localAddress(toward: "camera.local", networks: networks) == "10.0.0.5")
    }

    @Test func theWebhookTakesSixteenConnectionsAtOnce() async throws {
        let server = ReolinkWebhookServer(token: "abc")
        try await server.start(host: "127.0.0.1", port: 0) { _ in }
        let port = try #require(server.port)
        var streams: [TCPStream] = []
        for _ in 0..<ReolinkWebhookServer.maximumConnections {
            streams.append(try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(5)))
        }
        #expect(await eventually { server.openConnections == ReolinkWebhookServer.maximumConnections })
        // One more is closed at once: its stream ends.
        let extra = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        do { for try await _ in extra.incoming {} } catch {}
        #expect(server.openConnections == ReolinkWebhookServer.maximumConnections)
        // A closed one frees its place.
        await streams.removeLast().close()
        #expect(await eventually { server.openConnections == ReolinkWebhookServer.maximumConnections - 1 })
        for stream in streams { await stream.close() }
        await extra.close()
        await server.stop()
    }
}
