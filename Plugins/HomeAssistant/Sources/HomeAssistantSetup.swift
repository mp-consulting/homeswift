import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// Setup (GLOSSARY.md, "Setup"; docs/clean-room/HomeAssistant.md, sections 3 and 8): the instance's account is one Home
// Assistant server, authorized with an API Key (a long-lived access token). Setup lists the servers mDNS announces
// (`_home-assistant._tcp`) for the person to confirm, since anyone on the network can announce one, or takes an address,
// then checks the token with `get_states`. The token goes in the vault (the account's credentials), the address and the
// server's uuid in the block. The server's devices are then the instance's devices, each entity a Part a person may
// leave out (Accessory Settings' `parts`, by the entity's registry id); a whole device is Excluded as any other.
extension HomeAssistantPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    public func accountAuthorized() async -> Bool? {
        settings.url != nil && accessToken != nil
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if snapshotLoaded { return makePlan().devices.first { $0.deviceID == deviceID }?.kind }
        return nil
    }

    /// The server's devices: from the running instance's view, else read once now (an instance made only for Setup).
    public func discover() async throws -> [DiscoveredDevice] {
        guard let url = settings.url, let token = accessToken else { return [] }
        if !snapshotLoaded {
            do {
                let probe = try await Self.probe(url: url, token: token, dependencies: dependencies, verifyTLS: settings.verifyTLS)
                (config, states, entities, devices, areas, registriesAvailable) = (probe.config, probe.states, probe.entities, probe.devices, probe.areas, probe.registries)
                snapshotLoaded = true
            } catch {
                throw SetupError("Home Assistant did not answer: \(error)")
            }
        }
        let address = HomeAssistantURL.base(url)?.host
        return makePlan().devices.map { device in
            var discovered = DiscoveredDevice(deviceID: device.deviceID, name: device.name, model: device.model, address: address, isSetUp: true, kind: device.kind)
            discovered.parts = device.parts
            if let item = built[Self.accessoryID(deviceID: device.deviceID)] { discovered.isReachable = !item.accessory.isUnavailable }
            return discovered
        }
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Home Assistant's devices come with the server: they need no setup of their own")
        let found: [Announcement]
        if let kept = request.state["servers"]?.arrayValue {
            found = kept.compactMap { item in
                guard let url = item["url"]?.stringValue, let name = item["name"]?.stringValue else { return nil }
                return Announcement(name: name, uuid: item["uuid"]?.stringValue, url: url, version: item["version"]?.stringValue)
            }
        } else {
            found = await dependencies.browse(.seconds(3))
        }
        let state: JSONValue = ["servers": .array(found.map {
            ["name": .string($0.name), "url": .string($0.url), "uuid": $0.uuid.map(JSONValue.string) ?? .null, "version": $0.version.map(JSONValue.string) ?? .null]
        })]
        var fields: [SetupField] = []
        if !found.isEmpty {
            fields.append(.choice("server", label: "Server", options: found.map { SetupOption($0.url, label: $0.name, detail: $0.url) }, value: found.first?.url, optional: true))
        }
        fields.append(SetupField("url", label: "Address", optional: !found.isEmpty, value: found.isEmpty ? settings.url : nil))
        fields.append(SetupField("accessToken", label: "Long-lived access token", kind: .secret))
        let prompt = SetupPrompt(
            message: found.isEmpty
                ? "Enter the address of Home Assistant (http://homeassistant.local:8123) and a long-lived access token, made in Home Assistant under your profile, Security."
                : "Choose your Home Assistant server, or enter its address, and a long-lived access token, made in Home Assistant under your profile, Security.",
            fields: fields)
        if request.isFirst { return .ask(prompt, state: state) }
        let chosen = request.choice("server", among: found.map(\.url))
        guard let address = request.answer("url") ?? chosen, let base = HomeAssistantURL.base(address) else {
            return .ask(prompt, state: state)
        }
        guard let token = request.secret("accessToken") else { return .ask(prompt, state: state) }
        let url = base.absoluteString
        let probe: Probe
        do {
            probe = try await Self.probe(url: url, token: token, dependencies: dependencies, verifyTLS: settings.verifyTLS)
        } catch HomeAssistantError.authInvalid {
            logger.info("Home Assistant at \(url) refused the access token given through Setup")
            throw SetupError("Home Assistant refused this access token: make a new long-lived access token and paste it whole.")
        } catch {
            throw SetupError("Home Assistant did not answer at \(url): \(error)")
        }
        logger.info("Set up Home Assistant \(probe.config.version ?? "") at \(url): \(probe.states.count) entities")
        let uuid = found.first { $0.url == address || $0.url == url }?.uuid
        var settings: [String: JSONValue] = ["url": .string(url), "accessToken": .null]
        if let uuid { settings["serverId"] = .string(uuid) }
        return .done(try SetupOutcome(encoding: Credentials(accessToken: token), settings: settings))
    }

    /// What one connection reads: the token checked with `get_states` (Setup), the devices listed (discovery).
    struct Probe: Sendable {
        var config: ServerConfig
        var states: [String: EntityState]
        var entities: [String: EntityEntry]
        var devices: [String: DeviceEntry]
        var areas: [String: String]
        var registries: Bool
    }

    static func probe(url: String, token: String, dependencies: Dependencies, verifyTLS: Bool) async throws -> Probe {
        guard let webSocket = HomeAssistantURL.webSocket(url) else { throw HomeAssistantError.invalidURL(url) }
        var options = WebSocket.Options(timeout: .seconds(10))
        if !verifyTLS { options.tls = TLSOptions(trust: .any) }
        let socket = try await dependencies.connect(webSocket, options)
        let session = HomeAssistantSession(socket: socket)
        await session.start { _ in }
        do {
            try await session.authenticate(token: token, timeout: dependencies.authTimeout)
            let timeout = dependencies.commandTimeout
            let config = ServerConfig(try await session.command(["type": "get_config"], timeout: timeout))
            var probe = Probe(config: config, states: [:], entities: [:], devices: [:], areas: [:], registries: false)
            if let list = try? await session.command(["type": "config/entity_registry/list"], timeout: timeout),
               let deviceList = try? await session.command(["type": "config/device_registry/list"], timeout: timeout) {
                probe.registries = true
                probe.entities = Dictionary((list.arrayValue ?? []).compactMap(EntityEntry.init).map { ($0.entityID, $0) }) { first, _ in first }
                probe.devices = Dictionary((deviceList.arrayValue ?? []).compactMap(DeviceEntry.init).map { ($0.id, $0) }) { first, _ in first }
                for area in (try? await session.command(["type": "config/area_registry/list"], timeout: timeout))?.arrayValue ?? [] {
                    if let id = area["area_id"]?.stringValue, let name = area["name"]?.stringValue { probe.areas[id] = name }
                }
            }
            let states = try await session.command(["type": "get_states"], timeout: timeout)
            for item in states.arrayValue ?? [] { if let state = EntityState(item) { probe.states[state.entityID] = state } }
            await session.close()
            return probe
        } catch {
            await session.close()
            throw error
        }
    }

    /// The servers mDNS announces within `window` (section 3): their `internal_url`, else the SRV address and port.
    static func browse(for window: Duration) async -> [Announcement] {
        let events = BonjourBrowser.browse(type: serviceType, logger: Logger(label: "homeswift.HomeAssistant"))
        var found: [String: Announcement] = [:]
        for event in await events.collect(for: window) {
            guard case .found(let service) = event else { continue }
            let internalURL = service.txt["internal_url"].flatMap { HomeAssistantURL.base($0) }?.absoluteString
            var host = service.addresses.first { $0.contains(".") } ?? service.hostName
            if host.hasSuffix(".") { host.removeLast() }
            let url = internalURL ?? "http://\(host):\(service.port)"
            let name = sanitized(service.txt["location_name"]?.nonEmpty ?? service.name)
            let uuid = service.txt["uuid"]?.nonEmpty
            found[uuid ?? url] = Announcement(name: name, uuid: uuid, url: url, version: service.txt["version"])
        }
        return found.values.sorted { $0.name < $1.name }
    }
}
