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

    public static let icon: String? = "wingman"
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
        /// The least time between two reads of the homes that events ask for.
        var rereadGap: Duration = .seconds(10)
        /// The name a bridge pairs under, shown in Wingman's Paired Bridges.
        var bridgeName: String = "Homeswift on \(ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this machine")"
    }

    /// A Wingman Bonjour announces.
    struct Announced: Sendable, Equatable {
        var id: String
        var name: String
        var host: String
        var port: Int
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private(set) var links: [String: Link] = [:]
    private(set) var announced: [String: Announced] = [:]
    nonisolated var logger: Logger { context.logger }
    nonisolated var refreshInterval: Duration { .seconds(60 * max(configuration.refreshMinutes ?? 10, 1)) }

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
            // The token goes only to the certificate pairing pinned: never over a connection that accepts any.
            guard let token = device.token, !token.isEmpty, device.fingerprint?.isEmpty == false else {
                logger.warning("A Wingman in devices has no token or no pinned certificate: pair it on the plugin's page", metadata: ["wingman": "\(device.name ?? device.id)"])
                continue
            }
            let link = Link(device: device, token: token, plugin: self)
            links[device.id] = link
            tasks.add { await link.run() }
        }
        if links.isEmpty { logger.info("No Wingman paired yet: the plugin's page finds them on the network and pairs them") }
        // Bonjour, all the time: a Wingman whose address changed is reached at the new one, one that left is forgotten.
        let browse = dependencies.browse
        let logger = self.logger
        tasks.add { [weak self] in
            for await event in browse(logger) {
                guard let self else { return }
                await self.announced(event)
            }
        }
        // With no Wingman paired, the accessories a previous one left in the cache go.
        if links.isEmpty { _ = await context.removeAccessories(keeping: [], message: "Removing an Apple Home accessory of a Wingman no longer paired") }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    // MARK: Bonjour

    private func announced(_ event: BonjourBrowser.Event) async {
        switch event {
        case .found(let service):
            guard let id = service.txt["id"], !id.isEmpty else { return }
            let found = Announced(id: id, name: service.name, host: service.preferredAddress, port: service.port)
            guard announced[id] != found else { return }
            announced[id] = found
            await links[id]?.moved(to: found.host, port: found.port)
        case .lost(let name, _, _):
            announced = announced.filter { $0.value.name != name }
        }
    }

    /// The Wingmen announced now, from the browse that runs all the time, after a moment for a page that just opened.
    func discovered() async -> [Announced] {
        if announced.isEmpty { try? await Task.sleep(for: Self.discoveryDuration) }
        return announced.values.sorted { $0.name < $1.name }
    }

    // MARK: Accessories

    /// Whether an Apple Home accessory comes to Homeswift: not Homeswift's own (on its bridges, or published on its own
    /// like a TV or a camera, by serial number: `homeswift` is `context.publishedSerialNumbers`), not excluded, in a
    /// chosen home.
    nonisolated func includes(_ accessory: WingmanAPI.Accessory, home: WingmanAPI.Home, homeswift: Set<String>) -> Bool {
        if let serial = accessory.serialNumber, homeswift.contains(serial) { return false }
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

    nonisolated func publish(_ accessory: Accessory) {
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

    // MARK: The web page

    /// A Wingman as the page lists it, asked who it is: its version, whether pairing is open, and its certificate as
    /// this machine sees it, to compare with Wingman's menu before typing the code.
    private nonisolated func describe(_ wingman: Announced) async -> JSONValue {
        let client = WingmanClient(host: wingman.host, port: wingman.port, token: nil, fingerprint: nil, transports: dependencies.transports)
        var entry: [String: JSONValue] = ["name": .string(wingman.name), "host": .string(wingman.host), "port": .number(Double(wingman.port))]
        var id = wingman.id
        do {
            let (info, fingerprint) = try await client.info()
            id = info.id
            entry["version"] = info.version.map(JSONValue.string) ?? .null
            entry["pairing"] = .bool(info.pairing ?? false)
            entry["fingerprint"] = fingerprint.map(JSONValue.string) ?? .null
        } catch {
            entry["error"] = .string("\(error)")
        }
        entry["id"] = .string(id)
        entry["paired"] = .bool(configuration.devices?.contains { $0.id == id } == true)
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
                                 "error": "No token or no pinned certificate: pair it again"])
                }
            }
            return PluginWebResponse(["wingmen": .array(list)])
        case ("GET", "discover"):
            // Asked all at once: one that does not answer costs its timeout, not everyone's.
            let wingmen = await discovered()
            let found = await withTaskGroup(of: (Int, JSONValue).self) { group in
                for (index, wingman) in wingmen.enumerated() { group.addTask { (index, await self.describe(wingman)) } }
                var found: [(Int, JSONValue)] = []
                for await answer in group { found.append(answer) }
                return found.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return PluginWebResponse(["wingmen": .array(found)])
        case ("GET", "probe"):
            // A Wingman Bonjour does not reach (another network, a container without multicast), by its address.
            guard let host = request.query["host"]?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return .error(400, "an address is required") }
            let port = request.query["port"].flatMap(Int.init) ?? Self.defaultPort
            let wingman = await describe(Announced(id: "", name: host, host: host, port: port))
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
            let client = WingmanClient(host: host, port: port, token: nil, fingerprint: fingerprint, transports: dependencies.transports)
            do {
                let paired = try await client.pair(code: code, name: dependencies.bridgeName)
                var id = paired.wingman
                if id == nil { id = try await client.info().info.id }
                logger.info("Paired with Wingman", metadata: ["host": "\(host)"])
                var entry: [String: JSONValue] = ["id": .string(id ?? ""), "host": .string(host), "token": .string(paired.token), "fingerprint": .string(fingerprint)]
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
    private enum Phase: Equatable {
        case connecting, connected
        case unreachable(String), unpaired(String)
    }

    /// What the last read of the homes gave.
    private struct Snapshot {
        var mirrors: [String: Mirror]
        var homes: [String]
        var leftOut: Int
    }

    private let device: WingmanPlugin.Configuration.Device
    private let token: String
    /// Weak: the plugin owns its links, and a pairing reloads it.
    private weak var plugin: WingmanPlugin?
    private let logger: Logger
    private let dependencies: WingmanPlugin.Dependencies
    private let refreshInterval: Duration
    private var client: WingmanClient
    private var snapshot: Snapshot?
    private var since = 0
    private var phase = Phase.connecting
    private var lastContact: Date?

    init(device: WingmanPlugin.Configuration.Device, token: String, plugin: WingmanPlugin) {
        self.device = device
        self.token = token
        self.plugin = plugin
        logger = plugin.logger
        dependencies = plugin.dependencies
        refreshInterval = plugin.refreshInterval
        client = WingmanClient(
            host: device.host ?? "", port: device.port ?? WingmanPlugin.defaultPort, token: token, fingerprint: device.fingerprint,
            transports: plugin.dependencies.transports)
    }

    /// The accessories of the last read of the homes; nil before the first.
    var loadedIDs: Set<String>? { snapshot.map { Set($0.mirrors.values.map(\.accessory.id)) } }
    private var name: String { device.name ?? device.id }

    /// Bonjour announced Wingman at another address: the next request goes there.
    func moved(to host: String, port: Int) {
        guard host != client.host || port != client.port else { return }
        logger.info("Wingman moved", metadata: ["wingman": "\(name)", "host": "\(host)"])
        client = WingmanClient(host: host, port: port, token: token, fingerprint: device.fingerprint, transports: dependencies.transports)
    }

    func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let readAt = ContinuousClock.now
                try await refresh()
                failures = 0
                var nextRefresh = readAt + refreshInterval
                while !Task.isCancelled, ContinuousClock.now < nextRefresh {
                    guard try await follow() else { continue }
                    // A burst of "homes" events, or Apple Home changing in answer to a read (nothing does: mirrors
                    // stay out of HomeKit and Matter), reads the homes once per gap, not back to back.
                    try? await Task.sleep(until: readAt + dependencies.rereadGap, clock: .continuous)
                    nextRefresh = .now
                }
            } catch {
                guard !Task.isCancelled else { return }
                lost(error)
                if case WingmanError.unauthorized = error { return }
                try? await Task.sleep(for: dependencies.retry.delay(attempt: failures))
                failures += 1
            }
        }
    }

    /// Reads the homes. An accessory whose shape is as it was keeps its objects and takes the new values; the others
    /// are built again and replace theirs.
    func refresh() async throws {
        guard !client.host.isEmpty else { throw WingmanError.unreachable("no address yet: waiting for Bonjour") }
        guard let plugin else { return }
        // Changes from now on, counted before the read: one made while the homes are read comes as an event too.
        since = try await client.events(since: Int.max - 1, wait: 0).last ?? 0
        let homes = try await client.homes()
        let homeswift = plugin.context.publishedSerialNumbers
        let write: @Sendable (String, String, JSONValue) async throws -> Void = { [weak self] accessoryID, characteristicID, value in
            guard let client = await self?.client else { throw WingmanError.unreachable("stopped") }
            do {
                try await client.write(accessory: accessoryID, characteristic: characteristicID, value: value)
                // HomeKit took it: the accessory answers, whatever its reachability said.
                await self?.answered(accessoryID)
            } catch {
                self?.logger.warning("Wingman write failed: \(error)", metadata: ["accessory": "\(accessoryID)", "characteristic": "\(characteristicID)"])
                throw error
            }
        }
        var mirrors: [String: Mirror] = [:]
        var changed: [Mirror] = []
        var leftOut = 0
        for home in homes {
            for accessory in home.accessories {
                guard plugin.includes(accessory, home: home, homeswift: homeswift) else {
                    leftOut += 1
                    continue
                }
                if let kept = snapshot?.mirrors[accessory.id], kept.signature == Mirror.signature(of: accessory) {
                    kept.update(from: accessory)
                    mirrors[accessory.id] = kept
                } else if let mirror = Mirror(accessory, write: write) {
                    mirrors[accessory.id] = mirror
                    changed.append(mirror)
                }
            }
        }
        // The status first: whoever sees the accessories sees the state they came with.
        if phase != .connected {
            logger.info("Mirroring Apple Home through Wingman", metadata: ["wingman": "\(name)", "accessories": "\(mirrors.count)", "left out": "\(leftOut)"])
        }
        snapshot = Snapshot(mirrors: mirrors, homes: homes.map(\.name), leftOut: leftOut)
        phase = .connected
        lastContact = Date()
        for mirror in changed { plugin.publish(mirror.accessory) }
        await plugin.prune()
    }

    /// The accessory answered (a value change, a write Wingman took): No Response ends until a read says otherwise.
    private func answered(_ accessoryID: String) {
        snapshot?.mirrors[accessoryID]?.accessory.isUnreachable = false
    }

    /// Waits for value changes and applies them. Answers whether the homes must be read again (Wingman restarted,
    /// Apple Home's accessories, rooms or names changed, or a change names a characteristic not seen yet).
    private func follow() async throws -> Bool {
        let answer = try await client.events(since: since, wait: WingmanPlugin.eventWait)
        lastContact = Date()
        // Wingman restarted (its count began again), or dropped events older than it keeps: read the homes again.
        if let last = answer.last, last < since { return true }
        if let first = answer.first, first > since + 1 { return true }
        var readAgain = false
        for event in answer.events {
            if let seq = event.seq { since = max(since, seq) }
            if event.kind == "homes" {
                readAgain = true
                continue
            }
            guard let accessoryID = event.accessoryID, let characteristicID = event.characteristicID,
                  let mirror = snapshot?.mirrors[accessoryID] else { continue }
            guard let characteristic = mirror.characteristics[characteristicID] else {
                readAgain = true
                continue
            }
            Mirror.apply(event.value, to: characteristic)
            // It reports again: it answers.
            answered(accessoryID)
        }
        if let last = answer.last { since = max(since, last) }
        return readAgain
    }

    private func lost(_ error: any Error) {
        let message = "\(error)"
        let next: Phase = if case WingmanError.unauthorized = error { .unpaired(message) } else { .unreachable(message) }
        if next != phase { logger.warning("Wingman: \(message)", metadata: ["wingman": "\(name)"]) }
        phase = next
    }

    func status() -> JSONValue {
        let state: String, error: String?
        switch phase {
        case .connecting: (state, error) = ("connecting", nil)
        case .connected: (state, error) = ("connected", nil)
        case .unreachable(let message): (state, error) = ("unreachable", message)
        case .unpaired(let message): (state, error) = ("unpaired", message)
        }
        var json: [String: JSONValue] = [
            "id": .string(device.id), "name": .string(name), "host": .string(client.host), "port": .number(Double(client.port)), "state": .string(state),
            "accessories": .number(Double(snapshot?.mirrors.count ?? 0)), "notResponding": .number(Double(snapshot?.mirrors.values.count(where: \.accessory.isUnreachable) ?? 0)),
            "leftOut": .number(Double(snapshot?.leftOut ?? 0)), "homes": .array((snapshot?.homes ?? []).map(JSONValue.string)),
            "pinned": .bool(device.fingerprint != nil),
        ]
        if let error { json["error"] = .string(error) }
        if let lastContact { json["lastContact"] = .string(Timestamp.iso8601(lastContact)) }
        return .object(json)
    }
}
