import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A failure HomeKit hears about when it asks for a stream or a snapshot.
struct ProtectStreamError: Error, CustomStringConvertible {
    let description: String
}

/// FFmpeg's probe size for a camera (`ProbesizeTuner`): doubled, up to 5 MB, after FFmpeg failed to read the
/// livestream API's stream, for ten minutes, or for good after ten failures.
final class ProtectProbesizeTuner: Sendable {
    private struct State {
        var defaultProbesize: Int
        var override = 0
        var overrideCount = 0
        var generation = 0
    }

    /// The occasional failures of FFmpeg on the livestream API's fMP4.
    static let livestreamErrors = [
        "Cannot determine format of input stream 0:0 after EOF",
        "Finishing stream without any data written to it",
        "could not find corresponding trex",
        "moov atom not found",
    ]

    private let state: NIOLockedValueBox<State>
    private let log: ProtectLog
    private let timeScale: Double

    init(log: ProtectLog, defaultProbesize: Int, timeScale: Double = 1) {
        state = NIOLockedValueBox(State(defaultProbesize: defaultProbesize))
        self.log = log
        self.timeScale = timeScale
    }

    /// The message for a known failure of FFmpeg on the livestream API, which is logged instead of FFmpeg's.
    func errorCheck(_ stderr: [String], isApiLivestreaming: Bool) -> String? {
        guard isApiLivestreaming, stderr.contains(where: { line in Self.livestreamErrors.contains { line.contains($0) } }) else { return nil }
        return "FFmpeg ended unexpectedly due to issues processing the media stream provided by the UniFi Protect livestream API. "
            + "This error can be safely ignored - it will occur occasionally."
    }

    /// FFmpeg could not analyze the stream: a larger probe size for a while.
    func adjust() {
        let (count, generation) = state.withLockedValue { state -> (Int, Int) in
            state.generation += 1
            state.overrideCount += 1
            state.override = min((state.override == 0 ? state.defaultProbesize : state.override) * 2, ProtectSettings.ffmpegProbesizeMax)
            return (state.overrideCount, state.generation)
        }
        let permanent = count >= ProtectSettings.ffmpegProbesizeAdjustmentThreshold
        log.error("The FFmpeg process ended unexpectedly due to issues with the media stream provided by the UniFi Protect livestream API. "
            + "Adjusting the settings we use for FFmpeg \(permanent ? "permanently" : "temporarily") to use safer values at the expense of some additional streaming startup latency.")
        guard !permanent else { return }
        let delay = Duration.milliseconds(Int(Double(ProtectSettings.ffmpegProbesizeOverrideTimeout) * timeScale))
        Task { [state] in
            try? await Task.sleep(for: delay)
            state.withLockedValue { if $0.generation == generation { $0.override = 0 } }
        }
    }

    var probesize: Int {
        state.withLockedValue { $0.override != 0 ? $0.override : $0.defaultProbesize }
    }
}

/// What the FFmpeg streaming processes report back to (`HomebridgeStreamingDelegate`): the probe size, known
/// errors, and the end of a session, which goes to the streaming delegate on the plugin's actor.
final class ProtectStreamingHost: HomebridgeStreamingDelegate {
    let tuner: ProtectProbesizeTuner
    private let apiLivestreaming = NIOLockedValueBox(false)
    private let stop: @Sendable (String) -> Void
    private let forceStop: @Sendable (String) -> Void

    init(tuner: ProtectProbesizeTuner, stop: @escaping @Sendable (String) -> Void, forceStop: @escaping @Sendable (String) -> Void) {
        self.tuner = tuner
        self.stop = stop
        self.forceStop = forceStop
    }

    /// Whether live streams come from the livestream API (the timeshift buffer is running).
    var isApiLivestreaming: Bool {
        get { apiLivestreaming.withLockedValue { $0 } }
        set { apiLivestreaming.withLockedValue { $0 = newValue } }
    }

    func adjustProbeSize() { tuner.adjust() }
    func ffmpegErrorCheck(_ stderr: [String]) -> String? { tuner.errorCheck(stderr, isApiLivestreaming: isApiLivestreaming) }
    func stopStream(_ sessionID: String) { stop(sessionID) }
    func forceStopStreamingSession(_ sessionID: String) { forceStop(sessionID) }
}

/// A camera's streaming delegate (`ProtectStreamingDelegate`): the camera controller HomeKit talks to, live
/// streams through FFmpeg from RTSP or the timeshift buffer, two-way audio, snapshots and HKSV.
@ProtectActor
final class ProtectStreamingDelegate: CameraStreamingDelegate {
    /// What a prepared session needs to start (`SessionInfo`).
    struct SessionInfo {
        var address: String
        var addressVersion: IPAddressVersion
        var audioIncomingRtcpPort: Int
        var audioIncomingRtpPort: Int
        var audioPort: Int
        var audioSRTP: Data
        var audioSSRC: UInt32
        var hasAudioSupport: Bool
        var rtpDemuxer: (any ProtectRtpDemuxer)?
        var rtpPortReservations: [Int]
        var talkBack: String?
        var videoPort: Int
        var videoReturnPort: Int
        var videoSRTP: Data
        var videoSSRC: UInt32
    }

    /// How a stream request is answered (`StreamPlan`).
    struct StreamPlan: Equatable {
        var isHighLatency: Bool
        var isTranscoding: Bool
        var rtspEntry: RtspEntry
        var targetBitrate: Int
        var useTsb: Bool
    }

    private struct WeakDelegate: Sendable {
        weak var value: ProtectStreamingDelegate?
    }

    /// The state of feeding one stream from the livestream API.
    private final class FeedState {
        var seenInitSegment = false
        var fetchingInit = false
        var waiting: [Data] = []
    }

    private struct OngoingSession {
        var ffmpeg: [any ProtectFfmpegProcess]
        var rtpDemuxer: (any ProtectRtpDemuxer)?
        var rtpPortReservations: [Int]
        var toggleLight: Service?
    }

    let camera: ProtectCamera
    let ffmpeg: any ProtectFfmpegKit
    let ffmpegOptions: any ProtectFfmpegOptions
    private(set) var hksv: ProtectRecordingDelegate?
    private(set) var controller: CameraController?
    private var ongoingSessions: [String: OngoingSession] = [:]
    private var pendingSessions: [String: SessionInfo] = [:]
    private let host: ProtectStreamingHost
    private var snapshot: ProtectSnapshot!
    private var talkback: ProtectTalkback!
    private var abTest = false
    var verboseFfmpeg = false

    init(camera: ProtectCamera, resolutions: [VideoResolution], ffmpeg: any ProtectFfmpegKit) {
        self.camera = camera
        self.ffmpeg = ffmpeg
        let name = camera.accessoryName
        ffmpegOptions = ffmpeg.makeOptions(name: { name }, crop: camera.hints.crop ? camera.hints.cropOptions : nil, debug: camera.platform.configuration.debug,
                                               hardwareDecoding: camera.hints.hardwareDecoding, hardwareTranscoding: camera.hints.hardwareTranscoding,
                                               log: camera.log.logger)
        let tuner = ProtectProbesizeTuner(log: camera.log, defaultProbesize: camera.hints.probesize, timeScale: camera.platform.dependencies.timeScale)
        let stopper = NIOLockedValueBox(WeakDelegate())
        host = ProtectStreamingHost(tuner: tuner, stop: { [stopper] sessionID in
            let delegate = stopper.withLockedValue { $0.value }
            Task { @ProtectActor in delegate?.stopStream(sessionID) }
        }, forceStop: { [stopper] sessionID in
            let delegate = stopper.withLockedValue { $0.value }
            Task { @ProtectActor in delegate?.controller?.forceStopStreamingSession(sessionID) }
        })
        // Hardware acceleration makes a difference on a Mac.
        if !camera.hints.hardwareTranscoding, camera.context.packageCamera == nil, ffmpeg.hostSystem.hasPrefix("macOS.") {
            camera.log.warning("macOS detected: consider enabling hardware acceleration (located under the video feature options section in the HBUP webUI) "
                + "for even better performance and an improved user experience.")
        }
        if camera.isHksvCapable {
            hksv = ProtectRecordingDelegate(camera: camera, ffmpeg: ffmpeg, options: ffmpegOptions)
        }
        snapshot = ProtectSnapshot(camera: camera, stream: self, ffmpeg: ffmpeg, options: ffmpegOptions)
        talkback = ProtectTalkback(camera: camera, ffmpeg: ffmpeg, options: ffmpegOptions)
        stopper.withLockedValue { $0.value = self }
        do {
            let controller = try CameraController(Self.controllerOptions(camera: camera, resolutions: resolutions, streaming: self, recording: hksv),
                                                  logger: camera.platform.log.logger)
            // The saved Active and recording settings, as Homebridge's `configureController` restores them.
            camera.accessory.configureControllerState(controller)
            self.controller = controller
            camera.accessory.cameraController = controller
            hksv?.recordingAudioActive = { [weak controller] in
                let management = controller?.services.first { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid }
                return management?[.recordingAudioActive]?.value.intValue == 1
            }
        } catch {
            camera.log.error("Unable to configure the camera for HomeKit: \(error).")
        }
    }

    /// The controller's options (the Homebridge plugin's `CameraControllerOptions`): ten streams, H.264 Main at
    /// levels 3.1 to 4.0, AAC-ELD at 16 and 24 kHz for live streams (16 kHz alone from the livestream API, except
    /// doorbells), and HKSV with AAC-LC at the camera's rate (48 kHz for doorbells) and the plugin's motion sensor.
    static func controllerOptions(camera: ProtectCamera, resolutions: [VideoResolution], streaming: any CameraStreamingDelegate,
                                  recording: ProtectRecordingDelegate?) -> CameraControllerOptions {
        let isDoorbell = camera.ufp.feature("isDoorbell")
        let codec = H264CodecParameters(profiles: [.main], levels: [.level3_1, .level3_2, .level4_0])
        let streamingOptions = CameraStreamingOptions(
            supportedCryptoSuites: [.aesCM128HMACSHA1_80],
            video: VideoStreamingOptions(codec: codec, resolutions: resolutions),
            audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, audioChannels: 1, bitrate: .variable,
                                                                      samplerate: isDoorbell || !camera.hints.tsbStreaming ? [.khz16, .khz24] : [.khz16])],
                                         twoWayAudio: camera.hints.twoWayAudio))
        var recordingSetup: CameraRecordingSetup?
        var sensors: CameraSensorOptions?
        if camera.isHksvCapable, let recording {
            recordingSetup = CameraRecordingSetup(
                options: CameraRecordingOptions(
                    prebufferLength: ProtectSettings.hksvTimeshiftBufferMaxDuration,
                    mediaContainerConfiguration: [MediaContainerConfiguration(type: .fragmentedMP4, fragmentLength: 4000)],
                    video: VideoRecordingOptions(type: .h264, parameters: codec, resolutions: resolutions),
                    audio: [AudioRecordingCodec(type: .aacLC, samplerate: [isDoorbell ? .khz48 : .khz16])]),
                delegate: RecordingBridge(recording))
            sensors = camera.accessory.firstService(.motionSensor).map { CameraSensorOptions(motion: .service($0)) }
        }
        return CameraControllerOptions(cameraStreamCount: 10, delegate: streaming, streamingOptions: streamingOptions, recording: recordingSetup, sensors: sensors)
    }

    private var log: ProtectLog { camera.log }

    // MARK: What the device code needs

    /// Whether HomeKit Secure Video is recording events (the Home app's recording mode).
    var isRecording: Bool { hksv?.isRecording ?? false }
    /// Turns HKSV event recording off, when the camera leaves.
    func updateRecordingActive(_ active: Bool) async { await hksv?.updateRecordingActive(active) }
    /// The largest number of pixels the host can transcode, on constrained hardware.
    var hostSystemMaxPixels: Int? { ffmpegOptions.hostSystemMaxPixels }
    /// `raspbian`, `macOS.Apple`, … as the FFmpeg probe found it.
    var hostSystem: String { ffmpeg.hostSystem }
    var probesize: Int { host.tuner.probesize }

    func removeController() {
        controller?.destroy()
        controller = nil
        camera.accessory.cameraController = nil
    }

    // MARK: Snapshots

    /// Makes a snapshot now (MQTT `snapshot/set`).
    func handleSnapshotRequest() async {
        _ = try? await snapshot(nil)
    }

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        try await snapshot(request)
    }

    private func snapshot(_ request: SnapshotRequest?) async throws -> Data {
        guard let image = await snapshot.getSnapshot(request) else {
            throw ProtectStreamError(description: camera.accessoryName + ": Unable to retrieve a snapshot")
        }
        camera.nvr.mqtt?.publish(camera.ufp.mac, "snapshot", "data:image/jpeg;base64," + image.base64EncodedString())
        return image
    }

    // MARK: Streams

    /// Reserves the ports of a session and tells HomeKit where to send.
    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        var reservePortFailed = false
        var reservations: [Int] = []
        let ffmpeg = self.ffmpeg
        let ipv6 = request.addressVersion == .ipv6
        func reservePort(_ count: Int = 1) async -> Int {
            if reservePortFailed { return -1 }
            let port = await ffmpeg.reservePort(ipv6: ipv6, count: count)
            if port == -1 {
                reservePortFailed = true
            } else {
                reservations.append(port)
                if count == 2 { reservations.append(port + 1) }
            }
            return port
        }
        let isAudioEnabled = camera.ufp.feature("hasMic") && camera.hasFeature("Audio")
        let hasAudioSupport = isAudioEnabled && !ffmpegOptions.audioEncoder().isEmpty
        let twoWay = hasAudioSupport && camera.hints.twoWayAudio
        let audioIncomingRtcpPort = await reservePort()
        let audioIncomingPort = twoWay ? await reservePort() : -1
        let audioIncomingRtpPort = twoWay ? await reservePort(2) : -1
        let audioSSRC = Self.synchronisationSource()
        if !hasAudioSupport {
            log.info("Audio support disabled.\(isAudioEnabled ? " A version of FFmpeg that is compiled with fdk_aac support is required to support audio." : "")")
        }
        var rtpDemuxer: (any ProtectRtpDemuxer)?
        var talkBack: String?
        if twoWay {
            rtpDemuxer = await ffmpeg.makeRtpDemuxer(ipv6: ipv6, inputPort: audioIncomingPort, rtcpPort: audioIncomingRtcpPort, rtpPort: audioIncomingRtpPort,
                                                     log: log.logger)
            talkBack = await camera.api.getWsEndpoint("talkback", parameters: [("camera", camera.ufp.id)])
            if talkBack == nil { log.error("Unable to open the return audio channel.") }
        }
        let videoReturnPort = await reservePort()
        let videoSSRC = Self.synchronisationSource()
        if reservePortFailed { log.error("Unable to reserve the UDP ports needed to begin streaming.") }
        pendingSessions[request.sessionID] = SessionInfo(
            address: request.targetAddress, addressVersion: request.addressVersion, audioIncomingRtcpPort: audioIncomingRtcpPort,
            audioIncomingRtpPort: audioIncomingRtpPort, audioPort: request.audio.port, audioSRTP: request.audio.srtpKey + request.audio.srtpSalt,
            audioSSRC: audioSSRC, hasAudioSupport: hasAudioSupport, rtpDemuxer: rtpDemuxer, rtpPortReservations: reservations, talkBack: talkBack,
            videoPort: request.video.port, videoReturnPort: videoReturnPort, videoSRTP: request.video.srtpKey + request.video.srtpSalt, videoSSRC: videoSSRC)
        // Two-way audio goes through the demuxer, which separates RTP from RTCP.
        return PrepareStreamResponse(
            video: .init(port: videoReturnPort, ssrc: videoSSRC, srtpKey: request.video.srtpKey, srtpSalt: request.video.srtpSalt),
            audio: .init(port: twoWay ? audioIncomingPort : audioIncomingRtcpPort, ssrc: audioSSRC, srtpKey: request.audio.srtpKey, srtpSalt: request.audio.srtpSalt))
    }

    /// `CameraController.generateSynchronisationSource()`: a random 32-bit SSRC.
    nonisolated static func synchronisationSource() -> UInt32 { UInt32.random(in: 0...UInt32.max) }

    func handleStreamRequest(_ request: StreamingRequest) async throws {
        switch request {
        case .start(let start):
            try await startStream(start)
        case .reconfigure(let reconfigure):
            let video = reconfigure.video
            log.debug("Streaming parameters adjustment requested by HomeKit: \(video.width)x\(video.height), \(video.fps) fps, \(formatBps(Double(video.maxBitRate))).")
        case .stop(let sessionID):
            stopStream(sessionID)
        }
    }

    private func startStream(_ request: StartStreamRequest) async throws {
        guard let session = pendingSessions[request.sessionID] else {
            throw ProtectStreamError(description: camera.accessoryName + ": Unable to start a stream for a session that was never prepared.")
        }
        let plan = try planStream(request)
        let flashlight = activatePackageFlashlight()
        // The timeshift buffer gives FFmpeg the last seconds at once: it starts without waiting to analyze.
        let tsBuffer = plan.useTsb ? hksv?.timeshift.getLast(ProtectSettings.livestreamAPIIDRInterval * 1000) : nil
        let arguments = buildStreamArguments(request, session: session, plan: plan)
        host.isApiLivestreaming = camera.hints.tsbStreaming && isRecording
        let twoWay = session.hasAudioSupport && camera.hints.twoWayAudio
        let ffmpeg = self.ffmpeg.startStreaming(delegate: host, sessionID: request.sessionID, options: ffmpegOptions, arguments: arguments,
                                                returnPort: twoWay ? nil : FfmpegReturnPort(addressVersion: session.addressVersion, port: session.videoReturnPort))
        if plan.useTsb {
            guard await feedFromLivestream(ffmpeg, entry: plan.rtspEntry, tsBuffer: tsBuffer) else {
                ffmpeg.stop()
                throw ProtectStreamError(description: camera.accessoryName + ": Unable to access the Protect livestream API.")
            }
        }
        ongoingSessions[request.sessionID] = OngoingSession(ffmpeg: [ffmpeg], rtpDemuxer: session.rtpDemuxer,
                                                            rtpPortReservations: session.rtpPortReservations, toggleLight: flashlight)
        pendingSessions[request.sessionID] = nil
        if twoWay {
            let sessionID = request.sessionID
            let talkbackSession = ProtectTalkback.Session(address: session.address, audioIncomingRtpPort: session.audioIncomingRtpPort,
                                                          audioSRTP: session.audioSRTP, rtpDemuxer: session.rtpDemuxer, talkBack: session.talkBack)
            let host = self.host
            let talkback = self.talkback!
            Task { @ProtectActor [weak self] in
                await talkback.start(request, session: talkbackSession, sdpIpVersion: session.addressVersion == .ipv6 ? "IP6" : "IP4", host: host) { [weak self] process in
                    self?.ongoingSessions[sessionID]?.ffmpeg.append(process)
                }
            }
        }
        try await ffmpeg.waitForStart()
    }

    /// Feeds FFmpeg from the livestream API: the initialization segment (or the timeshift buffer), then each
    /// segment as it arrives. False when the livestream does not start.
    private func feedFromLivestream(_ ffmpeg: any ProtectFfmpegStreamingProcess, entry: RtspEntry, tsBuffer: Data?) async -> Bool {
        guard let livestream = camera.livestream.acquire(entry) else { return false }
        let queue = ProtectSegmentQueue(process: { ffmpeg })
        let state = FeedState()
        let log = self.log
        let listener = ProtectLivestreamListener(livestream) { event in
            switch event {
            case .segment(let segment):
                if state.seenInitSegment {
                    queue.push(segment)
                    return
                }
                state.waiting.append(segment)
                guard !state.fetchingInit else { return }
                state.fetchingInit = true
                Task { @ProtectActor in
                    var initSegment = tsBuffer
                    if initSegment == nil {
                        do {
                            initSegment = try await livestream.getInitSegment()
                        } catch {
                            log.debug("Unable to retrieve the livestream initialization segment: \(error)")
                        }
                    }
                    guard let initSegment else {
                        log.error("Unable to retrieve the fMP4 initialization segment for this streaming session.")
                        ffmpeg.endStdin(nil)
                        return
                    }
                    queue.push(initSegment)
                    state.seenInitSegment = true
                    for segment in state.waiting { queue.push(segment) }
                    state.waiting = []
                }
            case .close:
                ffmpeg.endStdin(nil)
            default:
                break
            }
        }
        let manager = camera.livestream
        ffmpeg.onExit {
            Task { @ProtectActor in
                manager.stop(entry)
                listener.cancel()
            }
        }
        guard await manager.start(entry) else {
            listener.cancel()
            return false
        }
        return true
    }

    /// How to answer a request: transcoding or not, the livestream API or RTSP, which stream, what bit rate.
    func planStream(_ request: StartStreamRequest) throws -> StreamPlan {
        guard camera.isOnline else {
            let message = "Unable to start video stream: the camera is offline or unavailable."
            log.error(message)
            throw ProtectStreamError(description: camera.accessoryName + ": " + message)
        }
        let hints = camera.hints
        let codec = camera.ufp.videoCodec
        // HomeKit asks for 60 ms audio packets on cellular connections.
        let isHighLatency = request.audio.packetTime >= 60
        let isTranscoding = hints.transcode || hints.crop || (isHighLatency && hints.transcodeHighLatency) || codec != "h264"
        var targetBitrate = request.video.maxBitRate
        // The livestream API only with a running timeshift buffer; RTSP otherwise.
        var useTsb = hints.tsbStreaming && isRecording
        if abTest, camera.hasFeature("Debug.Video.Stream.ABTest") { useTsb = !useTsb }
        abTest.toggle()
        // FFmpeg does not read AV1 over RTSP.
        if codec == "av1", !useTsb {
            guard isRecording else {
                let message = "Unable to start video stream: FFmpeg does not currently support AV1-encoded RTSP streams. "
                    + "Enable HKSV in the Home app and ensure API-based livestreaming is enabled in HBUP (enabled by default)."
                log.error(message)
                throw ProtectStreamError(description: camera.accessoryName + ": " + message)
            }
            useTsb = true
        }
        if camera.context.packageCamera != nil, !useTsb, isRecording { useTsb = true }
        var rtspEntry = useTsb ? hksv?.rtspEntry : nil
        if isTranscoding {
            // A source above the request, but at most twice its size: transcoders do better with more, not with 4K.
            let maxWidth = request.video.width * ProtectSettings.transcodeMaxDownscaleRatio
            let maxHeight = request.video.height * ProtectSettings.transcodeMaxDownscaleRatio
            let maxPixels = min(ffmpegOptions.hostSystemMaxPixels, maxWidth * maxHeight)
            rtspEntry = rtspEntry ?? camera.findRtsp(width: request.video.width, height: request.video.height, biasHigher: true, maxPixels: maxPixels)
            if isHighLatency, hints.transcodeHighLatencyBitrate > 0 {
                targetBitrate = hints.transcodeHighLatencyBitrate
            } else if !isHighLatency, hints.transcodeBitrate > 0 {
                targetBitrate = hints.transcodeBitrate
            }
            if let entry = rtspEntry, Double(targetBitrate) > Double(entry.channel.bitrate) / 1000 {
                targetBitrate = entry.channel.bitrate / 1000
            }
        } else {
            rtspEntry = rtspEntry ?? camera.findRtsp(width: request.video.width, height: request.video.height)
        }
        guard let rtspEntry else {
            let message = "Unable to start video stream: no valid RTSP stream profile was found."
            log.error("\(message) \(request.video.width)x\(request.video.height), \(request.video.fps) fps, \(Self.grouped(request.video.maxBitRate)) kbps.")
            throw ProtectStreamError(description: camera.accessoryName + ": " + message)
        }
        return StreamPlan(isHighLatency: isHighLatency, isTranscoding: isTranscoding, rtspEntry: rtspEntry, targetBitrate: targetBitrate, useTsb: useTsb)
    }

    /// `toLocaleString('en-US')`.
    nonisolated static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: ",")
    }

    /// The package camera's flashlight, turned on for a stream in the dark unless it is on already. Returned
    /// so the end of the session turns it off.
    private func activatePackageFlashlight() -> Service? {
        guard camera.context.packageCamera != nil,
              let service = camera.accessory.service(.lightbulb, subtype: ProtectReservedNames.lightbulbPackageFlashlight),
              camera.ufp.json.bool("isDark"), service[.on]?.value.boolValue != true else { return nil }
        Task { try? await service[.on]?.write(.bool(true)) }
        return service
    }

    /// The whole command line: video, audio when there is support for it, and logging.
    func buildStreamArguments(_ request: StartStreamRequest, session: SessionInfo, plan: StreamPlan) -> [String] {
        var arguments = buildVideoArguments(request, session: session, plan: plan)
        if session.hasAudioSupport { arguments += buildAudioArguments(request, session: session, useTsb: plan.useTsb) }
        if camera.platform.verboseFfmpeg || verboseFfmpeg || camera.hasFeature("Debug.Video.FFmpeg") { arguments += ["-loglevel", "level+verbose"] }
        if camera.platform.configuration.debug { arguments += ["-loglevel", "level+debug"] }
        return arguments
    }

    private func buildVideoArguments(_ request: StartStreamRequest, session: SessionInfo, plan: StreamPlan) -> [String] {
        let entry = plan.rtspEntry
        var arguments = ["-hide_banner", "-nostats", "-fflags", "+discardcorrupt", "-err_detect", "ignore_err"] + ffmpegOptions.videoDecoder(camera.ufp.videoCodec)
            + ["-max_delay", "500000", "-flags", "low_delay", "-probesize", String(probesize)]
        if plan.useTsb {
            arguments += ["-f", "mp4", "-i", "pipe:0"]
        } else {
            arguments += ["-avioflags", "direct", "-rtsp_transport", "tcp", "-i", entry.url]
        }
        arguments += ["-map", "0:v:0"]
        // Hardware acceleration, transcoding, a high-latency client, noise filtering.
        var hinting: [String] = []
        if plan.isTranscoding, camera.hints.hardwareTranscoding { hinting.append("\u{26A1}\u{FE0F}") }
        if plan.isTranscoding { hinting.append("\u{26ED}\u{FE0E}") }
        if request.audio.packetTime == 60 { hinting.append("\u{29D6}\u{FE0E}") }
        if session.hasAudioSupport, camera.hasFeature("Audio.Filter.Noise") { hinting.append("\u{1F50A}\u{FE0E}") }
        if !hinting.isEmpty { hinting.append("") }
        log.info("\(hinting.joined(separator: " "))Streaming request: \(request.video.width)x\(request.video.height)@\(request.video.fps)fps, "
            + "\(formatBps(Double(plan.targetBitrate) * 1000)). Using \(entry.name), \(formatBps(Double(entry.channel.bitrate))) [\(plan.useTsb ? "TSB/API" : "RTSP")].")
        // Motion interpolation where it runs in real time: Apple Silicon from M3, from the timeshift buffer.
        let useInterpolation = plan.useTsb && camera.context.packageCamera == nil && ffmpeg.hostSystem == "macOS.Apple" && ffmpeg.cpuGeneration >= 3
        if plan.isTranscoding {
            arguments += ffmpegOptions.streamEncoder(VideoEncoderOptions(
                bitrate: plan.targetBitrate, fps: useInterpolation ? entry.channel.fps : request.video.fps, height: request.video.height,
                idrInterval: 5, inputFps: entry.channel.fps, level: H264Level(rawValue: request.video.level) ?? .level3_1,
                profile: H264Profile(rawValue: request.video.profile) ?? .main, width: request.video.width))
            if useInterpolation {
                let fps = String(request.video.fps)
                let minterpolate = (camera.hints.hardwareTranscoding && ffmpeg.ffmpegVersion.hasPrefix("8.") ? "hwdownload, format=nv12, " : "")
                    + "fps=" + fps + ", minterpolate=fps=" + fps + ":mi_mode=mci:mc_mode=aobmc:me=fss:me_mode=bidir:vsbmc=1:scd=none"
                if let filter = arguments.firstIndex(of: "-filter:v"), filter + 1 < arguments.count {
                    arguments[filter + 1] += ", " + minterpolate
                } else {
                    arguments += ["-filter:v", minterpolate]
                }
            }
        } else {
            arguments += ["-codec:v", "copy"]
            if plan.useTsb { arguments += ["-bsf:v", "h264_mp4toannexb"] }
        }
        arguments += ["-metadata", "comment=" + camera.accessoryName + " Livestream"]
        arguments += ["-payload_type", String(request.video.pt), "-ssrc", String(session.videoSSRC), "-f", "rtp", "-flush_packets", "1", "-packetsize", "1200",
                      "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", session.videoSRTP.base64EncodedString(),
                      "srtp://" + session.address + ":" + String(session.videoPort) + "?rtcpport=" + String(session.videoPort)]
        return arguments
    }

    private func buildAudioArguments(_ request: StartStreamRequest, session: SessionInfo, useTsb: Bool) -> [String] {
        // The RTSP stream's Opus track sounds better; the livestream API has AAC only.
        var arguments = ["-map", useTsb ? "0:a:0?" : "0:a:1?"] + ffmpegOptions.audioEncoder()
            + ["-flags", "+global_header", "-profile:a", "38", "-ar", String(request.audio.sampleRate) + "k", "-b:a", String(request.audio.maxBitRate) + "k",
               "-ac", String(request.audio.channel)]
        let filters = camera.audioFilters
        if !filters.isEmpty { arguments += ["-filter:a", filters.joined(separator: ", ")] }
        arguments += ["-payload_type", String(request.audio.pt), "-ssrc", String(session.audioSSRC), "-f", "rtp", "-flush_packets", "1", "-packetsize", "384",
                      "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", session.audioSRTP.base64EncodedString(),
                      "srtp://" + session.address + ":" + String(session.audioPort) + "?rtcpport=" + String(session.audioPort)]
        return arguments
    }

    /// Ends a session: its FFmpeg processes, the demuxer, the flashlight, the ports.
    func stopStream(_ sessionID: String) {
        if let session = ongoingSessions[sessionID] {
            for process in session.ffmpeg { process.stop() }
            session.rtpDemuxer?.close()
            if let light = session.toggleLight { Task { try? await light[.on]?.write(.bool(false)) } }
            log.info("Stopped video streaming session.")
            for port in session.rtpPortReservations { ffmpeg.cancelPort(port) }
        }
        if let pending = pendingSessions[sessionID] {
            for port in pending.rtpPortReservations { ffmpeg.cancelPort(port) }
        }
        pendingSessions[sessionID] = nil
        ongoingSessions[sessionID] = nil
    }

    /// Stops every FFmpeg process and livestream of the camera.
    func shutdown() {
        for sessionID in ongoingSessions.keys { stopStream(sessionID) }
    }
}
