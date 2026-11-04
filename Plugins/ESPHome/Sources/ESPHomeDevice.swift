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
    private let file: JSONFile<[String: String]>?

    init(file: JSONFile<[String: String]>?) {
        self.file = file
        claims = NIOLockedValueBox(file?.load() ?? [:])
    }

    static func owner(mac: String, key: UInt32) -> String { "\(mac)/\(String(key, radix: 16))" }

    /// The suffix of the entity's accessory id, and whether its name was another entity's (to warn once).
    func suffix(name: String, mac: String, key: UInt32) -> (suffix: String, shared: Bool) {
        let owner = Self.owner(mac: mac, key: key)
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
        if changed, let file { try? file.save(claims.withLockedValue { $0 }) }
        return (suffix, suffix != name)
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
    /// Tells the plugin which device a host turned out to be.
    let learned: @Sendable (_ host: String, _ port: Int, _ info: DeviceInfo) async -> Void
}

/// One ESPHome device: its connection, kept up with retries, and its entities' accessories.
actor ESPHomeDevice {
    enum Status: Equatable, Sendable {
        case connecting
        case connected
        case unreachable
        /// Stopped until its configuration changes: a rejected password or key.
        case failed(String)
    }

    private(set) var endpoint: ESPHomeEndpoint
    let retryMaximum: Duration
    private let environment: DeviceEnvironment
    private var logger: Logger { environment.context.logger }
    private var label: String { "\(endpoint.host):\(endpoint.port)" }

    private var link: ESPHomeLink?
    private var bindings: [UInt32: EntityBinding] = [:]
    private var accessories: [UInt32: Accessory] = [:]
    private(set) var info: DeviceInfo?
    private(set) var mac: String?
    private(set) var status = Status.connecting
    private var everConnected = false
    private var outageLogged = false
    private var connectedThisRun = false
    private var excluded = false

    init(endpoint: ESPHomeEndpoint, retryAfter: Duration, environment: DeviceEnvironment) {
        self.endpoint = endpoint
        self.environment = environment
        retryMaximum = min(max(retryAfter, environment.timing.retryInitial), environment.timing.retryMaximum)
        mac = endpoint.expectedMAC
    }

    var isConnected: Bool { status == .connected }

    /// Connects and stays connected until cancelled, or until the device refuses the configured password or key.
    func run() async {
        if let mac { markCachedUnavailable(mac: mac) }
        var failures = 0
        while !Task.isCancelled {
            connectedThisRun = false
            var delay: Duration = .zero
            do {
                try await ESPHomeSession.run(
                    endpoint: endpoint, transport: environment.transport, timing: environment.timing, logger: logger,
                    onReady: { ready in await self.ready(ready) }, onState: { kind, state in await self.show(state) })
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled || excluded { break }
                delay = handle(error, failures: &failures)
            }
            disconnected()
            if case .failed = status { break }
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
            status = .failed(espError.description)
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
        await environment.learned(endpoint.host, endpoint.port, ready.info)

        let verbose: Logger.Level = environment.verbose ? .info : .debug
        logger.log(level: verbose, "\(label) is \(ready.info.name) (\(deviceMAC)), ESPHome \(ready.info.esphomeVersion), \(ready.entities.count) entities")
        for name in ready.unsupported { logger.info("\(name) is not supported") }
        var listed = Set<UInt32>()
        for entity in ready.entities {
            listed.insert(entity.key)
            if environment.blacklist.contains(entity.name) {
                logger.log(level: verbose, "Skipping \(entity.name): blacklisted")
                continue
            }
            if let binding = bindings[entity.key], binding.info == entity { continue }
            bind(entity, mac: deviceMAC.isEmpty ? endpoint.host : deviceMAC, info: ready.info)
        }
        for key in bindings.keys where !listed.contains(key) {
            bindings.removeValue(forKey: key)
            accessories.removeValue(forKey: key)
        }
        for accessory in accessories.values { accessory.isUnavailable = false }
    }

    private func bind(_ entity: EntityInfo, mac: String, info: DeviceInfo) {
        let context = environment.context
        let (suffix, shared) = environment.directory.suffix(name: entity.name, mac: mac, key: entity.key)
        if shared, environment.directory.shouldWarn(suffix) {
            let reason = entity.name.isEmpty ? "has no name" : "has the name of another entity"
            logger.warning("\(entity.name.isEmpty ? info.name : entity.name) on \(info.name) \(reason): its accessory is \(ESPHomePlugin.platform):\(suffix)")
        }
        let id = "\(ESPHomePlugin.platform):\(suffix)"
        let timing = environment.timing
        let link = EntityLink(send: { [weak self] frame in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await self.send(frame)
        }, timing: timing)
        guard let binding = EntityBinding.make(entity, link: link, adaptiveLighting: { context.adaptiveLighting(for: $0, accessoryID: id) }) else {
            logger.info("\(entity.name) could not be mapped to HomeKit")
            if context.accessories.contains(where: { $0.id == id }) { Task { try? await context.remove(id: id) } }
            return
        }
        let name = entity.name.isEmpty ? (info.friendlyName.isEmpty ? info.name : info.friendlyName) : entity.name
        let accessory = Accessory(
            id: id, name: name, manufacturer: info.manufacturer.isEmpty ? "ESPHome" : info.manufacturer,
            model: info.model.isEmpty ? "ESPHome" : info.model, serialNumber: mac, firmwareRevision: Self.firmwareRevision(info.esphomeVersion),
            category: binding.category, services: binding.services)
        if let cached = context.accessories.first(where: { $0.id == id }) { accessory.takeValues(from: cached) }
        do {
            try context.add(accessory)
        } catch {
            logger.error("Could not add \(name): \(error)")
            return
        }
        if bindings[entity.key] == nil { logger.info("\(name) discovered and set up") }
        bindings[entity.key] = binding
        accessories[entity.key] = accessory
    }

    /// ESPHome's version (`2025.1.0`, `2025.2.0-dev`) as HomeKit's x.y.z.
    static func firmwareRevision(_ version: String) -> String {
        let numbers = version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").prefix(3)
        return numbers.isEmpty ? "1.0.0" : numbers.joined(separator: ".")
    }

    private func show(_ state: ProtobufMessage) {
        bindings[state.fixed32(1)]?.apply(state)
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

    /// The accessories this device shows, by entity key (tests).
    var boundAccessories: [UInt32: Accessory] { accessories }
}
