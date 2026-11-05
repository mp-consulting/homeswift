import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A standalone battery camera (docs/clean-room/ReolinkBattery.md), Experimental: no HTTP API and no polling, a Baichuan
/// session opened only on demand (a live stream, a snapshot the cache cannot answer, the refresh after a wake push) and
/// closed 5 seconds after its last use; events by the camera's webhook, which needs no connection (6). Its state, the
/// battery and the last snapshot are kept, so a sleeping camera shows them rather than "No Response".
actor ReolinkBatteryHost {
    typealias Listener = @Sendable (ReolinkChannelState) -> Void

    /// What is kept between runs (2.3): the identity for Accessory Information while the camera sleeps, the battery.
    struct Record: Codable, Sendable, Equatable {
        var identity: ReolinkBatteryIdentity
        var battery: ReolinkBatteryReport?
        /// Whether the firmware has the webhook (`cmd_id` 806 answered); nil until asked.
        var webhookSupported: Bool?
    }

    /// How a webhook check ended (6.1).
    enum WebhookOutcome: Sendable, Equatable {
        case unsupported
        /// Another receiver's URL is set and the bridge does not take it over: its host.
        case taken(String)
        case current
        case subscribed
        case failed
    }

    /// The camera's timings (3.2, 3.3, 10), in seconds.
    static let idleClose: Double = 5
    static let loginSpacing: Double = 15
    static let connectTimeout: Double = 4
    static let nonceTimeout: Double = 5
    static let snapshotBudget: Double = 10
    static let streamBudget: Double = 15
    /// A connection failing this soon after a wake push counts towards the "UDP only" warning (2.1), after 3 of them.
    static let wakeWindow: Double = 30
    static let udpWarningFailures = 3
    /// While a session is open, a snapshot younger than this is answered from the cache (it would keep the camera awake).
    static let awakeSnapshotCache: Double = 10
    /// A request with reason `event` wakes the camera for a snapshot older than this (7).
    static let eventSnapshotAge: Double = 60
    static let udpOnlyMessage = "this camera only talks over Reolink's UDP protocol, which Homeswift does not support yet; add it to a Reolink Home Hub instead"

    let device: ReolinkPlugin.Device
    private(set) var record: Record
    private let connect: BaichuanSession.Connect
    private let log: Logger
    private let timing: ReolinkTiming
    private let saveRecord: @Sendable (Record) -> Void
    private let imageFile: URL?
    private let motionTimeout: Double
    private let toJPEG: (@Sendable (_ codec: BcMediaCodec, _ keyframe: [UInt8]) async -> Data?)?
    private var listener: Listener?
    private var state = ReolinkChannelState()
    private var session: BaichuanSession?
    private var opening: Task<BaichuanSession, any Error>?
    private var users = 0
    private var idleTask: Task<Void, Never>?
    private var lastLogin: ContinuousClock.Instant?
    private var lastWake: ContinuousClock.Instant?
    private var wakeFailures = 0
    private var udpWarned = false
    private var credentialsLogged = false
    private var webhook: (url: String, path: String, takeOver: Bool)?
    private var webhookChecked = false
    private var motionOff: Task<Void, Never>?
    private var refreshing = false
    private var unknownLogged: Set<String> = []
    private var image: (data: Data, at: ContinuousClock.Instant)?
    private var fetching: Task<Data, any Error>?
    private var stopped = false
    /// How many sessions were opened (tests).
    private(set) var connections = 0

    init(device: ReolinkPlugin.Device, record: Record, connect: @escaping BaichuanSession.Connect, log: Logger, timing: ReolinkTiming,
         motionTimeout: Double = 30, imageFile: URL?, saveRecord: @escaping @Sendable (Record) -> Void,
         toJPEG: (@Sendable (BcMediaCodec, [UInt8]) async -> Data?)? = nil) {
        self.device = device
        self.record = record
        self.connect = connect
        self.log = log
        self.timing = timing
        self.motionTimeout = motionTimeout
        self.imageFile = imageFile
        self.saveRecord = saveRecord
        self.toJPEG = toJPEG
        if let battery = record.battery {
            state.batteryPercent = battery.percent
            state.charging = battery.charging
            state.batteryLow = battery.isLow
        }
        state.asleep = true
        // The last image of an earlier run is old: answered while the camera sleeps, replaced on the next wake.
        if let imageFile, let data = try? Data(contentsOf: imageFile), !data.isEmpty { image = (data, .now - .seconds(86_400)) }
    }

    var uid: String { record.identity.uid }
    var currentState: ReolinkChannelState { state }
    var isAwake: Bool { session != nil }
    var lastImage: Data? { image?.data }

    func setListener(_ listener: @escaping Listener) {
        self.listener = listener
        listener(state)
    }

    /// Where the camera posts its events, and whether another receiver's URL is replaced; checked on the next connection.
    func setWebhook(url: String, path: String, takeOver: Bool) {
        webhook = (url, path, takeOver)
        webhookChecked = false
    }

    func stop() async {
        stopped = true
        idleTask?.cancel()
        motionOff?.cancel()
        fetching?.cancel()
        if let session {
            self.session = nil
            await session.stop()
        }
    }

    // MARK: Connections (3.2, 3.3)

    /// Runs `body` on a session, opened if none is, within `budget` seconds for the whole; the session closes 5 s after
    /// its last use.
    func use<T: Sendable>(budget: Double, _ body: @escaping @Sendable (BaichuanSession) async throws -> T) async throws -> T {
        guard !stopped else { throw BaichuanError.closed }
        users += 1
        idleTask?.cancel()
        defer {
            users -= 1
            scheduleIdleClose()
        }
        let deadline = ContinuousClock.now + timing.timeout(budget)
        let session = try await Self.withDeadline(deadline) { try await self.openSession() }
        return try await Self.withDeadline(deadline) { try await body(session) }
    }

    private func openSession() async throws -> BaichuanSession {
        if let session, await session.isOpen { return session }
        session = nil
        if let opening { return try await opening.value }
        let task = Task { try await self.login() }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    private func login() async throws -> BaichuanSession {
        if let lastLogin {
            let wait = timing.seconds(Self.loginSpacing) - (ContinuousClock.now - lastLogin)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        guard !stopped else { throw BaichuanError.closed }
        lastLogin = .now
        connections += 1
        let session = BaichuanSession(host: device.host, port: device.baichuanPort ?? 9000, username: device.username, password: device.password,
                                      connect: connect, log: log, timing: timing, connectTimeout: Self.connectTimeout, nonceTimeout: Self.nonceTimeout,
                                      retriesWaking: true)
        do {
            try await session.openOnce()
        } catch {
            connectionFailed(error)
            throw error
        }
        wakeFailures = 0
        self.session = session
        state.asleep = false
        publish()
        Task { await self.consume(session) }
        if let webhook, !webhookChecked {
            webhookChecked = true
            Task { await self.checkWebhook(webhook) }
        }
        scheduleIdleClose()
        return session
    }

    private func connectionFailed(_ error: any Error) {
        if case BaichuanError.unauthorized = error {
            if !credentialsLogged { log.error("The camera refused the user name or password.") }
            credentialsLogged = true
            return
        }
        log.debug("The battery camera did not answer (asleep or out of reach): \(error)")
        if let lastWake, ContinuousClock.now - lastWake < timing.seconds(Self.wakeWindow) {
            wakeFailures += 1
            if wakeFailures >= Self.udpWarningFailures, !udpWarned {
                udpWarned = true
                log.warning("The camera woke up but refused TCP \(device.baichuanPort ?? 9000) \(wakeFailures) times: \(Self.udpOnlyMessage).")
            }
        }
    }

    private func scheduleIdleClose() {
        guard users == 0, session != nil else { return }
        idleTask?.cancel()
        let delay = timing.seconds(Self.idleClose)
        idleTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.closeIfIdle()
        }
    }

    private func closeIfIdle() async {
        guard users == 0, let session else { return }
        self.session = nil
        log.debug("Closing the idle connection: the camera may sleep again.")
        await session.stop()
    }

    private func consume(_ session: BaichuanSession) async {
        for await event in session.events {
            if case .push(let push) = event { apply(push) }
        }
        if self.session === session { self.session = nil }
    }

    /// Ends `body` at `deadline` (it is cancelled, not waited for), throwing `timeout`.
    static func withDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = NIOLockedValueBox<CheckedContinuation<T, any Error>?>(nil)
        let work = NIOLockedValueBox<Task<Void, Never>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                once.withLockedValue { $0 = continuation }
                let finish: @Sendable (Result<T, any Error>) -> Void = { result in once.withLockedValue { value in value?.resume(with: result); value = nil } }
                let task = Task {
                    do { finish(.success(try await body())) } catch { finish(.failure(error)) }
                }
                work.withLockedValue { $0 = task }
                Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    finish(.failure(BaichuanError.timeout))
                    task.cancel()
                }
            }
        } onCancel: {
            once.withLockedValue { value in value?.resume(throwing: CancellationError()); value = nil }
            work.withLockedValue { $0 }?.cancel()
        }
    }

    // MARK: Events (6.2, 6.3)

    /// A webhook body: false when it is another camera's.
    @discardableResult
    func handleWebhook(_ json: JSONValue) -> Bool {
        guard let uid = json["uid"]?.stringValue, uid.caseInsensitiveCompare(record.identity.uid) == .orderedSame else { return false }
        if let data = json["data"] {
            let event = data["event"]?.stringValue?.lowercased() ?? ""
            let reason = data["reason"]?.stringValue?.lowercased()
            switch event {
            case "wake":
                lastWake = .now
                state.asleep = false
                switch reason {
                case "pir": motionDetected()
                case "doorbell": ring()
                case "network", "other", nil: break
                case let reason?: logOnce("wake reason \(reason)")
                }
                refreshAfterWake()
            case "sleep":
                state.asleep = true
            case "test":
                log.info("The camera's event push works.")
            default:
                logOnce("event \(event)")
            }
            publish()
        } else if let command = json["cmd"].lenientInt, let xml = json["xml"]?.stringValue {
            var unknown: Set<String> = []
            for push in BaichuanEvents.parse(command: UInt32(clamping: command), xml: xml, unknown: &unknown) { apply(push) }
            for item in unknown { logOnce(item) }
        }
        return true
    }

    func apply(_ push: ReolinkPush) {
        switch push {
        case .alarm(_, let motion, let visitor, _):
            if motion == true { motionDetected() } else if motion == false { motionCleared() }
            if visitor == true { ring() }
        case .sleep(_, let asleep):
            state.asleep = asleep
        case .battery(_, let report):
            if let percent = report.percent { state.batteryPercent = percent }
            state.charging = report.charging
            state.batteryLow = report.isLow
            if record.battery != report {
                record.battery = report
                saveRecord(record)
            }
        default:
            return
        }
        publish()
    }

    private func logOnce(_ item: String) {
        guard unknownLogged.count < 64, unknownLogged.insert(item).inserted else { return }
        log.debug("Battery camera push: unknown \(item), ignored.")
    }

    private func publish() { listener?(state) }

    /// Motion on, and off again `motionTimeout` later: a sleeping camera sends no "motion stopped" (6.2).
    private func motionDetected() {
        state.motion = true
        motionOff?.cancel()
        let delay = timing.seconds(motionTimeout)
        motionOff = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.motionCleared()
        }
        publish()
    }

    private func motionCleared() {
        motionOff?.cancel()
        motionOff = nil
        guard state.motion else { return }
        state.motion = false
        publish()
    }

    /// A doorbell press: the visitor's rising edge, then its fall (the camera throttles repeats).
    private func ring() {
        state.visitor = true
        publish()
        state.visitor = false
        publish()
    }

    /// After a wake push with no session open: one connection reads the battery and refreshes the snapshot, then closes
    /// when idle (6.2).
    private func refreshAfterWake() {
        guard session == nil, !refreshing, !stopped else { return }
        refreshing = true
        Task {
            defer { self.refreshDone() }
            let result = try? await self.use(budget: Self.snapshotBudget) { session -> (ReolinkBatteryReport?, Data?) in
                let battery = try? await session.battery(channel: 0)
                let image = try? await session.snapshot(channel: 0, stream: .sub, timeout: Self.snapshotBudget)
                return (battery, image)
            }
            if let battery = result?.0 { self.apply(.battery(channel: 0, report: battery)) }
            if let image = result?.1 { self.store(image) }
        }
    }

    private func refreshDone() { refreshing = false }

    // MARK: Webhook (6.1)

    private func checkWebhook(_ webhook: (url: String, path: String, takeOver: Bool)) async {
        let outcome: WebhookOutcome
        do {
            outcome = try await use(budget: Self.snapshotBudget) { session in
                try await Self.subscribe(session, url: webhook.url, path: webhook.path, takeOver: webhook.takeOver)
            }
        } catch {
            webhookChecked = false
            log.debug("Could not check the camera's event push: \(error)")
            return
        }
        let supported = outcome != .unsupported
        if record.webhookSupported != supported {
            record.webhookSupported = supported
            saveRecord(record)
        }
        Self.report(outcome, log: log)
    }

    /// Reads the webhook and writes it when it is not the bridge's: another receiver's URL only with `takeOver`.
    static func subscribe(_ session: BaichuanSession, url: String, path: String, takeOver: Bool) async throws -> WebhookOutcome {
        guard let current = try await session.webhook() else { return .unsupported }
        if current.enabled, current.url == url { return .current }
        let ours = current.url.hasSuffix(path)
        if current.enabled, !current.url.isEmpty, !ours, !takeOver {
            return .taken(URLComponents(string: current.url)?.host ?? "another receiver")
        }
        return try await session.setWebhook(url: url) ? .subscribed : .failed
    }

    static func report(_ outcome: WebhookOutcome, log: Logger) {
        switch outcome {
        case .unsupported: log.warning("This camera's firmware has no event push (webhook): no motion or doorbell events reach HomeKit.")
        case .taken(let host):
            log.warning("The camera sends its events to another receiver (\(host), Home Assistant's Reolink integration, say), and it has one slot only: turn on \"Take over event push\" in its settings to use Homeswift's.")
        case .current: log.debug("Event push is set to this bridge.")
        case .subscribed: log.info("Event push set to this bridge.")
        case .failed: log.warning("The camera did not keep the event push address.")
        }
    }

    // MARK: Snapshots (7)

    /// A snapshot as HomeKit asks for one: the cache whenever it is enough (the camera asleep, a `periodic` request),
    /// the camera's `cmd_id` 109 otherwise.
    func snapshot(for request: SnapshotRequest) async throws -> Data {
        let stream: Baichuan.MediaStream = request.width <= 640 ? .sub : .main
        if let image {
            let age = ContinuousClock.now - image.at
            let refresh = isAwake ? age >= timing.seconds(Self.awakeSnapshotCache)
                : request.reason == .event && age >= timing.seconds(Self.eventSnapshotAge)
            guard refresh else { return image.data }
            return (try? await fetch(stream)) ?? image.data
        }
        // Never woken for a periodic request (7).
        guard isAwake || request.reason != .periodic else { throw HAPStatusError(.serviceCommunicationFailure) }
        do {
            return try await fetch(stream)
        } catch {
            log.debug("No snapshot: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    private func fetch(_ stream: Baichuan.MediaStream) async throws -> Data {
        if let fetching { return try await fetching.value }
        let task = Task { () async throws -> Data in
            do {
                return try await self.use(budget: Self.snapshotBudget) { session in
                    try await session.snapshot(channel: 0, stream: stream, timeout: Self.snapshotBudget)
                }
            } catch {
                // A camera that answered but has no `cmd_id` 109: the first I-frame of a short stream.
                guard self.isAwake, let toJPEG = self.toJPEG else { throw error }
                let (codec, keyframe) = try await self.firstKeyframe(.sub)
                guard let jpeg = await toJPEG(codec, keyframe), !jpeg.isEmpty else { throw error }
                return jpeg
            }
        }
        fetching = task
        defer { fetching = nil }
        let data = try await task.value
        store(data)
        return data
    }

    func store(_ data: Data) {
        image = (data, .now)
        if let imageFile { try? OwnerOnlyFile.write(data, to: imageFile) }
    }

    /// The first I-frame of a short stream start (7, the fallback).
    private func firstKeyframe(_ stream: Baichuan.MediaStream) async throws -> (BcMediaCodec, [UInt8]) {
        try await use(budget: Self.snapshotBudget) { session in
            let (events, input) = AsyncStream.makeStream(of: BaichuanBinaryEvent.self)
            let counter = try await session.startMedia(channel: 0, stream: stream, timeout: Self.snapshotBudget) { input.yield($0) }
            var parser = BcMediaParser()
            var found: (BcMediaCodec, [UInt8])?
            loop: for await event in events {
                guard case .data(_, let payload) = event else { break }
                for frame in try parser.push(payload) {
                    if case .video(let codec, true, _, let data) = frame {
                        found = (codec, data)
                        break loop
                    }
                }
            }
            input.finish()
            await session.stopMedia(channel: 0, stream: stream, counter: counter)
            guard let found else { throw BaichuanError.timeout }
            return found
        }
    }

    // MARK: Live streams (5)

    /// Starts the camera's media and remuxes it (5.3): the feed once the first I-frame came, within 15 s. The session
    /// stays open until the feed is stopped; a snapshot is taken then, while the camera is still up.
    func liveFeed(sub: Bool, audio: Bool) async throws -> ReolinkMediaFeed {
        guard !stopped else { throw BaichuanError.closed }
        users += 1
        idleTask?.cancel()
        let stream: Baichuan.MediaStream = sub ? .sub : .main
        let deadline = ContinuousClock.now + timing.timeout(Self.streamBudget)
        do {
            let session = try await Self.withDeadline(deadline) { try await self.openSession() }
            let (events, input) = AsyncStream.makeStream(of: BaichuanBinaryEvent.self)
            let counter = try await Self.withDeadline(deadline) {
                try await session.startMedia(channel: 0, stream: stream, timeout: Self.streamBudget) { input.yield($0) }
            }
            let (output, out) = AsyncThrowingStream.makeStream(of: Data.self)
            let (starts, started) = AsyncThrowingStream.makeStream(of: FirstFrame.self)
            let pump = Task {
                var parser = BcMediaParser()
                var muxer = BcMediaMuxer(audio: audio)
                var size: (Int, Int)?
                var announced = false
                for await event in events {
                    guard case .data(_, let payload) = event else { break }
                    do {
                        for frame in try parser.push(payload) {
                            if case .info(let width, let height, _) = frame { size = (width, height) }
                            let bytes = muxer.push(frame)
                            if !announced, let codec = muxer.codec {
                                announced = true
                                started.yield(FirstFrame(codec: codec, fps: muxer.fps, width: size?.0, height: size?.1))
                                started.finish()
                            }
                            if !bytes.isEmpty { out.yield(Data(bytes)) }
                        }
                    } catch {
                        out.finish(throwing: error)
                        started.finish(throwing: error)
                        return
                    }
                }
                out.finish()
                started.finish(throwing: BaichuanError.closed)
            }
            let first: FirstFrame
            do {
                first = try await Self.withDeadline(deadline) {
                    for try await first in starts { return first }
                    throw BaichuanError.closed
                }
            } catch {
                pump.cancel()
                input.finish()
                await session.stopMedia(channel: 0, stream: stream, counter: counter)
                throw error
            }
            let stopped = NIOLockedValueBox(false)
            let stop: @Sendable () async -> Void = { [weak self] in
                guard stopped.withLockedValue({ value in defer { value = true }; return !value }) else { return }
                pump.cancel()
                input.finish()
                await session.stopMedia(channel: 0, stream: stream, counter: counter)
                await self?.feedEnded()
            }
            let fallback = sub ? (640, 360) : (2560, 1440)
            let size = (first.width ?? fallback.0, first.height ?? fallback.1)
            log.debug("Live \(sub ? "sub" : "main") stream: \(first.codec.rawValue) \(size.0) x \(size.1)\(first.fps.map { " at \($0) fps" } ?? "").")
            return ReolinkMediaFeed(stream: ReolinkStream(codec: first.codec.rawValue, width: size.0, height: size.1, fps: first.fps ?? 15), data: output, stop: stop)
        } catch {
            users -= 1
            scheduleIdleClose()
            throw error
        }
    }

    private struct FirstFrame: Sendable {
        var codec: BcMediaCodec
        var fps: Int?
        var width: Int?
        var height: Int?
    }

    /// A feed stopped: the snapshot is refreshed on the open session, then it closes when idle.
    private func feedEnded() {
        users -= 1
        guard !stopped, session != nil else {
            scheduleIdleClose()
            return
        }
        Task { _ = try? await self.fetch(.sub) }
        scheduleIdleClose()
    }
}
