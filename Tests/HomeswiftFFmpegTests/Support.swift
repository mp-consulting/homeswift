import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import Homeswift
@testable import HomeswiftFFmpeg

/// A log handler that records every message, as the TypeScript tests' `vi.fn()` loggers do.
struct RecordingLogHandler: LogHandler {
    let records: NIOLockedValueBox<[(level: Logger.Level, message: String)]>
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        records.withLockedValue { $0.append((event.level, event.message.description)) }
    }
}

/// A logger and what it recorded.
final class LogRecorder: Sendable {
    let records = NIOLockedValueBox<[(level: Logger.Level, message: String)]>([])

    var logger: Logger {
        let records = self.records
        return Logger(label: "test") { _ in RecordingLogHandler(records: records) }
    }

    var messages: [String] { records.withLockedValue { $0.map(\.message) } }

    func messages(_ level: Logger.Level) -> [String] { records.withLockedValue { $0.filter { $0.level == level }.map(\.message) } }

    /// Messages in the TypeScript tests' shape: `[level, message]`.
    var pairs: [[String]] {
        records.withLockedValue { records in
            records.map { record in
                let level = switch record.level {
                case .trace, .debug: "debug"
                case .info, .notice: "info"
                case .warning: "warn"
                case .error, .critical: "error"
                }
                return [level, record.message]
            }
        }
    }
}

/// The host profiles of ffmpeg-options.test.ts.
struct HostProfile: Sendable {
    var cpuGeneration = 0
    var decoders: [String] = []
    var encoders: [String] = []
    var gpuMem = 0
    var hostSystem: String
    var hwAccels: [String] = []
}

let MAC_ENCODERS = ["h264:h264_videotoolbox", "aac:aac_at", "aac:libfdk_aac"]
let QSV_DECODERS = ["h264:h264_qsv", "hevc:hevc_qsv", "av1:av1_qsv"]

let HOSTS: [String: HostProfile] = [
    "generic": HostProfile(encoders: ["aac:libfdk_aac"], hostSystem: "generic"),
    "generic-no-fdk": HostProfile(hostSystem: "generic"),
    "generic-qsv-gen10": HostProfile(cpuGeneration: 10, decoders: QSV_DECODERS, encoders: ["h264:h264_qsv", "aac:libfdk_aac"], hostSystem: "generic", hwAccels: ["qsv"]),
    "generic-qsv-gen12": HostProfile(cpuGeneration: 12, decoders: QSV_DECODERS, encoders: ["h264:h264_qsv", "aac:libfdk_aac"], hostSystem: "generic", hwAccels: ["qsv"]),
    "generic-qsv-no-hevc": HostProfile(cpuGeneration: 12, decoders: ["h264:h264_qsv"], encoders: ["h264:h264_qsv"], hostSystem: "generic", hwAccels: ["qsv"]),
    "macOS.Apple": HostProfile(cpuGeneration: 2, encoders: MAC_ENCODERS, hostSystem: "macOS.Apple", hwAccels: ["videotoolbox"]),
    "macOS.Apple-no-aac_at": HostProfile(encoders: ["h264:h264_videotoolbox", "aac:libfdk_aac"], hostSystem: "macOS.Apple", hwAccels: ["videotoolbox"]),
    "macOS.Apple-no-vt": HostProfile(encoders: ["aac:aac_at"], hostSystem: "macOS.Apple"),
    "macOS.Intel": HostProfile(encoders: MAC_ENCODERS, hostSystem: "macOS.Intel", hwAccels: ["videotoolbox"]),
    "raspbian": HostProfile(encoders: ["h264:h264_v4l2m2m", "aac:libfdk_aac"], gpuMem: 256, hostSystem: "raspbian"),
    "raspbian-lowmem": HostProfile(encoders: ["h264:h264_v4l2m2m", "aac:libfdk_aac"], gpuMem: 64, hostSystem: "raspbian"),
    "raspbian-no-v4l2": HostProfile(encoders: ["aac:libfdk_aac"], gpuMem: 256, hostSystem: "raspbian"),
]

private func codecMap(_ list: [String]) -> [String: Set<String>] {
    var map: [String: Set<String>] = [:]
    for entry in list {
        let parts = entry.split(separator: ":").map(String.init)
        map[parts[0], default: []].insert(parts[1])
    }
    return map
}

/// A stand-in for probed codec support with the capabilities of a host profile.
func stubCodecs(_ host: HostProfile, ffmpegVersion: String, ffmpegExec: String = "ffmpeg", log: Logger = Logger(label: "test")) -> FfmpegCodecs {
    FfmpegCodecs(
        ffmpegExec: ffmpegExec, log: log, ffmpegVersion: ffmpegVersion, hostSystem: host.hostSystem, cpuGeneration: host.cpuGeneration,
        gpuMem: host.gpuMem, decoders: codecMap(host.decoders), encoders: codecMap(host.encoders), hwAccels: Set(host.hwAccels)
    )
}

/// `FfmpegOptions` for a host profile, with the log of its construction.
func createOptions(
    _ host: HostProfile, ffmpegVersion: String, hardwareDecoding: Bool, hardwareTranscoding: Bool, crop: FfmpegOptionsConfig.Crop? = nil,
    ffmpegExec: String = "ffmpeg", debug: Bool = false, inputTimeout: Int = FFMPEG_INPUT_TIMEOUT, recordingTimeout: Int = HKSV_TIMEOUT
) -> (logs: LogRecorder, options: FfmpegOptions) {
    let logs = LogRecorder()
    var config = FfmpegOptionsConfig(
        codecSupport: stubCodecs(host, ffmpegVersion: ffmpegVersion, ffmpegExec: ffmpegExec), crop: crop, debug: debug,
        hardwareDecoding: hardwareDecoding, hardwareTranscoding: hardwareTranscoding, log: logs.logger, name: { "Test Camera" }
    )
    config.inputTimeout = inputTimeout
    config.recordingTimeout = recordingTimeout
    return (logs, FfmpegOptions(config))
}

/// Options whose "FFmpeg" is /bin/sh, for the process tests: the command lines are shell scripts.
func shellOptions(debug: Bool = false) -> (logs: LogRecorder, options: FfmpegOptions) {
    // A tenth of FFMPEG_INPUT_TIMEOUT: the inactivity stop and the SIGKILL failsafe come sooner; a fifth of HKSV_TIMEOUT.
    createOptions(
        HOSTS["generic"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: false, ffmpegExec: "/bin/sh", debug: debug,
        inputTimeout: FFMPEG_INPUT_TIMEOUT / 10, recordingTimeout: HKSV_TIMEOUT / 5)
}

/// A recording configuration as HomeKit selects one.
func recordingConfiguration(
    audio: AudioRecordingCodecType = .aacLC, samplerate: AudioRecordingSamplerate = .khz32, channels: Int = 1,
    resolution: VideoResolution = VideoResolution(1920, 1080, 24)
) -> CameraRecordingConfiguration {
    CameraRecordingConfiguration(
        prebufferLength: 4000, eventTriggerTypes: [.motion],
        mediaContainerConfiguration: MediaContainerConfiguration(fragmentLength: 4000),
        videoCodec: CameraRecordingConfiguration.VideoCodec(
            type: .h264,
            parameters: CameraRecordingConfiguration.VideoParameters(profile: .high, level: .level4_0, bitRate: 2000, iFrameInterval: 4000),
            resolution: resolution
        ),
        audioCodec: CameraRecordingConfiguration.AudioCodec(audioChannels: channels, type: audio, samplerate: samplerate, bitrateMode: .variable, bitrate: 64)
    )
}

/// An ISO BMFF box: a big-endian size, a four-character type and the payload.
func box(_ type: String, _ payload: Data) -> Data {
    var data = Data()
    let size = UInt32(8 + payload.count)
    data.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
    data.append(contentsOf: Array(type.utf8))
    data.append(payload)
    return data
}

func box(_ type: String, _ payload: [UInt8]) -> Data { box(type, Data(payload)) }

func bytes(_ count: Int, _ value: UInt8 = 0) -> Data { Data(repeating: value, count: count) }

/// Polls `condition` until it holds or `timeout` passes.
/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
@discardableResult
func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Waits for the running process of `process` to end. `action` (a stop, closing its input) runs once the wait is registered,
/// so an exit it causes at once is not missed.
func waitForExit(_ process: FfmpegProcess, timeout: Duration = .seconds(10), after action: () async -> Void = {}) async -> FfmpegExitStatus? {
    let box = NIOLockedValueBox<FfmpegExitStatus?>(nil)
    guard process.onceExit({ status in box.withLockedValue { $0 = status } }) else { return nil }
    await action()
    await eventually(timeout: timeout) { box.withLockedValue { $0 != nil } }
    return box.withLockedValue { $0 }
}

/// A UDP socket on the loopback address that records the datagrams it receives.
final class UDPReceiver: Sendable {
    let channel: any Channel
    let received: NIOLockedValueBox<[Data]>

    private final class Handler: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        let received: NIOLockedValueBox<[Data]>
        init(_ received: NIOLockedValueBox<[Data]>) { self.received = received }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data).data
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            received.withLockedValue { $0.append(Data(bytes)) }
        }
    }

    init(host: String = "127.0.0.1", port: Int = 0) async throws {
        let received = NIOLockedValueBox<[Data]>([])
        self.received = received
        channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Handler(received)) }
            }
            .bind(host: host, port: port)
            .get()
    }

    var port: Int { channel.localAddress!.port! }
    var packets: [Data] { received.withLockedValue { $0 } }

    func close() async { try? await channel.close() }
}

/// Sends one datagram to a loopback port.
func sendUDP(_ data: Data, to port: Int, host: String = "127.0.0.1") async throws {
    let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: host, port: 0).get()
    let address = try SocketAddress(ipAddress: host, port: port)
    try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: ByteBuffer(bytes: data))).get()
    try? await channel.close()
}
