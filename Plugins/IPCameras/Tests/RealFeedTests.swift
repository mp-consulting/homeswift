import Foundation
import HomeswiftFFmpeg
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftIPCameras

/// Real cameras, on demand: `CAMERA_FFMPEG_FEEDS` names a file of `<name> <rtsp(s)://…>` lines (kept out of the repository:
/// the URLs carry credentials, and nothing here prints them), `CAMERA_FFMPEG_OUTPUT` a directory for the snapshots, and
/// `CAMERA_FFMPEG_EXECUTABLE` the FFmpeg (`ffmpeg` by default). Each camera goes through the plugin's own delegates: a
/// snapshot, a live stream with audio to local UDP sockets for `CAMERA_FFMPEG_SECONDS` (20), and a HomeKit Secure Video
/// recording from the prebuffer. A feed whose name says `silent` has no audio. Skipped without the file, as in CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAMERA_FFMPEG_FEEDS"] != nil), .serialized)
struct RealFeedTests {
    struct Feed {
        var name: String
        var url: String
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Tab-separated lines, the last field the input: `<camera>\t<channel>\t<size>\t<rtsps://…>`, or FFmpeg input options
    /// (`-re -f lavfi -i testsrc2=…`) for a synthetic camera. A `#` line is left out.
    static func feeds() throws -> [Feed] {
        let text = try String(contentsOfFile: try #require(environment["CAMERA_FFMPEG_FEEDS"]), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t").map(String.init)
            guard let input = fields.last, fields.count > 1 else { return nil }
            return Feed(name: fields.dropLast().joined(separator: " "), url: input)
        }
    }

    /// The `source` of a feed: an RTSP URL over TCP after `CAMERA_FFMPEG_INPUT_OPTIONS` (a pinned certificate for
    /// RTSPS: `-ca_file <pem> -verifyhost <name>`), or the options as given.
    static func source(_ feed: Feed) -> String {
        let options = environment["CAMERA_FFMPEG_INPUT_OPTIONS"].map { $0 + " " } ?? ""
        return feed.url.hasPrefix("rtsp") ? options + "-rtsp_transport tcp -i \(feed.url)" : feed.url
    }

    static let executable = environment["CAMERA_FFMPEG_EXECUTABLE"] ?? "ffmpeg"
    static let seconds = Int(environment["CAMERA_FFMPEG_SECONDS"] ?? "") ?? 20

    static let logger: Logger = {
        var logger = Logger(label: "real-feeds")
        logger.logLevel = .info
        return logger
    }()

    func tools(_ name: String, capabilities: FFmpegCapabilities) -> (CameraLog, FFmpegTools) {
        (CameraLog(logger: Self.logger, name: name, promotesDebug: false),
         FFmpegTools(executable: Self.executable, capabilities: capabilities, name: name, logger: Self.logger, debug: false, debugReturn: false))
    }

    func report(_ text: String) {
        print("[real-feed] " + Masking.text(text))
    }

    @Test func snapshotsStreamsAndRecordings() async throws {
        let capabilities = FFmpegCapabilities(executable: Self.executable, logger: Self.logger)
        let output = URL(fileURLWithPath: Self.environment["CAMERA_FFMPEG_OUTPUT"] ?? FileManager.default.temporaryDirectory.path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        report("AAC-ELD encoder: \(await capabilities.aacELDEncoder() ?? ["none"]), decoder: \(await capabilities.aacELDDecoder())")
        for (index, feed) in try Self.feeds().enumerated() {
            let video = try videoConfig(["source": Self.source(feed), "audio": !feed.name.contains("silent"), "recording": true, "prebuffer": true,
                                         "maxWidth": 1280, "maxHeight": 720, "returnAudioTarget": "-f null -"])
            let (log, tools) = tools(feed.name, capabilities: capabilities)
            let streamer = CameraStreamer(video: video, log: log, tools: tools, ports: RtpPortAllocator())

            // (a) A snapshot through the delegate HomeKit calls.
            let started = ContinuousClock.now
            let image: Data
            do {
                image = try await streamer.handleSnapshotRequest(SnapshotRequest(height: 720, width: 1280))
            } catch {
                // An offline camera: the snapshot fails (HomeKit shows No Response), and nothing waits for it.
                report("\(feed.name): snapshot failed in \(ContinuousClock.now - started): \(error)")
                #expect(ContinuousClock.now - started < .seconds(30))
                continue
            }
            let file = output.appendingPathComponent("snapshot-\(index + 1).jpg")
            try image.write(to: file)
            report("\(feed.name): snapshot \(image.count) bytes in \(ContinuousClock.now - started), saved as \(file.lastPathComponent)")
            #expect(image.prefix(2) == Data([0xFF, 0xD8]))

            // (b) A live stream with audio, to UDP sockets standing in for the controller.
            let videoSocket = try await UDPSocket.bind(host: "127.0.0.1", port: 0)
            let audioSocket = try await UDPSocket.bind(host: "127.0.0.1", port: 0)
            let counts = NIOLockedValueBox((video: 0, videoBytes: 0, audio: 0, audioBytes: 0))
            let readers = [
                Task { for await datagram in videoSocket.datagrams { counts.withLockedValue { $0.video += 1; $0.videoBytes += datagram.data.count } } },
                Task { for await datagram in audioSocket.datagrams { counts.withLockedValue { $0.audio += 1; $0.audioBytes += datagram.data.count } } },
            ]
            func source(_ port: Int) -> PrepareStreamRequest.Source {
                PrepareStreamRequest.Source(port: port, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                                            srtpSalt: Data((0..<14).map { _ in UInt8.random(in: 0...255) }))
            }
            let session = "real-\(index)"
            let prepared = try await streamer.prepareStream(PrepareStreamRequest(
                sessionID: session, sourceAddress: "127.0.0.1", targetAddress: "127.0.0.1", addressVersion: .ipv4,
                video: source(try #require(videoSocket.localPort)), audio: source(try #require(audioSocket.localPort))))
            let streamStart = ContinuousClock.now
            try await streamer.handleStreamRequest(.start(startRequest(width: 1280, height: 720, fps: 30, bitrate: 802, rtcpInterval: 100, sessionID: session)))
            report("\(feed.name): stream started (first FFmpeg line) in \(ContinuousClock.now - streamStart)")
            // HomeKit talks halfway: one RTP packet on the audio return port starts the two-way FFmpeg.
            try await Task.sleep(for: .seconds(Self.seconds / 2))
            let talker = try await UDPSocket.bind(host: "127.0.0.1", port: 0)
            try await talker.send(Data([0x80, 110, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]), to: "127.0.0.1", port: try #require(prepared.audio?.port))
            await talker.close()
            try await Task.sleep(for: .seconds(Self.seconds - Self.seconds / 2))
            let sent = counts.withLockedValue { $0 }
            #expect(await streamer.sessionCount == 1, "the stream ran for the whole time")
            try await streamer.handleStreamRequest(.stop(sessionID: session))
            readers.forEach { $0.cancel() }
            await videoSocket.close()
            await audioSocket.close()
            report("\(feed.name): \(Self.seconds) s of SRTP: video \(sent.video) packets, \(sent.videoBytes * 8 / Self.seconds / 1000) kbit/s; "
                + "audio \(sent.audio) packets, \(sent.audioBytes * 8 / Self.seconds / 1000) kbit/s")
            #expect(sent.video > Self.seconds * 10)

            // (c) A HomeKit Secure Video recording from the prebuffer, from a camera's main stream.
            guard feed.name.contains("High") || !feed.url.hasPrefix("rtsp") else {
                await streamer.stopAll()
                continue
            }
            let prebuffer = Prebuffer(video: video, log: log, tools: tools)
            let recorder = CameraRecorder(video: video, log: log, tools: tools, prebuffer: prebuffer)
            try await prebuffer.start()
            try await Task.sleep(for: .seconds(8))
            recorder.updateRecordingConfiguration(recordingConfiguration(bitrate: 2000))
            var packets: [RecordingPacket] = []
            let recordingStart = ContinuousClock.now
            for try await packet in recorder.handleRecordingStreamRequest(streamID: index + 1) {
                packets.append(packet)
                if ContinuousClock.now - recordingStart > .seconds(16) || packets.count >= 5 { break }
            }
            recorder.closeRecordingStream(streamID: index + 1, reason: .normal)
            recorder.shutdown()
            let initialization = packets.first?.data ?? Data()
            report("\(feed.name): recording \(packets.count) packets (\(packets.map(\.data.count))) in \(ContinuousClock.now - recordingStart); "
                + "initialization \(String(decoding: initialization.dropFirst(4).prefix(4), as: UTF8.self)), audio track \(hasAudioTrack(initialization))")
            #expect(packets.count >= 2)
            await streamer.stopAll()
        }
    }
}
