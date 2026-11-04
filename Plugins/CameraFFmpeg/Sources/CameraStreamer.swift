import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// Snapshots and live streams of one camera (sections 7.2 to 7.7): FFmpeg encrypts and sends the RTP itself, and a UDP
/// socket on the video return port watches HomeKit's RTCP to stop a stream nobody watches any more.
actor CameraStreamer: CameraStreamingDelegate {
    /// How long a snapshot's image (or its failure) answers the requests that follow, after FFmpeg ended.
    static let snapshotCacheWindow: Duration = .seconds(3)
    /// The longest a snapshot's FFmpeg may run (the original has no limit; HomeKit gives up after about 25 seconds).
    static let snapshotTimeout = 60_000
    /// A prepared stream HomeKit never started gives its ports back after this long.
    static let preparedLifetime: Duration = .seconds(60)

    let video: CameraFFmpegPlugin.VideoConfig
    let log: CameraLog
    let tools: FFmpegTools
    private let ports: RtpPortAllocator
    /// Multiplies the inactivity timeout (tests shorten it).
    private let timeScale: Double
    private weak var controller: CameraController?

    private struct Prepared {
        var target: FFmpegArguments.Target
        var videoReturnPort: Int
        var audioReturnPort: Int
        var preparedAt: ContinuousClock.Instant
    }

    private struct Session {
        var token: Int
        var main: FfmpegProcess
        var returnAudio: FfmpegProcess?
        var socket: UDPSocket?
        var tasks: [Task<Void, Never>]
        var ports: [Int]
        /// HomeKit was told the stream started.
        var replied = false
    }

    private var prepared: [String: Prepared] = [:]
    private var sessions: [String: Session] = [:]
    private var nextToken = 0
    private var snapshot: (generation: Int, task: Task<Data, any Error>, finishedAt: ContinuousClock.Instant?)?
    private var snapshotGeneration = 0

    init(video: CameraFFmpegPlugin.VideoConfig, log: CameraLog, tools: FFmpegTools, ports: RtpPortAllocator, timeScale: Double = 1) {
        self.video = video
        self.log = log
        self.tools = tools
        self.ports = ports
        self.timeScale = timeScale
    }

    func attach(_ controller: CameraController) {
        self.controller = controller
    }

    /// The live streams running, for tests.
    var sessionCount: Int { sessions.count }

    // MARK: Snapshots

    struct SnapshotError: Error, CustomStringConvertible {
        var description: String
    }

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        let filters = FFmpegArguments.filters(video, width: request.width, height: request.height, snapshot: true)
        log.debug("Snapshot requested: \(request.width) x \(request.height)")
        do {
            let (image, cached) = try await cachedSnapshot(snapFilter: filters.snapFilter)
            log.debug("Sending snapshot: \(filters.width > 0 ? String(filters.width) : "native") x \(filters.height > 0 ? String(filters.height) : "native")\(cached ? " (cached)" : "")")
            return try await resize(image, resizeFilter: filters.resizeFilter)
        } catch {
            log.error("Error fetching snapshot: \(error)")
            throw error
        }
    }

    /// The image of the fetch running or ended less than `snapshotCacheWindow` ago, whatever size it was asked for, or a new
    /// fetch's.
    private func cachedSnapshot(snapFilter: String) async throws -> (Data, cached: Bool) {
        if let snapshot, snapshot.finishedAt.map({ ContinuousClock.now - $0 < Self.snapshotCacheWindow * timeScale }) ?? true {
            return (try await snapshot.task.value, true)
        }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let task = Task { [video, tools, log] in try await Self.fetchSnapshot(video: video, snapFilter: snapFilter, tools: tools, log: log) }
        snapshot = (generation, task, nil)
        defer { if snapshot?.generation == generation { snapshot?.finishedAt = .now } }
        return (try await task.value, false)
    }

    private static func fetchSnapshot(video: CameraFFmpegPlugin.VideoConfig, snapFilter: String, tools: FFmpegTools, log: CameraLog) async throws -> Data {
        let arguments = FFmpegArguments.snapshotFetch(video, snapFilter: snapFilter)
        let started = ContinuousClock.now
        let result = await FfmpegExec(tools.options, commandLineArgs: arguments, logErrors: video.debug).exec(timeout: snapshotTimeout)
        logTiming(log, ContinuousClock.now - started, "Fetched snapshot",
                  slowSuffix: ". The request has timed out and the snapshot has not been refreshed in HomeKit.")
        guard let result else { throw SnapshotError(description: "FFmpeg process creation failed, or FFmpeg took too long.") }
        guard !result.stdout.isEmpty else { throw SnapshotError(description: "Failed to fetch snapshot.") }
        return result.stdout
    }

    /// The image scaled down to the size HomeKit asked for (its first scaling filter only).
    private func resize(_ image: Data, resizeFilter: String?) async throws -> Data {
        let arguments = FFmpegArguments.snapshotResize(resizeFilter: resizeFilter)
        guard let result = await FfmpegExec(tools.options, commandLineArgs: arguments, logErrors: video.debug).exec(image, timeout: Self.snapshotTimeout) else {
            throw SnapshotError(description: "FFmpeg could not resize the snapshot.")
        }
        return result.stdout
    }

    // MARK: Prepare

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        releaseStalePrepared()
        let family = request.addressVersion
        let videoReturnPort = await ports.reserve(ipFamily: family)
        let audioReturnPort = await ports.reserve(ipFamily: family)
        guard videoReturnPort > 0, audioReturnPort > 0 else {
            for port in [videoReturnPort, audioReturnPort] where port > 0 { ports.cancel(port) }
            log.error("No free UDP port for a stream.")
            throw HAPStatusError(.resourceBusy)
        }
        let videoSSRC = CameraController.generateSynchronisationSource()
        let audioSSRC = CameraController.generateSynchronisationSource()
        if let previous = prepared.removeValue(forKey: request.sessionID) { release(previous) }
        prepared[request.sessionID] = Prepared(
            target: FFmpegArguments.Target(
                address: request.targetAddress, videoPort: request.video.port, videoSRTP: request.video.srtpKey + request.video.srtpSalt, videoSSRC: videoSSRC,
                audioPort: request.audio.port, audioSRTP: request.audio.srtpKey + request.audio.srtpSalt, audioSSRC: audioSSRC, isIPv6: family == .ipv6),
            videoReturnPort: videoReturnPort, audioReturnPort: audioReturnPort, preparedAt: .now)
        return PrepareStreamResponse(
            video: .init(port: videoReturnPort, ssrc: videoSSRC, srtpKey: request.video.srtpKey, srtpSalt: request.video.srtpSalt),
            audio: .init(port: audioReturnPort, ssrc: audioSSRC, srtpKey: request.audio.srtpKey, srtpSalt: request.audio.srtpSalt))
    }

    private func release(_ entry: Prepared) {
        ports.cancel(entry.videoReturnPort)
        ports.cancel(entry.audioReturnPort)
    }

    private func releaseStalePrepared() {
        let now = ContinuousClock.now
        for (id, entry) in prepared where now - entry.preparedAt > Self.preparedLifetime {
            prepared.removeValue(forKey: id)
            release(entry)
        }
    }

    // MARK: Start, reconfigure, stop

    func handleStreamRequest(_ request: StreamingRequest) async throws {
        switch request {
        case .start(let start):
            try await startStream(start)
        case .reconfigure:
            log.debug("Received request to reconfigure: ignored.")
        case .stop(let sessionID):
            stopStream(sessionID)
        }
    }

    private func startStream(_ request: StartStreamRequest) async throws {
        guard let entry = prepared.removeValue(forKey: request.sessionID) else {
            log.error("Error finding session information.")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        let values = FFmpegArguments.streamValues(video, request: request.video)
        log.debug("Video stream requested: \(request.video.width) x \(request.video.height), \(request.video.fps) fps, \(request.video.maxBitRate) kbps")
        func native(_ value: Int) -> String { value > 0 ? String(value) : "native" }
        log.info("Starting video stream: \(native(values.filters.width)) x \(native(values.filters.height)), \(native(values.fps)) fps, "
            + "\(values.bitrate > 0 ? String(values.bitrate) : "???") kbps\(video.audio ? " (\(request.audio.codec.rawValue))" : "")")
        let (arguments, unsupportedAudio) = FFmpegArguments.stream(video, values: values, request: request, target: entry.target)
        if unsupportedAudio { log.error("Unsupported audio codec requested: \(request.audio.codec.rawValue)") }

        nextToken += 1
        let token = nextToken
        let sessionID = request.sessionID
        let main = FfmpegProcess(tools.options, commandLineArgs: arguments)
        var session = Session(token: token, main: main, tasks: [], ports: [entry.videoReturnPort, entry.audioReturnPort])
        sessions[sessionID] = session

        let started = ContinuousClock.now
        main.start()
        watchExit(of: main, sessionID: sessionID, token: token, label: "")
        let sawFrame = NIOLockedValueBox(false)
        _ = main.onStdout { [log] chunk in
            guard !sawFrame.withLockedValue({ $0 }), let frame = Self.progressFrame(chunk), frame > 0 else { return }
            sawFrame.withLockedValue { $0 = true }
            logTiming(log, ContinuousClock.now - started, "Received first frame of stream")
        }

        if video.returnAudioTarget != nil {
            let returnAudio = FfmpegProcess(tools.returnOptions, commandLineArgs: FFmpegArguments.returnAudio(video))
            returnAudio.start()
            returnAudio.endStdin(Data(FFmpegArguments.returnAudioSDP(
                address: entry.target.address, isIPv6: entry.target.isIPv6, port: entry.audioReturnPort, srtp: entry.target.audioSRTP).utf8))
            watchExit(of: returnAudio, sessionID: sessionID, token: token, label: "Two-way ")
            session.returnAudio = returnAudio
        }

        do {
            let socket = try await UDPSocket.bind(host: entry.target.isIPv6 ? "::" : "0.0.0.0", port: entry.videoReturnPort, bufferSize: 16)
            session.socket = socket
            session.tasks.append(watchActivity(socket, timeout: FFmpegArguments.inactivityTimeout(rtcpInterval: request.video.rtcpInterval) * timeScale,
                                               sessionID: sessionID, token: token))
        } catch {
            log.error("Error on the stream's return socket: \(error)")
            sessions[sessionID] = session
            stopStream(sessionID)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        // A stop that came while the socket bound already removed the session.
        guard sessions[sessionID]?.token == token else {
            session.tasks.forEach { $0.cancel() }
            if let socket = session.socket { Task { await socket.close() } }
            session.returnAudio?.stop()
            return
        }
        sessions[sessionID] = session

        do {
            try await main.waitForStart()
        } catch {
            log.error("FFmpeg failed to start the stream: \(error)")
            stopStream(sessionID)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        sessions[sessionID]?.replied = true
    }

    /// The frame count of a `-progress` block, when the chunk is one.
    static func progressFrame(_ chunk: Data) -> Int? {
        let text = String(decoding: chunk, as: UTF8.self)
        guard text.hasPrefix("frame=") else { return nil }
        let line = text.dropFirst("frame=".count).prefix { $0 != "\n" && $0 != "\r" }
        return Int(line.trimmingCharacters(in: .whitespaces))
    }

    /// The return socket: each datagram (HomeKit's RTCP) puts off the inactivity timeout.
    private func watchActivity(_ socket: UDPSocket, timeout: Duration, sessionID: String, token: Int) -> Task<Void, Never> {
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

    private func inactive(sessionID: String, token: Int) {
        guard sessions[sessionID]?.token == token else { return }
        log.info("Device appears to be inactive. Stopping video stream.")
        controller?.forceStopStreamingSession(sessionID)
        stopStream(sessionID)
    }

    private func watchExit(of process: FfmpegProcess, sessionID: String, token: Int, label: String) {
        let watched = process.onceExit { [weak self] status in
            Task { await self?.exited(status, sessionID: sessionID, token: token, label: label) }
        }
        if !watched { log.error("\(label)FFmpeg ended at once.") }
    }

    /// An FFmpeg of a stream ended (section 7.5): an exit the plugin asked for is expected; a signal or 255 it did not cause
    /// is logged; any other exit ends the session.
    private func exited(_ status: FfmpegExitStatus, sessionID: String, token: Int, label: String) {
        guard let session = sessions[sessionID], session.token == token else {
            log.debug("\(label)FFmpeg exited (expected).")
            return
        }
        if status.exitCode == nil || status.exitCode == 255 {
            log.error("\(label)FFmpeg exited (unexpected), signal \(status.signal ?? "none").")
            return
        }
        log.error("\(label)FFmpeg exited with code \(status.exitCode ?? 0) and signal \(status.signal ?? "null").")
        stopStream(sessionID)
        if session.replied { controller?.forceStopStreamingSession(sessionID) }
    }

    /// Stops a stream (section 7.6): its timer and socket, its FFmpeg processes (`q`, then killed two seconds later).
    func stopStream(_ sessionID: String) {
        if let entry = prepared.removeValue(forKey: sessionID) { release(entry) }
        if let session = sessions.removeValue(forKey: sessionID) {
            session.tasks.forEach { $0.cancel() }
            if let socket = session.socket { Task { await socket.close() } }
            session.main.stop()
            session.returnAudio?.stop()
            for port in session.ports { ports.cancel(port) }
        }
        log.info("Stopped video stream.")
    }

    /// Stops every stream: the plugin is stopping.
    func stopAll() {
        for id in Array(sessions.keys) { stopStream(id) }
        for (_, entry) in prepared { release(entry) }
        prepared = [:]
        snapshot?.task.cancel()
    }
}
