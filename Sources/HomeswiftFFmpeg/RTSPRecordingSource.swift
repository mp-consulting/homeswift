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
    /// A complete fragment (a moof and its mdat), numbered in the order it came.
    private struct Fragment: Sendable {
        var number: Int
        var data: Data
        var at: ContinuousClock.Instant
        var isKeyframe: Bool
    }

    private struct State {
        var livestream: FfmpegLivestreamProcess?
        /// The configuration `livestream` was made for.
        var configuration: CameraRecordingConfiguration?
        var fragments: [Fragment] = []
        var nextNumber = 0
        var pendingMoof: Data?
        var recordings = 0
    }

    private let options: FfmpegOptions
    private let url: String
    private let codec: String
    private let prebufferLength: Duration
    private let keepsPrebuffer: Bool
    private let state = NIOLockedValueBox(State())
    /// Each fragment as it comes, to the recordings running.
    private let fragmentEvents = FfmpegEvent<Fragment>()

    public init(options: FfmpegOptions, url: String, codec: String = "h264", prebufferLength: Duration = .milliseconds(HKSV_FRAGMENT_LENGTH),
                keepsPrebuffer: Bool) {
        self.options = options
        self.url = url
        self.codec = codec
        self.prebufferLength = prebufferLength
        self.keepsPrebuffer = keepsPrebuffer
    }

    /// Starts the prebuffer, when it is kept, once HomeKit selected a recording configuration (the livestream's audio
    /// settings come from it); call it again when the configuration changes, which restarts it.
    public func start(_ configuration: CameraRecordingConfiguration) {
        if keepsPrebuffer { ensureLivestream(configuration) }
    }

    /// Stops the livestream and forgets the timeshift (a recording still running keeps its count, so the livestream
    /// it restarts stops with it).
    public func stop() {
        let livestream = state.withLockedValue { state -> FfmpegLivestreamProcess? in
            defer {
                state.livestream = nil
                state.configuration = nil
                state.fragments = []
                state.pendingMoof = nil
            }
            return state.livestream
        }
        livestream?.stop()
    }

    /// The livestream for `configuration`: the one already there (running, or starting for another caller), else a new
    /// one, made and stored under the lock so two callers never start two.
    @discardableResult
    private func ensureLivestream(_ configuration: CameraRecordingConfiguration) -> FfmpegLivestreamProcess {
        let (livestream, previous, isNew) = state.withLockedValue { state -> (FfmpegLivestreamProcess, FfmpegLivestreamProcess?, Bool) in
            if let current = state.livestream, state.configuration == configuration { return (current, nil, false) }
            // The source's audio is left out: recordings take it from their own encoder's silence otherwise.
            let livestream = FfmpegLivestreamProcess(options, recordingConfig: configuration,
                                                     livestreamOptions: FMp4LivestreamOptions(url: url, codec: codec, enableAudio: false))
            let previous = state.livestream
            state.livestream = livestream
            state.configuration = configuration
            state.fragments = []
            state.pendingMoof = nil
            return (livestream, previous, true)
        }
        guard isNew else { return livestream }
        previous?.stop()
        livestream.segmentEvents.on { [weak self, weak livestream] box in
            guard let livestream else { return }
            self?.received(box, from: livestream)
        }
        livestream.start()
        // A livestream that ended is made again by the next caller.
        let forget: @Sendable (FfmpegExitStatus) -> Void = { [weak self, weak livestream] _ in
            self?.state.withLockedValue { state in
                if let livestream, state.livestream === livestream {
                    state.livestream = nil
                    state.configuration = nil
                }
            }
        }
        if !livestream.onceExit(forget) { forget(FfmpegExitStatus(exitCode: nil, signal: nil)) }
        return livestream
    }

    private func received(_ box: Data, from livestream: FfmpegLivestreamProcess) {
        guard box.count >= BOX_HEADER_SIZE else { return }
        let type = box.readUInt32BE(4)
        let fragment = state.withLockedValue { state -> Fragment? in
            // A livestream replaced or stopped may still deliver a box.
            guard state.livestream === livestream else { return nil }
            if type == BOX_TYPE_MOOF {
                state.pendingMoof = box
                return nil
            }
            guard type == BOX_TYPE_MDAT, var moof = state.pendingMoof else { return nil }
            state.pendingMoof = nil
            moof.append(box)
            let now = ContinuousClock.now
            let fragment = Fragment(number: state.nextNumber, data: moof, at: now, isKeyframe: isKeyframe(moof))
            state.nextNumber += 1
            state.fragments.append(fragment)
            // Keep what covers the prebuffer, starting at a keyframe.
            while state.fragments.count > 1, now - state.fragments[1].at >= prebufferLength { state.fragments.removeFirst() }
            while state.fragments.count > 1, !state.fragments[0].isKeyframe { state.fragments.removeFirst() }
            if state.fragments.count > 64 { state.fragments.removeFirst(state.fragments.count - 64) }
            return fragment
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
                if idle, !keepsPrebuffer { stop() }
            }
            do {
                let initSegment = try await livestream.getInitSegment()
                // Live fragments queue up from before the timeshift is read, so none falls between the two; those in
                // both are written once.
                let (live, liveContinuation) = AsyncStream.makeStream(of: Fragment.self, bufferingPolicy: .bufferingNewest(32))
                let listener = fragmentEvents.on { liveContinuation.yield($0) }
                defer { fragmentEvents.off(listener) }
                let buffered = state.withLockedValue { $0.fragments }
                let lastBuffered = buffered.last?.number ?? -1
                recording.start()
                let writer = Task {
                    try await recording.writeStdin(initSegment)
                    for fragment in buffered { try await recording.writeStdin(fragment.data) }
                    for await fragment in live where fragment.number > lastBuffered {
                        guard !Task.isCancelled else { break }
                        try await recording.writeStdin(fragment.data)
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
}
