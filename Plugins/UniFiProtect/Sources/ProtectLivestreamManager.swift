import Foundation
import HomeswiftPlugin

/// The livestream API sessions of a camera, shared by their consumers (`LivestreamManager`): the timeshift
/// buffer and live streams use one session per channel and lens, started by the first and stopped by the
/// last. A watchdog restarts a session that stops delivering segments, with a growing backoff, and, with
/// `Device.SelfHealing`, reboots a camera whose livestream keeps failing.
///
/// The Homebridge plugin's debug-only `Debug.Video.HKSV.UseRtsp` (an FFmpeg process reading RTSP instead of
/// the livestream API) is not ported.
@ProtectActor
final class ProtectLivestreamManager {
    private weak var camera: ProtectCamera?
    private var livestreams: [String: ProtectLivestream] = [:]
    private var listeners: [String: ProtectLivestreamListener] = [:]
    private var generation: [String: Int] = [:]
    private var restartCount = 0
    private var restartDelay: [String: Int] = [:]
    private var restarting: [String: Bool] = [:]
    private var subscribers: [String: Int] = [:]
    private var startTime: [String: ContinuousClock.Instant] = [:]
    private var watchdogs: Set<String> = []
    /// When each session last delivered a segment: the watchdog looks at it when it fires rather than
    /// being re-armed (a new task) for every segment.
    private var lastSegment: [String: ContinuousClock.Instant] = [:]
    /// A first start in flight, which consumers arriving meanwhile wait for instead of starting the
    /// session again (and killing the first one's).
    private var starting: [String: Task<Bool, Never>] = [:]

    init(camera: ProtectCamera) {
        self.camera = camera
    }

    /// The channel and lens of an entry: a second lens always uses channel 0 of the livestream API.
    nonisolated static func index(_ entry: RtspEntry) -> (channel: Int, index: String, lens: Int?) {
        let channel = entry.lens == nil ? entry.channel.id : 0
        return (channel, String(channel) + (entry.lens.map { "." + String($0) } ?? ""), entry.lens)
    }

    private func watchdogKey(_ camera: ProtectCamera, _ index: String) -> String { camera.id + ".Livestream." + index }

    /// The session of this entry, created when needed (not started).
    func acquire(_ entry: RtspEntry) -> ProtectLivestream? {
        guard let camera else { return nil }
        let index = Self.index(entry).index
        if let livestream = livestreams[index] { return livestream }
        subscribers[index] = 0
        let livestream = camera.api.createLivestream(log: camera.log)
        livestreams[index] = livestream
        return livestream
    }

    func isRestarting(_ entry: RtspEntry) -> Bool { restarting[Self.index(entry).index] ?? false }

    /// The number of consumers of an entry's session.
    func subscriberCount(_ entry: RtspEntry) -> Int { subscribers[Self.index(entry).index] ?? 0 }

    /// Starts the session for its first consumer and counts the others. Consumers that come while the first
    /// start is under way share it.
    func start(_ entry: RtspEntry, segmentLength: Int = ProtectSettings.segmentResolution) async -> Bool {
        let index = Self.index(entry).index
        guard livestreams[index] != nil else { return false }
        if (subscribers[index] ?? 0) == 0 {
            let first: Task<Bool, Never>
            if let pending = starting[index] {
                first = pending
            } else {
                first = Task { await self.startSession(entry, segmentLength: segmentLength) }
                starting[index] = first
            }
            let started = await first.value
            if starting[index] == first { starting[index] = nil }
            guard started, livestreams[index] != nil else { return false }
        }
        subscribers[index, default: 0] += 1
        return true
    }

    /// The first start of a session: the livestream, its listener and its watchdog.
    private func startSession(_ entry: RtspEntry, segmentLength: Int) async -> Bool {
        guard let camera else { return false }
        let (channel, index, lens) = Self.index(entry)
        guard let livestream = livestreams[index] else { return false }
        let options = ProtectLivestream.Options(chunkSize: 16384, emitTimestamps: true, lens: lens ?? 0, requestId: camera.name + ":" + index, segmentLength: segmentLength)
        guard await livestream.start(cameraID: camera.ufp.id, channel: channel, options: options) else {
            camera.log.error("Unable to access the Protect livestream API: this is typically due to the Protect controller or camera rebooting.")
            return false
        }
        // Shut down while it started.
        guard livestreams[index] === livestream else {
            livestream.stop()
            return false
        }
        if generation[index] == nil { generation[index] = 0 }
        restartDelay[index] = ProtectSettings.livestreamRestartInterval
        restarting[index] = false
        startTime[index] = ContinuousClock.now
        lastSegment[index] = ContinuousClock.now
        listeners[index]?.cancel()
        listeners[index] = ProtectLivestreamListener(livestream) { [weak self] event in
            guard case .segment = event else { return }
            self?.segmentArrived(index)
        }
        armWatchdog(index, entry: entry, segmentLength: segmentLength)
        return true
    }

    /// A segment arrived: a session healthy for a while resets the backoff, and the watchdog learns it was
    /// alive at this time.
    private func segmentArrived(_ index: String) {
        guard let camera else { return }
        let now = ContinuousClock.now
        lastSegment[index] = now
        if let start = startTime[index], now - start > camera.timers.duration(milliseconds: ProtectSettings.livestreamOfflineRetryInterval) {
            restartCount = 0
            restartDelay[index] = ProtectSettings.livestreamRestartInterval
        }
    }

    /// Arms the watchdog that restarts a session that went quiet. When it fires after a segment came, it
    /// waits again for what is left of the timeout from that segment: the effect of re-arming on every
    /// segment, with one timer per timeout instead of one per segment.
    private func armWatchdog(_ index: String, entry: RtspEntry, segmentLength: Int, delay: Int = ProtectSettings.livestreamTimeout, retry: Bool = false) {
        guard let camera else { return }
        watchdogs.insert(index)
        let armed = ContinuousClock.now
        camera.timers.reset(watchdogKey(camera, index), after: delay) { [weak self] in
            guard let self, let camera = self.camera else { return }
            // A healthy session, on the regular watchdog: wait for the rest of the timeout from its last segment.
            if !retry, let last = self.lastSegment[index], last > armed {
                let timeout = camera.timers.duration(milliseconds: ProtectSettings.livestreamTimeout)
                let left = timeout - (ContinuousClock.now - last)
                if left > .zero {
                    let milliseconds = Int(left.components.seconds * 1000) + Int(left.components.attoseconds / 1_000_000_000_000_000)
                    self.armWatchdog(index, entry: entry, segmentLength: segmentLength,
                                     delay: max(1, Int((Double(milliseconds) / camera.timers.timeScale).rounded(.up))))
                    return
                }
            }
            self.watchdogs.remove(index)
            Task { await self.restart(index, entry: entry, segmentLength: segmentLength, retry: retry) }
        }
    }

    /// Restarts the session of an entry now (`emit('restart')`: the timeshift buffer asks after a failed recording).
    func restart(_ entry: RtspEntry) {
        let index = Self.index(entry).index
        guard livestreams[index] != nil else { return }
        Task { await restart(index, entry: entry, segmentLength: ProtectSettings.segmentResolution, retry: false) }
    }

    private func restart(_ index: String, entry: RtspEntry, segmentLength: Int, retry: Bool) async {
        guard let camera, listeners[index] != nil else { return }
        if restarting[index] == true, !retry { return }
        let currentGeneration = generation[index]
        guard let livestream = livestreams[index] else { return }
        let isStale = { [weak self] in self == nil || self?.generation[index] != currentGeneration || self?.livestreams[index] !== livestream }
        restarting[index] = true
        camera.timers.cancel(watchdogKey(camera, index))
        watchdogs.remove(index)
        livestream.stop()
        let offline = await camera.api.bootstrap == nil
        let throttled = await camera.api.isThrottled
        if offline || throttled || !camera.isOnline {
            armWatchdog(index, entry: entry, segmentLength: segmentLength, delay: ProtectSettings.livestreamOfflineRetryInterval, retry: true)
            return
        }
        if camera.hasFeature("Device.SelfHealing") {
            restartCount += 1
            if restartCount > 10 {
                restartCount = 0
                camera.log.warning("Restarting the camera to reset it's connection to the livestream API.")
                let url = await camera.api.endpoint(modelKey: camera.ufp.modelKey) + "/" + camera.ufp.id + "/reboot"
                let response = await camera.api.retrieve(url, method: "POST", body: Data("{}".utf8))
                if isStale() { return }
                guard response?.isSuccess == true else {
                    camera.log.error("Unable to restart the camera.")
                    armWatchdog(index, entry: entry, segmentLength: segmentLength, delay: ProtectSettings.livestreamOfflineRetryInterval, retry: true)
                    return
                }
            }
        }
        camera.log.warning("Reconnecting to the livestream API.")
        // Time for a reboot or a stuck session on the controller to clear.
        let delay = (Double.random(in: 0..<3) + Double(restartDelay[index] ?? ProtectSettings.livestreamRestartInterval)) * 1000
        await camera.timers.sleep(Int(delay))
        if isStale() { return }
        let (channel, _, lens) = Self.index(entry)
        _ = await livestream.start(cameraID: camera.ufp.id, channel: channel,
                                   options: .init(lens: lens ?? 0, requestId: camera.name + ":" + index, segmentLength: segmentLength))
        if isStale() {
            livestream.stop()
            return
        }
        startTime[index] = ContinuousClock.now
        lastSegment[index] = nil
        armWatchdog(index, entry: entry, segmentLength: segmentLength)
        let interval = ProtectSettings.livestreamRestartInterval
        restartDelay[index] = min((restartDelay[index] ?? interval) + interval / 2, interval * 3)
        restarting[index] = false
    }

    /// One consumer is done; the last one stops the session.
    func stop(_ entry: RtspEntry) {
        let index = Self.index(entry).index
        // Nobody counted: a stray stop must not end the session of the others.
        guard (subscribers[index] ?? 0) > 0 else { return }
        let remaining = (subscribers[index] ?? 0) - 1
        subscribers[index] = remaining
        guard remaining <= 0 else { return }
        generation[index] = (generation[index] ?? 0) + 1
        livestreams[index]?.stop()
        listeners.removeValue(forKey: index)?.cancel()
        if let camera { camera.timers.cancel(watchdogKey(camera, index)) }
        watchdogs.remove(index)
        lastSegment[index] = nil
        subscribers[index] = 0
    }

    /// Stops every session and invalidates restarts in flight.
    func shutdown() {
        for index in livestreams.keys {
            if let camera { camera.timers.cancel(watchdogKey(camera, index)) }
        }
        for listener in listeners.values { listener.cancel() }
        for livestream in livestreams.values {
            livestream.removeAllObservers()
            livestream.stop()
        }
        for (index, value) in generation { generation[index] = value + 1 }
        livestreams = [:]
        listeners = [:]
        watchdogs = []
        restartDelay = [:]
        restarting = [:]
        startTime = [:]
        lastSegment = [:]
        subscribers = [:]
    }
}
