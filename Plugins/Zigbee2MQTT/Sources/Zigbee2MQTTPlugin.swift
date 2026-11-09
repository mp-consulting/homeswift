import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The devices and groups of a Zigbee2MQTT installation, through the MQTT broker it publishes on: one accessory per
/// device (by IEEE address) and per group, built from the `exposes` Zigbee2MQTT reports, its state messages shown in
/// HomeKit and HomeKit's writes published as `set` messages. It never talks Zigbee itself.
///
/// The configuration is homebridge-z2m's (platform `zigbee2mqtt`), so a Homebridge block works unchanged; this is a
/// clean-room implementation of its behaviour, from docs/clean-room/Zigbee2MQTT.md. See README.md in this directory.
public actor Zigbee2MQTTPlugin: HomeswiftPlugin {
    /// The block as written: it is checked in `start()` (docs/clean-room/Zigbee2MQTT.md, 2.7), and an invalid one
    /// leaves the plugin idle instead of failing to decode.
    public struct Configuration: Decodable, Sendable {
        public var block: JSONValue

        public init(from decoder: any Decoder) throws {
            block = try JSONValue(from: decoder)
        }

        public init(block: JSONValue) { self.block = block }
    }

    /// What the plugin uses to reach the broker and how long it waits; tests swap them.
    struct Dependencies: Sendable {
        var connect: @Sendable (MQTTConfiguration) -> any MQTTConnection = { MQTTClient($0) }
        /// How long writes and `get` requests of one device are gathered into one message.
        var coalescing: Duration = .milliseconds(100)
        /// A `get` for every gettable property after this long without a state message.
        var refreshInterval: Duration = .seconds(14_400)
        /// A moving cover without a motor state is asked for its position this often.
        var coverPollInterval: Duration = .seconds(4)
        /// No device list this long after connecting: Zigbee2MQTT is probably not running.
        var deviceListWarning: Duration = .seconds(120)
        /// Setup's and discovery's wait for Zigbee2MQTT's retained messages.
        var bridgeTimeout: Duration = .seconds(5)
        /// The `ca`, `key` and `cert` files.
        var readFile: @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    }

    public static let platform = "zigbee2mqtt"
    public static let name = "Zigbee2MQTT"
    public static let icon: String? = "bridge"
    public static let summary: String? = "Zigbee lights, sensors, blinds and remotes from Zigbee2MQTT, over MQTT"
    /// The oldest Zigbee2MQTT whose `bridge/devices` this reads.
    static let minimumVersion = [1, 17, 0]

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var settings: Settings?
    var log: Log
    var connection: (any MQTTConnection)?
    private(set) var publisher: Publisher?
    /// By Device Id.
    var devices: [String: DeviceAccessory] = [:]
    /// IEEE addresses (a group's id) and friendly names to Device Ids, for the state topics.
    private var topics: [String: String] = [:]
    private var deviceList: [DeviceEntry]?
    private var groupList: [JSONValue]?
    private var groupMembers = Set<String>()
    private var availability: AvailabilityConfiguration?
    private var version: String?
    private var bridgeOffline = false
    /// The topic index and devices.json wait for the end of a sync, rather than following each device.
    private var topicsChanged = false
    private var entriesChanged = false
    var brokerDown = false
    private var everConnected = false
    private var reportedDisconnection = false
    private var reportedUnreachable = false
    private var deviceListTimer: Task<Void, Never>?
    /// A Join in progress: the network Zigbee2MQTT opened for Setup, and what came of it (Zigbee2MQTTJoin.swift).
    var joining: Joining?

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        log = Log(logger: context.logger)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// The stored device entries, by Device Id: accessories are rebuilt from them before the broker answers.
    var storedEntries: JSONFile<[String: DeviceEntry]> { context.jsonFile("devices.json") }

    /// The broker's password: the block's, or the one Setup put in the vault.
    func mqttSettings(_ settings: Settings) -> Settings.MQTT {
        var mqtt = settings.mqtt
        if mqtt.password == nil, let stored = context.credentials(as: BrokerLogin.self), stored.server == mqtt.server, mqtt.user == nil || mqtt.user == stored.user {
            mqtt.password = stored.password
            if mqtt.user == nil { mqtt.user = stored.user }
        }
        return mqtt
    }

    public func start() async throws {
        let settings: Settings
        do {
            settings = try Settings(configuration.block)
        } catch {
            log.error("The Zigbee2MQTT configuration is invalid, so the plugin will not work: \(error)")
            return
        }
        self.settings = settings
        log.debugAsInfo = settings.debugAsInfo
        if settings.debugAsInfo { log.warning("Debug messages are logged at info level (log.debug_as_info)") }
        for flag in settings.experimental.sorted() { log.warning("Experimental feature enabled: \(flag)") }
        for skipped in settings.skippedDevices { log.warning("Skipping \(skipped)") }
        log.debug("Default device options: \(JSONValue.object(settings.defaults).text())")

        let mqtt = mqttSettings(settings)
        let mqttConfiguration: MQTTConfiguration
        do {
            mqttConfiguration = try Self.mqttConfiguration(mqtt, readFile: dependencies.readFile)
        } catch {
            log.error("Cannot use the MQTT broker \(Self.masked(mqtt.server)): \(error)")
            return
        }
        let connection = dependencies.connect(mqttConfiguration)
        self.connection = connection
        publisher = Publisher(connection: connection, settings: settings, log: log, coalescing: dependencies.coalescing, tasks: tasks)
        restoreAccessories()

        let messages = connection.messages, states = connection.states
        tasks.add { [weak self] in
            for await message in messages { await self?.handle(message) }
        }
        tasks.add { [weak self] in
            for await state in states { await self?.connectionChanged(state) }
        }
        log.info("Connecting to the MQTT broker at \(Self.masked(mqtt.server))")
        let base = settings.mqtt.baseTopic
        tasks.add { [weak self] in
            do {
                try await connection.subscribe("\(base)/#", qos: .atMostOnce)
                try await connection.connect()
            } catch {
                await self?.log.error("Cannot reach the MQTT broker: \(error)")
            }
        }
    }

    public func stop() async {
        joining?.window.cancel()
        tasks.cancelAll()
        deviceListTimer?.cancel()
        for device in devices.values { device.refresh?.cancel() }
        await connection?.disconnect()
    }

    // MARK: The broker

    /// The client's settings (2.1): TLS from the files, the user and password only together, the protocol level.
    static func mqttConfiguration(_ mqtt: Settings.MQTT, readFile: @Sendable (String) throws -> String) throws -> MQTTConfiguration {
        guard let url = URL(string: mqtt.server) else { throw MQTTError.invalidURL(masked(mqtt.server)) }
        var tls = TLSOptions()
        if mqtt.rejectUnauthorized == false {
            tls.trust = .any
        } else if let ca = mqtt.ca {
            tls.trust = .roots(pem: try readFile(ca))
        }
        if let key = mqtt.key, let cert = mqtt.cert {
            tls.clientIdentity = .pem(certificate: try readFile(cert), privateKey: try readFile(key))
        }
        let clientID = mqtt.clientID ?? "mqttjs_" + String(format: "%08x", UInt32.random(in: .min ... .max))
        var configuration = try MQTTConfiguration(url: url, clientID: clientID, tls: tls)
        if let user = mqtt.user, !user.isEmpty, let password = mqtt.password, !password.isEmpty {
            configuration.username = user
            configuration.password = password
        }
        if let keepalive = mqtt.keepalive, keepalive > 0 { configuration.keepAlive = .seconds(keepalive) }
        switch mqtt.version {
        case 3: configuration.protocolVersion = .v3_1
        case 5: configuration.protocolVersion = .v5
        default: break
        }
        configuration.reconnect = .init(delay: .seconds(1), maximumDelay: .seconds(30), jitter: .proportional(0.2), firstConnection: true)
        return configuration
    }

    /// The server's address without a password in it, for the log.
    static func masked(_ server: String) -> String {
        guard var components = URLComponents(string: server), components.password != nil else { return server }
        components.password = "***"
        return components.string ?? server
    }

    private func connectionChanged(_ state: MQTTConnectionState) async {
        switch state {
        case .connected:
            reportedUnreachable = false
            reportedDisconnection = false
            log.info(everConnected ? "Reconnected to the MQTT broker" : "Connected to the MQTT broker")
            everConnected = true
            if brokerDown {
                brokerDown = false
                applyAvailabilityToAll()
            }
            if deviceList == nil, deviceListTimer == nil {
                let wait = dependencies.deviceListWarning
                deviceListTimer = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    await self?.warnIfNoDevices()
                }
            }
            await publisher?.sendBacklog()
        case .connectionLost(let reason):
            if everConnected, !reportedDisconnection {
                reportedDisconnection = true
                log.error("Disconnected from the MQTT broker: \(reason)")
            } else if !everConnected, !reportedUnreachable {
                reportedUnreachable = true
                log.error("Cannot reach the MQTT broker: \(reason)")
            }
            if !brokerDown {
                brokerDown = true
                applyAvailabilityToAll()
            }
        case .disconnected, .connecting:
            break
        }
    }

    private func warnIfNoDevices() {
        guard deviceList == nil else { return }
        log.error("No devices received from Zigbee2MQTT two minutes after connecting: check that Zigbee2MQTT runs, on base topic \(settings?.mqtt.baseTopic ?? ""), and is v1.17.0 or later")
    }

    // MARK: Messages (5.2)

    func handle(_ message: MQTTMessage) {
        guard let settings else { return }
        let prefix = settings.mqtt.baseTopic + "/"
        guard message.topic.hasPrefix(prefix) else {
            log.debug("Ignoring a message on \(message.topic)")
            return
        }
        let topic = String(message.topic.dropFirst(prefix.count))
        switch topic {
        case "bridge/devices": receivedDevices(message.payload)
        case "bridge/groups": receivedGroups(message.payload)
        case "bridge/state": receivedBridgeState(message.payload)
        case "bridge/info": receivedInfo(message.payload)
        case "bridge/event": receivedEvent(message.payload)
        case "bridge/response/permit_join": receivedPermitJoin(message.payload)
        default:
            if topic.hasPrefix("bridge/") || topic.hasSuffix("/get") || topic.hasSuffix("/set") { return }
            if topic.hasSuffix("/availability") {
                receivedAvailability(String(topic.dropLast("/availability".count)), message.payload)
            } else {
                receivedState(topic, message.payload)
            }
        }
    }

    private func receivedDevices(_ payload: Data) {
        do {
            deviceList = try JSONDecoder().decode([JSONValue].self, from: payload).compactMap { try? $0.decode(DeviceEntry.self) }
        } catch {
            log.error("Could not parse the device list of Zigbee2MQTT: \(error)")
            return
        }
        deviceListTimer?.cancel()
        sync()
    }

    private func receivedGroups(_ payload: Data) {
        guard let groups = (try? JSONValue(data: payload))?.arrayValue else {
            log.error("Could not parse the group list of Zigbee2MQTT")
            return
        }
        groupList = groups
        groupMembers = Self.members(of: groups)
        sync()
    }

    /// Both lists, once Zigbee2MQTT sent them.
    var knownLists: (devices: [DeviceEntry], groups: [JSONValue])? {
        guard let deviceList else { return nil }
        return (deviceList, groupList ?? [])
    }

    static func members(of groups: [JSONValue]) -> Set<String> {
        Set(groups.flatMap { $0["members"]?.arrayValue ?? [] }.compactMap { $0["ieee_address"]?.stringValue })
    }

    /// Brings the accessories in step with the lists. Groups wait for the device list, and nothing is removed until
    /// both lists came, so a group restored from the cache keeps its rooms whatever order the broker sends them in.
    private func sync() {
        guard let settings, let deviceList else { return }
        // Devices that are in a group may be left out: that needs the group list.
        if settings.excludeGroupedDevices, groupList == nil { return }
        defer { saveChanges() }
        for entry in deviceList where entry.hasValidDefinition { createOrUpdate(entry) }
        guard let groupList else { return }
        // A group skipped (nothing its members share) goes, as a device gone from the list does.
        var keep = Set(deviceList.map(\.deviceID))
        let byAddress = Dictionary(deviceList.map { ($0.ieeeAddress, $0) }) { first, _ in first }
        for group in groupList {
            guard let entry = groupEntry(group, devices: byAddress) else { continue }
            keep.insert(entry.deviceID)
            createOrUpdate(entry)
        }
        removeStale(keeping: keep)
    }

    /// A group as a device: the exposes all its members share (11).
    private func groupEntry(_ group: JSONValue, devices byAddress: [String: DeviceEntry]) -> DeviceEntry? {
        guard let id = group["id"]?.intValue, let name = group["friendly_name"]?.stringValue else { return nil }
        var exposes: [Expose]?
        for member in group["members"]?.arrayValue ?? [] {
            guard let address = member["ieee_address"]?.stringValue, let device = byAddress[address], let own = device.definition?.exposes else {
                log.warning("Group \(name): member \(member["ieee_address"]?.stringValue ?? "?") is not in the device list or has no exposes")
                continue
            }
            exposes = exposes.map { Expose.intersection($0, own) } ?? own.filter { $0.name != "linkquality" }
        }
        var entry = DeviceEntry(ieeeAddress: String(id), friendlyName: name, groupID: id,
                                definition: .init(vendor: "Zigbee2MQTT", model: "GROUP-\(id)", exposes: exposes ?? []))
        if (exposes ?? []).isEmpty {
            let options = settings.map { effectiveOptions(entry, $0) }
            guard let configured = options?.exposes, !configured.isEmpty, options?.exclude != true else {
                log.debug("Group \(name) has nothing all its members expose: skipped")
                return nil
            }
            entry.definition?.exposes = configured
        } else {
            log.debug("Group \(name) exposes \((try? JSONValue(encoding: exposes ?? []))?.text() ?? "[]")")
        }
        return entry
    }

    /// A device's effective options: `defaults`, its `devices` entry, then its Accessory Settings in `_accessories`.
    func effectiveOptions(_ entry: DeviceEntry, _ settings: Settings) -> DeviceOptions {
        settings.options(for: entry.optionIDs, accessory: context.accessorySettings(for: entry.deviceID).plugin)
    }

    /// Whether a device or group gets no accessory (6.7).
    func isExcluded(_ entry: DeviceEntry, options: DeviceOptions) -> Bool {
        if context.isExcluded(entry.deviceID) { return true }
        if options.exclude == true { return true }
        if options.exclude == false { return false }
        if settings?.excludeGroupedDevices == true, !entry.isGroup, groupMembers.contains(entry.ieeeAddress) { return true }
        return false
    }

    /// The entry with its options applied: the configured exposes in place of the device's, then filtered (6.8, 7).
    private func applying(_ options: DeviceOptions, to entry: DeviceEntry) -> DeviceEntry {
        var entry = entry
        if let exposes = options.exposes, !exposes.isEmpty { entry.definition?.exposes = exposes }
        if let exposes = entry.definition?.exposes { entry.definition?.exposes = options.filter(exposes) }
        return entry
    }

    /// Adds the accessory of a new device, rebuilds the one of a device that changed, removes an excluded one.
    private func createOrUpdate(_ entry: DeviceEntry) {
        guard let settings else { return }
        let options = effectiveOptions(entry, settings)
        let id = entry.deviceID
        if isExcluded(entry, options: options) {
            log.debug("Excluding \(entry.friendlyName) (\(entry.ieeeAddress))")
            if devices[id] != nil || context.accessory(id: Self.accessoryID(deviceID: id)) != nil { remove(id) }
            return
        }
        if let existing = devices[id], (existing.entry == entry || existing.entry.sameInformation(as: entry)), existing.options == options {
            existing.availabilityEnabled = availabilityEnabled(entry, options: options)
            applyAvailability(existing)
            return
        }
        let isNew = devices[id] == nil && context.accessory(id: Self.accessoryID(deviceID: id)) == nil
        guard let device = build(entry, options: options) else { return }
        if isNew { log.info("New accessory: \(entry.friendlyName) (\(device.accessory.name))") }
        entriesChanged = true
    }

    /// Builds the accessory and puts it on the bridge, in place of the one with its id.
    @discardableResult
    func build(_ entry: DeviceEntry, options: DeviceOptions) -> DeviceAccessory? {
        guard let publisher, let settings else { return nil }
        let filtered = applying(options, to: entry)
        guard filtered.hasValidDefinition else {
            log.error("No device definition for \(entry.friendlyName) (\(entry.ieeeAddress))")
            return nil
        }
        let flags = options.experimental.subtracting(settings.experimental)
        for flag in flags.sorted() { log.warning("Experimental feature enabled for \(entry.friendlyName): \(flag)") }
        log.debug("Options of \(entry.friendlyName): matched a devices entry: \(options.matched)")
        let accessoryID = Self.accessoryID(deviceID: entry.deviceID)
        let name = Names.sanitize(entry.friendlyName) ?? entry.deviceID
        let topic = entry.commandTopic
        let link = DeviceLink(
            displayName: name, log: log, coverPollInterval: dependencies.coverPollInterval,
            set: { [publisher] in publisher.set(topic, $0) }, get: { [publisher] in publisher.get(topic, $0) })
        let context = self.context
        let builder = ServiceBuilder(
            friendlyName: entry.friendlyName, fallbackName: entry.ieeeAddress, options: options, link: link,
            adaptiveLighting: { context.adaptiveLighting(for: $0, accessoryID: accessoryID) })
        let handlers = builder.build(filtered.definition?.exposes ?? [])
        let accessory = Accessory(
            id: accessoryID, name: name, manufacturer: entry.isGroup ? "Zigbee2MQTT" : filtered.definition?.vendor ?? "Zigbee2MQTT",
            model: filtered.definition?.model ?? "unknown", serialNumber: entry.isGroup ? "GROUP:\(entry.ieeeAddress)" : entry.ieeeAddress,
            firmwareRevision: entry.softwareBuildID ?? "?", category: Self.category(handlers), services: handlers.map(\.service))
        accessory.information.characteristic(adding: .hardwareRevision).value = .string(entry.dateCode ?? "?")
        if let cached = context.accessory(id: accessoryID) { accessory.takeValues(from: cached) }
        let device = DeviceAccessory(entry: entry, options: options, handlers: handlers, accessory: accessory)
        device.availabilityEnabled = availabilityEnabled(entry, options: options)
        if let previous = devices[entry.deviceID] {
            previous.refresh?.cancel()
            // What Zigbee2MQTT last said of its availability outlives the rebuild.
            device.online = previous.online
        }
        devices[entry.deviceID] = device
        topicsChanged = true
        do {
            try context.add(accessory)
        } catch {
            log.error("Could not add \(name): \(error)")
        }
        // A remote: a Button per action switch, whose moments it reports (a hold only where the device says its release).
        let actions = handlers.compactMap { $0 as? ActionHandler }
        if !actions.isEmpty {
            context.declareRemote(accessoryID, .inferred(from: accessory))
            for handler in actions {
                let part = RemoteLayout.partID(of: handler.service)
                handler.onMoment = { [context] moment in context.remoteMoment(moment, part: part, of: accessoryID) }
            }
        }
        applyAvailability(device)
        link.get(device.gettableKeys)
        return device
    }

    static func category(_ handlers: [any ServiceHandler]) -> AccessoryCategory {
        let order: [(ServiceType, AccessoryCategory)] = [
            (.lightbulb, .lightbulb), (.outlet, .outlet), (.switch, .switch), (.windowCovering, .windowCovering), (.lockMechanism, .doorLock),
            (.thermostat, .thermostat), (.statelessProgrammableSwitch, .programmableSwitch),
        ]
        for (type, category) in order where handlers.contains(where: { $0.service.type.uuid == type.uuid }) { return category }
        return handlers.isEmpty ? .other : .sensor
    }

    private func indexTopics() {
        topics = [:]
        for (id, device) in devices {
            topics[device.entry.ieeeAddress] = id
            topics[device.entry.friendlyName] = topics[device.entry.friendlyName] ?? id
        }
    }

    private func remove(_ id: String) {
        devices.removeValue(forKey: id)?.refresh?.cancel()
        topicsChanged = true
        entriesChanged = true
        let context = self.context
        tasks.add { try? await context.remove(id: Self.accessoryID(deviceID: id)) }
    }

    private func removeStale(keeping ids: Set<String>) {
        for id in devices.keys where !ids.contains(id) {
            log.debug("Removing \(devices[id]?.entry.friendlyName ?? id): no longer in Zigbee2MQTT")
            remove(id)
        }
        // What is kept is read when the removal runs, so an accessory a later message added stays.
        tasks.add { [weak self] in await self?.removeRestoredOnly() }
    }

    private func removeRestoredOnly() async {
        _ = await context.removeAccessories(keeping: Set(devices.keys.map(Self.accessoryID)))
    }

    /// The topic index and devices.json, once the accessories changed.
    private func saveChanges() {
        if topicsChanged { indexTopics() }
        topicsChanged = false
        guard entriesChanged else { return }
        entriesChanged = false
        do {
            try storedEntries.save(devices.mapValues(\.entry))
        } catch {
            log.warning("Could not save the device list: \(error)")
        }
    }

    /// The accessories of the last run, rebuilt before the broker answers (3.4), so writes work at once.
    private func restoreAccessories() {
        guard let settings else { return }
        for (id, entry) in storedEntries.load() ?? [:] {
            let options = effectiveOptions(entry, settings)
            if isExcluded(entry, options: options) {
                log.warning("Removing the excluded \(entry.friendlyName) (\(entry.ieeeAddress)) restored from the cache")
                remove(id)
                continue
            }
            log.info("Restoring accessory \(entry.friendlyName)")
            build(entry, options: options)
        }
        saveChanges()
    }

    private func receivedState(_ id: String, _ payload: Data) {
        guard !payload.isEmpty else {
            log.debug("Ignoring an empty message for \(id)")
            return
        }
        guard let deviceID = topics[id], let device = devices[deviceID] else {
            log.debug("Unhandled message on \(id)")
            return
        }
        guard let object = (try? JSONValue(data: payload))?.objectValue else {
            log.error("Could not parse the state of \(device.entry.friendlyName): \(String(decoding: payload.prefix(512), as: UTF8.self))")
            return
        }
        device.lastState = .now
        if device.refresh == nil { startRefresh(device) }
        let state = object.filter { !$0.value.isNull }
        for key in Self.powerOnKeys { if let value = state[key] { device.powerOnState[key] = value } }
        for handler in device.handlers { handler.update(state) }
        log.debug("Handled device update for \(id): \(String(decoding: payload.prefix(512), as: UTF8.self))")
    }

    /// Asks for every gettable property after four hours without a state message, then every four hours (6.6): one
    /// task per device, started by its first state message, that sleeps until the device has been silent that long.
    private func startRefresh(_ device: DeviceAccessory) {
        guard !device.gettableKeys.isEmpty else { return }
        let id = device.entry.deviceID, interval = dependencies.refreshInterval
        device.refresh = Task { [weak self] in
            while let wait = await self?.refreshWait(id, interval: interval) {
                do { try await Task.sleep(for: wait) } catch { return }
            }
        }
    }

    /// Sends the `get` once the device was silent `interval`; answers how long until the next check, nil once it is gone.
    private func refreshWait(_ id: String, interval: Duration) -> Duration? {
        guard let device = devices[id], let last = device.lastState else { return nil }
        let silent = ContinuousClock.now - last
        guard silent >= interval else { return interval - silent }
        publisher?.get(device.entry.commandTopic, device.gettableKeys)
        device.lastState = .now
        return interval
    }

    // MARK: Availability (10)

    func availabilityEnabled(_ entry: DeviceEntry, options: DeviceOptions) -> Bool {
        guard !options.ignoreAvailability else { return false }
        return availability?.isEnabled(address: entry.ieeeAddress, name: entry.friendlyName) ?? true
    }

    /// No Response while Zigbee2MQTT says the device is offline, or while Zigbee2MQTT or the broker is.
    private func applyAvailability(_ device: DeviceAccessory) {
        let deviceOffline = device.availabilityEnabled && !device.online
        let bridgeDown = !device.options.ignoreZ2MOnline && (brokerDown || bridgeOffline)
        let unavailable = deviceOffline || bridgeDown
        if device.accessory.isUnavailable != unavailable {
            log.debug("\(device.entry.friendlyName) is \(unavailable ? "unavailable" : "available")")
            device.accessory.isUnavailable = unavailable
        }
    }

    private func applyAvailabilityToAll() {
        for device in devices.values { applyAvailability(device) }
    }

    private func receivedAvailability(_ id: String, _ payload: Data) {
        guard let deviceID = topics[id], let device = devices[deviceID] else {
            log.debug("Unhandled availability of \(id)")
            return
        }
        let online = OnlineState.deviceIsOnline(payload)
        guard online != device.online else { return }
        log.debug("\(device.entry.friendlyName) is \(online ? "online" : "offline") (availability \(device.availabilityEnabled ? "on" : "off"))")
        device.online = online
        applyAvailability(device)
    }

    private func receivedBridgeState(_ payload: Data) {
        let offline = OnlineState.bridgeIsOffline(payload)
        // The first "online" changes nothing: accessories hear of the bridge only once it was seen offline.
        guard offline != bridgeOffline else { return }
        bridgeOffline = offline
        if offline {
            log.error("Zigbee2MQTT is OFFLINE")
        } else {
            log.info("Zigbee2MQTT is online")
        }
        applyAvailabilityToAll()
    }

    private func receivedInfo(_ payload: Data) {
        guard let info = try? JSONValue(data: payload) else {
            log.error("Could not parse bridge/info")
            return
        }
        if let version = info["version"]?.stringValue {
            if version != self.version {
                self.version = version
                log.info("Using Zigbee2MQTT v\(version) (identified via bridge/info)")
                if Self.isOlder(version, than: Self.minimumVersion) {
                    log.error("Zigbee2MQTT v\(version) is too old: update it to v1.17.0 or later, or this plugin might not work")
                }
            }
        } else {
            log.error("No version found in bridge/info")
        }
        guard let config = info["config"], config.objectValue != nil else { return }
        if let output = config["experimental"]?["output"], !output.text().contains("json") {
            log.error("Zigbee2MQTT must output JSON (experimental.output), not \(output.text())")
        }
        let availability = AvailabilityConfiguration(config: config)
        guard availability != self.availability else { return }
        self.availability = availability
        for device in devices.values {
            device.availabilityEnabled = availabilityEnabled(device.entry, options: device.options)
            applyAvailability(device)
        }
    }

    /// Semver's order on the numbers, a trailing `-dev` ignored.
    static func isOlder(_ version: String, than minimum: [Int]) -> Bool {
        let core = version.hasSuffix("-dev") ? String(version.dropLast(4)) : version
        let numbers = core.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        for (index, wanted) in minimum.enumerated() {
            let have = index < numbers.count ? numbers[index] : 0
            if have != wanted { return have < wanted }
        }
        return false
    }
}
