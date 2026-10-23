import Foundation

/// The timeshift buffer behind HomeKit Secure Video (`ProtectTimeshiftBuffer`): the last seconds of a
/// camera's livestream, kept as fMP4 segments so an event recording starts with the moments before the
/// motion, and so live streams and snapshots start from video already at hand.
@ProtectActor
final class ProtectTimeshiftBuffer {
    private let camera: ProtectCamera
    private var segments: [Data] = []
    private(set) var isStarted = false
    private(set) var isTransmitting = false
    private(set) var segmentLength = ProtectSettings.segmentResolution
    private var livestream: ProtectLivestream?
    private var listener: ProtectLivestreamListener?
    private var rtspEntry: RtspEntry?
    private var segmentCount = 1.0
    /// The recording delegate's listener (`on('segment')`): the buffer, then the livestream as it arrives.
    var onSegment: (@ProtectActor (Data) -> Void)?
    /// The recording's fragment length, which bounds the segment length.
    var fragmentLength: () -> Int? = { nil }

    init(camera: ProtectCamera) {
        self.camera = camera
    }

    private var log: ProtectLog { camera.log }

    private func handle(_ event: ProtectLivestream.Event) {
        switch event {
        case .close:
            // A restart closes the connection on purpose.
            if isRestarting { return }
            log.error("\(camera.hasFeature("Debug.Video.HKSV.UseRtsp") ? "RTSP" : "Livestream API") connection closed by the controller. Retrying shortly.")
        case .segment(let segment):
            if isTransmitting { onSegment?(segment) }
            segments.append(segment)
            if Double(segments.count) > segmentCount { segments.removeFirst() }
        default:
            break
        }
    }

    /// Starts buffering a stream. False when the livestream API does not answer.
    func start(_ entry: RtspEntry) async -> Bool {
        if isStarted { _ = stop() }
        // The segment length stays between 100 ms and 1.5 s, and at most half a recording fragment.
        if let fragmentLength = fragmentLength(), fragmentLength > 0,
           segmentLength < 100 || segmentLength > 1500 || Double(segmentLength) > Double(fragmentLength) / 2 {
            segmentLength = ProtectSettings.segmentResolution
        }
        segments = []
        guard let livestream = camera.livestream.acquire(entry) else { return false }
        self.livestream = livestream
        listener?.cancel()
        listener = ProtectLivestreamListener(livestream) { [weak self] event in self?.handle(event) }
        guard await camera.livestream.start(entry, segmentLength: segmentLength) else {
            listener?.cancel()
            listener = nil
            return false
        }
        rtspEntry = entry
        isStarted = true
        guard await getInitSegment() != nil else {
            _ = stop()
            return false
        }
        return true
    }

    /// Stops buffering.
    @discardableResult
    func stop() -> Bool {
        if isStarted {
            if let rtspEntry { camera.livestream.stop(rtspEntry) }
            listener?.cancel()
            listener = nil
        }
        segments = []
        isStarted = false
        livestream = nil
        rtspEntry = nil
        return true
    }

    /// Restarts the livestream connection (after a recording that produced nothing).
    func restart() {
        if let rtspEntry { camera.livestream.restart(rtspEntry) }
        segments = []
    }

    /// Starts sending the buffer and then the livestream to `onSegment`.
    func transmitStart() async -> Bool {
        var started = true
        if !isStarted, let rtspEntry { started = await start(rtspEntry) }
        guard started, let initSegment = livestream?.initSegment else {
            log.error("Unable to connect to the Protect livestream API — usually occurs when the Protect controller or devices reboot. Retrying shortly.")
            return false
        }
        onSegment?(segments.reduce(initSegment, +))
        isTransmitting = true
        return true
    }

    @discardableResult
    func transmitStop() -> Bool {
        isTransmitting = false
        return true
    }

    /// The fMP4 initialization segment, waiting up to two seconds for it.
    func getInitSegment() async -> Data? {
        guard let livestream else { return nil }
        if let initSegment = livestream.initSegment { return initSegment }
        let log = self.log
        return await protectTimeout(milliseconds: ProtectSettings.livestreamInitSegmentTimeout) {
            do {
                return try await livestream.getInitSegment()
            } catch {
                log.debug("Unable to retrieve the fMP4 initialization segment: \(error)")
                return nil
            }
        }
    }

    /// The initialization segment and the last `duration` milliseconds of video, or nil when there is none.
    func getLast(_ duration: Int) -> Data? {
        guard duration != 0 else { return nil }
        let start = Double(duration) / Double(segmentLength)
        if start >= Double(segments.count) { return buffer }
        guard let initSegment = livestream?.initSegment, !segments.isEmpty else { return nil }
        // `slice(-start)`: a fraction of a segment takes them all, as in JavaScript.
        let count = Int(start)
        return (count == 0 ? segments : Array(segments.suffix(count))).reduce(initSegment, +)
    }

    /// The initialization segment and the whole buffer.
    var buffer: Data? {
        guard let initSegment = livestream?.initSegment, !segments.isEmpty else { return nil }
        return segments.reduce(initSegment, +)
    }

    var isRestarting: Bool { rtspEntry.map { camera.livestream.isRestarting($0) } ?? false }

    /// Milliseconds of video buffered.
    var time: Int { segments.count * segmentLength }

    /// Milliseconds the buffer keeps.
    var configuredDuration: Int {
        get { Int(segmentCount * Double(segmentLength)) }
        set { segmentCount = max(Double(newValue) / Double(segmentLength), 1) }
    }
}
