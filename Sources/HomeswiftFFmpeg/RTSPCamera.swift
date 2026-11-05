import Foundation
import Homeswift
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

// A camera whose video is an RTSP URL, in HomeKit: live streams (FFmpeg reads the URL and sends SRTP to the controller) and
// HomeKit Secure Video (FFmpeg writes fragmented MP4 of it). Where the URL comes from is the plugin's: a URL a cloud makes
// for each session, or the camera's own on the LAN. The Nest plugin's streamer and recorder, made general, for camera
// plugins that have an RTSP URL and nothing more to do with FFmpeg.

/// Where a stream's video comes from: an RTSP URL, and what to do once the stream is done with it.
public struct RTSPSource: Sendable {
    public var url: String
    /// Called once when the stream or recording ends: a cloud's stream to stop.
    public var release: @Sendable () async -> Void
    /// Called when FFmpeg could not start on the URL or ended in an error: the plugin may try another source next time.
    public var failed: @Sendable () async -> Void
    /// Called when a live stream started on the URL: the source works.
    public var started: @Sendable () async -> Void

    public init(url: String, release: @escaping @Sendable () async -> Void = {}, failed: @escaping @Sendable () async -> Void = {},
                started: @escaping @Sendable () async -> Void = {}) {
        self.url = url
        self.release = release
        self.failed = failed
        self.started = started
    }
}

/// What a source is for.
public enum RTSPSourcePurpose: Sendable, Equatable {
    case live
    case recording
}

/// Opens a source for a stream or a recording; throws when there is none now (the camera is closed or offline).
public typealias RTSPSourceOpener = @Sendable (RTSPSourcePurpose) async throws -> RTSPSource

/// How FFmpeg reads and encodes an RTSP camera.
public struct RTSPCameraOptions: Sendable, Equatable {
    public static let defaultEncoder = ["libx264", "-preset", "ultrafast", "-tune", "zerolatency"]

    /// The video encoder and its options (`-codec:v` follows with them); `["copy"]` sends the camera's own H.264.
    public var encoder: [String]
    public var analyzeDuration: Int
    public var probeSize: Int
    /// `-rtsp_transport tcp` before the input, for an `rtsp://` URL.
    public var rtspOverTCP: Bool
    /// FFmpeg's verbose log.
    public var debug: Bool
    /// How long an RTSP input may stay silent before FFmpeg gives up, in microseconds; nil waits for ever. A cloud's URL that
    /// stops answering would otherwise hold FFmpeg (and the session) open.
    public var socketTimeout: Int?

    public init(encoder: [String] = defaultEncoder, analyzeDuration: Int = 15_000_000, probeSize: Int = 100_000_000, rtspOverTCP: Bool = false,
                debug: Bool = false, socketTimeout: Int? = nil) {
        self.encoder = encoder.isEmpty ? Self.defaultEncoder : encoder
        self.analyzeDuration = analyzeDuration
        self.probeSize = probeSize
        self.rtspOverTCP = rtspOverTCP
        self.debug = debug
        self.socketTimeout = socketTimeout
    }

    /// `encoder` is exactly `copy`: no transcoding.
    public var copiesVideo: Bool { encoder == ["copy"] }
}

/// The FFmpeg a plugin's cameras run, and the audio encoders it has, asked once in the background.
public final class RTSPCameraFFmpeg: Sendable {
    public let options: FfmpegOptions
    private let probe: Task<FfmpegCodecs?, Never>

    public init(executable: String = "ffmpeg", name: String, logger: Logger, debug: Bool) {
        let codecs = FfmpegCodecs(ffmpegExec: executable, log: logger, ffmpegVersion: "")
        var config = FfmpegOptionsConfig(codecSupport: codecs, debug: debug, hardwareDecoding: false, hardwareTranscoding: false, log: logger, name: { name })
        // Stopping writes `q`, then kills FFmpeg if it still runs two seconds later.
        config.inputTimeout = 2000
        options = FfmpegOptions(config)
        probe = Task {
            let probed = FfmpegCodecs(ffmpegExec: executable, log: logger)
            return await probed.probe() ? probed : nil
        }
    }

    /// Codecs known in advance (tests).
    public init(options: FfmpegOptions, codecs: FfmpegCodecs?) {
        self.options = options
        probe = Task { codecs }
    }

    /// HomeKit's AAC-ELD for live streams: libfdk_aac, else AudioToolbox's on macOS; nil when FFmpeg has neither, and the
    /// stream goes without audio.
    public func liveAudioEncoder() async -> [String]? {
        guard let codecs = await probe.value, !codecs.hasEncoder("aac", "libfdk_aac") else { return ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"] }
        return codecs.hasEncoder("aac", "aac_at") ? ["-codec:a", "aac_at", "-profile:a", "38", "-aac_at_mode", "cbr"] : nil
    }

    /// The RTSP demuxer's socket timeout option: `-timeout` since FFmpeg 5, `-stimeout` before (where `-timeout` made FFmpeg
    /// listen for a connection instead).
    public func rtspTimeoutFlag() async -> String {
        guard let version = await probe.value?.ffmpegVersion else { return "-timeout" }
        return RTSPCameraArguments.timeoutFlag(version: version)
    }

    /// Reading `url`, with the timeout option this FFmpeg takes: what every caller passes to the command lines below.
    public func input(url: String, options: RTSPCameraOptions) async -> [String] {
        RTSPCameraArguments.input(url: url, options: options, timeoutFlag: await rtspTimeoutFlag())
    }

    /// One JPEG frame of `url`, FFmpeg killed after `timeout` milliseconds; nil when it gave none.
    public func frame(url: String, options: RTSPCameraOptions, timeout: Int = 15_000, logErrors: Bool) async -> Data? {
        let arguments = RTSPCameraArguments.frame(input: await input(url: url, options: options))
        guard let result = await FfmpegExec(self.options, commandLineArgs: arguments, logErrors: logErrors).exec(timeout: timeout),
              result.stdout.starts(with: [0xFF, 0xD8]) else { return nil }
        return result.stdout
    }

    /// A recording's AAC: AAC-LC from libfdk_aac or FFmpeg's own encoder, AAC-ELD from libfdk_aac only.
    public func recordingAudioEncoder(_ type: AudioRecordingCodecType) async -> [String]? {
        let fdk = await probe.value.map { $0.hasEncoder("aac", "libfdk_aac") } ?? true
        switch type {
        case .aacLC: return fdk ? ["-codec:a", "libfdk_aac", "-profile:a", "aac_low"] : ["-codec:a", "aac", "-profile:a", "aac_low"]
        case .aacELD: return fdk ? ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"] : nil
        }
    }
}

/// FFmpeg's command lines for an RTSP camera, as argv: no shell is involved.
public enum RTSPCameraArguments {
    /// Where a live stream goes: HomeKit's controller and the keys it gave.
    public struct Target: Sendable, Equatable {
        public var address: String
        public var videoPort: Int
        /// Key and salt, 30 bytes.
        public var videoSRTP: Data
        public var videoSSRC: UInt32
        public var audioPort: Int
        public var audioSRTP: Data
        public var audioSSRC: UInt32

        public init(address: String, videoPort: Int, videoSRTP: Data, videoSSRC: UInt32, audioPort: Int, audioSRTP: Data, audioSSRC: UInt32) {
            self.address = address
            self.videoPort = videoPort
            self.videoSRTP = videoSRTP
            self.videoSSRC = videoSSRC
            self.audioPort = audioPort
            self.audioSRTP = audioSRTP
            self.audioSSRC = audioSSRC
        }
    }

    /// Reading the camera's URL; `timeoutFlag` is `RTSPCameraFFmpeg.rtspTimeoutFlag()`'s.
    public static func input(url: String, options: RTSPCameraOptions, timeoutFlag: String = "-timeout") -> [String] {
        var arguments: [String] = []
        let rtsp = url.lowercased().hasPrefix("rtsp")
        if options.rtspOverTCP, rtsp { arguments += ["-rtsp_transport", "tcp"] }
        if let timeout = options.socketTimeout, rtsp { arguments += [timeoutFlag, "\(timeout)"] }
        return arguments + ["-analyzeduration", "\(options.analyzeDuration)", "-probesize", "\(options.probeSize)", "-i", url]
    }

    /// `-stimeout` for an FFmpeg before 5 (`4.4.2`, `n4.3`), `-timeout` otherwise, an unknown version included.
    public static func timeoutFlag(version: String) -> String {
        let digits = (version.hasPrefix("n") ? version.dropFirst() : Substring(version)).prefix { $0.isNumber }
        guard let major = Int(digits) else { return "-timeout" }
        return major < 5 ? "-stimeout" : "-timeout"
    }

    /// The scaling filter for a requested size; nil when HomeKit asked for none.
    public static func filter(width: Int, height: Int) -> String? {
        guard width > 0 || height > 0 else { return nil }
        let w = width > 0 ? "'min(\(width),iw)'" : "iw"
        let h = height > 0 ? "'min(\(height),ih)'" : "ih"
        return "scale=\(w):\(h):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    /// A live stream: the input, video to HomeKit's video port and, when FFmpeg has an AAC-ELD encoder (`audioEncoder`), audio
    /// to its audio port, both SRTP.
    public static func live(input: [String], request: StartStreamRequest, target: Target, options: RTSPCameraOptions, audioEncoder: [String]?) -> [String] {
        let video = request.video
        var arguments = input
        arguments += ["-an", "-sn", "-dn", "-codec:v"] + options.encoder + ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-color_range", "mpeg"]
        if !options.copiesVideo {
            let bitrate = video.maxBitRate * 4
            arguments += ["-bf", "0", "-r", "\(video.fps)", "-b:v", "\(bitrate)k", "-bufsize", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k"]
            if let filter = filter(width: video.width, height: video.height) { arguments += ["-filter:v", filter] }
        }
        arguments += [
            "-payload_type", "\(video.pt)", "-ssrc", "\(target.videoSSRC)", "-f", "rtp",
            "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.videoSRTP.base64EncodedString(),
            "srtp://\(target.address):\(target.videoPort)?rtcpport=\(target.videoPort)&pkt_size=\(video.mtu)",
        ]
        if let audioEncoder {
            let audio = request.audio
            arguments += ["-vn", "-sn", "-dn"] + audioEncoder + [
                "-flags", "+global_header", "-ar", "\(audio.sampleRate)k", "-b:a", "\(audio.maxBitRate)k", "-ac", "\(audio.channel)",
                "-payload_type", "\(audio.pt)", "-ssrc", "\(target.audioSSRC)", "-f", "rtp",
                "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.audioSRTP.base64EncodedString(),
                "srtp://\(target.address):\(target.audioPort)?rtcpport=\(target.audioPort)&pkt_size=188",
            ]
        }
        if options.debug { arguments += ["-loglevel", "level+verbose"] }
        return arguments
    }

    public struct UnsupportedRecording: Error, CustomStringConvertible {
        public var description: String
    }

    /// A recording: H.264 as HomeKit chose it (libx264) and its audio, as fragmented MP4 on standard output; without audio
    /// when FFmpeg cannot encode it (`audioEncoder`: the codec and its profile).
    public static func recording(input: [String], configuration: CameraRecordingConfiguration, audioEncoder: [String]?) throws -> [String] {
        let video = configuration.videoCodec
        guard video.type == .h264 else { throw UnsupportedRecording(description: "the recording's codec is not H.264") }
        let rates: [AudioRecordingSamplerate: String] = [.khz8: "8", .khz16: "16", .khz24: "24", .khz32: "32", .khz44_1: "44.1", .khz48: "48"]
        let audio = configuration.audioCodec
        guard let sampleRate = rates[audio.samplerate] else { throw UnsupportedRecording(description: "unsupported sample rate") }
        var arguments = input
        if let audioEncoder {
            arguments += audioEncoder + ["-ar", "\(sampleRate)k", "-b:a", "\(audio.bitrate)k", "-ac", "\(audio.audioChannels)"]
        } else {
            arguments += ["-an"]
        }
        let profile = h264ProfileArg(video.parameters.profile), level = h264LevelArg(video.parameters.level)
        let interval = Double(video.parameters.iFrameInterval) / 1000
        let seconds = interval == interval.rounded() ? String(Int(interval)) : String(interval)
        arguments += [
            "-sn", "-dn", "-codec:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", profile, "-level:v", level,
            "-b:v", "\(video.parameters.bitRate)k", "-force_key_frames", "expr:eq(t,n_forced*\(seconds))", "-r", "\(video.resolution.fps)",
            "-fflags", "+genpts", "-reset_timestamps", "1", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1",
        ]
        return arguments
    }

    /// One JPEG frame of the input on standard output: a snapshot from the stream.
    public static func frame(input: [String]) -> [String] {
        ["-hide_banner"] + input + ["-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
    }
}

struct RTSPCameraError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Snapshots and live streams of one RTSP camera: a source per HomeKit session, read by an FFmpeg that sends SRTP to the
/// controller, and a UDP socket on the video return port whose silence (no RTCP for twice the interval, once the first
/// came) ends a stream nobody watches.
public actor RTSPCameraStreamer: CameraStreamingDelegate {
    /// The sizes HomeKit may ask a camera's live stream for, as HAP-NodeJS's examples list them.
    public static let standardResolutions: [VideoResolution] = [
        VideoResolution(320, 180, 30), VideoResolution(320, 240, 15), VideoResolution(320, 240, 30), VideoResolution(480, 270, 30),
        VideoResolution(480, 360, 30), VideoResolution(640, 360, 30), VideoResolution(640, 480, 30), VideoResolution(1280, 720, 30),
        VideoResolution(1280, 960, 30), VideoResolution(1920, 1080, 30), VideoResolution(1600, 1200, 30),
    ]
    static let preparedLifetime: Duration = .seconds(60)
    /// How long a stream may go without HomeKit's first RTCP report.
    static let firstReportWait: Duration = .seconds(60)

    private let name: String
    private let options: RTSPCameraOptions
    private let ffmpeg: RTSPCameraFFmpeg
    private let ports: RtpPortAllocator
    private let open: RTSPSourceOpener
    private let snapshot: @Sendable (SnapshotRequest) async throws -> Data
    private let log: Logger
    private let timeScale: Double
    private let minimumInactivity: Duration
    private weak var controller: CameraController?

    private struct Prepared {
        var target: RTSPCameraArguments.Target
        var videoReturnPort: Int
        var audioReturnPort: Int
        var isIPv6: Bool
        var preparedAt: ContinuousClock.Instant
    }

    private struct Session {
        var token: Int
        var process: FfmpegProcess
        var source: RTSPSource
        var socket: UDPSocket?
        var watcher: Task<Void, Never>?
        var ports: [Int]
        var started = false
    }

    private var prepared: [String: Prepared] = [:]
    private var sessions: [String: Session] = [:]
    private var nextToken = 0
    /// Sessions whose source is being opened; a stop takes them out.
    private var starting: Set<String> = []

    /// `snapshot` answers HomeKit's snapshots (the plugin decides where they come from); `timeScale` shortens the inactivity
    /// timeout in tests; `minimumInactivity` is the shortest silence that ends a stream, whatever RTCP interval HomeKit asked
    /// (a stream whose source costs a cloud call should not end on one lost burst of reports).
    public init(name: String, options: RTSPCameraOptions, ffmpeg: RTSPCameraFFmpeg, ports: RtpPortAllocator, open: @escaping RTSPSourceOpener,
                snapshot: @escaping @Sendable (SnapshotRequest) async throws -> Data, log: Logger, timeScale: Double = 1,
                minimumInactivity: Duration = .zero) {
        self.name = name
        self.options = options
        self.ffmpeg = ffmpeg
        self.ports = ports
        self.open = open
        self.snapshot = snapshot
        self.log = log
        self.timeScale = timeScale
        self.minimumInactivity = minimumInactivity
    }

    public func attach(_ controller: CameraController) { self.controller = controller }

    /// The live streams running, for tests.
    public var sessionCount: Int { sessions.count }

    public func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        try await snapshot(request)
    }

    public func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        let now = ContinuousClock.now
        for (id, entry) in prepared where now - entry.preparedAt > Self.preparedLifetime {
            prepared.removeValue(forKey: id)
            release(entry)
        }
        let videoReturnPort = await ports.reserve(ipFamily: request.addressVersion)
        let audioReturnPort = await ports.reserve(ipFamily: request.addressVersion)
        guard videoReturnPort > 0, audioReturnPort > 0 else {
            for port in [videoReturnPort, audioReturnPort] where port > 0 { ports.cancel(port) }
            throw HAPStatusError(.resourceBusy, reason: "No free UDP port")
        }
        let videoSSRC = CameraController.generateSynchronisationSource()
        let audioSSRC = CameraController.generateSynchronisationSource()
        if let previous = prepared.removeValue(forKey: request.sessionID) { release(previous) }
        prepared[request.sessionID] = Prepared(
            target: RTSPCameraArguments.Target(
                address: request.targetAddress, videoPort: request.video.port, videoSRTP: request.video.srtpKey + request.video.srtpSalt, videoSSRC: videoSSRC,
                audioPort: request.audio.port, audioSRTP: request.audio.srtpKey + request.audio.srtpSalt, audioSSRC: audioSSRC),
            videoReturnPort: videoReturnPort, audioReturnPort: audioReturnPort, isIPv6: request.addressVersion == .ipv6, preparedAt: now)
        return PrepareStreamResponse(
            video: .init(port: videoReturnPort, ssrc: videoSSRC, srtpKey: request.video.srtpKey, srtpSalt: request.video.srtpSalt),
            audio: .init(port: audioReturnPort, ssrc: audioSSRC, srtpKey: request.audio.srtpKey, srtpSalt: request.audio.srtpSalt))
    }

    private func release(_ entry: Prepared) {
        ports.cancel(entry.videoReturnPort)
        ports.cancel(entry.audioReturnPort)
    }

    public func handleStreamRequest(_ request: StreamingRequest) async throws {
        switch request {
        case .start(let start): try await startStream(start)
        case .reconfigure: log.debug("\(name): reconfigure (ignored).")
        case .stop(let sessionID): await stopStream(sessionID)
        }
    }

    private func startStream(_ request: StartStreamRequest) async throws {
        guard let entry = prepared.removeValue(forKey: request.sessionID) else { throw HAPStatusError(.serviceCommunicationFailure) }
        let video = request.video
        log.debug("\(name): video stream requested: \(video.width) x \(video.height), \(video.fps) fps, \(video.maxBitRate) kbps")
        let source: RTSPSource
        starting.insert(request.sessionID)
        do {
            source = try await open(.live)
        } catch {
            starting.remove(request.sessionID)
            release(entry)
            log.error("\(name): cannot start the stream: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        let audio = await ffmpeg.liveAudioEncoder()
        let input = await ffmpeg.input(url: source.url, options: options)
        // A stop that came while the source opened ends it here.
        guard starting.remove(request.sessionID) != nil else {
            release(entry)
            await source.release()
            return
        }
        if audio == nil { log.warning("\(name): FFmpeg has no AAC-ELD encoder (libfdk_aac, or aac_at on macOS): the stream has no audio.") }
        let arguments = RTSPCameraArguments.live(input: input, request: request, target: entry.target,
                                                 options: options, audioEncoder: audio)
        nextToken += 1
        let token = nextToken
        let sessionID = request.sessionID
        let process = FfmpegProcess(ffmpeg.options, commandLineArgs: arguments)
        sessions[sessionID] = Session(token: token, process: process, source: source, ports: [entry.videoReturnPort, entry.audioReturnPort])
        process.start()
        let watched = process.onceExit { [weak self] status in
            Task { await self?.exited(status, sessionID: sessionID, token: token) }
        }
        do {
            guard watched else { throw RTSPCameraError("FFmpeg process creation failed") }
            let socket = try await UDPSocket.bind(host: entry.isIPv6 ? "::" : "0.0.0.0", port: entry.videoReturnPort, bufferSize: 16)
            guard sessions[sessionID]?.token == token else {
                await socket.close()
                throw RTSPCameraError("the stream was stopped")
            }
            sessions[sessionID]?.socket = socket
            let interval = Double(video.rtcpInterval > 0 ? video.rtcpInterval : 0.5)
            let timeout = max(Duration.milliseconds(Int(interval * 2000)), minimumInactivity) * timeScale
            sessions[sessionID]?.watcher = watch(socket, timeout: timeout, sessionID: sessionID, token: token)
            try await process.waitForStart()
        } catch {
            log.error("\(name): failed to start the stream: \(error)")
            await source.failed()
            await stopStream(sessionID, token: token)
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        sessions[sessionID]?.started = true
        await source.started()
    }

    /// HomeKit's RTCP on the video return port: once it has come, a silence of `timeout` ends the stream.
    private func watch(_ socket: UDPSocket, timeout: Duration, sessionID: String, token: Int) -> Task<Void, Never> {
        let lastActivity = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let reader = Task {
            for await _ in socket.datagrams { lastActivity.withLockedValue { $0 = .now } }
        }
        let started = ContinuousClock.now
        return Task { [weak self] in
            defer { reader.cancel() }
            while !Task.isCancelled {
                // The timer starts with the first datagram; one that never comes ends the stream after a minute.
                guard let last = lastActivity.withLockedValue({ $0 }) else {
                    if ContinuousClock.now - started > max(timeout, Self.firstReportWait) {
                        await self?.inactive(sessionID: sessionID, token: token)
                        return
                    }
                    try? await Task.sleep(for: timeout)
                    continue
                }
                let idle = ContinuousClock.now - last
                if idle >= timeout {
                    await self?.inactive(sessionID: sessionID, token: token)
                    return
                }
                try? await Task.sleep(for: timeout - idle)
            }
        }
    }

    private func inactive(sessionID: String, token: Int) async {
        guard sessions[sessionID]?.token == token else { return }
        log.debug("\(name): the controller stopped watching. Stopping the stream.")
        controller?.forceStopStreamingSession(sessionID)
        await stopStream(sessionID, token: token)
    }

    /// FFmpeg ended: an exit the streamer caused is expected; another ends the session.
    private func exited(_ status: FfmpegExitStatus, sessionID: String, token: Int) async {
        guard let session = sessions[sessionID], session.token == token else {
            log.debug("\(name): FFmpeg exited with code \(status.exitCode.map(String.init) ?? "null") and signal \(status.signal ?? "null") (expected)")
            return
        }
        log.error("\(name): FFmpeg exited with code \(status.exitCode.map(String.init) ?? "null") and signal \(status.signal ?? "null")")
        await session.source.failed()
        await stopStream(sessionID, token: token)
        if session.started { controller?.forceStopStreamingSession(sessionID) }
    }

    /// Stops a stream: its watcher and socket, FFmpeg, and its source.
    public func stopStream(_ sessionID: String, token: Int? = nil) async {
        if token == nil { starting.remove(sessionID) }
        if let entry = prepared.removeValue(forKey: sessionID) { release(entry) }
        guard let session = sessions[sessionID], token == nil || session.token == token else { return }
        sessions.removeValue(forKey: sessionID)
        session.watcher?.cancel()
        await session.socket?.close()
        session.process.stop()
        for port in session.ports { ports.cancel(port) }
        await session.source.release()
        log.debug("\(name): stopped the video stream.")
    }

    public func stopAll() async {
        for id in Array(sessions.keys) { await stopStream(id) }
        for entry in prepared.values { release(entry) }
        prepared = [:]
    }
}

/// HomeKit Secure Video for one RTSP camera: each recording opens a source read by an FFmpeg writing fragmented MP4, sent
/// as the initialization segment, then a `moof` and `mdat` per fragment.
public final class RTSPCameraRecorder: CameraRecordingDelegate, @unchecked Sendable {
    private let name: String
    private let options: RTSPCameraOptions
    private let ffmpeg: RTSPCameraFFmpeg
    private let open: RTSPSourceOpener
    private let log: Logger

    private struct Recording {
        var streamID: Int
        var task: Task<Void, Never>
    }

    private struct State {
        var configuration: CameraRecordingConfiguration?
        var recording: Recording?
    }

    private let state = NIOLockedValueBox(State())

    public init(name: String, options: RTSPCameraOptions, ffmpeg: RTSPCameraFFmpeg, open: @escaping RTSPSourceOpener, log: Logger) {
        self.name = name
        self.options = options
        self.ffmpeg = ffmpeg
        self.open = open
        self.log = log
    }

    /// What HomeKit may ask a recording to be: H.264 High 4.0 at the streams' sizes, AAC-LC audio (FFmpeg's own encoder makes
    /// it, where AAC-ELD needs libfdk_aac).
    public static func options(resolutions: [VideoResolution], triggers: [EventTriggerOption] = [.motion]) -> CameraRecordingOptions {
        CameraRecordingOptions(
            prebufferLength: 4000, overrideEventTriggerOptions: triggers,
            mediaContainerConfiguration: [MediaContainerConfiguration(type: .fragmentedMP4, fragmentLength: 4000)],
            video: VideoRecordingOptions(parameters: H264CodecParameters(profiles: [.high], levels: [.level4_0]), resolutions: resolutions),
            audio: [AudioRecordingCodec(type: .aacLC, audioChannels: 1, bitrateMode: .variable, samplerate: [.khz48])])
    }

    public var configuration: CameraRecordingConfiguration? { state.withLockedValue { $0.configuration } }

    public func updateRecordingActive(_ active: Bool) {
        log.debug("\(name): recording \(active ? "active" : "inactive").")
    }

    public func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        state.withLockedValue { $0.configuration = configuration }
    }

    public typealias Packets = AsyncThrowingStream<RecordingPacket, any Error>

    public func handleRecordingStreamRequest(streamID: Int) -> Packets {
        let (packets, continuation) = Packets.makeStream()
        guard let configuration = configuration else {
            log.error("\(name): no recording configuration.")
            continuation.finish(throwing: HDSProtocolError(.invalidConfiguration))
            return packets
        }
        let task = Task { [self] in
            do {
                try await record(configuration, continuation)
                continuation.finish()
            } catch {
                if !Task.isCancelled { log.error("\(name): the recording failed: \(error)") }
                continuation.finish(throwing: error)
            }
        }
        // A new recording replaces the one running.
        let previous = state.withLockedValue { state -> Task<Void, Never>? in
            defer { state.recording = Recording(streamID: streamID, task: task) }
            return state.recording?.task
        }
        previous?.cancel()
        continuation.onTermination = { _ in task.cancel() }
        return packets
    }

    private func record(_ configuration: CameraRecordingConfiguration, _ continuation: Packets.Continuation) async throws {
        let source = try await open(.recording)
        let process: FfmpegProcess
        do {
            let audio = await ffmpeg.recordingAudioEncoder(configuration.audioCodec.type)
            let input = await ffmpeg.input(url: source.url, options: options)
            let arguments = try RTSPCameraArguments.recording(input: input, configuration: configuration,
                                                              audioEncoder: audio)
            process = FfmpegProcess(ffmpeg.options, commandLineArgs: arguments)
        } catch {
            await source.release()
            throw error
        }
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(4096))
        process.start()
        let listening = process.onStdout { outputContinuation.yield($0) } != nil && process.onceExit { _ in outputContinuation.finish() }
        var corrupt = false
        if listening {
            var reader = FMp4BoxReader()
            var pending = Data()
            for await chunk in output {
                guard !Task.isCancelled else { break }
                corrupt = !reader.push(chunk) { box in
                    pending.append(box.header)
                    pending.append(box.data)
                    // Everything up to a `moov` (ftyp, moov) or an `mdat` (moof, mdat) is one packet.
                    if box.type == BOX_TYPE_MOOV || box.type == BOX_TYPE_MDAT {
                        continuation.yield(RecordingPacket(data: pending))
                        pending = Data()
                    }
                }
                if corrupt { break }
            }
        }
        process.stop()
        // The recording ends by being cancelled: its source is released from a task of its own.
        await Task { await source.release() }.value
        guard listening else {
            await source.failed()
            throw RTSPCameraError("FFmpeg process creation failed")
        }
        if corrupt { throw RTSPCameraError("FFmpeg wrote an invalid MP4 box") }
    }

    public func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        let task = state.withLockedValue { state -> Task<Void, Never>? in
            guard state.recording?.streamID == streamID else { return nil }
            defer { state.recording = nil }
            return state.recording?.task
        }
        task?.cancel()
    }

    public func shutdown() {
        state.withLockedValue { $0.recording?.task }?.cancel()
    }
}
