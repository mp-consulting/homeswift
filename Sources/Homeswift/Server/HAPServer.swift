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

    struct State {
        var persisted: PersistedState
        var accessories: [Int: Accessory] = [:]
        var connections: [ObjectIdentifier: HAPConnection] = [:]
        var pairSetupOwner: ObjectIdentifier?
        var failedPairSetupAttempts = 0
        var serverChannel: (any Channel)?
    }

    public let primary: Accessory
    let options: Options
    let storage: any HAPStorage
    let logger: Logger
    let state: NIOLockedValueBox<State>
    let signingKey: Curve25519.Signing.PrivateKey
    let advertiser = BonjourAdvertiser()

    /// A bridge exposing several accessories. The bridge gets aid 1.
    public convenience init(bridge: Accessory, accessories: [Accessory], storage: any HAPStorage, options: Options = Options()) throws {
        try self.init(primary: bridge, bridged: accessories, storage: storage, options: options)
    }

    /// A single standalone accessory.
    public convenience init(accessory: Accessory, storage: any HAPStorage, options: Options = Options()) throws {
        try self.init(primary: accessory, bridged: [], storage: storage, options: options)
    }

    init(primary: Accessory, bridged: [Accessory], storage: any HAPStorage, options: Options) throws {
        self.primary = primary
        self.options = options
        self.storage = storage
        logger = options.logger

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

        state.withLockedValue { state in
            assign(primary, aid: 1, in: &state)
            for accessory in bridged { assign(accessory, aid: nil, in: &state) }
            refreshConfigurationNumber(in: &state)
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

    /// Adds a bridged accessory while running. HomeKit picks it up from the new configuration number.
    public func add(_ accessory: Accessory) throws {
        state.withLockedValue { state in
            assign(accessory, aid: nil, in: &state)
            refreshConfigurationNumber(in: &state)
        }
        try persist()
        updateAdvertisement()
    }

    /// Removes a bridged accessory while running.
    public func remove(_ accessory: Accessory) throws {
        state.withLockedValue { state in
            state.accessories[accessory.aid] = nil
            refreshConfigurationNumber(in: &state)
        }
        try persist()
        updateAdvertisement()
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
                    Task { await connection.run() }
                }
            }

        let preferred = options.port ?? state.withLockedValue { $0.persisted.port } ?? 0
        let channel = try await bind(bootstrap, port: preferred)
        let port = channel.localAddress?.port ?? preferred
        state.withLockedValue {
            $0.serverChannel = channel
            $0.persisted.port = port
        }
        try persist()
        logger.info("HAP server listening", metadata: ["port": "\(port)", "paired": "\(isPaired)"])

        if options.advertise {
            try advertiser.start(name: primary.name, port: port, txt: txtRecord())
        }
    }

    /// Stops advertising, disconnects controllers and closes the socket.
    public func stop() async {
        advertiser.stop()
        let (channel, connections) = state.withLockedValue { ($0.serverChannel, Array($0.connections.values)) }
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
            for candidate in Set([port, 0]) {
                if let channel = try? await bootstrap.bind(host: host, port: candidate).get() {
                    return channel
                }
            }
        }
        return try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
    }

    // MARK: Identifiers and database

    private func assign(_ accessory: Accessory, aid fixed: Int?, in state: inout State) {
        let aid: Int
        if let fixed {
            aid = fixed
        } else if let known = state.persisted.aids[accessory.id], known != 1 {
            aid = known
        } else {
            aid = max(1, state.persisted.aids.values.max() ?? 1) + 1
        }
        state.persisted.aids[accessory.id] = aid
        accessory.aidBox.withLockedValue { $0 = aid }

        let prefix = "\(aid)/"
        var next = (state.persisted.iids.filter { $0.key.hasPrefix(prefix) }.values.max() ?? 0) + 1
        func iid(for key: String) -> Int {
            if let known = state.persisted.iids[prefix + key] { return known }
            defer { next += 1 }
            state.persisted.iids[prefix + key] = next
            return next
        }
        for service in accessory.services {
            let serviceKey = "\(service.type.uuid.uuidString)/\(service.subtype ?? "")"
            service.iidBox.withLockedValue { $0 = iid(for: serviceKey) }
            for characteristic in service.characteristics {
                characteristic.attach(aid: aid, iid: iid(for: serviceKey + "/" + characteristic.type.uuid.uuidString), observer: self)
            }
        }
        state.accessories[aid] = accessory
    }

    private func refreshConfigurationNumber(in state: inout State) {
        let structure = database(accessories: state.accessories, includeValues: false)
        var json = JSONWriter(capacity: 64 * 1024)
        structure.write(to: &json)
        let hash = SHA256.hash(data: json.bytes).map { String(format: "%02x", $0) }.joined()
        if !state.persisted.databaseHash.isEmpty, state.persisted.databaseHash != hash {
            state.persisted.configurationNumber = state.persisted.configurationNumber % 65535 + 1
        }
        state.persisted.databaseHash = hash
    }

    func database(includeValues: Bool) -> AccessoryDatabase {
        let accessories = state.withLockedValue { $0.accessories }
        return database(accessories: accessories, includeValues: includeValues)
    }

    private func database(accessories: [Int: Accessory], includeValues: Bool) -> AccessoryDatabase {
        AccessoryDatabase(accessories: accessories.sorted { $0.key < $1.key }.map { aid, accessory in
            AccessoryDatabase.AccessoryJSON(aid: aid, services: accessory.services.map { service in
                AccessoryDatabase.ServiceJSON(
                    iid: service.iid,
                    type: service.type.uuid.shortForm,
                    characteristics: service.characteristics.map {
                        CharacteristicJSON(describing: $0, includeValue: includeValues, includeMeta: true)
                    },
                    primary: service.isPrimary ? true : nil,
                    hidden: service.isHidden ? true : nil
                )
            })
        })
    }

    func accessory(aid: Int) -> Accessory? {
        state.withLockedValue { $0.accessories[aid] }
    }

    func characteristic(aid: Int, iid: Int) -> Characteristic? {
        guard let accessory = state.withLockedValue({ $0.accessories[aid] }) else { return nil }
        for service in accessory.services {
            if let match = service.characteristics.first(where: { $0.iid == iid }) { return match }
        }
        return nil
    }

    // MARK: Persistence and advertising

    func persist() throws {
        let data = try state.withLockedValue { try JSONEncoder().encode($0.persisted) }
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
        advertiser.update(txt: txtRecord())
    }

    // MARK: Connections

    func unregister(_ connection: HAPConnection) {
        state.withLockedValue { state in
            state.connections[connection.id] = nil
            if state.pairSetupOwner == connection.id { state.pairSetupOwner = nil }
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

extension HAPServer: CharacteristicObserver {
    func characteristicDidChange(_ characteristic: Characteristic, value: HAPValue, origin: ObjectIdentifier?) {
        let key = CharacteristicKey(aid: characteristic.aid, iid: characteristic.iid)
        let connections = state.withLockedValue { Array($0.connections.values) }
        let targets = connections.filter { $0.id != origin && $0.isSubscribed(to: key) }
        guard !targets.isEmpty else { return }
        let event = CharacteristicsJSON(characteristics: [CharacteristicJSON(aid: key.aid, iid: key.iid, value: value)])
        let body = HTTPResponse.json(200, event)
        for connection in targets { connection.sendEvent(body) }
    }
}

struct CharacteristicKey: Hashable {
    var aid: Int
    var iid: Int
}
