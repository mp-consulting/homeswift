import Foundation
import Homeswift
import HomeswiftFFmpeg
import Logging

// The plugin's camera code talks to HomeKit through Homeswift's `CameraController` and its delegates
// directly. FFmpeg goes through the protocols below, shaped member for member like the HomeswiftFFmpeg
// types they stand for, so tests run the streaming, snapshot and HKSV code without spawning FFmpeg;
// HomeswiftCameraKit.swift plugs in the real ones.

extension VideoResolution {
    /// `1920x1080@30fps`.
    var formatted: String { "\(width)x\(height)@\(fps)fps" }
}

/// `FfmpegOptions`: the encoders and decoders this host has, with hardware acceleration.
protocol ProtectFfmpegOptions: AnyObject, Sendable {
    /// `-codec:a …` for AAC (`libfdk_aac` or `aac_at`).
    func audioEncoder() -> [String]
    var audioDecoder: String { get }
    func videoDecoder(_ codec: String) -> [String]
    var cropFilter: String { get }
    /// The largest transcode the host manages, in pixels.
    var hostSystemMaxPixels: Int { get }
    func streamEncoder(_ options: VideoEncoderOptions) -> [String]
}

/// An FFmpeg process (`FfmpegProcess`): stdin, stdout and its exit.
protocol ProtectFfmpegProcess: AnyObject, Sendable {
    func stop()
    func writeStdin(_ data: Data) async throws
    func endStdin(_ data: Data?)
    var isStdinWritable: Bool { get }
    @discardableResult
    func onStdout(_ handler: @escaping @Sendable (Data) -> Void) -> FfmpegProcess.StdoutListener?
    /// Runs once when the process exits; at once when it already has.
    func onExit(_ handler: @escaping @Sendable () -> Void)
}

/// `FfmpegStreamingProcess`: FFmpeg for a live stream, started; `waitForStart()` is the TypeScript
/// `StreamRequestCallback` (FFmpeg wrote to standard error, or failed before).
protocol ProtectFfmpegStreamingProcess: ProtectFfmpegProcess {
    func waitForStart() async throws
}

/// `FfmpegRecordingProcess`: the HKSV fragments FFmpeg produces from what goes into stdin.
protocol ProtectFfmpegRecording: ProtectFfmpegProcess {
    func segments() -> AsyncStream<Data>
    var isTimedOut: Bool { get }
    /// Stops, logging errors or not (`stop(false)` after a cancelled event).
    func stop(logErrors: Bool)
}

/// `RtpDemuxer`: splits return audio from RTCP for two-way audio.
protocol ProtectRtpDemuxer: AnyObject, Sendable {
    /// Waits for the first RTP packet, or the demuxer closing.
    func firstPacket() async
    var isRunning: Bool { get }
    func close()
}

/// The FFmpeg helper (`codecSupport` and `rtpPorts` of the Homebridge plugin's platform). nil in a build
/// without it, and then cameras are still added, with their sensors and switches, but no video.
protocol ProtectFfmpegKit: Sendable {
    /// `FfmpegCodecs`: probes FFmpeg once; false when it does not run.
    func probe() async -> Bool
    var hostSystem: String { get }
    var cpuGeneration: Int { get }
    var ffmpegVersion: String { get }
    func makeOptions(name: @escaping @Sendable () -> String, crop: (height: Double, width: Double, x: Double, y: Double)?, debug: Bool,
                     hardwareDecoding: Bool, hardwareTranscoding: Bool, log: Logger) -> any ProtectFfmpegOptions
    /// `RtpPortAllocator`: -1 when no port is free.
    func reservePort(ipv6: Bool, count: Int) async -> Int
    func cancelPort(_ port: Int)
    func makeRtpDemuxer(ipv6: Bool, inputPort: Int, rtcpPort: Int, rtpPort: Int, log: Logger) async -> any ProtectRtpDemuxer
    /// `FfmpegStreamingProcess` (with `awaitingStart`): starts FFmpeg for a live stream; `delegate` hears of its
    /// probe size troubles and its end. With a return port, a stream that sends nothing for five seconds is stopped.
    func startStreaming(delegate: any HomebridgeStreamingDelegate, sessionID: String, options: any ProtectFfmpegOptions, arguments: [String],
                        returnPort: FfmpegReturnPort?) -> any ProtectFfmpegStreamingProcess
    /// `FfmpegRecordingProcess`, started.
    func startRecording(options: any ProtectFfmpegOptions, configuration: CameraRecordingConfiguration, fMp4Options: FMp4RecordingOptions,
                        verbose: Bool) -> any ProtectFfmpegRecording
    /// `FfmpegExec`: runs FFmpeg to the end with `stdin`, killed after `timeout` milliseconds. nil when it did not run.
    func exec(options: any ProtectFfmpegOptions, arguments: [String], stdin: Data?, timeout: Int?, logErrors: Bool) async -> (exitCode: Int32?, stdout: Data)?
}
