import Foundation
import NIOConcurrencyHelpers

// The helpers of the camera code (protect-utils.ts and homebridge-plugin-utils' util.ts): bit rates and
// recording durations as the plugin logs them, the segment queue that feeds FFmpeg, timeouts, and livestream
// events delivered in order on the plugin's actor.

/// `formatBps`: `500 bps`, `2.5 kbps`, `3 Mbps`.
func formatBps(_ value: Double) -> String {
    func formatted(_ amount: Double) -> String {
        amount.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", amount) : String(format: "%.1f", amount)
    }
    if value < 1000 { return (value == value.rounded() ? String(Int(value)) : String(value)) + " bps" }
    if value < 1_000_000 { return formatted(value / 1000) + " kbps" }
    return formatted(value / 1_000_000) + " Mbps"
}

/// `formatRecordingDuration`: `0.5`, `12` seconds, `1:05` minutes, `01:00:05` hours.
func formatRecordingDuration(_ recordedSeconds: Double) -> (time: String, unit: String) {
    var recordedTime = ""
    let hours = Int((recordedSeconds / 3600).rounded(.down))
    let minutes = Int((recordedSeconds.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down))
    let seconds = Int(recordedSeconds.truncatingRemainder(dividingBy: 3600).truncatingRemainder(dividingBy: 60).rounded(.down))
    func javaScript(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
    if recordedSeconds < 1 {
        recordedTime = javaScript(recordedSeconds)
    } else if recordedSeconds < 60 {
        recordedTime = String(Int(recordedSeconds.rounded(.toNearestOrAwayFromZero)))
    } else {
        if hours > 9 {
            recordedTime = String(hours) + ":"
        } else if hours > 0 {
            recordedTime = "0" + String(hours) + ":"
        }
        if minutes > 9 {
            recordedTime += String(minutes) + ":"
        } else if minutes > 0 {
            recordedTime += (hours > 0 ? "0" : "") + String(minutes) + ":"
        } else if hours > 0 {
            recordedTime += "00:"
        }
        if !recordedTime.isEmpty, seconds < 10 {
            recordedTime += "0" + String(seconds)
        } else {
            recordedTime += seconds != 0 ? String(seconds) : javaScript(recordedSeconds)
        }
    }
    let unit = switch recordedTime.split(separator: ":", omittingEmptySubsequences: false).count - 1 {
    case 1: "minute"
    case 2: "hour"
    default: "second"
    }
    return (recordedTime, unit)
}

/// `runWithTimeout`: the operation's result, or nil when it takes longer than `milliseconds`. The operation
/// is not cancelled, as in the Homebridge plugin: it finishes on its own.
func protectTimeout<T: Sendable>(milliseconds: Int, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumed = NIOLockedValueBox(false)
        let resume: @Sendable (T?) -> Void = { value in
            let first = resumed.withLockedValue { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        let timeout = Task {
            try? await Task.sleep(for: .milliseconds(max(milliseconds, 0)))
            resume(nil)
        }
        Task {
            let value = await operation()
            timeout.cancel()
            resume(value)
        }
    }
}

/// `createSegmentQueueProcessor`: writes fMP4 segments to an FFmpeg process one after the other, waiting for
/// it to take each (backpressure), and drops the oldest when FFmpeg falls behind by more than `maxLength`.
@ProtectActor
final class ProtectSegmentQueue {
    private let process: @ProtectActor () -> (any ProtectFfmpegProcess)?
    private let onWritten: (@ProtectActor () -> Void)?
    private let log: ProtectLog?
    private let maxLength: Int
    private var queue: [Data] = []
    private var dropped = 0
    private var isWriting = false

    init(maxLength: Int = ProtectSettings.segmentQueueMaxLength, log: ProtectLog? = nil, process: @escaping @ProtectActor () -> (any ProtectFfmpegProcess)?,
         onWritten: (@ProtectActor () -> Void)? = nil) {
        self.maxLength = max(maxLength, 1)
        self.log = log
        self.process = process
        self.onWritten = onWritten
    }

    /// Queues a segment and writes what is queued.
    func push(_ segment: Data) {
        queue.append(segment)
        if queue.count > maxLength {
            queue.removeFirst()
            if dropped % 100 == 0 {
                log?.debug("FFmpeg is not keeping up with the livestream: discarded \(dropped + 1) queued segment(s) beyond the \(maxLength) segment queue limit.")
            }
            dropped += 1
        }
        drain()
    }

    var count: Int { queue.count }

    private func drain() {
        guard !isWriting, !queue.isEmpty else { return }
        isWriting = true
        Task { @ProtectActor in
            while !self.queue.isEmpty {
                let segment = self.queue.removeFirst()
                guard let process = self.process() else { break }
                do {
                    try await process.writeStdin(segment)
                    self.onWritten?()
                } catch {
                    // FFmpeg is gone: nothing more will be read.
                    self.queue.removeAll()
                    break
                }
            }
            self.isWriting = false
        }
    }
}

/// The events of a livestream, delivered in order on the plugin's actor (the Homebridge plugin's synchronous
/// `on('segment')` listeners).
@ProtectActor
final class ProtectLivestreamListener {
    private let livestream: ProtectLivestream
    private let token: Int
    private let continuation: AsyncStream<ProtectLivestream.Event>.Continuation
    private var task: Task<Void, Never>?

    init(_ livestream: ProtectLivestream, _ handler: @escaping @ProtectActor (ProtectLivestream.Event) -> Void) {
        self.livestream = livestream
        let (events, continuation) = AsyncStream.makeStream(of: ProtectLivestream.Event.self)
        self.continuation = continuation
        token = livestream.observe { event in continuation.yield(event) }
        task = Task { @ProtectActor in
            for await event in events { handler(event) }
        }
    }

    /// Stops listening (`off`).
    func cancel() {
        livestream.removeObserver(token)
        continuation.finish()
        task?.cancel()
        task = nil
    }
}
