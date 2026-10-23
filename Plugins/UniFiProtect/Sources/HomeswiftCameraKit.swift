import Foundation
import Homeswift
import HomeswiftFFmpeg
import Logging

// HomeswiftFFmpeg behind the FFmpeg protocols of CameraSupport.swift (`FfmpegCodecs`, `FfmpegOptions`,
// `FfmpegStreamingProcess`, `FfmpegRecordingProcess`, `FfmpegExec`, `RtpPortAllocator`, `RtpDemuxer`), and
// HomeKit Secure Video's calls in order on the plugin's actor. Nothing here decides anything.

/// HomeswiftFFmpeg as the plugin's FFmpeg kit, made with the block's `videoProcessor` (the FFmpeg to run) and
/// `verboseFfmpeg`.
final class HomeswiftFfmpegKit: ProtectFfmpegKit {
    let codecs: FfmpegCodecs
    let ports = RtpPortAllocator()

    init(videoProcessor: String?, verbose: Bool, logger: Logger) {
        codecs = FfmpegCodecs(ffmpegExec: videoProcessor, log: logger, verbose: verbose)
    }

    func probe() async -> Bool { await codecs.probe() }
    var hostSystem: String { codecs.hostSystem }
    var cpuGeneration: Int { codecs.cpuGeneration }
    var ffmpegVersion: String { codecs.ffmpegVersion }

    func makeOptions(name: @escaping @Sendable () -> String, crop: (height: Double, width: Double, x: Double, y: Double)?, debug: Bool,
                     hardwareDecoding: Bool, hardwareTranscoding: Bool, log: Logger) -> any ProtectFfmpegOptions {
        FfmpegOptions(FfmpegOptionsConfig(
            codecSupport: codecs, crop: crop.map { FfmpegOptionsConfig.Crop(height: $0.height, width: $0.width, x: $0.x, y: $0.y) }, debug: debug,
            hardwareDecoding: hardwareDecoding, hardwareTranscoding: hardwareTranscoding, log: log, name: name))
    }

    func reservePort(ipv6: Bool, count: Int) async -> Int { await ports.reserve(ipFamily: ipv6 ? .ipv6 : .ipv4, portCount: count) }
    func cancelPort(_ port: Int) { ports.cancel(port) }

    func makeRtpDemuxer(ipv6: Bool, inputPort: Int, rtcpPort: Int, rtpPort: Int, log: Logger) async -> any ProtectRtpDemuxer {
        await RtpDemuxer(ipFamily: ipv6 ? .ipv6 : .ipv4, inputPort: inputPort, rtcpPort: rtcpPort, rtpPort: rtpPort, log: log)
    }

    func startStreaming(delegate: any HomebridgeStreamingDelegate, sessionID: String, options: any ProtectFfmpegOptions, arguments: [String],
                        returnPort: FfmpegReturnPort?) -> any ProtectFfmpegStreamingProcess {
        FfmpegStreamingProcess(delegate: delegate, sessionId: sessionID, ffmpegOptions: Self.native(options), commandLineArgs: arguments,
                               returnPort: returnPort, awaitingStart: true)
    }

    func startRecording(options: any ProtectFfmpegOptions, configuration: CameraRecordingConfiguration, fMp4Options: FMp4RecordingOptions,
                        verbose: Bool) -> any ProtectFfmpegRecording {
        let process = FfmpegRecordingProcess(Self.native(options), recordingConfig: configuration, fMp4Options: fMp4Options, isVerbose: verbose)
        process.start()
        return process
    }

    func startProcess(options: any ProtectFfmpegOptions, arguments: [String]) -> any ProtectFfmpegProcess {
        let process = FfmpegProcess(Self.native(options), commandLineArgs: arguments)
        process.start()
        return process
    }

    func exec(options: any ProtectFfmpegOptions, arguments: [String], stdin: Data?, timeout: Int?, logErrors: Bool) async -> (exitCode: Int32?, stdout: Data)? {
        guard let result = await FfmpegExec(Self.native(options), commandLineArgs: arguments, logErrors: logErrors).exec(stdin, timeout: timeout) else { return nil }
        return (result.exitCode, result.stdout)
    }

    static func native(_ options: any ProtectFfmpegOptions) -> FfmpegOptions {
        // Every options object of this kit is one of ours.
        options as! FfmpegOptions
    }
}

extension FfmpegOptions: ProtectFfmpegOptions {
    func audioEncoder() -> [String] { audioEncoder(AudioEncoderOptions()) }
}

extension FfmpegProcess {
    func onExit(_ handler: @escaping @Sendable () -> Void) {
        if !onceExit({ _ in handler() }) { handler() }
    }
}

extension FfmpegProcess: ProtectFfmpegProcess {}

extension FfmpegStreamingProcess: ProtectFfmpegStreamingProcess {}

extension FfmpegRecordingProcess: ProtectFfmpegRecording {
    func segments() -> AsyncStream<Data> { segmentGenerator() }
}

extension RtpDemuxer: ProtectRtpDemuxer {
    /// The first RTP packet, or the demuxer closing (both emit `rtp`).
    func firstPacket() async {
        guard isRunning else { return }
        let events = rtpEvents
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            events.once { continuation.resume() }
        }
    }
}

/// HomeKit Secure Video's calls, in order, to the camera's recording delegate on the plugin's actor.
final class RecordingBridge: CameraRecordingDelegate {
    private let delegate: ProtectRecordingDelegate
    private let calls: AsyncStream<@ProtectActor @Sendable () async -> Void>.Continuation

    init(_ delegate: ProtectRecordingDelegate) {
        self.delegate = delegate
        let (stream, continuation) = AsyncStream.makeStream(of: (@ProtectActor @Sendable () async -> Void).self)
        calls = continuation
        Task { @ProtectActor in
            for await call in stream { await call() }
        }
    }

    deinit { calls.finish() }

    func updateRecordingActive(_ active: Bool) {
        let delegate = self.delegate
        calls.yield { await delegate.updateRecordingActive(active) }
    }

    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        let delegate = self.delegate
        calls.yield { delegate.updateRecordingConfiguration(configuration) }
    }

    /// The delegate produces straight into HomeKit's stream, in order with the stream's acknowledgement and
    /// close: a close that comes before production starts stops it.
    func handleRecordingStreamRequest(streamID: Int) -> AsyncThrowingStream<RecordingPacket, any Error> {
        let delegate = self.delegate
        let (packets, continuation) = AsyncThrowingStream.makeStream(of: RecordingPacket.self)
        calls.yield { delegate.beginRecordingStream(streamID: streamID, continuation) }
        return packets
    }

    func acknowledgeStream(streamID: Int) {
        let delegate = self.delegate
        calls.yield { delegate.acknowledgeStream(streamID: streamID) }
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        let delegate = self.delegate
        calls.yield { delegate.closeRecordingStream(streamID: streamID, reason: reason) }
    }
}
