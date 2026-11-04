import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// HomeKit Secure Video from an RTSP source, for camera plugins that have nothing better: an `FfmpegLivestreamProcess`
/// remuxes the source to fMP4 and keeps its last `prebufferLength` milliseconds (the timeshift), and each recording is an
/// `FfmpegRecordingProcess` fed with the initialization segment, the timeshift and the live segments that follow, read
/// back as HomeKit's packets. Without `keepsPrebuffer` the livestream runs only while a recording does (recordings then
/// start when the event is seen, with no seconds before it).
///
/// ```swift
/// let source = RTSPRecordingSource(options: ffmpegOptions, url: rtsp, codec: "h265", keepsPrebuffer: true)
/// source.start()
/// return source.recording(configuration, fps: 25)   // in handleRecordingStreamRequest
/// ```
public final class RTSPRecordingSource: Sendable {
    private struct State {
        var livestream: FfmpegLivestreamProcess?
        var listener: FfmpegEvent<Data>.Listener?
        /// Complete fragments (a moof and its mdat) with when they came.
        var fragments: [(data: Data, at: ContinuousClock.Instant)] = []
        var pendingMoof: Data?
        var recordings = 0
        var running = false
    }

    private let options: FfmpegOptions
    private let url: String
    private let codec: String
    private let prebufferLength: Duration
    private let keepsPrebuffer: Bool
    private let state = NIOLockedValueBox(State())
    /// Each fragment as it comes, to the recordings running.
    private let fragmentEvents = FfmpegEvent<Data>()

    public init(options: FfmpegOptions, url: String, codec: String = "h264", prebufferLength: Duration = .milliseconds(HKSV_FRAGMENT_LENGTH),
                keepsPrebuffer: Bool) {
        self.options = options
        self.url = url
        self.codec = codec
        self.prebufferLength = prebufferLength
        self.keepsPrebuffer = keepsPrebuffer
    }

    /// Starts the prebuffer, when it is kept, once HomeKit selected a recording configuration (the livestream's audio
    /// settings come from it); call it again when the configuration changes.
    public func start(_ configuration: CameraRecordingConfiguration) {
        state.withLockedValue { $0.running = true }
        if keepsPrebuffer { ensureLivestream(configuration) }
    }

    /// Stops the livestream and forgets the timeshift.
    public func stop() {
        let livestream = state.withLockedValue { state -> FfmpegLivestreamProcess? in
            state.running = false
            defer { state = State() }
            return state.livestream
        }
        livestream?.stop()
    }

    /// The timeshift's length in fragments, for tests.
    public var bufferedFragments: Int { state.withLockedValue { $0.fragments.count } }

    @discardableResult
    private func ensureLivestream(_ configuration: CameraRecordingConfiguration) -> FfmpegLivestreamProcess {
        if let running = state.withLockedValue({ $0.livestream }), running.isRunning { return running }
        // The source's audio is left out: recordings take it from their own encoder's silence otherwise.
        let livestream = FfmpegLivestreamProcess(options, recordingConfig: configuration,
                                                 livestreamOptions: FMp4LivestreamOptions(url: url, codec: codec, enableAudio: false))
        let listener = livestream.segmentEvents.on { [weak self] box in self?.received(box) }
        let previous = state.withLockedValue { state -> FfmpegLivestreamProcess? in
            defer {
                state.livestream = livestream
                state.listener = listener
                state.fragments = []
                state.pendingMoof = nil
            }
            return state.livestream
        }
        previous?.stop()
        livestream.start()
        return livestream
    }

    private func received(_ box: Data) {
        guard box.count >= BOX_HEADER_SIZE else { return }
        let type = box.subdata(in: (box.startIndex + 4)..<(box.startIndex + 8)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let fragment = state.withLockedValue { state -> Data? in
            if type == BOX_TYPE_MOOF {
                state.pendingMoof = box
                return nil
            }
            guard type == BOX_TYPE_MDAT, var moof = state.pendingMoof else { return nil }
            state.pendingMoof = nil
            moof.append(box)
            let now = ContinuousClock.now
            state.fragments.append((moof, now))
            // Keep what covers the prebuffer, starting at a keyframe.
            while state.fragments.count > 1, now - state.fragments[1].at >= prebufferLength { state.fragments.removeFirst() }
            while state.fragments.count > 1, !isKeyframe(state.fragments[0].data) { state.fragments.removeFirst() }
            if state.fragments.count > 64 { state.fragments.removeFirst(state.fragments.count - 64) }
            return moof
        }
        if let fragment { fragmentEvents.emit(fragment) }
    }

    /// A recording as HomeKit selected it: the timeshift then the live fragments, transcoded, until the stream is cancelled.
    public func recording(_ configuration: CameraRecordingConfiguration, fps: Int, enableAudio: Bool = false) -> AsyncThrowingStream<RecordingPacket, any Error> {
        let (packets, continuation) = AsyncThrowingStream.makeStream(of: RecordingPacket.self)
        let task = Task { [self] in
            state.withLockedValue { $0.recordings += 1 }
            let livestream = ensureLivestream(configuration)
            let recording = FfmpegRecordingProcess(options, recordingConfig: configuration,
                                                   fMp4Options: FMp4RecordingOptions(codec: codec, enableAudio: enableAudio, fps: fps))
            defer {
                recording.stop()
                let idle = state.withLockedValue { state -> Bool in
                    state.recordings -= 1
                    return state.recordings == 0
                }
                if idle, !keepsPrebuffer { stopLivestreamOnly() }
            }
            do {
                let initSegment = try await livestream.getInitSegment()
                let buffered = state.withLockedValue { $0.fragments.map(\.data) }
                // Live fragments queue up from here, so none is lost while the buffer is written.
                let (live, liveContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(32))
                let listener = fragmentEvents.on { liveContinuation.yield($0) }
                defer { fragmentEvents.off(listener) }
                recording.start()
                let writer = Task {
                    try await recording.writeStdin(initSegment)
                    for fragment in buffered { try await recording.writeStdin(fragment) }
                    for await fragment in live {
                        guard !Task.isCancelled else { break }
                        try await recording.writeStdin(fragment)
                    }
                }
                defer { writer.cancel() }
                for try await packet in recording.recordingPackets() {
                    continuation.yield(packet)
                    if packet.isLast { break }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return packets
    }

    private func stopLivestreamOnly() {
        let livestream = state.withLockedValue { state -> FfmpegLivestreamProcess? in
            defer {
                state.livestream = nil
                state.fragments = []
                state.pendingMoof = nil
            }
            return state.livestream
        }
        livestream?.stop()
    }
}
