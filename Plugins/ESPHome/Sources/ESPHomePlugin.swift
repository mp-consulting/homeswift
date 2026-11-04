import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// ESPHome devices over their native API (TCP 6053, plaintext or Noise-encrypted): switches, lights, binary sensors,
/// sensors, covers, fans, climates, locks and buttons, one accessory per entity, pushed by the device as they change.
///
/// A block of `homebridge-esphome-ts` loads unchanged (`devices` by `host`, `discover`, `retryAfter`, `blacklist`); its
/// accessories keep their identity, the entity's name (`esphome:<name>`, ESPHomeDevice.swift's `EntityDirectory`). What
/// the bridge writes is the canonical shape (ESPHomeSettings.swift): a device's `host`, `port` and `retryAfter` in
/// `_accessories` by its MAC, its encryption key or password in the vault. Each device is a device of Setup by its MAC
/// (ESPHomeSetup.swift), asking for its encryption key when it has one. See README.md in this directory.
public actor ESPHomePlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// A device of the Homebridge plugin's `devices`.
        public struct Device: Decodable, Sendable {
            public var host: String?
            public var port: Int?
            /// The legacy API password (firmware before 2026.1).
            public var password: String?
            /// The device's `api: encryption: key:`, base64 of 32 bytes.
            public var encryptionKey: String?
            /// Milliseconds; the platform's by default.
            public var retryAfter: Int?
        }

        public var name: String?
        public var devices: [Device]?
        /// Browse mDNS for devices at start and connect to each one found.
        public var discover: Bool?
        /// Milliseconds the browse lasts; 5000 by default.
        public var discoveryTimeout: Int?
        /// Milliseconds: the longest wait between attempts to reach a device (at most a minute); 90000 by default.
        public var retryAfter: Int?
        /// Entity names to leave out.
        public var blacklist: [String]?
        public var debug: Bool?
    }

    /// What the plugin uses to reach and find devices; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any ESPHomeTransport = TCPTransport()
        var browse: @Sendable (Duration, Logger) async -> [Announcement] = ESPHomeDiscovery.browse
        var timing = ESPHomeTiming()
        /// How long Setup's discovery browses on an instance that is not running.
        var setupDiscoveryWindow: Duration = .seconds(3)
    }

    public static let platform = "esphome"
    public static let name = "ESPHome"
    public static let icon: String? = "switch"
    public static let summary: String? = "Switches, lights, sensors, covers, fans and climates of ESPHome devices"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultRetryAfter = 90_000
    static let defaultDiscoveryTimeout = 5000

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let directory: EntityDirectory
    private let tasks = TaskBag()
    /// The devices the plugin runs, by `host:port`.
    private(set) var devices: [String: ESPHomeDevice] = [:]
    /// What mDNS announced at start (or Setup's browse), by MAC.
    private(set) var announced: [String: Announcement] = [:]
    /// The MAC each `host:port` answered with: what `canonicalSettings` and Setup key devices by.
    private(set) var learnedMACs: [String: String] = [:]
    /// What each device said of itself, by MAC.
    private(set) var learnedInfo: [String: DeviceInfo] = [:]
    /// Whether the start's mDNS browse ran: `announced` is what the network had then.
    var browsed = false
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        directory = EntityDirectory(file: context.jsonFile("entities.json"))
    }

    public static func deviceID(ofAccessory suffix: String) -> String? {
        // `<name>@<MAC>` and `<name>@<MAC>#<key>`; a bare name belongs to whichever device claimed it.
        guard let at = suffix.lastIndex(of: "@") else { return nil }
        return MACAddress.canonical(String(suffix[suffix.index(after: at)...].prefix { $0 != "#" }))
    }

    var blacklist: Set<String> { Set(configuration.blacklist ?? []) }

    static func milliseconds(_ value: Int?, default fallback: Int) -> Duration {
        .milliseconds(max(value ?? fallback, 0))
    }

    public func start() async throws {
        logger.info("Starting ESPHome")
        for accessory in context.accessories {
            let suffix = accessory.id.dropFirst(Self.platform.count + 1)
            let name = suffix.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if blacklist.contains(name) || blacklist.contains(String(suffix)) {
                logger.info("Removing the blacklisted accessory \(accessory.id)")
                try? await context.remove(id: accessory.id)
            }
        }
        let configured = configuredEndpoints()
        let discover = configuration.discover ?? false
        if configured.isEmpty && !discover {
            logger.error("No devices configured and discovery disabled: nothing will be exposed")
            return
        }
        guard discover else {
            for device in configured { run(device.endpoint, retryAfter: device.retryAfter) }
            return
        }
        let window = Self.milliseconds(configuration.discoveryTimeout, default: Self.defaultDiscoveryTimeout)
        let browse = dependencies.browse
        let logger = logger
        tasks.add { [weak self] in
            let found = await browse(window, logger)
            await self?.merge(found, into: configured)
        }
    }

    public func stop() async {
        tasks.cancelAll()
        await tasks.idle()
        devices.removeAll()
    }

    /// A device the plugin will connect to.
    struct Configured: Sendable {
        var endpoint: ESPHomeEndpoint
        var retryAfter: Duration
    }

    /// The devices set up through Setup (`_accessories` by MAC, with a host), then those of the Homebridge block's
    /// `devices`; Excluded ones left out, one per host and port.
    func configuredEndpoints() -> [Configured] {
        var result: [Configured] = []
        var seen = Set<String>()
        let platformRetry = configuration.retryAfter ?? Self.defaultRetryAfter
        for (mac, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key }) where !settings.excluded {
            guard let own = settings.decode(DeviceSettings.self), let host = own.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { continue }
            let credentials = context.credentials(for: mac, as: ESPHomeCredentials.self)
            let endpoint = ESPHomeEndpoint(
                host: host, port: own.port ?? ESPHomeEndpoint.defaultPort, encryptionKey: credentials?.encryptionKey?.nonEmpty,
                password: credentials?.password?.nonEmpty, expectedMAC: MACAddress.canonical(mac))
            guard seen.insert(Self.hostKey(endpoint.host, endpoint.port)).inserted else { continue }
            result.append(Configured(endpoint: endpoint, retryAfter: Self.milliseconds(own.retryAfter, default: platformRetry)))
        }
        for device in configuration.devices ?? [] {
            guard let host = device.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { continue }
            let port = device.port ?? ESPHomeEndpoint.defaultPort
            guard seen.insert(Self.hostKey(host, port)).inserted else { continue }
            if let mac = learnedMACs[Self.hostKey(host, port)], context.isExcluded(mac) { continue }
            let endpoint = ESPHomeEndpoint(host: host, port: port, encryptionKey: device.encryptionKey?.nonEmpty, password: device.password?.nonEmpty)
            result.append(Configured(endpoint: endpoint, retryAfter: Self.milliseconds(device.retryAfter, default: platformRetry)))
        }
        return result
    }

    /// The discovered devices joined to the configured ones (a configured `host` equal to the announced host name, or
    /// the MAC it was set up with): configured values win, the announced address replaces the host name. Devices found
    /// but not configured connect with the credentials the vault has for their MAC, or none.
    private func merge(_ found: [Announcement], into configured: [Configured]) {
        browsed = true
        var remaining = configured
        for announcement in found {
            if let mac = announcement.mac { announced[mac] = announcement }
            logger.info("Discovered \(announcement.name)")
            if let mac = announcement.mac, context.isExcluded(mac) { continue }
            let index = remaining.firstIndex { device in
                device.endpoint.host.lowercased() == announcement.hostName.lowercased()
                    || announcement.mac != nil && device.endpoint.expectedMAC == announcement.mac
                    || announcement.addresses.contains(device.endpoint.host)
            }
            var device: Configured
            if let index {
                device = remaining.remove(at: index)
            } else {
                let credentials = announcement.mac.flatMap { context.credentials(for: $0, as: ESPHomeCredentials.self) }
                device = Configured(
                    endpoint: ESPHomeEndpoint(
                        host: announcement.hostName, port: ESPHomeEndpoint.defaultPort, encryptionKey: credentials?.encryptionKey?.nonEmpty,
                        // Never a password to an address only an announcement gave: anyone on the network can announce.
                        password: nil, expectedMAC: announcement.mac),
                    retryAfter: Self.milliseconds(configuration.retryAfter, default: Self.defaultRetryAfter))
            }
            // A device opened by a password alone (sent in the clear) stays where it is configured: an announcement does
            // not move it to another address.
            let pinned = device.endpoint.password != nil && device.endpoint.encryptionKey == nil
            if !pinned {
                if let address = announcement.preferredAddress { device.endpoint.host = address }
                if announcement.port != ESPHomeEndpoint.defaultPort { device.endpoint.port = announcement.port }
            }
            run(device.endpoint, retryAfter: device.retryAfter)
        }
        for device in remaining { run(device.endpoint, retryAfter: device.retryAfter) }
    }

    private func run(_ endpoint: ESPHomeEndpoint, retryAfter: Duration) {
        let key = Self.hostKey(endpoint.host, endpoint.port)
        guard devices[key] == nil, !tasks.isStopped else { return }
        let device = ESPHomeDevice(endpoint: endpoint, retryAfter: retryAfter, environment: environment)
        devices[key] = device
        tasks.add { await device.run() }
    }

    var environment: DeviceEnvironment {
        DeviceEnvironment(
            context: context, directory: directory, transport: dependencies.transport, timing: dependencies.timing, blacklist: blacklist,
            verbose: configuration.debug ?? false,
            learned: { [weak self] host, port, info in await self?.learned(host: host, port: port, info: info) })
    }

    private func learned(host: String, port: Int, info: DeviceInfo) {
        guard let mac = MACAddress.canonical(info.mac) else { return }
        learnedMACs[Self.hostKey(host, port)] = mac
        learnedInfo[mac] = info
    }

    static func hostKey(_ host: String, _ port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(port)"
    }
}

/// What Setup keeps in the vault for a device.
struct ESPHomeCredentials: Codable, Sendable, Equatable {
    var encryptionKey: String?
    var password: String?

    var isEmpty: Bool { (encryptionKey ?? "").isEmpty && (password ?? "").isEmpty }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
