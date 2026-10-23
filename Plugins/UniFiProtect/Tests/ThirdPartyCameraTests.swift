import Foundation
import HomeswiftFFmpeg
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// A third-party camera with URLs of its own (`cameraOverrides`), which Protect reports disconnected, as the
/// TP-Link cameras of the live test did: snapshots from its snapshot URL or its RTSP stream, live streams and a
/// live view from its RTSP stream, none of it through the controller.
extension CameraStreamingTests {
    static let thirdPartyMAC = "F23E23931F5C"
    static let thirdPartyID = ProtectPlatform.accessoryID(thirdPartyMAC)
    static let thirdPartyRTSP = "rtsp://viewer:pass@192.168.2.100:8555/guest"

    /// The camera as Protect lists it: adopted, third-party, not connected.
    static func thirdPartyCamera() -> JSONValue {
        Fixtures.camera(id: "tp-id", mac: thirdPartyMAC, name: "Guest").setting("isThirdPartyCamera", true).setting("isConnected", false)
            .setting("marketName", "TP-Link C675D").setting("type", "TP-Link C675D")
    }

    func thirdPartyEnvironment(_ ffmpeg: FakeFfmpegKit, snapshotURL: String?, options: [String] = []) async throws -> (ProtectTestEnvironment, PluginHost) {
        let fake = FakeController(bootstrap: Fixtures.bootstrap(cameras: [Fixtures.camera(), Self.thirdPartyCamera()]))
        let environment = ProtectTestEnvironment(controller: fake, ffmpeg: ffmpeg, snapshotClock: FrozenClock())
        var override: [String: Any] = ["mac": "f2:3e:23:93:1f:5c", "rtspUrl": Self.thirdPartyRTSP]
        if let snapshotURL { override["snapshotUrl"] = snapshotURL }
        let host = try await environment.start(options: options, extra: ["cameraOverrides": [override]])
        _ = await controller(environment, host, Self.thirdPartyID)
        return (environment, host)
    }

    @Test func thirdPartySnapshotsFromTheCameraItself() async throws {
        let ffmpeg = FakeFfmpegKit()
        let (environment, host) = try await thirdPartyEnvironment(ffmpeg, snapshotURL: "http://viewer:se%40cret@192.168.2.100/camera-snapshot?channel=1")
        defer { Task { await host.stop() } }
        let stream = try #require(await stream(environment.device("tp-id")))
        let image = try await stream.handleSnapshotRequest(SnapshotRequest(height: 360, width: 640))
        #expect(image == Data([0xFF, 0xD8, 0xCA]))
        // Basic from the URL's credentials first, then Digest when the camera asks for it; never the controller.
        let requests = environment.controller.requests("/camera-snapshot")
        #expect(requests.count == 2)
        #expect(requests.first?.headers["authorization"] == "Basic " + Data("viewer:se@cret".utf8).base64EncodedString())
        #expect(requests.last?.headers["authorization"]?.hasPrefix("Digest username=\"viewer\"") == true)
        #expect(environment.controller.requests.allSatisfy { !$0.path.hasSuffix("/snapshot") })
        #expect(ffmpeg.execs.isEmpty)
    }

    @Test func thirdPartySnapshotsAndStreamsFromItsRTSPURL() async throws {
        let ffmpeg = FakeFfmpegKit()
        // Even without higher quality snapshots: the RTSP stream is the camera's only source of pixels.
        let (environment, host) = try await thirdPartyEnvironment(ffmpeg, snapshotURL: nil, options: ["Disable.Video.HighResSnapshots"])
        defer { Task { await host.stop() } }
        let stream = try #require(await stream(environment.device("tp-id")))
        let image = try await stream.handleSnapshotRequest(SnapshotRequest(height: 360, width: 640))
        #expect(image == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let exec = try #require(ffmpeg.execs.last)
        #expect(exec.arguments.contains(Self.thirdPartyRTSP) && exec.arguments.contains("-skip_frame"))
        // Protect has it disconnected: its snapshot API is not asked.
        #expect(environment.controller.requests.allSatisfy { !$0.path.hasSuffix("/snapshot") })
        // HomeKit streams from the RTSP URL too.
        _ = try await stream.prepareStream(prepare())
        try await stream.handleStreamRequest(start())
        let process = try #require(ffmpeg.streams.last)
        #expect(process.argument(after: "-i") == Self.thirdPartyRTSP)
        try await stream.handleStreamRequest(.stop(sessionID: "session-1"))
    }

    @Test func thirdPartyLiveViewThroughFFmpeg() async throws {
        let ffmpeg = FakeFfmpegKit()
        let (environment, host) = try await thirdPartyEnvironment(ffmpeg, snapshotURL: nil)
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let pending = Task { try await plugin.liveFeed(accessoryID: Self.thirdPartyID) }
        let process = try #require(await eventually { !ffmpeg.processes.isEmpty } ? ffmpeg.processes.last : nil)
        #expect(process.argument(after: "-i") == Self.thirdPartyRTSP && process.argument(after: "-codec:v") == "copy" && process.arguments.contains("-an"))
        #expect(process.argument(after: "-movflags") == "frag_keyframe+empty_moov+default_base_moof" && process.arguments.last == "pipe:1")
        #expect(await eventually { process.state.withLockedValue { !$0.stdoutHandlers.isEmpty } })
        // FFmpeg's output arrives in pieces that do not follow the boxes.
        let moof = Self.box("moof", Data([1])), mdat = Self.box("mdat", Data([2, 3]))
        let output = Self.liveInitSegment + moof + mdat
        process.output(output.prefix(7))
        process.output(output.dropFirst(7).prefix(Self.liveInitSegment.count + 3))
        process.output(output.dropFirst(Self.liveInitSegment.count + 10))
        let feed = try #require(try await pending.value)
        #expect(feed.initSegment == Self.liveInitSegment)
        #expect(feed.mimeType == #"video/mp4; codecs="avc1.4d4028""#)
        var fragments = feed.fragments.makeAsyncIterator()
        #expect(try await fragments.next() == moof + mdat)
        // No livestream API session for it.
        #expect(!environment.webSockets.connections.contains { $0.path.contains("livestream") })
        // The viewer leaves: FFmpeg goes.
        feed.cancel()
        #expect(process.isStopped)
        #expect(try await fragments.next() == nil)
    }

    @Test func rtspSnapshotInputWithoutAFrameRate() {
        let channel = ProtectChannel(["id": 0, "name": "High", "width": 1920, "height": 1080, "fps": 0])
        let entry = RtspEntry(channel: channel, name: "1920x1080", resolution: VideoResolution(1920, 1080, 0), url: "rtsp://camera/stream")
        #expect(!ProtectSnapshot.rtspInput(entry, probesize: 16384).contains("-r"))
        let withRate = RtspEntry(channel: ProtectChannel(["fps": 20]), name: "", resolution: VideoResolution(1920, 1080, 20), url: "rtsp://camera/stream")
        #expect(ProtectSnapshot.rtspInput(withRate, probesize: 16384).contains("-r"))
    }

    @Test func fragmentedMP4Splitter() {
        var splitter = FMp4FeedSplitter()
        let header = Self.box("ftyp", Data("isom".utf8)) + Self.box("moov", Data([9]))
        let first = Self.box("moof", Data([1])) + Self.box("mdat", Data([2]))
        let second = Self.box("moof", Data([3])) + Self.box("mdat", Data([4]))
        let all = header + first + second
        var initSegments: [Data] = []
        var fragments: [Data] = []
        for byte in all {
            let output = splitter.push(Data([byte]))
            if let initSegment = output?.initSegment { initSegments.append(initSegment) }
            fragments += output?.fragments ?? []
        }
        #expect(initSegments == [header])
        #expect(fragments == [first, second])
        // A corrupt size ends the feed.
        #expect(splitter.push(Data([0, 0, 0, 1, 0x6D, 0x6F, 0x6F, 0x66])) == nil)
    }
}
