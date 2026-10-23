import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftFFmpeg

/// A mocked host, as ffmpeg-codecs.test.ts mocks `node:process`, `node:os`, `node:fs` and `execFile`.
final class MockHost: Sendable {
    typealias Responder = @Sendable (String, [String]) -> Result<String, FfmpegCommandError>

    let calls = NIOLockedValueBox<[(command: String, args: [String])]>([])
    let responder: NIOLockedValueBox<Responder>
    let platform: String
    let cpuModel: String?
    let modelFile: String?

    init(platform: String = "linux", cpuModel: String? = "Generic CPU", modelFile: String? = nil, respond: @escaping Responder = MockHost.healthy) {
        self.platform = platform
        self.cpuModel = cpuModel
        self.modelFile = modelFile
        self.responder = NIOLockedValueBox(respond)
    }

    var environment: FfmpegHostEnvironment {
        let modelFile = self.modelFile
        return FfmpegHostEnvironment(
            platform: platform, cpuModel: cpuModel, deviceModel: { modelFile },
            run: { command, args throws(FfmpegCommandError) in
                self.calls.withLockedValue { $0.append((command, args)) }
                return try self.responder.withLockedValue { $0 }(command, args).get()
            },
            path: "/usr/bin:/bin"
        )
    }

    static let VERSION_OUTPUT = "ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers\nbuilt with Apple clang\n"

    static let CODECS_OUTPUT = [
        "Codecs:",
        " D..... = Decoding supported",
        " -------",
        " DEV.LS h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (decoders: h264 h264_qsv H264_V4L2M2M ) (encoders: libx264 h264_qsv "
            + "h264_videotoolbox )",
        " DEV.L. hevc                 H.265 / HEVC (High Efficiency Video Coding) (decoders: hevc hevc_qsv )",
        " DEA.L. aac                  AAC (Advanced Audio Coding) (decoders: aac aac_fixed libfdk_aac ) (encoders: aac aac_at libfdk_aac )",
        " D.V.L. av1                  Alliance for Open Media AV1",
        "",
    ].joined(separator: "\n")

    static let HWACCELS_OUTPUT = ["Hardware acceleration methods:", "videotoolbox", "QSV", ""].joined(separator: "\n")

    /// A healthy FFmpeg installation.
    static let healthy: Responder = { command, args in
        if command == "vcgencmd" { return .success("gpu=256M\n") }
        if args.contains("-version") { return .success(VERSION_OUTPUT) }
        if args.contains("-codecs") { return .success(CODECS_OUTPUT) }
        if args.contains("-hwaccels") { return .success(HWACCELS_OUTPUT) }
        // Hardware acceleration validation runs.
        return .success("")
    }

    func codecs(log: LogRecorder = LogRecorder(), ffmpegExec: String? = nil, verbose: Bool = false) -> FfmpegCodecs {
        FfmpegCodecs(ffmpegExec: ffmpegExec, log: log.logger, verbose: verbose, environment: environment)
    }
}

@Suite struct FfmpegCodecsHostDetectionTests {
    @Test func defaultsToAGenericHost() {
        let codecs = MockHost().codecs()
        #expect(codecs.hostSystem == "generic")
        #expect(codecs.cpuGeneration == 0)
        #expect(codecs.gpuMem == 0)
        #expect(codecs.ffmpegVersion == "")
        #expect(codecs.ffmpegExec == "ffmpeg")
        #expect(codecs.verbose == false)
    }

    @Test func detectsAppleSiliconAndItsGeneration() {
        let codecs = MockHost(platform: "darwin", cpuModel: "Apple M3 Pro").codecs()
        #expect(codecs.hostSystem == "macOS.Apple")
        #expect(codecs.cpuGeneration == 3)
    }

    @Test func reportsGenerationZeroForUnrecognizedAppleModels() {
        let codecs = MockHost(platform: "darwin", cpuModel: "Apple processor").codecs()
        #expect(codecs.hostSystem == "macOS.Apple")
        #expect(codecs.cpuGeneration == 0)
    }

    @Test func detectsIntelMacs() {
        let codecs = MockHost(platform: "darwin", cpuModel: "Intel(R) Core(TM) i7-8850H CPU @ 2.60GHz").codecs()
        #expect(codecs.hostSystem == "macOS.Intel")
        #expect(codecs.cpuGeneration == 0)
    }

    @Test(arguments: [
        ("Raspberry Pi 4 Model B Rev 1.4", "raspbian"), ("Raspberry Pi Compute Module 4 Rev 1.0", "raspbian"), ("Raspberry Pi 5 Model B Rev 1.0", "generic"),
    ])
    func detectsRaspberryPi4(model: String, host: String) {
        #expect(MockHost(modelFile: model).codecs().hostSystem == host)
    }

    @Test(arguments: [
        ("Intel(R) Core(TM) i7-920 CPU @ 2.67GHz", 1), ("Intel(R) Core(TM) i5-8500 CPU @ 3.00GHz", 8), ("Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz", 10),
        ("12th Gen Intel(R) Core(TM) i5-12400", 12), ("Intel(R) Celeron(R) N5105 @ 2.00GHz", 0),
    ])
    func derivesTheIntelGeneration(model: String, generation: Int) {
        #expect(MockHost(cpuModel: model).codecs().cpuGeneration == generation)
    }

    @Test func degradesWithoutCPUInformation() {
        let codecs = MockHost(cpuModel: nil).codecs()
        #expect(codecs.hostSystem == "generic")
        #expect(codecs.cpuGeneration == 0)
    }

    @Test func ignoresUnsupportedPlatforms() {
        let codecs = MockHost(platform: "win32", cpuModel: "Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz").codecs()
        #expect(codecs.hostSystem == "generic")
        #expect(codecs.cpuGeneration == 0)
    }

    @Test func readsThisHost() {
        // Whatever the machine, the real environment yields a known host family.
        let codecs = FfmpegCodecs(log: Logger(label: "test"))
        #expect(["generic", "macOS.Apple", "macOS.Intel", "raspbian"].contains(codecs.hostSystem))
    }
}

@Suite struct FfmpegCodecsProbingTests {
    @Test func parsesTheVersionCodecsAndAccelerators() async {
        let host = MockHost()
        let log = LogRecorder()
        let codecs = host.codecs(log: log, ffmpegExec: "/opt/ffmpeg")
        #expect(await codecs.probe())
        #expect(codecs.ffmpegVersion == "8.0.1")
        #expect(log.messages(.info) == ["Using FFmpeg version: 8.0.1."])

        #expect(codecs.hasDecoder("h264", "h264_qsv"))
        #expect(codecs.hasDecoder("H264", "h264_v4l2m2m"))
        #expect(codecs.hasDecoder("hevc", "hevc_qsv"))
        #expect(!codecs.hasDecoder("hevc", "hevc_videotoolbox"))
        #expect(!codecs.hasDecoder("av1", "av1_qsv"))
        #expect(!codecs.hasDecoder("vp9", "vp9"))
        #expect(codecs.hasEncoder("h264", "H264_VIDEOTOOLBOX"))
        #expect(codecs.hasEncoder("aac", "aac_at"))
        #expect(codecs.hasEncoder("aac", "libfdk_aac"))
        #expect(!codecs.hasEncoder("hevc", "hevc_qsv"))

        #expect(codecs.hasHwAccel("videotoolbox"))
        #expect(codecs.hasHwAccel("qsv"))
        #expect(!codecs.hasHwAccel("cuda"))

        let calls = host.calls.withLockedValue { $0 }
        #expect(calls.map(\.command) == Array(repeating: "/opt/ffmpeg", count: 5))
        #expect(calls.map(\.args) == [
            ["-hide_banner", "-version"],
            ["-hide_banner", "-codecs"],
            ["-hide_banner", "-hwaccels"],
            ["-hide_banner", "-hwaccel", "videotoolbox", "-v", "quiet", "-t", "1", "-f", "lavfi", "-i", "color=black:1920x1080", "-c:v", "libx264", "-f", "null", "-"],
            ["-hide_banner", "-hwaccel", "qsv", "-v", "quiet", "-t", "1", "-f", "lavfi", "-i", "color=black:1920x1080", "-c:v", "libx264", "-f", "null", "-"],
        ])
    }

    @Test func warnsWithoutLibx264() async {
        // DSM's /bin/ffmpeg: H.264 decodes, but nothing encodes it.
        let host = MockHost { command, args in
            if args.contains("-version") { return .success("ffmpeg version 4.1.9 Copyright (c) 2000-2022 the FFmpeg developers\n") }
            if args.contains("-codecs") { return .success(" DEV.LS h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (decoders: h264 )\n") }
            return MockHost.healthy(command, args)
        }
        let log = LogRecorder()
        #expect(await host.codecs(log: log, ffmpegExec: "/bin/ffmpeg").probe())
        #expect(log.messages(.warning) == [
            "FFmpeg 4.1.9 at '/bin/ffmpeg' has no libx264 encoder: HomeKit Secure Video recordings and livestreams fail unless a hardware encoder takes over. Use an FFmpeg built with libx264."
        ])

        let healthyLog = LogRecorder()
        _ = await MockHost().codecs(log: healthyLog).probe()
        #expect(healthyLog.messages(.warning).isEmpty)
    }

    @Test func recordsAnUnknownVersion() async {
        let host = MockHost { command, args in args.contains("-version") ? .success("something unexpected") : MockHost.healthy(command, args) }
        let codecs = host.codecs()
        #expect(await codecs.probe())
        #expect(codecs.ffmpegVersion == "unknown")
    }

    @Test func discardsAcceleratorsThatFailValidationLoggingOnlyWhenVerbose() async {
        let failValidation: MockHost.Responder = { command, args in
            args.contains("-hwaccel") && args.contains("qsv") ? .failure(.failed("Command failed")) : MockHost.healthy(command, args)
        }
        let quietLog = LogRecorder()
        let quiet = MockHost(respond: failValidation).codecs(log: quietLog)
        #expect(await quiet.probe())
        #expect(!quiet.hasHwAccel("qsv"))
        #expect(quiet.hasHwAccel("videotoolbox"))
        #expect(quietLog.messages(.error).isEmpty)

        let verboseLog = LogRecorder()
        let verbose = MockHost(respond: failValidation).codecs(log: verboseLog, verbose: true)
        _ = await verbose.probe()
        #expect(verboseLog.messages(.error) == [
            "Hardware-accelerated decoding and encoding using qsv will be unavailable: unable to successfully validate capabilities."
        ])
    }

    @Test func failsWhenFFmpegCannotBeFound() async {
        let host = MockHost { _, _ in .failure(.notFound) }
        let log = LogRecorder()
        let codecs = host.codecs(log: log)
        #expect(await codecs.probe() == false)
        #expect(log.messages(.error) == ["Unable to find 'ffmpeg' in path: '/usr/bin:/bin'."])
        #expect(host.calls.withLockedValue { $0.count } == 1)
    }

    @Test func failsAndExplainsWhenFFmpegErrorsWhileProbingCodecs() async {
        let host = MockHost { command, args in args.contains("-codecs") ? .failure(.failed("Segmentation fault.")) : MockHost.healthy(command, args) }
        let log = LogRecorder()
        let codecs = host.codecs(log: log)
        #expect(await codecs.probe() == false)
        #expect(log.messages(.error) == [
            "Error running ffmpeg: Segmentation fault.",
            "Unable to probe the capabilities of your Homebridge host without access to 'ffmpeg'. Ensure that it is available in your path and correctly working.",
        ])
        // We never get as far as probing hardware accelerators.
        #expect(!host.calls.withLockedValue { $0.contains { $0.args.contains("-hwaccels") } })
    }

    @Test func failsWhenTheAcceleratorListingCannotBeRetrieved() async {
        let host = MockHost { command, args in args.contains("-hwaccels") ? .failure(.failed("boom")) : MockHost.healthy(command, args) }
        #expect(await host.codecs().probe() == false)
    }

    @Test func probesRaspberryPiGPUMemoryFirst() async {
        let host = MockHost(modelFile: "Raspberry Pi 4 Model B Rev 1.4")
        let codecs = host.codecs()
        #expect(await codecs.probe())
        #expect(codecs.gpuMem == 256)
        let first = host.calls.withLockedValue { $0.first }
        #expect(first?.command == "vcgencmd")
        #expect(first?.args == ["get_mem", "gpu"])
    }

    @Test func treatsUnparseableGPUMemoryAsZero() async {
        let host = MockHost(modelFile: "Raspberry Pi 4 Model B Rev 1.4") { command, args in
            command == "vcgencmd" ? .success("error=1\n") : MockHost.healthy(command, args)
        }
        let codecs = host.codecs()
        _ = await codecs.probe()
        #expect(codecs.gpuMem == 0)
    }

    @Test func doesNotProbeGPUMemoryElsewhere() async {
        let host = MockHost()
        _ = await host.codecs().probe()
        #expect(!host.calls.withLockedValue { $0.contains { $0.command == "vcgencmd" } })
    }

    @Test func runsRealCommands() async throws {
        // The real runner: standard output on success, Node's "Command failed" message otherwise, notFound for a missing command.
        #expect(try await runCommand("/bin/sh", ["-c", "printf 'gpu=128M\\n'"]) == "gpu=128M\n")
        await #expect(throws: FfmpegCommandError.failed("Command failed: /bin/sh -c echo oops >&2; exit 3\noops\n")) {
            try await runCommand("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        }
        await #expect(throws: FfmpegCommandError.notFound) { try await runCommand("homeswift-no-such-command", []) }
        // Large outputs are read while the command runs.
        #expect(try await runCommand("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done"]).count == 220_000)
    }
}
