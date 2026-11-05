import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shelly Gen 2, Gen 3 and Gen 4 devices (Plus, Pro, Gen3, Gen4): found over mDNS (`_shelly._tcp`), at the addresses
/// config.json gives and where they were last seen, driven over their WebSocket RPC (`ws://<host>/rpc`), whose
/// notifications keep HomeKit current without polling.
///
/// A `ShellyNG` block of homebridge-shelly-ng loads unchanged; the bridge writes each device's options in `_accessories`
/// by its Device Id (`shellyplus1pm-aabbccddeeff`) and its password in the vault (ShellyNGSettings.swift). Each accessory
/// is `ShellyNG:<deviceId>-<switch|switch-N|cover|buttons|switchN|…>`, the Homebridge plugin's seeds. Gen 1 devices are
/// `ShellyPlugin`'s (the `Shelly` block).
public actor ShellyNGPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// The Homebridge plugin's per-device options (`Gen2DeviceOptions`); entries without an `id` are ignored.
        public var devices: [JSONValue]?
        /// `{ "enable": true, "interface": "eth0" }`; mDNS runs unless `enable` is anything but `true`.
        public var mdns: JSONValue?
        /// `{ "requestTimeout": 10, "pingInterval": 60, "reconnectInterval": [5, 10, 30, 60, 300, 600] }`.
        public var websocket: JSONValue?
    }

    /// A device announced over mDNS, or listed with an address.
    struct Sighting: Sendable, Equatable {
        var deviceID: String
        var host: String
    }

    struct Dependencies: Sendable {
        var connector: ShellyRPC.Connector = { url in try await WebSocket.connect(to: url, options: WebSocket.Options(timeout: .seconds(10))) }
        var browse: @Sendable (Logger, String?) -> AsyncStream<Sighting> = ShellyNGPlugin.browse
        var http: any HTTPSending = HTTPClient()
        /// Multiplies the WebSocket's and the retries' delays; tests shorten them.
        var timeScale: Double = 1
        /// How long slider writes wait for the next one (`LatestCallGuard`).
        var writeDelay: Duration = .milliseconds(100)
        /// How long Setup's discovery browses on an instance that is not running.
        var discoveryWindow: Duration = .seconds(3)
        /// The retries of a device listed with an address that did not answer.
        var retry = Backoff(initial: .seconds(10), maximum: .seconds(600), jitter: .proportional(0.2))
    }

    public static let platform = "ShellyNG"
    public static let name = "Shelly"
    public static let icon: String? = "switch"
    public static let summary: String? = "Shelly Plus, Pro, Gen3 and Gen4 relays, covers, buttons, lights and meters"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let rpcSettings: RPCSettings
    let clientID = "homeswift-\(Int.random(in: 0...1_000_000))"
    var logger: Logger { context.logger }

    private(set) var devices: [String: Gen2Device] = [:]
    private var adding: Set<String> = []
    /// Unknown models and Excluded devices, for the rest of the run.
    private var ignored: Set<String> = []
    /// Where each device was last seen, by Device Id.
    private(set) var sightings: [String: String] = [:]
    private(set) var failures: [String: String] = [:]
    private let tasks = TaskBag()
    private(set) var browsing = false
    private var stopped = false
    /// The names the Shelly app gave the devices in Shelly Cloud, read once for every device (empty without an account).
    private var cloudNames: Task<[String: String], Never>?

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        var settings = RPCSettings(timeScale: dependencies.timeScale)
        let websocket = configuration.websocket
        if let timeout = websocket?["requestTimeout"]?.number { settings.requestTimeout = timeout }
        if let ping = websocket?["pingInterval"]?.number { settings.pingInterval = ping }
        if let schedule = RPCSettings.reconnectSchedule(websocket?["reconnectInterval"]) { settings.reconnectInterval = schedule }
        rpcSettings = settings
    }

    /// The device of an accessory id's part after `ShellyNG:`: `<app>-<12 hex>` before its `-<accessory>`.
    public static func deviceID(ofAccessory suffix: String) -> String? {
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    // MARK: Lifecycle

    public func start() async throws {
        await removeExcludedAccessories()
        // Devices with an address in config.json, then where the cache last saw them, then mDNS.
        var known = cachedDevices().mapValues(\.hostname)
        for (id, options) in allOptions() where !options.exclude { if let host = options.hostname { known[id] = host } }
        for (id, host) in known.sorted(by: { $0.key < $1.key }) {
            tasks.add { [weak self] in await self?.keepTrying(Sighting(deviceID: id, host: host)) }
        }
        startMDNS()
    }

    public func stop() async {
        stopped = true
        tasks.cancelAll()
        for device in devices.values { await device.stop() }
        devices.removeAll()
        browsing = false
    }

    private func startMDNS() {
        let mdns = configuration.mdns
        guard (mdns?["enable"] ?? .bool(true)) == .bool(true) else {
            logger.debug("mDNS device discovery disabled")
            return
        }
        let interface = mdns?["interface"]?.stringValue?.trimmedNonEmpty
        if let interface, !Self.isLocalInterface(interface) {
            logger.error("Failed to start mDNS device discovery: Invalid network interface \"\(interface)\"")
            return
        }
        let browse = dependencies.browse, logger = logger
        browsing = true
        tasks.add { [weak self] in
            for await sighting in browse(logger, interface) {
                guard let self else { return }
                await self.discovered(sighting)
            }
        }
        logger.info("mDNS device discovery started")
    }

    /// An interface name or one of the host's IPv4 addresses.
    static func isLocalInterface(_ value: String) -> Bool {
        if let address = IPv4Network.parse(value) { return NetworkInterfaces.ipv4().contains { $0.address == address } }
        return if_nametoindex(value) != 0
    }

    /// `_shelly._tcp` services: the instance name is the device id, the first IPv4 address its host.
    static func browse(logger: Logger, interface: String?) -> AsyncStream<Sighting> {
        let index: UInt32? = interface.flatMap { IPv4Network.parse($0) == nil ? if_nametoindex($0) : nil }
        return AsyncStream { continuation in
            let task = Task {
                for await event in BonjourBrowser.browse(type: "_shelly._tcp", logger: logger) {
                    guard case .found(let service) = event else { continue }
                    if let index, service.interfaceIndex != index { continue }
                    guard let host = service.addresses.first(where: { IPv4Network.parse($0) != nil }) else { continue }
                    let id = service.name.split(separator: ".").first.map(String.init) ?? service.name
                    continuation.yield(Sighting(deviceID: id, host: host))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A device listed with an address: tried until it answers, with `Backoff` between attempts.
    private func keepTrying(_ sighting: Sighting) async {
        var attempt = 0
        while !Task.isCancelled {
            await discovered(sighting)
            if devices[sighting.deviceID] != nil || ignored.contains(sighting.deviceID) { return }
            let delay = dependencies.retry.delay(attempt: attempt)
            attempt += 1
            try? await Task.sleep(for: delay * dependencies.timeScale)
        }
    }

    // MARK: Devices

    /// A device seen somewhere: added once, followed when its address changes, ignored when Excluded or unknown.
    func discovered(_ sighting: Sighting) async {
        let id = sighting.deviceID
        sightings[id] = sighting.host
        if let device = devices[id] {
            // An address in config.json is the user's; mDNS moves the others (a DHCP change).
            if options(for: id).hostname == nil, await device.host != sighting.host {
                logger.info("[\(id)] Device moved to \(sighting.host)")
                await device.rpc.move(to: sighting.host)
                saveCache(id: id, model: device.info["model"]?.stringValue, host: sighting.host)
            }
            return
        }
        guard !adding.contains(id), !ignored.contains(id) else { return }
        let options = options(for: id)
        if options.exclude || context.isExcluded(id) {
            ignored.insert(id)
            logger.info("[\(id)] Device excluded")
            await removeAccessories(of: id)
            forgetCache(id: id)
            return
        }
        adding.insert(id)
        defer { adding.remove(id) }
        do {
            try await add(id, host: sighting.host, options: options)
            failures[id] = nil
        } catch {
            failures[id] = "\(error)"
            logger.error("Failed to add discovered device (id: \(id)): \(error)")
            // Its cached accessories answer No Response until it does.
            for accessory in context.accessories where context.isAccessory(accessory.id, of: id) { accessory.isUnavailable = true }
        }
    }

    private func add(_ id: String, host: String, options: Gen2DeviceOptions) async throws {
        switch options.protocolName {
        case "websocket": break
        case "outboundWebsocket": throw RPCError.notConnected("No WebSocket server has been configured")
        default: throw RPCError.notConnected("Unknown protocol \"\(options.protocolName)\"")
        }
        var deviceLogger = logger
        deviceLogger[metadataKey: "device"] = "\(id)"
        let password = options.password ?? context.credentials(for: id, as: DeviceCredentials.self)?.password
        let rpc = ShellyRPC(host: host, clientID: clientID, password: password, settings: rpcSettings, connector: dependencies.connector, logger: deviceLogger)
        do {
            let info = try await rpc.call("Shelly.GetDeviceInfo")
            let returned = info["id"]?.stringValue ?? ""
            guard returned == id else { throw RPCError.notConnected("Unexpected device ID (returned: \(returned), expected: \(id))") }
            let model = info["model"]?.stringValue ?? ""
            let status = try await rpc.call("Shelly.GetStatus")
            let config = try await rpc.call("Shelly.GetConfig")
            let device = Gen2Device(deviceID: id, rpc: rpc, info: info, status: status, config: config, options: options, context: context,
                                    logger: deviceLogger, writeDelay: dependencies.writeDelay, http: dependencies.http, password: password)
            if let cloud {
                if cloudNames == nil { cloudNames = Task { await cloud.deviceNames() } }
                await device.setCloudNames(await cloudNames?.value ?? [:])
            }
            let accessories = Gen2Models.unsupported.contains(model.uppercased()) ? [] : await device.makeAccessories(platform: Self.platform)
            guard !accessories.isEmpty else {
                ignored.insert(id)
                await rpc.stop()
                logger.info("[\(id)] Unknown device of model \"\(model)\" discovered.")
                return
            }
            let ids = Set(accessories.map(\.id))
            for accessory in context.accessories where context.isAccessory(accessory.id, of: id) && !ids.contains(accessory.id) {
                try? await context.remove(id: accessory.id)
            }
            // Stopped while the device answered: nothing of it stays behind.
            guard !stopped else {
                await rpc.stop()
                return
            }
            for accessory in accessories {
                if let cached = context.accessory(id: accessory.id) { accessory.takeValues(from: cached) }
                do {
                    try context.add(accessory)
                } catch {
                    // All or none: the ones added already would stay without a connection.
                    for added in accessories.prefix(while: { $0.id != accessory.id }) { try? await context.remove(id: added.id) }
                    throw error
                }
            }
            devices[id] = device
            await device.watch()
            if let cloud { await device.startCloudImport(cloud, delay: .milliseconds(Int(1100 * dependencies.timeScale))) }
            saveCache(id: id, model: model, host: host)
            let name = await device.baseName
            logger.info("[\(name)] Device added")
        } catch {
            await rpc.stop()
            throw error
        }
    }

    private func removeAccessories(of id: String) async {
        for accessory in context.accessories where context.isAccessory(accessory.id, of: id) {
            try? await context.remove(id: accessory.id)
        }
    }

    /// Cached accessories of devices Excluded since.
    private func removeExcludedAccessories() async {
        for accessory in context.accessories {
            guard let id = Self.deviceID(ofAccessory: String(accessory.id.dropFirst(Self.platform.count + 1))) else { continue }
            if options(for: id).exclude || context.isExcluded(id) {
                try? await context.remove(id: accessory.id)
                forgetCache(id: id)
            }
        }
    }

    // MARK: The device cache

    struct CachedDevice: Codable, Sendable, Equatable {
        var model: String?
        var hostname: String
    }

    private var cacheFile: JSONFile<[String: CachedDevice]> { context.jsonFile("shelly-ng-devices.json", as: [String: CachedDevice].self) }

    func cachedDevices() -> [String: CachedDevice] { cacheFile.load() ?? [:] }

    private func saveCache(id: String, model: String?, host: String) {
        var devices = cachedDevices()
        let entry = CachedDevice(model: model, hostname: host)
        guard devices[id] != entry else { return }
        devices[id] = entry
        do { try cacheFile.save(devices) } catch { logger.error("Failed to save cached devices: \(error)") }
    }

    private func forgetCache(id: String) {
        var devices = cachedDevices()
        guard devices.removeValue(forKey: id) != nil else { return }
        try? cacheFile.save(devices)
    }
}

/// What Setup keeps in the vault for a device whose authentication is on.
struct DeviceCredentials: Codable, Sendable {
    var username: String?
    var password: String
}
