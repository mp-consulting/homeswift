import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// The last image of a lens, kept on disk so it survives a restart: snapshots never wake the camera
/// (docs/clean-room/TapoCamera.md, 10), they show what the last live view saw.
final class TapoSnapshotStore: Sendable {
    private let file: URL?
    private let image: NIOLockedValueBox<Data?>

    init(file: URL?) {
        self.file = file
        image = NIOLockedValueBox(file.flatMap { try? Data(contentsOf: $0) })
    }

    var current: Data? { image.withLockedValue { $0 } }

    func update(_ data: Data) {
        image.withLockedValue { $0 = data }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? OwnerOnlyFile.write(data, to: file)
    }
}

/// One lens as a camera's streaming delegate: an FFmpeg per HomeKit session reads the feed's MPEG-TS on its standard
/// input, takes the lens's video stream (`0:v:<index>`), encodes it as HomeKit asked (HEVC in HD must become H.264) and
/// sends it as SRTP. The camera's G.711, which FFmpeg's MPEG-TS demuxer misreads (11), is taken out of the feed here
/// (`MPEGTSAudioExtractor`), held in a jitter buffer (`TapoAudioJitterBuffer`) and given in real time, as 16 kHz PCM,
/// to a second FFmpeg that encodes it as HomeKit asked (Opus or AAC-ELD) to the audio port. A second process, not a
/// second input: FFmpeg keeps its inputs in step, so the video's stalls would stall the audio, which the Home app then
/// plays crackling. A UDP socket on the video return port ends a stream nobody watches.
actor TapoCameraStreamer: CameraStreamingDelegate {
    static let preparedLifetime: Duration = .seconds(60)

    private let name: String
    /// Which video stream of the feed is this lens's.
    let videoIndex: Int
    let feed: TapoCameraFeed
    private let snapshots: TapoSnapshotStore
    let ffmpeg: FfmpegOptions
    private let ports: RtpPortAllocator
    private let log: Logger
    private let inputFps: Int
    /// The audio codec the camera offers HomeKit; nil when FFmpeg can encode none, and streams go without audio.
    let audioCodec: AudioStreamingCodecType?
    private weak var controller: CameraController?

    private struct Prepared {
        var address: String
        var isIPv6: Bool
        var videoPort: Int
        var videoKey: Data
        var videoSSRC: UInt32
        var videoReturnPort: Int
        var audioPort: Int
        var audioKey: Data
        var audioSSRC: UInt32
        var audioReturnPort: Int
        var preparedAt: ContinuousClock.Instant
    }

    private struct Session {
        var token: Int
        var process: FfmpegProcess
        /// The audio's FFmpeg, fed by `audioClock`.
        var audioProcess: FfmpegProcess?
        var viewer: Int?
        var pump: Task<Void, Never>?
        /// Releases the camera's audio to FFmpeg in real time (`TapoAudioJitterBuffer`).
        var audioClock: Task<Void, Never>?
        var socket: UDPSocket?
        var watcher: Task<Void, Never>?
        var ports: [Int]
    }

    private var prepared: [String: Prepared] = [:]
    private var sessions: [String: Session] = [:]
    private var nextToken = 0

    init(name: String, videoIndex: Int, feed: TapoCameraFeed, snapshots: TapoSnapshotStore, ffmpeg: FfmpegOptions, ports: RtpPortAllocator, inputFps: Int,
         audioCodec: AudioStreamingCodecType? = nil, log: Logger) {
        self.audioCodec = audioCodec
        self.name = name
        self.videoIndex = videoIndex
        self.feed = feed
        self.snapshots = snapshots
        self.ffmpeg = ffmpeg
        self.ports = ports
        self.inputFps = inputFps
        self.log = log
    }

    func attach(_ controller: CameraController) { self.controller = controller }

    /// The lens's name and log, for the web UI's live view.
    var liveName: String { name }
    var liveLog: Logger { log }

    var sessionCount: Int { sessions.count }

    // MARK: Snapshots

    /// The last image a live view saw; never a new connection to the camera.
    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        guard let image = snapshots.current else { throw HAPStatusError(.resourceDoesNotExist) }
        return image
    }

    /// FFmpeg's command line for one frame from a lens's MPEG-TS (`MPEGTSLensFilter`'s) on its standard input, as JPEG.
    static func snapshotArguments() -> [String] {
        ["-hide_banner", "-loglevel", "error", "-fflags", "+discardcorrupt", "-probesize", "1M", "-analyzeduration", "500000", "-f", "mpegts", "-i", "pipe:0",
         "-map", "0:v:0", "-frames:v", "1", "-vf", "scale='min(1280,iw)':-2", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
    }

    /// Takes the image of the `videoIndex`th lens from a sample of the feed.
    static func snapshot(from sample: Data, videoIndex: Int, ffmpeg: FfmpegOptions) async -> Data? {
        var filter = MPEGTSLensFilter(videoIndex: videoIndex)
        let lens = filter.filter(sample)
        guard !lens.isEmpty else { return nil }
        let exec = FfmpegExec(ffmpeg, commandLineArgs: snapshotArguments(), logErrors: false)
        guard let result = await exec.exec(lens, timeout: 20_000), result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
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
            videoKey: request.video.srtpKey + request.video.srtpSalt, videoSSRC: videoSSRC, videoReturnPort: videoReturnPort,
            audioPort: request.audio.port, audioKey: request.audio.srtpKey + request.audio.srtpSalt, audioSSRC: audioSSRC,
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

    /// FFmpeg's command line for a live stream: the feed's MPEG-TS on standard input, this lens's video encoded as
    /// HomeKit asked, as SRTP. The encoding is `RTSPCameraStreamer`'s, which HomeKit plays: libx264 with no latency,
    /// yuv420p in the MPEG range, a keyframe a second; the 4K HEVC is decoded by VideoToolbox on a Mac.
    static func arguments(videoIndex: Int, request: StartStreamRequest, target: (address: String, isIPv6: Bool, port: Int, key: Data, ssrc: UInt32),
                          ffmpeg: FfmpegOptions, inputFps: Int, debug: Bool) -> [String] {
        let video = request.video
        let host = target.isIPv6 ? "[\(target.address)]" : target.address
        var arguments = ["-hide_banner", "-nostats", "-fflags", "+genpts+discardcorrupt+nobuffer", "-err_detect", "ignore_err"]
        #if os(macOS)
        arguments += ["-hwaccel", "videotoolbox"]
        #endif
        // One stream that opens on a keyframe (`MPEGTSLensFilter`): FFmpeg starts at once, with no backlog to send.
        arguments += ["-probesize", "1M", "-analyzeduration", "500000", "-f", "mpegts", "-i", "pipe:0", "-map", "0:v:0", "-an", "-sn", "-dn"]
        let bitrate = max(video.maxBitRate, 300) * 4
        let fps = video.fps > 0 ? video.fps : inputFps
        arguments += ["-codec:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-color_range", "mpeg",
                      "-bf", "0", "-r", "\(fps)", "-g", "\(fps)", "-b:v", "\(bitrate)k", "-bufsize", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k"]
        if video.width > 0, video.height > 0 {
            arguments += ["-filter:v", "scale='min(\(video.width),iw)':'min(\(video.height),ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        arguments += ["-payload_type", "\(video.pt)", "-ssrc", "\(target.ssrc)", "-f", "rtp",
                      "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.key.base64EncodedString(),
                      "srtp://\(host):\(target.port)?rtcpport=\(target.port)&pkt_size=\(video.mtu > 0 ? video.mtu : 1316)"]
        arguments += ["-loglevel", debug ? "level+verbose" : "level+error"]
        return arguments
    }

    /// The audio's FFmpeg: the camera's audio as 16 kHz PCM on standard input, released in real time
    /// (`TapoAudioJitterBuffer`), encoded with `encoder` (`audioEncoder`) to HomeKit's audio port as SRTP.
    static func audioArguments(request: StartStreamRequest, target: (address: String, isIPv6: Bool, port: Int, key: Data, ssrc: UInt32),
                               encoder: [String], debug: Bool) -> [String] {
        let info = request.audio
        let host = target.isIPv6 ? "[\(target.address)]" : target.address
        return ["-hide_banner", "-nostats", "-f", "s16le", "-ar", "\(TapoAudioConverter.outputRate)", "-ac", "1", "-i", "pipe:0", "-map", "0:a:0", "-vn", "-sn", "-dn"]
            + encoder + [
                "-flags", "+global_header", "-ar", "\(info.sampleRate)k", "-b:a", "\(max(info.maxBitRate, 16))k", "-ac", "\(max(info.channel, 1))",
                "-payload_type", "\(info.pt)", "-ssrc", "\(target.ssrc)", "-f", "rtp", "-flush_packets", "1",
                "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.key.base64EncodedString(),
                "srtp://\(host):\(target.port)?rtcpport=\(target.port)&pkt_size=188",
                "-loglevel", debug ? "level+verbose" : "level+error"]
    }

    /// The encoder for HomeKit's audio codec: Opus from libopus, AAC-ELD from libfdk_aac or AudioToolbox; nil when FFmpeg
    /// has none for it.
    static func audioEncoder(_ info: AudioInfo, ffmpeg: FfmpegOptions) -> [String]? {
        switch info.codec {
        case .opus: return ffmpeg.hasOpusEncoder ? ffmpeg.opusEncoder(packetTime: info.packetTime) : nil
        case .aacELD:
            let encoder = ffmpeg.audioEncoder()
            return encoder.isEmpty ? nil : encoder + ["-profile:a", "38"]
        default: return nil
        }
    }

    /// The codec a camera offers HomeKit with this FFmpeg: Opus when it has libopus (ffmpeg-for-homeswift, Homebrew's),
    /// else AAC-ELD when it has an encoder for it, else none. Opus first: HomeKit plays AAC-ELD in frames of 480 samples,
    /// and AudioToolbox's encoder (aac_at, FFmpeg's only AAC-ELD on a Mac without libfdk_aac) makes frames of 512, with
    /// no option to change it, which the Home app plays crackling and metallic.
    static func audioCodec(_ ffmpeg: FfmpegOptions) -> AudioStreamingCodecType? {
        if ffmpeg.hasOpusEncoder { return .opus }
        return ffmpeg.audioEncoder().isEmpty ? nil : .aacELD
    }

    private func startStream(_ request: StartStreamRequest) async throws {
        guard let entry = prepared.removeValue(forKey: request.sessionID) else { throw HAPStatusError(.serviceCommunicationFailure) }
        let arguments = Self.arguments(
            videoIndex: videoIndex, request: request, target: (entry.address, entry.isIPv6, entry.videoPort, entry.videoKey, entry.videoSSRC),
            ffmpeg: ffmpeg, inputFps: inputFps, debug: log.logLevel <= .debug)
        // The audio's own FFmpeg, when the camera offers audio and FFmpeg has an encoder for the codec HomeKit chose.
        let audioProcess = (audioCodec == nil ? nil : Self.audioEncoder(request.audio, ffmpeg: ffmpeg)).map { encoder in
            FfmpegProcess(ffmpeg, commandLineArgs: Self.audioArguments(
                request: request, target: (entry.address, entry.isIPv6, entry.audioPort, entry.audioKey, entry.audioSSRC), encoder: encoder,
                debug: log.logLevel <= .debug))
        }
        log.info("\(name): streaming \(request.video.width) x \(request.video.height) at \(request.video.fps) fps.")
        nextToken += 1
        let token = nextToken
        let sessionID = request.sessionID
        let process = FfmpegProcess(ffmpeg, commandLineArgs: arguments)
        sessions[sessionID] = Session(token: token, process: process, audioProcess: audioProcess, ports: [entry.videoReturnPort, entry.audioReturnPort])
        process.start()
        // The audio is a bonus: its FFmpeg ending leaves the picture going.
        audioProcess?.start()
        _ = audioProcess?.onceExit { [weak self] status in
            Task { await self?.audioExited(status, sessionID: sessionID, token: token) }
        }
        let watched = process.onceExit { [weak self] status in
            Task { await self?.exited(status, sessionID: sessionID, token: token) }
        }
        guard watched else {
            log.error("\(name): FFmpeg did not start.")
            await stopStream(sessionID, token: token)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        // The camera is reached now, and only now: the feed opens its session with its first viewer.
        let (viewer, stream) = await feed.join()
        // Stopped meanwhile (HomeKit's stop, FFmpeg's exit): the viewer leaves at once, and nothing starts for it.
        guard sessions[sessionID]?.token == token else {
            await feed.leave(viewer)
            return
        }
        sessions[sessionID]?.viewer = viewer
        let splitter = TapoFeedSplitter(videoIndex: videoIndex, audio: audioProcess != nil, name: name, log: log)
        if let audioProcess {
            sessions[sessionID]?.audioClock = splitter.runAudio { pcm in
                do {
                    try await audioProcess.writeStdin(pcm)
                    return true
                } catch {
                    return false
                }
            }
        }
        sessions[sessionID]?.pump = Task { [weak self] in
            // The feed is read, and its audio taken, whether or not the video's FFmpeg keeps up (`videoWriter`).
            let (video, writer) = Self.videoWriter(process)
            for await data in stream {
                let lens = splitter.split(data)
                guard !lens.isEmpty else { continue }
                if case .terminated = video.yield(lens) { break }
            }
            video.finish()
            writer.cancel()
            // The feed ended (the camera kept dropping it, or the plugin stops): so does the HomeKit session.
            await self?.feedEnded(sessionID: sessionID, token: token)
        }
        do {
            let socket = try await UDPSocket.bind(host: entry.isIPv6 ? "::" : "0.0.0.0", port: entry.videoReturnPort, bufferSize: 16)
            guard sessions[sessionID]?.token == token else {
                await socket.close()
                return
            }
            sessions[sessionID]?.socket = socket
            let interval = Double(request.video.rtcpInterval > 0 ? request.video.rtcpInterval : 0.5)
            sessions[sessionID]?.watcher = watch(socket, timeout: .seconds(min(max(interval * 5, 30), 300)), sessionID: sessionID, token: token)
        } catch {
            log.warning("\(name): no RTCP watch for this stream: \(error)")
        }
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
                    await self?.forceStop(sessionID: sessionID, token: token, reason: "nobody watches the stream any more")
                    return
                }
                try? await Task.sleep(for: timeout - idle)
            }
        }
    }

    /// The video's way to its FFmpeg's standard input: a queue of `videoBacklog` parts and a task that writes them, so
    /// the feed's reader never waits on FFmpeg (a slow decode would stall the audio taken from the same feed). Past the
    /// backlog the oldest parts go, as a camera's lost packets would (FFmpeg discards what it cannot decode).
    static let videoBacklog = 512

    static func videoWriter(_ process: FfmpegProcess) -> (AsyncStream<Data>.Continuation, Task<Void, Never>) {
        let (parts, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(videoBacklog))
        let task = Task {
            for await part in parts {
                do { try await process.writeStdin(part) } catch { break }
            }
            continuation.finish()
        }
        return (continuation, task)
    }

    /// The audio's FFmpeg ended while its session runs (a stop ends it too, and says nothing): the picture goes on.
    private func audioExited(_ status: FfmpegExitStatus, sessionID: String, token: Int) {
        guard sessions[sessionID]?.token == token else { return }
        log.warning("\(name): the audio's FFmpeg ended (code \(status.exitCode.map(String.init) ?? "none"), signal \(status.signal ?? "none")): the stream goes on without sound.")
    }

    private func feedEnded(sessionID: String, token: Int) async {
        await forceStop(sessionID: sessionID, token: token, reason: "the camera's live view ended")
    }

    private func forceStop(sessionID: String, token: Int, reason: String) async {
        guard sessions[sessionID]?.token == token else { return }
        log.debug("\(name): \(reason): stopping the stream.")
        controller?.forceStopStreamingSession(sessionID)
        await stopStream(sessionID, token: token)
    }

    private func exited(_ status: FfmpegExitStatus, sessionID: String, token: Int) async {
        guard sessions[sessionID]?.token == token else { return }
        log.error("\(name): FFmpeg ended (code \(status.exitCode.map(String.init) ?? "none"), signal \(status.signal ?? "none")).")
        controller?.forceStopStreamingSession(sessionID)
        await stopStream(sessionID, token: token)
    }

    func stopStream(_ sessionID: String, token: Int? = nil) async {
        if let entry = prepared.removeValue(forKey: sessionID) { release(entry) }
        guard let session = sessions[sessionID], token == nil || session.token == token else { return }
        sessions.removeValue(forKey: sessionID)
        session.watcher?.cancel()
        session.pump?.cancel()
        session.audioClock?.cancel()
        session.audioProcess?.stop()
        if let viewer = session.viewer { await feed.leave(viewer) }
        await session.socket?.close()
        session.process.stop()
        for port in session.ports { ports.cancel(port) }
        log.debug("\(name): stream stopped.")
    }

    func stopAll() async {
        for id in Array(sessions.keys) { await stopStream(id) }
        for entry in prepared.values { release(entry) }
        prepared = [:]
    }
}
