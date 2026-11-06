import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Which accessory id each entity has. The Homebridge plugin made one accessory per entity and named it after the entity
/// alone, so an entity keeps `esphome:<name>`; a second entity of the same name (on another device, or the same) gets
/// `<name>@<MAC>`, and `<name>@<MAC>#<key>` after that, rather than sharing the first's accessory. The ids taken are kept
/// in `entities.json`, so they do not move with the order devices answer in.
final class EntityDirectory: Sendable {
    /// Each id's suffix (after `esphome:`), with its owner `<MAC>/<key>`.
    private let claims: NIOLockedValueBox<[String: String]>
    private let warned = NIOLockedValueBox<Set<String>>([])
    private let dirty = NIOLockedValueBox(false)
    private let file: JSONFile<[String: String]>?

    init(file: JSONFile<[String: String]>?) {
        self.file = file
        claims = NIOLockedValueBox(file?.load() ?? [:])
    }

    static func owner(mac: String, deviceID: UInt32, key: UInt32) -> String {
        deviceID == 0 ? "\(mac)/\(String(key, radix: 16))" : "\(mac)/\(deviceID).\(String(key, radix: 16))"
    }

    /// The suffix of the entity's accessory id, and whether its name was another entity's (to warn once).
    func suffix(name: String, mac: String, deviceID: UInt32 = 0, key: UInt32) -> (suffix: String, shared: Bool) {
        let owner = Self.owner(mac: mac, deviceID: deviceID, key: key)
        let qualified = "\(name)@\(mac)"
        let candidates = name.isEmpty ? [qualified, "\(qualified)#\(String(key, radix: 16))"] : [name, qualified, "\(qualified)#\(String(key, radix: 16))"]
        let (suffix, changed) = claims.withLockedValue { claims -> (String, Bool) in
            // An entity keeps its id while its name stays; a renamed one lets the old go.
            if let mine = claims.first(where: { $0.value == owner })?.key {
                if candidates.contains(mine) { return (mine, false) }
                claims.removeValue(forKey: mine)
            }
            let free = candidates.first { claims[$0] == nil } ?? candidates[candidates.count - 1]
            claims[free] = owner
            return (free, true)
        }
        if changed { dirty.withLockedValue { $0 = true } }
        return (suffix, suffix != name)
    }

    /// Whether an entity holds this suffix.
    func isClaimed(_ suffix: String) -> Bool {
        claims.withLockedValue { $0[suffix] != nil }
    }

    /// Lets an id go: its entity is gone.
    func release(_ suffix: String) {
        claims.withLockedValue { _ = $0.removeValue(forKey: suffix) }
        dirty.withLockedValue { $0 = true }
    }

    /// Writes the claims made since the last save.
    func save() {
        guard let file, dirty.withLockedValue({ dirty in defer { dirty = false }; return dirty }) else { return }
        try? file.save(claims.withLockedValue { $0 })
    }

    /// Whether the warning about a shared name is still to give.
    func shouldWarn(_ suffix: String) -> Bool {
        warned.withLockedValue { $0.insert(suffix).inserted }
    }

    /// The MAC owning each suffix, for the accessories restored from the cache before their device answers.
    func suffixes(of mac: String) -> [String] {
        claims.withLockedValue { claims in claims.filter { $0.value.hasPrefix("\(mac)/") }.map(\.key) }
    }
}

/// What a device needs of its plugin.
struct DeviceEnvironment: Sendable {
    let context: PluginContext
    let directory: EntityDirectory
    let transport: any ESPHomeTransport
    let timing: ESPHomeTiming
    let blacklist: Set<String>
    let verbose: Bool
    /// Where a Bluetooth proxy's advertisements go; nil to leave them unsubscribed.
    let bluetooth: BluetoothHub?
    /// Tells the plugin which device a host turned out to be.
    let learned: @Sendable (_ origin: String, _ info: DeviceInfo) async -> Void
}

/// One ESPHome device: its connection, kept up with retries, and its entities' accessories.
actor ESPHomeDevice {
    enum Status: Equatable, Sendable {
        case connecting
        case connected
        case unreachable
        /// Stopped until its configuration changes: a rejected password or key.
        case failed
    }

    private(set) var endpoint: ESPHomeEndpoint
    /// `host:port` as configured, before an announcement gave its address: what the plugin learns its MAC under.
    let origin: String
    let retryMaximum: Duration
    private let environment: DeviceEnvironment
    private var logger: Logger { environment.context.logger }
    private var label: String { "\(endpoint.host):\(endpoint.port)" }

    private var link: ESPHomeLink?
    /// By `EntityInfo.entityID`: a key is unique within its sub-device only.
    private var bindings: [UInt64: EntityBinding] = [:]
    private var accessories: [UInt64: Accessory] = [:]
    private(set) var info: DeviceInfo?
    private(set) var mac: String?
    private(set) var status = Status.connecting
    private var everConnected = false
    private var outageLogged = false
    private var connectedThisRun = false
    private var excluded = false

    init(endpoint: ESPHomeEndpoint, origin: String? = nil, retryAfter: Duration, environment: DeviceEnvironment) {
        self.endpoint = endpoint
        self.origin = origin ?? ESPHomePlugin.hostKey(endpoint.host, endpoint.port)
        self.environment = environment
        retryMaximum = min(max(retryAfter, environment.timing.retryInitial), environment.timing.retryMaximum)
        mac = endpoint.expectedMAC
    }

    var isConnected: Bool { status == .connected }

    /// Connects and stays connected until cancelled, or until the device refuses the configured password or key.
    func run() async {
        if let mac { markCachedUnavailable(mac: mac) }
        var failures = 0
        var onAdvertisements: (@Sendable ([BluetoothAdvertisement]) async -> Void)?
        if let hub = environment.bluetooth {
            let proxy = label
            onAdvertisements = { advertisements in await hub.receive(advertisements, from: proxy) }
        }
        while !Task.isCancelled {
            connectedThisRun = false
            var delay: Duration = .zero
            do {
                try await ESPHomeSession.run(
                    endpoint: endpoint, transport: environment.transport, timing: environment.timing, logger: logger,
                    onReady: { ready in await self.ready(ready) }, onState: { kind, state in await self.show(kind, state) },
                    onAdvertisements: onAdvertisements)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled || excluded { break }
                delay = handle(error, failures: &failures)
            }
            disconnected()
            if status == .failed { break }
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { break }
            }
        }
        disconnected()
        if excluded { logger.info("\(label) is Excluded: not connecting") }
    }

    /// Logs a failure once per outage and says how long to wait before the next attempt.
    private func handle(_ error: any Error, failures: inout Int) -> Duration {
        let espError = error as? ESPHomeError
        if let espError, espError.needsConfiguration {
            status = .failed
            switch espError {
            case .invalidPassword, .passwordRequired:
                logger.error("The device at \(label) rejected the password: check the configured password")
            default:
                logger.error("The device at \(label) cannot be opened: \(espError.description)")
            }
            return .zero
        }
        if connectedThisRun {
            failures = 0
            if !outageLogged {
                logger.warning("Connection to \(label) lost (\(Self.describe(error))); values may be stale")
                outageLogged = true
            }
            return espError == .disconnectedByDevice ? environment.timing.rebootDelay : .zero
        }
        failures += 1
        status = .unreachable
        if !outageLogged {
            logger.warning("Cannot reach the ESPHome device at \(label): \(Self.describe(error))")
            outageLogged = true
        } else {
            logger.debug("Trying to reconnect to the device at \(label): \(Self.describe(error))")
        }
        switch espError {
        case .requiresEncryption, .usesPlaintext, .wrongDevice:
            return retryMaximum
        default:
            return Backoff(initial: environment.timing.retryInitial, factor: 1.8, maximum: retryMaximum).delay(attempt: min(failures - 1, 10))
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ESPHomeError { return error.description }
        if let error = error as? NoiseError { return error.description }
        return String(describing: error)
    }

    private func disconnected() {
        link = nil
        if status == .connected { status = .unreachable }
        for accessory in accessories.values { accessory.isUnavailable = true }
    }

    /// The device answered with its entities: bind each to its accessory.
    private func ready(_ ready: ESPHomeSession.Ready) async {
        let context = environment.context
        let deviceMAC = MACAddress.canonical(ready.info.mac) ?? ready.info.mac
        if !deviceMAC.isEmpty, context.isExcluded(deviceMAC) {
            excluded = true
            await ready.link.close()
            return
        }
        link = ready.link
        info = ready.info
        connectedThisRun = true
        if !deviceMAC.isEmpty {
            mac = deviceMAC
            endpoint.expectedMAC = deviceMAC
        }
        if everConnected, outageLogged { logger.info("Connection to \(label) re-established") }
        everConnected = true
        outageLogged = false
        status = .connected
        await environment.learned(origin, ready.info)

        let verbose: Logger.Level = environment.verbose ? .info : .debug
        logger.log(level: verbose, "\(label) is \(ready.info.name) (\(deviceMAC)), ESPHome \(ready.info.esphomeVersion), \(ready.entities.count) entities")
        for name in ready.unsupported { logger.info("\(name) is not supported") }
        var listed = Set<UInt64>()
        let owner = deviceMAC.isEmpty ? endpoint.host : deviceMAC
        let claimedBefore = Set(environment.directory.suffixes(of: owner))
        for entity in ready.entities {
            if environment.blacklist.contains(entity.name) {
                logger.log(level: verbose, "Skipping \(entity.name): blacklisted")
                continue
            }
            listed.insert(entity.entityID)
            if let binding = bindings[entity.entityID], binding.info == entity { continue }
            bind(entity, mac: owner, info: ready.info)
        }
        for id in bindings.keys where !listed.contains(id) {
            bindings.removeValue(forKey: id)
            accessories.removeValue(forKey: id)
        }
        // An entity renamed or gone, now or while the bridge was off: its old accessory leaves the bridge.
        let current = Set(accessories.values.map(\.id))
        for suffix in claimedBefore.union(environment.directory.suffixes(of: owner)) where !current.contains("\(ESPHomePlugin.platform):\(suffix)") {
            let id = "\(ESPHomePlugin.platform):\(suffix)"
            environment.directory.release(suffix)
            if context.accessory(id: id) != nil {
                logger.info("Removing \(id): the device no longer has it")
                try? await context.remove(id: id)
            }
        }
        environment.directory.save()
        for accessory in accessories.values { accessory.isUnavailable = false }
    }

    private func bind(_ entity: EntityInfo, mac: String, info: DeviceInfo) {
        let context = environment.context
        let (suffix, shared) = environment.directory.suffix(name: entity.name, mac: mac, deviceID: entity.deviceID, key: entity.key)
        if shared, environment.directory.shouldWarn(suffix) {
            let reason = entity.name.isEmpty ? "has no name" : "has the name of another entity"
            logger.warning("\(entity.name.isEmpty ? info.name : entity.name) on \(info.name) \(reason): its accessory is \(ESPHomePlugin.platform):\(suffix)")
        }
        let id = "\(ESPHomePlugin.platform):\(suffix)"
        let timing = environment.timing
        let subDevice = entity.deviceID
        let link = EntityLink(send: { [weak self] frame in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            var frame = frame
            // A sub-device's entity is addressed by its key and its device_id.
            if subDevice != 0, let field = EntityKind.deviceIDField(ofCommand: frame.type) {
                var deviceID = ProtobufWriter()
                deviceID.uint32(field, subDevice)
                frame.body += deviceID.bytes
            }
            try await self.send(frame)
        }, timing: timing)
        guard let binding = EntityBinding.make(entity, link: link, adaptiveLighting: { context.adaptiveLighting(for: $0, accessoryID: id) }) else {
            logger.info("\(entity.name) could not be mapped to HomeKit")
            if context.accessory(id: id) != nil { Task { try? await context.remove(id: id) } }
            return
        }
        let name = entity.name.isEmpty ? (info.friendlyName.isEmpty ? info.name : info.friendlyName) : entity.name
        let accessory = Accessory(
            id: id, name: name, manufacturer: info.manufacturer.isEmpty ? "ESPHome" : info.manufacturer,
            model: info.model.isEmpty ? "ESPHome" : info.model, serialNumber: mac, firmwareRevision: Self.firmwareRevision(info.esphomeVersion),
            category: binding.category, services: binding.services)
        if let cached = context.accessory(id: id) { accessory.takeValues(from: cached) }
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(name): \(error)")
            return
        }
        if bindings[entity.entityID] == nil { logger.info("\(name) discovered and set up") }
        bindings[entity.entityID] = binding
        accessories[entity.entityID] = accessory
    }

    /// ESPHome's version (`2025.1.0`, `2025.2.0-dev`) as HomeKit's x.y.z.
    static func firmwareRevision(_ version: String) -> String {
        let numbers = version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").prefix(3)
        return numbers.isEmpty ? "1.0.0" : numbers.joined(separator: ".")
    }

    private func show(_ kind: EntityKind, _ state: ProtobufMessage) {
        bindings[kind.entityID(ofState: state)]?.apply(state)
    }

    /// Sends a command, or answers No Response when the device is not connected or the write fails.
    func send(_ frame: ESPHomeFrame) async throws {
        guard let link else { throw HAPStatusError(.serviceCommunicationFailure) }
        do {
            try await link.send(frame)
        } catch {
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// Accessories of this device restored from the cache show No Response until it answers.
    private func markCachedUnavailable(mac: String) {
        let ids = Set(environment.directory.suffixes(of: mac).map { "\(ESPHomePlugin.platform):\($0)" })
        for accessory in environment.context.accessories where ids.contains(accessory.id) { accessory.isUnavailable = true }
    }
}
