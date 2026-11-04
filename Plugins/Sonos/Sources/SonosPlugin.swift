import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Sonos zone players over their local UPnP API: each zone a speaker accessory whose Sonos service plays, pauses and
/// sets the volume of its group, with an optional Speakers service for the zone itself, its LED and button lock, its
/// alarms and its battery; optionally a Television of its own per zone whose inputs are the household's favourites.
///
/// Players are found by SSDP and mDNS (Discovery.swift), described by their `device_description.xml`, and followed
/// through GENA events (`CallbackServer`, the subscriptions below): nothing is polled but the LEDs with `heartrate`,
/// and a player that has been quiet for five minutes is asked once whether it is still there.
///
/// The configuration is the one of `homebridge-zp` (platform `ZP`), so a Homebridge block works unchanged; accessory ids
/// are `ZP:` and the Homebridge plugin's own (the player id, `RINCON_…`; a TV's `<tvIdPrefix>_…`), and the services keep
/// its subtypes and the characteristics its UUIDs. See README.md and docs/clean-room/Sonos.md.
public actor SonosPlugin: HomeswiftPlugin {
    public static let platform = "ZP"
    public static let name = "Sonos"
    public static let icon: String? = "speaker"
    public static let summary: String? = "Sonos speakers: play, volume and groups, favourites as TV inputs, LEDs and alarms"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// What the plugin uses to reach the players; tests swap them for fakes.
    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient(maximumBodySize: 4 << 20)
        var listen: EventListenerFactory = { port, handler in try await CallbackServer.bind(port: port, handler: handler) }
        var discover: @Sendable (_ mdns: Bool, _ logger: Logger) -> AsyncStream<DiscoveryHit> = Discovery.live
        var localAddress: @Sendable (_ toward: String) -> String = Discovery.localAddress(toward:)
        /// Scales the plugin's own delays (the reset timeout, the TV signal's 10 s, identify's blinks, the checks).
        var timeScale = 1.0
        /// How long `discover()` listens on an instance that is not running.
        var discoveryWindow: Duration = .seconds(5)
    }

    struct Player {
        var client: PlayerClient
        var description: DeviceDescription?
        var household: String?
        var bootSeq: Int?
        var probing = false
        var probed = false
        var lost = false
    }

    struct Household {
        var associated: String?
        /// The player its subscriptions are on.
        var subscribed: String?
        var targetCoordinator: String?
        var favourites: [Favourite] = []
        var favouritesUpdateID: String?
        var alarms: [Alarm] = []
        var topology: Topology?
    }

    struct SubscriptionKey: Hashable, Sendable {
        var player: String
        var service: UPnPService
    }

    struct Subscription {
        var sid: String
        var renewal: Task<Void, Never>?
    }

    /// The players' last addresses, for the next start (the Homebridge plugin keeps them in the accessories' context).
    struct KnownPlayer: Codable, Equatable {
        var address: String
        var household: String?
    }

    let configuration: Configuration
    let settings: Settings
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var logger: Logger { context.logger }
    private var started = false

    private(set) var players: [String: Player] = [:]
    private(set) var households: [String: Household] = [:]
    /// Every player's last topology entry, and its household.
    private(set) var topologyPlayers: [String: TopologyPlayer] = [:]
    private var topologyHousehold: [String: String] = [:]
    private(set) var zones: [String: ZoneAccessory] = [:]
    private(set) var slaves: [String: SlaveAccessory] = [:]
    private var subscriptions: [SubscriptionKey: Subscription] = [:]
    private var permanent: Set<SubscriptionKey> = []
    private var received: Set<SubscriptionKey> = []
    private var listener: (any EventListening)?
    private var listenerStart: Task<(any EventListening)?, Never>?
    private var outstandingProbes = 0
    private var topologyChanged = false
    private var warnedNoPlayers = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        settings = Settings(configuration)
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(_ seed: String) -> String { "\(platform):\(seed)" }

    /// A TV's accessory (`<prefix>_000E58A1B2C301400`) belongs to the player `RINCON_000E58A1B2C301400`.
    public static func deviceID(ofAccessory suffix: String) -> String? {
        guard !suffix.hasPrefix("RINCON_"), let underscore = suffix.lastIndex(of: "_") else { return nil }
        return "RINCON" + suffix[underscore...]
    }

    private var reference: PluginReference { PluginReference(plugin: self) }
    private func scaled(_ seconds: Double) -> Duration { .milliseconds(seconds * 1000 * dependencies.timeScale) }
    private var knownFile: JSONFile<[String: KnownPlayer]> { context.jsonFile("players.json", as: [String: KnownPlayer].self) }

    // MARK: Lifecycle

    public func start() async throws {
        started = true
        for warning in settings.warnings { logger.warning("\(warning)") }
        // The players of the cached accessories, at their last addresses, before any discovery.
        for (id, known) in (knownFile.load() ?? [:]).sorted(by: { $0.key < $1.key }) {
            handle(DiscoveryHit(id: id, address: known.address, household: known.household))
        }
        let discover = dependencies.discover
        let mdns = settings.mdns
        let logger = logger
        tasks.add { [weak self] in
            for await hit in discover(mdns, logger) {
                guard let self else { return }
                await self.handle(hit)
            }
        }
        let period = scaled(300)
        tasks.add { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: period) } catch { return }
                await self?.checkPlayers()
            }
        }
        if let heartrate = settings.heartrate, settings.leds {
            let interval = scaled(Double(heartrate))
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    await self?.pollLEDs()
                }
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        let current = subscriptions
        subscriptions = [:]
        for subscription in current.values { subscription.renewal?.cancel() }
        let clients = players.mapValues(\.client)
        await withTaskGroup(of: Void.self) { group in
            for (key, subscription) in current {
                guard let client = clients[key.player] else { continue }
                group.addTask { _ = try? await withTimeout(.seconds(2)) { try await client.unsubscribe(key.service.eventPath, sid: subscription.sid) } }
            }
        }
        await listener?.close()
        listener = nil
        listenerStart?.cancel()
        for zone in zones.values { zone.tv.withLockedValue { $0 = nil } }
        logger.debug("Stopped")
    }

    // MARK: Discovery and probing

    /// A player heard of (or remembered): one client per player id, which follows its address.
    func handle(_ hit: DiscoveryHit) {
        if players[hit.id] == nil {
            players[hit.id] = Player(
                client: PlayerClient(id: hit.id, address: hit.address, http: dependencies.http, timeout: .seconds(settings.timeout)),
                household: hit.household, bootSeq: hit.bootSeq)
            logger.debug("\(hit.id): found at \(hit.address)")
            probe(hit.id)
            return
        }
        guard var player = players[hit.id] else { return }
        if player.client.address != hit.address {
            // A known player moves only once the new address answers as that player: anyone on the network can
            // announce a player's id.
            verifyMove(hit.id, to: hit.address)
            return
        }
        if let household = hit.household, household != player.household { player.household = household }
        let rebooted = hit.bootSeq.map { new in player.bootSeq.map { new > $0 } ?? false } ?? false
        let previousBoot = player.bootSeq
        if let bootSeq = hit.bootSeq { player.bootSeq = max(bootSeq, player.bootSeq ?? bootSeq) }
        players[hit.id] = player
        seen(hit.id)
        if rebooted, let previousBoot, let bootSeq = hit.bootSeq { reboot(hit.id, from: previousBoot, to: bootSeq) }
        if !player.probed, !player.probing { probe(hit.id) }
    }

    /// Moves the player's client to `address` when the device description there names the same player.
    private func verifyMove(_ id: String, to address: String) {
        let probe = PlayerClient(id: id, address: address, http: dependencies.http, timeout: .seconds(settings.timeout))
        tasks.add { [weak self] in
            guard let description = try? await probe.deviceDescription(), description.id == id else { return }
            await self?.moved(id, to: address)
        }
    }

    private func moved(_ id: String, to address: String) {
        guard let client = players[id]?.client, client.move(to: address) else { return }
        logger.warning("\(name(of: id)): now at \(address)")
        saveKnown()
        seen(id)
    }

    private func probe(_ id: String) {
        guard players[id]?.probing == false else { return }
        players[id]?.probing = true
        outstandingProbes += 1
        tasks.add { [weak self] in await self?.runProbe(id) }
    }

    private func runProbe(_ id: String) async {
        defer {
            players[id]?.probing = false
            outstandingProbes -= 1
            if outstandingProbes == 0, topologyChanged { expose() }
        }
        guard let client = players[id]?.client else { return }
        do {
            let description = try await client.deviceDescription()
            guard description.id == id else { throw SonosError.addressMismatch(expected: id, found: description.id) }
            players[id]?.description = description
            seen(id)
            logger.debug("\(id): \(description.modelName) (\(description.modelNumber)) \(description.generation) v\(description.displayVersion) at \(client.address), reached from \(dependencies.localAddress(client.address))")
            if topologyPlayers[id] == nil { await readTopology(id) }
            guard let entry = topologyPlayers[id] else {
                logger.warning("\(description.roomName): no ZoneGroupTopology event received in \(settings.timeout)s")
                return
            }
            var household = topologyHousehold[id] ?? players[id]?.household
            if household == nil {
                household = try await client.call(.deviceProperties, "GetHouseholdID")["CurrentHouseholdID"]
            }
            guard let household else { return }
            players[id]?.household = household
            topologyHousehold[id] = household
            // The household's other players, from this one's topology.
            for (otherID, other) in households[household]?.topology?.players ?? [:] where players[otherID] == nil {
                guard let address = other.address else { continue }
                handle(DiscoveryHit(id: otherID, address: address, household: household, bootSeq: other.bootSeq))
            }
            if !entry.invisible {
                var record = households[household] ?? Household()
                let current = record.associated.flatMap { topologyPlayers[$0] }
                if record.associated == nil || (current?.battery != nil && entry.battery == nil) {
                    record.associated = id
                }
                households[household] = record
            }
            players[id]?.probed = true
            topologyChanged = true
            saveKnown()
        } catch {
            logger.error("\(id) at \(client.address): \(error)")
        }
    }

    /// Subscribes to the player's topology just long enough for its first event.
    private func readTopology(_ id: String) async {
        let key = SubscriptionKey(player: id, service: .zoneGroupTopology)
        guard await subscribe(key) else { return }
        _ = await waitForEvent(key)
        if !permanent.contains(key) { await unsubscribe(key) }
    }

    /// After probing settles: subscriptions of each household's associated player, the log of its zones, the accessories.
    private func expose() {
        topologyChanged = false
        guard !households.isEmpty else {
            if !warnedNoPlayers { logger.warning("no zone players found") }
            warnedNoPlayers = true
            return
        }
        warnedNoPlayers = false
        logger.info("found \(households.count) household\(households.count == 1 ? "" : "s")")
        for (household, record) in households.sorted(by: { $0.key < $1.key }) {
            logTree(household, record)
            if let associated = record.associated, record.subscribed != associated {
                households[household]?.subscribed = associated
                logger.info("\(household): associated player: \(name(of: associated))")
                tasks.add { [weak self] in await self?.associate(household: household, player: associated) }
            }
        }
        for household in households.keys.sorted() {
            for id in households[household]?.topology?.order ?? [] { expose(id) }
        }
        removeStale()
    }

    private func logTree(_ household: String, _ record: Household) {
        guard let topology = record.topology else { return }
        let ids = topology.order.filter { players[$0]?.description != nil }
        let zones = Set(ids.compactMap { topology.players[$0] }.filter { $0.role == .master }.map(\.id))
        let generation = ids.first.flatMap { players[$0]?.description?.generation } ?? "S2"
        logger.info("\(household): found \(ids.count) \(generation) zone players in \(zones.count) zones")
        for id in ids {
            guard let player = topology.players[id], let description = players[id]?.description else { continue }
            if player.role == .master { logger.info("\(player.zoneDisplayName)\(player.invisible ? " (invisible)" : "")") }
            var capabilities = [player.role.rawValue]
            if player.airPlay { capabilities.append("airPlay") }
            if description.audioIn { capabilities.append("audioIn") }
            if description.tvIn { capabilities.append("tvIn") }
            logger.info("  \(id): \(player.zonePlayerName) (\(description.modelName), \(description.modelNumber)) \(capabilities.joined(separator: ", "))")
        }
    }

    /// The household's permanent subscriptions on its associated player, each first event waited for in turn.
    private func associate(household: String, player id: String) async {
        var services: [UPnPService] = [.zoneGroupTopology]
        if settings.alarms { services.append(.alarmClock) }
        if settings.tv { services.append(.contentDirectory) }
        for service in services {
            let key = SubscriptionKey(player: id, service: service)
            permanent.insert(key)
            let isNew = subscriptions[key] == nil
            guard await subscribe(key) else { continue }
            if isNew, !(await waitForEvent(key)) {
                logger.warning("\(name(of: id)): no \(service.rawValue) event received in \(settings.timeout)s")
            }
        }
    }

    /// Creates the accessories of a player that has none yet.
    private func expose(_ id: String) {
        guard let player = topologyPlayers[id], let description = players[id]?.description, players[id]?.probed == true else { return }
        switch player.role {
        case .master:
            guard zones[id] == nil, !player.invisible, !(settings.excludeAirPlay && player.airPlay), !context.isExcluded(id) else { return }
            createZone(player, description)
        case .slave, .satellite:
            guard settings.leds, slaves[id] == nil, zones[player.zone] != nil, !context.isExcluded(id) else { return }
            let slave = SlaveAccessory(player: player, description: description)
            slaves[id] = slave
            let accessory = slave.build(
                player: player, settings: settings, host: reference, cached: context.accessory(id: Self.accessoryID(id)), identify: identifier(id))
            add(accessory)
            slave.setLost(players[id]?.lost ?? false)
            slave.seen(players[id]?.client.lastSeen)
        }
    }

    private func identifier(_ id: String) -> @Sendable () async throws -> Void {
        let reference = reference
        return { try await reference.plugin?.identify(id) }
    }

    private func createZone(_ player: TopologyPlayer, _ description: DeviceDescription) {
        let id = player.id
        let zone = ZoneAccessory(player: player, description: description, settings: settings, host: reference, logger: logger, timeScale: dependencies.timeScale)
        zones[id] = zone
        let household = topologyHousehold[id] ?? players[id]?.household
        let record = household.flatMap { households[$0] }
        let cached = context.accessory(id: Self.accessoryID(id))
        let wasTarget = cached?.service(settings.serviceType, subtype: "group")?[SonosCharacteristic.sonosCoordinator]?.value.boolValue == true
        zone.setTargetCoordinator(record?.targetCoordinator, groupShortName: record?.targetCoordinator.flatMap { topologyPlayers[$0]?.groupShortName })
        _ = zone.setAlarms(record?.alarms ?? [])
        let accessory = zone.build(shape: zone.wantedShape(alarms: record?.alarms ?? []), cached: cached, identify: identifier(id))
        add(accessory)
        zone.setLost(players[id]?.lost ?? false)
        zone.seen(players[id]?.client.lastSeen)
        zone.applyTopology(player, coordinator: zones[player.zoneGroup])
        if wasTarget || record?.targetCoordinator == id { becomeTargetCoordinator(id) }
        if settings.tv {
            let tv = TVAccessory(zone: zone, settings: settings, host: reference, logger: logger, timeScale: dependencies.timeScale)
            zone.tv.withLockedValue { $0 = tv }
            tv.attach(to: accessory.service(settings.serviceType, subtype: "group") ?? zone.services!.sonos)
            tv.setFavourites(record?.favourites ?? [])
            tv.setFault(players[id]?.lost ?? false)
            let context = context
            let logger = logger
            tasks.add {
                do {
                    try await context.publishExternal(tv.accessory)
                } catch {
                    logger.error("\(tv.accessory.name): cannot publish: \(error)")
                }
            }
        }
        var services: [UPnPService] = [.avTransport, .groupRenderingControl]
        if settings.speakers { services.append(.renderingControl) }
        tasks.add { [weak self, services] in
            for service in services { _ = await self?.subscribe(SubscriptionKey(player: id, service: service)) }
        }
    }

    private func add(_ accessory: Accessory) {
        do {
            try context.add(accessory)
        } catch {
            logger.error("\(accessory.name): \(error)")
        }
    }

    /// Cached accessories of probed players that no longer get one (`leds` or `tv` turned off, `excludeAirPlay`); a
    /// player that never answered keeps its accessories, with their rooms and automations.
    private func removeStale() {
        var held = Set(zones.values.compactMap { $0.accessory?.id } + slaves.values.compactMap { $0.accessory?.id })
        held.formUnion(zones.values.compactMap { $0.tv.withLockedValue { $0 }?.accessory.id })
        let prefix = "\(Self.platform):"
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) && !held.contains(accessory.id) {
            let seed = String(accessory.id.dropFirst(prefix.count))
            let playerID = Self.deviceID(ofAccessory: seed) ?? seed
            guard players[playerID]?.probed == true else { continue }
            let id = accessory.id
            let context = context
            tasks.add {
                try? await context.remove(id: id)
            }
            logger.info("remove \(accessory.name)")
        }
    }

    // MARK: Subscriptions

    private func ensureListener() async -> (any EventListening)? {
        if let listener { return listener }
        if let listenerStart { return await listenerStart.value }
        let listen = dependencies.listen
        let port = settings.port
        let reference = reference
        let logger = logger
        let task = Task<(any EventListening)?, Never> {
            do {
                return try await listen(port) { request in await reference.plugin?.handleEvent(request) ?? (503, nil, "") }
            } catch {
                logger.error("cannot listen for events on port \(port): \(error)")
                return nil
            }
        }
        listenerStart = task
        let started = await task.value
        listenerStart = nil
        listener = started
        if let started {
            logger.info("listening on http://\(dependencies.localAddress(players.values.first?.client.address ?? "")):\(started.port)/notify")
        }
        return started
    }

    /// A new subscription (or the one there is); false when it failed.
    @discardableResult
    private func subscribe(_ key: SubscriptionKey) async -> Bool {
        if subscriptions[key] != nil { return true }
        guard let listener = await ensureListener(), let client = players[key.player]?.client else { return false }
        if subscriptions[key] != nil { return true }
        received.remove(key)
        let callback = "http://\(dependencies.localAddress(client.address)):\(listener.port)/notify/\(key.player)\(key.service.eventPath)"
        do {
            let subscription = try await client.subscribe(key.service.eventPath, callback: callback, seconds: settings.subscriptionTimeout + 30)
            subscriptions[key] = Subscription(sid: subscription.sid)
            scheduleRenewal(key, granted: subscription.timeout)
            return true
        } catch {
            logger.warning("\(name(of: key.player)): subscribe \(key.service.eventPath): \(error)")
            return false
        }
    }

    /// Renews `subscriptionTimeout` after each subscribe, sooner when the player granted less.
    private func scheduleRenewal(_ key: SubscriptionKey, granted: Int?) {
        let duration = settings.subscriptionTimeout
        let seconds = granted.map { min(duration, max($0 - 30, 1)) } ?? duration
        let delay = scaled(Double(seconds))
        subscriptions[key]?.renewal?.cancel()
        subscriptions[key]?.renewal = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.renew(key)
        }
    }

    private func renew(_ key: SubscriptionKey) async {
        guard let subscription = subscriptions[key], let client = players[key.player]?.client else { return }
        do {
            let renewed = try await client.renew(key.service.eventPath, sid: subscription.sid, seconds: settings.subscriptionTimeout + 30)
            subscriptions[key]?.sid = renewed.sid
            scheduleRenewal(key, granted: renewed.timeout)
        } catch {
            if case SonosError.http(412, _) = error {
                logger.debug("\(name(of: key.player)): \(key.service.eventPath): subscription expired; subscribing again")
            } else {
                logger.warning("\(name(of: key.player)): renew \(key.service.eventPath): \(error)")
            }
            subscriptions[key] = nil
            await resubscribe(key)
        }
    }

    /// Subscribes again, retrying a minute apart (with jitter, longer each time) until it works or the plugin stops.
    private func resubscribe(_ key: SubscriptionKey) async {
        let backoff = Backoff(initial: .seconds(60), maximum: .seconds(900), jitter: .proportional(0.2))
        var attempt = 0
        while !Task.isCancelled, !tasks.isStopped {
            if await subscribe(key) { return }
            do { try await Task.sleep(for: backoff.delay(attempt: attempt) * dependencies.timeScale) } catch { return }
            attempt += 1
        }
    }

    private func unsubscribe(_ key: SubscriptionKey) async {
        guard let subscription = subscriptions.removeValue(forKey: key) else { return }
        subscription.renewal?.cancel()
        received.remove(key)
        do {
            try await players[key.player]?.client.unsubscribe(key.service.eventPath, sid: subscription.sid)
        } catch {
            logger.debug("\(name(of: key.player)): unsubscribe \(key.service.eventPath): \(error)")
        }
    }

    /// Waits up to `timeout` seconds for the subscription's first event.
    private func waitForEvent(_ key: SubscriptionKey) async -> Bool {
        let deadline = ContinuousClock.now + scaled(Double(settings.timeout))
        while !received.contains(key) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A player rebooted: its description read again, its subscriptions made afresh.
    private func reboot(_ id: String, from old: Int, to new: Int) {
        logger.warning("\(name(of: id)): rebooted (\(old) → \(new))")
        let keys = subscriptions.keys.filter { $0.player == id }
        for key in keys { subscriptions.removeValue(forKey: key)?.renewal?.cancel() }
        tasks.add { [weak self] in
            guard let self else { return }
            if let description = try? await self.players[id]?.client.deviceDescription() { await self.setDescription(id, description) }
            for key in keys { await self.subscribe(key) }
        }
    }

    private func setDescription(_ id: String, _ description: DeviceDescription) {
        players[id]?.description = description
    }

    // MARK: Events

    /// What the event server answers.
    func handleEvent(_ request: CallbackRequest) async -> (status: Int, contentType: String?, body: String) {
        if request.method == "GET", request.path == "/notify" { return (200, "text/html; charset=utf-8", statusPage()) }
        guard request.method == "NOTIFY" else { return (200, nil, "") }
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 5 || segments.count == 6, segments[0].isEmpty, segments[1] == "notify" else { return (200, nil, "") }
        let id = segments[2]
        // Only the player the path names, from its own address: the server listens on the whole network.
        guard let player = players[id], player.client.address == request.remoteAddress else { return (403, nil, "") }
        guard let service = UPnPService(eventPath: "/" + segments[3...].joined(separator: "/")) else { return (200, nil, "") }
        player.client.seen()
        seen(id)
        received.insert(SubscriptionKey(player: id, service: service))
        do {
            try await dispatch(service, from: id, body: request.body)
        } catch {
            logger.warning("\(name(of: id)): \(service.rawValue) event: \(error)")
        }
        return (200, nil, "")
    }

    private func dispatch(_ service: UPnPService, from id: String, body: Data) async throws {
        switch service {
        case .zoneGroupTopology:
            applyTopology(try Topology(event: body), from: id)
        case .avTransport:
            let variables = try Events.lastChange(try Events.properties(body)["LastChange"])
            guard !variables.isEmpty, let zone = zones[id] else { return }
            let update = TransportUpdate(variables)
            if zone.isCoordinator {
                zone.apply(update)
                for member in members(of: id) { member.apply(update, fromCoordinator: true) }
                if update.sleepTimerChanged {
                    tasks.add { [weak self] in
                        await zone.refreshRemainingDuration()
                        await self?.copyRemainingDuration(from: id)
                    }
                }
            } else {
                zone.markLeavingIfMember()
                zone.apply(update)
            }
        case .groupRenderingControl:
            let properties = try Events.properties(body)
            let volume = Events.int(properties["GroupVolume"])
            let mute = properties["GroupMute"].map { $0 == "1" }
            guard let zone = zones[id] else { return }
            zone.applyGroup(volume: volume, mute: mute)
            if zone.isCoordinator { for member in members(of: id) { member.applyGroup(volume: volume, mute: mute) } }
        case .renderingControl:
            let variables = try Events.lastChange(try Events.properties(body)["LastChange"])
            guard !variables.isEmpty else { return }
            zones[id]?.applyRendering(variables)
        case .alarmClock:
            guard let household = household(of: id) else { return }
            tasks.add { [weak self] in await self?.refreshAlarms(household) }
        case .contentDirectory:
            guard let household = household(of: id) else { return }
            let updateID = try Events.properties(body)["FavoritesUpdateID"]
            guard updateID == nil || updateID != households[household]?.favouritesUpdateID || households[household]?.favouritesUpdateID == nil else { return }
            households[household]?.favouritesUpdateID = updateID ?? households[household]?.favouritesUpdateID ?? ""
            tasks.add { [weak self] in await self?.refreshFavourites(household, from: id) }
        case .deviceProperties:
            break
        }
    }

    /// The zones whose group `id` coordinates, without it.
    private func members(of id: String) -> [ZoneAccessory] {
        zones.values.filter { $0.id != id && !$0.isCoordinator && $0.zoneGroup == id }
    }

    private func copyRemainingDuration(from id: String) {
        guard let value = zones[id]?.services?.sonos[.remainingDuration]?.value else { return }
        for member in members(of: id) { member.services?.sonos[.remainingDuration]?.value = value }
    }

    private func household(of id: String) -> String? { topologyHousehold[id] ?? players[id]?.household }

    func applyTopology(_ topology: Topology, from reporter: String) {
        guard let household = topology.household ?? household(of: reporter) else { return }
        let previous = households[household]?.topology
        var record = households[household] ?? Household()
        record.topology = topology
        households[household] = record
        for (id, entry) in topology.players {
            let old = topologyPlayers[id]
            topologyPlayers[id] = entry
            topologyHousehold[id] = household
            guard var player = players[id] else { continue }
            if let address = entry.address, player.client.move(to: address) {
                logger.warning("\(entry.zonePlayerName): address changed to \(address)")
                saveKnown()
            }
            if let bootSeq = entry.bootSeq {
                if let known = player.bootSeq, bootSeq > known, old != nil { reboot(id, from: known, to: bootSeq) }
                player.bootSeq = max(bootSeq, player.bootSeq ?? bootSeq)
            }
            players[id] = player
        }
        for id in topology.vanished { setLost(id, true) }
        guard previous != topology else { return }
        for zone in zones.values where topologyHousehold[zone.id] == household {
            guard let entry = topology.players[zone.id] else { continue }
            zone.applyTopology(entry, coordinator: zones[entry.zoneGroup])
            if zone.wantedShape(alarms: households[household]?.alarms ?? []) != zone.currentShape { rebuild(zone) }
        }
        for slave in slaves.values where topologyHousehold[slave.id] == household {
            guard let entry = topology.players[slave.id] else { continue }
            if slave.needsRebuild(for: entry) {
                add(slave.build(player: entry, settings: settings, host: reference, identify: identifier(slave.id)))
            } else {
                slave.applyTopology(entry)
            }
        }
        refreshTargetCoordinator(household)
    }

    private func rebuild(_ zone: ZoneAccessory) {
        let household = household(of: zone.id)
        let accessory = zone.build(shape: zone.wantedShape(alarms: household.flatMap { households[$0]?.alarms } ?? []), identify: identifier(zone.id))
        add(accessory)
        if let tv = zone.tv.withLockedValue({ $0 }), let sonos = zone.services?.sonos { tv.attach(to: sonos) }
        zone.setLost(players[zone.id]?.lost ?? false)
    }

    private func refreshAlarms(_ household: String) async {
        guard let id = households[household]?.associated, let client = players[id]?.client else { return }
        do {
            let alarms = try Alarm.list(try await client.call(.alarmClock, "ListAlarms")["CurrentAlarmList"])
            let old = Set(households[household]?.alarms.map(\.id) ?? [])
            households[household]?.alarms = alarms
            for removed in old.subtracting(alarms.map(\.id)).sorted() { logger.info("remove Alarm \(removed)") }
            for zone in zones.values where topologyHousehold[zone.id] == household {
                if zone.setAlarms(alarms) { rebuild(zone) }
            }
        } catch {
            logger.warning("\(name(of: id)): ListAlarms: \(error)")
        }
    }

    private func refreshFavourites(_ household: String, from id: String) async {
        guard let client = players[id]?.client else { return }
        do {
            let result = try await client.call(.contentDirectory, "Browse", [
                ("ObjectID", "FV:2"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI"),
                ("StartingIndex", "0"), ("RequestedCount", "0"), ("SortCriteria", ""),
            ])["Result"]
            let favourites = Favourite.list(result)
            households[household]?.favourites = favourites
            for zone in zones.values where topologyHousehold[zone.id] == household {
                zone.tv.withLockedValue { $0 }?.setFavourites(favourites)
            }
        } catch {
            logger.warning("\(name(of: id)): Browse favourites: \(error)")
        }
    }

    // MARK: Target coordinator, lost players, the LEDs

    func client(_ id: String) -> PlayerClient? { players[id]?.client }

    /// The client of the zone's household's associated player (alarms are the household's).
    func associatedClient(of id: String) -> PlayerClient? {
        household(of: id).flatMap { households[$0]?.associated }.flatMap { players[$0]?.client }
    }

    /// Makes `id` its household's target coordinator: the zone Speakers On joins, and the TVs' Join input.
    func becomeTargetCoordinator(_ id: String) {
        guard let household = household(of: id) else { return }
        households[household]?.targetCoordinator = id
        refreshTargetCoordinator(household)
    }

    private func refreshTargetCoordinator(_ household: String) {
        let target = households[household]?.targetCoordinator
        let groupShortName = target.flatMap { topologyPlayers[$0]?.groupShortName }
        for zone in zones.values where topologyHousehold[zone.id] == household {
            zone.setTargetCoordinator(target, groupShortName: groupShortName)
            zone.tv.withLockedValue { $0 }?.refresh()
        }
    }

    /// Any message from a player: its fault cleared, its Last Seen updated.
    private func seen(_ id: String) {
        if players[id]?.lost == true { setLost(id, false) }
        let date = players[id]?.client.lastSeen
        zones[id]?.seen(date)
        slaves[id]?.seen(date)
    }

    private func setLost(_ id: String, _ lost: Bool) {
        guard players[id] != nil || zones[id] != nil || slaves[id] != nil else { return }
        players[id]?.lost = lost
        if lost { logger.warning("\(name(of: id)): lost") }
        zones[id]?.setLost(lost)
        zones[id]?.tv.withLockedValue { $0 }?.setFault(lost)
        slaves[id]?.setLost(lost)
    }

    /// Every five minutes: a player quiet for five minutes is asked whether it is there; one unseen for ten is lost.
    func checkPlayers() async {
        if households.isEmpty, outstandingProbes == 0 { logger.warning("no zone players found") }
        let now = Date()
        for (id, player) in players.sorted(by: { $0.key < $1.key }) where player.probed {
            let age = player.client.lastSeen.map { now.timeIntervalSince($0) } ?? .infinity
            let line = "\(name(of: id)): last seen \(LastSeen.text(player.client.lastSeen)), boot sequence \(player.bootSeq.map(String.init) ?? "n/a")"
            if age >= 600 * dependencies.timeScale { logger.info("\(line)") } else { logger.debug("\(line)") }
            guard age >= 300 * dependencies.timeScale else { continue }
            let client = player.client
            if (try? await withTimeout(.seconds(settings.timeout)) { try await client.call(.deviceProperties, "GetLEDState") }) != nil {
                seen(id)
            } else if age >= 600 * dependencies.timeScale, players[id]?.lost == false {
                setLost(id, true)
            }
        }
    }

    /// With `heartrate`: every LED and button lock read, the LED's skipped while identify blinks it.
    func pollLEDs() async {
        var targets: [(Service, PlayerClient, Bool)] = []
        for zone in zones.values { if let led = zone.services?.led, let client = players[zone.id]?.client { targets.append((led, client, zone.blinking.withLockedValue { $0 })) } }
        for slave in slaves.values { if let led = slave.led, let client = players[slave.id]?.client { targets.append((led, client, slave.blinking.withLockedValue { $0 })) } }
        for (led, client, blinking) in targets {
            do { try await LEDService.poll(led, client: client, skipLED: blinking) } catch { logger.debug("\(client.id): LED: \(error)") }
        }
    }

    /// Identify: the player's LED blinks.
    func identify(_ id: String) async throws {
        guard let client = players[id]?.client, let blinking = zones[id]?.blinking ?? slaves[id]?.blinking else { return }
        let scale = dependencies.timeScale
        tasks.add { [logger] in
            do { try await ZoneAccessory.blink(client: client, isBlinking: blinking, timeScale: scale) } catch { logger.warning("\(id): identify: \(error)") }
        }
    }

    private func name(of id: String) -> String {
        topologyPlayers[id]?.zonePlayerName ?? players[id]?.description?.roomName ?? id
    }

    private func saveKnown() {
        var known: [String: KnownPlayer] = [:]
        for (id, player) in players where player.probed { known[id] = KnownPlayer(address: player.client.address, household: player.household) }
        guard !known.isEmpty else { return }
        do { try knownFile.save(known) } catch { logger.debug("players.json: \(error)") }
    }

    /// `GET /notify`: the registered players, for troubleshooting.
    private func statusPage() -> String {
        var rows = ""
        for (id, player) in players.sorted(by: { $0.key < $1.key }) {
            let subscribed = subscriptions.keys.filter { $0.player == id }.map { $0.service.eventPath.replacingOccurrences(of: "/Event", with: "") }.sorted()
            rows += "<tr><td>\(name(of: id).htmlEscaped)</td><td>\(id.htmlEscaped)</td><td>\(player.client.address.htmlEscaped)</td>"
                + "<td>\(dependencies.localAddress(player.client.address).htmlEscaped)</td><td>\(subscribed.joined(separator: ", ").htmlEscaped)</td></tr>"
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Sonos</title></head><body><table>"
            + "<tr><th>Name</th><th>ID</th><th>IP</th><th>Local IP</th><th>Subscriptions</th></tr>\(rows)</table></body></html>"
    }

    // MARK: Setup

    /// The zone players: those the running plugin knows, or (on an instance made for Setup) those SSDP and mDNS
    /// announce within `discoveryWindow`, each asked for its description. They need no authorization.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices: [String: DiscoveredDevice] = [:]
        if started {
            for (id, player) in players {
                guard let description = player.description, topologyPlayers[id]?.invisible != true else { continue }
                let entry = topologyPlayers[id]
                devices[id] = DiscoveredDevice(
                    deviceID: id, name: context.accessorySettings(for: id).name ?? entry?.accessoryName ?? description.roomName,
                    model: "\(description.modelName) (\(description.modelNumber))", address: player.client.address, isSetUp: true, kind: Self.deviceKind)
                devices[id]?.isReachable = !player.lost
            }
            return devices.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
        }
        let hits = await dependencies.discover(settings.mdns, logger).collect(for: dependencies.discoveryWindow)
        var latest: [String: DiscoveryHit] = [:]
        for hit in hits { latest[hit.id] = hit }
        let http = dependencies.http
        let found = await withTaskGroup(of: (DiscoveryHit, DeviceDescription?).self) { group in
            for hit in latest.values {
                group.addTask {
                    let client = PlayerClient(id: hit.id, address: hit.address, http: http, timeout: .seconds(3))
                    return (hit, try? await client.deviceDescription())
                }
            }
            var found: [(DiscoveryHit, DeviceDescription?)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (hit, description) in found {
            devices[hit.id] = DiscoveredDevice(
                deviceID: hit.id, name: context.accessorySettings(for: hit.id).name ?? description?.roomName ?? hit.id,
                model: description.map { "\($0.modelName) (\($0.modelNumber))" }, address: hit.address, isSetUp: true, kind: Self.deviceKind)
        }
        return devices.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// Every player is a speaker.
    static let deviceKind = "speaker"

    public func deviceKind(of deviceID: String) async -> String? { Self.deviceKind }
}
