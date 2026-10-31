import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's machinery, after the Homebridge plugin's platform modules: the device registry, the
/// accessory factory, the state router (updates in), the command dispatcher (commands out), discovery, and
/// the connection manager that logs in, retries, and runs the WebSocket and LAN control.
///
/// Offline first: the devices of the last discovery are kept in `devices.json`, so the accessories get
/// working handlers (and LAN control) at launch, before the cloud answers or while it is down.
@EWeLinkActor
final class EWeLinkPlatform {
    let configuration: EWeLinkPlugin.Configuration
    let context: PluginContext
    let logger: Logger
    let dependencies: EWeLinkPlugin.Dependencies
    let registry = DeviceRegistry()
    /// Values handlers keep across launches, by accessory id (see `BaseAccessory.contextValue`).
    let contexts: PersistedDictionary<[String: JSONValue]>
    var clock: EWeLinkClock { dependencies.clock }

    private(set) var api: CloudAPI?
    private(set) var lan: LANControl?
    private(set) var socket: CloudSocket?
    private(set) lazy var factory = AccessoryFactory(platform: self)
    private(set) lazy var dispatcher = CommandDispatcher(
        configuration: configuration, registry: registry, logger: logger, clock: clock,
        lan: { [weak self] in self?.lan }, cloud: { [weak self] in self?.socket }, groups: { [weak self] in self?.api })

    private var loggedIn = false
    private(set) var initialized = false
    private var stopped = false
    private(set) var retryAttempts = 0
    private var retryTask: Task<Void, Never>?
    private var deviceCache: JSONFile<DeviceCacheFile> { context.jsonFile("devices.json") }

    init(configuration: EWeLinkPlugin.Configuration, context: PluginContext, dependencies: EWeLinkPlugin.Dependencies) {
        self.configuration = configuration
        self.context = context
        logger = context.logger
        self.dependencies = dependencies
        contexts = context.persistedDictionary("accessory-context.json")
    }

    var hasPendingRetry: Bool { retryTask != nil }

    /// Left out: in `ignoredDevices`, or Excluded in its Accessory Settings (GLOSSARY.md), its channels and RF sub-devices
    /// with it (the runtime refuses their accessories too: `EWeLinkPlugin.deviceID(ofAccessory:)`).
    func isLeftOut(_ deviceID: String) -> Bool { configuration.isIgnored(deviceID) || context.isExcluded(deviceID) }
    var tokenStorage: TokenStorage { TokenStorage(context: context) }

    // MARK: Connection

    /// Restores the cached devices, starts LAN control, then logs in and discovers the devices, retrying with
    /// backoff until it works.
    func start() async {
        logger.info("=== DISCOVER DEVICES START ===")
        logger.debug("Config username: \(configuration.username?.isEmpty == false ? "SET" : "NOT SET")")
        logger.debug("Config password: \(configuration.password?.isEmpty == false ? "SET" : "NOT SET")")
        guard configuration.username?.isEmpty == false, configuration.password?.isEmpty == false else {
            logger.warning("eWeLink credentials not configured. Please configure the plugin.")
            return
        }
        logger.info("Initializing eWeLink API...")
        api = makeAPI()

        let restored = await restoreCachedAccessories()
        // `stop()` may run at any await: whatever starts after it is stopped again.
        if stopped { return registry.destroyAllHandlers() }
        if restored > 0 {
            logger.info("Restored \(restored) cached accessory handler(s) - waiting for eWeLink cloud discovery")
        }
        if configuration.connectionMode != .wan {
            let lan = makeLAN()
            self.lan = lan
            await preRegisterLANDevices(registry.devices.values.map(\.device), fromAPI: false)
            if stopped { return }
            await lan.start()
            if stopped { return await lan.stop() }
        }
        await discover()
    }

    func makeAPI() -> CloudAPI {
        CloudAPI(
            credentials: .init(username: configuration.username, password: configuration.password, countryCode: configuration.countryCode),
            transport: dependencies.transport, storage: tokenStorage, logger: logger, debug: configuration.debug == true)
    }

    private func makeLAN() -> LANControl {
        LANControl(
            dependencies: .init(network: dependencies.lanNetwork, clock: clock), logger: logger,
            selfAPIKey: { [weak self] in await self?.api?.apiKey ?? "" },
            deviceInfo: { [weak self] id in await self?.lanInfo(id) },
            knownDevices: { [weak self] in await self?.knownDevices() ?? [] },
            onUpdate: { [weak self] id, params in await self?.handleDeviceUpdate(id, params) })
    }

    private func lanInfo(_ deviceID: String) -> (name: String, deviceKey: String?)? {
        guard let device = registry.device(deviceID) else { return nil }
        return (device.name, device.devicekey)
    }

    private func knownDevices() -> [(id: String, name: String)] {
        registry.devices.values.map { ($0.device.deviceid, $0.device.name) }.sorted { $0.id < $1.id }
    }

    private func makeSocket(_ api: CloudAPI) -> CloudSocket {
        CloudSocket(
            api: api, dependencies: .init(connect: dependencies.connectSocket, clock: clock, random: dependencies.random), logger: logger,
            onUpdate: { [weak self] id, params in await self?.handleDeviceUpdate(id, params) },
            deviceAPIKey: { [weak self] id in await self?.registry.device(id)?.apikey },
            displayName: { [weak self] id in await self?.registry.displayName(id) ?? id })
    }

    /// One login and discovery; schedules the next attempt when it fails.
    func discover() async {
        guard !stopped, let api else { return }
        let devices: [EWeLinkDevice], groups: [JSONValue]
        do {
            if !loggedIn {
                logger.info("Attempting login...")
                try await api.login()
                loggedIn = true
            }
            (devices, groups) = try await api.devices()
            logger.info("Discovered \(devices.count) devices and \(groups.count) groups from eWeLink")
        } catch {
            if stopped { return }
            logger.error("Failed to discover devices: \(error)")
            scheduleRetry()
            return
        }
        if stopped { return }
        retryAttempts = 0
        for device in devices { registry.store(device) }
        if lan != nil { await preRegisterLANDevices(devices, fromAPI: true) }
        if stopped { return }

        // Real-time updates connect in the background (and retry on their own): accessories never wait.
        if configuration.connectionMode != .lan, socket == nil {
            let socket = makeSocket(api)
            self.socket = socket
            Task { await socket.start() }
        }
        await registerAccessories(devices, groups: groups, api: api)
        if stopped { return registry.destroyAllHandlers() }
        initialized = true
        logger.info("eWeLink platform initialization complete")
    }

    /// 15 s doubling up to 5 min, ±20 %.
    nonisolated static func retryDelay(attempt: Int, random: Double) -> Double {
        retryBackoff.milliseconds(attempt: attempt - 1, random: random)
    }

    private nonisolated static let retryBackoff = Backoff(
        initial: .milliseconds(Timing.discoveryRetryBase), maximum: .milliseconds(Timing.discoveryRetryMaximum),
        jitter: .proportional(Timing.discoveryRetryJitter))

    private func scheduleRetry() {
        guard !stopped, retryTask == nil else { return }
        retryAttempts += 1
        let delay = Self.retryDelay(attempt: retryAttempts, random: dependencies.random())
        logger.warning("Retrying eWeLink login/discovery in \(Int(jsRound(delay / 1000)))s (attempt \(retryAttempts + 1))")
        let clock = clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(milliseconds: delay) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            await self.discover()
        }
    }

    /// Devices with LAN support and an address from the cloud (or the cache) go to LAN control before mDNS
    /// finds them.
    private func preRegisterLANDevices(_ devices: [EWeLinkDevice], fromAPI: Bool) async {
        guard let lan else { return }
        var registered = 0, noIP = 0
        for device in devices where device.localtype == 1 {
            if let ip = device.ip, let port = device.port {
                await lan.registerDevice(device.deviceid, ip: ip, port: port, deviceKey: device.devicekey, encrypt: true)
                registered += 1
            } else {
                noIP += 1
                if fromAPI {
                    logger.debug("[\(device.name)] LAN capable but no IP from API (localtype=\(device.localtype.map(String.init) ?? "undefined"), ip=\(device.ip ?? "undefined"), port=\(device.port.map(String.init) ?? "undefined"))")
                }
            }
        }
        if registered > 0 { logger.info("Pre-registered \(registered) device(s) for LAN control from \(fromAPI ? "API" : "accessory cache")") }
        if noIP > 0, fromAPI { logger.info("\(noIP) device(s) support LAN but API didn't provide IP addresses") }
    }

    func stop() async {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        await socket?.disconnect()
        await lan?.stop()
        dispatcher.clear()
        registry.destroyAllHandlers()
        do {
            try contexts.flush()
        } catch {
            logger.warning("Could not save accessory state: \(error)")
        }
    }

    // MARK: Discovery

    private func registerAccessories(_ devices: [EWeLinkDevice], groups: [JSONValue], api: CloudAPI) async {
        for device in devices { await factory.addAccessory(device) }
        let groupDevices = await processGroups(groups, api: api)
        let current = devices + groupDevices
        await removeStaleAccessories(current)
        saveDeviceCache(current)
    }

    /// eWeLink groups become devices of UIID 5000, controlled through the HTTP API.
    func processGroups(_ groups: [JSONValue], api: CloudAPI) async -> [EWeLinkDevice] {
        guard !groups.isEmpty else { return [] }
        logger.info("Processing \(groups.count) group(s) from eWeLink account")
        let apiKey = await api.apiKey
        var devices: [EWeLinkDevice] = []
        for group in groups {
            var raw = group.objectValue ?? [:]
            let id = raw["id"]?.jsString ?? ""
            raw["extra"] = ["uiid": 5000]
            raw["deviceid"] = .string(id)
            raw["productModel"] = "Group [5000]"
            raw["brandName"] = "eWeLink"
            raw["online"] = true
            raw["params"] = .object(raw["params"]?.objectValue ?? [:])
            raw["devicekey"] = ""
            raw["apikey"] = .string(apiKey)
            raw["name"] = .string(raw["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Group \(id)")
            raw["deviceStatus"] = "online"
            raw["createdAt"] = .string(clock.now.formatted(.iso8601))
            let device = EWeLinkDevice(raw: raw)
            registry.store(device)
            devices.append(device)
            await factory.addAccessory(device)
        }
        return devices
    }

    /// Accessories whose device left the account (or is ignored) leave HomeKit; channels and RF sub-devices
    /// stay while their parent exists.
    func removeStaleAccessories(_ current: [EWeLinkDevice]) async {
        let ids = Set(current.map(\.deviceid).filter { !isLeftOut($0) })
        let prefix = "\(EWeLinkPlugin.platform):"
        func isStale(_ id: String) -> Bool {
            guard id.hasPrefix(prefix) else { return false }
            let deviceID = String(id.dropFirst(prefix.count))
            return !ids.contains(deviceID) && !ids.contains(DeviceLimits.parentDeviceID(deviceID))
        }
        let accessoryIDs = Set(context.accessories.map(\.id))
        for id in accessoryIDs.union(registry.handlers.keys) where isStale(id) {
            registry.removeHandler(id)
            contexts.removeValue(forKey: id)
        }
        await context.removeAccessories(keeping: accessoryIDs.filter { !isStale($0) })
    }

    /// Takes an accessory off the bridge and drops its handler and saved state.
    func removeAccessory(id: String) async {
        registry.removeHandler(id)
        contexts.removeValue(forKey: id)
        guard context.accessory(id: id) != nil else { return }
        do {
            try await context.remove(id: id)
        } catch {
            logger.warning("Could not remove accessory \(id): \(error)")
        }
    }

    // MARK: The device cache file

    struct DeviceCacheFile: Codable {
        var devices: [JSONValue]
    }

    private func saveDeviceCache(_ devices: [EWeLinkDevice]) {
        do {
            try deviceCache.save(DeviceCacheFile(devices: devices.map(\.json)))
        } catch {
            logger.warning("Could not save the device cache: \(error)")
        }
    }

    /// The devices of the last discovery.
    func loadDeviceCache() -> [EWeLinkDevice] {
        (deviceCache.load()?.devices ?? []).compactMap(EWeLinkDevice.init)
    }

    /// Handlers for the cached devices, so HomeKit and LAN control work before the cloud answers.
    func restoreCachedAccessories() async -> Int {
        var restored = 0
        for device in loadDeviceCache() where !device.deviceid.isEmpty && !isLeftOut(device.deviceid) {
            let before = registry.handlers.count
            await factory.addAccessory(device)
            restored += max(0, registry.handlers.count - before)
        }
        return restored
    }

    // MARK: Updates and commands

    /// Routes an update (WebSocket, LAN, a query's answer) to the device's handler, or to every channel of a
    /// multi-channel device.
    func handleDeviceUpdate(_ deviceID: String, _ params: DeviceParams) {
        guard let box = registry.box(deviceID) else {
            logger.debug("Device not found in cache for update: \(deviceID)")
            return
        }
        let uiid = box.device.uiid
        let channelCount = DeviceCatalog.channelCount(uiid)
        let isCurtain = uiid == 126 && DeviceCatalog.hasCurtainParams(box.device.params)
        let single = registry.handler(AccessoryRecord.accessoryID(deviceID))
        if channelCount <= 1 || isCurtain || single != nil {
            if let single {
                apply(params, to: single)
            } else {
                logger.debug("No handler found for device update: \(deviceID)")
            }
            return
        }
        for id in DeviceRegistry.channelIDs(deviceID, channelCount: channelCount) {
            if let handler = registry.handler(id) { apply(params, to: handler) }
        }
    }

    private func apply(_ params: DeviceParams, to handler: BaseAccessory) {
        handler.updateState(params)
        if let online = params["online"] { handler.markStatus(online == .bool(true)) }
    }

    func sendDeviceCommand(_ deviceID: String, _ params: DeviceParams) async -> Bool {
        await dispatcher.sendDeviceCommand(deviceID, params)
    }

    func queryDeviceState(_ deviceID: String) async -> Bool {
        await dispatcher.queryDeviceState(deviceID)
    }

    func curtainStaggerDelay() -> Int { dispatcher.curtainStaggerDelay() }

    func setDeviceTemperature(_ deviceID: String, _ temperature: Double) { registry.setTemperature(deviceID, temperature) }
    func deviceTemperature(_ deviceID: String) -> Double? { registry.temperature(deviceID) }

    /// The RF sub-device handlers of a bridge, with their buttons.
    func rfHandlers(bridge deviceID: String) -> [BaseAccessory] {
        registry.handlers.values.filter { $0.box.device.deviceid == deviceID && $0.record.buttons != nil }
            .sorted { ($0.record.rfButtonIndex ?? 0) < ($1.record.rfButtonIndex ?? 0) }
    }
}
