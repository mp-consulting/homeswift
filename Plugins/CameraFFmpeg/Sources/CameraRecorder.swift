import Foundation
import Homeswift
import HomeswiftFFmpeg
import NIOConcurrencyHelpers

/// HomeKit Secure Video for one camera (sections 9.1 to 9.4): each recording is an FFmpeg reading the source (or the
/// prebuffer) and writing fragmented MP4, cut into the initialization segment and `moof` + `mdat` fragments.
final class CameraRecorder: CameraRecordingDelegate, @unchecked Sendable {
    let video: CameraFFmpegPlugin.VideoConfig
    let log: CameraLog
    let tools: FFmpegTools
    let prebuffer: Prebuffer?

    private struct Recording {
        var streamID: Int
        var process: FfmpegProcess
        /// The plugin ended it: its exit is not a failure.
        var stopping = false
    }

    private struct State {
        var configuration: CameraRecordingConfiguration?
        var recording: Recording?
    }

    private let state = NIOLockedValueBox(State())

    init(video: CameraFFmpegPlugin.VideoConfig, log: CameraLog, tools: FFmpegTools, prebuffer: Prebuffer?) {
        self.video = video
        self.log = log
        self.tools = tools
        self.prebuffer = prebuffer
    }

    /// What HomeKit can ask a recording to be (9.1).
    static func options(resolutions: [VideoResolution]) -> CameraRecordingOptions {
        CameraRecordingOptions(
            prebufferLength: 4000, overrideEventTriggerOptions: [.motion, .doorbell],
            mediaContainerConfiguration: [MediaContainerConfiguration(type: .fragmentedMP4, fragmentLength: 4000)],
            video: VideoRecordingOptions(parameters: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]),
                                         resolutions: resolutions),
            audio: [AudioRecordingCodec(type: .aacLC, audioChannels: 1, bitrateMode: .variable, samplerate: [.khz32])])
    }

    func updateRecordingActive(_ active: Bool) {
        log.info("Recording \(active ? "activated" : "deactivated").")
    }

    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        log.info("Recording configuration \(configuration == nil ? "cleared" : "updated").")
        state.withLockedValue { $0.configuration = configuration }
    }

    typealias Packets = AsyncThrowingStream<RecordingPacket, any Error>

    func handleRecordingStreamRequest(streamID: Int) -> Packets {
        log.info("Recording stream requested: \(streamID)")
        let (packets, continuation) = Packets.makeStream()
        guard let configuration = state.withLockedValue({ $0.configuration }) else {
            log.error("Unable to start recording stream: no recording configuration.")
            continuation.finish()
            return packets
        }
        let task = Task { [self] in
            await record(streamID: streamID, configuration: configuration, continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return packets
    }

    private func record(streamID: Int, configuration: CameraRecordingConfiguration, _ continuation: Packets.Continuation) async {
        var feed: AsyncStream<Data>?
        if let prebuffer {
            do {
                try await prebuffer.start()
            } catch {
                log.error("Prebuffer failed to start: \(error)")
            }
            feed = prebuffer.feed(duration: .milliseconds(configuration.mediaContainerConfiguration.fragmentLength))
        }
        guard !Task.isCancelled else { return }
        let arguments: [String]
        do {
            arguments = try FFmpegArguments.recording(video, configuration: configuration, prebuffered: feed != nil)
        } catch {
            log.error("Recording stream error: \(error)")
            continuation.yield(RecordingPacket(data: Data(), isLast: true))
            return
        }

        let process = FfmpegProcess(tools.options, commandLineArgs: arguments)
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        // One recording FFmpeg per camera: a new one ends the one before.
        let previous = state.withLockedValue { state -> FfmpegProcess? in
            defer { state.recording = Recording(streamID: streamID, process: process) }
            state.recording?.stopping = true
            return state.recording?.process
        }
        previous?.stop()
        process.start()
        guard process.onStdout({ outputContinuation.yield($0) }) != nil,
              process.onceExit({ [weak self] status in
                  outputContinuation.finish()
                  self?.exited(status, process: process)
              })
        else {
            log.error("FFmpeg session failed to start.")
            continuation.yield(RecordingPacket(data: Data(), isLast: true))
            return
        }
        let writer = feed.map { feed in
            Task {
                for await data in feed {
                    do { try await process.writeStdin(data) } catch { break }
                }
                // The prebuffer ended: the recording reaches the end of its input, rather than waiting for more.
                process.endStdin()
            }
        }
        defer {
            writer?.cancel()
            stop(process)
        }

        var reader = MP4BoxReader()
        var fragmenter = RecordingFragmenter()
        var fragments = 0
        var bytes = 0
        do {
            for await chunk in output {
                for box in try reader.push(chunk) {
                    guard let packet = fragmenter.add(box) else { continue }
                    fragments += 1
                    bytes += packet.count
                    log.debug("Recording wrote \(packet.count) bytes (\(fragments) fragments, \(bytes) bytes in all).")
                    continuation.yield(RecordingPacket(data: packet))
                }
            }
            guard !Task.isCancelled else { return }
            log.info("Recording completed: \(fragments) fragments, \(bytes) bytes.")
            // FFmpeg ended before the hub closed the stream (the camera went away): the hub is told it is over.
            continuation.yield(RecordingPacket(data: Data(), isLast: true))
        } catch {
            log.error("Recording stream error: \(error)")
            continuation.yield(RecordingPacket(data: Data(), isLast: true))
        }
    }

    /// Stops a recording's FFmpeg the plugin no longer needs.
    private func stop(_ process: FfmpegProcess) {
        state.withLockedValue { state in
            if state.recording?.process === process { state.recording?.stopping = true }
        }
        process.stop()
    }

    private func exited(_ status: FfmpegExitStatus, process: FfmpegProcess) {
        let expected = state.withLockedValue { state -> Bool in
            guard state.recording?.process === process else { return true }
            defer { state.recording = nil }
            return state.recording?.stopping ?? true
        }
        if !expected, let code = status.exitCode, code != 0, code != 255 {
            log.warning("FFmpeg recording process exited with code \(code).")
        }
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        log.info("Recording stream closed: \(streamID), reason \(reason.map { String($0.rawValue) } ?? "none").")
        if let reason { Self.logReason(reason.rawValue, log) }
        let process = state.withLockedValue { state -> FfmpegProcess? in
            guard state.recording?.streamID == streamID else { return nil }
            state.recording?.stopping = true
            return state.recording?.process
        }
        process?.stop()
    }

    /// The original's line for each close reason (section 9.2).
    static func logReason(_ reason: Int, _ log: CameraLog) {
        switch reason {
        case 0: log.info("Recording ended normally.")
        case 1: log.warning("Recording ended with a generic error.")
        case 2: log.warning("Recording ended with a network error.")
        case 3: log.warning("Recording ended: insufficient resources.")
        case 4: log.warning("Recording ended: HomeKit is busy.")
        case 5: log.warning("Recording ended: insufficient buffer space.")
        case 6: log.warning("Recording ended: stream format incompatibility. Check the H.264 parameters of the camera.")
        case 7: log.warning("Recording ended: maximum recording time exceeded.")
        case 8: log.warning("Recording ended: storage is full.")
        default: log.warning("Recording ended for an unknown reason (\(reason)).")
        }
    }

    /// Ends the recording and the prebuffer: the plugin is stopping.
    func shutdown() {
        let process = state.withLockedValue { state -> FfmpegProcess? in
            state.recording?.stopping = true
            return state.recording?.process
        }
        process?.stop()
        prebuffer?.stop()
    }
}

/// A rolling buffer of the camera's source as fragmented MP4 (section 9.3), so a recording starts a few seconds before
/// the event: FFmpeg copies the source to its standard output, and the last 15 seconds of boxes are kept. One per camera
/// that asks for it (the original only ever ran the first camera's).
final class Prebuffer: @unchecked Sendable {
    static let window: Duration = .seconds(15)
    /// Boxes beyond this many bytes go first, whatever their age.
    static let maximumBytes = 64 * 1024 * 1024

    let video: CameraFFmpegPlugin.VideoConfig
    let log: CameraLog
    let tools: FFmpegTools

    private struct State {
        var process: FfmpegProcess?
        var reader = MP4BoxReader()
        var ftyp: MP4Box?
        var moov: MP4Box?
        var boxes: [(time: ContinuousClock.Instant, box: MP4Box)] = []
        var bytes = 0
        var listeners: [Int: AsyncStream<Data>.Continuation] = [:]
        var nextListener = 0
    }

    private let state = NIOLockedValueBox(State())

    init(video: CameraFFmpegPlugin.VideoConfig, log: CameraLog, tools: FFmpegTools) {
        self.video = video
        self.log = log
        self.tools = tools
    }

    struct StartFailure: Error, CustomStringConvertible {
        var description: String { "FFmpeg could not be started" }
    }

    /// Starts FFmpeg, unless it runs already. It is not restarted when it dies.
    func start() async throws {
        guard state.withLockedValue({ $0.process == nil }) else { return }
        let process = FfmpegProcess(tools.options, commandLineArgs: FFmpegArguments.prebuffer(video))
        let fresh = state.withLockedValue { state -> Bool in
            guard state.process == nil else { return false }
            state = State()
            state.process = process
            return true
        }
        guard fresh else { return }
        log.info("Prebuffer starting.")
        log.info("Prebuffer command: \(tools.executable) \(Masking.commandLine(process.commandLineArgs))")
        process.start()
        let listening = process.onStdout { [weak self] chunk in self?.received(chunk) } != nil
            && process.onceExit { [weak self] status in self?.ended(process, status: status) }
        guard listening else {
            ended(process, status: FfmpegExitStatus(exitCode: nil, signal: nil))
            throw StartFailure()
        }
    }

    private func received(_ chunk: Data) {
        let now = ContinuousClock.now
        let (live, listeners, failure) = state.withLockedValue { state -> ([Data], [AsyncStream<Data>.Continuation], (any Error)?) in
            let boxes: [MP4Box]
            do {
                boxes = try state.reader.push(chunk)
            } catch {
                return ([], [], error)
            }
            let listeners = Array(state.listeners.values)
            var live: [Data] = []
            for box in boxes {
                if state.ftyp == nil {
                    state.ftyp = box
                } else if state.moov == nil {
                    state.moov = box
                } else {
                    state.boxes.append((now, box))
                    state.bytes += box.data.count
                    if !listeners.isEmpty { live.append(box.data) }
                }
            }
            var drop = 0
            while drop < state.boxes.count, now - state.boxes[drop].time > Self.window || state.bytes > Self.maximumBytes {
                state.bytes -= state.boxes[drop].box.data.count
                drop += 1
            }
            if drop > 0 { state.boxes.removeFirst(drop) }
            return (live, listeners, nil)
        }
        if let failure {
            // The stream cannot be followed from here on: the prebuffer stops, and the next recording starts it again.
            log.error("Prebuffer: \(failure). Stopping it.")
            stop()
            return
        }
        // Whole boxes only: a recording that joins mid-chunk still reads a well-formed stream.
        for listener in listeners {
            for box in live { listener.yield(box) }
        }
    }

    private func ended(_ process: FfmpegProcess, status: FfmpegExitStatus) {
        let listeners = state.withLockedValue { state -> [AsyncStream<Data>.Continuation] in
            guard state.process === process else { return [] }
            defer { state = State() }
            return Array(state.listeners.values)
        }
        listeners.forEach { $0.finish() }
        log.info("Prebuffer ended (\(status)).")
    }

    /// What a recording reads: `ftyp`, `moov`, the buffered boxes of the last `duration` from the first `moof` among them,
    /// then the stream as it comes. nil until the prebuffer has its initialization boxes.
    func feed(duration: Duration) -> AsyncStream<Data>? {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(8192))
        let registered = state.withLockedValue { state -> Int? in
            guard let ftyp = state.ftyp, let moov = state.moov else { return nil }
            let since = ContinuousClock.now - duration
            let recent = state.boxes.drop { $0.time < since }.drop { $0.box.type != "moof" }
            // Under the lock, so the live boxes come after these; each box as it is, without copying them together.
            for box in [ftyp, moov] + recent.map(\.box) { continuation.yield(box.data) }
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            return state.nextListener
        }
        guard let registered else { return nil }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLockedValue { _ = $0.listeners.removeValue(forKey: registered) }
            self?.log.info("Prebuffer request ended.")
        }
        return stream
    }

    func stop() {
        let (process, listeners) = state.withLockedValue { state in
            defer { state = State() }
            return (state.process, Array(state.listeners.values))
        }
        listeners.forEach { $0.finish() }
        process?.stop()
    }
}
