import Foundation
import Homeswift
import HomeswiftNetwork
import Logging

/// One television: what the plugin knows about it, how it watches it, and every command HomeKit can send.
///
/// The state comes from polls and from the TV's own `notifychange` channel; HomeKit writes go to the TV at
/// once and are remembered, so a poll a moment later does not undo them. Input switching is arbitrated here
/// because the wheel and the source switches are two HomeKit views of the same choice: one selection is
/// outstanding at a time, a newer one supersedes it, and a selection made while the TV is off or still
/// booting is parked and replayed once the TV is up (a Home scene writes power and input together).
actor TVDevice {
    static let wakeWindow: Duration = .seconds(20)
    static let wakePollInterval: Duration = .seconds(2)
    static let unreachablePollsBeforeOff = 2
    static let longPollRetryDelay: Duration = .seconds(60)
    static let confirmedLongPollInterval: Duration = .seconds(60)
    static let activityRefreshThrottle: Duration = .seconds(10)
    static let userActionCooldown: Duration = .seconds(10)
    static let colorCoalescing: Duration = .milliseconds(50)
    static let styleRetryDelays: [Duration] = [.seconds(3), .seconds(6)]
    static let pendingConfirmTimeout: Duration = .seconds(20)
    static let ambiguousSightings = 2
    static let ambiguousWindow: Duration = .seconds(60)
    static let wakeReplayWindow: Duration = .seconds(90)
    static let wakeReplayAttempts = 5
    static let wakeReplayRetry: Duration = .seconds(3)
    static let wakeConfirmSettle: Duration = .milliseconds(1500)
    static let switchPrecedence: Duration = .milliseconds(1500)
    static let sceneCoalescing: Duration = .milliseconds(250)
    static let pruneAfterMissedListings = 2
    static let hueRefreshThrottle: Duration = .seconds(30)
    static let appRefreshInterval: Duration = .seconds(3600)
    static let menuBrightnessMax = 10
    static let colorTemperatureRange = 140...500

    /// An input with its HomeKit identifier and what the user made of it.
    struct Input: Sendable, Equatable {
        var data: InputData
        var identifier: Int
        var configuredName: String
        var hidden: Bool
        var id: String { data.id }
        var name: String { data.name }
    }

    struct AmbilightState: Sendable, Equatable {
        var on = false
        var hue = 0.0
        var saturation = 0.0
        var brightness = 100
        var colorTemperature = 280
        var style: String?
    }

    /// What the accessory layer is told about.
    enum Change: Sendable {
        case power(Bool)
        case ambilight(AmbilightState)
        case mute(Bool)
        case input(identifier: Int, id: String?)
        case hueLamp(Bool)
        /// Inputs were added, removed or renamed: the accessory is rebuilt.
        case inputs
    }

    let settings: TVSettings
    let client: JointSpaceClient
    let catalog: InputCatalog
    private let transports: any JointSpaceTransportFactory
    private let logger: Logger
    private var inputStore: InputStore
    private var switchNames: SwitchNameStore
    private var observer: (@Sendable (Change) -> Void)?

    private(set) var isOn = false
    private var initialPowerReported = false
    private var unreachablePolls = 0
    private var consecutiveFailures = 0
    private var poweredOnAt: ContinuousClock.Instant?
    private(set) var muted = false
    private(set) var ambilight = AmbilightState()
    private var lastAmbilightAction: ContinuousClock.Instant?
    private var styleRetry: Task<Void, Never>?
    private var pendingColorWrite: Task<Void, any Error>?
    private(set) var hueLampOn = false
    private var lastHueRefresh: ContinuousClock.Instant?
    private var refreshingHue = false

    private(set) var inputs: [Input] = []
    private(set) var currentIdentifier = 0
    private var pendingIdentifier: Int?
    private var pendingSince: ContinuousClock.Instant?
    private var switchGeneration = 0
    private var launching = false
    private var launchWaiters: [CheckedContinuation<Void, Never>] = []
    private var wakeSelection: (input: Input, generation: Int, parkedAt: ContinuousClock.Instant)?
    private var lastSwitchRequest: (id: String, at: ContinuousClock.Instant)?
    private var ambiguousReport: (app: String, sightings: Int, lastSeen: ContinuousClock.Instant)?
    private var tvTrackedApps: Set<String> = []
    private var awaitingWakeAlignment = false
    private var missedListings: [String: Int] = [:]
    private var lastAppFetch: ContinuousClock.Instant?
    private(set) var currentApp: String?

    private var pollTask: Task<Void, Never>?
    private var pollRequested = false
    private var polling = false
    private var notify: NotifyChangeClient?
    private var longPollConfirmed = false
    private var longPollRetry: Task<Void, Never>?
    private var lastNotifyRefresh: ContinuousClock.Instant?
    private(set) var started = false

    init(settings: TVSettings, storageDirectory: URL, transports: any JointSpaceTransportFactory, logger: Logger) {
        self.settings = settings
        self.transports = transports
        var deviceLogger = logger
        deviceLogger[metadataKey: "tv"] = "\(settings.name)"
        self.logger = deviceLogger
        client = JointSpaceClient(ip: settings.ip, username: settings.username, password: settings.password, certificateFingerprint: settings.certFingerprint, transports: transports, logger: deviceLogger)
        catalog = InputCatalog(settings: settings)
        var store = InputStore(directory: storageDirectory, mac: settings.mac)
        switchNames = SwitchNameStore(directory: storageDirectory, mac: settings.mac)
        // The inputs known before the TV answers: the static sources and the apps remembered from last time.
        var used = Set<Int>()
        var built: [Input] = []
        for data in catalog.startupInputs(cached: store.records) {
            let identifier = store.identifier(for: data.id, inUse: used)
            used.insert(identifier)
            built.append(Self.makeInput(data, identifier: identifier, record: store.record(for: data.id), settings: settings))
        }
        inputs = built
        currentIdentifier = built.first { $0.id == JointSpace.watchTVURI }?.identifier ?? built.first?.identifier ?? 0
        do {
            try store.save(Self.records(of: built))
        } catch {
            deviceLogger.warning("Could not save the inputs: \(error)")
        }
        inputStore = store
    }

    func setObserver(_ observer: @escaping @Sendable (Change) -> Void) { self.observer = observer }

    /// What a page shows about the TV.
    struct Snapshot: Sendable {
        var name: String, ip: String, mac: String
        var isOn: Bool, isReachable: Bool, muted: Bool
        var ambilight: AmbilightState
        var currentApp: String?
        var currentInput: String?
        var inputs: Int
        var longPoll: String
        var pinned: Bool
    }

    var snapshot: Snapshot {
        Snapshot(
            name: settings.name, ip: settings.ip, mac: settings.mac, isOn: isOn, isReachable: consecutiveFailures < Self.unreachablePollsBeforeOff, muted: muted,
            ambilight: ambilight, currentApp: currentApp, currentInput: inputs.first { $0.identifier == currentIdentifier }?.name, inputs: inputs.count,
            longPoll: notify == nil ? "off" : longPollConfirmed ? "confirmed" : "waiting", pinned: settings.certFingerprint != nil)
    }

    var isWaking: Bool {
        guard let poweredOnAt else { return false }
        return ContinuousClock.now - poweredOnAt < Self.wakeWindow
    }

    /// The inputs in the wheel's order: the sources setting's order, the configured list's, then registration order.
    var orderedInputs: [Input] {
        inputs.enumerated().sorted { lhs, rhs in
            switch (catalog.order(of: lhs.element.id), catalog.order(of: rhs.element.id)) {
            case (let a?, let b?): a != b ? a < b : lhs.offset < rhs.offset
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The `DisplayOrder` of the wheel.
    var displayOrder: String { Inputs.displayOrder(orderedInputs.map(\.identifier)) }

    func switchName(for id: String) -> String? { switchNames.names[id] }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let polled = ContinuousClock.now
                // Short sleeps, so a change of cadence (the TV going off, the long poll stopping) takes effect at once.
                while !Task.isCancelled {
                    let due = polled + (await self.nextPollInterval)
                    let now = ContinuousClock.now
                    if now >= due { break }
                    do { try await Task.sleep(for: min(due - now, .milliseconds(500))) } catch { return }
                }
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        styleRetry?.cancel()
        pendingColorWrite?.cancel()
        longPollRetry?.cancel()
        await stopLongPoll()
        started = false
    }

    private var nextPollInterval: Duration {
        if isWaking { return Self.wakePollInterval }
        if longPollConfirmed { return max(settings.pollingInterval, Self.confirmedLongPollInterval) }
        return settings.pollingInterval
    }

    // MARK: Polling

    /// Reads the TV's state. A poll asked for while one runs earns exactly one follow-up: the running one
    /// may have read a resource before the change that prompted the request.
    func poll() async {
        if polling {
            pollRequested = true
            return
        }
        polling = true
        defer { polling = false }
        repeat {
            pollRequested = false
            await readState()
        } while pollRequested && !Task.isCancelled
    }

    private func readState() async {
        let reported: Bool?
        do {
            reported = try await client.powerState()
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            reported = nil
            if consecutiveFailures == Self.unreachablePollsBeforeOff { logger.debug("The TV is not answering: \(error)") }
        }
        let on: Bool
        if let reported {
            unreachablePolls = 0
            on = reported
        } else {
            unreachablePolls += 1
            // Believed on and only just gone quiet: a second miss before calling it standby.
            if isOn, unreachablePolls < Self.unreachablePollsBeforeOff { return }
            on = false
        }
        await applyPower(on)
        guard on else { return }
        if let configuration = try? await client.ambilightConfiguration() {
            applyAmbilight(configuration)
        } else if let power = try? await client.ambilightPower() {
            applyAmbilightPower(power)
        }
        if let volume = try? await client.volume() {
            applyVolume(volume)
        }
        if let activity = try? await client.currentActivity() {
            applyCurrentApp(activity)
        }
        if !catalog.hasUserInputs, lastAppFetch.map({ ContinuousClock.now - $0 > Self.appRefreshInterval }) ?? true {
            await fetchAppsFromTV()
        }
    }

    private func applyPower(_ on: Bool) async {
        let changed = on != isOn
        let known = initialPowerReported
        guard changed || !known else { return }
        isOn = on
        initialPowerReported = true
        if changed { logger.info("Power: \(on ? "on" : "standby")") }
        observer?(.power(on))
        if on {
            // A TV seen off that comes on is booting and drops launches for a while; one that is on at launch
            // has been on for a while.
            if changed, known, poweredOnAt == nil { poweredOnAt = .now }
            awaitingWakeAlignment = changed || awaitingWakeAlignment
            startLongPoll()
            if changed {
                if settings.ambilightOnStart { await startAmbilightWithConfiguredMode() }
                await fetchAppsFromTV()
                await replayWakeSelection()
            }
        } else {
            poweredOnAt = nil
            await stopLongPoll()
            longPollRetry?.cancel()
            reflectAmbilightOff()
            observer?(.input(identifier: currentIdentifier, id: nil))
        }
    }

    // MARK: Long poll

    private func startLongPoll() {
        guard notify == nil else { return }
        let notifyClient = JointSpaceClient(
            ip: settings.ip, username: settings.username, password: settings.password, certificateFingerprint: settings.certFingerprint,
            transports: transports, logger: logger)
        let notify = NotifyChangeClient(client: notifyClient, logger: logger)
        self.notify = notify
        Task { [weak self] in
            await notify.start { [weak self] event in
                await self?.handle(event)
            }
        }
        logger.debug("Long-poll started; polling continues until it delivers")
    }

    private func stopLongPoll() async {
        guard let notify else { return }
        self.notify = nil
        longPollConfirmed = false
        lastNotifyRefresh = nil
        await notify.stop()
    }

    private func handle(_ event: NotifyChangeClient.Event) async {
        switch event {
        case .failed:
            await stopLongPoll()
            if isOn {
                logger.debug("Long-poll failed while the TV is on; retrying in \(Self.longPollRetryDelay)")
                longPollRetry?.cancel()
                longPollRetry = Task { [weak self] in
                    try? await Task.sleep(for: Self.longPollRetryDelay)
                    guard !Task.isCancelled, let self, await self.isOn else { return }
                    await self.startLongPoll()
                }
            }
        case .notification(let payload):
            guard !payload.isEmpty else { return }
            if !longPollConfirmed {
                longPollConfirmed = true
                logger.info("Long-poll confirmed; polling slows down")
            }
            let actionable = payload.filter { $0.key != "activities/tv" }
            if !actionable.isEmpty {
                if await applyNotification(actionable) {
                    lastNotifyRefresh = .now
                    logger.debug("Applied notification: \(actionable.keys.sorted().joined(separator: ", "))")
                } else {
                    lastNotifyRefresh = .now
                    await poll()
                }
                return
            }
            // Only activities/tv: it ticks every second with tuner data, but it is also the one resource some
            // models push on app switches from the remote. Refresh on a throttle.
            if let last = lastNotifyRefresh, ContinuousClock.now - last < Self.activityRefreshThrottle { return }
            lastNotifyRefresh = .now
            await poll()
        }
    }

    /// Applies the values a notification carries. False when a payload has a shape this does not read,
    /// before anything was applied: the caller polls instead.
    private func applyNotification(_ payload: [String: JSONPayload]) async -> Bool {
        var updates: [() -> Void] = []
        var power: Bool?
        for (key, value) in payload {
            switch key {
            case "powerstate":
                guard let state = value["powerstate"]?.stringValue else { return false }
                power = state == "On"
            case "ambilight/currentconfiguration":
                guard let style = value["styleName"]?.stringValue else { return false }
                let color = value["colorSettings"]?["color"]
                var configuration = JointSpace.AmbilightConfiguration(styleName: style, isExpert: value["isExpert"]?.boolValue, menuSetting: value["menuSetting"]?.stringValue, algorithm: value["algorithm"]?.stringValue)
                if let hue = color?["hue"]?.intValue, let saturation = color?["saturation"]?.intValue, let brightness = color?["brightness"]?.intValue {
                    configuration.colorSettings = .init(color: .init(hue: hue, saturation: saturation, brightness: brightness), colorDelta: .init(hue: 0, saturation: 0, brightness: 0), speed: 0)
                }
                updates.append { self.applyAmbilight(configuration) }
            case "ambilight/power":
                guard let state = value["power"]?.stringValue else { return false }
                if payload["ambilight/currentconfiguration"] == nil {
                    updates.append { self.applyAmbilightPower(state == "On") }
                }
            case "audio/volume":
                let muted = value["muted"]?.boolValue
                let current = value["current"]?.intValue
                guard muted != nil || current != nil else { return false }
                updates.append { self.applyVolume(JointSpace.Volume(current: current, muted: muted)) }
            case "activities/current":
                guard let package = value["component"]?["packageName"]?.stringValue else { return false }
                updates.append { self.applyCurrentApp(package) }
            default:
                return false
            }
        }
        if let power {
            await applyPower(power)
            if !power { return true }
        }
        for update in updates { update() }
        return true
    }

    // MARK: Power

    /// HomeKit's Active: Wake-on-LAN then the request when switching on, so a TV whose network is asleep
    /// still hears it; the state is believed at once and reconciled by the polls that follow.
    func setPower(_ on: Bool) async throws {
        if on {
            if settings.wakeOnLAN {
                var addresses = ["255.255.255.255"]
                if let directed = WakeOnLAN.broadcastAddress(for: settings.ip) { addresses.append(directed) }
                do {
                    try await WakeOnLAN.wake(mac: settings.mac, addresses: addresses)
                } catch {
                    logger.debug("Wake-on-LAN failed: \(error)")
                }
            }
            do {
                try await client.setPower(on: true)
            } catch {
                guard settings.wakeOnLAN else {
                    logger.warning("Could not switch the TV on: \(error)")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                logger.debug("The TV did not answer the power request; waiting for it to wake")
            }
            logger.info("Switched on")
            if !isOn { poweredOnAt = .now }
            await applyPower(true)
            Task { [weak self] in await self?.poll() }
        } else {
            do {
                try await client.setPower(on: false)
            } catch {
                logger.warning("Could not switch the TV off: \(error)")
                throw HAPStatusError(.serviceCommunicationFailure)
            }
            logger.info("Switched off")
            clearWakeSelection()
            await applyPower(false)
        }
    }

    // MARK: Volume and keys

    func setMuted(_ muted: Bool) async throws {
        do {
            try await client.setMuted(muted)
        } catch {
            logger.warning("Could not \(muted ? "mute" : "unmute"): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        self.muted = muted
    }

    /// `VolumeSelector`: 0 is up, 1 is down.
    func volume(up: Bool) async throws {
        try await sendKey(up ? "VolumeUp" : "VolumeDown")
    }

    func remoteKey(_ value: Int) async {
        let key: String? = switch value {
        case HAPConstants.RemoteKey.back: settings.backButtonKey
        case HAPConstants.RemoteKey.playPause: settings.playPauseButtonKey
        case HAPConstants.RemoteKey.information: settings.infoButtonKey
        default: Inputs.remoteKeys[value]
        }
        guard let key else {
            logger.debug("Unknown remote key \(value)")
            return
        }
        try? await sendKey(key)
    }

    func sendKey(_ key: String) async throws {
        do {
            try await client.sendKey(key)
            logger.debug("Sent key \(key)")
        } catch {
            logger.warning("Could not send \(key): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    private func applyVolume(_ volume: JointSpace.Volume) {
        let muted = volume.muted ?? false
        guard muted != self.muted else { return }
        self.muted = muted
        logger.debug("Volume: \(volume.current.map(String.init) ?? "?")\(muted ? " (muted)" : "")")
        observer?(.mute(muted))
    }

    // MARK: Ambilight

    private var configuredMode: (style: String, algorithm: String?) {
        let parts = settings.ambilightMode.uppercased().split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "FOLLOW_VIDEO", parts.count > 1 ? parts[1].nonEmpty : nil)
    }

    private var isShowingColor: Bool { ambilight.style == "FOLLOW_COLOR" }

    func setAmbilight(on: Bool) async throws {
        lastAmbilightAction = .now
        if !on, !isOn {
            // Already true: a request would only time out against a sleeping TV.
            styleRetry?.cancel()
            ambilight.on = false
            return
        }
        do {
            if on {
                let mode = configuredMode
                try await client.setAmbilightPower(true)
                try await client.setAmbilightStyle(mode.style, algorithm: mode.algorithm)
                ambilight.on = true
                ambilight.style = mode.style
                scheduleStyleRetry(mode.style, algorithm: mode.algorithm)
            } else {
                styleRetry?.cancel()
                pendingColorWrite?.cancel()
                try await client.setAmbilightOff()
                ambilight.on = false
                ambilight.style = "OFF"
            }
            lastAmbilightAction = .now
            logger.info("Ambilight \(on ? "on" : "off")")
        } catch {
            if !on, !isOn {
                // A scene switching the TV and Ambilight off together: the TV reached standby first, and
                // Ambilight is off either way.
                ambilight.on = false
                return
            }
            logger.warning("Could not switch Ambilight \(on ? "on" : "off"): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    func setAmbilightBrightness(_ brightness: Int) async throws {
        ambilight.brightness = brightness
        guard ambilight.on else { return }
        if !isShowingColor {
            // Following video or audio there is no colour to dim: the menu's brightness is the faithful mapping.
            let level = Int((Double(brightness) / 100 * Double(Self.menuBrightnessMax)).rounded())
            do {
                try await client.setAmbilightBrightness(level)
            } catch {
                logger.warning("Could not set the Ambilight brightness: \(error)")
                throw HAPStatusError(.serviceCommunicationFailure)
            }
            lastAmbilightAction = .now
            return
        }
        try await writeColor()
    }

    func setAmbilightHue(_ hue: Double) async throws {
        ambilight.hue = hue
        if ambilight.on { try await writeColor() }
    }

    func setAmbilightSaturation(_ saturation: Double) async throws {
        ambilight.saturation = saturation
        if ambilight.on { try await writeColor() }
    }

    /// A colour temperature becomes a hue and saturation; the Home app's Hue and Saturation follow.
    func setAmbilightColorTemperature(_ mireds: Int) async throws {
        ambilight.colorTemperature = mireds
        let (hue, saturation) = ColorConversion.hueAndSaturation(mireds: mireds)
        ambilight.hue = hue
        ambilight.saturation = saturation
        observer?(.ambilight(ambilight))
        if ambilight.on { try await writeColor() }
    }

    /// Sends hue, saturation and brightness as one `FOLLOW_COLOR` command: a colour pick writes them as
    /// three characteristics within milliseconds, and every writer awaits the same command.
    private func writeColor() async throws {
        if pendingColorWrite == nil {
            pendingColorWrite = Task { [weak self] in
                try await Task.sleep(for: Self.colorCoalescing)
                guard let self else { return }
                try await self.flushColor()
            }
        }
        guard let pending = pendingColorWrite else { return }
        do {
            try await pending.value
        } catch is CancellationError {
            return
        } catch {
            throw error
        }
    }

    private func flushColor() async throws {
        pendingColorWrite = nil
        let color = ColorConversion.philipsColor(hue: ambilight.hue, saturation: ambilight.saturation, brightness: ambilight.brightness)
        do {
            try await client.setAmbilightColor(color)
        } catch {
            logger.warning("Could not set the Ambilight colour: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        ambilight.style = "FOLLOW_COLOR"
        lastAmbilightAction = .now
    }

    /// Ambilight on at power-on, with the configured mode (`ambilightOnStart`).
    private func startAmbilightWithConfiguredMode() async {
        let mode = configuredMode
        logger.info("Starting Ambilight (\(settings.ambilightMode))")
        do {
            try await client.setAmbilightPower(true)
            try await client.setAmbilightStyle(mode.style, algorithm: mode.algorithm)
            ambilight.on = true
            ambilight.style = mode.style
            lastAmbilightAction = .now
            observer?(.ambilight(ambilight))
            scheduleStyleRetry(mode.style, algorithm: mode.algorithm)
        } catch {
            logger.warning("Could not start Ambilight: \(error)")
        }
    }

    /// The TV restores its own default style a few seconds after switching on; re-apply ours twice.
    private func scheduleStyleRetry(_ style: String, algorithm: String?) {
        styleRetry?.cancel()
        styleRetry = Task { [weak self] in
            for delay in Self.styleRetryDelays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, await self.ambilight.on else { return }
                await self.reapplyStyle(style, algorithm: algorithm)
            }
        }
    }

    private func reapplyStyle(_ style: String, algorithm: String?) async {
        guard let current = try? await client.ambilightConfiguration() else { return }
        ambilight.style = current.style
        guard current.style != style else { return }
        logger.debug("Ambilight style drifted to \(current.style); re-applying \(style)")
        if (try? await client.setAmbilightStyle(style, algorithm: algorithm)) != nil { ambilight.style = style }
        lastAmbilightAction = .now
    }

    private func reflectAmbilightOff() {
        styleRetry?.cancel()
        pendingColorWrite?.cancel()
        pendingColorWrite = nil
        guard ambilight.on else { return }
        ambilight.on = false
        observer?(.ambilight(ambilight))
    }

    private func applyAmbilight(_ configuration: JointSpace.AmbilightConfiguration) {
        if let last = lastAmbilightAction, ContinuousClock.now - last < Self.userActionCooldown { return }
        var state = ambilight
        state.style = configuration.style
        state.on = configuration.style != "OFF"
        if configuration.style == "FOLLOW_COLOR", let color = configuration.colorSettings?.color {
            let converted = ColorConversion.homeKitColor(color)
            state.hue = converted.hue
            state.saturation = converted.saturation
            state.brightness = converted.brightness
        }
        guard state != ambilight else { return }
        ambilight = state
        logger.debug("Ambilight: \(state.on ? state.style ?? "on" : "off")")
        observer?(.ambilight(state))
    }

    private func applyAmbilightPower(_ on: Bool) {
        if let last = lastAmbilightAction, ContinuousClock.now - last < Self.userActionCooldown { return }
        guard on != ambilight.on else { return }
        ambilight.on = on
        logger.debug("Ambilight: \(on ? "on" : "off")")
        observer?(.ambilight(ambilight))
    }

    // MARK: Ambilight+hue

    /// The last known state at once; the TV is re-read in the background, throttled.
    func hueLampState() -> Bool {
        if isOn, !refreshingHue, lastHueRefresh.map({ ContinuousClock.now - $0 >= Self.hueRefreshThrottle }) ?? true {
            refreshingHue = true
            Task { [weak self] in await self?.refreshHueLamp() }
        }
        return hueLampOn
    }

    private func refreshHueLamp() async {
        defer { refreshingHue = false }
        lastHueRefresh = .now
        guard let on = try? await client.hueLampPower(), on != hueLampOn else { return }
        hueLampOn = on
        observer?(.hueLamp(on))
    }

    func setHueLamp(_ on: Bool) async throws {
        do {
            try await client.setHueLampPower(on)
        } catch {
            logger.warning("Could not switch Ambilight+hue \(on ? "on" : "off"): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        hueLampOn = on
        lastHueRefresh = .now
        logger.info("Ambilight+hue \(on ? "on" : "off")")
    }

    // MARK: Inputs

    private static func makeInput(_ data: InputData, identifier: Int, record: InputRecord?, settings: TVSettings) -> Input {
        let setting = settings.sources[data.id]
        let hidden: Bool
        if let visible = setting?.visible {
            hidden = !visible
        } else {
            hidden = record?.visibility == 1
        }
        let name = setting?.customName ?? record?.configuredName.nonEmpty ?? data.name
        return Input(data: data, identifier: identifier, configuredName: name, hidden: hidden)
    }

    private static func records(of inputs: [Input]) -> [InputRecord] {
        inputs.map { InputRecord(id: $0.id, name: $0.name, configuredName: $0.configuredName, type: $0.data.type, identifier: $0.identifier, visibility: $0.hidden ? 1 : 0) }
    }

    private func saveInputs() {
        do {
            try inputStore.save(Self.records(of: inputs))
        } catch {
            logger.warning("Could not save the inputs: \(error)")
        }
    }

    /// Learns the TV's apps: new ones become inputs, placeholder names become the real labels, apps the TV
    /// stopped reporting twice in a row go, unless the user asked for them.
    func fetchAppsFromTV() async {
        guard !catalog.hasUserInputs, isOn else { return }
        lastAppFetch = .now
        guard let applications = try? await client.applications(), !applications.isEmpty else { return }
        var changed = false
        let discovered = catalog.appsFromTV(applications)
        let reported = Set(applications.compactMap(\.packageName))

        for app in discovered {
            guard let index = inputs.firstIndex(where: { $0.id == app.id }) else { continue }
            let placeholder = TVSettings.homeKitName(app.id)
            guard app.name != placeholder, settings.sources[app.id]?.customName == nil,
                  inputs[index].name == placeholder, inputs[index].configuredName == placeholder else { continue }
            inputs[index].data.name = app.name
            inputs[index].configuredName = app.name
            changed = true
        }

        var stale: [String] = []
        for input in inputs where input.data.type == .app {
            if reported.contains(input.id) {
                missedListings[input.id] = nil
                continue
            }
            if catalog.isUserRequested(input.id) || input.identifier == currentIdentifier || wakeSelection?.input.id == input.id { continue }
            let misses = (missedListings[input.id] ?? 0) + 1
            missedListings[input.id] = misses
            if misses >= Self.pruneAfterMissedListings { stale.append(input.id) }
        }
        if !stale.isEmpty {
            inputs.removeAll { stale.contains($0.id) }
            for id in stale { missedListings[id] = nil }
            logger.info("Removed \(stale.count) app(s) the TV no longer has: \(stale.joined(separator: ", "))")
            changed = true
        }

        let known = Set(inputs.map(\.id))
        let new = catalog.sortBySourcePriority(discovered.filter { !known.contains($0.id) })
        let room = max(0, Inputs.maximum - inputs.count)
        var used = Set(inputs.map(\.identifier))
        for app in new.prefix(room) {
            let identifier = inputStore.identifier(for: app.id, inUse: used)
            used.insert(identifier)
            inputs.append(Self.makeInput(app, identifier: identifier, record: inputStore.record(for: app.id), settings: settings))
            changed = true
        }
        if new.count > room { logger.debug("Input limit reached (\(Inputs.maximum)); \(new.count - room) app(s) left out") }
        if !new.isEmpty { logger.info("Discovered \(min(new.count, room)) app(s) (\(inputs.count) inputs)") }
        if changed {
            saveInputs()
            observer?(.inputs)
            // The app in front may be one that just became an input.
            if let currentApp { applyCurrentApp(currentApp) }
        }
    }

    /// A rename from the Home app. tvOS writes its own "Input N" placeholder back sometimes; that is ignored.
    func renameInput(identifier: Int, to name: String) {
        let cleaned = TVSettings.controllerName(name)
        guard !cleaned.isEmpty, !Inputs.isGenericName(cleaned), let index = inputs.firstIndex(where: { $0.identifier == identifier }), inputs[index].configuredName != cleaned else { return }
        inputs[index].configuredName = cleaned
        saveInputs()
        logger.debug("Input \(inputs[index].name) renamed to \(cleaned)")
    }

    func setInputHidden(identifier: Int, hidden: Bool) {
        guard let index = inputs.firstIndex(where: { $0.identifier == identifier }), inputs[index].hidden != hidden else { return }
        inputs[index].hidden = hidden
        saveInputs()
    }

    func renameSwitch(id: String, to name: String) {
        let cleaned = TVSettings.controllerName(name)
        guard !cleaned.isEmpty else { return }
        do {
            try switchNames.set(cleaned, for: id)
        } catch {
            logger.warning("Could not save the switch name: \(error)")
        }
    }

    // MARK: Input selection

    enum SelectionOrigin { case wheel, sourceSwitch }

    /// `ActiveIdentifier` from HomeKit.
    func selectInput(identifier: Int) async throws {
        guard let input = inputs.first(where: { $0.identifier == identifier }) else {
            logger.warning("Unknown input identifier \(identifier)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        logger.info("Switching to \(input.name)")
        try await requestSwitch(input, origin: .wheel)
    }

    /// A source switch turned on.
    func selectSource(id: String) async throws {
        guard let input = inputs.first(where: { $0.id == id }) else {
            logger.warning("Unknown source \(id)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        logger.info("Source switch: \(input.name)")
        try await requestSwitch(input, origin: .sourceSwitch)
    }

    /// The one path every selection takes. A switch acts at once; the wheel waits a beat for a switch the
    /// same scene may carry, since the Home app fills a scene's input in from whatever it was at creation.
    private func requestSwitch(_ input: Input, origin: SelectionOrigin) async throws {
        if origin == .sourceSwitch {
            lastSwitchRequest = (input.id, .now)
        } else {
            if settings.sourceSwitches { try? await Task.sleep(for: Self.sceneCoalescing) }
            if supersededByRecentSwitch(input) { return }
        }
        switchGeneration += 1
        let generation = switchGeneration
        wakeSelection = nil
        if !isOn {
            park(input, generation: generation, reason: "The TV is off")
            return
        }
        if isWaking {
            park(input, generation: generation, reason: "The TV is still waking")
            return
        }
        await acquireLaunch()
        defer { releaseLaunch() }
        guard generation == switchGeneration else {
            logger.debug("Skipping the superseded switch to \(input.name)")
            return
        }
        try await performSwitch(input, generation: generation)
    }

    private func performSwitch(_ input: Input, generation: Int) async throws {
        do {
            try await launch(input)
            guard generation == switchGeneration else {
                logger.debug("Launched \(input.name), but a newer selection superseded it")
                return
            }
            commitSelection(input)
        } catch {
            if isWaking {
                if generation == switchGeneration { park(input, generation: generation, reason: "The TV is still waking") }
                return
            }
            if input.data.type == .app {
                logger.warning("Could not launch \(input.name) (\(input.id)): \(error). If the TV rejected the activity, set the app's launch activity in the configuration.")
            } else {
                logger.warning("Could not switch to \(input.name): \(error)")
            }
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    private func launch(_ input: Input) async throws {
        switch input.data.type {
        case .app:
            try await client.launchApplication(input.id, className: input.data.className, action: input.data.action)
        case .source:
            if input.id == JointSpace.watchTVURI {
                try await client.launchWatchTV()
            } else if input.id == JointSpace.homeURI {
                try await client.launchHome()
            } else {
                try await client.setSource(input.id)
            }
        case .channel:
            // The tuner first, or the screen goes black when coming from an app; the channel is asked for anyway.
            if (try? await client.launchWatchTV()) == nil { logger.debug("Could not bring up the tuner before channel \(input.id)") }
            guard let number = Int(input.id) else { throw JointSpaceError.invalidResponse("channel \(input.id) is not a number") }
            try await client.setChannel(number)
        }
    }

    private func acquireLaunch() async {
        guard launching else {
            launching = true
            return
        }
        await withCheckedContinuation { launchWaiters.append($0) }
    }

    private func releaseLaunch() {
        if launchWaiters.isEmpty {
            launching = false
        } else {
            launchWaiters.removeFirst().resume()
        }
    }

    /// True when a source switch just asked for a different source: this wheel write is the leftover half
    /// of a scene. The wheel is put back on the source that won.
    private func supersededByRecentSwitch(_ input: Input) -> Bool {
        guard let recent = lastSwitchRequest, recent.id != input.id, ContinuousClock.now - recent.at <= Self.switchPrecedence,
              let winner = inputs.first(where: { $0.id == recent.id }) else { return false }
        logger.info("Ignoring input \(input.name): \(winner.name) was just selected from its switch. If a scene sets both, remove the one you did not intend; to pick \(input.name), choose it again.")
        currentIdentifier = winner.identifier
        observer?(.input(identifier: winner.identifier, id: winner.id))
        return true
    }

    private func park(_ input: Input, generation: Int, reason: String) {
        wakeSelection = (input, generation, .now)
        currentIdentifier = input.identifier
        observer?(.input(identifier: input.identifier, id: input.id))
        logger.info("\(reason); switching to \(input.name) once it is ready")
        if isOn { Task { [weak self] in await self?.replayWakeSelection() } }
    }

    private func clearWakeSelection() {
        if let parked = wakeSelection {
            logger.debug("Dropping the pending switch to \(parked.input.name): the TV was switched off")
            wakeSelection = nil
        }
    }

    /// Applies a parked selection once the TV is up: a launch the TV acknowledges while booting is dropped,
    /// so each attempt is checked against what the TV then reports.
    private func replayWakeSelection() async {
        guard let parked = wakeSelection else { return }
        wakeSelection = nil
        if ContinuousClock.now - parked.parkedAt > Self.wakeReplayWindow {
            logger.debug("Discarding the stale pending switch to \(parked.input.name)")
            return
        }
        for attempt in 1...Self.wakeReplayAttempts {
            guard switchGeneration == parked.generation else {
                logger.debug("Abandoning the pending switch to \(parked.input.name): superseded")
                return
            }
            await acquireLaunch()
            var launched = false
            if switchGeneration == parked.generation {
                launched = (try? await launch(parked.input)) != nil
            }
            releaseLaunch()
            if launched, await launchTookEffect(parked.input) {
                guard switchGeneration == parked.generation else { return }
                commitSelection(parked.input)
                logger.info("Switched to \(parked.input.name) after the TV woke")
                return
            }
            if attempt < Self.wakeReplayAttempts { try? await Task.sleep(for: Self.wakeReplayRetry) }
        }
        logger.warning("Could not switch to \(parked.input.name) after the TV woke")
    }

    private func launchTookEffect(_ input: Input) async -> Bool {
        try? await Task.sleep(for: Self.wakeConfirmSettle)
        guard let reported = try? await client.currentActivity() else { return false }
        if reported == input.id { return true }
        if Inputs.isLauncher(reported) { return input.id == JointSpace.homeURI }
        if reported == Inputs.playTVPackage { return input.data.type == .source && input.id != JointSpace.homeURI }
        if reported == Inputs.noAppReport { return true }
        logger.debug("The TV is on \(reported), not \(input.name); retrying")
        return false
    }

    private func commitSelection(_ input: Input) {
        currentIdentifier = input.identifier
        pendingIdentifier = input.identifier
        pendingSince = .now
        awaitingWakeAlignment = false
        observer?(.input(identifier: input.identifier, id: input.id))
    }

    /// Reconciles the wheel with the app the TV reports.
    private func applyCurrentApp(_ app: String) {
        if app != currentApp {
            currentApp = app
            logger.debug("Foreground: \(app)")
        }
        let direct = inputs.first { $0.id == app }
        guard let input = direct ?? inputs.first(where: { $0.id == resolve(app) }) else {
            ambiguousReport = nil
            return
        }
        if let direct, direct.data.type == .app, app != Inputs.noAppReport, app != Inputs.playTVPackage {
            tvTrackedApps.insert(direct.id)
        }
        // "No trackable app" is an absence of information while an app the TV never names is on screen.
        if direct == nil, app == Inputs.noAppReport, isOnUntrackedApp {
            ambiguousReport = nil
            return
        }
        if direct == nil, app == Inputs.noAppReport || app == Inputs.playTVPackage {
            guard recordAmbiguousSighting(app) else { return }
        } else {
            ambiguousReport = nil
        }
        if let pending = pendingIdentifier {
            if input.identifier == pending {
                pendingIdentifier = nil
            } else if let since = pendingSince, ContinuousClock.now - since < Self.pendingConfirmTimeout {
                return
            } else {
                pendingIdentifier = nil
            }
        }
        awaitingWakeAlignment = false
        guard input.identifier != currentIdentifier else { return }
        currentIdentifier = input.identifier
        logger.debug("Input: \(input.name)")
        observer?(.input(identifier: input.identifier, id: input.id))
    }

    /// System packages to the input they stand for: the launcher is Home; the tuner package is Watch TV
    /// or the HDMI input already current; a sustained "NA" is Home.
    private func resolve(_ app: String) -> String {
        if Inputs.isLauncher(app) { return JointSpace.homeURI }
        if app == Inputs.playTVPackage {
            if let current = inputs.first(where: { $0.identifier == currentIdentifier }), current.data.type == .source, current.id != JointSpace.homeURI {
                return current.id
            }
            return JointSpace.watchTVURI
        }
        if app == Inputs.noAppReport { return JointSpace.homeURI }
        return app
    }

    private var isOnUntrackedApp: Bool {
        guard !awaitingWakeAlignment, let current = inputs.first(where: { $0.identifier == currentIdentifier }) else { return false }
        return current.data.type == .app && !tvTrackedApps.contains(current.id)
    }

    private func recordAmbiguousSighting(_ app: String) -> Bool {
        let now = ContinuousClock.now
        if var report = ambiguousReport, report.app == app, now - report.lastSeen <= Self.ambiguousWindow {
            report.sightings += 1
            report.lastSeen = now
            ambiguousReport = report
        } else {
            ambiguousReport = (app, 1, now)
        }
        return (ambiguousReport?.sightings ?? 0) >= Self.ambiguousSightings
    }
}

/// HomeKit's hue (0 to 360), saturation and brightness (0 to 100) against the TV's 0 to 255, and colour
/// temperatures to a hue and saturation.
enum ColorConversion {
    static func philipsColor(hue: Double, saturation: Double, brightness: Int) -> JointSpace.AmbilightConfiguration.Color {
        .init(hue: min(255, Int((hue / 360 * 255).rounded())), saturation: min(255, Int((saturation / 100 * 255).rounded())), brightness: min(255, Int((Double(brightness) / 100 * 255).rounded())))
    }

    static func homeKitColor(_ color: JointSpace.AmbilightConfiguration.Color) -> (hue: Double, saturation: Double, brightness: Int) {
        (min(360, (Double(color.hue) / 255 * 360).rounded()), min(100, (Double(color.saturation) / 255 * 100).rounded()), min(100, Int((Double(color.brightness) / 255 * 100).rounded())))
    }

    /// A colour temperature in mireds to the hue and saturation of that white (the black-body curve through
    /// an sRGB approximation), as HAP-NodeJS's ColorUtils does.
    static func hueAndSaturation(mireds: Int) -> (hue: Double, saturation: Double) {
        let kelvin = 1_000_000 / Double(max(1, mireds))
        let temperature = kelvin / 100
        var red: Double, green: Double, blue: Double
        if temperature <= 66 {
            red = 255
            green = 99.4708025861 * log(temperature) - 161.1195681661
            blue = temperature <= 19 ? 0 : 138.5177312231 * log(temperature - 10) - 305.0447927307
        } else {
            red = 329.698727446 * pow(temperature - 60, -0.1332047592)
            green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
            blue = 255
        }
        red = min(255, max(0, red)) / 255
        green = min(255, max(0, green)) / 255
        blue = min(255, max(0, blue)) / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        let saturation = maximum == 0 ? 0 : delta / maximum * 100
        return (hue.rounded(), saturation.rounded())
    }
}
