import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Somfy TaHoma, Connexoon and Switch, Atlantic Cozytouch and the other Overkiz setups: each device of the setup as an
/// accessory chosen from its uiClass and widget (shutters, blinds, awnings, garage doors and gates, locks, alarms,
/// lights, sensors, heaters, water heaters), and its scenarios as switches. A Somfy account with one gateway talks to
/// the gateway's local API (Developer Mode, its certificate checked against the Overkiz Root CA) once it minted a token
/// for it, and to the cloud when the gateway does not answer.
///
/// The block is homebridge-tahoma's (`Tahoma`), so a Homebridge configuration works unchanged; this is a clean-room
/// implementation from the functional spec in docs/clean-room/Tahoma.md. See README.md in this directory.
public actor TahomaPlugin: HomeswiftPlugin {
    /// What the plugin uses to reach Overkiz; tests swap it for fakes, and shorten the delays with `timeScale`.
    struct Dependencies: Sendable {
        var cloudHTTP: any HTTPSending = HTTPClient(maximumBodySize: 16 * 1024 * 1024)
        /// The client for a gateway: its certificate must be one the Overkiz Root CA signed, naming
        /// `gateway-<PIN>.local` when the PIN is known.
        var localHTTP: @Sendable (_ pin: String?) -> any HTTPSending = { pin in
            HTTPClient(tls: .authority(pem: OverkizRootCA.pem, serverName: pin.map(TahomaPlugin.gatewayHostName)), maximumBodySize: 16 * 1024 * 1024)
        }
        /// The gateways announcing `_kizboxdev._tcp`, browsed for `duration` or until the one of `pin` answers.
        var browseGateways: @Sendable (_ duration: Duration, _ pin: String?) async -> [GatewayAnnouncement] = { duration, pin in
            await GatewayAnnouncement.browse(for: duration, pin: pin)
        }
        /// Multiplies every interval, timeout and delay: 1 for real devices.
        var timeScale: Double = 1
        var now: @Sendable () -> Date = { Date() }
    }

    public static let platform = "Tahoma"
    public static let name = "Somfy TaHoma"
    public static let icon: String? = "blind"
    public static let summary: String? = "Somfy TaHoma, Connexoon and Cozytouch shutters, heaters and sensors"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    let store = StateStore()
    let wakeup = Wakeup()
    private(set) var executions: Executions!
    /// The client in use, cloud or local.
    private(set) var client: OverkizClient?
    /// The mappers of the exposed devices, by deviceURL, and each attached sensor's owner.
    private(set) var mappers: [String: Mapper] = [:]
    private var owners: [String: String] = [:]
    private(set) var devices: [OverkizDevice] = []
    /// The listing's devices by deviceURL, for the event path.
    private(set) var deviceIndex: [String: OverkizDevice] = [:]
    /// The scenarios `exposeScenarios` puts in HomeKit, Excluded ones included: what Setup lists and the settings
    /// resolve names against.
    private(set) var listedScenarios: [OverkizScenario] = []
    /// Those of them with an accessory: neither in `exclude` nor Excluded.
    private(set) var scenarios: [OverkizScenario] = []
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    let localToken: SecretFile<LocalToken>
    /// The account's sign-in pause, kept across the clients `run()` makes one after another.
    let signInLockout = SignInLockout()
    /// Setup's checks of an account typed in, by service and user: three tries, then the same pauses, so a loop of wrong
    /// passwords does not get the account banned. Kept by the process: a plugin not added yet is made anew at each step.
    private static let setupLockouts = NIOLockedValueBox<[String: SignInLockout]>([:])

    static func setupLockout(service: OverkizService, user: String) -> SignInLockout {
        setupLockouts.withLockedValue { all in
            let key = "\(service.rawValue)/\(user.lowercased())"
            if let lockout = all[key] { return lockout }
            let lockout = SignInLockout(grace: 2)
            all[key] = lockout
            return lockout
        }
    }
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        localToken = context.secretFile("local-token.json", as: LocalToken.self)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }
    static func scenarioDeviceID(oid: String) -> String { "scene:\(oid)" }
    static func gatewayHostName(pin: String) -> String { "gateway-\(pin).local" }

    static func isPIN(_ text: String) -> Bool { text.range(of: #"^[0-9]{4}-[0-9]{4}-[0-9]{4}$"#, options: .regularExpression) != nil }
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    func scaled(_ seconds: Double) -> Duration { scaledDuration(seconds, by: dependencies.timeScale) }

    var debugLogging: Bool { configuration.debug == true }

    // MARK: Periods (2.1)

    var service: OverkizService? { account.flatMap { OverkizService(configured: $0.service) } }

    /// `pollingPeriod` in seconds, with the cloud's floor; 0 polls only while something runs.
    func pollingPeriod(log: Bool = false) -> Double {
        let configured = min(configuration.pollingPeriod?.value ?? 60, 86400)
        guard service != .local else { return max(0, configured) }
        if configured != 0, configured < 10 {
            if log { logger.error("pollingPeriod \(configured) is below 10 seconds: 60 is used") }
            return 60
        }
        if log, configured != 0, configured < 30 { logger.warning("A pollingPeriod below 30 seconds is discouraged: Overkiz may ban the account") }
        if log, configured > 60 { logger.warning("A pollingPeriod above 60 seconds may let the server drop the event listener") }
        return max(0, configured)
    }

    var execPollingPeriod: Double { min(max(1, configuration.execPollingPeriod?.value ?? 5), 3600) }

    func refreshPeriod(log: Bool = false) -> Double {
        let minutes = min(configuration.refreshPeriod?.value.flatMap { $0 > 0 ? $0 : nil } ?? 30, 7 * 1440)
        if log, minutes < 30 { logger.warning("A refreshPeriod below 30 minutes is discouraged") }
        return minutes
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard let account else {
            if !context.accessories.isEmpty {
                logger.error("No Overkiz account: set user and password, or sign in through Add accessories")
            }
            return
        }
        guard OverkizService(configured: account.service) != nil else {
            logger.error("Invalid service name: \(account.service)")
            return
        }
        if account.service == "local", !Self.isPIN(account.user), !Self.isIPv4(account.user) {
            logger.error("Invalid username. Please provide gateway PIN (XXXX-XXXX-XXXX) or gateway IP")
            return
        }
        _ = pollingPeriod(log: true)
        _ = refreshPeriod(log: true)
        let wakeup = wakeup
        executions = Executions(
            timings: Executions.Timings(
                window: scaled(0.1), timeout: scaled(120), busy: Backoff(initial: scaled(5), maximum: scaled(60), jitter: .proportional(0.3))),
            logger: logger,
            client: { [weak self] in await self?.client }, started: { wakeup.signal() })
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        tasks.cancelAll()
        await executions?.stop()
        for mapper in mappers.values { mapper.stop() }
        endRefreshWait()
    }

    /// Connects and lists the setup, again after a failure (60 s, doubling, at most an hour), then follows its events
    /// and refreshes its states.
    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let client = try await connect()
                self.client = client
                try await discover(using: client)
                break
            } catch is CancellationError {
                return
            } catch {
                let delay = Backoff(initial: scaled(60), maximum: scaled(3600)).delay(attempt: attempt)
                // Once per outage at error, the retries after at debug.
                let level: Logger.Level = attempt == 0 ? .error : .debug
                logger.log(level: level, "\(error)")
                logger.log(level: level, "Retry in \(Int(delay.components.seconds)) sec...")
                attempt += 1
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        tasks.add { [weak self] in await self?.pollEvents() }
        tasks.add { [weak self] in await self?.refreshLoop() }
    }

    // MARK: Discovery (6.1)

    /// Lists the setup (or takes the listing given) and builds an accessory per exposed device, then the scenarios;
    /// removes the others.
    func discover(using client: OverkizClient, listed given: [OverkizDevice]? = nil) async throws {
        let exposesScenarios = configuration.exposeScenarios?.exposesAny == true
        async let listing = given == nil ? client.devices() : given!
        async let scenarioListing = exposesScenarios ? client.scenarios() : []
        async let country = given == nil ? (try? await client.countryCode()) : nil
        let listed = try await listing, scenarios = try await scenarioListing
        if let country = await country { await executions.setLanguage(country == "fr" ? "fr" : "en") }
        build(listed, scenarios: scenarios)
        var kept = Set(mappers.keys.map(Self.accessoryID(deviceID:)))
        kept.formUnion(self.scenarios.map { Self.accessoryID(deviceID: Self.scenarioDeviceID(oid: $0.oid)) })
        _ = await context.removeAccessories(keeping: kept)
    }

    var exclusions: Set<String> { DeviceGrouping.builtInExclusions.union(configuration.exclude ?? []) }

    /// The accessories of a listing, replacing those there are.
    private func build(_ listed: [OverkizDevice], scenarios listedScenarios: [OverkizScenario]) {
        for mapper in mappers.values { mapper.stop() }
        mappers = [:]
        owners = [:]
        setDevices(listed)
        store.replaceAll(listed)
        let exclusions = exclusions
        let environment = mapperEnvironment
        for group in DeviceGrouping.group(listed) {
            let device = group.device
            guard !DeviceGrouping.isExcluded(device, by: exclusions), !context.isExcluded(device.deviceURL) else { continue }
            guard let type = MapperTable.mapper(for: device) else {
                logger.warning("\(device.uiClass) > \(device.widgetName) not supported.")
                continue
            }
            let options = options(for: device)
            logger.info("Configure device \(device.label)")
            logger.info("  \(device.uiClass) > \(device.widgetName)")
            let optionsText = "Options of \(device.label): \(String(describing: options))"
            if debugLogging { logger.info("\(optionsText)") } else { logger.debug("\(optionsText)") }
            let mapper = type.init(device: device, sensors: group.sensors, parent: group.parent, options: options, environment: environment)
            var services: [Service] = []
            do {
                services = try mapper.build()
            } catch {
                logger.warning("\(device.label): \(error)")
            }
            let id = Self.accessoryID(deviceID: device.deviceURL)
            let cached = context.accessory(id: id)
            if cached == nil { logger.info("Create accessory: \(device.label)") }
            let accessory = Accessory(
                id: id, name: device.label, manufacturer: device.states["core:ManufacturerNameState"]?.stringValue ?? "Somfy",
                model: device.states["core:ModelState"]?.stringValue ?? device.uiClass, serialNumber: device.serialNumber,
                category: type.category, services: services)
            if let cached { accessory.takeValues(from: cached) }
            do {
                try context.add(accessory)
            } catch {
                logger.warning("\(device.label): \(error)")
                continue
            }
            mappers[device.deviceURL] = mapper
            owners[device.deviceURL] = device.deviceURL
            for sensor in group.sensors { owners[sensor.deviceURL] = device.deviceURL }
            mapper.receiveCurrentStates()
            showAvailability(of: device.deviceURL, available: device.available)
        }
        buildScenarios(listedScenarios)
    }

    private func setDevices(_ listed: [OverkizDevice]) {
        devices = listed
        deviceIndex = Dictionary(listed.map { ($0.deviceURL, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Changed states of a device to the mapper that shows it, and its availability.
    private func deliver(_ deviceURL: String, _ states: [String: JSONValue], available: Bool?) {
        let changed = store.apply(deviceURL, states)
        if !changed.isEmpty, let owner = owners[deviceURL], let mapper = mappers[owner] { mapper.receive(changed, from: deviceURL, log: true) }
        if let available, mappers[deviceURL] != nil { showAvailability(of: deviceURL, available: available) }
    }

    var mapperEnvironment: MapperEnvironment {
        MapperEnvironment(
            executions: executions, store: store, logger: logger, timeScale: dependencies.timeScale,
            refreshDevice: { [weak self] url in await self?.refreshDevice(url) }, now: dependencies.now)
    }

    /// No Response for a device the server says is unavailable (6.5).
    private func showAvailability(of deviceURL: String, available: Bool) {
        let unavailable = !available || store.value(deviceURL, "core:StatusState")?.stringValue == "unavailable"
        guard let accessory = context.accessory(id: Self.accessoryID(deviceID: deviceURL)), accessory.isUnavailable != unavailable else { return }
        accessory.isUnavailable = unavailable
    }

    /// A device's options (2.4): the `devicesConfig` entries whose key is its protocol, uiClass, widget, label, the
    /// Homebridge accessory's UUID or its deviceURL, merged in that order (later wins), then its Accessory Settings.
    func options(for device: OverkizDevice) -> DeviceOptions {
        var byKey: [String: [String: JSONValue]] = [:]
        for entry in configuration.devicesConfig ?? [] {
            guard let fields = entry.objectValue, let key = fields["key"]?.scalarText else { continue }
            byKey[key] = fields
        }
        var merged: [String: JSONValue] = [:]
        for key in [device.protocolName, device.uiClass, device.widgetName, device.label, device.legacyUUID, device.deviceURL] {
            for (name, value) in byKey[key] ?? [:] where name != "key" { merged[name] = value }
        }
        for (name, value) in context.accessorySettings(for: device.deviceURL).plugin where !value.isNull { merged[name] = value }
        return DeviceOptions(merged)
    }

    // MARK: Scenarios (5.12)

    private func buildScenarios(_ listed: [OverkizScenario]) {
        let choice = configuration.exposeScenarios ?? .all(false)
        let exclusions = exclusions
        listedScenarios = listed.filter { !$0.label.isEmpty && !$0.label.hasPrefix("internal:") && choice.exposes($0.label) }
        scenarios = listedScenarios.filter { !exclusions.contains($0.label) && !context.isExcluded(Self.scenarioDeviceID(oid: $0.oid)) }
        for scenario in scenarios {
            let id = Self.accessoryID(deviceID: Self.scenarioDeviceID(oid: scenario.oid))
            let power = Service(.switch, name: scenario.label, isPrimary: true)
            power.characteristic(.on).value = false
            let running = NIOLockedValueBox<String?>(nil)
            let executions = executions!, logger = logger, label = scenario.label, oid = scenario.oid
            let on = power.characteristic(.on)
            on.onWrite { [weak self, weak on] value in
                if value.boolValue == true {
                    guard let client = await self?.client else { throw HAPStatusError(.serviceCommunicationFailure) }
                    let target = on
                    do {
                        let execID = try await client.runScenario(oid: oid)
                        running.withLockedValue { $0 = execID }
                        await executions.track(execID) { update in
                            guard update.state.isFinal else { return }
                            logger.info("[Scene] \(label) \(update.state == .completed ? "COMPLETED" : update.failureType ?? update.state.rawValue)")
                            running.withLockedValue { $0 = nil }
                            target?.value = false
                        }
                    } catch {
                        logger.error("[Scene] \(label) \(error)")
                        throw HAPStatusError(.serviceCommunicationFailure)
                    }
                } else if let execID = running.withLockedValue({ $0 }) {
                    try? await executions.cancel(execID)
                }
            }
            if context.accessory(id: id) == nil { logger.info("Map scene \(scenario.label)") }
            try? context.add(Accessory(id: id, name: scenario.label, manufacturer: "Somfy", model: "Scenario", category: .switch, services: [power]))
        }
    }

    // MARK: Events (6.2)

    /// Fetches events every `pollingPeriod` seconds, every `execPollingPeriod` while an execution runs, registering the
    /// listener when there is none; a failure waits 10 s, doubling up to 10 minutes, and is logged once per outage.
    private func pollEvents() async {
        var listener: String?
        var session = 0
        var failures = 0
        let backoff = Backoff(initial: scaled(10), maximum: scaled(600), jitter: .proportional(0.1))
        let polling = pollingPeriod()
        if polling == 0 { logger.debug("Disable event polling") } else { logger.debug("Enable event polling period every \(Int(polling)) sec") }
        while !Task.isCancelled {
            let running = await executions.inFlight > 0
            // A refresh waiting for its completion event is fetched as an execution is, even when polling is off.
            let period = running || (polling == 0 && refreshWaiter != nil) ? execPollingPeriod : polling
            if period == 0 {
                listener = nil
                await wakeup.wait(for: nil)
                continue
            }
            if listener != nil { await wakeup.wait(for: scaled(period)) }
            guard !Task.isCancelled, let client else { return }
            // A refreshed Somfy token is a new session, whose listener is a new one (11.4).
            let generation = await client.sessionGeneration
            if generation != session {
                session = generation
                listener = nil
            }
            let registering = listener == nil
            do {
                if registering { listener = try await client.registerListener() }
                let events = try await client.fetchEvents(listener: listener!)
                if failures > 0 { logger.info("Events arrive again") }
                failures = 0
                await handle(events)
            } catch is CancellationError {
                return
            } catch {
                let message = registering ? "Registration error - \(error)" : "Polling error - \(error)"
                if failures == 0 { logger.error("\(message)") } else { logger.debug("\(message)") }
                if let status = (error as? OverkizError)?.status, [400, 401, 404].contains(status) { listener = nil }
                let delay = backoff.delay(attempt: failures)
                failures += 1
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    /// Applies a batch of events.
    func handle(_ events: [OverkizEvent]) async {
        for event in events {
            switch event {
            case .deviceStateChanged(let url, let states):
                // Availability only when the status changed (the listing's flag stands otherwise).
                let available = states["core:StatusState"] != nil && store.value(url, "core:StatusState") != states["core:StatusState"]
                deliver(url, states, available: available ? (deviceIndex[url]?.available ?? true) : nil)
            case .executionStateChanged(let execID, let state, let final, let failureType, let failed):
                await executions.handle(execID: execID, newState: state, final: final, failureType: failureType, failedDevices: failed)
            case .refreshAllCompleted:
                logger.debug("Refresh all states completed")
                endRefreshWait()
            }
        }
    }

    // MARK: Refresh (6.3)

    /// Every `refreshPeriod` minutes: asks the gateway to poll every device, waits for it (at most 30 s), lists the setup
    /// again and applies what changed; a setup whose devices changed is built again (6.5).
    private func refreshLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: scaled(refreshPeriod() * 60)) } catch { return }
            await refreshAll()
        }
    }

    func refreshAll() async {
        guard let client else { return }
        try? await client.refreshAllStates()
        await waitForRefresh(timeout: scaled(30))
        do {
            let listed = try await client.devices()
            if Set(listed.map(\.deviceURL)) != Set(deviceIndex.keys) {
                logger.info("The setup's devices changed: building its accessories again")
                try await discover(using: client, listed: listed)
                return
            }
            setDevices(listed)
            for device in listed { deliver(device.deviceURL, device.states, available: device.available) }
        } catch {
            logger.error("Refresh error - \(error)")
        }
    }

    private func waitForRefresh(timeout: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.endRefreshWait()
        }
        await withCheckedContinuation { continuation in
            refreshWaiter?.resume()
            refreshWaiter = continuation
            wakeup.signal()
        }
        timer.cancel()
    }

    private func endRefreshWait() {
        refreshWaiter?.resume()
        refreshWaiter = nil
    }

    func refreshDevice(_ deviceURL: String) async {
        try? await client?.refreshStates(deviceURL: deviceURL)
    }
}

/// Wakes a waiting loop early: the event loop when an execution starts.
final class Wakeup: Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())

    func signal() {
        let waiter = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Waits `duration` (forever when nil), or until `signal()`, or until the task is cancelled.
    func wait(for duration: Duration?) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.signalled() }
            if let duration { group.addTask { try? await Task.sleep(for: duration) } }
            await group.next()
            group.cancelAll()
            self.release()
        }
    }

    private func signalled() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLockedValue { state -> Bool in
                    if state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.waiter?.resume()
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            self.release()
        }
    }

    private func release() {
        state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            defer { state.waiter = nil }
            return state.waiter
        }?.resume()
    }
}
