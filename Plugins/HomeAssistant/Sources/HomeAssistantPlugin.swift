import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The devices of a Home Assistant server, over its WebSocket API: one accessory per HA device (by its device registry
/// id), one service per supported entity (subtype: the entity registry id, so renaming an `entity_id` keeps HomeKit's
/// iids), states followed through `state_changed` and HomeKit's writes sent as `call_service`.
///
/// There is no Homebridge plugin behind it: this is a clean-room implementation of docs/clean-room/HomeAssistant.md,
/// whose domain mapping follows Home Assistant's own HomeKit bridge so an entity looks the same in Apple Home whichever
/// bridge shows it. See README.md in this directory.
public actor HomeAssistantPlugin: HomeswiftPlugin {
    /// The block as written; read by `Settings`.
    public struct Configuration: Decodable, Sendable {
        public var block: JSONValue

        public init(from decoder: any Decoder) throws { block = try JSONValue(from: decoder) }
        public init(block: JSONValue) { self.block = block }
    }

    /// The account's credentials, kept in the vault by Setup.
    struct Credentials: Codable, Sendable {
        var accessToken: String
    }

    /// A Home Assistant server mDNS announces (section 3).
    struct Announcement: Sendable, Equatable {
        var name: String
        var uuid: String?
        var url: String
        var version: String?
    }

    /// What the plugin uses to reach Home Assistant and how long it waits; tests swap them.
    struct Dependencies: Sendable {
        var connect: @Sendable (URL, WebSocket.Options) async throws -> any WebSocketConnection = { try await WebSocket.connect(to: $0, options: $1) }
        var browse: @Sendable (Duration) async -> [Announcement] = { await HomeAssistantPlugin.browse(for: $0) }
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: .proportional(0.2))
        var authTimeout: Duration = .seconds(10)
        var commandTimeout: Duration = .seconds(30)
        var pingInterval: Duration = .seconds(30)
        var pongTimeout: Duration = .seconds(10)
        /// Characteristic writes of one service gathered into one call (section 6).
        var batchWindow: Duration = .milliseconds(10)
        /// A scene's or a button's switch turns itself off after this (7.3, proposal: 1 s).
        var momentaryReset: Duration = .seconds(1)
        /// Registry changes and new entities rebuild the accessories after this quiet time.
        var resyncDelay: Duration = .milliseconds(300)
        /// States are read again this often while Home Assistant is still starting (2.9).
        var notRunningRetry: Duration = .seconds(10)
    }

    public static let platform = "HomeAssistant"
    public static let name = "Home Assistant"
    public static let icon: String? = "bridge"
    public static let summary: String? = "Lights, sensors, climate and more from a Home Assistant server"
    /// What a mirrored entity's accessory says it comes from.
    static let mirrorSource = "Home Assistant"
    static let serviceType = "_home-assistant._tcp"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let settings: Settings
    let tasks = TaskBag()
    var logger: Logger { context.logger }

    // The server's view, as last read.
    var config = ServerConfig()
    var states: [String: EntityState] = [:]
    private var lastUpdated: [String: String] = [:]
    var entities: [String: EntityEntry] = [:]
    var devices: [String: DeviceEntry] = [:]
    var areas: [String: String] = [:]
    var registriesAvailable = false
    var snapshotLoaded = false

    // What is on the bridge.
    struct Built {
        var accessory: Accessory
        var signature: String
        var functions: [EntityFunction]
        var sources: Set<String>
        var controllers: [AdaptiveLightingController]
    }
    var built: [String: Built] = [:]
    /// Each entity's Functions (a device's Battery is under every entity that feeds it), and the accessory it is on.
    private var functions: [String: [EntityFunction]] = [:]
    private var accessoryOfEntity: [String: String] = [:]

    private var session: HomeAssistantSession?
    private var connected = false
    private var resync: Task<Void, Never>?
    private var resyncRefetch = false
    private var warnedDomains = Set<String>()
    private var warnedLoops = Set<String>()
    private var warnedHomeKit = false
    private var reportedOutage = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        settings = Settings(configuration.block)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// The token: the block's (sealed or resolved by the runtime), else the one Setup put in the vault.
    var accessToken: String? {
        settings.accessToken ?? context.credentials(as: Credentials.self)?.accessToken
    }

    public func start() async throws {
        guard let url = settings.url, let webSocket = HomeAssistantURL.webSocket(url) else {
            logger.warning("No Home Assistant address: set it up from Add accessories")
            return
        }
        guard accessToken != nil else {
            logger.warning("No access token for Home Assistant at \(Self.redacted(url)): set it up from Add accessories")
            return
        }
        tasks.add { [weak self] in await self?.run(webSocket) }
    }

    public func stop() async {
        tasks.cancelAll()
        resync?.cancel()
        await session?.close()
    }

    /// The address without credentials, for the log.
    static func redacted(_ url: String) -> String { HomeAssistantURL.base(url)?.absoluteString ?? url }

    // MARK: The connection (2.9)

    private func run(_ url: URL) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await connectOnce(url) { attempt = 0 }
            } catch HomeAssistantError.authInvalid(let message) {
                // Never retried in a loop: HA counts failed logins towards its IP ban (2.2).
                logger.error("Home Assistant refused the access token (\(message)): set the plugin up again")
                context.accountRefused("Home Assistant refused the access token")
                setConnected(false)
                return
            } catch {
                if !Task.isCancelled, !reportedOutage {
                    reportedOutage = true
                    logger.error("Cannot reach Home Assistant at \(url.host ?? "?"): \(error)")
                }
            }
            setConnected(false)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: dependencies.backoff.delay(attempt: attempt))
            attempt += 1
        }
    }

    private enum SessionEvent: Sendable {
        case state(JSONValue)
        case registry
    }

    /// One session: connect, authenticate, read everything, follow the events until the connection ends.
    private func connectOnce(_ url: URL, connectedNow: () -> Void) async throws {
        var options = WebSocket.Options(timeout: .seconds(15))
        if !settings.verifyTLS {
            let pinned = context.jsonFile("certificate.json", as: [String: String].self).load()?["fingerprint"]
            options.tls = TLSOptions(trust: pinned.map { .pinned($0) } ?? .any)
        }
        let socket = try await dependencies.connect(url, options)
        if !settings.verifyTLS, let real = socket as? WebSocket, let fingerprint = real.certificateFingerprint {
            try? context.jsonFile("certificate.json", as: [String: String].self).save(["fingerprint": fingerprint])
        }
        let session = HomeAssistantSession(socket: socket)
        let (closed, closedContinuation) = AsyncStream.makeStream(of: String.self)
        await session.start { reason in
            closedContinuation.yield(reason)
            closedContinuation.finish()
        }
        let (events, eventsContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
        var consumer: Task<Void, Never>?
        var pinger: Task<Void, Never>?
        defer {
            consumer?.cancel()
            pinger?.cancel()
            eventsContinuation.finish()
        }
        do {
            guard let token = accessToken else { throw HomeAssistantError.authInvalid("no access token") }
            try await session.authenticate(token: token, timeout: dependencies.authTimeout)
            context.accountAccepted()
            self.session = session
            let timeout = dependencies.commandTimeout
            _ = try? await session.command(["type": "supported_features", "features": ["coalesce_messages": 1]], timeout: timeout)
            config = ServerConfig(try await session.command(["type": "get_config"], timeout: timeout))
            if config.components.contains("homekit"), !warnedHomeKit {
                warnedHomeKit = true
                logger.warning("Home Assistant runs its own HomeKit bridge: entities it exposes may show twice in Apple Home; mirror them here (the mirror setting) or exclude them")
            }
            // Subscribed before the states are read, so no change is lost; the events wait in the stream (2.9).
            try await session.subscribe(eventType: "state_changed") { eventsContinuation.yield(.state($0)) }
            try await loadRegistries(session)
            try await loadStates(session)
            for type in ["entity_registry_updated", "device_registry_updated", "area_registry_updated"] where registriesAvailable {
                try? await session.subscribe(eventType: type) { _ in eventsContinuation.yield(.registry) }
            }
            reportedOutage = false
            let version = await session.version ?? config.version ?? ""
            logger.info("Connected to Home Assistant \(version) (\(config.locationName ?? "home")): \(states.count) entities")
            connectedNow()
            sync()
            setConnected(true)
            consumer = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
            pinger = Task { [weak self, dependencies] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: dependencies.pingInterval)
                    guard !Task.isCancelled else { return }
                    do {
                        try await session.command(["type": "ping"], timeout: dependencies.pongTimeout)
                    } catch {
                        await self?.logger.warning("Home Assistant did not answer a ping: reconnecting")
                        await session.close()
                        return
                    }
                }
            }
            if config.state != nil, config.state != "RUNNING" { scheduleResync(refetch: true, after: dependencies.notRunningRetry) }
            var reason = "closed"
            for await why in closed { reason = why }
            if !Task.isCancelled { logger.warning("Disconnected from Home Assistant: \(reason)") }
        } catch {
            self.session = nil
            await session.close()
            throw error
        }
        self.session = nil
        await session.close()
    }

    private func loadRegistries(_ session: HomeAssistantSession) async throws {
        let timeout = dependencies.commandTimeout
        do {
            // Independent commands: the session multiplexes them by id.
            async let entityRequest = session.command(["type": "config/entity_registry/list"], timeout: timeout)
            async let deviceRequest = session.command(["type": "config/device_registry/list"], timeout: timeout)
            async let areaRequest = session.command(["type": "config/area_registry/list"], timeout: timeout)
            let entityList = try await entityRequest
            let deviceList = try await deviceRequest
            let areaList = try? await areaRequest
            entities = Dictionary((entityList.arrayValue ?? []).compactMap(EntityEntry.init).map { ($0.entityID, $0) }) { first, _ in first }
            devices = Dictionary((deviceList.arrayValue ?? []).compactMap(DeviceEntry.init).map { ($0.id, $0) }) { first, _ in first }
            var names: [String: String] = [:]
            for area in areaList?.arrayValue ?? [] {
                if let id = area["area_id"]?.stringValue, let name = area["name"]?.stringValue { names[id] = name }
            }
            areas = names
            registriesAvailable = true
        } catch let error as HomeAssistantError where error.isUnavailableCommand {
            // A token without access to the registries: states only, each entity an accessory of its own (4.4).
            if registriesAvailable || !snapshotLoaded { logger.warning("The registries are not available to this token (\(error)): each entity is an accessory of its own") }
            registriesAvailable = false
            entities = [:]
            devices = [:]
            areas = [:]
        }
    }

    private func loadStates(_ session: HomeAssistantSession) async throws {
        let list = try await session.command(["type": "get_states"], timeout: dependencies.commandTimeout)
        var read: [String: EntityState] = [:]
        lastUpdated = [:]
        for item in list.arrayValue ?? [] {
            guard let state = EntityState(item) else { continue }
            read[state.entityID] = state
            if let updated = item["last_updated"]?.stringValue { lastUpdated[state.entityID] = updated }
        }
        states = read
        snapshotLoaded = true
    }

    private func setConnected(_ value: Bool) {
        connected = value
        for (_, item) in built { applyAvailability(item) }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .registry: scheduleResync(refetch: true)
        case .state(let event): stateChanged(event)
        }
    }

    private func stateChanged(_ event: JSONValue) {
        guard let data = event["data"], let entityID = data["entity_id"]?.stringValue else { return }
        guard let newState = data["new_state"], !newState.isNull, let state = EntityState(newState) else {
            // Removed.
            if states.removeValue(forKey: entityID) != nil, accessoryOfEntity[entityID] != nil { scheduleResync(refetch: false) }
            return
        }
        // An event older than the snapshot it was buffered behind changes nothing (2.9).
        if let updated = newState["last_updated"]?.stringValue {
            if let known = lastUpdated[entityID], updated < known { return }
            lastUpdated[entityID] = updated
        }
        let old = states[entityID]
        states[entityID] = state
        guard EntityFunctions.domains.contains(state.domain) else { return }
        if old == nil || EntityFunctions.shape(of: old!) != EntityFunctions.shape(of: state) || (old?.hasValue == false && accessoryOfEntity[entityID] == nil) {
            scheduleResync(refetch: old == nil && registriesAvailable && entities[entityID] == nil)
            return
        }
        apply(state)
    }

    private func apply(_ state: EntityState) {
        if state.hasValue { for function in functions[state.entityID] ?? [] { function.update(state) } }
        if let id = accessoryOfEntity[state.entityID], let item = built[id] { applyAvailability(item) }
    }

    /// No Response while disconnected, or while every entity behind the accessory is `unavailable` (4.5).
    private func applyAvailability(_ item: Built) {
        let unavailable = !connected || (!item.sources.isEmpty && item.sources.allSatisfy { states[$0]?.isUnavailable ?? true })
        if item.accessory.isUnavailable != unavailable { item.accessory.isUnavailable = unavailable }
    }

    private func scheduleResync(refetch: Bool, after delay: Duration? = nil) {
        resyncRefetch = resyncRefetch || refetch
        guard resync == nil else { return }
        let wait = delay ?? dependencies.resyncDelay
        resync = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.runResync()
        }
    }

    private func runResync() async {
        resync = nil
        let refetch = resyncRefetch
        resyncRefetch = false
        if refetch, let session {
            do {
                if let config = try? await session.command(["type": "get_config"], timeout: dependencies.commandTimeout) { self.config = ServerConfig(config) }
                try await loadRegistries(session)
                try await loadStates(session)
            } catch {
                logger.warning("Could not read Home Assistant again: \(error)")
            }
            if config.state != nil, config.state != "RUNNING" { scheduleResync(refetch: true, after: dependencies.notRunningRetry) }
        }
        sync()
    }

    // MARK: Service calls

    func callService(_ call: ServiceCall) async throws {
        guard let session else { throw HomeAssistantError.closed("not connected") }
        var message: [String: JSONValue] = ["type": "call_service", "domain": .string(call.domain), "service": .string(call.service)]
        if !call.data.isEmpty { message["service_data"] = .object(call.data) }
        if let entityID = call.entityID { message["target"] = ["entity_id": .string(entityID)] }
        logger.debug("\(call.domain).\(call.service) on \(call.entityID ?? "-")")
        try await session.command(message, timeout: dependencies.commandTimeout)
    }

    func link(for entityID: String) -> EntityLink {
        EntityLink(
            entityID: entityID,
            send: { [weak self] call in
                guard let self else { throw HomeAssistantError.closed("stopped") }
                try await self.callService(call)
            },
            batchWindow: dependencies.batchWindow, momentaryReset: dependencies.momentaryReset, fahrenheit: config.isFahrenheit,
            lockCode: settings.lockCode, alarmCode: settings.alarmCode)
    }

    // MARK: Building

    /// Brings the accessories in step with the server's view: builds what changed shape, removes what is gone, and shows
    /// the current values.
    func sync() {
        guard snapshotLoaded else { return }
        let plan = makePlan()
        for domain in plan.unsupported.subtracting(warnedDomains).sorted() {
            warnedDomains.insert(domain)
            logger.info("Entities of the \(domain) domain are not supported yet: left out")
        }
        for entityID in plan.loops.subtracting(warnedLoops).sorted() {
            warnedLoops.insert(entityID)
            logger.warning("Skipping \(entityID): Home Assistant has it from this bridge through HomeKit, publishing it again would loop")
        }
        var keep = Set<String>()
        for device in plan.devices where !context.isExcluded(device.deviceID) {
            for part in device.accessories {
                keep.insert(part.accessoryID)
                build(part, device: device)
            }
        }
        for id in built.keys where !keep.contains(id) {
            built.removeValue(forKey: id)
            tasks.add { [weak self] in await self?.removeIfGone(id) }
        }
        functions = [:]
        accessoryOfEntity = [:]
        for (id, item) in built {
            for function in item.functions {
                if function is BatteryFunction { continue }
                functions[function.entityID, default: []].append(function)
            }
            for source in item.sources { accessoryOfEntity[source] = id }
        }
        for item in built.values {
            if let battery = item.functions.first(where: { $0 is BatteryFunction }) {
                for source in item.sources where plan.batterySources.contains(source) { functions[source, default: []].append(battery) }
            }
        }
        for state in states.values where accessoryOfEntity[state.entityID] != nil { apply(state) }
        // What is kept is read when the removal runs, so an accessory a later sync added stays.
        tasks.add { [weak self] in await self?.removeStale() }
    }

    private func removeIfGone(_ id: String) async {
        guard built[id] == nil else { return }
        try? await context.remove(id: id)
    }

    /// Drops the accessories of the last run (restored from the cache) that the server no longer has.
    private func removeStale() async {
        _ = await context.removeAccessories(keeping: Set(built.keys))
    }

    private func build(_ part: AccessoryPlan, device: DevicePlan) {
        if let existing = built[part.accessoryID], existing.signature == part.signature { return }
        var made: [EntityFunction] = []
        var havePrimary = false
        for entity in part.entities {
            guard let state = states[entity.entityID] else { continue }
            if entity.batteryOnly { continue }
            guard let function = EntityFunctions.make(state, key: entity.key, isPrimary: !havePrimary, included: entity.explicitlyIncluded, link: link(for: state.entityID)) else { continue }
            havePrimary = true
            made.append(function)
        }
        if part.entities.contains(where: \.feedsBattery) {
            made.append(BatteryFunction(key: "battery", name: made.isEmpty ? device.name : nil))
        }
        guard !made.isEmpty else {
            if built.removeValue(forKey: part.accessoryID) != nil {
                let id = part.accessoryID
                tasks.add { [weak self] in await self?.removeIfGone(id) }
            }
            return
        }
        let services = made.flatMap(\.services)
        let accessory = Accessory(
            id: part.accessoryID, name: device.name, manufacturer: device.manufacturer, model: device.model, serialNumber: device.serialNumber,
            firmwareRevision: device.firmware, category: made.first?.category ?? .other, services: services)
        if part.mirrored { accessory.mirroredFrom = Self.mirrorSource }
        accessory.suggestedRoom = device.room
        if let cached = context.accessory(id: part.accessoryID) { accessory.takeValues(from: cached) }
        var controllers: [AdaptiveLightingController] = []
        if !part.mirrored {
            for case let light as LightFunction in made where light.canHaveAdaptiveLighting {
                if let controller = context.adaptiveLighting(for: light.service, accessoryID: part.accessoryID) {
                    light.attach(controller)
                    controllers.append(controller)
                }
            }
        }
        let isNew = built[part.accessoryID] == nil && context.accessory(id: part.accessoryID) == nil
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(device.name): \(error)")
            return
        }
        if isNew { logger.info("New accessory: \(device.name)\(part.mirrored ? " (mirrored, not in HomeKit)" : "")") }
        let item = Built(accessory: accessory, signature: part.signature, functions: made, sources: Set(part.entities.map(\.entityID)), controllers: controllers)
        built[part.accessoryID] = item
    }
}
