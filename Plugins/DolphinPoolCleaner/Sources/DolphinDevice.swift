import Foundation
import HomeswiftPlugin
import Logging

/// One robot: its state from the shadow, kept fresh by the shadows MQTT pushes and by polling when none
/// arrived for a whole interval, and its commands.
actor DolphinDevice {
    nonisolated let serialNumber: String
    nonisolated let name: String
    nonisolated let deviceType: Int
    nonisolated let features: DeviceFeatures
    nonisolated let modelName: String
    nonisolated let pollingInterval: Duration
    private let cloud: any DolphinCloud
    private let timing: DolphinTiming
    private let logger: Logger
    private(set) var state = RobotState()
    private var lastShadowVersion: Int?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observer: UUID?
    private var stateHandler: (@Sendable (RobotState) -> Void)?

    init(serialNumber: String, name: String, deviceType: Int, pollingInterval: Duration, cloud: any DolphinCloud, timing: DolphinTiming = .standard, logger: Logger) {
        self.serialNumber = serialNumber
        self.name = name
        self.deviceType = deviceType
        self.pollingInterval = pollingInterval
        self.cloud = cloud
        self.timing = timing
        self.logger = logger
        features = DeviceCatalog.features(deviceType: deviceType)
        modelName = DeviceCatalog.modelName(deviceType: deviceType)
        logger.info("Device created: \(name) (\(modelName)) - S/N: \(serialNumber)")
    }

    /// Called with a copy of the state whenever it changes.
    func setStateHandler(_ handler: (@Sendable (RobotState) -> Void)?) { stateHandler = handler }

    /// Listens for pushed shadows, reads the shadow once, then polls.
    func start() async {
        logger.debug("Starting polling for \(name) every \(pollingInterval.components.seconds)s")
        observer = await cloud.addShadowObserver { [weak self] shadow in
            await self?.apply(shadow)
        }
        await refreshState()
        let interval = pollingInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.poll()
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let observer {
            await cloud.removeShadowObserver(observer)
            self.observer = nil
        }
        logger.debug("Stopped polling for \(name)")
    }

    /// Polls the shadow, unless MQTT pushed one within the interval: skipping redundant requests keeps the
    /// plugin under the AWS IoT rate limit.
    private func poll() async {
        if let pushed = await cloud.lastShadowReceivedAt() {
            let since = ContinuousClock.now - pushed
            if since < pollingInterval {
                logger.debug("Skipping poll for \(name): shadow received \(since.components.seconds)s ago")
                return
            }
        }
        await refreshState()
    }

    /// Reads the shadow; when it cannot be read, the last known state stays.
    func refreshState() async {
        if let shadow = await cloud.thingShadow(serialNumber: serialNumber) {
            apply(shadow)
        }
    }

    /// Applies a shadow and tells the handler when something changed.
    func apply(_ shadow: JSONValue) {
        let wasConnected = state.connected
        let changed = process(shadow)
        state.connected = true
        if changed || !wasConnected { stateHandler?(state) }
    }

    /// Returns false when the shadow's version was already applied.
    private func process(_ shadow: JSONValue) -> Bool {
        let version = ShadowParser.version(of: shadow)
        if let version, version == lastShadowVersion { return false }
        lastShadowVersion = version
        var parsed = ShadowParser.parse(shadow, existing: state)
        // Only models with a sensor report the water's temperature.
        if !features.hasTemperatureSensor { parsed.temperature = nil }
        state = parsed
        logger.debug("State updated for \(name): cleaning=\(state.isCleaning), mode=\(state.cleaningMode)")
        return true
    }

    /// Reads the shadow again shortly after a command, once the robot reacted. A newer command replaces a
    /// pending refresh instead of stacking another.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let delay = timing.stateRefreshDelay
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.refreshState()
        }
    }

    /// Starts a cycle in `mode` (the robot's current one when nil or unknown).
    func startCleaning(mode: String?) async -> Bool {
        let resolved = mode.flatMap(Self.resolveCleaningMode)
        if let mode, resolved == nil {
            logger.warning("Unknown cleaning mode \"\(mode)\", starting \(name) with its current mode")
        }
        // The mode is sent only when the robot does not have it queued: every shadow request counts against
        // the shared rate limit and delays the start.
        if let resolved, state.nextCycleMode != resolved, let cleaningMode = CleaningMode.all[resolved] {
            if await cloud.setCleaningMode(serialNumber: serialNumber, mode: cleaningMode.apiMode) {
                state.nextCycleMode = resolved
            } else {
                logger.warning("Could not set cleaning mode \(resolved) for \(name), starting with its current mode")
            }
        }
        let success = await cloud.startRobot(serialNumber: serialNumber)
        if success {
            logger.info("Started cleaning for \(name)\(resolved.map { " (mode: \($0))" } ?? "")")
            // Optimistically, until the robot reports.
            state.isCleaning = true
            if let resolved { state.cleaningMode = resolved }
            stateHandler?(state)
            scheduleRefresh()
        }
        return success
    }

    func stopCleaning() async -> Bool {
        let success = await cloud.stopRobot(serialNumber: serialNumber)
        if success {
            logger.info("Stopped cleaning for \(name)")
            state.isCleaning = false
            stateHandler?(state)
            scheduleRefresh()
        }
        return success
    }

    func setCleaningMode(_ mode: String) async -> Bool {
        guard let resolved = Self.resolveCleaningMode(mode), let cleaningMode = CleaningMode.all[resolved] else {
            logger.warning("Unknown cleaning mode: \(mode)")
            return false
        }
        let success = await cloud.setCleaningMode(serialNumber: serialNumber, mode: cleaningMode.apiMode)
        if success {
            logger.info("Set cleaning mode to \(resolved) for \(name)")
            state.cleaningMode = resolved
            state.nextCycleMode = resolved
            stateHandler?(state)
        }
        return success
    }

    /// A configured mode (with aliases such as `regular`) as a key of `CleaningMode.all`, or nil.
    static func resolveCleaningMode(_ mode: String) -> String? {
        let normalized = ShadowParser.cleaningMode(mode)
        return CleaningMode.all[normalized] == nil ? nil : normalized
    }
}
