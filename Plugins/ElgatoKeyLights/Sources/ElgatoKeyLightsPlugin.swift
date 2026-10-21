import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Elgato Key Light, Key Light Air, Key Light Mini and Ring Light: found over Bonjour (`_elg._tcp`) or
/// listed in config.json, controlled over their HTTP API, polled for changes made elsewhere.
///
/// The configuration is the one of `@mp-consulting/homebridge-elgato-key-lights`, so a Homebridge block
/// works unchanged. See README.md in this directory.
public actor ElgatoKeyLightsPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            public var mac: String
            public var name: String?
            /// Overrides the name the light reports.
            public var displayName: String?
            public var host: String?
            /// Preferred over `host`.
            public var ip: String?
            public var port: Int?
            public var model: String?
            /// `false` keeps the light out of HomeKit.
            public var enabled: Bool?
            /// 0 means the platform's setting.
            public var powerOnBehavior: Int?
            public var powerOnBrightness: Int?
            /// Kelvin.
            public var powerOnTemperature: Int?
        }

        public var name: String?
        /// Milliseconds between polls; 250 at least, 1000 by default.
        public var pollingRate: Int?
        public var powerOnBehavior: Int?
        public var powerOnBrightness: Int?
        /// Kelvin, 2900 to 7000.
        public var powerOnTemperature: Int?
        public var switchOnDurationMs: Int?
        public var switchOffDurationMs: Int?
        public var colorChangeDurationMs: Int?
        /// Accepted for compatibility: Homeswift connects to the address Bonjour resolved, and falls back
        /// to the host name only when there is none.
        public var useIP: Bool?
        public var devices: [Device]?
    }

    /// A light announced over Bonjour or listed in config.json.
    struct DiscoveredLight: Sendable, Equatable {
        var name: String
        var mac: String
        var host: String
        var port: Int
    }

    /// What the plugin uses to reach and find lights; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any KeyLightTransport = URLSessionTransport()
        var discover: @Sendable (Logger) -> AsyncStream<DiscoveredLight> = Discovery.browse
    }

    public static let platform = "ElgatoKeyLights"
    public static let name = "Elgato Key Lights"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingRate = 1000
    static let minimumPollingRate = 250

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var logger: Logger { context.logger }

    private enum Status { case initializing, ready, failed }
    private var devices: [String: KeyLightDevice] = [:]
    private var status: [String: Status] = [:]
    /// Lights with an `ip` or `host` in config.json: announcements never move them.
    private var pinned: Set<String> = []
    private var discoveryTask: Task<Void, Never>?
    private var initializations: [Task<Void, Never>] = []

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        removeDisabledAccessories()
        registerConfiguredDevices()
        let discover = dependencies.discover
        let logger = logger
        discoveryTask = Task { [weak self] in
            for await light in discover(logger) {
                guard let self else { return }
                await self.handleDiscovered(light)
            }
        }
        logger.info("Started Bonjour discovery for Elgato lights")
    }

    public func stop() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        for task in initializations { task.cancel() }
        initializations.removeAll()
        for device in devices.values {
            await device.stopPolling()
        }
        logger.debug("Stopped")
    }

    /// The light with this MAC, once it answered.
    func device(mac: String) -> KeyLightDevice? { devices[Self.canonicalMAC(mac)] }

    /// Waits until every light found so far has been added or given up on. For tests.
    func settle() async {
        let pending = initializations
        for task in pending { await task.value }
    }

    // MARK: Discovery

    /// Lights from config.json work without Bonjour, e.g. in containers without multicast.
    private func registerConfiguredDevices() {
        for device in configuration.devices ?? [] {
            let mac = Self.canonicalMAC(device.mac)
            if device.enabled == false {
                logger.info("Skipping disabled light", metadata: ["light": "\(device.name ?? mac)"])
                continue
            }
            guard let host = device.ip ?? device.host, !host.isEmpty else {
                // Without an address the entry only names and tunes the light once Bonjour finds it.
                continue
            }
            let port = device.port ?? KeyLightClient.defaultPort
            guard KeyLightClient.isValidHost(host), KeyLightClient.isValidPort(port) else {
                logger.warning("Skipping light with an invalid address in config.json", metadata: ["light": "\(device.name ?? mac)", "host": "\(host)", "port": "\(port)"])
                continue
            }
            let light = DiscoveredLight(name: device.name ?? mac, mac: mac, host: host, port: port)
            logger.info("Registering configured light", metadata: ["light": "\(light.name)", "host": "\(host)"])
            pinned.insert(mac)
            initialize(light)
        }
    }

    /// The address config.json gives a light, for the ones registered from it.
    private func configuredLight(mac: String) -> DiscoveredLight? {
        guard let device = deviceConfiguration(mac: mac), let host = device.ip ?? device.host, !host.isEmpty else { return nil }
        return DiscoveredLight(name: device.name ?? mac, mac: mac, host: host, port: device.port ?? KeyLightClient.defaultPort)
    }

    private func handleDiscovered(_ light: DiscoveredLight) {
        let mac = Self.canonicalMAC(light.mac)
        let light = DiscoveredLight(name: light.name, mac: mac, host: light.host, port: light.port)
        switch status[mac] {
        case .ready:
            logger.debug("Light announced again", metadata: ["light": "\(light.name)", "host": "\(light.host)"])
            if pinned.contains(mac) { return }
            if let device = devices[mac] {
                Task { await device.follow(host: light.host, port: light.port) }
            }
        case .initializing:
            break
        case .failed:
            if pinned.contains(mac), let configured = configuredLight(mac: mac) {
                // A pinned light retries at its configured address, never at an announced one.
                logger.info("Retrying light at its configured address", metadata: ["light": "\(configured.name)", "host": "\(configured.host)"])
                initialize(configured)
            } else {
                logger.info("Retrying light with its announced address", metadata: ["light": "\(light.name)"])
                initialize(light)
            }
        case nil:
            logger.info("Discovered light", metadata: ["light": "\(light.name)", "host": "\(light.host)"])
            initialize(light)
        }
    }

    private func initialize(_ light: DiscoveredLight) {
        guard KeyLightClient.isValidHost(light.host), KeyLightClient.isValidPort(light.port) else {
            logger.warning("Ignoring light with an invalid address", metadata: ["light": "\(light.name)", "host": "\(light.host)", "port": "\(light.port)"])
            return
        }
        if deviceConfiguration(mac: light.mac)?.enabled == false {
            logger.debug("Ignoring disabled light", metadata: ["light": "\(light.name)"])
            return
        }
        status[light.mac] = .initializing
        initializations.append(Task { await self.connect(light) })
    }

    private func connect(_ light: DiscoveredLight) async {
        let interval = Duration.milliseconds(max(Self.minimumPollingRate, configuration.pollingRate ?? Self.defaultPollingRate))
        let client = KeyLightClient(host: light.host, port: light.port, transport: dependencies.transport)
        let device = KeyLightDevice(mac: light.mac, name: light.name, client: client, pollingInterval: interval, logger: logger)
        do {
            try await device.connect()
        } catch {
            logger.error("Could not reach \(light.name) at \(light.host):\(light.port), skipping: \(error)")
            status[light.mac] = .failed
            return
        }
        guard !Task.isCancelled else { return }

        let deviceConfiguration = self.deviceConfiguration(mac: light.mac)
        let reportedName = await device.displayName
        let name = deviceConfiguration?.displayName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? reportedName
        await device.applySettings(settings(for: device, configuration: deviceConfiguration))

        let accessory = await KeyLightAccessory.make(device: device, name: name, idPrefix: Self.platform)
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(name) to the bridge: \(error)")
            status[light.mac] = .failed
            return
        }
        devices[light.mac] = device
        status[light.mac] = .ready
        await device.startPolling()
        let model = await device.model
        let serial = await device.serialNumber
        logger.info("Added light", metadata: ["light": "\(name)", "model": "\(model)", "serial": "\(serial)"])
    }

    /// Lights disabled in config.json disappear from HomeKit instead of lingering as unresponsive tiles.
    private func removeDisabledAccessories() {
        for device in configuration.devices ?? [] where device.enabled == false {
            let id = "\(Self.platform):\(Self.canonicalMAC(device.mac))"
            guard context.accessory(id: id) != nil else { continue }
            do {
                try context.remove(id: id)
                logger.info("Removed disabled light from the bridge", metadata: ["light": "\(device.displayName ?? device.name ?? device.mac)"])
            } catch {
                logger.warning("Could not remove disabled light: \(error)")
            }
        }
    }

    // MARK: Settings

    func deviceConfiguration(mac: String) -> Configuration.Device? {
        let target = Self.canonicalMAC(mac)
        return configuration.devices?.first { Self.canonicalMAC($0.mac) == target }
    }

    /// Per-light settings win over the platform's, which win over what the light has, then the defaults.
    func settings(for device: KeyLightDevice, configuration deviceConfiguration: Configuration.Device?) async -> KeyLightSettings {
        let current = await device.settings
        let defaults = KeyLightDevice.defaultSettings
        let kelvin = deviceConfiguration?.powerOnTemperature ?? configuration.powerOnTemperature
        let behavior = deviceConfiguration?.powerOnBehavior.flatMap { $0 == 0 ? nil : $0 }
        return KeyLightSettings(
            powerOnBehavior: behavior ?? configuration.powerOnBehavior ?? current?.powerOnBehavior ?? defaults.powerOnBehavior,
            powerOnBrightness: deviceConfiguration?.powerOnBrightness ?? configuration.powerOnBrightness ?? current?.powerOnBrightness ?? defaults.powerOnBrightness,
            powerOnTemperature: kelvin.map(Self.mirek(kelvin:)) ?? current?.powerOnTemperature ?? defaults.powerOnTemperature,
            switchOnDurationMs: configuration.switchOnDurationMs ?? current?.switchOnDurationMs ?? defaults.switchOnDurationMs,
            switchOffDurationMs: configuration.switchOffDurationMs ?? current?.switchOffDurationMs ?? defaults.switchOffDurationMs,
            colorChangeDurationMs: configuration.colorChangeDurationMs ?? current?.colorChangeDurationMs ?? defaults.colorChangeDurationMs)
    }

    /// Kelvin to mirek, clamped to what the light accepts (2900 K is 345 mirek, one past the range).
    static func mirek(kelvin: Int) -> Int {
        guard kelvin > 0 else { return LightState.temperatureRange.lowerBound }
        return LightState.clamp(temperature: Int((1_000_000.0 / Double(kelvin)).rounded()))
    }

    /// Uppercase colon-separated octets (`3C:6A:9D:04:0A:0B`), whatever separators and leading zeros the
    /// input had, so a light is keyed the same from Bonjour and from config.json.
    static func canonicalMAC(_ mac: String) -> String {
        let trimmed = mac.trimmingCharacters(in: .whitespaces)
        let octets = trimmed.split(whereSeparator: { $0 == ":" || $0 == "-" }).map { String($0) }
        let digits: String
        if octets.count == 6, octets.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) {
            digits = octets.map { $0.count == 1 ? "0" + $0 : $0 }.joined()
        } else {
            digits = trimmed.filter { $0 != ":" && $0 != "-" && $0 != "." }
        }
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit) else { return trimmed.uppercased() }
        let characters = Array(digits.uppercased())
        return stride(from: 0, to: 12, by: 2).map { String(characters[$0..<$0 + 2]) }.joined(separator: ":")
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
