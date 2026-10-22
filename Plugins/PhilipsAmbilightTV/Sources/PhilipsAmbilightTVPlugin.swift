import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Philips Android TVs with Ambilight over their JointSpace API: power (with Wake-on-LAN), inputs (the
/// tuner, Home, HDMI, the apps the TV reports or the configured ones), the remote, volume and mute,
/// Ambilight as a colour lightbulb, and optional switches and sensors for scenes and automations.
///
/// Each TV is published as an accessory of its own, as Homebridge does: HomeKit allows one television per
/// bridge. The configuration is the one of `homebridge-philips-ambilight-tv`; pairing a TV happens on the
/// plugin's page in the web UI, or with the Homebridge plugin's settings page. See README.md.
public actor PhilipsAmbilightTVPlugin: HomeswiftPlugin {
    public static let platform = "PhilipsAmbilightTV"
    public static let name = "Philips Ambilight TV"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    static let discoveryServiceType = "_androidtvremote2._tcp"
    static let discoveryDuration: Duration = .seconds(5)
    static let pairingSessionLifetime: TimeInterval = 300

    /// What the plugin uses to reach TVs; tests swap them for a fake TV.
    struct Dependencies: Sendable {
        var transports: any JointSpaceTransportFactory = NetworkTransportFactory()
        var discover: @Sendable (Logger) async -> [DiscoveredTV] = Discovery.browse
        var lookUpARP: @Sendable (String) async -> String? = ARPTable.macAddress(for:)
    }

    struct DiscoveredTV: Sendable, Equatable {
        var name: String
        var host: String
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var logger: Logger { context.logger }
    private var devices: [String: TVDevice] = [:]
    private var pairings: [String: JointSpacePairing.Session] = [:]

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        var settings: [TVSettings] = []
        for (index, device) in (configuration.devices ?? []).enumerated() {
            do {
                let checked = try TVSettings(device)
                if settings.contains(where: { $0.mac == checked.mac }) {
                    logger.warning("Skipping TV \"\(checked.name)\": its MAC address is already used by another TV in the block")
                    continue
                }
                settings.append(checked)
            } catch {
                logger.error("Skipping TV \(device.name.map { "\"\($0)\"" } ?? "#\(index + 1)"): \(error)")
            }
        }
        await removeUnconfigured(keeping: settings.map(\.mac))
        for tv in settings {
            let device = TVDevice(settings: tv, storageDirectory: context.storageDirectory, transports: dependencies.transports, logger: logger)
            devices[tv.mac] = device
            await publish(device)
            await device.start()
            logger.info("Added TV", metadata: ["tv": "\(tv.name)", "ip": "\(tv.ip)"])
        }
    }

    public func stop() async {
        for device in devices.values { await device.stop() }
        logger.debug("Stopped")
    }

    func device(mac: String) -> TVDevice? { TVSettings.canonicalMAC(mac).flatMap { devices[$0] } }

    /// Builds the TV's accessory and publishes it on a server of its own; the device's changes flow into
    /// it, and a change of inputs rebuilds it.
    private func publish(_ device: TVDevice) async {
        let binding = await TVAccessory.make(device: device, idPrefix: Self.platform, logger: logger)
        let mac = device.settings.mac
        await device.setObserver { [weak self] change in
            binding.apply(change)
            if case .inputs = change {
                Task { [weak self] in await self?.republish(mac: mac) }
            }
        }
        // Changes between the build and the observer reached the previous accessory.
        await binding.sync(with: device)
        do {
            try await context.publishExternal(binding.accessory)
        } catch {
            logger.error("Could not publish \(binding.accessory.name): \(error)")
        }
    }

    private func republish(mac: String) async {
        guard let device = devices[mac] else { return }
        logger.debug("Inputs changed; rebuilding the accessory")
        await publish(device)
    }

    /// TVs taken out of the configuration leave HomeKit instead of lingering as unresponsive tiles.
    private func removeUnconfigured(keeping macs: [String]) async {
        let prefix = "\(Self.platform):"
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) && !macs.contains(String(accessory.id.dropFirst(prefix.count))) {
            do {
                try await context.remove(id: accessory.id)
                logger.info("Removed a TV that is no longer configured", metadata: ["tv": "\(accessory.name)"])
            } catch {
                logger.warning("Could not remove \(accessory.name): \(error)")
            }
        }
    }

    // MARK: The web page

    /// `GET tvs` lists the TVs with their state; `POST wake?mac=` sends Wake-on-LAN; `POST key` sends a
    /// remote key; `GET discover` looks for TVs over Bonjour; `POST pair` and `POST pair/grant` pair a TV
    /// and answer with the keys of its configuration block. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "tvs"):
            var tvs: [JSONValue] = []
            for (mac, device) in devices.sorted(by: { $0.key < $1.key }) {
                let tv = await device.snapshot
                tvs.append([
                    "mac": .string(mac), "name": .string(tv.name), "ip": .string(tv.ip), "on": .bool(tv.isOn), "reachable": .bool(tv.isReachable),
                    "muted": .bool(tv.muted), "ambilight": .bool(tv.ambilight.on), "ambilightStyle": tv.ambilight.style.map { .string($0) } ?? .null,
                    "currentApp": tv.currentApp.map { .string($0) } ?? .null, "currentInput": tv.currentInput.map { .string($0) } ?? .null,
                    "inputs": .number(Double(tv.inputs)), "longPoll": .string(tv.longPoll), "pinned": .bool(tv.pinned),
                ])
            }
            return PluginWebResponse(["tvs": .array(tvs)])
        case ("POST", "wake"):
            guard let mac = request.query["mac"], let device = device(mac: mac) else { return .error(404, "no TV with that MAC") }
            let settings = device.settings
            var addresses = ["255.255.255.255"]
            if let directed = WakeOnLAN.broadcastAddress(for: settings.ip) { addresses.append(directed) }
            do {
                try await WakeOnLAN.wake(mac: settings.mac, addresses: addresses)
            } catch {
                return .error(500, "\(error)")
            }
            return PluginWebResponse(["woke": .string(settings.mac)])
        case ("POST", "key"):
            guard let mac = request.body["mac"]?.stringValue, let device = device(mac: mac) else { return .error(404, "no TV with that MAC") }
            guard let key = RemoteKeys.valid(request.body["key"]?.stringValue) else { return .error(400, "unknown key") }
            do {
                try await device.sendKey(key)
            } catch {
                return .error(502, "the TV did not take the key")
            }
            return PluginWebResponse(["sent": .string(key)])
        case ("GET", "discover"):
            let found = await dependencies.discover(logger)
            return PluginWebResponse(["tvs": .array(found.map { ["name": .string($0.name), "host": .string($0.host)] })])
        case ("POST", "pair"):
            guard let ip = request.body["ip"]?.stringValue?.trimmingCharacters(in: .whitespaces), TVSettings.isIPv4(ip) else { return .error(400, "an IPv4 address is required") }
            let deviceName = request.body["name"]?.stringValue?.nonEmpty ?? "Homeswift"
            do {
                let session = try await JointSpacePairing.request(ip: ip, deviceName: deviceName, transport: dependencies.transports.makeTransport(tls: .any))
                pairings[ip] = session
                logger.info("Pairing started", metadata: ["ip": "\(ip)"])
                return PluginWebResponse(["message": "The TV shows a PIN: enter it to finish.", "certificateSeen": .bool(session.certificateFingerprint != nil)])
            } catch {
                logger.warning("Pairing request failed: \(error)")
                return .error(502, "Cannot reach the TV at \(ip): is it on, and on this network? (\(error))")
            }
        case ("POST", "pair/grant"):
            guard let ip = request.body["ip"]?.stringValue, let session = pairings[ip] else { return .error(400, "no pairing in progress for that address; start again") }
            guard Date().timeIntervalSince(session.startedAt) < Self.pairingSessionLifetime else {
                pairings[ip] = nil
                return .error(400, "the pairing expired; start again")
            }
            guard let pin = request.body["pin"]?.stringValue?.trimmingCharacters(in: .whitespaces), pin.count == 4, pin.allSatisfy(\.isNumber) else { return .error(400, "a 4-digit PIN is required") }
            let transport = dependencies.transports.makeTransport(tls: session.certificateFingerprint.map { .pinned($0) } ?? .any)
            do {
                let credentials = try await JointSpacePairing.grant(session, pin: pin, transport: transport)
                pairings[ip] = nil
                logger.info("Paired", metadata: ["ip": "\(ip)"])
                // The MAC address, for the block, from the TV itself when it tells.
                let mac = await lookUpMAC(ip: ip, credentials: credentials)
                var block: [String: JSONValue] = ["ip": .string(ip), "username": .string(credentials.username), "password": .string(credentials.password)]
                if let fingerprint = credentials.certFingerprint { block["certFingerprint"] = .string(fingerprint) }
                if let mac { block["mac"] = .string(mac) }
                return PluginWebResponse(["device": .object(block), "certificatePinned": .bool(credentials.certFingerprint != nil)])
            } catch let error as JointSpaceError {
                if case .certificateMismatch = error { pairings[ip] = nil }
                logger.warning("Pairing failed: \(error)")
                return .error(502, "\(error)")
            } catch {
                return .error(502, "\(error)")
            }
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// The TV's own `network/devices` first, preferring the interface that answers on `ip`; then this machine's
    /// ARP table, which has the TV since pairing just talked to it (what the Homebridge plugin reads).
    private func lookUpMAC(ip: String, credentials: JointSpacePairing.Credentials) async -> String? {
        let client = JointSpaceClient(ip: ip, username: credentials.username, password: credentials.password, certificateFingerprint: credentials.certFingerprint, transports: dependencies.transports, logger: logger)
        do {
            let devices = try await client.networkDevices().filter { $0.mac.flatMap(TVSettings.canonicalMAC) != nil }
            let wireless = devices.first { $0.type?.lowercased().contains("wifi") == true || $0.type?.lowercased().contains("wireless") == true }
            if let mac = (devices.first { $0.ip == ip } ?? wireless ?? devices.first)?.mac.flatMap(TVSettings.canonicalMAC) { return mac }
            logger.info("The TV lists no MAC address in network/devices; trying the ARP table", metadata: ["ip": "\(ip)"])
        } catch {
            logger.info("The TV did not give its MAC address (\(error)); trying the ARP table", metadata: ["ip": "\(ip)"])
        }
        if let mac = await dependencies.lookUpARP(ip).flatMap(TVSettings.canonicalMAC) { return mac }
        logger.warning("No MAC address for the TV in the ARP table either; the TV's network settings show it", metadata: ["ip": "\(ip)"])
        return nil
    }
}

/// Finds Android TVs over Bonjour: the remote service they announce.
enum Discovery {
    @Sendable static func browse(logger: Logger) async -> [PhilipsAmbilightTVPlugin.DiscoveredTV] {
        let deadline = ContinuousClock.now + PhilipsAmbilightTVPlugin.discoveryDuration
        let task = Task { () -> [String: PhilipsAmbilightTVPlugin.DiscoveredTV] in
            var found: [String: PhilipsAmbilightTVPlugin.DiscoveredTV] = [:]
            for await event in BonjourBrowser.browse(type: PhilipsAmbilightTVPlugin.discoveryServiceType, logger: logger) {
                guard case .found(let service) = event else { continue }
                var hostName = service.hostName
                if hostName.hasSuffix(".") { hostName.removeLast() }
                let host = service.addresses.first { !$0.contains(":") } ?? service.addresses.first ?? hostName
                found[service.name] = PhilipsAmbilightTVPlugin.DiscoveredTV(name: service.name, host: host)
            }
            return found
        }
        try? await Task.sleep(until: deadline)
        task.cancel()
        return await task.value.values.sorted { $0.name < $1.name }
    }
}
