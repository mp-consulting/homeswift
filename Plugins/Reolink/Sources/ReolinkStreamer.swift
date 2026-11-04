import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// What a channel's camera reaches the device with.
struct ReolinkCameraSource: Sendable {
    /// `Snap` of the main or sub stream.
    var snapshot: @Sendable (_ sub: Bool) async throws -> Data
    /// The URL FFmpeg reads (credentials inside), and that stream's encoding.
    var stream: @Sendable (_ sub: Bool) async -> (url: String, stream: ReolinkStream)?
    /// Whether the channel is a battery camera asleep now (its snapshot would wake it).
    var asleep: @Sendable () async -> Bool
}

/// Snapshots and live streams of one channel (6.2, 4.6, 4.7): snapshots from `Snap` with a 10-second cache and an FFmpeg
/// frame as the fallback; live video by an FFmpeg reading RTSP over TCP and sending SRTP to the controller, the sub
/// stream for small requests, H.264 copied when the option says so and H.265 always transcoded; a UDP socket on the
/// video return port ends a stream nobody watches.
actor ReolinkStreamer: CameraStreamingDelegate {
    static let snapshotCache: Double = 10
    static let sleepingSnapshotCache: Double = 3600
    static let preparedLifetime: Duration = .seconds(60)

    private let name: String
    private let options: ReolinkPlugin.CameraOptions
    private let ffmpeg: FfmpegOptions
    private let ports: RtpPortAllocator
    private let source: ReolinkCameraSource
    private let log: Logger
    private let timing: ReolinkTiming
    private weak var controller: CameraController?

    private struct Prepared {
        var address: String
        var isIPv6: Bool
        var videoPort: Int
        var videoKey: Data
        var videoSSRC: UInt32
        var audioPort: Int
        var audioKey: Data
        var audioSSRC: UInt32
        var videoReturnPort: Int
        var audioReturnPort: Int
        var preparedAt: ContinuousClock.Instant
    }

    private struct Session {
        var token: Int
        var process: FfmpegProcess
        var socket: UDPSocket?
        var watcher: Task<Void, Never>?
        var ports: [Int]
        var started = false
    }

    private var prepared: [String: Prepared] = [:]
    private var sessions: [String: Session] = [:]
    private var nextToken = 0
    private var lastImage: (data: Data, at: ContinuousClock.Instant)?
    private var fetching: Task<Data, any Error>?

    init(name: String, options: ReolinkPlugin.CameraOptions, ffmpeg: FfmpegOptions, ports: RtpPortAllocator, source: ReolinkCameraSource, log: Logger,
         timing: ReolinkTiming) {
        self.name = name
        self.options = options
        self.ffmpeg = ffmpeg
        self.ports = ports
        self.source = source
        self.log = log
        self.timing = timing
    }

    func attach(_ controller: CameraController) { self.controller = controller }

    var sessionCount: Int { sessions.count }

    // MARK: Snapshots

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        let now = ContinuousClock.now
        if let lastImage, now - lastImage.at < timing.seconds(Self.snapshotCache) { return lastImage.data }
        if let lastImage, now - lastImage.at < timing.seconds(Self.sleepingSnapshotCache), await source.asleep() { return lastImage.data }
        if let fetching { return try await fetching.value }
        let sub = request.width <= 640 && request.height <= 480
        let task = Task { [source, ffmpeg, log, name] () async throws -> Data in
            do {
                return try await source.snapshot(sub)
            } catch {
                log.debug("\(name): Snap failed (\(error)); taking a frame of the stream instead.")
                guard let stream = await source.stream(sub) else { throw error }
                let arguments = ["-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp", "-i", stream.url, "-frames:v", "1", "-f", "image2", "-"]
                guard let frame = await FfmpegExec(ffmpeg, commandLineArgs: arguments, logErrors: false).exec(timeout: 15_000)?.stdout, !frame.isEmpty else {
                    throw error
                }
                return frame
            }
        }
        fetching = task
        defer { fetching = nil }
        do {
            let image = try await task.value
            lastImage = (image, .now)
            return image
        } catch {
            if let lastImage { return lastImage.data }
            log.warning("\(name): no snapshot: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    // MARK: Prepare

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        let now = ContinuousClock.now
        for (id, entry) in prepared where now - entry.preparedAt > Self.preparedLifetime {
            prepared.removeValue(forKey: id)
            release(entry)
        }
        let videoReturnPort = await ports.reserve(ipFamily: request.addressVersion)
        let audioReturnPort = await ports.reserve(ipFamily: request.addressVersion)
        guard videoReturnPort > 0, audioReturnPort > 0 else {
            for port in [videoReturnPort, audioReturnPort] where port > 0 { ports.cancel(port) }
            throw HAPStatusError(.resourceBusy)
        }
        let videoSSRC = CameraController.generateSynchronisationSource()
        let audioSSRC = CameraController.generateSynchronisationSource()
        if let previous = prepared.removeValue(forKey: request.sessionID) { release(previous) }
        prepared[request.sessionID] = Prepared(
            address: request.targetAddress, isIPv6: request.addressVersion == .ipv6, videoPort: request.video.port,
            videoKey: request.video.srtpKey + request.video.srtpSalt, videoSSRC: videoSSRC, audioPort: request.audio.port,
            audioKey: request.audio.srtpKey + request.audio.srtpSalt, audioSSRC: audioSSRC, videoReturnPort: videoReturnPort,
            audioReturnPort: audioReturnPort, preparedAt: now)
        return PrepareStreamResponse(
            video: .init(port: videoReturnPort, ssrc: videoSSRC, srtpKey: request.video.srtpKey, srtpSalt: request.video.srtpSalt),
            audio: .init(port: audioReturnPort, ssrc: audioSSRC, srtpKey: request.audio.srtpKey, srtpSalt: request.audio.srtpSalt))
    }

    private func release(_ entry: Prepared) {
        ports.cancel(entry.videoReturnPort)
        ports.cancel(entry.audioReturnPort)
    }

    // MARK: Streams

    func handleStreamRequest(_ request: StreamingRequest) async throws {
        switch request {
        case .start(let start): try await startStream(start)
        case .reconfigure: log.debug("\(name): reconfigure (ignored).")
        case .stop(let sessionID): await stopStream(sessionID)
        }
    }

    /// Whether a request is answered from the sub stream (6.2): `stream` says, or `auto` takes it for sizes up to its own.
    static func usesSub(_ option: String, request: VideoInfo, sub: ReolinkStream) -> Bool {
        switch option {
        case "main": false
        case "sub": true
        default: request.width <= sub.width && request.height <= sub.height
        }
    }

    /// FFmpeg's command line for a live stream: the source over TCP, the video copied (H.264 with `vcodec: copy`) or
    /// encoded as HomeKit asked, the audio when on, both as SRTP.
    static func arguments(url: String, stream: ReolinkStream, request: StartStreamRequest, target: (address: String, isIPv6: Bool, videoPort: Int, videoKey: Data,
                                                                                                   videoSSRC: UInt32, audioPort: Int, audioKey: Data, audioSSRC: UInt32),
                          options: ReolinkPlugin.CameraOptions, ffmpeg: FfmpegOptions, audioEncoder: [String]?) -> [String] {
        let video = request.video
        let host = target.isIPv6 ? "[\(target.address)]" : target.address
        var arguments = ["-hide_banner", "-nostats", "-fflags", "+discardcorrupt", "-err_detect", "ignore_err"]
        if url.hasPrefix("rtsp") { arguments += ["-rtsp_transport", "tcp"] }
        arguments += ["-i", url, "-map", "0:v:0"]
        if options.vcodec == "copy", stream.codec == "h264" {
            arguments += ["-codec:v", "copy"]
        } else {
            arguments += ffmpeg.streamEncoder(VideoEncoderOptions(
                bitrate: video.maxBitRate, fps: video.fps, height: video.height, idrInterval: HOMEKIT_IDR_INTERVAL, inputFps: stream.fps,
                level: H264Level(rawValue: video.level) ?? .level3_1, profile: H264Profile(rawValue: video.profile) ?? .main, width: video.width))
            if let extra = options.encoderOptions { arguments += extra.split(whereSeparator: \.isWhitespace).map(String.init) }
        }
        arguments += ["-payload_type", "\(video.pt)", "-ssrc", "\(target.videoSSRC)", "-f", "rtp",
                      "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.videoKey.base64EncodedString(),
                      "srtp://\(host):\(target.videoPort)?rtcpport=\(target.videoPort)&pkt_size=\(video.mtu > 0 ? video.mtu : 1316)"]
        if options.audio, let audioEncoder {
            let audio = request.audio
            arguments += ["-map", "0:a:0?"] + audioEncoder + ["-flags", "+global_header", "-ar", "\(audio.sampleRate)k", "-b:a", "\(audio.maxBitRate)k",
                                                              "-ac", "\(audio.channel)", "-payload_type", "\(audio.pt)", "-ssrc", "\(target.audioSSRC)", "-f", "rtp",
                                                              "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.audioKey.base64EncodedString(),
                                                              "srtp://\(host):\(target.audioPort)?rtcpport=\(target.audioPort)&pkt_size=188"]
        }
        arguments += ["-loglevel", options.debug ? "level+verbose" : "level+error"]
        return arguments
    }

    private func startStream(_ request: StartStreamRequest) async throws {
        guard let entry = prepared.removeValue(forKey: request.sessionID) else { throw HAPStatusError(.serviceCommunicationFailure) }
        let subInfo = await source.stream(true)
        let sub = subInfo.map { Self.usesSub(options.stream, request: request.video, sub: $0.stream) } ?? false
        guard let chosen = sub ? subInfo : await source.stream(false) else {
            release(entry)
            log.error("\(name): no stream to read.")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        let audioEncoder: [String]? = options.audio ? ffmpeg.audioEncoder().nonEmptyArray : nil
        let target = (entry.address, entry.isIPv6, entry.videoPort, entry.videoKey, entry.videoSSRC, entry.audioPort, entry.audioKey, entry.audioSSRC)
        let arguments = Self.arguments(url: chosen.url, stream: chosen.stream, request: request, target: target, options: options, ffmpeg: ffmpeg,
                                       audioEncoder: audioEncoder)
        log.info("\(name): streaming \(request.video.width) x \(request.video.height) at \(request.video.fps) fps from the \(sub ? "sub" : "main") stream (\(chosen.stream.codec)).")
        log.debug("\(name): FFmpeg \(ReolinkStreamURL.masked(redactCommandLine(arguments)))")
        nextToken += 1
        let token = nextToken
        let sessionID = request.sessionID
        let process = FfmpegProcess(ffmpeg, commandLineArgs: arguments)
        sessions[sessionID] = Session(token: token, process: process, ports: [entry.videoReturnPort, entry.audioReturnPort])
        process.start()
        let watched = process.onceExit { [weak self] status in
            Task { await self?.exited(status, sessionID: sessionID, token: token) }
        }
        do {
            guard watched else { throw ReolinkError.invalidResponse("FFmpeg did not start") }
            let socket = try await UDPSocket.bind(host: entry.isIPv6 ? "::" : "0.0.0.0", port: entry.videoReturnPort, bufferSize: 16)
            guard sessions[sessionID]?.token == token else {
                await socket.close()
                return
            }
            sessions[sessionID]?.socket = socket
            let interval = Double(request.video.rtcpInterval > 0 ? request.video.rtcpInterval : 0.5)
            let timeout = timing.seconds(min(max(interval * 5, 30), 300))
            sessions[sessionID]?.watcher = watch(socket, timeout: timeout, sessionID: sessionID, token: token)
            try await process.waitForStart()
        } catch {
            log.error("\(name): the stream did not start: \(error)")
            await stopStream(sessionID, token: token)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        sessions[sessionID]?.started = true
    }

    /// HomeKit's RTCP on the video return port: a silence of `timeout` ends the stream.
    private func watch(_ socket: UDPSocket, timeout: Duration, sessionID: String, token: Int) -> Task<Void, Never> {
        let lastActivity = NIOLockedValueBox(ContinuousClock.now)
        let reader = Task {
            for await _ in socket.datagrams { lastActivity.withLockedValue { $0 = .now } }
        }
        return Task { [weak self] in
            defer { reader.cancel() }
            while !Task.isCancelled {
                let idle = ContinuousClock.now - lastActivity.withLockedValue { $0 }
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
        log.debug("\(name): nobody watches the stream any more: stopping it.")
        controller?.forceStopStreamingSession(sessionID)
        await stopStream(sessionID, token: token)
    }

    private func exited(_ status: FfmpegExitStatus, sessionID: String, token: Int) async {
        guard let session = sessions[sessionID], session.token == token else { return }
        log.error("\(name): FFmpeg ended (code \(status.exitCode.map(String.init) ?? "none"), signal \(status.signal ?? "none")).")
        await stopStream(sessionID, token: token)
        if session.started { controller?.forceStopStreamingSession(sessionID) }
    }

    func stopStream(_ sessionID: String, token: Int? = nil) async {
        if let entry = prepared.removeValue(forKey: sessionID) { release(entry) }
        guard let session = sessions[sessionID], token == nil || session.token == token else { return }
        sessions.removeValue(forKey: sessionID)
        session.watcher?.cancel()
        await session.socket?.close()
        session.process.stop()
        for port in session.ports { ports.cancel(port) }
        log.debug("\(name): stream stopped.")
    }

    func stopAll() async {
        for id in Array(sessions.keys) { await stopStream(id) }
        for entry in prepared.values { release(entry) }
        prepared = [:]
        fetching?.cancel()
    }
}

extension Array {
    var nonEmptyArray: Self? { isEmpty ? nil : self }
}

/// HomeKit Secure Video of one channel (6.2): `RTSPRecordingSource` on its main stream.
final class ReolinkRecorder: CameraRecordingDelegate, @unchecked Sendable {
    private let name: String
    private let log: Logger
    private let fps: Int
    private let state = NIOLockedValueBox<(configuration: CameraRecordingConfiguration?, source: RTSPRecordingSource?)>((nil, nil))
    private let makeSource: @Sendable () async -> RTSPRecordingSource?

    init(name: String, fps: Int, log: Logger, makeSource: @escaping @Sendable () async -> RTSPRecordingSource?) {
        self.name = name
        self.fps = fps
        self.log = log
        self.makeSource = makeSource
    }

    static func options(resolutions: [VideoResolution]) -> CameraRecordingOptions {
        CameraRecordingOptions(
            prebufferLength: 4000, overrideEventTriggerOptions: [.motion, .doorbell],
            mediaContainerConfiguration: [MediaContainerConfiguration(type: .fragmentedMP4, fragmentLength: HKSV_FRAGMENT_LENGTH)],
            video: VideoRecordingOptions(parameters: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]),
                                         resolutions: resolutions),
            audio: [AudioRecordingCodec(type: .aacLC, audioChannels: 1, bitrateMode: .variable, samplerate: [.khz32, .khz48])])
    }

    func start() async {
        guard let source = await makeSource() else { return }
        let configuration = state.withLockedValue { state in
            state.source = source
            return state.configuration
        }
        if let configuration { source.start(configuration) }
    }

    func updateRecordingActive(_ active: Bool) {
        log.debug("\(name): HomeKit Secure Video \(active ? "on" : "off").")
    }

    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        let source = state.withLockedValue { state in
            state.configuration = configuration
            return state.source
        }
        if let configuration { source?.start(configuration) }
    }

    func handleRecordingStreamRequest(streamID: Int) -> AsyncThrowingStream<RecordingPacket, any Error> {
        let (configuration, source) = state.withLockedValue { ($0.configuration, $0.source) }
        guard let configuration, let source else {
            return AsyncThrowingStream { $0.finish(throwing: HDSProtocolError(.invalidConfiguration)) }
        }
        log.debug("\(name): recording \(streamID) starts.")
        return source.recording(configuration, fps: fps)
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        log.debug("\(name): recording \(streamID) ended\(reason.map { " (\($0))" } ?? "").")
    }

    func shutdown() {
        state.withLockedValue { $0.source }?.stop()
    }
}
