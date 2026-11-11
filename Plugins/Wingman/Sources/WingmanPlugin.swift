import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The Home app's accessories in Homeswift, through Homeswift Wingman: a menu bar app on a Mac that reads Apple Home
/// with HomeKit and serves it over TLS to the bridges paired with it (github.com/mp-consulting/homeswift-wingman).
///
/// Each Wingman is a device of Setup by its id (WingmanSetup.swift), authorized with the code its menu shows once its
/// certificate is checked: its token and pinned certificate are kept in the vault under its id, its address in its
/// Accessory Settings (an entry of `devices` the plugin's page wrote after pairing before Setup did still runs, its `token`
/// and `fingerprint` moved into the vault; an entry with only an address is a Wingman for Setup to pair). Each mirrored
/// accessory and each bridge of Apple Home is a Discovered Device too, which its Accessory Settings Exclude
/// (WingmanSettings.swift). The plugin reads the homes (`GET /homes`), follows value changes with a
/// long-poll (`GET /events?since=&wait=`) and writes through `POST /write`. Its accessories are mirrored
/// (`Accessory.mirroredFrom`): on the web UI's wall, in moods, scenes, automations and the MCP tools, but never
/// published to HomeKit, which has them already. Homeswift's own accessories, which Apple Home lists too, are left
/// out. See README.md.
public actor WingmanPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            /// Wingman's id (its Bonjour TXT `id`), which keys the entry. Empty for an entry with only an address: a
            /// Wingman Bonjour does not reach, typed in the settings for Setup to find and pair.
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
    public static let summary: String? = "Apple Home's accessories in Homeswift, through a Mac"
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
        /// How long a look for Wingmen on the network lasts when none is known yet.
        var discoveryDuration: Duration = WingmanPlugin.discoveryDuration
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
    /// Whether Bonjour browses all the time (the plugin started), so `announced` is what the network has.
    private(set) var isBrowsing = false
    private var linkTasks: [String: Task<Void, Never>] = [:]
    /// The home Homeswift's bridge is in, by name, as each link (by Wingman id) last read it: the accessories mirrored
    /// are theirs.
    nonisolated let bridgeHomes = NIOLockedValueBox<[String: String]>([:])
    nonisolated var logger: Logger { context.logger }
    nonisolated var refreshInterval: Duration { .seconds(60 * max(configuration.refreshMinutes ?? 10, 1)) }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    /// The Wingmen the plugin runs, from `devices` and Setup (`configuredDevices`), read at start.
    private(set) var running: [Configuration.Device] = []

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        Self.moveLegacyCredentials(configuration, context)
    }

    public func start() async throws {
        running = configuredDevices()
        for device in running {
            // Excluded in its Accessory Settings: not reached, its accessories not mirrored.
            if context.isExcluded(device.id) { continue }
            // The token goes only to the certificate pairing pinned: never over a connection that accepts any.
            guard let token = device.token, !token.isEmpty, device.fingerprint?.isEmpty == false else {
                logger.warning("A Wingman in devices has no token or no pinned certificate: set it up on Add accessories", metadata: ["wingman": "\(device.name ?? device.id)"])
                continue
            }
            run(device, token: token)
        }
        if links.isEmpty { logger.info("No Wingman paired yet: Add accessories finds them on the network and pairs them") }
        // Bonjour, all the time: a Wingman whose address changed is reached at the new one, one that left is forgotten.
        let browse = dependencies.browse
        let logger = self.logger
        isBrowsing = true
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

    /// Starts the link to a Wingman, in place of the one it had.
    private func run(_ device: Configuration.Device, token: String) {
        linkTasks[device.id]?.cancel()
        let link = Link(device: device, token: token, plugin: self)
        links[device.id] = link
        linkTasks[device.id] = tasks.add { await link.run() }
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

    /// What Bonjour announces within `discoveryDuration`, by Wingman's id.
    func browseOnce() async -> [Announced] {
        var found: [String: Announced] = [:]
        for event in await dependencies.browse(logger).collect(for: dependencies.discoveryDuration) {
            guard case .found(let service) = event, let id = service.txt["id"], !id.isEmpty else { continue }
            found[id] = Announced(id: id, name: service.name, host: service.preferredAddress, port: service.port)
        }
        return Array(found.values)
    }

    // MARK: Accessories

    /// Whether an Apple Home accessory comes to Homeswift: not Homeswift's own (on its bridges, or published on its own
    /// like a TV or a camera, by serial number: `homeswift` is `context.publishedSerialNumbers`), not excluded, in a
    /// chosen home.
    nonisolated func includes(_ accessory: WingmanAPI.Accessory, home: WingmanAPI.Home, homeswift: Set<String>) -> Bool {
        isCandidate(accessory, home: home, homeswift: homeswift) && !isLeftOut(accessory)
    }

    /// Whether an Apple Home accessory is one Homeswift may mirror at all: not Homeswift's own, in a chosen home. What
    /// discovery lists, Excluded or not.
    nonisolated func isCandidate(_ accessory: WingmanAPI.Accessory, home: WingmanAPI.Home, homeswift: Set<String>) -> Bool {
        if let serial = accessory.serialNumber, homeswift.contains(PluginContext.serialKey(serial)) { return false }
        if !includesHome(home.name) { return false }
        if let bridge = accessory.bridge, bridge.manufacturer == "Homeswift" || bridge.model == "Homeswift" { return false }
        return true
    }

    /// Excluded, it or its bridge (by their Accessory Settings), or left out by a Homebridge-shaped list (`exclude`,
    /// `excludeBridges`).
    nonisolated func isLeftOut(_ accessory: WingmanAPI.Accessory) -> Bool {
        if context.isExcluded(accessory.id) || isExcludedBySettings(accessory) { return true }
        guard let bridge = accessory.bridge else { return false }
        let id = Self.bridgeID(bridge.name).lowercased()
        return context.excludedDeviceIDs.contains { $0.lowercased() == id }
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

    /// `GET wingmen` the paired Wingmen and how they are doing. Finding and pairing one is Setup's (WingmanSetup.swift).
    /// `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "wingmen"):
            // Polled every few seconds by the page: the devices read from the vault once, at start, not at each poll.
            var list: [JSONValue] = []
            for device in running where !context.isExcluded(device.id) {
                if let link = links[device.id] {
                    list.append(await link.status())
                } else {
                    list.append(["id": .string(device.id), "name": .string(device.name ?? device.id), "state": "unpaired",
                                 "error": "No token or no pinned certificate: set it up again on Add accessories"])
                }
            }
            return PluginWebResponse(["wingmen": .array(list)])
        case ("GET", "empty-groups"):
            return await emptyGroupsResponse()
        case ("POST", "empty-groups/remove"):
            // By id only: removing all of them is a list the person saw, never an empty request.
            guard let ids = request.body["ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty else { return .error(400, "ids: the groups to remove") }
            return await removeEmptyGroups(Set(ids))
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
        /// Every accessory Homeswift may mirror, Excluded or not: the Discovered Devices.
        var candidates: [WingmanAPI.Accessory]
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
    /// Apple Home's rooms, scenes and automations; nil when this Wingman does not serve them.
    private(set) var structure: Structure?
    /// The Home as the last read gave it to the Home Link: Homeswift hears of it when it changes.
    private var lastHome: HomeSnapshot?

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

    /// The accessories Homeswift may mirror from the last read of the homes, Excluded ones included; nil before the first.
    var candidates: [WingmanAPI.Accessory]? { snapshot?.candidates }

    /// The accessories of the last read of the homes; nil before the first.
    var loadedIDs: Set<String>? { snapshot.map { Set($0.mirrors.values.map(\.accessory.id)) } }
    var name: String { device.name ?? device.id }
    var isConnected: Bool { phase == .connected }

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
    /// `scenes` false after a structural edit: the homes changed, not the scenes or automations.
    /// Reads of the homes started, and edits put in the copy, counted; and the latest one applied. A read applies what it
    /// read only when nothing that started after it was applied first: a read from before an edit never puts an old name back.
    private var reads = 0
    private var applied = 0

    func refresh(scenes: Bool = true) async throws {
        guard !client.host.isEmpty else { throw WingmanError.unreachable("no address yet: waiting for Bonjour") }
        guard let plugin else { return }
        reads += 1
        let read = reads
        let info = try await client.info().info
        // Changes from now on, counted before the read: one made while the homes are read comes as an event too.
        since = try await client.events(since: Int.max - 1, wait: 0).last ?? 0
        let homes = try await client.homes()
        guard read > applied else { return }
        applied = read
        let homeswift = plugin.context.publishedSerialNumbers
        let bridges = plugin.context.homeswiftBridgeSerialNumbers
        let bridgeHome = Structure.bridgeHome(of: homes, bridges: bridges)
        plugin.bridgeHomes.withLockedValue { $0[device.id] = bridgeHome.flatMap { id in homes.first { $0.id == id }?.name } }
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
        var candidates: [WingmanAPI.Accessory] = []
        for home in homes {
            for accessory in home.accessories {
                if plugin.isCandidate(accessory, home: home, homeswift: homeswift) { candidates.append(accessory) }
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
        snapshot = Snapshot(mirrors: mirrors, homes: homes.map(\.name), leftOut: leftOut, candidates: candidates)
        phase = .connected
        lastContact = Date()
        if info.servesStructure {
            var structure = Structure(
                allowed: info.structure == true, homes: homes, mirrored: Set(mirrors.keys),
                bridges: bridges, bridgeHome: bridgeHome, own: plugin.context.ownSerialNumbers, homeLink: info.servesHomeLink)
            // What the last read gave, until this one's scenes and automations come.
            structure.scenes = self.structure?.scenes ?? []
            structure.automations = self.structure?.automations ?? []
            self.structure = structure
            await reload(scenes: scenes, automations: scenes)
        } else {
            structure = nil
        }
        for mirror in changed { plugin.publish(mirror.accessory) }
        await plugin.prune()
        homeMayHaveChanged()
    }

    /// Tells Homeswift when the Home the Home Link gives changed: a room, a zone, a group or a placement, made in the Home
    /// app or by Homeswift, or the link going up or down.
    private func homeMayHaveChanged() {
        guard let plugin else { return }
        let home = phase == .connected ? structure?.homeSnapshot(in: plugin.context) : nil
        guard home != lastHome else { return }
        lastHome = home
        plugin.context.homeChanged()
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
        var scenes = false, automations = false, settings = false
        for event in answer.events {
            if let seq = event.seq { since = max(since, seq) }
            switch event.kind {
            case "homes":
                readAgain = true
                continue
            case "scenes": scenes = true; continue
            case "automations": automations = true; continue
            case "settings": settings = true; continue
            default: break
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
        // A read of the homes reads the rest too.
        if !readAgain, structure != nil {
            if settings, let info = try? await client.info().info { structure?.allowed = info.structure == true }
            await reload(scenes: scenes, automations: automations)
        }
        return readAgain
    }

    // MARK: Rooms, scenes and automations

    enum Reload { case nothing, scenes, automations }

    /// Reads Apple Home's scenes, automations or both again; a failure keeps what was read before.
    func reload(scenes: Bool, automations: Bool) async {
        guard structure != nil else { return }
        do {
            if scenes { structure?.scenes = try await client.scenes() }
            if automations { structure?.automations = try await client.automations() }
        } catch {
            logger.warning("Could not read Apple Home's scenes and automations: \(error)", metadata: ["wingman": "\(name)"])
        }
    }

    /// A structural edit (docs/apple-home-design.md), then what it changed read again: Wingman's event would come too,
    /// but the person who asked sees the result at once.
    @discardableResult
    func edit(_ path: String, _ body: JSONValue, reload what: Reload = .nothing) async throws -> JSONValue {
        do {
            let answer = try await client.edit(path, body)
            await reload(scenes: what == .scenes, automations: what == .automations)
            return answer
        } catch {
            logger.warning("Wingman refused \(path): \(error)", metadata: ["wingman": "\(name)"])
            throw error
        }
    }

    /// A change the Home Link asks for (`WingmanPlugin.applyHomeChange`): Wingman's refusal as Apple Home's, the homes
    /// read again so the next snapshot shows it (a move is put in the copy at once). Answers the id of what `created`
    /// names in Wingman's answer.
    func homeEdit(_ path: String, _ body: JSONValue, created: String? = nil, moved: (accessory: String, roomID: String?)? = nil) async throws -> String? {
        let answer: JSONValue
        do {
            answer = try await client.edit(path, body)
        } catch WingmanError.refused(let status, let message) {
            logger.warning("Wingman refused \(path): \(message)", metadata: ["wingman": "\(name)"])
            throw HomeChangeError(status == 404 ? .notFound : .refused, message)
        } catch {
            lost(error)
            throw HomeChangeError(.unreachable, "\(error)")
        }
        if let moved {
            // The copy has the move now: a read already under way, from before it, keeps its old room to itself.
            reads += 1
            applied = reads
            structure?.devices[moved.accessory]?.roomID = moved.roomID
            let home = structure?.devices[moved.accessory].flatMap { structure?.home($0.home) }
            structure?.devices[moved.accessory]?.room = moved.roomID.flatMap { id in home?.rooms.first { $0.id == id }?.name }
            lastHome = plugin.flatMap { structure?.homeSnapshot(in: $0.context) }
        } else {
            do { try await refresh(scenes: false) } catch { lost(error) }
        }
        return created.flatMap { answer[$0]?["id"]?.stringValue }
    }

    private func lost(_ error: any Error) {
        let message = "\(error)"
        let next: Phase = if case WingmanError.unauthorized = error { .unpaired(message) } else { .unreachable(message) }
        if next != phase { logger.warning("Wingman: \(message)", metadata: ["wingman": "\(name)"]) }
        phase = next
        homeMayHaveChanged()
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
