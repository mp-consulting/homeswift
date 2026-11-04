import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Ring's alarm, Smart Lighting, cameras, doorbells, chimes and intercoms, from Ring's cloud: the alarm and lighting
/// hubs over each location's WebSocket, cameras and chimes by polling `ring_devices`, dings and motion by push (an FCM
/// receiver), as the Homebridge plugin `homebridge-ring` does. Cameras are accessories of their own (snapshots, motion,
/// doorbell); live video needs WebRTC, which Homeswift has not.
///
/// The configuration is the one of `homebridge-ring` (platform `Ring`), so a Homebridge block works unchanged; its
/// `refreshToken` moves into the vault, where the rotated tokens go. Written from the functional specification in
/// docs/clean-room/Ring.md. See README.md in this directory.
///
/// Security System Target State, Lock Target State and the Panic Buttons are security controls: the MCP server and the
/// Assistant write them only through set_security_accessory.
public actor RingPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// The Homebridge plugin's token (a wrapper of the refresh token, the hardware id and its push credentials, or a
        /// bare refresh token): read once, then kept in the vault.
        public var refreshToken: String?
        public var alarmOnEntryDelay: Bool?
        public var hideLightGroups: Bool?
        public var hideDoorbellSwitch: Bool?
        public var hideCameraLight: Bool?
        public var hideCameraMotionSensor: Bool?
        public var hideCameraSirenSwitch: Bool?
        public var hideInHomeDoorbellSwitch: Bool?
        public var hideAlarmSirenSwitch: Bool?
        public var showPanicButtons: Bool?
        public var nightModeBypassFor: String?
        public var avoidSnapshotBatteryDrain: Bool?
        public var beamDurationSeconds: Int?
        public var debug: Bool?
        public var disableLogs: Bool?
        public var cameraStatusPollingSeconds: Int?
        public var locationModePollingSeconds: Int?
        /// Homebridge UUIDs of the accessories to leave out.
        public var hideDeviceIds: [String]?
        public var locationIds: [String]?
        public var onlyDeviceTypes: [String]?
        /// Unused: there is no live video to transcode.
        public var ffmpegPath: String?
        /// The name Ring's Control Center shows for this client.
        public var controlCenterDisplayName: String?

        var cameraPolling: Int { max(cameraStatusPollingSeconds ?? 20, 0) }
        var locationModePolling: Int { max(locationModePollingSeconds ?? 20, 0) }
        var displayName: String { controlCenterDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? "homebridge-ring" }
    }

    /// What the plugin reaches Ring with; tests swap them for fakes.
    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient()
        var connectWebSocket: RingLocationHub.Connect = { url in
            var options = WebSocket.Options()
            options.heartbeat = .seconds(60)
            return try await WebSocket.connect(to: url, options: options)
        }
        var push: @Sendable (FCMCredentials?, Logger) -> (any RingPushSource)? = { credentials, logger in
            FCMReceiver(configuration: RingPush.configuration, credentials: credentials, logger: logger)
        }
        var timing = RingTiming()
    }

    public static let platform = "Ring"
    public static let name = "Ring"
    public static let icon: String? = "bell"
    public static let summary: String? = "Ring alarms, cameras, doorbells, chimes and Smart Lighting"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var logger: Logger { context.logger }
    private(set) var client: RingClient?
    private var push: (any RingPushSource)?
    private var pushReadyAt: ContinuousClock.Instant?
    private var pushCredentialsChanged = false
    private var pushFailures = 0
    private var hubs: [String: RingLocationHub] = [:]
    /// What shows each device's data, by zid or REST id.
    private let updaters = NIOLockedValueBox<[String: [@Sendable (JSONValue) -> Void]]>([:])
    private var cameras: [String: RingCamera] = [:]
    private var intercoms: [String: RingIntercom] = [:]
    private var locationModes: [RingLocationMode] = []
    /// Every accessory this run made, by Device Id (its seed), for discovery.
    private(set) var built: [String: (name: String, deviceType: String, isCamera: Bool)] = [:]
    /// The seeds of every accessory this run could make, hidden ones too: what `hideDeviceIds` may name.
    private(set) var knownSeeds: Set<String> = []
    private var restIDs: Set<String> = []
    private var pollSleeper: Task<Void, Never>?
    private var lastRefreshRequest: ContinuousClock.Instant?
    private var lastResubscribe: ContinuousClock.Instant?
    lazy var memory = PersistedDictionary<RingMemory>(url: context.storageDirectory.appendingPathComponent("ring-accessories.json"), logger: context.logger)

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(seed: String) -> String { "\(platform):\(seed)" }

    public func start() async throws {
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        tasks.cancelAll()
        pollSleeper?.cancel()
        await push?.stop()
        for hub in hubs.values { await hub.stop() }
        await client?.shutdown()
        try? memory.flush()
    }

    // MARK: Start-up

    private func run() async {
        guard let account = loadAccount() else {
            logger.warning("Ring is not set up: sign in to the Ring account through Add accessories")
            return
        }
        let context = context, logger = logger
        let client = RingClient(
            http: dependencies.http, account: account, displayName: configuration.displayName, timing: dependencies.timing, logger: logger
        ) { [weak self] previous, rotated in
            // Stored at once: Ring's refresh tokens are single use.
            guard let self else { return }
            self.saveRotated(rotated, replacing: previous, context: context, logger: logger)
        }
        self.client = client
        await client.setOnSessionCreated { [weak self] in await self?.sessionCreated() }
        startPush()

        let attempt = Backoff(initial: .seconds(5), maximum: .seconds(300), jitter: .proportional(0.2))
        var failures = 0
        while !Task.isCancelled {
            do {
                try await discoverAccessories(client: client)
                break
            } catch is CancellationError {
                return
            } catch RingError.notAuthorized {
                logger.error("\(RingError.notAuthorized)")
                return
            } catch {
                if failures == 0 { logger.error("Could not reach Ring: \(error)") }
                failures += 1
                try? await Task.sleep(for: attempt.delay(attempt: failures - 1))
            }
        }
        startPolling(client: client)
    }

    /// Saves a rotated token, unless the vault holds another account's by now (Setup signed in again meanwhile).
    nonisolated func saveRotated(_ account: RingAccount, replacing previous: RingAccount, context: PluginContext, logger: Logger) {
        if let stored = context.credentials(as: RingAccount.self), stored.refreshToken != previous.refreshToken { return }
        do { try context.saveCredentials(account) } catch { logger.error("Could not store Ring's new refresh token: \(error)") }
    }

    /// The account: the vault's, or the block's `refreshToken` when it is new (a Homebridge block pasted in), which is
    /// moved into the vault at once since Ring rotates it on first use.
    func loadAccount() -> RingAccount? {
        let stored = context.credentials(as: RingAccount.self)
        if let token = configuration.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let fingerprint = RingIdentity.sha256(token)
            if stored?.importedFrom != fingerprint {
                let wrapper = RingTokenWrapper(parsing: token)
                let account = RingAccount(
                    refreshToken: wrapper.refreshToken, hardwareId: wrapper.hardwareID ?? stored?.hardwareId ?? hardwareID(),
                    wrapper: wrapper.others.isEmpty ? nil : wrapper.others, importedFrom: fingerprint)
                do { try context.saveCredentials(account) } catch { logger.error("Could not store the Ring account in the vault: \(error)") }
                return account
            }
        }
        return stored.flatMap { $0.refreshToken.isEmpty ? nil : $0 }
    }

    /// The hardware id for a new token: UUID v5 of `.ring.json`'s system id (made once, kept).
    nonisolated func hardwareID() -> String {
        let file = context.jsonFile(".ring.json", as: [String: String].self)
        if let systemID = file.load()?["systemId"], !systemID.isEmpty { return RingIdentity.hardwareID(systemID: systemID) }
        let systemID = RingIdentity.newSystemID()
        try? file.save(["systemId": systemID])
        return RingIdentity.hardwareID(systemID: systemID)
    }

    var environment: RingEnvironment {
        get throws {
            guard let client else { throw RingError.unexpected("not connected") }
            return RingEnvironment(
                configuration: configuration, timing: dependencies.timing, logger: logger, client: client, memory: memory, tasks: tasks,
                requestRefresh: { [weak self] in Task { await self?.refreshSoon() } })
        }
    }

    /// Locations, REST devices, each hub location's devices; then the accessories, in the original's order.
    private func discoverAccessories(client: RingClient) async throws {
        var locations = try await client.locations()
        if let only = configuration.locationIds {
            locations = locations.filter { only.contains($0["location_id"]?.stringValue ?? "") }
            if locations.isEmpty { logger.error("No locations: locationIds lists none of the account's") }
        }
        for location in locations {
            logger.info("locationId: \(location["location_id"]?.stringValue ?? "") - \(location["name"]?.stringValue ?? "")")
        }
        let devices = try await client.ringDevices()
        let environment = try environment

        let other = devices["other"]?.arrayValue ?? []
        let doorbells = (devices["doorbots"]?.arrayValue ?? []) + (devices["authorized_doorbots"]?.arrayValue ?? [])
        let cameraData = doorbells.map { ($0, true) } + (devices["stickup_cams"]?.arrayValue ?? []).map { ($0, false) }
            + other.filter { $0["kind"]?.stringValue == "onvif_camera" }.map { ($0, false) }
        let chimes = devices["chimes"]?.arrayValue ?? []
        let intercomData = other.filter { ["intercom_handset_audio", "intercom_handset_video"].contains($0["kind"]?.stringValue ?? "") }
        let baseStations = Set((devices["base_stations"]?.arrayValue ?? []).compactMap { $0["location_id"]?.stringValue })
        let hubLocations = baseStations.union((devices["beams_bridges"]?.arrayValue ?? []).compactMap { $0["location_id"]?.stringValue })

        var accessories: [(built: RingBuiltAccessory, external: Bool)] = []
        for location in locations {
            guard let locationID = location["location_id"]?.stringValue else { continue }
            let locationName = location["name"]?.stringValue ?? locationID
            let inLocation: (JSONValue) -> Bool = { $0["location_id"]?.stringValue == locationID }
            var built: [RingBuiltAccessory] = []
            if hubLocations.contains(locationID) {
                let hub = hubs[locationID] ?? RingLocationHub(
                    locationID: locationID, name: locationName, client: client, timing: dependencies.timing, logger: logger,
                    connect: dependencies.connectWebSocket)
                hubs[locationID] = hub
                hub.inventory.onChange.withLockedValue { [updaters] in
                    $0 = { zid, data in for update in updaters.withLockedValue({ $0[zid] ?? [] }) { update(data) } }
                }
                await hub.start()
                if await !hub.waitUntilReady(timeout: dependencies.timing.hubListTimeout) {
                    logger.warning("The hubs of \(locationName) did not list their devices in time; showing what they sent")
                }
                for device in hub.inventory.all {
                    if let accessory = RingHubAccessories.make(zid: device.zid, data: device.data, hub: hub, environment: environment) {
                        built.append(accessory)
                    } else if let type = device.data["deviceType"]?.stringValue, !RingHubAccessories.quietTypes.contains(type) {
                        logger.info("Hidden accessory \(RingIdentity.homebridgeUUID(device.zid)) \(type) \(device.data["name"]?.stringValue ?? "")")
                    }
                }
                if configuration.showPanicButtons == true,
                   let panel = hub.inventory.all.first(where: { $0.data["deviceType"]?.stringValue == "security-panel" }) {
                    built.append(RingHubAccessories.panicButtons(panelZid: panel.zid, data: panel.data, locationName: locationName, hub: hub, environment: environment))
                }
            }
            var external: [RingBuiltAccessory] = []
            let locationCameras = cameraData.filter { inLocation($0.0) }
            logger.info("Configuring \(locationCameras.count) cameras and \(built.count) devices for location \(locationName)")
            for (data, isDoorbell) in locationCameras {
                let camera = RingCamera(data: data, isDoorbell: isDoorbell, environment: environment)
                let accessory = try camera.makeAccessory()
                cameras[camera.id] = camera
                restIDs.insert(camera.id)
                external.append(RingBuiltAccessory(seed: "\(camera.id)camera", deviceType: camera.kind, accessory: accessory, update: { camera.update($0) }))
            }
            for data in chimes where inLocation(data) {
                let chime = RingChime.make(data: data, environment: environment)
                restIDs.insert(chime.seed)
                built.append(chime)
            }
            for data in intercomData where inLocation(data) {
                let intercom = RingIntercom(data: data, environment: environment)
                intercoms[intercom.id] = intercom
                restIDs.insert(intercom.id)
                built.append(RingBuiltAccessory(seed: intercom.id, deviceType: data["kind"]?.stringValue ?? "intercom", accessory: intercom.accessory, update: { intercom.update($0) }))
            }
            if configuration.locationModePolling > 0, !baseStations.contains(locationID), !locationCameras.isEmpty {
                if let mode = try? await client.locationMode(locationID), mode["readOnly"]?.boolValue != true,
                   let current = mode["mode"]?.stringValue, current != "disabled", current != "unset" {
                    let locationMode = RingLocationMode(locationID: locationID, locationName: locationName, mode: current, environment: environment)
                    locationModes.append(locationMode)
                    built.append(RingBuiltAccessory(seed: "\(locationID)mode", deviceType: "location.mode", accessory: locationMode.accessory, update: { _ in }))
                }
            }
            accessories += built.map { ($0, false) } + external.map { ($0, true) }
        }

        var kept: Set<String> = []
        for (accessory, external) in accessories {
            let uuid = RingIdentity.homebridgeUUID(accessory.seed)
            let name = accessory.accessory.name
            knownSeeds.insert(accessory.seed)
            if isHidden(accessory, uuid: uuid) {
                logger.info("Hidden accessory \(uuid) \(accessory.deviceType) \(name)")
                continue
            }
            built[accessory.seed] = (name, accessory.deviceType, external)
            for zid in [accessory.seed] + accessory.follows {
                updaters.withLockedValue { $0[zid, default: []].append(accessory.update) }
            }
            do {
                if external {
                    try await context.publishExternal(accessory.accessory)
                    logger.info("Configured camera \(uuid) \(accessory.deviceType) \(name)")
                } else {
                    try context.add(accessory.accessory)
                    logger.info("Adding new accessory \(uuid) \(accessory.deviceType) \(name)")
                }
                kept.insert(accessory.accessory.id)
            } catch {
                logger.error("Could not add \(name): \(error)")
            }
        }
        _ = await context.removeAccessories(keeping: kept, message: "Removing stale cached accessory")
        await subscribeAll(intercomsToo: true, devices: cameraData.map(\.0) + intercomData)
    }

    /// Hidden by the options (`hideLightGroups`, `hideDeviceIds`, `onlyDeviceTypes`) or Excluded in its settings.
    private func isHidden(_ accessory: RingBuiltAccessory, uuid: String) -> Bool {
        if configuration.hideLightGroups == true, accessory.deviceType == "group.light-group.beams" { return true }
        if configuration.hideDeviceIds?.contains(where: { $0.lowercased() == uuid }) == true { return true }
        if let only = configuration.onlyDeviceTypes, !only.isEmpty, !only.contains(accessory.deviceType) { return true }
        return context.isExcluded(accessory.seed)
    }

    /// Ring sends dings and motion only for cameras subscribed to them; intercoms at start, when not yet subscribed.
    private func subscribeAll(intercomsToo: Bool, devices: [JSONValue]? = nil) async {
        guard let client else { return }
        for id in cameras.keys where built["\(id)camera"] != nil {
            do {
                try await client.subscribe(id, motions: false)
                try await client.subscribe(id, motions: true)
            } catch {
                logger.warning("Could not subscribe \(cameras[id]?.name ?? id) to its events: \(error)")
            }
        }
        guard intercomsToo else { return }
        for data in devices ?? [] {
            guard let id = data["id"]?.idString, intercoms[id] != nil, built[id] != nil, data["subscribed"]?.boolValue != true else { continue }
            try? await client.subscribe(id, motions: false)
        }
    }

    /// After each session: the cameras subscribed again (at most once a second), the push token registered again.
    func sessionCreated() async {
        if let token = await push?.token { await registerPushToken(token) }
        let throttle = dependencies.timing.resubscribeThrottle
        if let last = lastResubscribe, .now - last < throttle { return }
        lastResubscribe = .now
        await subscribeAll(intercomsToo: false)
    }

    // MARK: Polling (3.5)

    private func startPolling(client: RingClient) {
        let interval = configuration.cameraPolling
        if interval > 0, !restIDs.isEmpty {
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    await self?.pollDevices()
                    guard let sleeper = await self?.makeSleeper(.seconds(interval)) else { return }
                    await sleeper.value
                }
            }
        }
        let modeInterval = configuration.locationModePolling
        if modeInterval > 0, !locationModes.isEmpty {
            let modes = locationModes
            tasks.add {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(modeInterval))
                    for mode in modes { try? await mode.fetch() }
                }
            }
        }
    }

    private func makeSleeper(_ interval: Duration) -> Task<Void, Never> {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: interval) }
        pollSleeper = sleeper
        return sleeper
    }

    /// A HomeKit read asked for fresh data: the next poll now, at most every 500 ms.
    func refreshSoon() {
        guard configuration.cameraPolling > 0 else { return }
        if let last = lastRefreshRequest, .now - last < dependencies.timing.refreshThrottle { return }
        lastRefreshRequest = .now
        pollSleeper?.cancel()
    }

    /// One fetch of `ring_devices`: each known device's data replaced by its new one.
    func pollDevices() async {
        guard let client, let devices = try? await client.ringDevices() else { return }
        let lists = ["doorbots", "authorized_doorbots", "stickup_cams", "chimes", "other"]
        for list in lists {
            for data in devices[list]?.arrayValue ?? [] {
                guard let id = data["id"]?.idString, restIDs.contains(id) else { continue }
                for update in updaters.withLockedValue({ $0[id] ?? $0["\(id)camera"] ?? [] }) { update(data) }
            }
        }
    }

    // MARK: Push (3.6, 11)

    private func startPush() {
        let secretFile = context.secretFile("ring-push.json", as: FCMCredentials.self)
        guard let push = dependencies.push(secretFile.load(), logger) else { return }
        self.push = push
        tasks.add { [weak self] in
            for await event in push.events { await self?.handle(event) }
        }
        tasks.add { await push.start() }
    }

    func handle(_ event: FCMReceiver.Event) async {
        switch event {
        case .credentialsChanged(let credentials):
            pushCredentialsChanged = true
            do { try context.secretFile("ring-push.json", as: FCMCredentials.self).save(credentials) } catch {
                logger.error("Could not store the push credentials: \(error)")
            }
            await registerPushToken(credentials.token)
        case .ready:
            if pushFailures > 0 { logger.info("Push notifications reconnected") }
            pushFailures = 0
            pushReadyAt = .now
            if !pushCredentialsChanged, let token = await push?.token {
                pushCredentialsChanged = true
                await registerPushToken(token)
            }
        case .message(let message):
            if let ready = pushReadyAt, .now - ready < dependencies.timing.pushQuiet {
                logger.debug("Ignoring push notification received in first two seconds")
                return
            }
            route(message.data)
        case .disconnected(let reason):
            pushFailures += 1
            if pushFailures == 2 {
                logger.warning("Push notifications from Ring keep failing (\(reason)): check that TCP port 5228 to mtalk.google.com is not blocked by a firewall or a DNS ad blocker")
            }
        }
    }

    func route(_ data: [String: String]) {
        switch RingPush.route(data) {
        case .notification(let notification):
            if let camera = cameras[notification.deviceID] {
                camera.handle(notification)
            } else if notification.category == RingNotification.intercom, let intercom = intercoms[notification.deviceID] {
                intercom.ding()
            } else {
                logger.debug("Push for an unknown device")
            }
        case .intercomUnlocked(let id):
            intercoms[id]?.showUnlocked()
        case .ignored:
            logger.debug("Push of an unknown kind")
        }
    }

    private func registerPushToken(_ token: String) async {
        guard let client else { return }
        do { try await client.registerPushToken(token) } catch { logger.warning("Could not register for Ring's push notifications: \(error)") }
    }

    // For tests and the Setup.
    var cameraList: [RingCamera] { Array(cameras.values) }
    func hub(_ locationID: String) -> RingLocationHub? { hubs[locationID] }
}
