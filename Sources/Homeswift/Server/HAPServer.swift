import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A HomeKit accessory server over IP.
///
/// Give it a single accessory, or a bridge accessory plus the accessories it bridges:
///
/// ```swift
/// let lamp = Accessory(id: "lamp", name: "Lamp", category: .lightbulb,
///                      services: [Service(.lightbulb, optional: [.brightness])])
/// let server = try HAPServer(bridge: Accessory(id: "bridge", name: "My Bridge", category: .bridge, services: []),
///                            accessories: [lamp], storage: FileStorage(name: "my-bridge"))
/// try await server.run()
/// ```
public final class HAPServer: @unchecked Sendable {
    public struct Options: Sendable {
        /// How the server is advertised over Bonjour.
        public enum Advertiser: String, Sendable {
            /// The system's dns_sd (mDNSResponder on macOS, Avahi on Linux), or the built-in responder when it
            /// is unavailable.
            case system
            /// The built-in mDNS responder (`MDNSResponder`), HAP-NodeJS's ciao.
            case builtIn
        }

        /// Overrides the stored setup code. Defaults to the stored one, or a random code on first launch.
        public var setupCode: SetupCode?
        /// Overrides the stored device ID, six hex octets such as `0E:1A:2B:3C:4D:5E` (Homebridge's
        /// `username`). Defaults to the stored one, or a random ID on first launch. A different ID is a
        /// new accessory: the pairings are dropped and a new signing key made, so controllers add it again.
        public var deviceID: String?
        /// The TCP port. Defaults to the port used last time, or one the system picks.
        public var port: Int?
        /// Advertise over Bonjour. Turn off for tests.
        public var advertise: Bool
        public var advertiser: Advertiser = .system
        /// Interface names or IPv4 addresses the built-in responder advertises on (Homebridge's `bind`); empty
        /// for every interface.
        public var interfaces: [String] = []
        /// How long a connection holds characteristic events to send them as one message: a plugin updating 30 lights
        /// sends a few events, not 30. Button presses go at once. HAP-NodeJS waits 250ms (`EVENT_COALESCING_DELAY`);
        /// a burst arrives within a few milliseconds, and a quarter of a second shows on another iPhone.
        public var eventCoalescingDelay: TimeAmount = .milliseconds(50)
        public var logger: Logger

        public init(
            setupCode: SetupCode? = nil, deviceID: String? = nil, port: Int? = nil, advertise: Bool = true,
            logger: Logger = Logger(label: "homeswift")
        ) {
            self.setupCode = setupCode
            self.deviceID = deviceID
            self.port = port
            self.advertise = advertise
            self.logger = logger
        }
    }

    /// Called when a characteristic's value changes, from HomeKit or from the accessory's own code.
    public typealias ChangeObserver = @Sendable (_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue) -> Void

    /// How long a call took: a controller's read or write of `/characteristics` (`request`), or an accessory's
    /// read or write handler, the plugin reaching its device (`handler`).
    public struct Timing: Sendable {
        public enum Kind: String, Sendable { case request, handler }
        public let kind: Kind
        /// The accessories it was about: those a request read or wrote, or the one whose handler ran.
        public let accessories: [Accessory]
        public let duration: Duration
    }

    /// Called after every timed call (`Timing`).
    public typealias TimingObserver = @Sendable (Timing) -> Void

    struct State {
        var persisted: PersistedState
        var accessories: [Int: Accessory] = [:]
        /// The ids of accessories kept out of HomeKit by choice (`setHiddenFromHomeKit`), as mirrored ones are.
        var hiddenFromHomeKit: Set<String> = []
        var connections: [ObjectIdentifier: HAPConnection] = [:]
        var changeObservers: [ChangeObserver] = []
        var structureObservers: [@Sendable () -> Void] = []
        var pairSetupOwner: ObjectIdentifier?
        var failedPairSetupAttempts = 0
        var serverChannel: (any Channel)?
        var idleCheck: RepeatedTask?
        /// `persisted.databaseHash` is behind the database: accessories with new ids were added since, each with
        /// its bump of the number. A settle, shortly after or at `stop()`, catches the hash up.
        var hashBehind = false
        var hashSettleScheduled = false
        /// Removals since the last settle not yet saved nor advertised: the settle does both, once for the burst.
        var announceBehind = false
        /// The `GET /accessories` body without its values, and what it was built from: `databaseVersion` (the
        /// server's accessories) and `StructureGeneration` (their services).
        var databaseTemplate: DatabaseTemplate?
        var databaseVersion = 0
    }

    private let primaryBox: NIOLockedValueBox<Accessory>
    /// The accessory with aid 1: the bridge, or the one standalone accessory.
    public var primary: Accessory { primaryBox.withLockedValue { $0 } }
    let options: Options
    let storage: any HAPStorage
    let logger: Logger
    let state: NIOLockedValueBox<State>
    /// What requests look up (`Lookup`), apart from `state`: a request takes this lock once, to copy a reference,
    /// where it took the state lock for every characteristic it named, which 16 connections queued on.
    private let lookupBox = NIOLockedValueBox<(lookup: Lookup?, generation: Int)>((nil, 0))
    private let timingObservers = NIOLockedValueBox<[TimingObserver]>([])
    let signingKey: Curve25519.Signing.PrivateKey
    let advertiser = BonjourAdvertiser()
    let builtInAdvertiser: MDNSAdvertiser
    /// Whether the built-in responder advertises the server rather than dns_sd.
    let usesBuiltInAdvertiser = NIOLockedValueBox(false)

    /// A bridge exposing several accessories. The bridge gets aid 1.
    public convenience init(bridge: Accessory, accessories: [Accessory], storage: any HAPStorage, options: Options = Options()) throws {
        try self.init(primary: bridge, bridged: accessories, storage: storage, options: options)
    }

    /// A single standalone accessory.
    public convenience init(accessory: Accessory, storage: any HAPStorage, options: Options = Options()) throws {
        try self.init(primary: accessory, bridged: [], storage: storage, options: options)
    }

    init(primary: Accessory, bridged: [Accessory], storage: any HAPStorage, options: Options) throws {
        Self.addProtocolInformation(to: primary)
        primaryBox = NIOLockedValueBox(primary)
        self.options = options
        self.storage = storage
        logger = options.logger
        builtInAdvertiser = MDNSAdvertiser(interfaces: options.interfaces, logger: options.logger)

        var persisted: PersistedState
        if let data = try storage.load() {
            persisted = try JSONDecoder().decode(PersistedState.self, from: data)
        } else {
            persisted = PersistedState.new(setupCode: options.setupCode)
        }
        if let code = options.setupCode { persisted.setupCode = code.rawValue }
        if let deviceID = options.deviceID?.uppercased(), deviceID != persisted.deviceID {
            if !persisted.pairings.isEmpty {
                options.logger.warning("Device ID changed: the bridge is a new accessory and must be paired again", metadata: ["from": "\(persisted.deviceID)", "to": "\(deviceID)"])
            }
            persisted.deviceID = deviceID
            persisted.signingKey = Curve25519.Signing.PrivateKey().rawRepresentation
            persisted.pairings.removeAll()
        }
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: persisted.signingKey)
        state = NIOLockedValueBox(State(persisted: persisted))

        // The configuration number is not touched here: accessories may still be added before `start()`,
        // which hashes the database once. Hashing it now, bridge alone, bumped the number at every launch.
        state.withLockedValue { state in
            assign(primary, aid: 1, in: &state)
            for accessory in bridged { assign(accessory, aid: nil, in: &state) }
        }
        try persist()
    }

    // MARK: Public surface

    public var setupCode: SetupCode {
        state.withLockedValue { SetupCode($0.persisted.setupCode)! }
    }

    /// The `X-HM://` payload to render as a QR code for pairing.
    public var setupURI: String {
        state.withLockedValue { makeSetupURI(code: SetupCode($0.persisted.setupCode)!, category: primary.category, setupID: $0.persisted.setupID) }
    }

    public var isPaired: Bool { state.withLockedValue { !$0.persisted.pairings.isEmpty } }

    public var pairings: [Pairing] { state.withLockedValue { $0.persisted.pairings } }

    public var deviceID: String { state.withLockedValue { $0.persisted.deviceID } }

    /// The bound port, once started.
    public var port: Int? { state.withLockedValue { $0.serverChannel?.localAddress?.port } }

    public var accessories: [Accessory] {
        state.withLockedValue { $0.accessories.sorted { $0.key < $1.key }.map(\.value) }
    }

    /// The accessory with this id, or nil: a lookup by its aid, not a scan of `accessories` (which sorts them).
    public func accessory(id: String) -> Accessory? {
        state.withLockedValue { state in state.persisted.aids[id].flatMap { state.accessories[$0] } }
    }

    /// Adds a bridged accessory, before or while running. Once running, HomeKit picks it up from the new
    /// configuration number; before, `start()` hashes the whole database once.
    public func add(_ accessory: Accessory) throws {
        defer { structureChanged() }
        // A mirrored accessory gets its aid and iids for the web UI and the MCP server, but HomeKit's database, its
        // configuration number and the advertisement stay as they are: no bump, no write, no new TXT record.
        // Only when it replaces one HomeKit could see under the same id does the database change.
        if accessory.mirroredFrom != nil {
            let running = state.withLockedValue { state -> Bool in
                let previous = state.persisted.aids[accessory.id].flatMap { state.accessories[$0] }
                _ = assign(accessory, aid: nil, in: &state)
                guard let previous, previous.mirroredFrom == nil else { return false }
                return refreshIfRunning(&state)
            }
            if running {
                try persist()
                updateAdvertisement()
            }
            return
        }
        let (running, changed) = state.withLockedValue { state -> (Bool, Bool) in
            let before = (state.persisted.configurationNumber, state.persisted.databaseHash)
            let previous = state.persisted.aids[accessory.id].flatMap { state.accessories[$0] }
            let assigned = assign(accessory, aid: nil, in: &state)
            let running: Bool
            if state.serverChannel != nil, !assigned, let previous, structure(of: previous) == structure(of: accessory) {
                // It replaces an accessory of the same shape under the same ids: the database is as it was, and
                // hashing all of it again for every accessory a plugin adds at launch cost N² (seconds for 300).
                running = true
            } else if state.serverChannel != nil, assigned {
                // New ids: the database changed whatever its hash, so the number goes up now; the hash, as costly
                // for every accessory of a burst, is caught up once the burst is over.
                state.persisted.configurationNumber = state.persisted.configurationNumber % 65535 + 1
                state.hashBehind = true
                running = true
            } else {
                running = refreshIfRunning(&state)
            }
            return (running, assigned || before != (state.persisted.configurationNumber, state.persisted.databaseHash))
        }
        scheduleHashSettle()
        // Nothing to save or announce when the ids, the database and its number are as they were: a plugin
        // replacing its cached accessories at launch, one by one.
        guard running, changed else { return }
        try persist()
        updateAdvertisement()
    }

    /// Replaces the primary accessory (a standalone accessory that changed shape) under the same identity:
    /// the iids of the services it keeps stay, HomeKit sees the rest through the configuration number.
    public func replace(primary accessory: Accessory) throws {
        defer { structureChanged() }
        Self.addProtocolInformation(to: accessory)
        let running = state.withLockedValue { state in
            state.accessories[1] = nil
            assign(accessory, aid: 1, in: &state)
            return refreshIfRunning(&state)
        }
        primaryBox.withLockedValue { $0 = accessory }
        guard running else { return }
        try persist()
        updateAdvertisement()
    }

    /// Every accessory a controller pairs with carries a Protocol Information service.
    private static func addProtocolInformation(to accessory: Accessory) {
        guard accessory[.protocolInformation] == nil else { return }
        accessory.append(Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")]))
    }

    /// Removes a bridged accessory, before or while running. One HomeKit sees bumps the number at once; the hash, the
    /// save and the advertisement wait for the settle, once for a burst: a plugin removing N stale accessories hashed
    /// the whole database N times, under the lock every request takes.
    public func remove(_ accessory: Accessory) throws {
        defer { structureChanged() }
        state.withLockedValue { state in
            guard let removed = state.accessories.removeValue(forKey: accessory.aid) else { return }
            structureMoved(&state)
            guard state.serverChannel != nil, removed.mirroredFrom == nil, !state.hiddenFromHomeKit.contains(removed.id) else { return }
            state.persisted.configurationNumber = state.persisted.configurationNumber % 65535 + 1
            state.hashBehind = true
            state.announceBehind = true
        }
        scheduleHashSettle()
    }

    /// Refreshes the configuration number while the server runs; before `start()` the database is still
    /// being assembled. Returns whether it runs.
    private func refreshIfRunning(_ state: inout State) -> Bool {
        guard state.serverChannel != nil else { return false }
        refreshConfigurationNumber(in: &state)
        return true
    }

    /// Keeps the accessories with these ids out of HomeKit, as mirrored ones are (`Accessory.mirroredFrom`): they keep
    /// their aids and iids for the web UI, the MCP server and Matter, but leave `GET /accessories` and controllers
    /// cannot read, write or subscribe to them. A change bumps the configuration number, so the Home app drops them,
    /// or adds them back as new accessories. Never the primary accessory.
    public func setHiddenFromHomeKit(_ ids: Set<String>) throws {
        let primaryID = primary.id
        let ids = ids.subtracting([primaryID])
        let running = state.withLockedValue { state -> Bool? in
            guard state.hiddenFromHomeKit != ids else { return nil }
            state.hiddenFromHomeKit = ids
            structureMoved(&state)
            return refreshIfRunning(&state)
        }
        guard let running else { return }
        if running {
            try persist()
            updateAdvertisement()
        }
        structureChanged()
    }

    /// Whether the accessory with this id is kept out of HomeKit by `setHiddenFromHomeKit`.
    public func isHiddenFromHomeKit(_ id: String) -> Bool {
        state.withLockedValue { $0.hiddenFromHomeKit.contains(id) }
    }

    /// Registers an observer called after an accessory is added, replaced or removed, whether or not it runs.
    public func observeStructure(_ observer: @escaping @Sendable () -> Void) {
        state.withLockedValue { $0.structureObservers.append(observer) }
    }

    private func structureChanged() {
        for observer in state.withLockedValue({ $0.structureObservers }) { observer() }
    }

    /// Registers an observer of characteristic changes on every accessory of this server.
    public func observeChanges(_ observer: @escaping ChangeObserver) {
        state.withLockedValue { $0.changeObservers.append(observer) }
    }

    /// Registers an observer of how long controllers' requests and the accessories' handlers take.
    public func observeTimings(_ observer: @escaping TimingObserver) {
        timingObservers.withLockedValue { $0.append(observer) }
    }

    /// Tells the timing observers that a call about the accessories `aids` began at `start` and ended now.
    func recordTiming(_ kind: Timing.Kind, aids: some Sequence<Int>, since start: ContinuousClock.Instant) {
        let duration = ContinuousClock.now - start
        let observers = timingObservers.withLockedValue { $0 }
        guard !observers.isEmpty else { return }
        let all = lookup().accessories
        let accessories = aids.compactMap { all[$0] }
        let timing = Timing(kind: kind, accessories: accessories, duration: duration)
        for observer in observers { observer(timing) }
    }

    /// Forgets every pairing and disconnects all controllers, so the accessory can be added again.
    public func resetPairings() throws {
        let connections = state.withLockedValue { state in
            state.persisted.pairings.removeAll()
            return Array(state.connections.values)
        }
        try persist()
        connections.forEach { $0.close() }
        updateAdvertisement()
    }

    /// Binds the socket and starts advertising.
    public func start() async throws {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                let connection = HAPConnection(channel: channel, server: self)
                self.state.withLockedValue { $0.connections[connection.id] = connection }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(connection.inboundHandler)
                    // The connection's task runs on its channel's event loop where the runtime allows it: a request
                    // and its answer then need no hop from the loop to the task and back, and no wake-up between them.
                    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) {
                        Task(executorPreference: EventLoopTaskExecutor(channel.eventLoop)) { await connection.run() }
                    } else {
                        Task { await connection.run() }
                    }
                }
            }

        let preferred = options.port ?? state.withLockedValue { $0.persisted.port } ?? 0
        let channel = try await bind(bootstrap, port: preferred)
        let port = channel.localAddress?.port ?? preferred
        let idleCheck = channel.eventLoop.scheduleRepeatedTask(initialDelay: .minutes(1), delay: .minutes(1)) { [weak self] _ in
            self?.closeIdleConnections()
        }
        state.withLockedValue {
            // The database is complete now: one hash, one bump when it changed since the last run.
            refreshConfigurationNumber(in: &$0)
            $0.serverChannel = channel
            $0.idleCheck = idleCheck
            $0.persisted.port = port
        }
        try persist()
        logger.info("HAP server listening", metadata: ["port": "\(port)", "paired": "\(isPaired)"])

        if options.advertise {
            startAdvertising(port: port)
        }
    }

    private func startAdvertising(port: Int) {
        if options.advertiser == .system {
            do {
                try advertiser.start(name: primary.name, port: port, txt: txtRecord())
                return
            } catch {
                // Avahi not running, or out of reach (a Synology package, a container): HomeKit must still find
                // the bridge.
                logger.warning("Bonjour unavailable (\(error)); advertising with the built-in mDNS responder")
            }
        }
        usesBuiltInAdvertiser.withLockedValue { $0 = true }
        builtInAdvertiser.start(name: primary.name, port: port, txt: txtRecord())
    }

    /// Stops advertising, disconnects controllers and closes the socket.
    public func stop() async {
        // A hash still behind is stored now, so the next launch does not count the same changes again.
        settleHash()
        advertiser.stop()
        await builtInAdvertiser.stop()
        usesBuiltInAdvertiser.withLockedValue { $0 = false }
        let (channel, connections, idleCheck) = state.withLockedValue { state in
            defer { state.idleCheck = nil }
            return (state.serverChannel, Array(state.connections.values), state.idleCheck)
        }
        idleCheck?.cancel()
        connections.forEach { $0.close() }
        try? await channel?.close()
        state.withLockedValue { $0.serverChannel = nil }
    }

    /// Starts the server and keeps it running until the task is cancelled.
    public func run() async throws {
        try await start()
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {}
        await stop()
    }

    private func bind(_ bootstrap: ServerBootstrap, port: Int) async throws -> any Channel {
        for host in ["::", "0.0.0.0"] {
            // The configured port first; a Set would try them in a random order and land on a random port.
            for candidate in (port == 0 ? [0] : [port, 0]) {
                if let channel = try? await bootstrap.bind(host: host, port: candidate).get() {
                    return channel
                }
            }
        }
        return try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
    }

    // MARK: Identifiers and database

    /// Gives the accessory its aid and iids, the ones it had when known; returns whether any was new.
    @discardableResult
    private func assign(_ accessory: Accessory, aid fixed: Int?, in state: inout State) -> Bool {
        let aid: Int
        if let fixed {
            aid = fixed
        } else if let known = state.persisted.aids[accessory.id], known != 1 {
            aid = known
        } else {
            aid = max(1, state.persisted.aids.values.max() ?? 1) + 1
        }
        var changed = state.persisted.aids[accessory.id] != aid
        state.persisted.aids[accessory.id] = aid
        accessory.aidBox.withLockedValue { $0 = aid }

        let prefix = "\(aid)/"
        // The next free iid, looked for only when one is needed: every server's iids would be scanned for each
        // accessory otherwise, though at launch they are all known.
        var next: Int?
        func iid(for key: String) -> Int {
            if let known = state.persisted.iids[prefix + key] { return known }
            let free = next ?? (state.persisted.iids.filter { $0.key.hasPrefix(prefix) }.values.max() ?? 0) + 1
            next = free + 1
            state.persisted.iids[prefix + key] = free
            changed = true
            return free
        }
        for service in accessory.services {
            let serviceKey = "\(service.type.uuid.uuidString)/\(service.subtype ?? "")"
            service.iidBox.withLockedValue { $0 = iid(for: serviceKey) }
            for characteristic in service.characteristics {
                characteristic.attach(aid: aid, iid: iid(for: serviceKey + "/" + characteristic.type.uuid.uuidString), server: self)
            }
        }
        state.accessories[aid] = accessory
        structureMoved(&state)
        return changed
    }

    private func refreshConfigurationNumber(in state: inout State) {
        let hash = databaseHash(state)
        // Behind, the stored hash is from before the last adds and cannot tell whether this change changed anything:
        // a bump then, at worst one more than needed.
        if state.hashBehind || !state.persisted.databaseHash.isEmpty && state.persisted.databaseHash != hash {
            state.persisted.configurationNumber = state.persisted.configurationNumber % 65535 + 1
        }
        state.persisted.databaseHash = hash
        state.hashBehind = false
    }

    private func databaseHash(_ state: State) -> String {
        let structure = database(accessories: state.accessories, hidden: state.hiddenFromHomeKit, includeValues: false)
        var json = JSONWriter(capacity: 64 * 1024)
        structure.write(to: &json)
        return Secrets.hex(SHA256.hash(data: json.bytes))
    }

    /// Catches the hash up a quarter of a second after the last add with new ids or removal, once for the burst.
    private func scheduleHashSettle() {
        let first = state.withLockedValue { state -> Bool in
            guard state.hashBehind, !state.hashSettleScheduled else { return false }
            state.hashSettleScheduled = true
            return true
        }
        guard first else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.settleHash()
        }
    }

    /// Stores the hash of the database as it is, without another bump: its changes have had theirs. Saves, and
    /// advertises the number when removals have not.
    func settleHash() {
        let (settled, announce) = state.withLockedValue { state -> (Bool, Bool) in
            state.hashSettleScheduled = false
            defer { state.announceBehind = false }
            guard state.hashBehind else { return (false, state.announceBehind) }
            state.persisted.databaseHash = databaseHash(state)
            state.hashBehind = false
            return (true, state.announceBehind)
        }
        if settled || announce { try? persist() }
        if announce { updateAdvertisement() }
    }

    /// One accessory's part of the hashed database: its aid, services, characteristics and their metadata.
    private func structure(of accessory: Accessory) -> [UInt8] {
        var json = JSONWriter(capacity: 2048)
        database(accessories: [accessory.aid: accessory], hidden: [], includeValues: false).write(to: &json)
        return json.bytes
    }

    /// The `GET /accessories` body: the cached template (built again when the accessories or their structure changed)
    /// with the values as they are now. Building it took most of the request: the permissions, types and metadata
    /// of every characteristic, for every controller that reconnects.
    func accessoriesBody() -> [UInt8] {
        let template = databaseTemplate()
        var json = JSONWriter(capacity: template.bytes.count + template.characteristics.count * 8)
        var start = 0
        for (hole, characteristic) in zip(template.holes, template.characteristics) {
            json.raw(template.bytes[start..<hole])
            json.bare(characteristic.value)
            start = hole
        }
        json.raw(template.bytes[start...])
        return json.bytes
    }

    private func databaseTemplate() -> DatabaseTemplate {
        let generation = StructureGeneration.current
        let (cached, version, accessories, hidden) = state.withLockedValue { state in
            (state.databaseTemplate, state.databaseVersion, state.accessories, state.hiddenFromHomeKit)
        }
        if let cached, cached.version == version, cached.generation == generation { return cached }
        // Built outside the lock; kept only when nothing changed meanwhile.
        var characteristics: [Characteristic]? = []
        let database = database(accessories: accessories, hidden: hidden, includeValues: false, holes: &characteristics)
        var json = JSONWriter(capacity: 64 * 1024)
        database.write(to: &json)
        let template = DatabaseTemplate(
            bytes: json.bytes, holes: json.holes, characteristics: characteristics ?? [], version: version, generation: generation)
        state.withLockedValue { state in
            if state.databaseVersion == version, StructureGeneration.current == generation { state.databaseTemplate = template }
        }
        return template
    }

    func database(includeValues: Bool) -> AccessoryDatabase {
        let (accessories, hidden) = state.withLockedValue { ($0.accessories, $0.hiddenFromHomeKit) }
        return database(accessories: accessories, hidden: hidden, includeValues: includeValues)
    }

    /// Mirrored accessories (`Accessory.mirroredFrom`) stay out, HomeKit has them already, and those `hidden` from it.
    private func database(accessories: [Int: Accessory], hidden: Set<String>, includeValues: Bool) -> AccessoryDatabase {
        var holes: [Characteristic]?
        return database(accessories: accessories, hidden: hidden, includeValues: includeValues, holes: &holes)
    }

    /// With `holes`, each readable characteristic gets a hole for its value (`DatabaseTemplate`), and is appended.
    private func database(
        accessories: [Int: Accessory], hidden: Set<String>, includeValues: Bool, holes: inout [Characteristic]?
    ) -> AccessoryDatabase {
        AccessoryDatabase(accessories: accessories.filter { $0.value.mirroredFrom == nil && !hidden.contains($0.value.id) }.sorted { $0.key < $1.key }.map { aid, accessory in
            AccessoryDatabase.AccessoryJSON(aid: aid, services: accessory.services.map { service in
                AccessoryDatabase.ServiceJSON(
                    iid: service.iid,
                    type: service.type.uuid.shortForm,
                    characteristics: service.characteristics.map {
                        var entry = CharacteristicJSON(describing: $0, includeValue: includeValues, includeMeta: true)
                        if holes != nil, $0.type.permissions.contains(.pairedRead) {
                            entry.valueHole = true
                            holes?.append($0)
                        }
                        return entry
                    },
                    primary: service.isPrimary ? true : nil,
                    hidden: service.isHidden ? true : nil,
                    linked: service.linked.isEmpty ? nil : service.linked.map(\.iid)
                )
            })
        })
    }

    /// The accessory a controller names; never a mirrored or hidden one, which HomeKit does not see.
    func accessory(aid: Int) -> Accessory? {
        state.withLockedValue { state in
            state.accessories[aid].flatMap { $0.mirroredFrom == nil && !state.hiddenFromHomeKit.contains($0.id) ? $0 : nil }
        }
    }

    func characteristic(aid: Int, iid: Int) -> Characteristic? {
        lookup().characteristics[CharacteristicKey(aid: aid, iid: iid)]
    }

    /// The characteristics controllers can name and the accessories by aid, built again after the accessories changed.
    func lookup() -> Lookup {
        let generation = lookupBox.withLockedValue { box -> Int? in box.lookup == nil ? box.generation : nil }
        guard let generation else { return lookupBox.withLockedValue { $0.lookup! } }
        let (accessories, hidden) = state.withLockedValue { ($0.accessories, $0.hiddenFromHomeKit) }
        var characteristics: [CharacteristicKey: Characteristic] = [:]
        for (aid, accessory) in accessories where accessory.mirroredFrom == nil && !hidden.contains(accessory.id) {
            for service in accessory.services {
                for characteristic in service.characteristics {
                    characteristics[CharacteristicKey(aid: aid, iid: characteristic.iid)] = characteristic
                }
            }
        }
        let lookup = Lookup(characteristics: characteristics, accessories: accessories)
        // Kept only when nothing changed since the generation was read: a change made meanwhile may be missing.
        lookupBox.withLockedValue { if $0.generation == generation { $0.lookup = lookup } }
        return lookup
    }

    /// The accessories or their ids changed: the cached `GET /accessories` body and the lookup are built again. Called
    /// inside `state`'s lock; `lookup()` never holds both.
    private func structureMoved(_ state: inout State) {
        state.databaseVersion += 1
        lookupBox.withLockedValue {
            $0.lookup = nil
            $0.generation += 1
        }
    }

    // MARK: Persistence and advertising

    func persist() throws {
        let data = state.withLockedValue { $0.persisted.encoded() }
        try storage.save(data)
    }

    func txtRecord() -> [(String, String)] {
        state.withLockedValue { state in
            let persisted = state.persisted
            return [
                ("c#", String(persisted.configurationNumber)),
                ("ff", "0"),
                ("id", persisted.deviceID),
                ("md", primary.name),
                ("pv", "1.1"),
                ("s#", "1"),
                ("sf", persisted.pairings.isEmpty ? "1" : "0"),
                ("ci", String(primary.category.rawValue)),
                ("sh", SetupID.hash(setupID: persisted.setupID, deviceID: persisted.deviceID)),
            ]
        }
    }

    func updateAdvertisement() {
        guard options.advertise else { return }
        if usesBuiltInAdvertiser.withLockedValue({ $0 }) {
            builtInAdvertiser.update(txt: txtRecord())
        } else {
            advertiser.update(txt: txtRecord())
        }
    }

    // MARK: Connections

    func unregister(_ connection: HAPConnection) {
        state.withLockedValue { state in
            state.connections[connection.id] = nil
            if state.pairSetupOwner == connection.id { state.pairSetupOwner = nil }
        }
    }

    /// From this many connections on, those idle for `maxConnectionIdleTime` are closed (HAP-NodeJS's
    /// EventedHTTPServer). HAP servers must not send TCP keepalives, which wake iOS devices, so a controller that left
    /// the network without closing its connection would otherwise keep it, and its socket, for good.
    static let idleConnectionLimit = 16
    static let maxConnectionIdleTime = TimeAmount.hours(1)

    /// Closes the connections idle for an hour or more, when there are `idleConnectionLimit` or more.
    func closeIdleConnections(now: NIODeadline = .now()) {
        let connections = state.withLockedValue { Array($0.connections.values) }
        guard connections.count >= Self.idleConnectionLimit else { return }
        for connection in connections where now - connection.lastActivity >= Self.maxConnectionIdleTime {
            logger.debug("Closing an idle connection", metadata: ["controller": "\(connection.controllerID ?? "-")"])
            connection.close()
        }
    }

    func closeConnections(controllers: Set<String>?) {
        let connections = state.withLockedValue { Array($0.connections.values) }
        for connection in connections {
            guard let controller = connection.controllerID else { continue }
            if controllers == nil || controllers!.contains(controller) { connection.close() }
        }
    }
}

extension HAPServer {
    func characteristicDidChange(_ characteristic: Characteristic, value: HAPValue, origin: ObjectIdentifier?) {
        let key = CharacteristicKey(aid: characteristic.aid, iid: characteristic.iid)
        let (connections, observers, accessory, hidden) = state.withLockedValue { state in
            let accessory = state.accessories[key.aid]
            return (Array(state.connections.values), state.changeObservers, accessory, accessory.map { state.hiddenFromHomeKit.contains($0.id) } ?? false)
        }
        if let accessory {
            for observer in observers { observer(accessory, characteristic, value) }
        }
        // A subscription made before it was hidden hears nothing more: HomeKit no longer has it.
        guard !hidden else { return }
        // As HAP-NodeJS, button presses are delivered at once (they take the queued events with them), the rest after
        // `eventCoalescingDelay`.
        let uuid = characteristic.type.uuid
        let immediate = uuid == CharacteristicType.buttonEvent.uuid || uuid == CharacteristicType.programmableSwitchEvent.uuid
        for connection in connections where connection.id != origin {
            connection.queueEvent(key, value: value, immediate: immediate, delay: options.eventCoalescingDelay)
        }
    }
}

struct CharacteristicKey: Hashable {
    var aid: Int
    var iid: Int
}

/// Runs a task's jobs on one event loop: a connection's work stays on the thread its channel's I/O runs on.
/// Nothing in a connection's path may block (NIO refuses `wait()` there); its awaits still go where they go.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
final class EventLoopTaskExecutor: TaskExecutor {
    let eventLoop: any EventLoop

    init(_ eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// The `GET /accessories` body with a hole where each readable characteristic's value goes (`HAPServer.accessoriesBody`).
struct DatabaseTemplate: Sendable {
    var bytes: [UInt8]
    var holes: [Int]
    /// The characteristics whose values fill the holes, in order.
    var characteristics: [Characteristic]
    var version: Int
    var generation: UInt64
}

/// What a request looks up (`HAPServer.lookup()`): the characteristics controllers can name, by aid and iid, and every
/// accessory by aid.
struct Lookup: Sendable {
    var characteristics: [CharacteristicKey: Characteristic]
    var accessories: [Int: Accessory]
}
