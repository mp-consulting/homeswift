import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's work once configured: log in, find the devices, put them in HomeKit, keep them fresh by
/// polling and over the WebSocket, and stay within the daily quota.
///
/// Polling follows `pollInterval`: the configured interval, at least an hour while the WebSocket pushes
/// changes, doubled per failed poll (up to four times), and at least an hour when fewer than 20 calls are
/// left today. A change from HomeKit triggers a poll `forceUpdateDelay` later, debounced, unless the
/// WebSocket will push it.
actor DaikinSession {
    /// Polling slows to this when few calls are left today.
    static let lowQuotaPoll: Duration = .seconds(3600)
    static let lowQuotaThreshold = 20
    /// Failed polls stretch the interval up to this many times.
    static let maxBackoffMultiplier = 4

    struct Timing: Sendable {
        var webSocketSafetyPoll: Duration = .seconds(3600)
        var rateLimitWriteInterval: Duration = .seconds(5)
        /// Overrides the configured intervals; for tests, where a minute is long.
        var pollInterval: Duration?
        var forceUpdateDelay: Duration?
    }

    /// What moves the session, in order: the API's quota reports, the WebSocket's events, writes from HomeKit.
    enum Event: Sendable {
        case rateLimit(RateLimitStatus)
        case webSocket(DaikinWebSocket.Event)
        case forceUpdate
    }

    let settings: DaikinSettings
    let mode: AuthMode
    let context: PluginContext
    let tokens: TokenClient
    let api: DaikinAPI
    let http: DaikinHTTP
    private let timing: Timing
    private let connectWebSocket: DaikinWebSocket.Connect?
    private var webSocket: DaikinWebSocket?
    private let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var eventTask: Task<Void, Never>?
    let logger: Logger

    private(set) var devices: [DaikinCloudDevice] = []
    private(set) var accessories: [String: DaikinAccessory] = [:]
    private(set) var lastFetched: Date?
    private(set) var isRunning = false

    private var pollTask: Task<Void, Never>?
    private var forceTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private(set) var pollingStarted = false
    private var shuttingDown = false
    private(set) var consecutiveFailures = 0
    private(set) var remainingDay: Int?
    private var webSocketHasConnected = false
    private(set) var webSocketConnected = false

    /// The quota the API reported last, with the mode and when: the settings page reads it here, and from the
    /// file after a restart.
    private(set) var rateLimit: JSONValue?
    private var pendingRateLimit: JSONValue?
    private var rateLimitWriteTask: Task<Void, Never>?
    private var lastRateLimitWrite = Date.distantPast
    /// For tests: counts polls.
    private(set) var pollCount = 0

    init(
        settings: DaikinSettings, context: PluginContext, logger: Logger, http: DaikinHTTP, webSocket: DaikinWebSocket.Connect?, timing: Timing = Timing(),
        apiDependencies: DaikinAPI.Dependencies = .init()
    ) {
        self.settings = settings
        self.logger = logger
        mode = settings.authMode
        self.context = context
        self.http = http
        self.timing = timing
        connectWebSocket = webSocket
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let file = context.storageDirectory.appendingPathComponent(settings.authMode.tokenFileName)
        let onError: @Sendable (String) -> Void = { logger.error("[Error] \($0)") }
        if settings.authMode == .mobileApp {
            tokens = MobileOAuth.client(file: file, http: http, log: { logger.info("\($0)") }, onError: onError)
        } else {
            tokens = DeveloperPortalOAuth.client(file: file, clientID: settings.clientID ?? "", clientSecret: settings.clientSecret ?? "", http: http, onError: onError)
        }
        let continuation = continuation
        api = DaikinAPI(oauth: tokens, http: http, dependencies: apiDependencies) { continuation.yield(.rateLimit($0)) }
    }

    var tokenFile: URL { context.storageDirectory.appendingPathComponent(mode.tokenFileName) }

    var serviceContext: ServiceContext {
        let continuation = continuation
        return ServiceContext(settings: settings, logger: logger) { continuation.yield(.forceUpdate) }
    }

    // MARK: Starting

    /// Logs in when needed, finds the devices and starts polling and the WebSocket. Answers whether the
    /// devices are in HomeKit now.
    @discardableResult
    func run() async -> Bool {
        guard !isRunning, !shuttingDown else { return isRunning }
        startEvents()
        defer { logger.info("--------------- End Daikin info for debugging reasons --------------------") }
        if await !tokens.isAuthenticated() {
            if mode == .mobileApp, let credentials = settings.mobileCredentials {
                logger.info("[Auth] Authenticating with Daikin Cloud using mobile app credentials...")
                do {
                    let mobile = MobileOAuth(email: credentials.email, password: credentials.password, http: http, log: { [logger] in logger.info("\($0)") })
                    let fresh = try await mobile.authenticate()
                    guard !shuttingDown else { return false }
                    await tokens.store(fresh)
                    logger.info("[Auth] Authentication successful!")
                } catch {
                    logger.error("[Auth] Authentication failed: \(message(of: error))")
                    return false
                }
            } else {
                logger.warning("[Auth] Not authenticated. Please use the plugin's page in the Homeswift UI to authenticate with Daikin Cloud.")
                return false
            }
        }
        guard !shuttingDown else { return false }
        let found = await discover()
        guard !found.isEmpty, !shuttingDown else { return false }
        createAccessories(found)
        isRunning = true
        pollingStarted = true
        schedulePoll()
        if settings.webSocketEnabled { await enableWebSocket() }
        return isRunning
    }

    private func startEvents() {
        guard eventTask == nil else { return }
        let events = events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: Event) async {
        switch event {
        case .rateLimit(let status): rateLimitReported(status)
        case .forceUpdate: forceUpdateDevices()
        case .webSocket(let event): await webSocketEvent(event)
        }
    }

    /// The first read retries gateway errors: a transient failure here would cost the whole start.
    private func discover() async -> [DaikinCloudDevice] {
        do {
            return try await fetch(retryGatewayErrors: true)
        } catch {
            let text = message(of: error)
            logger.error("[API Syncing] Failed to get cloud devices from Daikin Cloud: \(text)")
            if text.contains("invalid_grant") { invalidGrant() }
            return []
        }
    }

    /// Fetches the devices, updating the ones known already, and pushes the changes to HomeKit.
    @discardableResult
    private func fetch(retryGatewayErrors: Bool) async throws -> [DaikinCloudDevice] {
        guard await tokens.isAuthenticated() else { throw DaikinError("Not authenticated. Please authenticate first.") }
        let raws = try await api.devices(retryGatewayErrors: retryGatewayErrors)
        var updated: [DaikinCloudDevice] = []
        for raw in raws {
            let id = raw["id"]?.stringValue ?? ""
            if let existing = devices.first(where: { $0.id == id }) {
                existing.update(raw: raw)
                updated.append(existing)
                deviceChanged(id)
            } else {
                updated.append(DaikinCloudDevice(raw, api: api))
            }
        }
        devices = updated
        lastFetched = Date()
        return updated
    }

    private func createAccessories(_ devices: [DaikinCloudDevice]) {
        for device in devices {
            let id = DaikinAccessory.id(device)
            logger.debug("Create Device \(device.deviceModel) \(DaikinCloudDevice.masked(device.raw).text(pretty: true))")
            if settings.isExcluded(device.id) {
                logger.info("[Platform] Device \(device.deviceModel) (id: \(device.id)) is excluded, don't add accessory")
                if context.accessory(id: id) != nil {
                    let context = context
                    Task { try? await context.remove(id: id) }
                }
                continue
            }
            let name = DaikinAccessory.displayName(device)
            if let cached = context.accessory(id: id) {
                logger.info("[Platform] Restoring existing accessory from cache: \(cached.name) (id: \(device.id))")
            } else {
                logger.info("[Platform] Adding new accessory: \(name) (id: \(device.id))")
            }
            do {
                let accessory = try DaikinAccessory(device: device, context: serviceContext)
                try context.add(accessory.accessory)
                accessories[device.id] = accessory
                logger.debug("[Platform] Created \(accessory.profile.displayName) accessory")
            } catch {
                logger.error("[Platform] Failed to create accessory: \(message(of: error))")
                logger.debug("[Platform] Device JSON: \(DaikinCloudDevice.masked(device.raw).text(pretty: true))")
            }
        }
    }

    /// A device's data changed: its accessory follows, rebuilt when RotationSpeed must change shape.
    private func deviceChanged(_ deviceID: String) {
        guard let accessory = accessories[deviceID] else { return }
        logger.debug("[API Syncing] Updated \(accessory.accessory.name) (\(accessory.accessory.id)), LastUpdated: \(accessory.device.lastUpdated)")
        guard accessory.needsRebuild else {
            accessory.refreshValues()
            return
        }
        do {
            let rebuilt = try DaikinAccessory(device: accessory.device, context: serviceContext, previous: accessory)
            try context.add(rebuilt.accessory)
            accessories[deviceID] = rebuilt
        } catch {
            logger.warning("[\(accessory.accessory.name)] Could not rebuild the accessory: \(message(of: error))")
            accessory.refreshValues()
        }
    }

    // MARK: Polling

    /// The delay until the next poll.
    static func pollInterval(configured: Duration, webSocketConnected: Bool, consecutiveFailures: Int, remainingDay: Int?, timing: Timing = Timing()) -> Duration {
        var interval = configured
        if webSocketConnected { interval = max(interval, timing.webSocketSafetyPoll) }
        if consecutiveFailures > 0 { interval = interval * min(1 << min(consecutiveFailures, 30), maxBackoffMultiplier) }
        if let remainingDay, remainingDay <= lowQuotaThreshold { interval = max(interval, lowQuotaPoll) }
        return interval
    }

    var configuredInterval: Duration { timing.pollInterval ?? .milliseconds(Int(settings.updateInterval)) }

    var currentPollInterval: Duration {
        Self.pollInterval(configured: configuredInterval, webSocketConnected: webSocketConnected, consecutiveFailures: consecutiveFailures, remainingDay: remainingDay, timing: timing)
    }

    /// One poll at a time: a periodic poll, a forced one and a reconnection's catch-up share it.
    func updateDevices() async {
        if let inFlight { return await inFlight.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.pollOnce()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func pollOnce() async {
        pollCount += 1
        do {
            try await fetch(retryGatewayErrors: false)
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            logger.error("[API Syncing] Failed to update devices data: \(message(of: error))")
        }
    }

    /// Polls now, then schedules the next one.
    func pollNow() async {
        guard !shuttingDown else { return }
        stopPolling()
        await updateDevices()
        schedulePoll()
    }

    /// (Re)schedules the next periodic poll; there is never more than one.
    func schedulePoll() {
        stopPolling()
        // A forced update pending restarts polling when it fires.
        guard !shuttingDown, forceTask == nil else { return }
        let delay = currentPollInterval
        logger.debug("[API Syncing] Next update of devices data in \(Int((delay / .seconds(60)).rounded())) minutes")
        pollTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            await self?.pollFired()
        }
    }

    private func pollFired() async {
        pollTask = nil
        await pollNow()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// After a change from HomeKit: a poll `forceUpdateDelay` after the last change of a burst, so a few
    /// quick changes cost one request. Skipped while the WebSocket will push the change.
    func forceUpdateDevices(delay: Duration? = nil) {
        guard !shuttingDown else { return }
        if webSocketConnected {
            logger.debug("[API Syncing] WebSocket connected, skipping forced update (waiting for push update)")
            return
        }
        let delay = delay ?? timing.forceUpdateDelay ?? .milliseconds(Int(settings.forceUpdateDelay))
        let milliseconds = Int(delay / .milliseconds(1))
        if forceTask != nil {
            forceTask?.cancel()
            logger.debug("[API Syncing] Force update rescheduled (debouncing rapid changes, delayed by \(milliseconds)ms)")
        } else {
            logger.debug("[API Syncing] Force update devices data (delayed by \(milliseconds)ms)")
            // Periodic polling waits for the change to settle; the forced update restarts it.
            stopPolling()
        }
        forceTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            await self?.forceFired()
        }
    }

    private func forceFired() async {
        forceTask = nil
        await pollNow()
    }

    // MARK: WebSocket

    private func enableWebSocket() async {
        guard mode == .mobileApp, !shuttingDown else { return }
        guard let connectWebSocket else {
            logger.info("[WebSocket] No WebSocket client: polling only")
            return
        }
        logger.info("[WebSocket] Enabling real-time updates...")
        let continuation = continuation
        let socket = DaikinWebSocket(oauth: tokens, connect: connectWebSocket) { continuation.yield(.webSocket($0)) }
        webSocket = socket
        await socket.connect()
        // A stop while connecting may have reached the socket before the connect did.
        if shuttingDown { await socket.disconnect() }
    }

    private func webSocketEvent(_ event: DaikinWebSocket.Event) async {
        switch event {
        case .connected:
            webSocketConnected = true
            logger.info("[WebSocket] Connected - receiving real-time updates")
            let isReconnect = webSocketHasConnected
            webSocketHasConnected = true
            guard pollingStarted, !shuttingDown else { return }
            // A reconnection catches up on what changed meanwhile; the first one stretches polling.
            if isReconnect { await pollNow() } else { schedulePoll() }
        case .disconnected(_, _, let reconnecting):
            webSocketConnected = false
            if reconnecting {
                logger.debug("[WebSocket] Disconnected, attempting to reconnect...")
            } else {
                logger.info("[WebSocket] Disconnected")
            }
            // Pushes are gone: back to the configured interval.
            if pollingStarted { schedulePoll() }
        case .deviceUpdate(let update):
            guard let device = devices.first(where: { $0.id == update.deviceID }) else { return }
            device.apply(update)
            logger.debug("[WebSocket] Device update: \(update.deviceID) - \(update.characteristicName) \(update.data.text())")
            deviceChanged(update.deviceID)
        case .groupUpdate:
            break
        case .error(let text):
            logger.error("[Error] WebSocket error: \(text)")
        }
    }

    // MARK: Rate limit

    private func rateLimitReported(_ status: RateLimitStatus) {
        if let remaining = status.remainingDay {
            remainingDay = remaining
            if remaining <= Self.lowQuotaThreshold {
                logger.warning("[Rate Limit] Rate limit almost reached, you only have \(remaining) calls left today")
            }
        }
        let minute = status.limitMinute.map { " -- this minute: \(status.remainingMinute.map(String.init) ?? "undefined")/\($0)" } ?? ""
        logger.debug("[Rate Limit] Remaining calls today: \(status.remainingDay.map(String.init) ?? "undefined")/\(status.limitDay.map(String.init) ?? "undefined")\(minute)")
        saveRateLimit(status)
    }

    /// Keeps the quota for the settings page, which reads it instead of spending a call, and writes it to the file
    /// at most every few seconds.
    private func saveRateLimit(_ status: RateLimitStatus) {
        var object = status.json.objectValue ?? [:]
        object["mode"] = .string(mode.rawValue)
        object["updatedAt"] = .string(ISO8601DateFormatter.withFractionalSeconds.string(from: Date()))
        rateLimit = .object(object)
        pendingRateLimit = .object(object)
        guard rateLimitWriteTask == nil, !shuttingDown else { return }
        let wait = max(.zero, timing.rateLimitWriteInterval - .milliseconds(Int(Date().timeIntervalSince(lastRateLimitWrite) * 1000)))
        rateLimitWriteTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            await self?.flushRateLimit()
        }
    }

    private func flushRateLimit() {
        rateLimitWriteTask = nil
        guard let status = pendingRateLimit else { return }
        pendingRateLimit = nil
        lastRateLimitWrite = Date()
        let url = context.storageDirectory.appendingPathComponent(DaikinCloudPlugin.rateLimitFileName)
        do {
            try OwnerOnlyFile.write(status.encoded(pretty: true), to: url)
        } catch {
            logger.debug("[Rate Limit] Could not write \(DaikinCloudPlugin.rateLimitFileName): \(error)")
        }
    }

    // MARK: Tokens

    private func invalidGrant() {
        logger.warning("[API Syncing] TokenSet is invalid, removing TokenSet file")
        do {
            try FileManager.default.removeItem(at: tokenFile)
            logger.warning("[API Syncing] TokenSet file removed. Please re-authenticate on the plugin's page in the Homeswift UI.")
        } catch {
            logger.error("[API Syncing] TokenSet file could not be removed. Location: \(tokenFile.path) \(error)")
        }
        Task { await tokens.reload() }
    }

    // MARK: Stopping

    func stop() async {
        logger.debug("[Platform] Shutting down, cleaning up resources...")
        shuttingDown = true
        stopPolling()
        forceTask?.cancel()
        forceTask = nil
        rateLimitWriteTask?.cancel()
        rateLimitWriteTask = nil
        flushRateLimit()
        await webSocket?.disconnect()
        webSocket = nil
        eventTask?.cancel()
        eventTask = nil
        continuation.finish()
        isRunning = false
    }
}

extension ISO8601DateFormatter {
    /// `2026-10-22T18:44:00.123Z`, as JavaScript's `toISOString`.
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `2026-10-22T18:44:00Z`.
    nonisolated(unsafe) static let internetDateTime = ISO8601DateFormatter()
}
