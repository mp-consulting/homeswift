import Foundation
import Homeswift
import HomeswiftNetwork
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
        /// `true` connects to the address Bonjour announced; otherwise to the light's host name, turned into an
        /// address through the ARP table, then the announced addresses (`HostResolution`).
        public var useIP: Bool?
        public var devices: [Device]?
    }

    /// A light announced over Bonjour or listed in config.json.
    struct DiscoveredLight: Sendable, Equatable {
        var name: String
        var mac: String
        /// An address, or a host name `HostResolution` turns into one before connecting.
        var host: String
        var port: Int
        /// The addresses Bonjour looked up for the light, IPv4 first.
        var addresses: [String] = []
        /// The model the Bonjour record names (`md`).
        var model: String?

        /// The light's entry in config.json, when it gives an address.
        init?(configured device: Configuration.Device, mac: String) {
            guard let host = device.ip ?? device.host, !host.isEmpty else { return nil }
            self.init(name: device.name ?? mac, mac: mac, host: host, port: device.port ?? KeyLightClient.defaultPort, addresses: device.ip.map { [$0] } ?? [])
        }

        init(name: String, mac: String, host: String, port: Int, addresses: [String] = [], model: String? = nil) {
            self.name = name
            self.mac = mac
            self.host = host
            self.port = port
            self.addresses = addresses
            self.model = model
        }
    }

    /// What the plugin uses to reach and find lights; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any KeyLightTransport = URLSessionTransport()
        var discover: @Sendable (Logger) -> AsyncStream<DiscoveredLight> = Discovery.browse
        /// The IPv4 address the ARP table has for a MAC.
        var arp: @Sendable (String) async -> String? = HostResolution.arpAddress(forMAC:)
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

    private enum Status: String { case initializing, ready, failed }
    private var devices: [String: KeyLightDevice] = [:]
    /// Each light's Adaptive Lighting, by MAC: kept here, as the lightbulb holds it only weakly.
    private var adaptiveLighting: [String: AdaptiveLightingController] = [:]
    private var status: [String: Status] = [:]
    /// Lights with an `ip` or `host` in config.json: announcements never move them.
    private var pinned: Set<String> = []
    /// Every light Bonjour announced, by MAC, for the page's list of lights on the network.
    private var announced: [String: DiscoveredLight] = [:]
    /// Where each light was last tried and why it failed, for the page's offline lights.
    private var attempts: [String: DiscoveredLight] = [:]
    private var failures: [String: String] = [:]
    private var discoveryTask: Task<Void, Never>?
    /// The connection in progress or last made to each light, by MAC: one per light, however often it is retried.
    private var initializations: [String: Task<Void, Never>] = [:]

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        await removeDisabledAccessories()
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
        for task in initializations.values { task.cancel() }
        initializations.removeAll()
        for device in devices.values {
            await device.stopPolling()
        }
        // Let go, not disabled: a running schedule stays saved and resumes at the next start.
        adaptiveLighting.removeAll()
        logger.debug("Stopped")
    }

    /// The light with this MAC, once it answered.
    func device(mac: String) -> KeyLightDevice? { devices[Self.canonicalMAC(mac)] }

    // MARK: The web page

    /// `GET lights` lists the lights with their state; `POST identify?mac=` flashes one; `GET probe?host=&port=`
    /// asks a light at an address who it is (adding one by address, testing a connection). `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "lights"):
            var lights: [JSONValue] = []
            for (mac, device) in devices.sorted(by: { $0.key < $1.key }) {
                let light = await device.snapshot
                lights.append([
                    "mac": .string(mac), "name": .string(light.name), "model": .string(light.model), "serial": .string(light.serial),
                    "firmware": .string(light.firmware), "host": .string(light.host), "port": .number(Double(light.port)),
                    "reachable": .bool(light.isReachable), "status": .string((status[mac] ?? .initializing).rawValue), "pinned": .bool(pinned.contains(mac)),
                    "on": .bool(light.state.on == 1), "brightness": light.state.brightness.map { .number(Double($0)) } ?? .null,
                    "temperature": light.state.temperature.map { .number(Double($0)) } ?? .null,
                ])
            }
            // Lights tried but not running (connecting, or they did not answer), and what Bonjour announces.
            var pending: [JSONValue] = []
            for (mac, light) in attempts.sorted(by: { $0.key < $1.key }) where devices[mac] == nil {
                pending.append([
                    "mac": .string(mac), "name": .string(light.name), "host": .string(light.host), "port": .number(Double(light.port)),
                    "status": .string((status[mac] ?? .initializing).rawValue), "pinned": .bool(pinned.contains(mac)),
                    "error": failures[mac].map { .string($0) } ?? .null,
                ])
            }
            let discovered: [JSONValue] = announced.sorted(by: { $0.key < $1.key }).map { mac, light in
                [
                    "mac": .string(mac), "name": .string(light.name), "model": light.model.map { .string($0) } ?? .null,
                    "host": .string(light.host), "address": light.addresses.first.map { .string($0) } ?? .null, "port": .number(Double(light.port)),
                    "running": .bool(devices[mac] != nil),
                ]
            }
            return PluginWebResponse(["lights": .array(lights), "pending": .array(pending), "discovered": .array(discovered)])
        case ("GET", "probe"):
            guard let host = request.query["host"]?.trimmingCharacters(in: .whitespaces), KeyLightClient.isValidHost(host) else { return .error(400, "a host name or IP address is required") }
            let port = request.query["port"].flatMap(Int.init) ?? KeyLightClient.defaultPort
            guard KeyLightClient.isValidPort(port) else { return .error(400, "the port must be between 1 and 65535") }
            let client = KeyLightClient(host: host, port: port, transport: dependencies.transport)
            let started = ContinuousClock.now
            let info: KeyLightInfo
            do {
                info = try await client.info()
            } catch {
                return .error(502, "No light answered at \(host):\(port): \(error)")
            }
            let elapsed = ContinuousClock.now - started
            // Older firmware leaves the MAC out of its answer; the ARP table has it, the light having just answered.
            var mac = info.macAddress.map(Self.canonicalMAC)
            if mac == nil { mac = await ARPTable.macAddress(for: host).map(Self.canonicalMAC) }
            var light: [String: JSONValue] = [
                "host": .string(host), "port": .number(Double(port)), "milliseconds": .number((elapsed / .milliseconds(1)).rounded()),
                "name": .string(info.displayName?.nonEmpty ?? info.productName ?? "Key Light"), "model": .string(info.productName ?? "Key Light"),
            ]
            if let mac { light["mac"] = .string(mac) }
            if let serial = info.serialNumber { light["serial"] = .string(serial) }
            if let firmware = info.firmwareVersion { light["firmware"] = .string(firmware) }
            return PluginWebResponse(["light": .object(light)])
        case ("POST", "identify"):
            guard let mac = request.query["mac"].map(Self.canonicalMAC), let device = devices[mac] else { return .error(404, "no light with that MAC") }
            await device.identify()
            return PluginWebResponse(["identified": .string(mac)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// Waits until every light found so far has been added or given up on. For tests.
    func settle() async {
        let pending = initializations.values
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
            guard let light = DiscoveredLight(configured: device, mac: mac) else {
                // Without an address the entry only names and tunes the light once Bonjour finds it.
                continue
            }
            guard KeyLightClient.isValidHost(light.host), KeyLightClient.isValidPort(light.port) else {
                logger.warning("Skipping light with an invalid address in config.json", metadata: ["light": "\(light.name)", "host": "\(light.host)", "port": "\(light.port)"])
                continue
            }
            logger.info("Registering configured light", metadata: ["light": "\(light.name)", "host": "\(light.host)"])
            pinned.insert(mac)
            initialize(light)
        }
    }

    /// The address config.json gives a light, for the ones registered from it.
    private func configuredLight(mac: String) -> DiscoveredLight? {
        deviceConfiguration(mac: mac).flatMap { DiscoveredLight(configured: $0, mac: mac) }
    }

    private func handleDiscovered(_ light: DiscoveredLight) {
        let mac = Self.canonicalMAC(light.mac)
        var light = light
        light.mac = mac
        announced[mac] = light
        // `useIP` connects to the announced address (IPv4 first), as the Homebridge plugin does.
        if configuration.useIP == true, let address = light.addresses.first(where: HostResolution.isIPv4) ?? light.addresses.first {
            light.host = address
        }
        switch status[mac] {
        case .ready:
            logger.debug("Light announced again", metadata: ["light": "\(light.name)", "host": "\(light.host)"])
            if pinned.contains(mac) { return }
            if let device = devices[mac] {
                let arp = dependencies.arp
                Task {
                    let host = await HostResolution.resolve(host: light.host, mac: mac, addresses: light.addresses, arp: arp)
                    await device.follow(host: host, port: light.port)
                }
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
        attempts[light.mac] = light
        failures[light.mac] = nil
        initializations[light.mac]?.cancel()
        initializations[light.mac] = Task { await self.connect(light) }
    }

    private func connect(_ light: DiscoveredLight) async {
        var light = light
        let resolved = await HostResolution.resolve(host: light.host, mac: light.mac, addresses: light.addresses, arp: dependencies.arp)
        if resolved != light.host {
            logger.info("Resolved \(light.host) to \(resolved) for \(light.name)")
            light.host = resolved
            attempts[light.mac] = light
        }
        guard KeyLightClient.isValidHost(light.host) else {
            logger.warning("Ignoring light with an invalid address", metadata: ["light": "\(light.name)", "host": "\(light.host)"])
            failures[light.mac] = "invalid address \(light.host)"
            status[light.mac] = .failed
            return
        }
        let interval = Duration.milliseconds(max(Self.minimumPollingRate, configuration.pollingRate ?? Self.defaultPollingRate))
        let client = KeyLightClient(host: light.host, port: light.port, transport: dependencies.transport)
        let device = KeyLightDevice(mac: light.mac, name: light.name, client: client, pollingInterval: interval, logger: logger)
        do {
            try await device.connect()
        } catch {
            logger.error("Could not reach \(light.name) at \(light.host):\(light.port), skipping: \(error)")
            failures[light.mac] = "\(error)"
            status[light.mac] = .failed
            return
        }
        guard !Task.isCancelled else { return }

        let deviceConfiguration = self.deviceConfiguration(mac: light.mac)
        let reportedName = await device.displayName
        let name = deviceConfiguration?.displayName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? reportedName
        await device.applySettings(settings(for: device, configuration: deviceConfiguration))

        let (accessory, adaptiveLighting) = await KeyLightAccessory.make(device: device, name: name, idPrefix: Self.platform, logger: logger)
        // Its schedule survives restarts; the controller lives as long as the light is on the bridge.
        context.configureController(adaptiveLighting, accessoryID: accessory.id)
        self.adaptiveLighting[light.mac] = adaptiveLighting
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(name) to the bridge: \(error)")
            self.adaptiveLighting[light.mac] = nil
            failures[light.mac] = "\(error)"
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
    private func removeDisabledAccessories() async {
        for device in configuration.devices ?? [] where device.enabled == false {
            let id = "\(Self.platform):\(Self.canonicalMAC(device.mac))"
            guard context.accessory(id: id) != nil else { continue }
            do {
                try await context.remove(id: id)
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
        // Kelvin, the light's own value when unset or 0 (a light's 0 does not fall back to the platform's).
        let kelvin = (deviceConfiguration?.powerOnTemperature ?? configuration.powerOnTemperature).flatMap { $0 > 0 ? $0 : nil }
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
        MACAddress.canonical(mac) ?? mac.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
