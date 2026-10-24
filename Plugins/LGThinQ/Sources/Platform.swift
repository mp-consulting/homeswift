import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The Homebridge plugin's platform: signs in, discovers the account's devices and gives each its handler and
/// accessory, then keeps them current: MQTT pushes and a five-minute REST reconciliation for ThinQ2 devices,
/// polling every `refresh_interval` seconds for ThinQ1 devices.
@ThinQActor
final class LGThinQPlatform {
    let configuration: LGThinQPlugin.Configuration
    let context: PluginContext
    let thinq: ThinQ
    var logger: Logger
    let thinq1Enabled: Bool
    let interval: Duration
    /// `refresh_interval`, seconds.
    let intervalSeconds: Double
    static let defaultIntervalSeconds: Double = 60
    private(set) var handlers: [String: BaseDevice] = [:]
    private var startTask: Task<Void, Never>?
    private var thinq2Poll: Task<Void, Never>?
    private var thinq1Poll: Task<Void, Never>?
    private var mqttStarted = false
    /// Set by `stop()`: start-up work that was waiting on LG adds nothing and starts nothing afterwards.
    private(set) var stopped = false
    /// Overridable in tests.
    var discoveryRetryDelay = ThinQConstants.deviceDiscoveryDelay

    init(configuration: LGThinQPlugin.Configuration, context: PluginContext, transport: any HTTPSending, mqtt: @escaping ThinQ.MQTTFactory) {
        self.configuration = configuration
        self.context = context
        logger = context.logger
        let client = RequestClient(transport: transport, logger: context.logger)
        let api = ThinQAPI(country: configuration.country ?? "", language: configuration.language ?? "", client: client, logger: context.logger)
        if let token = configuration.refresh_token, !token.isEmpty {
            try? api.setRefreshToken(token)
        } else if let username = configuration.username, let password = configuration.password, !username.isEmpty, !password.isEmpty {
            api.setUsernamePassword(username, password)
        }
        thinq = ThinQ(api: api, persist: Persist(directory: context.storageDirectory.appendingPathComponent("persist")), mqtt: mqtt, logger: context.logger)
        thinq1Enabled = configuration.thinq1 ?? false
        // The schema's and the page's default; the Homebridge runtime fell back to 5 s, a monitoring request per
        // ThinQ1 device every 5 s against LG's rate limit.
        intervalSeconds = configuration.refresh_interval.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultIntervalSeconds
        // Saturated: a huge or infinite refresh_interval polls (almost) never instead of trapping.
        interval = .milliseconds(Int64(saturating: intervalSeconds * 1000, in: 1...Int64(Int32.max) * 1000) ?? Int64(Self.defaultIntervalSeconds * 1000))
    }

    /// The configured devices (empty: all of them).
    var configuredDevices: [LGThinQPlugin.DeviceConfiguration] { configuration.devices ?? [] }

    /// Whether the block has a region and a sign-in (an account or a refresh token).
    var isConfigured: Bool {
        guard let country = configuration.country, !country.isEmpty, let language = configuration.language, !language.isEmpty else { return false }
        return (configuration.username?.isEmpty == false && configuration.password?.isEmpty == false) || configuration.refresh_token?.isEmpty == false
    }

    /// Signs in and discovers in the background; start() itself returns at once.
    func start() {
        guard isConfigured else {
            logger.error("Missing required config parameter.")
            return
        }
        startTask = Task { @ThinQActor [weak self] in
            guard let self else { return }
            do {
                try await thinq.isReady()
                guard !stopped else { return }
                logger.info("Successfully connected to the ThinQ API.")
            } catch {
                guard !stopped else { return }
                if case ThinQError.notConnected = error {
                    logger.error("LG ThinQ internal server error, try again later.")
                } else if "\(error)" == "Internal Server Error" {
                    logger.error("LG ThinQ internal server error, try again later.")
                } else {
                    logger.error("ThinQ API is not ready. Please check configuration and try again.")
                }
                logger.error("\(error)")
                return
            }
            await discoverAndMonitor()
        }
    }

    private func discoverAndMonitor() async {
        while !Task.isCancelled, !stopped {
            do {
                try await discoverDevices()
                guard !stopped else { return }
                startMonitor()
                return
            } catch ThinQError.notConnected {
                try? await Task.sleep(for: discoveryRetryDelay)
            } catch {
                logger.error("\(error)")
                return
            }
        }
    }

    func stop() async {
        stopped = true
        startTask?.cancel()
        thinq2Poll?.cancel()
        thinq1Poll?.cancel()
        await thinq.stopMQTT()
        let running = handlers.values
        handlers = [:]
        for handler in running {
            handler.destroy()
            await thinq.unregister(handler.device)
        }
    }

    // MARK: Discovery

    /// Adds or replaces an accessory per supported device; cached accessories of devices that are gone,
    /// skipped or unsupported leave HomeKit, once LG answered for every home.
    func discoverDevices() async throws {
        let listing = await thinq.deviceListing()
        guard !stopped else { return }
        let devices = listing.devices
        if devices.isEmpty { logger.warning("No ThinQ devices in your account.") }
        var kept = Set<String>()
        for device in devices {
            logger.debug("Device [\(device.name)]: \(device.description)")
            logger.debug("\(JSONValue.object(device.data).text())")
            if !thinq1Enabled, device.platform == PlatformType.thinq1 {
                logger.debug("Thinq1 device is skipped: \(device.description)")
                continue
            }
            let block = configuredDevices.first { $0.id == device.id }
            if !configuredDevices.isEmpty, block == nil {
                logger.info("Device skipped: \(device.id)")
                continue
            }
            logger.info("[\(device.name)] Setting up device!")
            let ready = try await thinq.setup(device)
            guard !stopped else { return }
            guard ready else {
                logger.warning("[\(device.name)] Failed to setup device!")
                continue
            }
            guard let kind = DeviceRegistry.handler(for: device.type, platform: device.platform) else {
                logger.info("Device not supported: \(device.platform ?? "undefined"): \(device.description)")
                await thinq.unregister(device)
                logger.debug("\(device.id) - unregistered!")
                continue
            }
            let environment = DeviceEnvironment(thinq: thinq, logger: logger, settings: DeviceSettings(type: device.type, block: block?.raw))
            let handler = kind.init(device: device, environment: environment)
            handlers[device.id]?.destroy()
            handler.updateAccessoryCharacteristic(device)
            let accessory = handler.makeAccessory()
            let cached = context.accessory(id: accessory.id) != nil
            do {
                if DeviceRegistry.isExternal(device.type) {
                    if cached, !context.isExternal(id: accessory.id) { logger.info("Migrating accessory to external: \(device.description)") }
                    logger.info("Publishing external accessory: \(device.description)")
                    try await context.publishExternal(accessory)
                    guard !stopped else {
                        handler.destroy()
                        return
                    }
                } else {
                    logger.info("\(cached ? "Restoring existing accessory" : "Adding new accessory"): \(device.description)")
                    try context.add(accessory)
                }
            } catch {
                logger.error("Could not add \(device.name): \(error)")
                handler.destroy()
                continue
            }
            handlers[device.id] = handler
            kept.insert(accessory.id)
        }
        // A failed listing must not empty HomeKit: accessories leave only when LG answered for every home (a
        // home whose request failed or was rate-limited would otherwise lose its accessories) and listed some.
        guard listing.complete, !devices.isEmpty else {
            if !listing.complete { logger.debug("The device list is incomplete; keeping the accessories LG did not list.") }
            return
        }
        let prefix = "\(BaseDevice.platformPrefix):"
        var keep = kept
        for accessory in context.accessories {
            if !accessory.id.hasPrefix(prefix) {
                keep.insert(accessory.id)
            } else if !kept.contains(accessory.id) {
                handlers.removeValue(forKey: String(accessory.id.dropFirst(prefix.count)))?.destroy()
            }
        }
        await context.removeAccessories(keeping: keep, message: "Removing accessory")
    }

    // MARK: Monitoring

    func startMonitor() {
        guard !stopped else { return }
        let thinq2 = handlers.values.filter { $0.device.platform == PlatformType.thinq2 }
        if !thinq2.isEmpty {
            thinq2Poll?.cancel()
            thinq2Poll = Task { @ThinQActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: ThinQConstants.thinq2PollInterval)
                    guard !Task.isCancelled, let self else { return }
                    let devices = await thinq.devices()
                    guard !Task.isCancelled else { return }
                    for device in devices where device.platform == PlatformType.thinq2 {
                        handlers[device.id]?.update(device.snapshot)
                    }
                }
            }
            if !mqttStarted {
                mqttStarted = true
                logger.info("Start MQTT listener for ThinQ2 devices")
                thinq.registerMQTTListener { [weak self] message in self?.handleMQTT(message) }
            }
        }
        guard handlers.count > thinq2.count else { return }
        logger.info("Start polling device data every \(JS.format(intervalSeconds)) seconds.")
        thinq1Poll?.cancel()
        thinq1Poll = Task { @ThinQActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                do {
                    for handler in handlers.values.sorted(by: { $0.device.id < $1.device.id }) where handler.device.platform == PlatformType.thinq1 && thinq1Enabled {
                        try await thinq.pollMonitor(handler.device)
                        guard !Task.isCancelled else { return }
                        if handler.device.snapshot["raw"] != nil, handler.device.snapshot["raw"] != .null {
                            handler.update(handler.device.snapshot)
                        }
                    }
                } catch ThinQError.manualProcessNeeded(let message) {
                    logger.info("Stop polling device data.")
                    logger.warning("\(message)")
                    return
                } catch {
                    logger.debug("ThinQ1 poll failed: \(error)")
                }
            }
        }
    }

    /// `{ deviceId, data: { state: { reported } } }`: the reported delta goes to its device.
    func handleMQTT(_ message: JSONValue) {
        guard let deviceID = message["deviceId"].map({ JS.string($0) }), message["data"] != nil,
              let reported = message["data"]?["state"]?["reported"]?.objectValue else { return }
        handlers[deviceID]?.update(reported)
    }
}
