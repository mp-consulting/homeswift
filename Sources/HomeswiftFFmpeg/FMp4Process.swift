import Foundation
import Homeswift
import NIOConcurrencyHelpers

// The FFmpeg plumbing shared by fMP4 recordings and livestreams (fmp4-process.ts): the option types and the command line skeleton,
// with FFmpeg's fMP4 output fed through a box reader. The modes are FfmpegRecordingProcess and FfmpegLivestreamProcess.

// The AAC object types of the HKSV audio codecs.
private func translateAudioRecordingCodecType(_ type: AudioRecordingCodecType) -> String {
    switch type {
    case .aacELD: "38"
    case .aacLC: "1"
    }
}

// The sample rates in kHz.
private func translateAudioSampleRate(_ samplerate: AudioRecordingSamplerate) -> String {
    switch samplerate {
    case .khz8: "8"
    case .khz16: "16"
    case .khz24: "24"
    case .khz32: "32"
    case .khz44_1: "44.1"
    case .khz48: "48"
    }
}

// HKSV errors that come from occasional inconsistencies in the input stream or FFmpeg's own quirks.
private func isKnownHKSVError(_ line: String) -> Bool {
    [
        "Cannot determine format of input stream 0:0 after EOF",
        "Could not write header (incorrect codec parameters ?): Broken pipe",
        "Could not write header for output file #0",
        "Error closing file: Broken pipe",
        "Error splitting the input into NAL units.",
        "Invalid data found when processing input",
        "moov atom not found",
    ].contains { line.contains($0) }
}

/// The options shared by fMP4 recordings and livestreams. Every field is optional: nil takes the default.
///
/// - `audioFilters`: audio filters (default none). Filters force audio transcoding.
/// - `audioStream`: the audio stream of the input (default 0).
/// - `codec`: the input video codec, `av1`, `h264` (default) or `hevc`.
/// - `enableAudio`: default true.
/// - `hardwareDecoding`: default the options' setting with FFmpeg 8, off before.
/// - `hardwareTranscoding`: default the options' setting.
/// - `transcodeAudio`: transcode audio to AAC (default true); false copies audio that is already AAC.
/// - `videoFilters`: video filters (default none).
/// - `videoStream`: the video stream of the input (default 0).
public struct FMp4BaseOptions: Sendable {
    public var audioFilters: [String]?
    public var audioStream: Int?
    public var codec: String?
    public var enableAudio: Bool?
    public var hardwareDecoding: Bool?
    public var hardwareTranscoding: Bool?
    public var transcodeAudio: Bool?
    public var videoFilters: [String]?
    public var videoStream: Int?

    public init(
        audioFilters: [String]? = nil, audioStream: Int? = nil, codec: String? = nil, enableAudio: Bool? = nil, hardwareDecoding: Bool? = nil,
        hardwareTranscoding: Bool? = nil, transcodeAudio: Bool? = nil, videoFilters: [String]? = nil, videoStream: Int? = nil
    ) {
        self.audioFilters = audioFilters
        self.audioStream = audioStream
        self.codec = codec
        self.enableAudio = enableAudio
        self.hardwareDecoding = hardwareDecoding
        self.hardwareTranscoding = hardwareTranscoding
        self.transcodeAudio = transcodeAudio
        self.videoFilters = videoFilters
        self.videoStream = videoStream
    }
}

/// A separate audio source for a livestream, when video and audio come from different endpoints (DoorBird's audio.cgi). Raw
/// streams need `format` (`alaw`, `mulaw` or `s16le`), `sampleRate` (Hz, default 8000) and `channels` (default 1); self-describing
/// sources (RTSP, containers) need only the URL.
public struct FMp4AudioInputConfig: Sendable {
    public enum Format: String, Sendable {
        case alaw
        case mulaw
        case s16le
    }

    public var channels: Int?
    public var format: Format?
    public var sampleRate: Int?
    public var url: String

    /// A URL alone: the TypeScript string shorthand.
    public init(url: String, format: Format? = nil, sampleRate: Int? = nil, channels: Int? = nil) {
        self.url = url
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// An HKSV recording: the base options plus the input frame rate (default 30), the probe size in bytes (default 5000000) and the
/// timeshift into the input in milliseconds (default 0).
public struct FMp4RecordingOptions: Sendable {
    public var audioFilters: [String]?
    public var audioStream: Int?
    public var codec: String?
    public var enableAudio: Bool?
    public var hardwareDecoding: Bool?
    public var hardwareTranscoding: Bool?
    public var transcodeAudio: Bool?
    public var videoFilters: [String]?
    public var videoStream: Int?
    public var fps: Int?
    public var probesize: Int?
    public var timeshift: Int?

    public init(
        audioFilters: [String]? = nil, audioStream: Int? = nil, codec: String? = nil, enableAudio: Bool? = nil, fps: Int? = nil,
        hardwareDecoding: Bool? = nil, hardwareTranscoding: Bool? = nil, probesize: Int? = nil, timeshift: Int? = nil,
        transcodeAudio: Bool? = nil, videoFilters: [String]? = nil, videoStream: Int? = nil
    ) {
        self.audioFilters = audioFilters
        self.audioStream = audioStream
        self.codec = codec
        self.enableAudio = enableAudio
        self.fps = fps
        self.hardwareDecoding = hardwareDecoding
        self.hardwareTranscoding = hardwareTranscoding
        self.probesize = probesize
        self.timeshift = timeshift
        self.transcodeAudio = transcodeAudio
        self.videoFilters = videoFilters
        self.videoStream = videoStream
    }

    var base: FMp4BaseOptions {
        FMp4BaseOptions(
            audioFilters: audioFilters, audioStream: audioStream, codec: codec, enableAudio: enableAudio, hardwareDecoding: hardwareDecoding,
            hardwareTranscoding: hardwareTranscoding, transcodeAudio: transcodeAudio, videoFilters: videoFilters, videoStream: videoStream
        )
    }
}

/// A livestream: the base options, the source URL (RTSP) remuxed to fMP4, and an optional separate audio source.
public struct FMp4LivestreamOptions: Sendable {
    public var audioFilters: [String]?
    public var audioStream: Int?
    public var codec: String?
    public var enableAudio: Bool?
    public var hardwareDecoding: Bool?
    public var hardwareTranscoding: Bool?
    public var transcodeAudio: Bool?
    public var videoFilters: [String]?
    public var videoStream: Int?
    public var audioInput: FMp4AudioInputConfig?
    public var url: String

    public init(
        url: String, audioFilters: [String]? = nil, audioInput: FMp4AudioInputConfig? = nil, audioStream: Int? = nil, codec: String? = nil,
        enableAudio: Bool? = nil, hardwareDecoding: Bool? = nil, hardwareTranscoding: Bool? = nil, transcodeAudio: Bool? = nil,
        videoFilters: [String]? = nil, videoStream: Int? = nil
    ) {
        self.url = url
        self.audioFilters = audioFilters
        self.audioInput = audioInput
        self.audioStream = audioStream
        self.codec = codec
        self.enableAudio = enableAudio
        self.hardwareDecoding = hardwareDecoding
        self.hardwareTranscoding = hardwareTranscoding
        self.transcodeAudio = transcodeAudio
        self.videoFilters = videoFilters
        self.videoStream = videoStream
    }

    var base: FMp4BaseOptions {
        FMp4BaseOptions(
            audioFilters: audioFilters, audioStream: audioStream, codec: codec, enableAudio: enableAudio, hardwareDecoding: hardwareDecoding,
            hardwareTranscoding: hardwareTranscoding, transcodeAudio: transcodeAudio, videoFilters: videoFilters, videoStream: videoStream
        )
    }
}

/// The base options with their defaults applied.
struct ResolvedFMp4Options: Sendable {
    var audioFilters: [String]
    var audioStream: Int
    var codec: String
    var enableAudio: Bool
    var hardwareDecoding: Bool
    var hardwareTranscoding: Bool
    var transcodeAudio: Bool
    var videoFilters: [String]
    var videoStream: Int
}

/// The base of fMP4 FFmpeg processes: the shared command line (preamble, video mapping, movflags, audio encoding, output) and the
/// box parsing loop. Subclasses provide the mode-specific pieces through the hook methods and call `buildCommandLine()` at the end
/// of their initializer. `closeEvents` fires once per process lifecycle when the process is stopped.
public class FfmpegFMp4Process: FfmpegProcess, @unchecked Sendable {
    /// Fires once per process lifecycle when the process is stopped (the TypeScript `close` event).
    public let closeEvents = FfmpegEvent<Void>()

    let fMp4Options: ResolvedFMp4Options
    let recordingConfig: CameraRecordingConfiguration
    // Per-session verbose logging, on top of the codec support's.
    private let isVerboseSession: Bool

    private struct FMp4State {
        var hasEmittedClose = false
        var isLoggingErrors = true
    }

    private let fmp4State = NIOLockedValueBox(FMp4State())

    init(_ ffmpegOptions: FfmpegOptions, recordingConfig: CameraRecordingConfiguration, fMp4Options: FMp4BaseOptions, isVerbose: Bool) {
        self.recordingConfig = recordingConfig
        self.fMp4Options = ResolvedFMp4Options(
            audioFilters: fMp4Options.audioFilters ?? [],
            audioStream: fMp4Options.audioStream ?? 0,
            codec: fMp4Options.codec ?? "h264",
            enableAudio: fMp4Options.enableAudio ?? true,
            hardwareDecoding: fMp4Options.hardwareDecoding
                ?? (ffmpegOptions.codecSupport.ffmpegVersion.hasPrefix("8.") ? ffmpegOptions.config.hardwareDecoding : false),
            hardwareTranscoding: fMp4Options.hardwareTranscoding ?? ffmpegOptions.config.hardwareTranscoding,
            transcodeAudio: fMp4Options.transcodeAudio ?? true,
            videoFilters: fMp4Options.videoFilters ?? [],
            videoStream: fMp4Options.videoStream ?? 0
        )
        self.isVerboseSession = isVerbose
        super.init(ffmpegOptions)
    }

    // Assembles the command line from the hooks, in the standard order.
    func buildCommandLine() {
        // -hide_banner                  No startup banner.
        // -nostats                      No progress reports.
        // -fflags +discardcorrupt       Discard corrupt packets rather than exit.
        // -err_detect ignore_err        Ignore decoding errors.
        // -max_delay 500000             At most half a second demuxing packets.
        var arguments = [
            "-hide_banner",
            "-nostats",
            "-fflags", "+discardcorrupt",
            "-err_detect", "ignore_err",
        ]
        arguments += options.videoDecoder(fMp4Options.codec)
        arguments += ["-max_delay", "500000"]
        // The mode's input (RTSP for a livestream, standard input for a recording), and its separate audio input, if any.
        arguments += inputArgs()
        arguments += separateAudioInputArgs()

        // -map 0:v:X                    The video track.
        arguments += ["-map", "0:v:" + String(fMp4Options.videoStream)]
        arguments += videoEncoderArgs()
        if !fMp4Options.videoFilters.isEmpty {
            arguments += ["-filter:v", fMp4Options.videoFilters.joined(separator: ", ")]
        }
        arguments += postFilterArgs()

        // -movflags                     default-base-is-moof, an initial empty moov, a fragment per keyframe, no sidx, no trailing moov.
        // -flush_packets 1              Flush after each packet.
        // -reset_timestamps             Timestamps start over with each segment.
        // -metadata                     The camera's name, to tell sessions apart.
        arguments += [
            "-movflags", "default_base_moof+empty_moov+frag_keyframe+skip_sidx+skip_trailer",
            "-flush_packets", "1",
            "-reset_timestamps", "1",
            "-metadata", "comment=" + options.name() + " " + metadataLabel(),
        ]

        var transcodeAudio = fMp4Options.transcodeAudio
        if fMp4Options.enableAudio {
            // -map N:a:X?                 The audio stream of input N, if there is one: 0, or 1 with a separate audio input.
            arguments += ["-map", String(audioInputIndex()) + ":a:" + String(fMp4Options.audioStream) + "?"]
            if !fMp4Options.audioFilters.isEmpty {
                arguments += ["-filter:a", fMp4Options.audioFilters.joined(separator: ", ")]
                // Filtering requires transcoding.
                transcodeAudio = true
            }
            if transcodeAudio {
                // -codec:a                  The host's AAC encoder.
                // -profile:a                AAC-LC or AAC-ELD, as HKSV asks.
                // -ar                       The sample rate HKSV asks for.
                // -ac                       The number of channels.
                arguments += options.audioEncoder(AudioEncoderOptions(codec: recordingConfig.audioCodec.type))
                arguments += [
                    "-profile:a", translateAudioRecordingCodecType(recordingConfig.audioCodec.type),
                    "-ar", translateAudioSampleRate(recordingConfig.audioCodec.samplerate) + "k",
                    "-ac", String(recordingConfig.audioCodec.audioChannels),
                ]
            } else {
                // -codec:a copy             The audio is already AAC.
                arguments += ["-codec:a", "copy"]
            }
        }

        // -f mp4 pipe:1                 MP4 to standard output.
        arguments += ["-f", "mp4", "pipe:1"]
        if isVerboseSession || isVerbose {
            arguments.insert(contentsOf: ["-loglevel", "level+verbose"], at: 0)
        }
        commandLineArgs = arguments
    }

    // MARK: Hooks

    func inputArgs() -> [String] { fatalError("Subclasses provide the input") }
    func separateAudioInputArgs() -> [String] { [] }
    func audioInputIndex() -> Int { 0 }
    func videoEncoderArgs() -> [String] { fatalError("Subclasses provide the video encoder") }
    func postFilterArgs() -> [String] { [] }
    func metadataLabel() -> String { "" }
    func handleParsedBox(header: Data, data: Data, dataLength: Int, type: UInt32) {}
    func willStart() {}

    // Feeds FFmpeg's output through a box reader of its own for each process, handing every complete box to handleParsedBox.
    override func configureProcess(_ child: Subprocess, errorHandler: (@Sendable (String) -> Void)?) {
        super.configureProcess(child, errorHandler: errorHandler)
        let reader = NIOLockedValueBox(FMp4BoxReader())
        let listener = NIOLockedValueBox<Int?>(nil)
        let id = child.addStdoutHandler { [weak self] chunk in
            guard let self else { return }
            let (boxes, ok, invalidSize) = reader.withLockedValue { reader -> ([FMp4ParsedBox], Bool, Int?) in
                var boxes: [FMp4ParsedBox] = []
                let ok = reader.push(chunk) { boxes.append($0) }
                return (boxes, ok, reader.invalidBoxSize)
            }
            for box in boxes {
                self.handleParsedBox(header: box.header, data: box.data, dataLength: box.length, type: box.type)
            }
            guard !ok else { return }
            // A size below the header size leaves the stream unparseable: end the session.
            self.log.error("Invalid fMP4 box size (\(invalidSize.map(String.init) ?? "null")) detected in the FFmpeg output stream. Ending this session.")
            if let id = listener.withLockedValue({ $0 }) { child.removeStdoutHandler(id) }
            self.stop()
        }
        listener.withLockedValue { $0 = id }
    }

    /// Starts FFmpeg; a restarted instance can emit `close` again.
    override public func start(_ commandLineArgs: [String]? = nil, errorHandler: (@Sendable (String) -> Void)? = nil) {
        willStart()
        fmp4State.withLockedValue { $0 = FMp4State() }
        super.start(commandLineArgs, errorHandler: errorHandler)
    }

    override func stopProcess() {
        super.stopProcess()
        // The process has ended for us; `close` fires at most once per process lifecycle.
        setEnded()
        let emit = fmp4State.withLockedValue { state -> Bool in
            defer { state.hasEmittedClose = true }
            return !state.hasEmittedClose
        }
        if emit { closeEvents.emit() }
    }

    /// Stops FFmpeg; `logErrors` says whether an abnormal exit is logged. It holds until the next `start()`: the exit comes
    /// after this returns, so a setting restored here would log it anyway.
    public func stop(logErrors: Bool) {
        fmp4State.withLockedValue { $0.isLoggingErrors = logErrors }
        super.stop()
    }

    override func logFfmpegError(_ status: FfmpegExitStatus) {
        guard fmp4State.withLockedValue({ $0.isLoggingErrors }) else { return }
        if stderrLog.contains(where: isKnownHKSVError) {
            log.error("FFmpeg ended unexpectedly due to issues processing the media stream. This error can be safely ignored - it will occur occasionally.")
            return
        }
        super.logFfmpegError(status)
    }
}

/// An HKSV event recording (recording-process.ts): fMP4 on standard input (the timeshift buffer) transcoded to what HomeKit asked
/// for, read back as segments: the initialization segment (ftyp and moov) first, then moof and mdat pairs.
///
/// ```swift
/// let recording = FfmpegRecordingProcess(options, recordingConfig: configuration, fMp4Options: FMp4RecordingOptions(fps: 30))
/// recording.start()
/// // feed the buffer with recording.writeStdin(...)
/// for await segment in recording.segmentGenerator() { ... }
/// ```
public final class FfmpegRecordingProcess: FfmpegFMp4Process, @unchecked Sendable {
    private let fps: Int
    private let probesize: Int
    private let timeshift: Int

    private struct RecordingState {
        var recordingBuffer: [FMp4ParsedBox] = []
        var isTimedOut = false
        var isStopped = false
    }

    private let recordingState = NIOLockedValueBox(RecordingState())
    private let mp4box = AsyncSignal()
    /// Called by the segment generator after its end check, right before it waits for a box: lets tests stop the process there.
    let beforeBoxWait = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)

    public init(
        _ options: FfmpegOptions, recordingConfig: CameraRecordingConfiguration, fMp4Options: FMp4RecordingOptions = FMp4RecordingOptions(),
        isVerbose: Bool = false
    ) {
        fps = fMp4Options.fps ?? 30
        probesize = fMp4Options.probesize ?? 5_000_000
        timeshift = fMp4Options.timeshift ?? 0
        super.init(options, recordingConfig: recordingConfig, fMp4Options: fMp4Options.base, isVerbose: isVerbose)
        buildCommandLine()
    }

    /// Whether the recording ended because FFmpeg produced nothing within `HKSV_TIMEOUT`.
    public var isTimedOut: Bool { recordingState.withLockedValue { $0.isTimedOut } }

    // -flags low_delay              Optimize for low delay.
    // -probesize                    How many bytes to analyze for stream information.
    // -f mp4 -i pipe:0              MP4 on standard input.
    // -ss                           Skip to where HKSV expects the event to start.
    override func inputArgs() -> [String] {
        ["-flags", "low_delay", "-probesize", String(probesize), "-f", "mp4", "-i", "pipe:0", "-ss", String(timeshift) + "ms"]
    }

    // Transcode for HKSV with the host's encoder.
    override func videoEncoderArgs() -> [String] {
        let video = recordingConfig.videoCodec
        return options.recordEncoder(VideoEncoderOptions(
            bitrate: video.parameters.bitRate, fps: video.resolution.fps, hardwareDecoding: fMp4Options.hardwareDecoding,
            hardwareTranscoding: fMp4Options.hardwareTranscoding, height: video.resolution.height, idrInterval: HKSV_IDR_INTERVAL, inputFps: fps,
            level: video.parameters.level, profile: video.parameters.profile, width: video.resolution.width
        ))
    }

    override func metadataLabel() -> String { "HKSV Event" }

    override func willStart() {
        recordingState.withLockedValue { $0 = RecordingState() }
    }

    override func handleParsedBox(header: Data, data: Data, dataLength: Int, type: UInt32) {
        recordingState.withLockedValue { $0.recordingBuffer.append(FMp4ParsedBox(data: data, header: header, length: dataLength, type: type)) }
        mp4box.signal()
    }

    override func stopProcess() {
        // Release a waiting segment generator.
        setEnded()
        recordingState.withLockedValue { $0.isStopped = true }
        mp4box.signal()
        super.stopProcess()
    }

    /// The segments for HomeKit as FFmpeg produces them: the ftyp and moov boxes, then each moof and mdat pair. Ends when FFmpeg
    /// ends, or when nothing arrives within `HKSV_TIMEOUT` (`isTimedOut` is then set).
    public func segmentGenerator() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                var segment = Data()
                while let self, !Task.isCancelled {
                    // Stopped, or FFmpeg has finished its output and every box of it was handed over (its exit comes after the
                    // last of its output, which may still wait here).
                    let (isStopped, isDrained) = self.recordingState.withLockedValue { ($0.isStopped, $0.recordingBuffer.isEmpty) }
                    if isStopped || (self.isEnded && isDrained) { break }
                    self.beforeBoxWait.withLockedValue { $0 }?()
                    // Wait for FFmpeg to produce more boxes, within HKSV's timing. A stop since the check above is seen here too: it
                    // is flagged before its signal, and the flag is read under the signal's lock.
                    let recordingState = self.recordingState
                    _ = await self.mp4box.wait(timeout: .milliseconds(HKSV_TIMEOUT)) {
                        recordingState.withLockedValue { !$0.recordingBuffer.isEmpty || $0.isStopped }
                    }
                    // The consumer went away: that is neither a timeout nor more output to hand over.
                    if Task.isCancelled { break }
                    let box = recordingState.withLockedValue { state -> FMp4ParsedBox? in
                        state.recordingBuffer.isEmpty ? nil : state.recordingBuffer.removeFirst()
                    }
                    // Nothing within HKSV's 5 seconds: we're done. (The TypeScript generator also flags a stop during the wait as a
                    // timeout; a stop is not one.)
                    guard let box else {
                        recordingState.withLockedValue { if !$0.isStopped { $0.isTimedOut = true } }
                        break
                    }
                    segment.append(box.header)
                    segment.append(box.data)
                    // A complete moov (with its ftyp) or a complete moof and mdat pair goes to HomeKit.
                    if box.type == BOX_TYPE_MOOV || box.type == BOX_TYPE_MDAT {
                        continuation.yield(segment)
                        segment = Data()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The segments as HKSV recording packets: `segmentGenerator()` with `isLast` false, and, when FFmpeg timed out, a final
    /// one-byte packet marked last so HomeKit closes the recording cleanly (what the UniFi Protect plugin sends). The stream ends
    /// without a last packet when FFmpeg simply ended.
    public func recordingPackets() -> AsyncThrowingStream<RecordingPacket, any Error> {
        let segments = segmentGenerator()
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                for await segment in segments {
                    continuation.yield(RecordingPacket(data: segment, isLast: false))
                }
                if self?.isTimedOut == true {
                    continuation.yield(RecordingPacket(data: Data([0]), isLast: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Why `FfmpegLivestreamProcess.getInitSegment()` failed.
public enum FfmpegLivestreamError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No FFmpeg process is running.
    case noActiveProcess
    /// The process stopped or exited before the initialization segment arrived.
    case aborted

    public var description: String {
        switch self {
        case .noActiveProcess: "No active FFmpeg livestream process."
        case .aborted: "The FFmpeg livestream process ended before the initialization segment arrived."
        }
    }
}

/// An fMP4 livestream (livestream-process.ts): an RTSP source remuxed to fMP4 without transcoding, with the initialization segment
/// captured and each later box emitted as a segment.
///
/// ```swift
/// let livestream = FfmpegLivestreamProcess(options, recordingConfig: configuration, livestreamOptions: FMp4LivestreamOptions(url: rtsp))
/// livestream.segmentEvents.on { segment in ... }
/// livestream.start()
/// let initSegment = try await livestream.getInitSegment()
/// ```
public final class FfmpegLivestreamProcess: FfmpegFMp4Process, @unchecked Sendable {
    /// Fires with each box after the initialization segment (the TypeScript `segment` event).
    public let segmentEvents = FfmpegEvent<Data>()

    private struct LivestreamState {
        var segmentLength: Int?
        var hasAudioInput = false
        var initSegment = Data()
        var initSegmentParts: [Data] = []
        var hasInitSegment = false
        var initWaiters: [Int: CheckedContinuation<Data, any Error>] = [:]
        var nextWaiter = 0
    }

    private let livestreamState = NIOLockedValueBox(LivestreamState())
    private let livestreamOptions: FMp4LivestreamOptions

    public init(_ options: FfmpegOptions, recordingConfig: CameraRecordingConfiguration, livestreamOptions: FMp4LivestreamOptions, isVerbose: Bool = false) {
        self.livestreamOptions = livestreamOptions
        super.init(options, recordingConfig: recordingConfig, fMp4Options: livestreamOptions.base, isVerbose: isVerbose)
        buildCommandLine()
    }

    /// The fMP4 fragment duration in milliseconds, applied to `-frag_duration` when the process starts (one second otherwise).
    public var segmentLength: Int? {
        get { livestreamState.withLockedValue { $0.segmentLength } }
        set { livestreamState.withLockedValue { $0.segmentLength = newValue } }
    }

    // -avioflags direct             Minimal buffering.
    // -rtsp_transport tcp           RTSP over TCP.
    // -i url                        The source.
    override func inputArgs() -> [String] {
        ["-avioflags", "direct", "-rtsp_transport", "tcp", "-i", livestreamOptions.url]
    }

    // A separate audio input (DoorBird and others serve audio from another endpoint).
    override func separateAudioInputArgs() -> [String] {
        guard fMp4Options.enableAudio, let audioInput = livestreamOptions.audioInput else { return [] }
        var arguments: [String] = []
        // Raw audio cannot be probed: -f format -ar sampleRate -ac channels.
        if let format = audioInput.format {
            arguments += ["-f", format.rawValue, "-ar", String(audioInput.sampleRate ?? 8000), "-ac", String(audioInput.channels ?? 1)]
        }
        // RTSP audio over TCP, like the video.
        let url = audioInput.url.lowercased()
        if url.hasPrefix("rtsp://") || url.hasPrefix("rtsps://") {
            arguments += ["-rtsp_transport", "tcp"]
        }
        arguments += ["-i", audioInput.url]
        livestreamState.withLockedValue { $0.hasAudioInput = true }
        return arguments
    }

    // Audio is on the second input when it has its own.
    override func audioInputIndex() -> Int {
        livestreamState.withLockedValue { $0.hasAudioInput } ? 1 : 0
    }

    // Remux the video as is.
    override func videoEncoderArgs() -> [String] { ["-codec:v", "copy"] }

    // -frag_duration                One-second fragments, in microseconds.
    override func postFilterArgs() -> [String] { ["-frag_duration", "1000000"] }

    override func metadataLabel() -> String { "Livestream Buffer" }

    // Everything before the first moof is the initialization segment; from the moof on, every box is a segment.
    override func handleParsedBox(header: Data, data: Data, dataLength: Int, type: UInt32) {
        let (initWaiters, initSegment, emit) = livestreamState.withLockedValue { state -> ([CheckedContinuation<Data, any Error>], Data, Bool) in
            var waiters: [CheckedContinuation<Data, any Error>] = []
            if !state.hasInitSegment {
                if type == BOX_TYPE_MOOF {
                    var initSegment = Data()
                    for part in state.initSegmentParts { initSegment.append(part) }
                    state.initSegment = initSegment
                    state.initSegmentParts = []
                    state.hasInitSegment = true
                    waiters = Array(state.initWaiters.values)
                    state.initWaiters = [:]
                } else {
                    state.initSegmentParts.append(header)
                    state.initSegmentParts.append(data)
                }
            }
            return (waiters, state.initSegment, state.hasInitSegment)
        }
        for waiter in initWaiters { waiter.resume(returning: initSegment) }
        if emit {
            var segment = header
            segment.append(data)
            segmentEvents.emit(segment)
        }
    }

    // A pending initialization segment wait is released when the process exits on its own.
    override func configureProcess(_ child: Subprocess, errorHandler: (@Sendable (String) -> Void)?) {
        super.configureProcess(child, errorHandler: errorHandler)
        // The base handler runs first and clears the current process when this one exits; if another is current, it superseded this one.
        child.addExitHandler { [weak self] _ in
            guard let self, !self.isRunning else { return }
            self.abortInitSegmentWait()
        }
    }

    override func stopProcess() {
        abortInitSegmentWait()
        super.stopProcess()
    }

    /// Starts FFmpeg with a fresh initialization segment, applying `segmentLength`.
    override public func start(_ commandLineArgs: [String]? = nil, errorHandler: (@Sendable (String) -> Void)? = nil) {
        let segmentLength = livestreamState.withLockedValue { state -> Int? in
            state.hasInitSegment = false
            state.initSegment = Data()
            state.initSegmentParts = []
            return state.segmentLength
        }
        var arguments = commandLineArgs ?? self.commandLineArgs
        if let segmentLength, let index = arguments.firstIndex(of: "-frag_duration"), index + 1 < arguments.count {
            // Microseconds; a length too large to multiply is clamped rather than trapping.
            let (microseconds, overflow) = segmentLength.multipliedReportingOverflow(by: 1000)
            arguments[index + 1] = String(overflow ? (segmentLength < 0 ? Int.min : Int.max) : microseconds)
        }
        super.start(arguments, errorHandler: errorHandler)
    }

    /// The initialization segment, waiting for it if needed. Concurrent callers share the wait; throws when no process runs, or when
    /// it stops or exits first.
    public func getInitSegment() async throws -> Data {
        let id = livestreamState.withLockedValue { state -> Int in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let running = isRunning
                let result = livestreamState.withLockedValue { state -> Result<Data, any Error>? in
                    if state.hasInitSegment { return .success(state.initSegment) }
                    if !running { return .failure(FfmpegLivestreamError.noActiveProcess) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.initWaiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            livestreamState.withLockedValue { $0.initWaiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    private func abortInitSegmentWait() {
        let waiters = livestreamState.withLockedValue { state in
            defer { state.initWaiters = [:] }
            return Array(state.initWaiters.values)
        }
        for waiter in waiters { waiter.resume(throwing: FfmpegLivestreamError.aborted) }
    }

    /// The initialization segment, nil until it has arrived.
    public var initSegment: Data? {
        livestreamState.withLockedValue { $0.hasInitSegment ? $0.initSegment : nil }
    }

    var pendingInitSegmentWaits: Int { livestreamState.withLockedValue { $0.initWaiters.count } }
}
