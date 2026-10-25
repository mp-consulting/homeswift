import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The Home app's accessories in Homeswift, through Homeswift Wingman: a menu bar app on a Mac that reads Apple Home
/// with HomeKit and serves it over TLS to the bridges paired with it (github.com/mp-consulting/homeswift-wingman).
///
/// Each paired Wingman is an entry of `devices` (its id, address, token and certificate fingerprint), which the
/// plugin's page writes after pairing. The plugin reads the homes (`GET /homes`), follows value changes with a
/// long-poll (`GET /events?since=&wait=`) and writes through `POST /write`. Its accessories are mirrored
/// (`Accessory.mirroredFrom`): on the web UI's wall, in moods, scenes, automations and the MCP tools, but never
/// published to HomeKit, which has them already. Homeswift's own accessories, which Apple Home lists too, are left
/// out. See README.md.
public actor WingmanPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            /// Wingman's id (its Bonjour TXT `id`), which keys the entry.
            public var id: String
            public var name: String?
            /// Its address; Bonjour moves it when Wingman announces another.
            public var host: String?
            public var port: Int?
            /// The token pairing gave, sent as `Authorization: Bearer`.
            public var token: String?
            /// Wingman's certificate SHA-256, pinned.
            public var fingerprint: String?
        }

        public var name: String?
        public var devices: [Device]?
        /// Only these homes, by name; all of them without it.
        public var homes: [String]?
        /// Accessories left out, by name or HomeKit id.
        public var exclude: [String]?
        /// Bridges whose accessories are left out, by name, besides those made by Homeswift.
        public var excludeBridges: [String]?
        /// Minutes between two reads of the whole home (names, rooms, new accessories); 10 by default.
        public var refreshMinutes: Int?
    }

    public static let platform = "Wingman"
    public static let name = "Wingman"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    static let serviceType = "_homeswift-wingman._tcp"
    static let defaultPort = 8619
    static let discoveryDuration: Duration = .seconds(4)
    static let eventWait = 25

    /// What the plugin uses to reach Wingman; tests swap them for a fake.
    struct Dependencies: Sendable {
        var transports: any WingmanTransportFactory = NetworkTransportFactory()
        var browse: @Sendable (Logger) -> AsyncStream<BonjourBrowser.Event> = { BonjourBrowser.browse(type: WingmanPlugin.serviceType, logger: $0) }
        var retry = Backoff(initial: .seconds(2), maximum: .seconds(60), jitter: .proportional(0.2))
        /// The name a bridge pairs under, shown in Wingman's Paired Bridges.
        var bridgeName: String = "Homeswift on \(ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this machine")"
    }

    /// A Wingman Bonjour announces.
    struct Announced: Sendable, Equatable {
        var id: String
        var name: String
        var host: String
        var port: Int
        var home: String?
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var links: [String: Link] = [:]
    private var announced: [String: Announced] = [:]
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        for device in configuration.devices ?? [] {
            guard let token = device.token, !token.isEmpty else {
                logger.warning("A Wingman in devices has no token: pair it on the plugin's page", metadata: ["wingman": "\(device.name ?? device.id)"])
                continue
            }
            let link = Link(device: device, token: token, plugin: self)
            links[device.id] = link
            tasks.add { await link.run() }
        }
        if links.isEmpty { logger.info("No Wingman paired yet: the plugin's page finds them on the network and pairs them") }
        // Bonjour, all the time: a Wingman whose address changed is reached at the new one.
        let browse = dependencies.browse
        let logger = self.logger
        tasks.add { [weak self] in
            for await event in browse(logger) {
                guard case .found(let service) = event, let self else { continue }
                await self.announce(service)
            }
        }
        // With no Wingman paired, the accessories a previous one left in the cache go.
        if links.isEmpty { _ = await context.removeAccessories(keeping: [], message: "Removing an Apple Home accessory of a Wingman no longer paired") }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    // MARK: Bonjour

    private func announce(_ service: BonjourService) async {
        guard let id = service.txt["id"], !id.isEmpty else { return }
        let host = service.addresses.first { !$0.contains(":") } ?? service.addresses.first ?? service.hostName
        let found = Announced(id: id, name: service.name, host: host, port: service.port, home: service.txt["home"])
        guard announced[id] != found else { return }
        announced[id] = found
        await links[id]?.moved(to: found.host, port: found.port)
    }

    /// The Wingmen announced now, from the browse that runs all the time, after a moment for a page that just opened.
    func discovered() async -> [Announced] {
        if announced.isEmpty { try? await Task.sleep(for: Self.discoveryDuration) }
        return announced.values.sorted { $0.name < $1.name }
    }

    // MARK: Accessories

    /// Whether an Apple Home accessory comes to Homeswift: not Homeswift's own, not excluded, in a chosen home.
    func includes(_ accessory: WingmanAPI.Accessory, home: WingmanAPI.Home) -> Bool {
        if let homes = configuration.homes, !homes.isEmpty, !homes.contains(where: { $0.caseInsensitiveCompare(home.name) == .orderedSame }) { return false }
        if let exclude = configuration.exclude, exclude.contains(where: { $0 == accessory.id || $0.caseInsensitiveCompare(accessory.name) == .orderedSame }) {
            return false
        }
        if let bridge = accessory.bridge {
            if bridge.manufacturer == "Homeswift" || bridge.model == "Homeswift" { return false }
            if let names = configuration.excludeBridges, names.contains(where: { $0.caseInsensitiveCompare(bridge.name) == .orderedSame }) { return false }
        }
        return true
    }

    func publish(_ accessory: Accessory) {
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(accessory.name): \(error)")
        }
    }

    /// Drops the accessories Apple Home no longer has, once every paired Wingman has read its homes: before, an
    /// accessory of one still connecting would go.
    func prune() async {
        var keep: Set<String> = []
        for link in links.values {
            guard let ids = await link.loadedIDs else { return }
            keep.formUnion(ids)
        }
        _ = await context.removeAccessories(keeping: keep, message: "Removing an accessory Apple Home no longer has")
    }

    nonisolated var log: Logger { context.logger }
    nonisolated var transports: any WingmanTransportFactory { dependencies.transports }
    nonisolated var retry: Backoff { dependencies.retry }
    nonisolated var refreshInterval: Duration { .seconds(60 * max(configuration.refreshMinutes ?? 10, 1)) }

    // MARK: The web page

    /// A Wingman as the page lists it, asked who it is: its version, whether pairing is open, and its certificate as
    /// this machine sees it, to compare with Wingman's menu before typing the code.
    private func describe(_ wingman: Announced) async -> JSONValue {
        let configured = Set((configuration.devices ?? []).map(\.id))
        var entry: [String: JSONValue] = [
            "id": .string(wingman.id), "name": .string(wingman.name), "host": .string(wingman.host), "port": .number(Double(wingman.port)),
            "paired": .bool(configured.contains(wingman.id)),
        ]
        if let home = wingman.home { entry["home"] = .string(home) }
        let client = WingmanClient(host: wingman.host, port: wingman.port, token: nil, fingerprint: nil, transports: transports)
        do {
            let (info, fingerprint) = try await client.info()
            entry["id"] = .string(info.id)
            entry["paired"] = .bool(configured.contains(info.id))
            entry["version"] = info.version.map(JSONValue.string) ?? .null
            entry["pairing"] = .bool(info.pairing ?? false)
            entry["fingerprint"] = fingerprint.map(JSONValue.string) ?? .null
        } catch {
            entry["error"] = .string("\(error)")
        }
        return .object(entry)
    }

    /// `GET wingmen` the paired Wingmen and how they are doing; `GET discover` those Bonjour finds, each asked who it
    /// is (`/info`, its certificate seen); `POST pair` pairs one with the code its menu shows and answers its entry
    /// for `devices`, the certificate pinned. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "wingmen"):
            var list: [JSONValue] = []
            for device in configuration.devices ?? [] {
                if let link = links[device.id] {
                    list.append(await link.status())
                } else {
                    list.append(["id": .string(device.id), "name": .string(device.name ?? device.id), "state": "unpaired",
                                 "error": "No token: pair it again"])
                }
            }
            return PluginWebResponse(["wingmen": .array(list)])
        case ("GET", "discover"):
            var found: [JSONValue] = []
            for wingman in await discovered() { found.append(await describe(wingman)) }
            return PluginWebResponse(["wingmen": .array(found)])
        case ("GET", "probe"):
            // A Wingman Bonjour does not reach (another network, a container without multicast), by its address.
            guard let host = request.query["host"]?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return .error(400, "an address is required") }
            let port = request.query["port"].flatMap(Int.init) ?? Self.defaultPort
            let wingman = await describe(Announced(id: "", name: host, host: host, port: port, home: nil))
            if let error = wingman["error"]?.stringValue { return .error(502, error) }
            return PluginWebResponse(["wingman": wingman])
        case ("POST", "pair"):
            guard let host = request.body["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return .error(400, "an address is required") }
            let port = request.body["port"]?.saturatingIntValue ?? Self.defaultPort
            guard let code = request.body["code"]?.stringValue?.filter(\.isNumber), code.count == 6 else { return .error(400, "the 6-digit code Wingman shows is required") }
            // The certificate the user compared with Wingman's menu, pinned for the pairing itself.
            guard let fingerprint = request.body["fingerprint"]?.stringValue.map(HTTPClient.normalizeFingerprint), fingerprint.count == 64 else {
                return .error(400, "the certificate fingerprint seen at discovery is required")
            }
            let client = WingmanClient(host: host, port: port, token: nil, fingerprint: fingerprint, transports: transports)
            do {
                let paired = try await client.pair(code: code, name: dependencies.bridgeName)
                let (info, _) = try await client.info()
                logger.info("Paired with Wingman", metadata: ["host": "\(host)"])
                var entry: [String: JSONValue] = [
                    "id": .string(paired.wingman ?? info.id), "host": .string(host), "token": .string(paired.token), "fingerprint": .string(fingerprint),
                ]
                if port != Self.defaultPort { entry["port"] = .number(Double(port)) }
                if let name = request.body["name"]?.stringValue, !name.isEmpty { entry["name"] = .string(name) }
                return PluginWebResponse(["device": .object(entry)])
            } catch let error as WingmanError {
                logger.warning("Pairing with Wingman failed: \(error)", metadata: ["host": "\(host)"])
                if case .refused(let status, let message) = error { return .error(status == 403 ? 403 : 502, message) }
                return .error(502, "\(error)")
            }
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }
}

/// One paired Wingman: reads its homes, mirrors their accessories, follows their changes and carries the writes.
actor Link {
    private var device: WingmanPlugin.Configuration.Device
    private let token: String
    /// Weak: the plugin owns its links, and a pairing reloads it.
    private weak var plugin: WingmanPlugin?
    private let logger: Logger
    private let transports: any WingmanTransportFactory
    private let retry: Backoff
    private let refreshInterval: Duration
    private var client: WingmanClient
    private var loaded = false
    private var mirrors: [String: Mirror] = [:]
    private var since = 0
    private var state = "connecting"
    private var lastError: String?
    private var lastContact: Date?
    private var homeNames: [String] = []
    private var skipped = 0

    init(device: WingmanPlugin.Configuration.Device, token: String, plugin: WingmanPlugin) {
        self.device = device
        self.token = token
        self.plugin = plugin
        logger = plugin.log
        transports = plugin.transports
        retry = plugin.retry
        refreshInterval = plugin.refreshInterval
        client = WingmanClient(
            host: device.host ?? "", port: device.port ?? WingmanPlugin.defaultPort, token: token, fingerprint: device.fingerprint,
            transports: plugin.transports)
    }

    /// The accessories of the last read of the homes; nil before the first.
    var loadedIDs: Set<String>? { loaded ? Set(mirrors.values.map(\.accessory.id)) : nil }
    private var name: String { device.name ?? device.id }

    /// Bonjour announced Wingman at another address: the next request goes there.
    func moved(to host: String, port: Int) {
        guard host != client.host || port != client.port else { return }
        logger.info("Wingman moved", metadata: ["wingman": "\(name)", "host": "\(host)"])
        client = WingmanClient(host: host, port: port, token: token, fingerprint: device.fingerprint, transports: transports)
    }

    func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await refresh()
                failures = 0
                var nextRefresh = ContinuousClock.now + refreshInterval
                while !Task.isCancelled, ContinuousClock.now < nextRefresh {
                    if try await follow() { nextRefresh = .now }
                }
            } catch {
                guard !Task.isCancelled else { return }
                lost(error)
                if case WingmanError.unauthorized = error { return }
                try? await Task.sleep(for: retry.delay(attempt: failures))
                failures += 1
            }
        }
    }

    /// Reads the homes and (re)builds the accessories.
    private func refresh() async throws {
        guard !client.host.isEmpty else { throw WingmanError.unreachable("no address yet: waiting for Bonjour") }
        let homes = try await client.homes()
        // Changes from now on: the events after this read.
        since = try await client.events(since: Int.max - 1, wait: 0).last ?? 0
        var built: [String: Mirror] = [:]
        var left = 0
        guard let plugin else { return }
        let write: @Sendable (String, String, JSONValue) async throws -> Void = { [weak self] accessoryID, characteristicID, value in
            guard let self else { throw WingmanError.unreachable("stopped") }
            try await self.write(accessory: accessoryID, characteristic: characteristicID, value: value)
        }
        for home in homes {
            for accessory in home.accessories {
                guard await plugin.includes(accessory, home: home) else {
                    left += 1
                    continue
                }
                guard let mirror = Mirror(accessory, platform: WingmanPlugin.platform, write: write) else { continue }
                built[accessory.id] = mirror
            }
        }
        // The status first: whoever sees the accessories sees the state they came with.
        if state != "connected" {
            logger.info("Mirroring Apple Home through Wingman", metadata: ["wingman": "\(name)", "accessories": "\(built.count)", "left out": "\(left)"])
        }
        mirrors = built
        loaded = true
        homeNames = homes.map(\.name)
        skipped = left
        state = "connected"
        lastError = nil
        lastContact = Date()
        for mirror in built.values { await plugin.publish(mirror.accessory) }
        await plugin.prune()
    }

    /// Waits for value changes and applies them. Answers whether the homes must be read again (Wingman restarted, or
    /// a change names a characteristic not seen yet).
    private func follow() async throws -> Bool {
        let answer = try await client.events(since: since, wait: WingmanPlugin.eventWait)
        lastContact = Date()
        if let last = answer.last, last < since { return true }
        var unknown = false
        for event in answer.events {
            if let seq = event.seq { since = max(since, seq) }
            guard let accessoryID = event.accessoryID, let characteristicID = event.characteristicID else { continue }
            guard let mirror = mirrors[accessoryID] else { continue }
            guard let characteristic = mirror.characteristics[characteristicID] else {
                unknown = true
                continue
            }
            Mirror.apply(event.value, to: characteristic)
            if mirror.accessory.isUnavailable { mirror.accessory.isUnavailable = false }
        }
        if let last = answer.last { since = max(since, last) }
        return unknown
    }

    private func write(accessory: String, characteristic: String, value: JSONValue) async throws {
        try await client.write(accessory: accessory, characteristic: characteristic, value: value)
    }

    private func lost(_ error: any Error) {
        let message = "\(error)"
        if lastError != message {
            logger.warning("Wingman: \(message)", metadata: ["wingman": "\(name)"])
        }
        if case WingmanError.unauthorized = error { state = "unpaired" } else { state = "unreachable" }
        lastError = message
    }

    func status() -> JSONValue {
        var json: [String: JSONValue] = [
            "id": .string(device.id), "name": .string(name), "host": .string(client.host), "port": .number(Double(client.port)), "state": .string(state),
            "accessories": .number(Double(mirrors.count)), "notResponding": .number(Double(mirrors.values.filter(\.accessory.isUnavailable).count)),
            "leftOut": .number(Double(skipped)), "homes": .array(homeNames.map(JSONValue.string)), "pinned": .bool(device.fingerprint != nil),
        ]
        if let lastError { json["error"] = .string(lastError) }
        if let lastContact { json["lastContact"] = .string(ISO8601DateFormatter().string(from: lastContact)) }
        return .object(json)
    }
}
