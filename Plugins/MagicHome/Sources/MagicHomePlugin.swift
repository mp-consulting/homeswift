import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Magic Home (Zengge, LEDENET) Wi-Fi lights, controllers and sockets on the local network: found by the UDP broadcast
/// `HF-A11ASSISTHREAD` on port 48899, driven over TCP 5577 with the protocol of their family, read every 30 seconds (or
/// told by those that send their changes). No cloud, no account.
///
/// A block of `homebridge-magichome-dynamic-platform` loads unchanged; written from the functional spec in
/// docs/clean-room/MagicHome.md. Each device is an accessory whose Device Id is its MAC (12 digits, uppercase), the seed
/// of the Homebridge plugin's UUID. See README.md in this directory.
public actor MagicHomePlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Pruning: Decodable, Sendable {
            public var pruneMissingCachedAccessories: Bool?
            public var restartsBeforeMissingAccessoriesPruned: Int?
            public var pruneAllAccessoriesNextRestart: Bool?
        }

        /// The option names are the Homebridge plugin's, misspellings included.
        public struct WhiteEffects: Decodable, Sendable {
            public var simultaniousDevicesColorWhite: Bool?
            public var colorWhiteThreshold: Double?
            public var colorWhiteThresholdSimultaniousDevices: Double?
            public var colorOffThresholdSimultaniousDevices: Double?
        }

        public struct DeviceManagement: Decodable, Sendable {
            /// `blacklist` or `whitelist`.
            public var blacklistOrWhitelist: String?
            /// MACs (12 hexadecimal digits).
            public var blacklistedUniqueIDs: [String]?
        }

        public struct AdvancedOptions: Decodable, Sendable {
            /// A scan every 30 seconds; true by default.
            public var periodicDiscovery: Bool?
            /// New devices named `<Bulb|Strip|Switch|LED> <last 6 of the MAC>`.
            public var namesWithMacAddress: Bool?
            /// 1 errors to 5 trace; 3 by default.
            public var logLevel: Int?
            /// More broadcast addresses for the scans.
            public var additionalSubnets: [String]?
        }

        public var name: String?
        public var pruning: Pruning?
        public var whiteEffects: WhiteEffects?
        public var deviceManagement: DeviceManagement?
        public var advancedOptions: AdvancedOptions?
        /// Devices by address, for those the broadcast does not reach: each gets the probe directly.
        public var addresses: [String]?
        /// A switch per built-in pattern on the lights that play them; off by default, so accessories stay as they were.
        public var effects: Bool?
        /// The patterns' speed, 0 (slowest) to 100 (fastest); 50 by default.
        public var effectSpeed: Int?
    }

    /// What the plugin uses to reach devices; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any MagicHomeTransport = MagicHomeTCPTransport()
        /// The scan's socket: port 48899 (older devices answer only there), any port when it is taken.
        var bindDiscovery: @Sendable () async throws -> any MagicHomeDiscoverySocket = {
            do {
                return try await UDPSocket.bind(port: MagicHomeDiscovery.port, reuseAddress: true, reusePort: true, broadcast: true)
            } catch {
                return try await UDPSocket.bind(port: 0, broadcast: true)
            }
        }
        var networks: @Sendable () -> [IPv4Network] = { localIPv4Networks() }
        var ownAddresses: @Sendable () -> Set<String> = { MagicHomeDiscovery.ownAddresses() }
        var timing = MagicHomeTiming()
    }

    public static let platform = "homebridge-magichome-dynamic-platform"
    public static let name = "Magic Home"
    public static let icon: String? = "bulb"
    public static let summary: String? = "Magic Home Wi-Fi lights, LED controllers and sockets on the local network"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// Scans in a row while none answers, at start (section 5.1).
    static let startScans = 6

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let effects: MagicHomeWhiteEffects
    let log: MagicHomeLog
    private let tasks = TaskBag()

    /// The devices, by Device Id.
    private(set) var devices: [String: MagicHomeDevice] = [:]
    /// Each device's poll loop.
    private var polls: [String: Task<Void, Never>] = [:]
    /// Each light's Adaptive Lighting, kept here: the lightbulb holds it weakly.
    private(set) var adaptiveLighting: [String: AdaptiveLightingController] = [:]
    /// What the plugin keeps of each device (`devices.json`).
    let records: PersistedDictionary<MagicHomeRecord>
    /// Every device a scan heard, the ones left out included, for Setup.
    private(set) var seen: [String: DiscoveredDevice] = [:]
    /// Devices being added: a second reply meanwhile does not add them again.
    private var adding: Set<String> = []
    /// Devices that did not answer or that the plugin does not know, by Device Id: not asked again at that address until
    /// `retryRejected` has passed, and warned about once.
    private var rejected: [String: (address: String, until: ContinuousClock.Instant)] = [:]
    /// Devices the lists leave out that were warned about.
    private var refusedWarned: Set<String> = []
    /// The most devices kept from the scans' replies, which anyone on the network can send.
    static let maximumSeen = 256
    /// The most devices the plugin adds: a HomeKit bridge takes 150 accessories, and a reply can claim any MAC.
    static let maximumDevices = 149
    /// The scan running, which a second asker waits for rather than binding the port again.
    private var scanning: Task<[MagicHomeFound], Never>?
    private(set) var scans = 0
    private(set) var isStarted = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        records = context.persistedDictionary("devices.json")
        var effects = MagicHomeWhiteEffects()
        if let white = configuration.whiteEffects {
            effects.simultaneous = white.simultaniousDevicesColorWhite ?? effects.simultaneous
            effects.colorWhiteThreshold = white.colorWhiteThreshold ?? effects.colorWhiteThreshold
            effects.mixThreshold = white.colorWhiteThresholdSimultaniousDevices ?? effects.mixThreshold
            effects.offThreshold = white.colorOffThresholdSimultaniousDevices ?? effects.offThreshold
        }
        self.effects = effects
        log = MagicHomeLog(logger: context.logger, level: min(max(configuration.advancedOptions?.logLevel ?? 3, 1), 5))
    }

    public func start() async throws {
        isStarted = true
        await prune()
        // A cached accessory the lists now leave out (a whitelist without it) goes; Excluded ones the runtime keeps out.
        let prefix = MagicHomeAccessory.accessoryID("")
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) {
            let id = String(accessory.id.dropFirst(prefix.count))
            guard !isAllowed(id) else { continue }
            log.warning("Removing \(accessory.name): \(listMode == .whitelist ? "not whitelisted" : "blacklisted")")
            try? await context.remove(id: accessory.id)
            records[id] = nil
        }
        // The devices kept from before are controllable at once, before a scan finds them (section 5.1, step 3), their
        // first polls spread over the interval, so twenty lights are not read in the same instant every time.
        let kept = records.values.sorted(by: { $0.key < $1.key }).filter { isAllowed($0.key) && !context.isExcluded($0.key) }
        for (index, (id, record)) in kept.enumerated() {
            guard let profile = MagicHomeProfile.make(model: record.model, version: record.version, modeByte: record.mode) else { continue }
            let first = dependencies.timing.poll * (Double(index) / Double(kept.count))
            _ = await add(id: id, record: record, profile: profile, state: nil, firstPoll: first)
        }
        tasks.add { [weak self] in await self?.runDiscovery() }
    }

    public func stop() async {
        // The polls are among the tasks.
        tasks.cancelAll()
        polls.removeAll()
        for device in devices.values { await device.stop() }
        // Let go, not disabled: a running schedule stays saved and resumes at the next start.
        adaptiveLighting.removeAll()
        do { try records.flush() } catch { log.error("Could not save devices.json: \(error)") }
    }

    // MARK: Pruning (section 5.1)

    /// `pruneAllAccessoriesNextRestart` removes every accessory; `pruneMissingCachedAccessories` those no scan heard for
    /// `restartsBeforeMissingAccessoriesPruned` launches. Each launch counts one for every device until it is heard.
    private func prune() async {
        let pruning = configuration.pruning
        if pruning?.pruneAllAccessoriesNextRestart == true {
            for accessory in context.accessories {
                log.warning("Pruning \(accessory.name): pruneAllAccessoriesNextRestart is on (turn it off again)")
                try? await context.remove(id: accessory.id)
            }
            for id in records.values.keys { records[id] = nil }
        } else {
            let limit = max(pruning?.restartsBeforeMissingAccessoriesPruned ?? 3, 1)
            for (id, record) in records.values {
                var record = record
                record.restartsSinceSeen += 1
                records[id] = record
                guard pruning?.pruneMissingCachedAccessories == true, record.restartsSinceSeen >= limit else { continue }
                let accessoryID = MagicHomeAccessory.accessoryID(id)
                log.warning("Pruning \(context.accessory(id: accessoryID)?.name ?? id): not seen for \(record.restartsSinceSeen) restarts")
                records[id] = nil
                if context.accessory(id: accessoryID) != nil { try? await context.remove(id: accessoryID) }
            }
        }
    }

    // MARK: Discovery

    /// Where the probe goes: each interface's broadcast, `additionalSubnets` and `addresses`.
    var targets: [String] {
        MagicHomeDiscovery.targets(networks: dependencies.networks(), extra: (configuration.advancedOptions?.additionalSubnets ?? []) + (configuration.addresses ?? []))
    }

    /// The scans at start (again while none answers, six at most), then one every 30 seconds with `periodicDiscovery`.
    private func runDiscovery() async {
        var found = await scanAndHandle()
        var attempts = 1
        while found == 0, attempts < Self.startScans, !Task.isCancelled {
            log.debug("No device answered the scan: scanning again")
            found = await scanAndHandle()
            attempts += 1
        }
        guard configuration.advancedOptions?.periodicDiscovery ?? true else { return }
        let interval = dependencies.timing.periodicDiscovery
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            _ = await scanAndHandle()
        }
    }

    /// One scan and what it found added or followed; the number of devices that answered.
    @discardableResult
    func scanAndHandle() async -> Int {
        let found = await scan()
        // At once: a new device that does not answer takes seconds, which the others do not wait for.
        await withTaskGroup(of: Void.self) { group in
            for device in found { group.addTask { await self.handle(device) } }
        }
        return found.count
    }

    /// One scan, shared with a caller that asks while it runs.
    @discardableResult
    func scan() async -> [MagicHomeFound] {
        if let scanning { return await scanning.value }
        let dependencies = dependencies, targets = targets, log = log
        let task = Task<[MagicHomeFound], Never> {
            let socket: any MagicHomeDiscoverySocket
            do {
                socket = try await dependencies.bindDiscovery()
            } catch {
                log.error("Could not open the discovery socket: \(error)")
                return []
            }
            log.debug("Scanning \(targets.joined(separator: ", "))")
            return await MagicHomeDiscovery.scan(on: socket, targets: targets, window: dependencies.timing.scanWindow, ownAddresses: dependencies.ownAddresses())
        }
        scanning = task
        let found = await task.value
        scanning = nil
        scans += 1
        for device in found {
            let announcement = device.announcement
            log.debug("Discovered \(announcement.mac) at \(announcement.address), \(announcement.module)")
            remember(device)
        }
        return found
    }

    /// A device a scan heard, for Setup.
    private func remember(_ found: MagicHomeFound) {
        let id = found.announcement.mac
        guard seen[id] != nil || seen.count < Self.maximumSeen else { return }
        let model = found.version?.model.flatMap { MagicHomeModel.table[$0]?.description } ?? found.announcement.module
        let refused = !isAllowed(id)
        var device = seen[id] ?? DiscoveredDevice(deviceID: id, name: id, kind: nil)
        device.name = context.accessorySettings(for: id).name ?? context.accessory(id: MagicHomeAccessory.accessoryID(id))?.name ?? model
        device.model = model
        device.address = found.announcement.address
        device.isSetUp = !refused
        device.excludedBySettings = refused
        if let modelByte = found.version?.model ?? records[id]?.model {
            device.kind = MagicHomeProfile.make(model: modelByte, version: found.version?.version ?? 0, modeByte: 0)?.deviceKind
        }
        seen[id] = device
    }

    /// A device a scan heard: followed to its address when known, else asked for its state and added.
    private func handle(_ found: MagicHomeFound) async {
        let announcement = found.announcement
        let id = announcement.mac
        guard isAllowed(id) else {
            if refusedWarned.count < Self.maximumSeen, refusedWarned.insert(id).inserted {
                log.warning("\(id) is \(listMode == .whitelist ? "not whitelisted" : "blacklisted"): left out")
            }
            if devices[id] != nil { await forget(id) }
            return
        }
        if let device = devices[id] {
            await device.seen(at: announcement.address)
            return
        }
        // An Excluded device is not reached (the runtime would not add it anyway); one being added is not added twice.
        guard !context.isExcluded(id), adding.insert(id).inserted else { return }
        defer { adding.remove(id) }
        if let rejection = rejected[id], rejection.address == announcement.address, ContinuousClock.now < rejection.until { return }
        guard devices.count < Self.maximumDevices else {
            if refusedWarned.count < Self.maximumSeen, refusedWarned.insert(id).inserted {
                log.warning("\(id) at \(announcement.address) is left out: the plugin has \(Self.maximumDevices) devices already")
            }
            return
        }
        let first = rejected[id] == nil
        guard let state = await firstState(of: announcement.address) else {
            reject(id, at: announcement.address)
            if !first {
                log.debug("\(id) at \(announcement.address) still does not answer")
            } else if announcement.module == "000-0000" {
                log.warning("\(id) at \(announcement.address) (\(announcement.module)) is not supported")
            } else {
                log.warning("\(id) at \(announcement.address) did not answer: make sure it works in the Magic Home Pro app")
            }
            return
        }
        guard let profile = MagicHomeProfile.make(model: state.model, version: state.version, modeByte: state.mode) else {
            reject(id, at: announcement.address)
            if first {
                log.warning(
                    "\(id) at \(announcement.address) is a device the plugin does not know (model \(String(format: "0x%02X", state.model)), version \(state.version)): please report it")
            }
            return
        }
        rejected[id] = nil
        // Others found in the same scan may have been added while this one answered.
        guard devices.count < Self.maximumDevices else { return }
        let record = MagicHomeRecord(host: announcement.address, module: announcement.module, model: state.model, version: state.version, mode: state.mode)
        log.info("Registering new accessory: \(id), \(profile.description)")
        // Kept once it is on the bridge.
        if await add(id: id, record: record, profile: profile, state: state, firstPoll: nil) { records[id] = record }
    }

    /// Not asked again at `address` for `retryRejected`; the oldest give way to a flood of replies.
    private func reject(_ id: String, at address: String) {
        let now = ContinuousClock.now
        if rejected[id] == nil, rejected.count >= Self.maximumSeen {
            rejected = rejected.filter { $0.value.until > now }
            if rejected.count >= Self.maximumSeen { rejected.removeAll() }
        }
        rejected[id] = (address, now + dependencies.timing.retryRejected)
    }

    /// The state of a device just found, asked up to `addAttempts` times on a connection of its own.
    private func firstState(of host: String) async -> MagicHomeState? {
        let connection = MagicHomeConnection(host: host, persistent: false, transport: dependencies.transport, timing: dependencies.timing.connection)
        defer { Task { await connection.close() } }
        for attempt in 1...max(dependencies.timing.addAttempts, 1) {
            if Task.isCancelled { return nil }
            // The families that wrap their queries still answer the plain one (section 10.5).
            if let state = try? await connection.query(wrapped: false) { return state }
            log.debug("\(host) did not answer the state query (\(attempt))")
            await connection.close()
        }
        return nil
    }

    // MARK: Accessories

    private func add(id: String, record: MagicHomeRecord, profile: MagicHomeProfile, state: MagicHomeState?, firstPoll: Duration?) async -> Bool {
        let device = MagicHomeDevice(
            id: id, record: record, profile: profile, transport: dependencies.transport,
            options: MagicHomeDevice.Options(effects: effects, timing: dependencies.timing, effectSpeed: effectSpeed(id)), log: log)
        await device.observe(
            reshape: { [weak self] _ in await self?.rebuild(id) },
            record: { [weak self] record in await self?.update(id, record) })
        guard await build(device, state: state) else { return false }
        devices[id] = device
        polls[id] = tasks.add { await device.run(first: firstPoll) }
        return true
    }

    /// Builds the device's accessory and puts it on the bridge, with the cached accessory's last values meanwhile.
    @discardableResult
    private func build(_ device: MagicHomeDevice, state: MagicHomeState?) async -> Bool {
        let id = MagicHomeAccessory.accessoryID(device.id)
        let profile = await device.profile
        let name = context.accessory(id: id)?.name ?? profile.defaultName(mac: device.id, withMAC: configuration.advancedOptions?.namesWithMacAddress == true)
        let built = await MagicHomeAccessory.make(device: device, name: name, effects: showsEffects(device.id))
        if let cached = context.accessory(id: id) { built.accessory.takeValues(from: cached) }
        var lighting: AdaptiveLightingController?
        if profile.hasBrightness, profile.hasTemperature {
            lighting = context.adaptiveLighting(for: built.services.primary, accessoryID: id)
        }
        await device.attach(built.services, adaptiveLighting: lighting, state: state)
        do {
            try context.add(built.accessory)
        } catch {
            log.error("Could not add \(name) to the bridge: \(error)")
            return false
        }
        adaptiveLighting[device.id] = lighting
        log.debug("\(name): \(profile.description), \(String(format: "0x%02X", profile.model)) version \(profile.version), family \(profile.family.rawValue)")
        return true
    }

    /// The device's characteristics changed (a firmware update, another mode): its accessory is built again, same id.
    private func rebuild(_ id: String) async {
        guard let device = devices[id] else { return }
        log.info("\(id) changed: its accessory is built again")
        await build(device, state: nil)
    }

    /// Whether the device gets its effect switches: its Accessory Settings' `effects`, else the plugin's.
    func showsEffects(_ id: String) -> Bool {
        context.accessorySettings(for: id).plugin["effects"]?.boolValue ?? configuration.effects ?? false
    }

    /// The patterns' speed for the device: its Accessory Settings' `effectSpeed`, else the plugin's, else 50.
    func effectSpeed(_ id: String) -> Int {
        context.accessorySettings(for: id).plugin["effectSpeed"]?.saturatingIntValue ?? configuration.effectSpeed ?? 50
    }

    private func update(_ id: String, _ record: MagicHomeRecord) {
        records[id] = record
    }

    /// Takes a device off the bridge: refused by the lists.
    private func forget(_ id: String) async {
        polls.removeValue(forKey: id)?.cancel()
        await devices.removeValue(forKey: id)?.stop()
        adaptiveLighting[id] = nil
        records[id] = nil
        try? await context.remove(id: MagicHomeAccessory.accessoryID(id))
    }

}
