import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// V2C Trydan EV chargers on the local network, read and driven over their HTTP interface (port 80, no account, no
/// cloud), polled for changes: each charger an Outlet (charging allowed, in use, Eve power and energy), a Fan v2 for the
/// charge current in amperes, a Lock Mechanism that disables it, and a Contact Sensor for the car (README.md).
///
/// A new plugin with no Homebridge counterpart, written from docs/clean-room/V2CTrydan.md. Chargers are reached by
/// address: `devices` lists them as a Homebridge-style list, and what the bridge writes is the canonical shape, each
/// charger's settings in `_accessories` by its Device Id (its `ID`), its `host` among them (V2CTrydanSetup.swift).
public actor V2CTrydanPlugin: HomeswiftPlugin {
    public struct Configuration: Codable, Sendable {
        /// A charger reached by address.
        public struct Device: Codable, Sendable, Equatable {
            public var host: String?
            public var name: String?
            /// Its Device Id, when known (Setup writes it); otherwise learned from its first answer.
            public var id: String?

            public init(host: String?, name: String? = nil, id: String? = nil) {
                self.host = host
                self.name = name
                self.id = id
            }
        }

        public var name: String?
        /// Seconds between `/RealTimeData` reads: 10 by default, 5 at least.
        public var pollingInterval: Int?
        /// Seconds per request: 5 by default.
        public var timeout: Int?
        public var devices: [Device]?
    }

    /// What the plugin uses to reach the chargers; tests swap it for a fake.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient(maximumBodySize: TrydanClient.maximumBody)
        var timing = TrydanTiming()
    }

    /// A charger to run: where it is, and its Device Id when the configuration knows it.
    struct Target: Sendable, Equatable {
        var host: String
        var deviceID: String?
        var name: String?
    }

    public static let platform = "V2CTrydan"
    public static let name = "V2C Trydan"
    public static let icon: String? = "bolt"
    public static let summary: String? = "Trydan EV chargers on the local network: charging, current, lock and power"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingInterval = 10
    static let defaultTimeout = 5
    static let defaultName = "V2C Trydan"
    static let chargerKind = "charger"

    let configuration: Configuration
    let context: PluginContext
    /// What each charger keeps across restarts, by Device Id (`chargers.json`).
    let memories: PersistedDictionary<ChargerMemory>
    let dependencies: Dependencies
    let tasks = TaskBag()
    /// The chargers running, by host key (`hostKey`).
    private(set) var chargers: [String: TrydanCharger] = [:]
    /// The host key of each Device Id on the bridge, for duplicates.
    private var owners: [String: String] = [:]
    /// Device Ids whose accessory the bridge refused: tried again at each poll, logged once until it goes on it.
    private var addFailures: Set<String> = []
    /// The Device Id each charger of `devices` without one answered with, by host key: what `canonicalSettings` writes.
    private(set) var learnedIDs: [String: String] = [:]
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        memories = context.persistedDictionary("chargers.json", of: ChargerMemory.self, autosave: ChargerMemory.autosave)
    }

    var pollingInterval: Duration {
        max(dependencies.timing.second * max(configuration.pollingInterval ?? Self.defaultPollingInterval, 1), dependencies.timing.minimumPollingInterval)
    }

    var timeout: Duration { dependencies.timing.second * min(max(configuration.timeout ?? Self.defaultTimeout, 1), 60) }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// `host` as a key: lowercase, port 80 left out.
    static func hostKey(_ host: String) -> String {
        (TrydanIdentity.normalizedHost(host) ?? host.trimmingCharacters(in: .whitespaces)).lowercased()
    }

    public func start() async throws {
        for target in targets() { await run(target) }
    }

    public func stop() async {
        tasks.cancelAll()
        chargers.removeAll()
    }

    /// The chargers to run: those of `_accessories` with a host, then `devices`; a host or a Device Id once only, an
    /// Excluded one left out. A `devices` entry's host wins over `_accessories`' for its Device Id (Setup writes it there).
    func targets() -> [Target] {
        var targets: [Target] = []
        var hosts: Set<String> = [], ids: Set<String> = []
        var fromList: [String: Target] = [:]
        for device in configuration.devices ?? [] {
            guard let raw = device.host, let host = TrydanIdentity.normalizedHost(raw) else {
                logger.warning("Skipping a charger with an invalid address in devices", metadata: ["host": "\(device.host ?? "")"])
                continue
            }
            let id = device.id.flatMap(TrydanIdentity.deviceID) ?? learnedIDs[Self.hostKey(host)]
            let target = Target(host: host, deviceID: id, name: device.name?.trimmingCharacters(in: .whitespaces).nonEmpty)
            if let id, fromList[id] == nil { fromList[id] = target }
            if id == nil { targets.append(target) }
        }
        var ordered: [Target] = []
        for (deviceID, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key }) {
            if let listed = fromList.removeValue(forKey: deviceID) {
                ordered.append(listed)
                continue
            }
            guard let raw = settings.decode(ChargerSettings.self)?.host, let host = TrydanIdentity.normalizedHost(raw) else { continue }
            ordered.append(Target(host: host, deviceID: deviceID))
        }
        ordered += fromList.values.sorted { ($0.deviceID ?? "") < ($1.deviceID ?? "") }
        var result: [Target] = []
        for target in ordered + targets {
            if let id = target.deviceID {
                if context.isExcluded(id) { continue }
                guard ids.insert(id).inserted else { continue }
            }
            guard hosts.insert(Self.hostKey(target.host)).inserted else {
                logger.warning("Two chargers have the address \(target.host): only the first runs")
                continue
            }
            result.append(target)
        }
        return result
    }

    /// The charger's settings: its Accessory Settings.
    func settings(for deviceID: String?) -> ChargerSettings {
        deviceID.flatMap { context.accessorySettings(for: $0).decode(ChargerSettings.self) } ?? ChargerSettings()
    }

    private func run(_ target: Target) async {
        let charger = TrydanCharger(
            host: target.host, deviceID: target.deviceID, name: target.name ?? Self.defaultName, settings: settings(for: target.deviceID),
            transport: dependencies.transport, interval: pollingInterval, timeout: timeout, timing: dependencies.timing, context: context, memories: memories, tasks: tasks)
        let key = Self.hostKey(target.host)
        chargers[key] = charger
        if let deviceID = target.deviceID {
            // On the bridge at once, from the cache, values filled once it answers.
            await attach(charger, deviceID: deviceID, name: target.name)
        }
        tasks.add { [weak self] in
            // Until stopped, or until it answers as an Excluded charger (`answered` lets it go).
            while !Task.isCancelled, let self, await self.isRunning(charger, key: key) {
                if await charger.refresh() != nil { await self.answered(charger) }
                let delay = await charger.nextDelay()
                try? await Task.sleep(for: delay)
            }
        }
    }

    func isRunning(_ charger: TrydanCharger, key: String) -> Bool { chargers[key] === charger }

    /// After a read: a charger not on the bridge yet goes on it under the `ID` it gave; one whose shape changed is rebuilt.
    func answered(_ charger: TrydanCharger) async {
        if let deviceID = await charger.deviceID, await charger.isOnBridge {
            if await charger.needsRebuild { await attach(charger, deviceID: deviceID, name: nil) }
            return
        }
        guard let report = await charger.report else { return }
        let host = charger.host
        let deviceID = report.deviceID(host: host)
        if report.id.flatMap(TrydanIdentity.deviceID) == nil {
            logger.info("The charger at \(host) gives no ID: it is keyed by its address (\(deviceID)), and becomes a new accessory if the address changes")
        }
        learnedIDs[Self.hostKey(host)] = deviceID
        if context.isExcluded(deviceID) {
            logger.debug("Ignoring excluded charger", metadata: ["deviceID": "\(deviceID)"])
            chargers[Self.hostKey(host)] = nil
            return
        }
        let name = (configuration.devices ?? []).first { Self.hostKey($0.host ?? "") == Self.hostKey(host) }?.name?.nonEmpty
        await attach(charger, deviceID: deviceID, name: name)
    }

    private func attach(_ charger: TrydanCharger, deviceID: String, name: String?) async {
        let key = Self.hostKey(charger.host)
        if let owner = owners[deviceID], owner != key {
            logger.error("The chargers at \(owner) and \(charger.host) have the same ID \(deviceID): only the first runs")
            chargers[key] = nil
            return
        }
        owners[deviceID] = key
        let id = Self.accessoryID(deviceID: deviceID)
        let cached = context.accessory(id: id)
        let name = name ?? cached?.name ?? Self.defaultName
        do {
            let first = !(await charger.isOnBridge)
            let attached = try await charger.attach(deviceID: deviceID, name: name, settings: settings(for: deviceID), cached: cached)
            if attached { addFailures.remove(deviceID) }
            if attached, first {
                let firmware = await charger.report?.firmwareVersion ?? "unknown"
                logger.info("Added charger", metadata: ["charger": "\(name)", "host": "\(charger.host)", "deviceID": "\(deviceID)", "firmware": "\(firmware)"])
            }
        } catch {
            // Tried again at each poll: said once.
            if addFailures.insert(deviceID).inserted {
                logger.error("Could not add \(name) to the bridge: \(error)")
            } else {
                logger.debug("Could not add \(name) to the bridge: \(error)")
            }
        }
    }

    /// The charger with this Device Id.
    func charger(deviceID: String) async -> TrydanCharger? {
        for charger in chargers.values where await charger.deviceID == deviceID { return charger }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
