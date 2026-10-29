import Foundation
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

// MARK: FFmpeg in memory

final class FakeFfmpegOptions: ProtectFfmpegOptions, @unchecked Sendable {
    let audioDecoder = "libfdk_aac"
    let cropFilter = "crop=w=iw*1:h=ih*1:x=iw*0:y=ih*0"
    let hostSystemMaxPixels: Int
    let decoder: [String]
    /// false: an FFmpeg without libfdk_aac, with libopus (ffmpeg-for-homeswift).
    let hasFdk: Bool

    init(hostSystemMaxPixels: Int = 3840 * 2160, decoder: [String] = [], hasFdk: Bool = true) {
        self.hostSystemMaxPixels = hostSystemMaxPixels
        self.decoder = decoder
        self.hasFdk = hasFdk
    }

    func audioEncoder() -> [String] { hasFdk ? ["-codec:a", "libfdk_aac", "-afterburner", "1"] : [] }
    var hasOpusEncoder: Bool { !hasFdk }
    func opusEncoder(packetTime: Int) -> [String] { ["-codec:a", "libopus", "-frame_duration", String(packetTime)] }
    func videoDecoder(_ codec: String) -> [String] { decoder }
    func streamEncoder(_ options: VideoEncoderOptions) -> [String] {
        ["-codec:v", "libx264", "-filter:v", "scale=\(options.width):\(options.height)", "-b:v", "\(options.bitrate)k", "-r", "\(options.fps)"]
    }
}

/// An FFmpeg process that records what goes in and lets the test end it.
final class FakeProcess: ProtectFfmpegStreamingProcess, ProtectFfmpegRecording, @unchecked Sendable {
    struct State {
        var stdin: [Data] = []
        var stdinEnded = false
        var stopped = false
        var exited = false
        var stdoutHandlers: [@Sendable (Data) -> Void] = []
        var exitHandlers: [@Sendable () -> Void] = []
    }

    let arguments: [String]
    let state = NIOLockedValueBox(State())
    private let fragments: AsyncStream<Data>
    private let fragmentContinuation: AsyncStream<Data>.Continuation

    init(arguments: [String]) {
        self.arguments = arguments
        (fragments, fragmentContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    var stdin: [Data] { state.withLockedValue { $0.stdin } }
    var written: Data { stdin.reduce(Data(), +) }
    var isStopped: Bool { state.withLockedValue { $0.stopped } }

    func argument(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    func stop() {
        state.withLockedValue { $0.stopped = true }
        exit()
    }

    func stop(logErrors: Bool) { stop() }

    func exit() {
        let handlers = state.withLockedValue { state -> [@Sendable () -> Void] in
            guard !state.exited else { return [] }
            state.exited = true
            return state.exitHandlers
        }
        fragmentContinuation.finish()
        handlers.forEach { $0() }
    }

    func writeStdin(_ data: Data) async throws { state.withLockedValue { $0.stdin.append(data) } }
    func endStdin(_ data: Data?) {
        state.withLockedValue { state in
            if let data { state.stdin.append(data) }
            state.stdinEnded = true
        }
    }

    var isStdinWritable: Bool { state.withLockedValue { !$0.stopped && !$0.stdinEnded } }
    func onStdout(_ handler: @escaping @Sendable (Data) -> Void) -> FfmpegProcess.StdoutListener? {
        state.withLockedValue { $0.stdoutHandlers.append(handler) }
        return nil
    }
    func output(_ data: Data) { state.withLockedValue { $0.stdoutHandlers }.forEach { $0(data) } }

    func onExit(_ handler: @escaping @Sendable () -> Void) {
        let exited = state.withLockedValue { state -> Bool in
            if !state.exited { state.exitHandlers.append(handler) }
            return state.exited
        }
        if exited { handler() }
    }

    func waitForStart() async throws {}
    func segments() -> AsyncStream<Data> { fragments }
    func fragment(_ data: Data) { fragmentContinuation.yield(data) }
    let isTimedOut = false
}

/// FFmpeg on a camera's RTSP stream (`Debug.Video.HKSV.UseRtsp`): the test writes its initialization segment and boxes.
final class FakeLivestream: ProtectFfmpegLivestream, @unchecked Sendable {
    struct State {
        var segmentLength: Int?
        var starts: [Int?] = []
        var stops = 0
        var running = false
        var initSegment: Data?
        /// Written as soon as FFmpeg starts, when set.
        var initOnStart: Data?
        var initWaiters: [CheckedContinuation<Data, any Error>] = []
        var segmentHandlers: [@Sendable (Data) -> Void] = []
        var exitHandlers: [@Sendable () -> Void] = []
    }

    let options: FMp4LivestreamOptions
    let state = NIOLockedValueBox(State())

    init(options: FMp4LivestreamOptions) {
        self.options = options
    }

    var segmentLength: Int? {
        get { state.withLockedValue { $0.segmentLength } }
        set { state.withLockedValue { $0.segmentLength = newValue } }
    }

    var starts: [Int?] { state.withLockedValue { $0.starts } }
    var isRunning: Bool { state.withLockedValue { $0.running } }

    func startLivestream() {
        state.withLockedValue { state in
            state.starts.append(state.segmentLength)
            state.running = true
            state.initSegment = state.initOnStart
        }
    }

    func stop() { exit() }

    /// FFmpeg ends: waiters fail, exit handlers run.
    func exit() {
        let (waiters, handlers) = state.withLockedValue { state -> ([CheckedContinuation<Data, any Error>], [@Sendable () -> Void]) in
            guard state.running else { return ([], []) }
            state.running = false
            state.stops += 1
            defer { state.initWaiters = []; state.exitHandlers = [] }
            return (state.initWaiters, state.exitHandlers)
        }
        waiters.forEach { $0.resume(throwing: FfmpegLivestreamError.aborted) }
        handlers.forEach { $0() }
    }

    func onSegment(_ handler: @escaping @Sendable (Data) -> Void) { state.withLockedValue { $0.segmentHandlers.append(handler) } }

    func onExit(_ handler: @escaping @Sendable () -> Void) {
        let running = state.withLockedValue { state -> Bool in
            if state.running { state.exitHandlers.append(handler) }
            return state.running
        }
        if !running { handler() }
    }

    func getInitSegment() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLockedValue { state -> Result<Data, any Error>? in
                if let segment = state.initSegment { return .success(segment) }
                guard state.running else { return .failure(FfmpegLivestreamError.noActiveProcess) }
                state.initWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    /// FFmpeg writes its ftyp and moov.
    func writeInit(_ segment: Data) {
        let waiters = state.withLockedValue { state in
            state.initSegment = segment
            defer { state.initWaiters = [] }
            return state.initWaiters
        }
        waiters.forEach { $0.resume(returning: segment) }
    }

    /// FFmpeg writes a box of this type: a 32-bit size, the type, the payload.
    func writeBox(_ type: String, _ payload: Data) {
        let box = Self.box(type, payload)
        state.withLockedValue { $0.segmentHandlers }.forEach { $0(box) }
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var box = Data()
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { box.append(contentsOf: $0) }
        return box + Data(type.utf8) + payload
    }
}

final class FakeDemuxer: ProtectRtpDemuxer, @unchecked Sendable {
    let closed = NIOLockedValueBox(false)
    func firstPacket() async {}
    var isRunning: Bool { !closed.withLockedValue { $0 } }
    func close() { closed.withLockedValue { $0 = true } }
}

final class FakeFfmpegKit: ProtectFfmpegKit, @unchecked Sendable {
    struct State {
        var nextPort = 50000
        var cancelled: [Int] = []
        var streams: [FakeProcess] = []
        var recordings: [(process: FakeProcess, options: FMp4RecordingOptions)] = []
        var execs: [(arguments: [String], stdin: Data?)] = []
        var execResult: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0])
        var demuxers: [FakeDemuxer] = []
        var processes: [FakeProcess] = []
        var livestreams: [FakeLivestream] = []
        /// The initialization segment the RTSP livestreams write as they start.
        var livestreamInit: Data?
        var probes = 0
    }

    let state = NIOLockedValueBox(State())
    let hostSystem: String
    let cpuGeneration = 0
    let ffmpegVersion = "7.1"
    let options: FakeFfmpegOptions
    let works: Bool

    init(hostSystem: String = "macOS.Apple", options: FakeFfmpegOptions = FakeFfmpegOptions(), works: Bool = true) {
        self.hostSystem = hostSystem
        self.options = options
        self.works = works
    }

    var streams: [FakeProcess] { state.withLockedValue { $0.streams } }
    var processes: [FakeProcess] { state.withLockedValue { $0.processes } }
    var execs: [(arguments: [String], stdin: Data?)] { state.withLockedValue { $0.execs } }

    func probe() async -> Bool {
        state.withLockedValue { $0.probes += 1 }
        return works
    }

    func makeOptions(name: @escaping @Sendable () -> String, crop: (height: Double, width: Double, x: Double, y: Double)?, debug: Bool,
                     hardwareDecoding: Bool, hardwareTranscoding: Bool, log: Logger) -> any ProtectFfmpegOptions { options }

    func reservePort(ipv6: Bool, count: Int) async -> Int {
        state.withLockedValue { state in
            defer { state.nextPort += count }
            return state.nextPort
        }
    }

    func cancelPort(_ port: Int) { state.withLockedValue { $0.cancelled.append(port) } }

    func makeRtpDemuxer(ipv6: Bool, inputPort: Int, rtcpPort: Int, rtpPort: Int, log: Logger) async -> any ProtectRtpDemuxer {
        let demuxer = FakeDemuxer()
        state.withLockedValue { $0.demuxers.append(demuxer) }
        return demuxer
    }

    func startStreaming(delegate: any HomebridgeStreamingDelegate, sessionID: String, options: any ProtectFfmpegOptions, arguments: [String],
                        returnPort: FfmpegReturnPort?) -> any ProtectFfmpegStreamingProcess {
        let process = FakeProcess(arguments: arguments)
        state.withLockedValue { $0.streams.append(process) }
        return process
    }

    func startRecording(options: any ProtectFfmpegOptions, configuration: CameraRecordingConfiguration, fMp4Options: FMp4RecordingOptions,
                        verbose: Bool) -> any ProtectFfmpegRecording {
        let process = FakeProcess(arguments: [])
        state.withLockedValue { $0.recordings.append((process, fMp4Options)) }
        return process
    }

    func makeLivestream(options: any ProtectFfmpegOptions, configuration: CameraRecordingConfiguration, livestreamOptions: FMp4LivestreamOptions,
                        verbose: Bool) -> any ProtectFfmpegLivestream {
        let livestream = FakeLivestream(options: livestreamOptions)
        state.withLockedValue { state in
            livestream.state.withLockedValue { $0.initOnStart = state.livestreamInit }
            state.livestreams.append(livestream)
        }
        return livestream
    }

    func startProcess(options: any ProtectFfmpegOptions, arguments: [String]) -> any ProtectFfmpegProcess {
        let process = FakeProcess(arguments: arguments)
        state.withLockedValue { $0.processes.append(process) }
        return process
    }

    func exec(options: any ProtectFfmpegOptions, arguments: [String], stdin: Data?, timeout: Int?, logErrors: Bool) async -> (exitCode: Int32?, stdout: Data)? {
        let result = state.withLockedValue { state -> Data? in
            state.execs.append((arguments, stdin))
            return state.execResult
        }
        return result.map { (0, $0) }
    }
}

// MARK: Pure functions

@Suite struct CameraFormattingTests {
    @Test func bitRatesAndDurations() {
        #expect(formatBps(500) == "500 bps")
        #expect(formatBps(2500) == "2.5 kbps")
        #expect(formatBps(2_000_000) == "2 Mbps")
        #expect(formatBps(1_500_000) == "1.5 Mbps")
        #expect(formatRecordingDuration(0.5) == ("0.5", "second"))
        #expect(formatRecordingDuration(12.4) == ("12", "second"))
        #expect(formatRecordingDuration(65) == ("1:05", "minute"))
        #expect(formatRecordingDuration(600) == ("10:00", "minute"))
        #expect(formatRecordingDuration(3605) == ("01:00:05", "hour"))
        #expect(formatRecordingDuration(36000) == ("10:00:00", "hour"))
        #expect(ProtectStreamingDelegate.grouped(1234567) == "1,234,567")
        #expect(ProtectStreamingDelegate.grouped(999) == "999")
    }

    @Test func probesizeTuning() async {
        let tuner = ProtectProbesizeTuner(log: ProtectLog(logger: testLogger), defaultProbesize: 16384, timeScale: 0.00001)
        #expect(tuner.probesize == 16384)
        #expect(tuner.errorCheck(["[mov] moov atom not found"], isApiLivestreaming: false) == nil)
        #expect(tuner.errorCheck(["[mov] moov atom not found"], isApiLivestreaming: true)?.hasPrefix("FFmpeg ended unexpectedly") == true)
        #expect(tuner.errorCheck(["something else"], isApiLivestreaming: true) == nil)
        tuner.adjust()
        #expect(tuner.probesize == 32768)
        // Back to the default after the override's time (ten minutes, scaled).
        #expect(await eventually { tuner.probesize == 16384 })
        for _ in 0..<12 { tuner.adjust() }
        #expect(tuner.probesize == ProtectSettings.ffmpegProbesizeMax)
        try? await Task.sleep(for: .milliseconds(50))
        // Ten adjustments make it permanent.
        #expect(tuner.probesize == ProtectSettings.ffmpegProbesizeMax)
    }

    @Test func talkbackDescription() {
        let request = CameraStreamingTests.startRequest("s", width: 1280, height: 720, packetTime: 30)
        let session = ProtectTalkback.Session(address: "10.0.0.2", audioIncomingRtpPort: 50002, audioSRTP: Data(repeating: 7, count: 30), rtpDemuxer: nil, talkBack: nil)
        let sdp = ProtectTalkback.sdp(request, session: session, sdpIpVersion: "IP4", accessoryName: "Front Door").split(separator: "\n").map(String.init)
        #expect(sdp == [
            "v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=Front Door Audio Talkback", "c=IN IP4 10.0.0.2", "t=0 0", "m=audio 50002 RTP/AVP 110", "b=AS:24",
            "a=rtpmap:110 MPEG4-GENERIC/16000/1",
            "a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00",
            "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:" + Data(repeating: 7, count: 30).base64EncodedString(),
        ])
        var wide = request
        wide.audio.sampleRate = 24
        let wideSDP = ProtectTalkback.sdp(wide, session: session, sdpIpVersion: "IP6", accessoryName: "Front Door")
        #expect(wideSDP.contains("MPEG4-GENERIC/24000/1") && wideSDP.contains("config=F8EC212C00BC00") && wideSDP.contains("c=IN IP6 10.0.0.2"))
    }

    @Test func snapshotCommandLine() {
        let input = ["-f", "mp4", "-i", "pipe:0"]
        let scaled = ProtectSnapshot.snapshotArguments(input: input, decoder: [], request: SnapshotRequest(height: 360, width: 640), verbose: false)
        #expect(scaled == ["-hide_banner", "-nostats", "-fflags", "+discardcorrupt+genpts", "-max_delay", "500000", "-flags", "low_delay", "-skip_frame", "nointra",
                           "-f", "mp4", "-i", "pipe:0", "-fps_mode", "vfr", "-frames:v", "1", "-q:v", "2",
                           "-filter:v", "scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2",
                           "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"])
        let qsv = ProtectSnapshot.snapshotArguments(input: input, decoder: ["-hwaccel", "qsv", "-codec:v", "h264_qsv"],
                                                    request: SnapshotRequest(height: 360, width: 640), verbose: true)
        #expect(qsv.prefix(2) == ["-loglevel", "level+verbose"])
        #expect(qsv.contains("hwdownload,format=nv12,scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2"))
        let full = ProtectSnapshot.snapshotArguments(input: input, decoder: [], request: nil, verbose: false)
        #expect(!full.contains("-filter:v"))
    }
}

// MARK: Cameras on a bridge

/// The camera code with the real camera controller and FFmpeg in memory: the controller's options, live streams from RTSP and the
/// livestream API, snapshots, HKSV through the timeshift buffer, two-way audio (protect-stream, protect-record,
/// protect-timeshift, protect-snapshot and protect-talkback of the Homebridge plugin).
@Suite(.timeLimit(.minutes(1))) struct CameraStreamingTests {
    static let cameraID = ProtectPlatform.accessoryID(Fixtures.cameraMAC)
    static let doorbellID = ProtectPlatform.accessoryID(Fixtures.doorbellMAC)
    static let packageID = ProtectPlatform.accessoryID(Fixtures.doorbellMAC + ".PackageCamera")

    @ProtectActor func stream(_ device: ProtectDevice?) -> ProtectStreamingDelegate? { (device as? ProtectCamera)?.stream }
    @ProtectActor func recording(_ device: ProtectDevice?) -> ProtectRecordingDelegate? { (device as? ProtectCamera)?.stream?.hksv }

    /// The camera controller the plugin put on an accessory, once it is published.
    func controller(_ environment: ProtectTestEnvironment, _ host: PluginHost, _ id: String) async -> CameraController? {
        await eventually { environment.accessory(host, id)?.cameraController != nil } ? environment.accessory(host, id)?.cameraController : nil
    }

    /// A recording configuration HomeKit could select: 1080p30 at 2 Mbps, AAC-LC at 16 kHz.
    static func recordingConfiguration(prebuffer: Int = 200) -> CameraRecordingConfiguration {
        CameraRecordingConfiguration(
            prebufferLength: prebuffer, eventTriggerTypes: [.motion], mediaContainerConfiguration: MediaContainerConfiguration(fragmentLength: 4000),
            videoCodec: .init(type: .h264, parameters: .init(profile: .main, level: .level4_0, bitRate: 2000, iFrameInterval: 4000), resolution: VideoResolution(1920, 1080, 30)),
            audioCodec: .init(audioChannels: 1, type: .aacLC, samplerate: .khz16, bitrateMode: .variable, bitrate: 32))
    }

    static func startRequest(_ sessionID: String, width: Int, height: Int, packetTime: Int) -> StartStreamRequest {
        StartStreamRequest(
            sessionID: sessionID,
            video: VideoInfo(codec: 0, profile: 1, level: 2, packetizationMode: 0, cvoId: nil, width: width, height: height, fps: 30, pt: 99, ssrc: 1,
                             maxBitRate: 299, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: packetTime, pt: 110, ssrc: 2, maxBitRate: 24,
                             rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))
    }
    @ProtectActor func livestreamSubscribers(_ device: ProtectDevice?, _ entry: RtspEntry) -> Int { (device as? ProtectCamera)?.livestream.subscriberCount(entry) ?? -1 }

    func prepare(_ sessionID: String = "session-1") -> PrepareStreamRequest {
        PrepareStreamRequest(sessionID: sessionID, sourceAddress: "10.0.0.1", targetAddress: "10.0.0.2", addressVersion: .ipv4,
                             video: .init(port: 51000, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 1, count: 16), srtpSalt: Data(repeating: 2, count: 14)),
                             audio: .init(port: 51002, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 3, count: 16), srtpSalt: Data(repeating: 4, count: 14)))
    }

    func start(_ sessionID: String = "session-1", width: Int = 1280, height: Int = 720, packetTime: Int = 20) -> StreamingRequest {
        .start(Self.startRequest(sessionID, width: width, height: height, packetTime: packetTime))
    }

    @Test func controllerOptions() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let package = try #require(await controller(environment, host, Self.packageID))
        let camera = try #require(await controller(environment, host, Self.cameraID))
        let resolutions = camera.options.streamingOptions.video.resolutions.map(\.formatted)
        #expect(resolutions.contains("1920x1080@30fps") && resolutions.contains("1280x720@30fps") && resolutions.contains("2688x1512@30fps"))
        // H.264 Main at levels 3.1 to 4.0, for streams and recordings.
        #expect(camera.options.streamingOptions.video.codec == H264CodecParameters(profiles: [.main], levels: [.level3_1, .level3_2, .level4_0]))
        #expect(camera.options.recording?.options.video.parameters == camera.options.streamingOptions.video.codec)
        // The livestream API's 16 kHz for cameras; doorbells sample at 48 kHz, which divides into 16 and 24.
        #expect(camera.options.streamingOptions.audio?.codecs.map(\.samplerate) == [[.khz16]] && camera.options.streamingOptions.audio?.twoWayAudio == false)
        let recording = try #require(camera.options.recording?.options)
        #expect(recording.audio.map(\.samplerate) == [[.khz16]] && recording.mediaContainerConfiguration == [MediaContainerConfiguration(fragmentLength: 4000)])
        #expect(recording.prebufferLength == 10000)
        // Ten streams, a microphone, HKSV with the plugin's motion sensor.
        #expect(camera.streamManagementServices.count == 10 && camera.motionService != nil && camera.microphoneService != nil && camera.speakerService == nil)
        let doorbell = try #require(await controller(environment, host, Self.doorbellID))
        #expect(doorbell.options.streamingOptions.audio?.codecs.map(\.samplerate) == [[.khz16, .khz24]] && doorbell.options.streamingOptions.audio?.twoWayAudio == true)
        #expect(doorbell.options.recording?.options.audio.map(\.samplerate) == [[.khz48]])
        #expect(package.options.streamingOptions.video.resolutions.first?.formatted == "1600x1200@2fps")
        // The controller's services are on the accessory.
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        #expect(accessory.services.contains { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid })
        #expect(ffmpeg.state.withLockedValue { $0.probes } == 1)
    }

    @Test func withoutFFmpegNothingStarts() async throws {
        let environment = ProtectTestEnvironment(ffmpeg: FakeFfmpegKit(works: false))
        let host = try environment.host(settings: ProtectTestEnvironment.block())
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.logs.contains("This plugin requires a working version of FFmpeg") })
        #expect(environment.controller.requests("/api/auth/login").isEmpty)
    }

    @Test func rtspStream() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let stream = try #require(await stream(environment.device("camera-id")))
        let response = try await stream.prepareStream(prepare())
        // No speaker: the audio return port is the RTCP port, the video's is the next.
        #expect(response.audio?.port == 50000 && response.video.port == 50001)
        #expect(response.video.srtpKey == Data(repeating: 1, count: 16) && response.audio?.srtpSalt == Data(repeating: 4, count: 14))
        try await stream.handleStreamRequest(start())
        let process = try #require(ffmpeg.streams.last)
        // Transcoding (the default) from the stream at or above the request, at the configured bit rate.
        #expect(process.argument(after: "-rtsp_transport") == "tcp")
        #expect(process.argument(after: "-i") == "rtsps://192.168.1.1:7441/mediumAlias?enableSrtp")
        #expect(process.argument(after: "-probesize") == "16384")
        #expect(process.argument(after: "-b:v") == "2000k")
        #expect(process.argument(after: "-map") == "0:v:0")
        #expect(process.arguments.contains("0:a:1?") && process.argument(after: "-ar") == "16k" && process.argument(after: "-packetsize") == "1200")
        let videoSRTP = (Data(repeating: 1, count: 16) + Data(repeating: 2, count: 14)).base64EncodedString()
        #expect(process.argument(after: "-srtp_out_params") == videoSRTP)
        #expect(process.arguments.contains("srtp://10.0.0.2:51000?rtcpport=51000") && process.arguments.contains("srtp://10.0.0.2:51002?rtcpport=51002"))
        #expect(process.argument(after: "-metadata") == "comment=Driveway Livestream")
        #expect(environment.logs.contains("Streaming request: 1280x720@30fps, 2 Mbps. Using 1280x720@30fps (Medium) [H264], 2 Mbps [RTSP]."))
        try await stream.handleStreamRequest(.stop(sessionID: "session-1"))
        #expect(process.isStopped)
        #expect(ffmpeg.state.withLockedValue { $0.cancelled }.sorted() == [50000, 50001])
        #expect(environment.logs.contains("Stopped video streaming session."))
        // A session that was never prepared, and a camera that went offline.
        await #expect(throws: ProtectStreamError.self) { try await stream.handleStreamRequest(start("unknown")) }
        _ = try await stream.prepareStream(prepare("session-2"))
        environment.update("camera", id: "camera-id", ["isConnected": false])
        _ = await eventually { await self.stream(environment.device("camera-id"))?.camera.isOnline == false }
        await #expect(throws: ProtectStreamError.self) { try await stream.handleStreamRequest(start("session-2")) }
        // The failed start released what the session had reserved.
        #expect(ffmpeg.state.withLockedValue { $0.cancelled }.sorted() == [50000, 50001, 50002, 50003])
    }

    @Test func highLatencyAndCopy() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start(options: ["Disable.Video.Transcode"])
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let stream = try #require(await stream(environment.device("camera-id")))
        _ = try await stream.prepareStream(prepare())
        try await stream.handleStreamRequest(start(width: 1920, height: 1080))
        let copy = try #require(ffmpeg.streams.last)
        // At home without transcoding: the stream is copied, from the closest stream below the request.
        #expect(copy.argument(after: "-codec:v") == "copy" && copy.argument(after: "-i") == "rtsps://192.168.1.1:7441/mediumAlias?enableSrtp")
        _ = try await stream.prepareStream(prepare("session-2"))
        try await stream.handleStreamRequest(start("session-2", width: 1280, height: 720, packetTime: 60))
        let cellular = try #require(ffmpeg.streams.last)
        // Cellular clients are transcoded by default, at their own bit rate.
        #expect(cellular.argument(after: "-codec:v") == "libx264" && cellular.argument(after: "-b:v") == "1000k")
    }

    @Test func snapshots() async throws {
        let ffmpeg = FakeFfmpegKit()
        // The budgets are real time; a clock that stands still keeps a loaded machine from running them out.
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg, snapshotClock: FrozenClock())
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let stream = try #require(await stream(environment.device("camera-id")))
        let image = try await stream.handleSnapshotRequest(SnapshotRequest(height: 360, width: 640))
        #expect(image == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let exec = try #require(ffmpeg.execs.last)
        // No timeshift buffer: the highest quality RTSP stream.
        #expect(exec.arguments.contains("rtsps://192.168.1.1:7441/highAlias?enableSrtp") && exec.arguments.contains("-skip_frame"))
        #expect(await eventually { environment.mqtt.published("unifi/protect/\(Fixtures.cameraMAC)/snapshot").first?.hasPrefix("data:image/jpeg;base64,/9j/") == true })
        // HomeKit asks again for a smaller image: the fresh one serves.
        _ = try await stream.handleSnapshotRequest(SnapshotRequest(height: 180, width: 320))
        #expect(ffmpeg.execs.count == 1)
        // A larger one needs a new image; FFmpeg fails, and the controller's API answers.
        ffmpeg.state.withLockedValue { $0.execResult = nil }
        let fallback = try await stream.handleSnapshotRequest(SnapshotRequest(height: 1080, width: 1920))
        #expect(fallback == Data([0xFF, 0xD8, 0xFF]))
        let request = try #require(environment.controller.requests.last { $0.path.hasSuffix("/snapshot") })
        #expect(request.query?.contains("w=1920") == true)
    }

    @Test func recordingThroughTheTimeshiftBuffer() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let controller = try #require(await controller(environment, host, Self.cameraID))
        // HomeKit turns recording audio on.
        controller.services.first { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid }?[.recordingAudioActive]?.value = .int(1)
        let recording = try #require(await recording(environment.device("camera-id")))
        let device = await environment.device("camera-id")
        await recording.updateRecordingConfiguration(Self.recordingConfiguration())
        let activation = Task { await recording.updateRecordingActive(true) }
        // The timeshift buffer opens a livestream on the stream above 1080p.
        let socket = try #require(await eventually { environment.webSockets.connections.contains { $0.path.contains("livestream") } }
            ? environment.webSockets.connections.last { $0.path.contains("livestream") } : nil)
        let request = try #require(environment.controller.requests("/proxy/protect/api/ws/livestream").last)
        #expect(request.query?.contains("channel=0") == true && request.query?.contains("camera=camera-id") == true)
        socket.push(ProtocolTests.livePacket(250, Data("init".utf8)))
        await activation.value
        #expect(await recording.isRecording)
        let recordingName = await recording.rtspEntry?.name ?? "-"
        #expect(environment.logs.messages.contains { $0.hasSuffix("HKSV: \u{26A1}\u{FE0F} \(recordingName), 2 Mbps.") })
        for value in UInt8(1)...UInt8(5) {
            socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([value])) + ProtocolTests.livePacket(254, Data([value])) + ProtocolTests.livePacket(255))
        }
        let timeshift = await recording.timeshift
        #expect(await eventually { await timeshift.time == 500 })
        #expect(await timeshift.getLast(200) == Data("init".utf8) + Data([4, 4, 5, 5]))
        #expect(await timeshift.getLast(50) == Data("init".utf8) + Data([1, 1, 2, 2, 3, 3, 4, 4, 5, 5]))
        #expect(await timeshift.getLast(0) == nil)
        // An event: FFmpeg gets the buffer, then the livestream, and HomeKit its fragments.
        let packets = await recording.handleRecordingStreamRequest(streamID: 1)
        let event = try #require(await eventually { ffmpeg.state.withLockedValue { !$0.recordings.isEmpty } }
            ? ffmpeg.state.withLockedValue { $0.recordings.last } : nil)
        #expect(event.options.timeshift == 300 && event.options.enableAudio == true && event.options.fps == 30)
        #expect(await eventually { event.process.written == Data("init".utf8) + Data([1, 1, 2, 2, 3, 3, 4, 4, 5, 5]) })
        socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([6])) + ProtocolTests.livePacket(254, Data([6])) + ProtocolTests.livePacket(255))
        #expect(await eventually { event.process.written.suffix(2) == Data([6, 6]) })
        event.process.fragment(Data("fragment-1".utf8))
        event.process.fragment(Data("fragment-2".utf8))
        var iterator = packets.makeAsyncIterator()
        for fragment in ["fragment-1", "fragment-2"] {
            let packet = try await iterator.next()
            #expect(packet?.data == Data(fragment.utf8) && packet?.isLast == false)
        }
        await recording.closeRecordingStream(streamID: 1, reason: .normal)
        #expect(event.process.isStopped)
        // Turning recording off stops the buffer and its livestream.
        await recording.updateRecordingActive(false)
        #expect(await eventually { socket.isClosed })
        #expect(environment.logs.contains("Disabling HomeKit Secure Video event recording."))
        _ = device
    }

    /// `Debug.Video.HKSV.UseRtsp`: the timeshift buffer reads the channel's RTSP stream through FFmpeg instead of the livestream API
    /// (protect-livestream.ts with `FfmpegLivestreamProcess`), each moof and its mdat one segment.
    @Test func recordingFromRtsp() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: ffmpeg)
        let host = try await environment.start(options: ["Enable.Debug.Video.HKSV.UseRtsp"])
        defer { Task { await host.stop() } }
        let controller = try #require(await controller(environment, host, Self.cameraID))
        controller.services.first { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid }?[.recordingAudioActive]?.value = .int(1)
        #expect(environment.logs.contains("Enabling RTSP-based HKSV events are for debugging purposes only and unsupported."))
        let recording = try #require(await recording(environment.device("camera-id")))
        await recording.updateRecordingConfiguration(Self.recordingConfiguration())
        let activation = Task { await recording.updateRecordingActive(true) }
        let livestream = try #require(await eventually { ffmpeg.state.withLockedValue { !$0.livestreams.isEmpty } }
            ? ffmpeg.state.withLockedValue { $0.livestreams.last } : nil)
        #expect(await eventually { livestream.isRunning })
        let entry = try #require(await recording.rtspEntry)
        #expect(livestream.options.url == entry.url && livestream.options.codec == "h264" && livestream.options.enableAudio == true)
        #expect(livestream.starts == [ProtectSettings.segmentResolution])
        livestream.writeInit(Data("init".utf8))
        await activation.value
        #expect(await recording.isRecording)
        // No livestream API session.
        #expect(!environment.webSockets.connections.contains { $0.path.contains("livestream") })
        #expect(environment.controller.requests("/proxy/protect/api/ws/livestream").isEmpty)
        for value in UInt8(1)...UInt8(3) {
            livestream.writeBox("moof", Data([value]))
            livestream.writeBox("mdat", Data([value]))
        }
        let timeshift = await recording.timeshift
        #expect(await eventually { await timeshift.time == 300 })
        let pair = { (value: UInt8) in FakeLivestream.box("moof", Data([value])) + FakeLivestream.box("mdat", Data([value])) }
        #expect(await timeshift.getLast(100) == Data("init".utf8) + pair(3))
        #expect(await timeshift.buffer == Data("init".utf8) + pair(1) + pair(2) + pair(3))
        // FFmpeg ends on its own: the session closes.
        livestream.exit()
        #expect(await eventually { environment.logs.contains("RTSP connection closed by the controller. Retrying shortly.") })
        await recording.updateRecordingActive(false)
        #expect(!livestream.isRunning)
    }

    /// A session from RTSP that goes quiet is restarted like a livestream API session: FFmpeg starts again.
    @Test func rtspSessionRestarts() async throws {
        let ffmpeg = FakeFfmpegKit()
        ffmpeg.state.withLockedValue { $0.livestreamInit = Data("init".utf8) }
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start(options: ["Enable.Debug.Video.HKSV.UseRtsp"])
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let recording = try #require(await recording(environment.device("camera-id")))
        await recording.updateRecordingConfiguration(Self.recordingConfiguration())
        let activation = Task { await recording.updateRecordingActive(true) }
        let livestream = try #require(await eventually { ffmpeg.state.withLockedValue { !$0.livestreams.isEmpty } }
            ? ffmpeg.state.withLockedValue { $0.livestreams.last } : nil)
        await activation.value
        #expect(await recording.isRecording)
        // Nothing comes: the watchdog restarts FFmpeg.
        #expect(await eventually { livestream.starts.count >= 2 && livestream.isRunning })
        #expect(environment.logs.contains("Reconnecting to the RTSP stream."))
        #expect(ffmpeg.state.withLockedValue { $0.livestreams.count } == 1)
        await recording.updateRecordingActive(false)
    }

    @Test func recordingWithoutEnoughVideo() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let recording = try #require(await recording(environment.device("camera-id")))
        // Not configured: HomeKit gets a single empty packet.
        var iterator = await recording.handleRecordingStreamRequest(streamID: 1).makeAsyncIterator()
        let packet = try await iterator.next()
        #expect(packet?.data == Data([0]) && packet?.isLast == true)
        #expect(try await iterator.next() == nil)
    }

    @Test func liveFromTheLivestreamAPI() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let recording = try #require(await recording(environment.device("camera-id")))
        await recording.updateRecordingConfiguration(Self.recordingConfiguration())
        let activation = Task { await recording.updateRecordingActive(true) }
        let socket = try #require(await eventually { environment.webSockets.connections.contains { $0.path.contains("livestream") } }
            ? environment.webSockets.connections.last { $0.path.contains("livestream") } : nil)
        socket.push(ProtocolTests.livePacket(250, Data("init".utf8)))
        await activation.value
        socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([1])) + ProtocolTests.livePacket(254, Data([1])) + ProtocolTests.livePacket(255))
        let timeshift = await recording.timeshift
        #expect(await eventually { await timeshift.time == 100 })
        let stream = try #require(await stream(environment.device("camera-id")))
        _ = try await stream.prepareStream(prepare())
        try await stream.handleStreamRequest(start())
        let process = try #require(ffmpeg.streams.last)
        // The same session as the buffer: one livestream, two consumers.
        #expect(process.argument(after: "-i") == "pipe:0" && process.argument(after: "-f") == "mp4" && process.arguments.contains("0:a:0?"))
        let entry = try #require(await recording.rtspEntry)
        #expect(await livestreamSubscribers(environment.device("camera-id"), entry) == 2)
        #expect(environment.webSockets.connections.filter { $0.path.contains("livestream") }.count == 1)
        socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([2])) + ProtocolTests.livePacket(254, Data([2])) + ProtocolTests.livePacket(255))
        // The buffer's last seconds, then the livestream.
        #expect(await eventually { process.written == Data("init".utf8) + Data([1, 1]) + Data([2, 2]) })
        try await stream.handleStreamRequest(.stop(sessionID: "session-1"))
        #expect(await eventually { await self.livestreamSubscribers(environment.device("camera-id"), entry) == 1 })
        #expect(!socket.isClosed)
    }

    /// An ISO BMFF box.
    static func box(_ type: String, _ body: Data) -> Data {
        let size = UInt32(8 + body.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + Data(type.utf8) + body
    }

    /// An initialization segment with one H.264 track whose avcC says Main at level 4.0.
    static let liveInitSegment: Data = box("ftyp", Data("isom".utf8)) + box("moov", box("trak", box("mdia", box("minf", box("stbl",
        box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + box("avc1", Data(count: 78) + box("avcC", Data([1, 0x4D, 0x40, 0x28, 0xFF])))))))))

    @ProtectActor func liveFeedEntry(_ device: ProtectDevice?) -> RtspEntry? { (device as? ProtectCamera)?.liveFeedEntry }

    @Test func liveFeedForTheWebUI() async throws {
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: FakeFfmpegKit())
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let plugin = try #require(environment.plugin)
        #expect(try await plugin.liveFeed(accessoryID: ProtectPlatform.accessoryID(Fixtures.lightMAC)) == nil)

        let pending = Task { try await plugin.liveFeed(accessoryID: Self.cameraID) }
        let socket = try #require(await eventually { environment.webSockets.connections.contains { $0.path.contains("livestream") } }
            ? environment.webSockets.connections.last { $0.path.contains("livestream") } : nil)
        // The channel with the fewest pixels: Low, which is light on the controller.
        let request = try #require(environment.controller.requests("/proxy/protect/api/ws/livestream").last)
        #expect(URLComponents(string: "https://x/?" + (request.query ?? ""))?.queryItems?.first { $0.name == "channel" }?.value == "2")
        socket.push(ProtocolTests.livePacket(248, Data("avc1.640028,mp4a.40.2".utf8)) + ProtocolTests.livePacket(250, Self.liveInitSegment))
        let feed = try #require(try await pending.value)
        // The codecs of the segment itself, over what the API announced.
        #expect(feed.mimeType == #"video/mp4; codecs="avc1.4d4028""#)
        #expect(feed.initSegment == Self.liveInitSegment)
        let segment = { (byte: UInt8) in
            ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([byte])) + ProtocolTests.livePacket(254, Data([byte + 1])) + ProtocolTests.livePacket(255)
        }
        socket.push(segment(1) + segment(3))
        var fragments = feed.fragments.makeAsyncIterator()
        #expect(try await fragments.next() == Data([1, 2]))
        #expect(try await fragments.next() == Data([3, 4]))

        // A second viewer joins the session: the initialization segment at once, one WebSocket.
        let second = try #require(try await plugin.liveFeed(accessoryID: Self.cameraID))
        #expect(second.initSegment == Self.liveInitSegment)
        let entry = try #require(await liveFeedEntry(environment.device("camera-id")))
        #expect(await livestreamSubscribers(environment.device("camera-id"), entry) == 2)
        #expect(environment.webSockets.connections.filter { $0.path.contains("livestream") }.count == 1)

        // Leaving releases the session; the last viewer stops it.
        feed.cancel()
        #expect(try await fragments.next() == nil)
        #expect(await eventually { await self.livestreamSubscribers(environment.device("camera-id"), entry) == 1 })
        #expect(!socket.isClosed)
        second.cancel()
        #expect(await eventually { await self.livestreamSubscribers(environment.device("camera-id"), entry) == 0 })
        #expect(await eventually { socket.isClosed })
    }

    @Test func twoWayAudio() async throws {
        let ffmpeg = FakeFfmpegKit()
        let controller = FakeController()
        controller.update { state in
            state.bootstrap = Fixtures.bootstrap(cameras: [Fixtures.camera(), Fixtures.doorbell().setting("talkbackSettings", [
                "samplingRate": 24000, "channels": 1, "bindPort": 7004, "typeFmt": "aac",
            ])])
        }
        let environment = ProtectTestEnvironment(controller: controller, ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await self.controller(environment, host, Self.doorbellID)
        let stream = try #require(await stream(environment.device("doorbell-id")))
        let response = try await stream.prepareStream(prepare())
        // RTCP, the demuxer's input, two RTP ports, then video.
        #expect(response.audio?.port == 50001 && response.video.port == 50004)
        #expect(controller.requests("/proxy/protect/api/ws/talkback").last?.query?.contains("camera=doorbell-id") == true)
        try await stream.handleStreamRequest(start())
        let talkback = try #require(await eventually { ffmpeg.streams.count == 2 } ? ffmpeg.streams.last : nil)
        #expect(talkback.argument(after: "-f") == "sdp" && talkback.argument(after: "-codec:a") == "libfdk_aac" && talkback.argument(after: "-ar") == "24000")
        #expect(talkback.argument(after: "-ac") == "1" && talkback.argument(after: "-b:a") == "24k" && talkback.arguments.last == "pipe:1")
        let sdp = String(decoding: talkback.written, as: UTF8.self)
        #expect(sdp.hasPrefix("v=0\n") && sdp.contains("m=audio 50002 RTP/AVP 110") && sdp.hasSuffix("\n"))
        // FFmpeg's ADTS goes to the camera through the controller's talkback WebSocket.
        let socket = try #require(await eventually { environment.webSockets.connections.contains { $0.path.contains("talkback") } }
            ? environment.webSockets.connections.last { $0.path.contains("talkback") } : nil)
        talkback.output(Data([0xFF, 0xF1, 1]))
        talkback.output(Data([0xFF, 0xF1, 2]))
        #expect(await eventually { socket.sentData == [Data([0xFF, 0xF1, 1]), Data([0xFF, 0xF1, 2])] })
        try await stream.handleStreamRequest(.stop(sessionID: "session-1"))
        #expect(talkback.isStopped)
        #expect(await eventually { socket.isClosed })
        #expect(ffmpeg.state.withLockedValue { $0.demuxers.first?.closed.withLockedValue { $0 } } == true)
    }

    /// ffmpeg-for-homeswift: no libfdk_aac, libopus. Live streams offer and send Opus; talkback decodes it and
    /// sends the camera FFmpeg's own AAC.
    @Test func opusWithoutFdk() async throws {
        let ffmpeg = FakeFfmpegKit(options: FakeFfmpegOptions(hasFdk: false))
        let controller = FakeController()
        controller.update { state in
            state.bootstrap = Fixtures.bootstrap(cameras: [Fixtures.camera(), Fixtures.doorbell().setting("talkbackSettings", [
                "samplingRate": 24000, "channels": 1, "bindPort": 7004, "typeFmt": "aac",
            ])])
        }
        let environment = ProtectTestEnvironment(controller: controller, ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let doorbell = try #require(await self.controller(environment, host, Self.doorbellID))
        #expect(doorbell.options.streamingOptions.audio?.codecs.map(\.type) == [.opus])
        let stream = try #require(await stream(environment.device("doorbell-id")))
        _ = try await stream.prepareStream(prepare())
        #expect(!environment.logs.contains("Audio support disabled"))
        var request = Self.startRequest("session-1", width: 1280, height: 720, packetTime: 20)
        request.audio.codec = .opus
        request.audio.pt = 111
        try await stream.handleStreamRequest(.start(request))
        let live = try #require(await eventually { ffmpeg.streams.count == 2 } ? ffmpeg.streams.first : nil)
        #expect(live.argument(after: "-frame_duration") == "20" && live.arguments.contains("libopus") && !live.arguments.contains("-profile:a"))
        #expect(live.argument(after: "-ar") == "16k" && live.arguments.contains("srtp://10.0.0.2:51002?rtcpport=51002"))
        let talkback = try #require(ffmpeg.streams.last)
        let codecs = talkback.arguments.indices.filter { talkback.arguments[$0] == "-codec:a" }.map { talkback.arguments[$0 + 1] }
        #expect(codecs == ["libopus", "aac"] && talkback.argument(after: "-ar") == "24000" && talkback.arguments.last == "pipe:1")
        let sdp = String(decoding: talkback.written, as: UTF8.self)
        #expect(sdp.contains("m=audio 50002 RTP/AVP 111") && sdp.contains("a=rtpmap:111 opus/48000/2") && !sdp.contains("MPEG4-GENERIC"))
        try await stream.handleStreamRequest(.stop(sessionID: "session-1"))
    }

    @Test func removingTheCameraTakesTheControllerOff() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start(options: ["Disable.Nvr.DelayDeviceRemoval"])
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let stream = try #require(await stream(environment.device("camera-id")))
        #expect(await stream.controller != nil)
        environment.add("event", id: "event-3", ["type": "deviceUnadopted", "metadata": ["deviceId": ["text": "camera-id"]]])
        #expect(await eventually { await stream.controller == nil })
    }
}
