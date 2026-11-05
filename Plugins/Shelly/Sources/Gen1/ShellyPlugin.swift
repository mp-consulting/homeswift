import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Shelly Gen 1 devices (Shelly 1, 2.5, Plug, Dimmer, RGBW2, Bulb, Duo, Button1, i3, Door/Window, H&T, Flood, …): heard
/// over CoIoT, the CoAP status they multicast to 224.0.1.187:5683 on every change, and driven over their HTTP API.
///
/// A `Shelly` block of homebridge-shelly loads unchanged; the bridge writes each device's options in `_accessories` by
/// its Device Id (the CoIoT id, `A4CF12F45678`) and credentials in the vault (ShellySettings.swift). Accessories are
/// `Shelly:<model name> <device id>[ #<index>]`, the Homebridge plugin's seeds. Gen 2+ devices are `ShellyNGPlugin`'s.
public actor ShellyPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// HTTP Basic credentials for every device; used when both are set.
        public var username: String?
        public var password: String?
        /// An interface name or local IPv4 address to join the CoIoT group on.
        public var networkInterface: String?
        /// Milliseconds; 10000 by default.
        public var requestTimeout: JSONValue?
        /// Milliseconds a device may stay offline before its accessories go; 0 or `false` never.
        public var staleTimeout: JSONValue?
        /// The Homebridge plugin's own admin page: read and ignored (the web UI replaces it).
        public var admin: JSONValue?
        /// Per-device options, by `id`.
        public var devices: [JSONValue]?
    }

    struct Dependencies: Sendable {
        var listen: @Sendable (String?) async throws -> any CoIoTListener = CoIoT.listen(interfaceAddress:)
        var http: any HTTPSending = HTTPClient()
        /// Multiplies the plugin's own delays (validity, stale timeout, debounces); tests shorten them.
        var timeScale: Double = 1
        /// How long Setup listens for devices on an instance that is not running.
        var discoveryWindow: Duration = .seconds(3)
    }

    /// What the plugin remembers of a device to make its accessories again before it is heard.
    struct StoredDevice: Codable, Sendable, Equatable {
        var type: String
        var id: String
        var host: String
        var mode: String?
        var name: String?
    }

    public static let platform = "Shelly"
    public static let name = "Shelly Gen 1"
    public static let icon: String? = "switch"
    public static let summary: String? = "Shelly Gen 1 relays, plugs, dimmers, bulbs, buttons and sensors"
    // `configurationSchemaJSON` is in ShellyPluginSchema.swift, generated from ../config.gen1.schema.json.

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    var logger: Logger { context.logger }

    private(set) var devices: [String: Gen1Device] = [:]
    private var built: [String: [Gen1Builder.Built]] = [:]
    private var offlineTimers: [String: Task<Void, Never>] = [:]
    private var staleTimers: [String: Task<Void, Never>] = [:]
    /// Unknown and Excluded devices, logged once each.
    private var ignored: Set<String> = []
    private var listener: (any CoIoTListener)?
    private let tasks = TaskBag()
    private(set) var listening = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    var requestTimeout: Duration { .milliseconds(Int(saturating: configuration.requestTimeout?.number ?? 10000, in: 100...600_000) ?? 10000) }

    /// The device of an accessory id's part after `Shelly:`: the word before ` #<index>`.
    public static func deviceID(ofAccessory suffix: String) -> String? {
        var seed = Substring(suffix)
        if let hash = seed.range(of: " #", options: .backwards), Int(seed[hash.upperBound...]) != nil { seed = seed[..<hash.lowerBound] }
        return seed.split(separator: " ").last.map(String.init)
    }

    // MARK: Lifecycle

    public func start() async throws {
        await restoreDevices()
        let interface = resolveInterface()
        let listen = dependencies.listen
        let socket = try await listen(interface)
        listener = socket
        listening = true
        try? await socket.send(Data(CoIoTStatus.request()), to: CoIoTStatus.multicastGroup, port: CoIoTStatus.port)
        tasks.add { [weak self] in
            for await (data, address) in socket.datagrams {
                guard let self else { return }
                await self.received(data, from: address)
            }
        }
        logger.info("Listening for Shelly devices over CoIoT")
    }

    public func stop() async {
        tasks.cancelAll()
        for task in offlineTimers.values { task.cancel() }
        for task in staleTimers.values { task.cancel() }
        offlineTimers.removeAll()
        staleTimers.removeAll()
        await listener?.close()
        listener = nil
        listening = false
        built.removeAll()
    }

    /// `networkInterface` as an IPv4 address: an interface's first, or one of the host's; nil for the default.
    private func resolveInterface() -> String? {
        guard let value = configuration.networkInterface?.trimmedNonEmpty else { return nil }
        let local = NetworkInterfaces.ipv4()
        if let address = IPv4Network.parse(value), local.contains(where: { $0.address == address }) { return value }
        if let address = NetworkInterfaces.ipv4Address(ofInterface: value) { return address }
        logger.warning("Ignoring unknown network interface name or address \"\(value)\"")
        return nil
    }

    // MARK: Devices

    private var storeFile: JSONFile<[String: StoredDevice]> { context.jsonFile("shelly-devices.json", as: [String: StoredDevice].self) }

    /// The devices of the last run, offline until they are heard, with their accessories made again.
    private func restoreDevices() async {
        for accessory in context.accessories {
            guard let id = Self.deviceID(ofAccessory: String(accessory.id.dropFirst(Self.platform.count + 1))), isLeftOut(id) else { continue }
            try? await context.remove(id: accessory.id)
        }
        var restored = 0
        for (key, stored) in (storeFile.load() ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let model = Gen1Models.all[stored.type], !isLeftOut(stored.id) else { continue }
            let device = makeDevice(model: model, id: stored.id, host: stored.host, mode: stored.mode, name: stored.name)
            devices[key] = device
            restored += await buildAccessories(device, armed: false)
        }
        logger.info("\(restored) accessories loaded from cache")
    }

    private func makeDevice(model: Gen1Model, id: String, host: String, mode: String?, name: String? = nil) -> Gen1Device {
        var deviceLogger = logger
        deviceLogger[metadataKey: "device"] = "\(model.id) \(id)"
        return Gen1Device(model: model, deviceID: id, host: host, mode: mode, http: dependencies.http, credentials: credentials(for: id),
                          timeout: requestTimeout, logger: deviceLogger, settingsName: name)
    }

    func received(_ data: Data, from address: String) async {
        guard let status = CoIoTStatus(datagram: data) else { return }
        let key = "\(status.model)#\(status.deviceID)"
        if let device = devices[key] {
            let (modeChanged, hostChanged) = await device.apply(status, from: address)
            if modeChanged { _ = await buildAccessories(device, armed: true) }
            if modeChanged || hostChanged { await store(device) }
            if await device.candidateHost != nil {
                tasks.add { [weak self] in
                    if await device.verifyMove() { await self?.store(device) }
                }
            }
            await heard(device, validity: status.validity)
            return
        }
        guard !ignored.contains(key) else { return }
        guard let model = Gen1Models.all[status.model] else {
            ignored.insert(key)
            if let name = Gen1Models.unsupportedNames[status.model] {
                logger.info("Unknown device, so skipping it: \(name) \(status.deviceID) at \(address)")
            } else {
                logger.info("Unknown device \(status.model) \(status.deviceID) at \(address) discovered")
            }
            return
        }
        if isLeftOut(status.deviceID) {
            ignored.insert(key)
            logger.info("Excluding device \(status.model) \(status.deviceID) at \(address)")
            return
        }
        logger.info("New device discovered: \(status.model) \(status.deviceID) at \(address)")
        let device = makeDevice(model: model, id: status.deviceID, host: address, mode: nil)
        await device.apply(status, from: address)
        devices[key] = device
        _ = await buildAccessories(device, armed: true)
        await store(device)
        await heard(device, validity: status.validity)
    }

    /// A status arrived: online, its settings loaded once, offline again when its validity runs out.
    private func heard(_ device: Gen1Device, validity: Int?) async {
        let key = device.key
        if await device.setOnline(true) {
            staleTimers.removeValue(forKey: key)?.cancel()
            tasks.add { [weak self] in await self?.loadSettings(device) }
        }
        guard let validity, validity > 0 else { return }
        offlineTimers[key]?.cancel()
        let delay = Duration.seconds(Double(validity) * dependencies.timeScale)
        offlineTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.wentOffline(device)
        }
    }

    private func wentOffline(_ device: Gen1Device) async {
        guard await device.setOnline(false) else { return }
        let stale = configuration.staleTimeout?.number ?? 0
        guard stale > 0, stale == stale.rounded() else { return }
        let key = device.key, label = device.label
        let delay = Duration.milliseconds(Int(saturating: stale * dependencies.timeScale) ?? Int.max)
        staleTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, await !device.isOnline else { return }
            await self.forget(key, message: "Device \(label) is stale. Unregistering its accessories.")
        }
    }

    private func forget(_ key: String, message: String) async {
        logger.info("\(message)")
        for item in built.removeValue(forKey: key) ?? [] { try? await context.remove(id: item.accessory.id) }
        if let device = devices.removeValue(forKey: key) { await device.removeObservers() }
        offlineTimers.removeValue(forKey: key)?.cancel()
        staleTimers.removeValue(forKey: key)
        var stored = storeFile.load() ?? [:]
        if stored.removeValue(forKey: key) != nil { try? storeFile.save(stored) }
    }

    private func loadSettings(_ device: Gen1Device) async {
        do {
            guard try await device.loadSettings() else { return }
        } catch {
            await device.logFailure("Failed to load device settings", error)
            _ = await device.setOnline(false)
            return
        }
        let firmware = await device.firmware, hardware = await device.hardwareRevision
        for item in built[device.key] ?? [] {
            if let firmware { item.accessory.information.characteristic(.firmwareRevision).update(.string(firmware)) }
            if let hardware { item.accessory.information.characteristic(adding: .hardwareRevision).update(.string(hardware)) }
        }
        await store(device)
    }

    /// Makes the device's accessories for its mode, removing those of another mode; answers how many.
    private func buildAccessories(_ device: Gen1Device, armed: Bool) async -> Int {
        let key = device.key
        await device.removeObservers()
        let mode = await device.mode
        let count = Gen1Builder.count(device.model, mode: mode)
        let scale = dependencies.timeScale
        let builder = Gen1Builder(
            device: device, platform: Self.platform, context: context, logger: device.logger, lightDelay: .milliseconds(Int(100 * scale)),
            rollerDelay: .milliseconds(Int(1000 * scale)), rollerSettle: .milliseconds(Int(500 * scale)))
        let settingsName = await device.settingsName
        let deviceName = deviceOptions(device.deviceID)["name"]?.stringValue?.trimmedNonEmpty ?? settingsName
        var made: [Gen1Builder.Built] = []
        for index in 0..<count {
            do {
                if let item = try await builder.build(index: index, count: count, options: accessoryOptions(device.deviceID, index: index),
                                                      deviceName: deviceName, armed: armed) {
                    made.append(item)
                }
            } catch {
                logger.error("Failed to add device \(device.label): \(error)")
            }
        }
        let ids = Set(made.map(\.accessory.id))
        for old in built[key] ?? [] where !ids.contains(old.accessory.id) { try? await context.remove(id: old.accessory.id) }
        // Cached accessories of this device from another mode (two relays, then one roller).
        for accessory in context.accessories where !ids.contains(accessory.id) && context.isAccessory(accessory.id, of: device.deviceID)
            && accessory.id.hasPrefix("\(Self.platform):\(device.model.name) ") {
            try? await context.remove(id: accessory.id)
        }
        // Before the accessories go on the bridge: the bridge never reads the meter the plugin takes over.
        await recordEnergy(device, made: made, name: made.first?.accessory.name ?? device.label)
        for item in made {
            if let cached = context.accessory(id: item.accessory.id) { item.accessory.takeValues(from: cached) }
            do { try context.add(item.accessory) } catch { logger.error("Failed to add device \(device.label): \(error)") }
        }
        built[key] = made
        return made.count
    }

    /// The EM's and 3EM's power meter is the plugin's Meter: its phases added up (the service shows the first alone),
    /// with the energy each counted and sent back (CoIoT's counters, in Wh), suggested as the grid (a whole home's
    /// meter); the series keeps the name it had when the plugin recorded the power itself.
    private func recordEnergy(_ device: Gen1Device, made: [Gen1Builder.Built], name: String) async {
        let phases: [Int] = switch device.model.id {
        case "SHEM-3": [0, 1, 2]
        case "SHEM": [0]
        default: []
        }
        guard !phases.isEmpty,
              let item = made.first(where: { $0.accessory.services.contains { $0.type.uuid == PowerMeter.service.uuid } }),
              let service = item.accessory.services.first(where: { $0.type.uuid == PowerMeter.service.uuid }) else { return }
        let meter = context.meter(of: service, accessoryID: item.accessory.id, device: name, suggestedRole: .grid, series: "\(device.deviceID):grid")
        let power = phases.map { "power\($0)" }, drawn = phases.map { "energyCounter\($0)" }, back = phases.map { "energyReturned\($0)" }
        let sum: @Sendable ([String], [String: JSONValue]) -> Double? = { names, values in
            let known = names.compactMap { values[$0]?.number }
            return known.count == names.count ? known.reduce(0, +) : nil
        }
        await device.observe(Set(power + drawn + back)) { values in
            if let watts = sum(power, values) { meter.record(watts: watts) }
            if let wattHours = sum(drawn, values) { meter.record(counter: wattHours) }
            if let wattHours = sum(back, values) { meter.record(counter: wattHours, direction: .returned) }
        }
    }

    private func store(_ device: Gen1Device) async {
        var stored = storeFile.load() ?? [:]
        let entry = StoredDevice(type: device.model.id, id: device.deviceID, host: await device.host, mode: await device.mode, name: await device.settingsName)
        guard stored[device.key] != entry else { return }
        stored[device.key] = entry
        do { try storeFile.save(stored) } catch { logger.error("Failed to save devices: \(error)") }
    }
}
