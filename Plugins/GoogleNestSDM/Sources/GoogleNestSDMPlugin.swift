import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Google Nest thermostats, cameras, doorbells and displays through Google's Smart Device Management API: the devices a
/// person shares with their own Device Access project, their changes pulled from the project's Cloud Pub/Sub
/// subscription. A thermostat (and its fan, with `showFan`) is on the bridge; each camera, doorbell and display is an
/// accessory of its own, with live view over the SDM RTSP stream, snapshots of the latest event image, motion, the doorbell
/// and HomeKit Secure Video, through FFmpeg. WebRTC cameras (2021 and later) give events and snapshots only.
///
/// The configuration is homebridge-google-nest-sdm's block, so a Homebridge block works unchanged;
/// docs/clean-room/GoogleNestSDM.md is the functional specification it was written from. See README.md.
public actor GoogleNestSDMPlugin: HomeswiftPlugin {
    /// What the plugin reaches the world with; tests swap them.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        var ffmpeg: @Sendable (_ logger: Logger, _ debug: Bool) -> NestFFmpeg = { NestFFmpeg(logger: $0, debug: $1) }
        var ports = RtpPortAllocator()
        /// Multiplies the plugin's waits (motion, retries, the stale cache): tests shorten them.
        var timeScale: Double = 1
        var now: @Sendable () -> Date = { Date() }
    }

    public static let platform = "homebridge-google-nest-sdm"
    public static let name = "Google Nest"
    public static let icon: String? = "thermostat"
    public static let summary: String? = "Nest thermostats, cameras and doorbells through Google's Device Access"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// The run-time refresh token, sealed in the vault: Setup's, a Homebridge block's moved there, or one Google rotated.
    static let tokenFile = "google-nest-sdm-token.json"
    struct StoredToken: Codable, Sendable { var refreshToken: String }

    /// A device's cache is fetched again on a read when it is older than this (section 7.2).
    static let staleAfter: TimeInterval = 24 * 3600
    static let retry = Backoff(initial: .seconds(10), maximum: .seconds(300), jitter: .proportional(0.2))

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let options: NestOptions
    private let tasks = TaskBag()
    private var sdm: SDMClient?
    private(set) var thermostats: [String: NestThermostat] = [:]
    private(set) var cameras: [String: NestCamera] = [:]
    /// When each device's cache was last listed or fetched, and those being fetched.
    private var fetched: [String: Date] = [:]
    private var fetching: Set<String> = []
    private(set) var devicesLoaded = false
    /// One FFmpeg for every camera: its codecs are probed once.
    private var ffmpeg: NestFFmpeg?
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        options = NestOptions(configuration, debug: context.logger.logLevel <= .debug)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    // MARK: The account

    var tokens: SecretFile<StoredToken> { context.secretFile(Self.tokenFile, as: StoredToken.self) }

    /// The client secret Setup kept in the vault, else the block's.
    var clientSecret: String? { context.credentials()?["clientSecret"]?.stringValue.nonEmptyText ?? configuration.clientSecret }

    /// The refresh token kept in the vault, else the block's.
    var refreshToken: String? { tokens.load()?.refreshToken.nonEmptyText ?? configuration.refreshToken }

    /// The account, or the keys it lacks (section 1.2).
    func account() -> Result<NestAccount, NestError> {
        let secret = clientSecret, token = refreshToken
        guard let projectID = configuration.projectId, let clientID = configuration.clientId, let secret, let token,
              let subscription = configuration.subscriptionId else {
            let values = [("projectId", configuration.projectId), ("clientId", configuration.clientId), ("clientSecret", secret),
                          ("refreshToken", token), ("subscriptionId", configuration.subscriptionId)]
            return .failure(.notConfigured(values.filter { $0.1 == nil }.map(\.0)))
        }
        return .success(NestAccount(clientID: clientID, clientSecret: secret, projectID: projectID, refreshToken: token, subscriptionID: subscription))
    }

    func caller(for account: NestAccount) -> GoogleCaller {
        let tokens = tokens
        let logger = logger
        let accessTokens = AccessTokens(account: account, transport: dependencies.transport, now: dependencies.now) { next in
            do { try tokens.save(StoredToken(refreshToken: next)) } catch { logger.error("Could not keep Google's new refresh token: \(error)") }
        }
        return GoogleCaller(transport: dependencies.transport, tokens: accessTokens)
    }

    // MARK: Lifecycle

    public func start() async throws {
        let account: NestAccount
        switch self.account() {
        case .success(let found): account = found
        case .failure(let error):
            // The keys only: never the block, which holds the secrets.
            logger.error("The configuration is not complete (\(error)): set up the account in Add accessories.")
            return
        }
        if configuration.fanDuration != nil, options.fanDuration == nil {
            logger.error("fanDuration must be between 1 and 43200 seconds: the fan cannot be turned on.")
        }
        let caller = caller(for: account)
        let sdm = SDMClient(caller: caller, projectID: account.projectID)
        self.sdm = sdm
        let pubsub = PubSubClient(caller: caller, subscription: account.subscriptionID)
        tasks.add { [weak self] in
            await self?.loadDevices(sdm)
            await self?.listen(pubsub)
        }
    }

    public func stop() async {
        tasks.cancelAll()
        for camera in cameras.values { await camera.stop() }
    }

    /// Lists the devices once (events start flowing after a list), retrying with a back-off while it fails: the
    /// Homebridge plugin stays without accessories until it restarts.
    func loadDevices(_ sdm: SDMClient) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let devices = try await sdm.listDevices()
                logger.debug("Listed \(devices.count) devices.")
                await add(devices)
                devicesLoaded = true
                return
            } catch {
                if attempt == 0 || !((error as? NestError)?.isRateLimit ?? false) {
                    logger.error("Could not execute device LIST request: \(error)")
                }
                try? await Task.sleep(for: Self.retry.delay(attempt: attempt) * dependencies.timeScale)
                attempt += 1
            }
        }
    }

    private func add(_ devices: [SDMDevice]) async {
        var keep: Set<String> = []
        let now = dependencies.now()
        for device in devices where !context.isExcluded(device.name) {
            guard let kind = device.kind else { continue }
            fetched[device.name] = now
            do {
                switch kind {
                case .thermostat:
                    let thermostat = makeThermostat(device)
                    try context.add(thermostat.accessory)
                    keep.insert(thermostat.accessory.id)
                    if let fan = thermostat.fanAccessory {
                        try context.add(fan)
                        keep.insert(fan.id)
                    }
                    thermostats[device.name] = thermostat
                case .camera, .doorbell, .display:
                    let camera = try NestCamera(device: device, options: options, tools: cameraTools(), log: logger)
                    await camera.start()
                    context.configureController(camera.controller, accessoryID: camera.accessory.id)
                    do {
                        try await context.publishExternal(camera.accessory)
                    } catch {
                        await camera.stop()
                        throw error
                    }
                    keep.insert(camera.accessory.id)
                    cameras[device.name] = camera
                }
                logger.info("Adding new accessory: \(device.displayName)")
            } catch {
                logger.error("Could not add \(device.displayName): \(error)")
            }
        }
        // Devices no longer shared (or the fan, with `showFan` off) leave the bridge.
        await context.removeAccessories(keeping: keep)
    }

    private func makeThermostat(_ device: SDMDevice) -> NestThermostat {
        let resource = device.name
        return NestThermostat(device: device, options: options, send: commander(), log: logger) { [weak self] in
            Task { await self?.refreshIfStale(resource) }
        }
    }

    private func cameraTools() -> NestCamera.Tools {
        let caller = sdm?.caller
        return NestCamera.Tools(
            send: commander(),
            download: { url, authorization in
                guard let caller else { throw NestError.notConfigured([]) }
                return try await caller.download(url, authorization: authorization)
            },
            ffmpeg: sharedFFmpeg(), ports: dependencies.ports, timeScale: dependencies.timeScale, now: dependencies.now)
    }

    private func sharedFFmpeg() -> NestFFmpeg {
        if let ffmpeg { return ffmpeg }
        let made = dependencies.ffmpeg(logger, options.debug)
        ffmpeg = made
        return made
    }

    /// Sends commands, logging their failures (Google's status and message only: never a parameter or a result, which
    /// carry stream tokens and URLs).
    func commander() -> Commander {
        let sdm = sdm
        let logger = logger
        return { device, command, params in
            guard let sdm else { throw NestError.notConfigured([]) }
            logger.debug("Executing \(command)")
            do {
                return try await sdm.execute(device, command, params)
            } catch let error as NestError where error.isRateLimit {
                logger.error("Google rate-limited the \(command) command; wait about a minute.")
                throw error
            } catch {
                logger.error("Could not execute device command \(command): \(error)")
                throw error
            }
        }
    }

    /// A read found the device's cache older than a day: it is fetched again in the background (section 7.2).
    func refreshIfStale(_ name: String) async {
        guard let sdm, !fetching.contains(name), let last = fetched[name],
              dependencies.now().timeIntervalSince(last) > Self.staleAfter * dependencies.timeScale else { return }
        fetching.insert(name)
        defer { fetching.remove(name) }
        do {
            let device = try await sdm.device(name)
            fetched[name] = dependencies.now()
            if let thermostat = thermostats[name], thermostat.replace(device) { rebuild(name) }
        } catch let error as NestError where error.isRateLimit {
            logger.warning("Google rate-limited the GetDevice API; using cached state.")
        } catch {
            logger.error("Could not execute device GET request: \(error)")
        }
    }

    /// A thermostat whose props changed (scale, eco, modes) is built again under the same ids, as "configure" does.
    private func rebuild(_ name: String) {
        guard let old = thermostats[name] else { return }
        let thermostat = makeThermostat(old.device)
        thermostat.accessory.takeValues(from: old.accessory)
        thermostat.show()
        do {
            try context.add(thermostat.accessory)
            if let fan = thermostat.fanAccessory { try context.add(fan) }
            thermostats[name] = thermostat
        } catch {
            logger.error("Could not update \(old.device.displayName): \(error)")
        }
    }

    // MARK: Events

    /// Pulls the subscription, acknowledging each message before it is read (a message that cannot be read is not
    /// delivered again), with a back-off while it fails.
    func listen(_ pubsub: PubSubClient) async {
        var attempt = 0
        var failing = false
        while !Task.isCancelled {
            do {
                let messages = try await pubsub.pull()
                do { try await pubsub.acknowledge(messages.map(\.ackID)) } catch { logger.debug("Could not acknowledge events: \(error)") }
                for message in messages { await handle(message.data) }
                if failing { logger.info("Receiving events again.") }
                failing = false
                attempt = 0
            } catch {
                if Task.isCancelled { return }
                if !failing { logger.error("Event subscription failure (\(error)): see the configuration section of the README.") }
                failing = true
                try? await Task.sleep(for: Self.retry.delay(attempt: attempt) * dependencies.timeScale)
                attempt += 1
            }
        }
    }

    /// One Pub/Sub message (section 4.2).
    func handle(_ data: Data) async {
        let event: SDMEvent
        do {
            event = try SDMEvent(data: data)
        } catch {
            logger.error("Could not handle event: \(error)")
            return
        }
        guard devicesLoaded, let resource = event.resource else {
            logger.debug("Ignoring an event without a resource update.")
            return
        }
        if let traits = event.traits, let thermostat = thermostats[resource] {
            if thermostat.apply(traits) { rebuild(resource) }
        }
        if event.events != nil, let camera = cameras[resource] {
            // A camera's image fetch does not hold back the events after it.
            Task { await camera.handle(event) }
        }
    }
}
