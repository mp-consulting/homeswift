import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The FFmpeg the cameras run, and the audio encoders it has, asked once in the background.
final class NestFFmpeg: Sendable {
    let options: FfmpegOptions
    private let probe: Task<FfmpegCodecs?, Never>

    init(executable: String = "ffmpeg", logger: Logger, debug: Bool) {
        let codecs = FfmpegCodecs(ffmpegExec: executable, log: logger, ffmpegVersion: "")
        var config = FfmpegOptionsConfig(codecSupport: codecs, debug: debug, hardwareDecoding: false, hardwareTranscoding: false, log: logger, name: { "Nest" })
        // Stopping writes `q`, then kills FFmpeg if it still runs two seconds later.
        config.inputTimeout = 2000
        options = FfmpegOptions(config)
        probe = Task {
            let probed = FfmpegCodecs(ffmpegExec: executable, log: logger)
            return await probed.probe() ? probed : nil
        }
    }

    /// Codecs known in advance (tests).
    init(options: FfmpegOptions, codecs: FfmpegCodecs?) {
        self.options = options
        probe = Task { codecs }
    }

    /// HomeKit's AAC-ELD for live streams: libfdk_aac (the Homebridge plugin's), else AudioToolbox's on macOS; nil when
    /// FFmpeg has neither, and the stream goes without audio.
    func liveAudioEncoder() async -> [String]? {
        guard let codecs = await probe.value, !codecs.hasEncoder("aac", "libfdk_aac") else { return ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"] }
        return codecs.hasEncoder("aac", "aac_at") ? ["-codec:a", "aac_at", "-profile:a", "38", "-aac_at_mode", "cbr"] : nil
    }

    /// A recording's AAC: AAC-LC from libfdk_aac or FFmpeg's own encoder, AAC-ELD from libfdk_aac only.
    func recordingAudioEncoder(_ type: AudioRecordingCodecType) async -> [String]? {
        let fdk = await probe.value.map { $0.hasEncoder("aac", "libfdk_aac") } ?? true
        switch type {
        case .aacLC: return fdk ? ["-codec:a", "libfdk_aac", "-profile:a", "aac_low"] : ["-codec:a", "aac", "-profile:a", "aac_low"]
        case .aacELD: return fdk ? ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"] : nil
        }
    }
}

/// One SDM RTSP stream (section 6.5.1): generated for a live view or a recording, extended before it expires (Google gives
/// five minutes; the Homebridge plugin never extends, so its streams stop there), stopped when done.
actor RTSPStream {
    nonisolated let url: String
    private let device: String
    private let send: Commander
    private let log: Logger
    private let lead: Duration
    private var extensionToken: String
    private var extender: Task<Void, Never>?
    private var stopped = false

    private init(url: String, extensionToken: String, device: String, send: @escaping Commander, log: Logger, lead: Duration) {
        self.url = url
        self.extensionToken = extensionToken
        self.device = device
        self.send = send
        self.log = log
        self.lead = lead
    }

    /// `GenerateRtspStream`; `lead` is how long before `expiresAt` the stream is extended.
    static func open(device: String, send: @escaping Commander, log: Logger, lead: Duration = .seconds(60)) async throws -> RTSPStream {
        let results: JSONValue
        do {
            results = try await send(device, "CameraLiveStream.GenerateRtspStream", [:])
        } catch {
            throw StreamError("unable to start stream: no response from the Nest API (\(error))")
        }
        guard let url = results["streamUrls"]?["rtspUrl"]?.stringValue, let token = results["streamExtensionToken"]?.stringValue else {
            throw StreamError("unable to start stream: the Nest API sent no stream")
        }
        let stream = RTSPStream(url: url, extensionToken: token, device: device, send: send, log: log, lead: lead)
        await stream.schedule(expires: results["expiresAt"]?.stringValue.flatMap(SDMEvent.date))
        return stream
    }

    private func schedule(expires: Date?) {
        guard !stopped, let expires else { return }
        let seconds = max(expires.timeIntervalSinceNow - Double(lead.components.seconds) - Double(lead.components.attoseconds) / 1e18, 0)
        extender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            await self?.extend()
        }
    }

    /// `ExtendRtspStream`: a new extension token and expiry; the running RTSP session goes on. A failure leaves the stream
    /// to end when it expires.
    private func extend() async {
        guard !stopped else { return }
        do {
            let results = try await send(device, "CameraLiveStream.ExtendRtspStream", ["streamExtensionToken": .string(extensionToken)])
            if let token = results["streamExtensionToken"]?.stringValue { extensionToken = token }
            log.debug("Extended the live stream.")
            schedule(expires: results["expiresAt"]?.stringValue.flatMap(SDMEvent.date))
        } catch {
            log.warning("Could not extend the live stream: \(error). It ends when it expires.")
        }
    }

    /// `StopRtspStream`; errors are logged and ignored.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        extender?.cancel()
        do {
            _ = try await send(device, "CameraLiveStream.StopRtspStream", ["streamExtensionToken": .string(extensionToken)])
        } catch {
            log.debug("Could not stop the live stream: \(error)")
        }
    }
}

struct StreamError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Opens an SDM stream for a camera; tests give a fake.
typealias StreamOpener = @Sendable () async throws -> RTSPStream

/// Snapshots and live streams of one camera (sections 6.1 to 6.6): an SDM stream per HomeKit session, read by an FFmpeg
/// that sends SRTP to the controller, and a UDP socket on the video return port whose silence (no RTCP for twice the
/// interval) ends a stream nobody watches.
actor NestStreamer: CameraStreamingDelegate {
    static let preparedLifetime: Duration = .seconds(60)

    private let name: String
    private let webRTC: Bool
    private let options: NestOptions
    private let ffmpeg: NestFFmpeg
    private let ports: RtpPortAllocator
    private let open: StreamOpener
    private let snapshot: @Sendable () async -> Data
    private let log: Logger
    private let timeScale: Double
    private weak var controller: CameraController?

    private struct Prepared {
        var target: FFmpegArguments.Target
        var videoReturnPort: Int
        var audioReturnPort: Int
        var isIPv6: Bool
        var preparedAt: ContinuousClock.Instant
    }

    private struct Session {
        var token: Int
        var process: FfmpegProcess
        var stream: RTSPStream
        var socket: UDPSocket?
        var watcher: Task<Void, Never>?
        var ports: [Int]
        var started = false
    }

    private var prepared: [String: Prepared] = [:]
    private var sessions: [String: Session] = [:]
    private var nextToken = 0

    init(name: String, webRTC: Bool, options: NestOptions, ffmpeg: NestFFmpeg, ports: RtpPortAllocator, open: @escaping StreamOpener,
         snapshot: @escaping @Sendable () async -> Data, log: Logger, timeScale: Double) {
        self.name = name
        self.webRTC = webRTC
        self.options = options
        self.ffmpeg = ffmpeg
        self.ports = ports
        self.open = open
        self.snapshot = snapshot
        self.log = log
        self.timeScale = timeScale
    }

    func attach(_ controller: CameraController) { self.controller = controller }

    var sessionCount: Int { sessions.count }

    /// The latest event image, or the placeholder (section 6.6): SDM has no snapshot of its own, and a stream for one would
    /// spend the quota.
    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        await snapshot()
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        guard !webRTC else {
            log.error("\(name): live view of this camera needs WebRTC, which Homeswift does not have yet.")
            throw HAPStatusError(.resourceDoesNotExist, reason: "Live view of WebRTC cameras is not supported yet")
        }
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
            target: FFmpegArguments.Target(
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

    func handleStreamRequest(_ request: StreamingRequest) async throws {
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
        let stream: RTSPStream
        do {
            stream = try await open()
        } catch {
            release(entry)
            log.error("\(name): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        let audio = await ffmpeg.liveAudioEncoder()
        if audio == nil { log.warning("\(name): FFmpeg has no AAC-ELD encoder (libfdk_aac, or aac_at on macOS): the stream has no audio.") }
        let arguments = FFmpegArguments.live(input: FFmpegArguments.input(rtspURL: stream.url, options: options), request: request, target: entry.target,
                                             options: options, audioEncoder: audio)
        nextToken += 1
        let token = nextToken
        let sessionID = request.sessionID
        let process = FfmpegProcess(ffmpeg.options, commandLineArgs: arguments)
        sessions[sessionID] = Session(token: token, process: process, stream: stream, ports: [entry.videoReturnPort, entry.audioReturnPort])
        process.start()
        let watched = process.onceExit { [weak self] status in
            Task { await self?.exited(status, sessionID: sessionID, token: token) }
        }
        do {
            guard watched else { throw StreamError("FFmpeg process creation failed") }
            let socket = try await UDPSocket.bind(host: entry.isIPv6 ? "::" : "0.0.0.0", port: entry.videoReturnPort, bufferSize: 16)
            guard sessions[sessionID]?.token == token else {
                await socket.close()
                throw StreamError("the stream was stopped")
            }
            sessions[sessionID]?.socket = socket
            let interval = Double(video.rtcpInterval > 0 ? video.rtcpInterval : 0.5)
            sessions[sessionID]?.watcher = watch(socket, timeout: .milliseconds(Int(interval * 2000 * timeScale)), sessionID: sessionID, token: token)
            try await process.waitForStart()
        } catch {
            log.error("\(name): failed to start stream: \(error)")
            await stopStream(sessionID, token: token)
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        sessions[sessionID]?.started = true
    }

    /// HomeKit's RTCP on the video return port: once it has come, a silence of `timeout` ends the stream.
    private func watch(_ socket: UDPSocket, timeout: Duration, sessionID: String, token: Int) -> Task<Void, Never> {
        let lastActivity = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let reader = Task {
            for await _ in socket.datagrams { lastActivity.withLockedValue { $0 = .now } }
        }
        return Task { [weak self] in
            defer { reader.cancel() }
            while !Task.isCancelled {
                // The timer starts with the first datagram.
                guard let last = lastActivity.withLockedValue({ $0 }) else {
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
        log.debug("\(name): device appears to be inactive. Stopping stream.")
        controller?.forceStopStreamingSession(sessionID)
        await stopStream(sessionID, token: token)
    }

    /// FFmpeg ended (section 6.3): an exit the plugin caused is expected; another ends the session.
    private func exited(_ status: FfmpegExitStatus, sessionID: String, token: Int) async {
        guard let session = sessions[sessionID], session.token == token else {
            log.debug("\(name): FFmpeg exited with code \(status.exitCode.map(String.init) ?? "null") and signal \(status.signal ?? "null") (Expected)")
            return
        }
        log.error("\(name): FFmpeg exited with code \(status.exitCode.map(String.init) ?? "null") and signal \(status.signal ?? "null") (Error)")
        await stopStream(sessionID, token: token)
        if session.started { controller?.forceStopStreamingSession(sessionID) }
    }

    /// Stops a stream: its watcher and socket, FFmpeg and the SDM stream.
    func stopStream(_ sessionID: String, token: Int? = nil) async {
        if let entry = prepared.removeValue(forKey: sessionID) { release(entry) }
        guard let session = sessions[sessionID], token == nil || session.token == token else { return }
        sessions.removeValue(forKey: sessionID)
        session.watcher?.cancel()
        await session.socket?.close()
        session.process.stop()
        for port in session.ports { ports.cancel(port) }
        await session.stream.stop()
        log.debug("\(name): stopped video stream.")
    }

    func stopAll() async {
        for id in Array(sessions.keys) { await stopStream(id) }
        for entry in prepared.values { release(entry) }
        prepared = [:]
    }
}

/// HomeKit Secure Video for one RTSP camera (section 6.7): each recording is a new SDM stream read by an FFmpeg writing
/// fragmented MP4, sent as the initialization segment, then a `moof` and `mdat` per fragment.
final class NestRecorder: CameraRecordingDelegate, @unchecked Sendable {
    private let name: String
    private let options: NestOptions
    private let ffmpeg: NestFFmpeg
    private let open: StreamOpener
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

    init(name: String, options: NestOptions, ffmpeg: NestFFmpeg, open: @escaping StreamOpener, log: Logger) {
        self.name = name
        self.options = options
        self.ffmpeg = ffmpeg
        self.open = open
        self.log = log
    }

    /// What HomeKit may ask a recording to be: H.264 High 4.0 at the streams' sizes, AAC-LC audio (FFmpeg's own encoder
    /// makes it, where AAC-ELD needs libfdk_aac).
    static func options(resolutions: [VideoResolution]) -> CameraRecordingOptions {
        CameraRecordingOptions(
            prebufferLength: 4000, overrideEventTriggerOptions: [.motion, .doorbell],
            mediaContainerConfiguration: [MediaContainerConfiguration(type: .fragmentedMP4, fragmentLength: 4000)],
            video: VideoRecordingOptions(parameters: H264CodecParameters(profiles: [.high], levels: [.level4_0]), resolutions: resolutions),
            audio: [AudioRecordingCodec(type: .aacLC, audioChannels: 1, bitrateMode: .variable, samplerate: [.khz48])])
    }

    var configuration: CameraRecordingConfiguration? { state.withLockedValue { $0.configuration } }

    func updateRecordingActive(_ active: Bool) {
        log.debug("\(name): recording \(active ? "active" : "inactive").")
    }

    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        state.withLockedValue { $0.configuration = configuration }
    }

    typealias Packets = AsyncThrowingStream<RecordingPacket, any Error>

    func handleRecordingStreamRequest(streamID: Int) -> Packets {
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
                if !Task.isCancelled { log.error("\(name): encountered an unexpected error on the recording generator: \(error)") }
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
        let stream = try await open()
        let audio = await ffmpeg.recordingAudioEncoder(configuration.audioCodec.type)
        let process: FfmpegProcess
        do {
            let arguments = try FFmpegArguments.recording(input: FFmpegArguments.input(rtspURL: stream.url, options: options), configuration: configuration,
                                                          audioEncoder: audio)
            process = FfmpegProcess(ffmpeg.options, commandLineArgs: arguments)
        } catch {
            await stream.stop()
            throw error
        }
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(4096))
        process.start()
        let listening = process.onStdout { outputContinuation.yield($0) } != nil && process.onceExit { _ in outputContinuation.finish() }
        defer { process.stop() }
        guard listening else {
            await stream.stop()
            throw StreamError("FFmpeg process creation failed")
        }
        var reader = FMp4BoxReader()
        var pending = Data()
        var corrupt = false
        for await chunk in output {
            guard !Task.isCancelled else { break }
            let ok = reader.push(chunk) { box in
                pending.append(box.header)
                pending.append(box.data)
                // Everything up to a `moov` (ftyp, moov) or an `mdat` (moof, mdat) is one packet.
                if box.type == BOX_TYPE_MOOV || box.type == BOX_TYPE_MDAT {
                    continuation.yield(RecordingPacket(data: pending))
                    pending = Data()
                }
            }
            if !ok {
                corrupt = true
                break
            }
        }
        process.stop()
        await stream.stop()
        if corrupt { throw StreamError("FFmpeg wrote an invalid MP4 box") }
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        let task = state.withLockedValue { state -> Task<Void, Never>? in
            guard state.recording?.streamID == streamID else { return nil }
            defer { state.recording = nil }
            return state.recording?.task
        }
        task?.cancel()
    }

    func shutdown() {
        state.withLockedValue { $0.recording?.task }?.cancel()
    }
}
