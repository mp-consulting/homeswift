import Foundation
@testable import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import Testing

@testable import HomeswiftTapo

/// A real camera, only when asked: `TAPO_LIVE_HOST` (its address), `TAPO_LIVE_PASSWORD_FILE` (a file holding the
/// owner's cloud password), `TAPO_LIVE_OUTPUT` (where the MPEG-TS goes) and optionally `TAPO_LIVE_RESOLUTION` (`HD` or
/// `VGA`) and `TAPO_LIVE_BYTES`. Skipped otherwise, as in CI.
struct StreamdLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["TAPO_LIVE_HOST"] != nil), .timeLimit(.minutes(1)))
    func recordsASampleFromARealCamera() async throws {
        let host = try #require(Self.environment["TAPO_LIVE_HOST"])
        let passwordFile = try #require(Self.environment["TAPO_LIVE_PASSWORD_FILE"])
        let output = try #require(Self.environment["TAPO_LIVE_OUTPUT"])
        let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = Streamd.Resolution(rawValue: Self.environment["TAPO_LIVE_RESOLUTION"] ?? "HD") ?? .hd
        let wanted = Int(Self.environment["TAPO_LIVE_BYTES"] ?? "") ?? 4 * 1024 * 1024
        var logger = testLogger
        logger.logLevel = .trace
        let client = StreamdClient(host: host, password: { password }, connect: { host, port, timeout in
            try await TCPStream.connect(host: host, port: port, timeout: timeout)
        }, logger: logger)
        let started = ContinuousClock.now
        let session = try await client.open(resolution: resolution)
        let opened = ContinuousClock.now - started
        var sample = Data()
        for try await data in session.stream {
            sample.append(data)
            if sample.count >= wanted { break }
        }
        await session.close()
        try sample.write(to: URL(fileURLWithPath: output))
        print("Streamd live: session \(session.sessionID ?? "?"), opened in \(opened), \(sample.count) bytes in \(ContinuousClock.now - started)")
        #expect(sample.first == 0x47)
    }

    /// The live stream's FFmpeg command line, as the streamer makes it for a 1080p request, run on a recorded sample
    /// (`TAPO_LIVE_SAMPLE`) for each lens with the SRTP output swapped for a null one: it must encode in real time.
    @Test(.enabled(if: environment["TAPO_LIVE_SAMPLE"] != nil), .timeLimit(.minutes(1)))
    func theStreamCommandEncodesARecordedSample() async throws {
        let sample = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.environment["TAPO_LIVE_SAMPLE"])))
        let request = StartStreamRequest(
            sessionID: "s",
            video: VideoInfo(codec: 0, profile: 2, level: 2, packetizationMode: 0, cvoId: nil, width: 1920, height: 1080, fps: 15, pt: 99, ssrc: 1,
                             maxBitRate: 2000, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 2, maxBitRate: 24,
                             rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))
        let codecs = FfmpegCodecs(ffmpegExec: "ffmpeg", log: testLogger)
        _ = await codecs.probe()
        let ffmpeg = FfmpegOptions(FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: true, log: testLogger, name: { "Tapo" }))
        for lens in 0..<2 {
            var arguments = TapoCameraStreamer.arguments(videoIndex: lens, request: request, target: ("127.0.0.1", false, 50000, Data(repeating: 1, count: 30), 11),
                                                         ffmpeg: ffmpeg, inputFps: 15, debug: false)
            let output = try #require(arguments.firstIndex(of: "-payload_type"))
            arguments.replaceSubrange(output..<(arguments.firstIndex(of: "-loglevel") ?? arguments.endIndex), with: ["-f", "null", "-"])
            print("Lens \(lens): ffmpeg \(arguments.joined(separator: " "))")
            let started = ContinuousClock.now
            var filter = MPEGTSLensFilter(videoIndex: lens)
            let result = try #require(await FfmpegExec(ffmpeg, commandLineArgs: arguments).exec(filter.filter(sample), timeout: 50_000))
            let took = ContinuousClock.now - started
            print("Lens \(lens): exit \(result.exitCode.map(String.init) ?? "?") in \(took); \(String(decoding: result.stderr.suffix(400), as: UTF8.self))")
            #expect(result.exitCode == 0)
        }
    }
}
