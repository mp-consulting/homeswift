import Foundation
import Logging

/// One camera's live view, shared by everyone watching it: both lenses of a C675D come in one HD session, so the two
/// cameras' streams read the same feed. A battery camera is never reached unless someone watches
/// (docs/clean-room/TapoCamera.md, 12.3): the session opens with the first viewer and closes shortly after the last
/// one leaves; when the camera goes to standby during a view (about every 10 minutes, 8) the feed reconnects quietly,
/// at most `reconnectBudget` times in `reconnectWindow`, and ends the viewers' streams after that.
actor TapoCameraFeed {
    struct Timing: Sendable {
        /// How long the session outlives its last viewer: HomeKit stops and starts again when it changes the size.
        var linger: Duration = .seconds(3)
        /// The waits between reconnections after a session that failed to open.
        var retryDelay: Duration = .seconds(2)
        var reconnectBudget = 5
        var reconnectWindow: Duration = .seconds(600)
        /// How much MPEG-TS a snapshot is taken from, and how often one is taken while a session runs.
        var sampleBytes = 3 * 1024 * 1024
        var sampleInterval: Duration = .seconds(60)
    }

    private let name: String
    private let client: StreamdClient
    private let resolution: Streamd.Resolution
    private let timing: Timing
    private let logger: Logger
    /// Gets the start of each session, and a sample every `sampleInterval`, for the snapshots.
    private let onSample: @Sendable (Data) async -> Void

    private var viewers: [Int: AsyncStream<Data>.Continuation] = [:]
    private var nextViewer = 0
    private var runner: Task<Void, Never>?
    private var lingering: Task<Void, Never>?
    private var sessionsOpened = 0

    init(name: String, client: StreamdClient, resolution: Streamd.Resolution, timing: Timing = Timing(), logger: Logger,
         onSample: @escaping @Sendable (Data) async -> Void = { _ in }) {
        self.name = name
        self.client = client
        self.resolution = resolution
        self.timing = timing
        self.logger = logger
        self.onSample = onSample
    }

    var viewerCount: Int { viewers.count }
    var isConnected: Bool { runner != nil }
    /// How many sessions were opened with the camera: tests check the camera is left alone.
    var openedSessions: Int { sessionsOpened }

    /// A new viewer: the MPEG-TS from now on, until `leave` or the end of the feed.
    func join() -> (id: Int, stream: AsyncStream<Data>) {
        nextViewer += 1
        let id = nextViewer
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1024))
        viewers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.leave(id) }
        }
        lingering?.cancel()
        lingering = nil
        if runner == nil {
            runner = Task { await self.run() }
        }
        return (id, stream)
    }

    func leave(_ id: Int) {
        guard let continuation = viewers.removeValue(forKey: id) else { return }
        continuation.finish()
        guard viewers.isEmpty, runner != nil, lingering == nil else { return }
        let linger = timing.linger
        lingering = Task {
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            self.closeIfUnwatched()
        }
    }

    private func closeIfUnwatched() {
        lingering = nil
        guard viewers.isEmpty else { return }
        runner?.cancel()
        runner = nil
        logger.debug("\(name): nobody watches: the camera's session is closed.")
    }

    /// Ends every viewer and closes the session.
    func stop() {
        lingering?.cancel()
        lingering = nil
        runner?.cancel()
        runner = nil
        for continuation in viewers.values { continuation.finish() }
        viewers = [:]
    }

    private func broadcast(_ data: Data) {
        for continuation in viewers.values { continuation.yield(data) }
    }

    private var isWatched: Bool { !viewers.isEmpty }

    /// Opens sessions while anyone watches.
    private func run() async {
        var reconnects: [ContinuousClock.Instant] = []
        var first = true
        while !Task.isCancelled, isWatched {
            if !first {
                let now = ContinuousClock.now
                reconnects = reconnects.filter { now - $0 < timing.reconnectWindow } + [now]
                if reconnects.count > timing.reconnectBudget {
                    logger.warning("\(name): the camera keeps dropping the stream: giving up for now.")
                    break
                }
            }
            first = false
            let session: StreamdClient.Session
            do {
                sessionsOpened += 1
                session = try await client.open(resolution: resolution)
            } catch {
                if Task.isCancelled { break }
                if case StreamdError.invalidCredentials = error {
                    logger.error("\(name): \(error). Check the Tapo account's password (the camera's owner).")
                    break
                }
                logger.warning("\(name): could not open the live view: \(error)")
                try? await Task.sleep(for: timing.retryDelay)
                continue
            }
            logger.debug("\(name): live view opened\(session.sessionID.map { " (session \($0))" } ?? "").")
            await pump(session)
            await session.close()
            if Task.isCancelled || !isWatched { break }
            logger.info("\(name): the camera ended the live view (standby): reconnecting.")
        }
        // Done: whoever still watches is told the feed ended.
        if !Task.isCancelled {
            for continuation in viewers.values { continuation.finish() }
            viewers = [:]
            runner = nil
        }
    }

    /// Passes a session's MPEG-TS to the viewers, and its first bytes, then a sample a minute, to `onSample`.
    private func pump(_ session: StreamdClient.Session) async {
        var sample = Data()
        var sampling = true
        var nextSample = ContinuousClock.now + timing.sampleInterval
        let onSample = onSample
        do {
            for try await data in session.stream {
                if Task.isCancelled { return }
                broadcast(data)
                if sampling {
                    sample.append(data)
                    if sample.count >= timing.sampleBytes {
                        let taken = sample
                        sample = Data()
                        sampling = false
                        nextSample = ContinuousClock.now + timing.sampleInterval
                        Task { await onSample(taken) }
                    }
                } else if ContinuousClock.now >= nextSample {
                    sampling = true
                }
            }
        } catch {
            logger.debug("\(name): live view ended: \(error)")
        }
    }
}
