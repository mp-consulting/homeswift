import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// TP-Link Tapo plugs and bulbs on the local network: P100/P105 and P110 plugs as Outlets (the P110 with its power on
/// Eve's characteristics and the Status page's Energy section), L510E, L520E and L530E bulbs as Lightbulbs (the white and
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
    }

    public static let platform = "TapoP100"
    public static let name = "TP-Link Tapo"
    public static let icon: String? = "outlet"
    public static let summary: String? = "Tapo plugs and bulbs on the local network"

    static let defaultUpdateInterval = 10.0
    static let defaultTimeout = 2.0
    static let defaultWaitTimeUpdate = 100.0
    /// The longest wait between polls of a device that does not answer.
    static let maximumBackoff = 300.0

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    /// The devices, by Device Id.
    private(set) var devices: [String: TapoDevice] = [:]
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    func scaled(_ seconds: Double) -> Duration { .seconds(seconds * dependencies.timeScale) }

    /// The account: what Setup kept in the vault, else the block's `username` and `password`.
    nonisolated var credentials: TapoCredentials? {
        if let kept = context.credentials(as: TapoCredentials.self), !kept.username.isEmpty, !kept.password.isEmpty { return kept }
        guard let username = configuration.username, !username.isEmpty, let password = configuration.password, !password.isEmpty else { return nil }
        return TapoCredentials(username: username, password: password)
    }

    /// The block's devices with an address, the first of each Device Id; an Excluded one is left out.
    func configuredDevices() -> [(deviceID: String, device: Configuration.Device)] {
        var seen = Set<String>()
        var devices: [(String, Configuration.Device)] = []
        for device in configuration.devices ?? [] {
            guard let deviceID = device.deviceID else {
                logger.warning("A device has no host: it is left out")
                continue
            }
            guard seen.insert(deviceID).inserted else {
                logger.warning("Two devices have the same host and name (\(device.trimmedHost ?? "")): only the first is used")
                continue
            }
            devices.append((deviceID, device))
        }
        return devices
    }

    public func start() async throws {
        let configured = configuredDevices()
        if credentials == nil, !configured.isEmpty {
            logger.error("No Tapo account: set username and password, or sign in through Add accessories")
        }
        for (deviceID, device) in configured where !context.isExcluded(deviceID) {
            try await startDevice(deviceID: deviceID, device: device)
        }
        let kept = Set(devices.keys.map(Self.accessoryID(deviceID:)))
        _ = await context.removeAccessories(keeping: kept)
    }

    public func stop() async {
        tasks.cancelAll()
        for device in devices.values { await device.services?.history?.flush() }
        devices.removeAll()
    }

    private func startDevice(deviceID: String, device: Configuration.Device) async throws {
        guard let host = device.trimmedHost else { return }
        let id = Self.accessoryID(deviceID: deviceID)
        let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? host
        let kind = TapoKind(type: device.type)
        let interval = device.updateInterval?.positive ?? Self.defaultUpdateInterval
        let settings = TapoDevice.Settings(
            deviceID: deviceID, name: name, host: host, kind: kind, interval: scaled(interval),
            backoff: Backoff(initial: scaled(interval), maximum: scaled(max(interval, Self.maximumBackoff)), jitter: .proportional(0.1)),
            writeDelay: scaled((configuration.waitTimeUpdate?.value.flatMap { $0 >= 0 ? $0 : nil } ?? Self.defaultWaitTimeUpdate) / 1000),
            bulbEnergyInterval: dependencies.bulbEnergyInterval)
        let connection = TapoConnection(
            host: host, http: dependencies.http, requestTimeout: scaled(device.timeout?.positive ?? Self.defaultTimeout),
            handshakeTimeout: scaled(5), logger: logger) { [weak self] in self?.credentials }
        let series = context.series("\(deviceID):power")
        let energyTag = EnergyTag(role: .home, device: name)
        let context = context
        let tapo = TapoDevice(settings: settings, connection: connection, logger: logger) { watts in
            context.recordValue(watts, series: series, energy: energyTag)
        }
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

    /// A Device Id as a file name: letters, digits, dots and dashes.
    static func fileName(_ deviceID: String) -> String {
        String(deviceID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}
