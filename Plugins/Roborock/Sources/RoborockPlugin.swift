import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Roborock robot vacuums in HomeKit: each robot a Fan v2 that starts a clean and sends it home, its battery, the dock's
/// mop wash, the scenes of the Roborock app and the brushes and filter. The account signs in through Setup (an emailed
/// code, or a password); the robots answer on the LAN (TCP 58867, protocols 1.0 and L01; A01 and B01 experimental), and
/// through the cloud's MQTT broker when the LAN does not.
///
/// The configuration is the one of homebridge-roborock-vacuum (platform `RoborockVacuumPlatform`), so a Homebridge
/// block works unchanged; written from the functional specification in docs/clean-room/Roborock.md. See README.md.
public actor RoborockPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// A list written as an array or as text separated by commas and new lines.
        public struct List: Decodable, Sendable, Equatable {
            public var values: [String]

            public init(_ values: [String]) { self.values = values }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    values = Self.split(text)
                } else {
                    values = try container.decode([String].self).flatMap(Self.split)
                }
            }

            static func split(_ text: String) -> [String] {
                text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }

        public struct CurrentRoom: Decodable, Sendable {
            public var enabled: Bool?
            public var brokerUrl: String?
            public var topic: String?
            public var cleaningPollSeconds: Int?
        }

        public var name: String?
        public var email: String?
        public var password: String?
        public var encryptedToken: String?
        public var baseURL: String?
        public var language: String?
        public var skipDevices: List?
        public var matterDevices: List?
        public var matterSceneDevices: List?
        public var debugMode: Bool?
        public var currentRoomMqtt: CurrentRoom?
        /// Legacy: matched against a device's `sn` or duid; such devices are not polled.
        public var ignoredDevices: List?
    }

    /// What the plugin reaches the cloud and the robots with; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        var dialer: any LocalDialing = TCPDialer()
        var makeMQTT: @Sendable (MQTTConfiguration) -> any MQTTConnection = { MQTTClient($0) }
        /// nil: listen on UDP 58866.
        var discoverIPs: (@Sendable (Set<String>) async -> [String: String])?
        var timings = RoborockTimings.standard
        var now: @Sendable () -> Date = { Date() }
    }

    public static let platform = "RoborockVacuumPlatform"
    public static let name = "Roborock"
    public static let icon: String? = "vacuum"
    public static let summary: String? = "Robot vacuums: clean, dock, battery, mop washing, scenes and brushes"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    let storage: RoborockStorage
    var logger: Logger { context.logger }
    var timings: RoborockTimings { dependencies.timings }

    private(set) var messenger: RoborockMessenger?
    private(set) var home: RoborockHome?
    private(set) var homeID: Int?
    private(set) var session: RoborockSession?
    private(set) var scenes: [RoborockScene] = []
    private(set) var accessories: [String: VacuumAccessory] = [:]
    private var loginHost: String?
    private var region: RoborockLoginAPI.Region?
    private var clientID = ""
    private var lastLoginRetryable = false
    private var sessionInvalidated = false
    private var cloudFailing = false
    private var lastClockWarning: ContinuousClock.Instant?
    private var pollers: [String: Task<Void, Never>] = [:]
    private var activePollRunning: Set<String> = []
    private var sceneRuns: [String: Task<Void, Never>] = [:]
    private var transientLogged: [String: (at: ContinuousClock.Instant, suppressed: Int)] = [:]
    private var warnedMatter = false
    private lazy var udp = RoborockUDPDiscovery(logger: logger, duration: timings.udpListen)

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        storage = RoborockStorage(context: context)
    }

    static func accessoryID(duid: String) -> String { "\(platform):\(duid)" }

    var language: String { RoborockStrings.language(configuration.language) }
    var email: String? { configuration.email?.trimmingCharacters(in: .whitespaces).nonEmptyValue }
    /// The password Setup kept in the vault, else the block's.
    var password: String? { context.credentials()?["password"]?.stringValue?.nonEmptyValue ?? configuration.password?.nonEmptyValue }

    func debug(_ message: @autoclosure () -> String) {
        guard configuration.debugMode == true else { return }
        logger.debug("\(message())")
    }

    // MARK: Which devices

    func isSkipped(_ duid: String) -> Bool {
        configuration.skipDevices?.values.contains(duid) == true || context.isExcluded(duid)
    }

    /// Legacy `ignoredDevices` (by duid or serial number): shown, but not polled.
    func isIgnored(_ device: RoborockHome.Device) -> Bool {
        guard let ignored = configuration.ignoredDevices?.values, !ignored.isEmpty else { return false }
        return ignored.contains(device.duid) || device.serialNumber.map(ignored.contains) == true
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard let email else {
            logger.error("No email: set the Roborock account's email (or sign in from Add accessories)")
            return
        }
        logger.info("Starting: this may take a few minutes")
        tasks.add { [weak self] in await self?.run(email: email) }
    }

    public func stop() async {
        tasks.cancelAll()
        pollers.values.forEach { $0.cancel() }
        pollers = [:]
        sceneRuns.values.forEach { $0.cancel() }
        sceneRuns = [:]
        await messenger?.stop()
    }

    /// The start (section 7.1).
    func run(email: String) async {
        clientID = storage.loadOrCreateClientID()
        let encrypted = configuration.encryptedToken?.nonEmptyValue
        if password == nil, encrypted == nil, storage.session.load()?.isValid != true {
            logger.error("No password and no session: sign in from Add accessories")
            return
        }
        await chooseRegion(email: email)
        session = await chooseSession(email: email)
        var online = false
        if let session {
            if let fetched = await fetchHome(session: session, email: email) {
                home = fetched
                online = true
            }
        }
        if home == nil {
            guard let cached = storage.cachedHome(email: email, logger: logger) else {
                logger.error("No cached device data: the plugin needs one successful online start")
                return
            }
            homeID = storage.homeID.load()?.val
            home = RoborockHome(cached)
            logger.warning("Starting in local-only mode: the cloud did not answer")
        }
        guard !Task.isCancelled, let home else { return }
        let messenger = makeMessenger()
        self.messenger = messenger
        await messenger.setDevices(messengerDevices(home))
        if let session { await messenger.startCloud(session: session) }
        scenes = storage.cachedScenes(email: email).compactMap(RoborockScene.init)
        if online { await refreshScenes() }
        let refresh = timings.homeRefresh
        tasks.add { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refresh)
                guard !Task.isCancelled else { return }
                await self?.refreshHome()
            }
        }
        await reconcileAccessories()
        logger.info(online ? "Started" : "Started in local-only mode")
        await connectDevices(home)
    }

    private func makeMessenger() -> RoborockMessenger {
        RoborockMessenger(
            timings: timings, dialer: dependencies.dialer, makeMQTT: dependencies.makeMQTT, logger: logger, discoverIPs: discoverIPs,
            onUpdate: { [weak self] duid, payload in await self?.deviceUpdate(duid, payload) })
    }

    /// The devices the messenger reaches: owned robots of a supported model with a local key, and shared ones.
    func messengerDevices(_ home: RoborockHome) -> [RoborockMessenger.Device] {
        home.devices.compactMap { device in
            guard !isSkipped(device.duid), RoborockHome.isSupported(model: home.model(of: device)) else { return nil }
            if device.localKey == nil {
                logger.warning("A robot has no local key: it cannot be controlled (it has \(device.fieldNames.joined(separator: ", ")))", metadata: ["device": "\(RoborockMessenger.short(device.duid))"])
            }
            return RoborockMessenger.Device(
                duid: device.duid, localKey: device.localKey, version: device.version, isShared: device.isShared, online: device.online)
        }
    }

    /// An owned robot of a supported model with a local key, not skipped: one the plugin dials and polls.
    func isControlled(_ device: RoborockHome.Device, in home: RoborockHome) -> Bool {
        !device.isShared && device.localKey != nil && !isSkipped(device.duid) && RoborockHome.isSupported(model: home.model(of: device))
    }

    /// UDP discovery, or the tests' fake.
    var discoverIPs: @Sendable (Set<String>) async -> [String: String] {
        let udp = udp
        return dependencies.discoverIPs ?? { known in await udp.discover(known: known) }
    }

    /// Discovery, then the LAN, then polling (steps 6.7 to 6.12).
    private func connectDevices(_ home: RoborockHome) async {
        guard let messenger else { return }
        let known = Set(home.devices.filter { isControlled($0, in: home) }.map(\.duid))
        var ips = storage.localDevices.load()?.val.filter { known.contains($0.key) } ?? [:]
        for (duid, ip) in await discoverIPs(known) { ips[duid] = ip }
        if await messenger.isMQTTUp {
            let reported = await withTaskGroup(of: (String, String?).self) { group in
                for duid in known { group.addTask { (duid, try? await messenger.networkInfo(duid)) } }
                var found: [String: String] = [:]
                for await (duid, ip) in group { if let ip { found[duid] = ip } }
                return found
            }
            ips.merge(reported) { _, new in new }
        }
        storage.saveIPs(ips)
        await withTaskGroup(of: Void.self) { group in
            for duid in known { group.addTask { [ip = ips[duid]] in await messenger.connectLocal(duid, ip: ip) } }
        }
        await updatePollers()
        for duid in known where pollers[duid] != nil {
            _ = try? await messenger.request(duid, "get_fw_features")
        }
    }

    // MARK: Signing in

    private func chooseRegion(email: String) async {
        if let configured = configuration.baseURL?.nonEmptyValue {
            loginHost = RoborockLoginAPI.normalizedHost(configured)
        } else if let found = await RoborockLoginAPI.discoverRegion(email: email, transport: dependencies.transport) {
            loginHost = found.host
            region = found
            logger.info("Region found: \(found.host)")
        } else {
            logger.warning("Could not find the account's region: using \(RoborockLoginAPI.defaultHost)")
            loginHost = RoborockLoginAPI.defaultHost
        }
    }

    func loginAPI(email: String) -> RoborockLoginAPI {
        RoborockLoginAPI(transport: dependencies.transport, host: loginHost ?? RoborockLoginAPI.defaultHost, email: email, clientID: clientID, language: language)
    }

    var country: (country: String, code: String) {
        let fallback = RoborockLoginAPI.fallbackCountry(host: loginHost ?? RoborockLoginAPI.defaultHost)
        return (region?.country ?? fallback.country, region?.countryCode ?? fallback.code)
    }

    /// A Homebridge `encryptedToken` (with its key file copied over), the session Setup or a login kept, or a password
    /// login (section 2.5).
    private func chooseSession(email: String) async -> RoborockSession? {
        if let token = configuration.encryptedToken?.nonEmptyValue {
            if let key = storage.tokenKey(), let session = RoborockSession.decrypt(encryptedToken: token, key: key) {
                logger.info("Using the session from the configuration")
                try? storage.session.save(session)
                return session
            }
            logger.debug("The encryptedToken cannot be opened without its roborock.token.key: sign in from Add accessories")
        }
        if let stored = storage.session.load(), stored.isValid {
            logger.info("Using the stored session")
            return stored
        }
        return await passwordLogin(email: email)
    }

    private func passwordLogin(email: String) async -> RoborockSession? {
        guard let password else {
            lastLoginRetryable = false
            return nil
        }
        let api = loginAPI(email: email)
        do {
            let signature = try await api.signature()
            switch try await api.login(password: password, country: country.country, signature: signature) {
            case .success(let session) where session.isValid:
                try? storage.session.save(session)
                lastLoginRetryable = false
                return session
            case .twoFactorRequired:
                logger.error("Two-factor authentication required: sign in with the emailed code from Add accessories; trying local-only")
            case .success, .failed:
                logger.error("Login failed: sign in again from Add accessories; trying local-only")
            }
            lastLoginRetryable = false
            storage.session.remove()
        } catch {
            lastLoginRetryable = (error as? RoborockCloudError)?.isRetryable ?? true
            logger.error("Login failed: \(error); trying local-only")
        }
        return nil
    }

    // MARK: Home data

    private func hawk(_ session: RoborockSession) -> RoborockHawkAPI {
        RoborockHawkAPI(transport: dependencies.transport, session: session, now: dependencies.now)
    }

    /// The home id, then the home data (step 4).
    private func fetchHome(session: RoborockSession, email: String) async -> RoborockHome? {
        do {
            guard let token = session.token else { return nil }
            switch try await loginAPI(email: email).homeDetail(token: token) {
            case .home(let id):
                homeID = id
                try? storage.homeID.save(StoredValue(id))
            case .rejected:
                logger.warning("The stored session was rejected: sign in again from Add accessories")
                self.session = nil
                storage.session.remove()
                return nil
            case .unknown:
                homeID = storage.homeID.load()?.val
            }
            guard let homeID else { return nil }
            let json = try await hawk(session).homeData(homeID: homeID, startup: true)
            guard json.objectValue != nil else { return nil }
            try? storage.homeData.save(StoredValue(json, account: email))
            return RoborockHome(json)
        } catch {
            logger.error("Failed to fetch the home data: \(error)")
            return nil
        }
    }

    private func refreshScenes() async {
        guard let session, let homeID, let email else { return }
        do {
            let list = try await hawk(session).scenes(homeID: homeID)
            if list != scenes.map(\.raw) { try? storage.scenes.save(StoredValue(["result": .array(list)], account: email)) }
            scenes = list.compactMap { json in
                guard let scene = RoborockScene(json) else {
                    logger.warning("A scene cannot be read: skipping it")
                    return nil
                }
                return scene
            }
        } catch {
            debug("Could not fetch the scenes: \(error)")
        }
    }

    /// The 180-second refresh (section 7.4).
    func refreshHome() async {
        guard let email, !sessionInvalidated else { return }
        if session == nil {
            guard password != nil, lastLoginRetryable, let session = await passwordLogin(email: email) else { return }
            self.session = session
            await messenger?.startCloud(session: session)
            logger.info("Signed in again: the cloud is back")
        }
        guard let session else { return }
        if homeID == nil {
            guard let token = session.token, case .home(let id) = try? await loginAPI(email: email).homeDetail(token: token) else {
                debug("No home id yet")
                return
            }
            homeID = id
            try? storage.homeID.save(StoredValue(id))
        }
        guard let homeID else { return }
        do {
            let json = try await hawk(session).homeData(homeID: homeID, startup: false)
            guard json.objectValue != nil else {
                logger.warning("The home data came back empty")
                return
            }
            if json != home?.raw { try? storage.homeData.save(StoredValue(json, account: email)) }
            if cloudFailing {
                cloudFailing = false
                logger.info("The Roborock cloud is reachable again")
            }
            await messenger?.setCloudUnreachable(false)
            let home = RoborockHome(json)
            self.home = home
            await refreshScenes()
            await messenger?.setDevices(messengerDevices(home))
            await reconcileAccessories()
            await updatePollers()
        } catch RoborockCloudError.http(401, let date) {
            await unauthorized(date: date, email: email)
        } catch {
            cloudFailure(error)
        }
    }

    private func cloudFailure(_ error: any Error) {
        if cloudFailing {
            debug("The cloud still fails: \(error)")
        } else {
            cloudFailing = true
            logger.error("The Roborock cloud failed: \(error) (further failures are logged at debug)")
        }
        let messenger = messenger
        Task { await messenger?.setCloudUnreachable(true) }
    }

    /// A 401 from the signed API (section 8.4): the clock, else the token, which getHomeDetail confirms.
    private func unauthorized(date: String?, email: String) async {
        if let skew = RoborockHawkAPI.skew(date: date, now: dependencies.now()), abs(skew) > 60 {
            if lastClockWarning.map({ ContinuousClock.now - $0 >= timings.clockSkewLogInterval }) ?? true {
                lastClockWarning = .now
                logger.error("This machine's clock is \(Int(skew.rounded())) seconds off the Roborock cloud's: set up NTP, every signed request fails until then")
            }
            return
        }
        guard !sessionInvalidated, let token = session?.token else { return }
        if case .rejected = try? await loginAPI(email: email).homeDetail(token: token) {
            sessionInvalidated = true
            session = nil
            storage.session.remove()
            logger.warning("The Roborock cloud rejected the session: sign in again from Add accessories and restart")
            return
        }
        cloudFailure(RoborockCloudError.http(status: 401, date: date))
    }

    // MARK: Accessories

    /// Adds, rebuilds and removes accessories after a home-data change (sections 3.1, 3.4, 6.7).
    func reconcileAccessories() async {
        guard let home else { return }
        var keep: Set<String> = []
        for device in home.devices {
            if isSkipped(device.duid) {
                logger.info("Skipping a robot", metadata: ["device": "\(RoborockMessenger.short(device.duid))"])
                continue
            }
            guard RoborockHome.isSupported(model: home.model(of: device)) else {
                logger.info("Not supported: \(home.model(of: device) ?? "no model")", metadata: ["device": "\(RoborockMessenger.short(device.duid))"])
                continue
            }
            if configuration.matterDevices?.values.contains(device.duid) == true, !warnedMatter {
                warnedMatter = true
                logger.warning("matterDevices are published over HomeKit: the bridge's Matter bridge shows them to other ecosystems")
            }
            let id = Self.accessoryID(duid: device.duid)
            keep.insert(id)
            let vacuum = accessories[device.duid] ?? makeAccessory(device, home: home)
            vacuum.updateDevice(device, model: home.model(of: device))
            vacuum.language = language
            vacuum.connectedLocally = await messenger?.isConnectedLocally(device.duid) ?? false
            let shape = vacuum.desiredShape(home: home, sceneList: scenes)
            let rebuilt = accessories[device.duid] == nil || shape != vacuum.shape
            let accessory = rebuilt ? vacuum.build(shape) : nil
            vacuum.showAll(home: home, online: device.online)
            if let accessory {
                do {
                    try context.add(accessory)
                } catch {
                    logger.error("Could not add a robot: \(error)")
                }
                accessories[device.duid] = vacuum
            }
        }
        for duid in accessories.keys where !keep.contains(Self.accessoryID(duid: duid)) { accessories[duid] = nil }
        _ = await context.removeAccessories(keeping: keep, message: "Removing a robot no longer in the account")
    }

    private func makeAccessory(_ device: RoborockHome.Device, home: RoborockHome) -> VacuumAccessory {
        let actions = VacuumActions(
            setActive: { [weak self] duid, active in await self?.setActive(duid, active) },
            setDockWash: { [weak self] duid, on in try await self?.setDockWash(duid, on) },
            runScene: { [weak self] id in await self?.runScene(id) })
        return VacuumAccessory(
            device: device, model: home.model(of: device), language: language, timings: timings, actions: actions, accessoryID: Self.accessoryID(duid: device.duid))
    }

    /// A device's update: an RPC answer or a status broadcast (section 6.7), on its accessory only.
    func deviceUpdate(_ duid: String, _ payload: JSONValue) async {
        guard let vacuum = accessories[duid] else { return }
        var object = RoborockMessages.firstObject(payload)
        if let dps = object?["dps"]?.objectValue { object = dps }
        guard var fields = object else { return }
        for (id, field) in RoborockMessages.schemaFields where fields[id] != nil {
            fields[field] = fields.removeValue(forKey: id)
        }
        vacuum.record(fields)
        vacuum.show(fields: Set(fields.keys), home: home)
        // A consumable seen for the first time, or a dock type that washes, adds a service.
        guard fields["dock_type"] != nil || RoborockConsumables.all.contains(where: { fields[$0.field] != nil }) else { return }
        let shape = vacuum.desiredShape(home: home, sceneList: scenes)
        if shape != vacuum.shape {
            try? context.add(vacuum.build(shape))
            vacuum.showAll(home: home, online: vacuum.device.online)
        }
    }

    // MARK: Polling (section 7)

    /// Starts the pollers of reachable robots and stops the others.
    func updatePollers() async {
        guard let home, let messenger else { return }
        for device in home.devices {
            let controlled = isControlled(device, in: home) && !isIgnored(device)
            let reachable = await messenger.isReachable(device.duid)
            if controlled, reachable {
                guard pollers[device.duid] == nil else { continue }
                let duid = device.duid, active = timings.activePoll, full = timings.homeRefresh
                pollers[duid] = Task { [weak self] in
                    await self?.fullPoll(duid)
                    var last = ContinuousClock.now
                    while !Task.isCancelled {
                        try? await Task.sleep(for: active)
                        guard !Task.isCancelled else { return }
                        if ContinuousClock.now - last >= full {
                            last = .now
                            await self?.fullPoll(duid)
                        } else {
                            await self?.activePoll(duid)
                        }
                    }
                }
            } else if let poller = pollers.removeValue(forKey: device.duid) {
                poller.cancel()
            }
        }
    }

    /// get_status (1.0 only), then the consumables (section 7.2). The optional polls change nothing HomeKit shows and
    /// are not sent.
    func fullPoll(_ duid: String) async {
        guard let messenger, let device = home?.device(duid) else { return }
        if device.version == .v1, await !messenger.isPaused(duid, "get_status") {
            await send(duid, "get_status")
        }
        if await !messenger.isPaused(duid, "get_consumable"), let answer = try? await messenger.request(duid, "get_consumable"),
            let object = RoborockMessages.firstObject(answer)
        {
            let lives = RoborockConsumables.lives(object)
            if !lives.isEmpty { await deviceUpdate(duid, .object(lives.mapValues { .number($0) })) }
        }
    }

    /// Every 15 seconds while cleaning or while the cloud is down: get_status on the LAN.
    func activePoll(_ duid: String) async {
        guard let messenger, let vacuum = accessories[duid], !activePollRunning.contains(duid) else { return }
        guard vacuum.device.version == .v1, await messenger.isConnectedLocally(duid) else { return }
        let cleaning = RoborockStates.isCleaning(vacuum.value("state", home: home).map { Int($0) })
        guard await !messenger.isMQTTUp || cleaning, await !messenger.isPaused(duid, "get_status") else { return }
        activePollRunning.insert(duid)
        await send(duid, "get_status")
        activePollRunning.remove(duid)
    }

    // MARK: Commands

    /// Sends a command, logging what fails (section 8.5's throttle for the transient errors); answers the result.
    @discardableResult
    func send(_ duid: String, _ method: String, _ params: JSONValue = [], localOnly: Bool = false) async -> JSONValue? {
        try? await request(duid, method, params, localOnly: localOnly)
    }

    /// `send`, throwing what failed (logged already).
    func request(_ duid: String, _ method: String, _ params: JSONValue = [], localOnly: Bool = false) async throws -> JSONValue {
        guard let messenger else {
            logger.warning("Not initialised yet: \(method) not sent")
            throw RoborockRequestError.refused("not initialised")
        }
        guard accessories[duid] != nil else {
            logger.warning("Unknown device: \(method) not sent")
            throw RoborockRequestError.refused("unknown device")
        }
        do {
            return try await messenger.request(duid, method, params, localOnly: localOnly)
        } catch {
            logFailure(duid, method, error)
            throw error
        }
    }

    private func logFailure(_ duid: String, _ method: String, _ error: any Error) {
        let text = "\(error)"
        let model = accessories[duid]?.model ?? "?"
        if (error as? RoborockRequestError)?.isTransient == true {
            let key = "\(duid)|\(method)"
            if let entry = transientLogged[key], ContinuousClock.now - entry.at < timings.transientLogInterval {
                transientLogged[key] = (entry.at, entry.suppressed + 1)
                return
            }
            let suppressed = transientLogged[key]?.suppressed ?? 0
            transientLogged[key] = (.now, 0)
            logger.warning("\(method) failed: \(text)\(suppressed > 0 ? " (\(suppressed) more since)" : "")", metadata: ["device": "\(RoborockMessenger.short(duid))", "model": "\(model)"])
        } else if case RoborockRequestError.refused = error {
            debug("\(method) not sent: \(text)")
        } else {
            logger.error("\(method) failed: \(text)", metadata: ["device": "\(RoborockMessenger.short(duid))", "model": "\(model)"])
        }
    }

    /// Active on starts a clean; off stops it and sends the robot home (section 6.1).
    func setActive(_ duid: String, _ active: Bool) async {
        if active {
            await send(duid, "app_start")
        } else {
            cancelSceneRun(duid)
            await send(duid, "app_stop")
            cancelSceneRun(duid)
            await send(duid, "app_charge")
        }
    }

    /// The dock's mop wash (section 6.3). A command that fails fails the write, so On keeps what the robot does.
    func setDockWash(_ duid: String, _ on: Bool) async throws {
        do {
            _ = try await request(duid, on ? "app_start_wash" : "app_stop_wash")
        } catch {
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    // MARK: Scenes (section 6.4)

    func cancelSceneRun(_ duid: String) {
        sceneRuns.removeValue(forKey: duid)?.cancel()
    }

    func runScene(_ id: Int) async {
        guard let scene = scenes.first(where: { $0.id == id }), let messenger else { return }
        let targets = scene.targets
        for duid in targets { cancelSceneRun(duid) }
        var local = scene.isLocalCommands
        if local {
            for duid in targets {
                guard let home, let device = home.device(duid), isControlled(device, in: home), accessories[duid] != nil,
                    device.version == .v1, await messenger.isLocallyAvailable(duid)
                else {
                    local = false
                    break
                }
            }
        }
        guard local else { return await runSceneInCloud(scene) }
        logger.info("Running a scene on the LAN: \(scene.name)")
        let run = Task { [weak self] () -> Void in await self?.runLocally(scene) }
        for duid in targets { sceneRuns[duid] = run }
        await run.value
    }

    private func runSceneInCloud(_ scene: RoborockScene) async {
        guard let session else {
            logger.warning("The scene \(scene.name) needs the cloud, which is not signed in")
            return
        }
        do {
            try await hawk(session).executeScene(scene.id)
        } catch {
            logger.error("The scene \(scene.name) did not start: \(error)")
        }
    }

    /// Each step on the LAN, waiting for the robot to finish it; the cloud runs the scene when the first does not start.
    private func runLocally(_ scene: RoborockScene) async {
        for (index, item) in scene.items.enumerated() {
            guard !Task.isCancelled, let duid = item.entityID, let method = item.method else { return }
            let before = await pollStatus(duid)
            let wasBusy = before.map { RoborockStates.isBusy(state: $0.state, inCleaning: $0.inCleaning) } ?? true
            let answer = await send(duid, method, item.params, localOnly: true)
            var started = answer.map(RoborockMessages.isOK) ?? false
            if !started, answer != nil, let after = await pollStatus(duid) {
                started = !wasBusy && RoborockStates.isBusy(state: after.state, inCleaning: after.inCleaning)
            }
            guard started else {
                if index == 0 {
                    logger.warning("The scene \(scene.name) could not start on the LAN: asking the cloud")
                    await runSceneInCloud(scene)
                } else {
                    stopped(scene, at: index, reason: "step \(index + 1) did not start")
                }
                return
            }
            if let reason = await waitForStep(duid) {
                stopped(scene, at: index + 1, reason: reason)
                return
            }
        }
        logger.info("The scene \(scene.name) finished")
    }

    private func stopped(_ scene: RoborockScene, at index: Int, reason: String) {
        let left = scene.items.enumerated().dropFirst(index).map { "\($0.offset + 1) \($0.element.method ?? "?")" }
        logger.info("The scene \(scene.name) stopped: \(reason)\(left.isEmpty ? "" : "; not run: \(left.joined(separator: ", "))")")
    }

    /// Polls until the step is done (busy, then docked), answering why it stopped otherwise.
    private func waitForStep(_ duid: String) async -> String? {
        let start = ContinuousClock.now
        var seenBusy = false
        while !Task.isCancelled {
            try? await Task.sleep(for: timings.scenePoll)
            guard !Task.isCancelled else { return "cancelled" }
            if let status = await pollStatus(duid) {
                if let error = status.error, error != 0 { return "the robot reported error \(error)" }
                let busy = RoborockStates.isBusy(state: status.state, inCleaning: status.inCleaning)
                if busy { seenBusy = true } else if seenBusy, status.state.map(RoborockStates.docked.contains) == true { return nil }
            }
            let elapsed = ContinuousClock.now - start
            if !seenBusy, elapsed > timings.sceneStartWindow { return "the step did not start" }
            if elapsed > timings.sceneMaximum { return "the step ran for more than 4 hours" }
        }
        return "cancelled"
    }

    private func pollStatus(_ duid: String) async -> (state: Int?, inCleaning: Int?, error: Int?)? {
        guard let answer = await send(duid, "get_status", localOnly: true), let status = RoborockMessages.firstObject(answer) else { return nil }
        return (status["state"]?.intValue, status["in_cleaning"]?.intValue, status["error_code"]?.intValue)
    }
}

extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}
