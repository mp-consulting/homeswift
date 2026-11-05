import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// TP-Link Tapo plugs and bulbs on the local network: P100/P105 and P110 plugs as Outlets (the P110 with its power on
/// Eve's characteristics and history, not the Status page's Energy section, where a whole-home meter would count it
/// twice), L510E, L520E and L530E bulbs as Lightbulbs (the white and
/// colour ones with Adaptive Lighting). Each device is listed by address in `devices` and reached over HTTP with KLAP,
/// or securePassthrough on older firmware, signed in with the Tapo account's email and password.
///
/// The block is the one of homebridge-tapo (`TapoP100`), so a Homebridge configuration works unchanged; this is a
/// clean-room implementation from the functional spec in docs/clean-room/Tapo.md. See README.md in this directory.
public actor TapoPlugin: HomeswiftPlugin {
    /// What the plugin uses to reach its devices; tests swap it for a fake, and shorten the delays with `timeScale`.
    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient(maximumBodySize: 256 * 1024)
        /// Multiplies every interval, timeout and delay: 1 for real devices.
        var timeScale: Double = 1
        /// How often an L530 is asked for its energy.
        var bulbEnergyInterval: Duration = .seconds(600)
        /// How long Setup waits for a device to check the account with.
        var setupTimeout: Duration = .seconds(5)
        /// How a camera's Streamd connection is opened (TCP; a fake in tests).
        var connect: StreamdClient.Connect = { host, port, timeout in try await TCPStream.connect(host: host, port: port, timeout: timeout) }
        var ports = RtpPortAllocator()
        var cameraTiming = TapoCameraFeed.Timing()
        /// The TP-Link cloud, for the cameras' motion.
        var cloudHTTP: any HTTPSending = HTTPClient(tls: .authority(pem: TapoCloud.roots, serverName: nil), maximumBodySize: 1024 * 1024)
        var cloudEntry = TapoCloud.entry
        var motionTiming = TapoMotionWatcher.Timing()
        var motionHold: Duration = .seconds(30)
        var macAddress: @Sendable (String) async -> String? = { await ARPTable.macAddress(for: $0) }
        /// The ARP table's entries (IP and MAC): the addresses of the cameras the cloud lists, at Setup.
        var neighbours: @Sendable () async -> [(ip: String, mac: String)] = { await ARPTable.entries() }
        /// Makes the system resolve the local networks' addresses, when the table lacks a camera the cloud lists.
        var resolveNeighbours: @Sendable (_ wanted: Set<String>) async -> Void = { await ARPTable.resolveLocalNetworks(lookingFor: $0) }
        /// The cameras' control API (pan and tilt); nil for HTTPS that pins each camera's certificate on first use.
        var controlHTTP: (any HTTPSending)? = nil
        /// How long Setup's discovery waits for the cloud's list of cameras.
        var cloudListTimeout: Duration = .seconds(4)
    }

    public static let platform = "TapoP100"
    public static let name = "TP-Link Tapo"
    public static let icon: String? = "logo-tapo"
    public static let summary: String? = "Tapo plugs, bulbs and battery cameras on the local network"

    static let defaultUpdateInterval = 10.0
    static let defaultTimeout = 2.0
    static let defaultWaitTimeUpdate = 100.0
    /// The longest wait between polls of a device that does not answer.
    static let maximumBackoff = 300.0

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    /// The devices, by Device Id.
    private(set) var devices: [String: TapoDevice] = [:]
    /// The battery cameras, by Device Id.
    var cameraRuntimes: [String: TapoCameraRuntime] = [:]
    var ffmpegOptions: FfmpegOptions?
    /// What is known of each camera's motor (`ptz.json`), read once.
    var ptzStates: [String: PTZState]?
    /// When asking a camera about its motor last failed: not again for a while (TapoPTZ.swift).
    var ptzProbeFailures: [String: ContinuousClock.Instant] = [:]
    /// When each camera's presets were last read.
    var presetsReadAt: [String: ContinuousClock.Instant] = [:]
    /// The account's sign-in to the TP-Link cloud, and the watch of its cameras' notifications.
    let cloud: TapoCloud
    let motionWatcher: TapoMotionWatcher
    /// The devices that completed a KLAP handshake, which never fall back to securePassthrough.
    let klapDevices: KLAPDevices
    /// Each camera's pinned control API certificate, by Device Id (fingerprints, not secrets).
    let controlPins: PersistedDictionary<String>
    private let credentialCache: NIOLockedValueBox<TapoCredentials??>
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        klapDevices = KLAPDevices(file: context.jsonFile("klap-devices.json", as: [String].self), logger: context.logger)
        controlPins = context.persistedDictionary("control-certificates.json", of: String.self, autosave: nil)
        let cache = NIOLockedValueBox<TapoCredentials??>(nil)
        credentialCache = cache
        cloud = Self.makeCloud(context: context, dependencies: dependencies) {
            Self.cachedCredentials(cache, context: context, configuration: configuration)
        }
        motionWatcher = TapoMotionWatcher(cloud: cloud, timing: dependencies.motionTiming, logger: context.logger, macAddress: dependencies.macAddress)
    }

    /// The cloud's session, kept in the vault.
    static func makeCloud(context: PluginContext, dependencies: Dependencies, credentials: @escaping @Sendable () -> TapoCredentials?) -> TapoCloud {
        let file = context.secretFile("cloud-session.json", as: TapoCloud.Session.self)
        let logger = context.logger
        return TapoCloud(http: dependencies.cloudHTTP, entry: dependencies.cloudEntry, credentials: credentials, load: { file.load() }, save: { session in
            do { try file.save(session) } catch { logger.warning("Could not keep the Tapo cloud's session: \(error)") }
        }, logger: logger)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    func scaled(_ seconds: Double) -> Duration { .seconds(seconds * dependencies.timeScale) }

    /// The account: what Setup kept in the vault, else the block's `username` and `password`. The vault is read once a
    /// run: a Setup that changes the account reloads the plugin.
    nonisolated var credentials: TapoCredentials? {
        Self.cachedCredentials(credentialCache, context: context, configuration: configuration)
    }

    static func cachedCredentials(_ cache: NIOLockedValueBox<TapoCredentials??>, context: PluginContext, configuration: Configuration) -> TapoCredentials? {
        cache.withLockedValue { cached in
            if let cached { return cached }
            let found = readCredentials(context: context, configuration: configuration)
            cached = .some(found)
            return found
        }
    }

    private static func readCredentials(context: PluginContext, configuration: Configuration) -> TapoCredentials? {
        if let kept = context.credentials(as: TapoCredentials.self), !kept.username.isEmpty, !kept.password.isEmpty { return kept }
        guard let username = configuration.username, !username.isEmpty, let password = configuration.password, !password.isEmpty else { return nil }
        return TapoCredentials(username: username, password: password)
    }

    /// The devices: those of `_accessories` with a `host` (by their Device Id, the canonical shape), then those of the
    /// Homebridge-shaped `devices` with an address, the first of each Device Id; Excluded ones included (Setup lists them).
    /// `log` says what is left out.
    func configuredDevices(log: Bool = false) -> [(deviceID: String, device: Configuration.Device)] {
        var seen = Set<String>()
        var devices: [(String, Configuration.Device)] = []
        for (deviceID, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key }) where settings.plugin["host"] != nil {
            guard let device = settings.decode(Configuration.Device.self, adding: [:]), device.trimmedHost != nil else {
                if log { logger.warning("The settings of \(deviceID) have no usable host: it is left out") }
                continue
            }
            seen.insert(deviceID)
            devices.append((deviceID, device))
        }
        for device in configuration.devices ?? [] {
            guard let deviceID = device.deviceID else {
                if log { logger.warning("A device has no host: it is left out") }
                continue
            }
            guard seen.insert(deviceID).inserted else {
                if log { logger.warning("Two devices have the same host and name (\(device.trimmedHost ?? "")): only the first is used") }
                continue
            }
            devices.append((deviceID, device))
        }
        return devices
    }

    public func start() async throws {
        let configured = configuredDevices(log: true)
        if credentials == nil, !configured.isEmpty {
            logger.error("No Tapo account: set username and password, or sign in through Add accessories")
        }
        var kept = Set<String>()
        for (deviceID, device) in configured where !context.isExcluded(deviceID) {
            if let kind = TapoCameraKind(type: device.type) {
                kept.formUnion(try await startCamera(deviceID: deviceID, device: device, kind: kind))
            } else {
                try await startDevice(deviceID: deviceID, device: device)
            }
        }
        kept.formUnion(devices.keys.map(Self.accessoryID(deviceID:)))
        if !cameraRuntimes.isEmpty {
            let watcher = motionWatcher
            tasks.add { await watcher.run() }
        }
        _ = await context.removeAccessories(keeping: kept)
    }

    public func stop() async {
        tasks.cancelAll()
        for device in devices.values { await device.services?.history?.flush() }
        devices.removeAll()
        await stopCameras()
    }

    private func startDevice(deviceID: String, device: Configuration.Device) async throws {
        guard let host = device.trimmedHost else { return }
        let id = Self.accessoryID(deviceID: deviceID)
        let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? host
        let kind = TapoKind(type: device.type)
        let interval = device.updateInterval?.positive ?? Self.defaultUpdateInterval
        let settings = TapoDevice.Settings(
            name: name, host: host, kind: kind, interval: scaled(interval),
            backoff: Backoff(initial: scaled(interval), maximum: scaled(max(interval, Self.maximumBackoff)), jitter: .proportional(0.1)),
            settleTime: scaled(2),
            writeDelay: scaled((configuration.waitTimeUpdate?.value.flatMap { $0 >= 0 ? $0 : nil } ?? Self.defaultWaitTimeUpdate) / 1000),
            bulbEnergyInterval: dependencies.bulbEnergyInterval)
        let connection = makeConnection(
            deviceID: deviceID, host: host, requestTimeout: scaled(device.timeout?.positive ?? Self.defaultTimeout), handshakeTimeout: scaled(5)
        ) { [weak self] in self?.credentials }
        let tapo = TapoDevice(settings: settings, connection: connection, logger: logger)
        let historyURL = kind.measuresEnergy ? context.storageDirectory.appendingPathComponent("\(Self.fileName(deviceID))_persist.json") : nil
        let services = TapoServices.make(
            id: id, name: name, kind: kind, cached: context.accessories.first { $0.id == id }, historyURL: historyURL, context: context
        ) { [weak tapo] change in
            guard let tapo else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await tapo.write(change)
        }
        await tapo.attach(services)
        try context.add(services.accessory)
        devices[deviceID] = tapo
        tasks.add { await tapo.run() }
    }

    /// A device's connection, which remembers in `klapDevices` that it spoke KLAP.
    func makeConnection(
        deviceID: String, host: String, requestTimeout: Duration, handshakeTimeout: Duration, credentials: @escaping @Sendable () -> TapoCredentials?
    ) -> TapoConnection {
        let known = klapDevices
        return TapoConnection(
            host: host, http: dependencies.http, requestTimeout: requestTimeout, handshakeTimeout: handshakeTimeout, logger: logger,
            spokeKLAP: { known.contains(deviceID) }, rememberKLAP: { known.remember(deviceID) }, credentials: credentials)
    }

    /// A Device Id as a file name: letters, digits, dots and dashes.
    static func fileName(_ deviceID: String) -> String {
        String(deviceID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}

/// The Device Ids of the devices that completed a KLAP handshake, in the plugin's `klap-devices.json` (not a secret).
final class KLAPDevices: Sendable {
    private let file: JSONFile<[String]>
    private let known: NIOLockedValueBox<Set<String>>
    private let logger: Logger

    init(file: JSONFile<[String]>, logger: Logger) {
        self.file = file
        self.logger = logger
        known = NIOLockedValueBox(Set(file.load() ?? []))
    }

    func contains(_ deviceID: String) -> Bool { known.withLockedValue { $0.contains(deviceID) } }

    func remember(_ deviceID: String) {
        let all = known.withLockedValue { known -> [String]? in known.insert(deviceID).inserted ? known.sorted() : nil }
        guard let all else { return }
        do {
            try file.save(all)
        } catch {
            logger.warning("Could not keep which devices speak KLAP: \(error)")
        }
    }
}
