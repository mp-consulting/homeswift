import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// SwitchBot devices and IR remotes through the SwitchBot cloud (OpenAPI v1.1): Bots, Relay Switches, plugs, curtains,
/// blinds, meters, hubs, sensors, locks, lights, humidifiers, fans, vacuums and air purifiers, polled within the
/// account's daily requests and, with `options.webhookURL`, told of changes by the cloud's webhook. IR remotes
/// (televisions, fans, air conditioners, lights…) send their commands through their Hub.
///
/// A block of `@switchbot/homebridge-switchbot` (4.x's `credentials` and `options`, or 5.x's flatter shape) loads
/// unchanged; what the bridge writes is the canonical shape (SwitchBotSettings.swift): the token and secret in the
/// vault, each device's options in `_accessories` by its Device Id, 4.x's seed `<deviceId>-<deviceType>`. Devices whose
/// `connectionType` is `BLE` or `BLE/OpenAPI` are reached over Bluetooth LE where the spec pins their frames
/// (SwitchBotBluetooth.swift, BLEProtocol.swift); without a token, the block's devices are reached over Bluetooth alone.
/// See README.md in this directory.
public actor SwitchBotPlugin: HomeswiftPlugin {
    /// What the plugin uses to reach the cloud and to wait; tests swap them.
    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient()
        /// Every wait (polls, retries, the refresh after a command, the air conditioner's settle) is multiplied by it.
        var timeScale: Double = 1
        var now: @Sendable () -> Date = Date.init
        /// The address the webhook listener binds; tests bind the loopback.
        var webhookHost = "0.0.0.0"
        /// The webhook listener's port when not the URL's; tests pass 0.
        var webhookPort: Int?
        /// The Bluetooth adapter, shared with the other plugins (nil where this process may not use it); tests pass a fake.
        var bleCentral: @Sendable (Logger) throws -> (any BLECentral)? = { try Bluetooth.systemCentral(logger: $0) }
        /// Bluetooth's timeouts (not scaled: they bound a radio, not a wait of the plugin's).
        var bleTiming = SwitchBotBluetooth.Timing()
    }

    public static let platform = "SwitchBot"
    public static let name = "SwitchBot"
    public static let icon: String? = "plugin"
    public static let summary: String? = "Bots, curtains, meters, locks, lights and IR remotes through the SwitchBot cloud"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// The shortest interval between two polls of a device.
    static let minimumRefreshRate = 30.0

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var logger: Logger { context.logger }

    /// A device on the bridge.
    struct Entry {
        var info: DeviceInfo
        var accessory: DeviceAccessory
        var hap: Accessory
        /// Whether its status is polled: a physical device the cloud serves.
        var polled: Bool
        var interval: Duration
        /// The interval while it moves (`updateRate`) or a write waits.
        var update: Duration
        /// Its Bluetooth side, when its `connectionType` asks for Bluetooth and the spec pins its frames.
        var ble: BLEDevice?
        /// Whether the cloud reaches it: the only way, or the fallback of `BLE/OpenAPI`.
        var cloud = true
        /// Between two connected status reads (`blePollIntervalMs`), and whether they are made (`blePollingEnabled`).
        var bleInterval: Duration = .seconds(600)
        var blePolling = true
    }

    private(set) var entries: [String: Entry] = [:]
    /// Device ids (normalised) to Device Ids, for webhooks and linked meters.
    private var byCloudID: [String: String] = [:]
    private var pollTasks: [String: Task<Void, Never>] = [:]
    var failing: Set<String> = []
    /// Bluetooth, once a device needs it: nil until then, or when this process may not use it.
    var bluetooth: SwitchBotBluetooth?
    var bluetoothTried = false
    /// MACs (12 upper-case hex digits) to Device Ids, for advertisements.
    var byMAC: [String: String] = [:]
    /// The last sequence number each MAC advertised.
    var sequences: [String: UInt8] = [:]
    /// Devices whose Bluetooth problem was logged.
    var bluetoothWarned: Set<String> = []
    /// The cloud's last device list, for Setup and the settings.
    private(set) var latest: DeviceList?
    private var webhook: WebhookServer?
    private var registeredWebhookURL: String?
    private(set) var client: OpenAPIClient?
    let budget: RequestBudget

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        listedDevices = Self.index(configuration.deviceEntries)
        listedRemotes = Self.index(configuration.remoteEntries)
        budget = RequestBudget(
            limit: configuration.dailyApiLimit ?? 10_000, reserve: configuration.dailyApiReserveForCommands ?? 1_000,
            localMidnight: configuration.dailyApiResetLocalMidnight ?? false, file: context.jsonFile("requests.json"), now: dependencies.now)
    }

    func scaled(_ seconds: Double) -> Duration { .milliseconds(Int(saturating: max(seconds, 0) * 1000 * dependencies.timeScale) ?? 0) }

    /// The token and secret: the block's when it has them (Setup takes them out, so they were typed since: a rotated
    /// token), else Setup's, in the vault.
    var keys: (token: String, secret: String)? {
        if let token = configuration.token, let secret = configuration.secret { return (token, secret) }
        guard let stored = context.credentials(as: AccountKeys.self), !stored.token.isEmpty, !stored.secret.isEmpty else { return nil }
        return (stored.token, stored.secret)
    }

    func makeClient(token: String, secret: String, attempts: Int? = nil) -> OpenAPIClient {
        let options = configuration.platformOptions
        var settings = OpenAPIClient.Settings()
        settings.base = configuration.base
        settings.attempts = attempts ?? max(Int(saturating: options.number("maxRetries") ?? 2) ?? 2, 1)
        // Milliseconds at the platform level, as 4.x reads it.
        settings.retryDelay = scaled((options.number("delayBetweenRetries") ?? 3000) / 1000)
        return OpenAPIClient(token: token, secret: secret, settings: settings, http: dependencies.http, budget: budget, now: dependencies.now)
    }

    public func start() async throws {
        guard let keys else {
            // Without a token, the block's devices are reached over Bluetooth alone (§4.3).
            if let local = localDeviceList() {
                logger.info("No OpenAPI token: \(local.devices.count) device\(local.devices.count == 1 ? "" : "s") of the block over Bluetooth only")
                tasks.add { [weak self] in await self?.apply(local) }
                return
            }
            logger.warning("No OpenAPI token and secret: run Setup with the token and secret from the SwitchBot app (Profile, Preferences, App Version tapped ten times, Developer Options)")
            return
        }
        client = makeClient(token: keys.token, secret: keys.secret)
        tasks.add { [weak self] in await self?.discoverUntilListed() }
    }

    public func stop() async {
        tasks.cancelAll()
        for task in pollTasks.values { task.cancel() }
        pollTasks.removeAll()
        await webhook?.stop()
        webhook = nil
        if let url = registeredWebhookURL, let client {
            _ = try? await client.webhook("deleteWebhook", ["action": "deleteWebhook", "url": .string(url)], attempts: 1)
            registeredWebhookURL = nil
        }
        await budget.save()
        await bluetooth?.stop()
        for entry in entries.values { (entry.accessory as? LightAccessory)?.adaptiveLighting = nil }
    }

    // MARK: Discovery

    /// Lists the devices, retrying with a backoff while the cloud does not answer, then adds them and starts the polls
    /// and the webhook.
    private func discoverUntilListed() async {
        guard let client else { return }
        let backoff = Backoff(initial: scaled(5), maximum: scaled(300), jitter: .proportional(0.2))
        var attempt = 0
        while !Task.isCancelled {
            do {
                let list = try await client.deviceList(attempts: 1)
                if attempt > 0 { logger.info("SwitchBot's cloud answered the device list again") }
                await apply(list)
                await startWebhook()
                return
            } catch {
                if attempt == 0 { logger.error("Could not list the SwitchBot devices: \(error); retrying") }
                attempt += 1
                try? await Task.sleep(for: backoff.delay(attempt: attempt))
            }
        }
    }

    /// Adds an accessory for each device the rules expose (§4.2, §4.4), drops the others, and starts polling.
    func apply(_ list: DeviceList) async {
        latest = list
        var kept = Set<String>()
        var polled: [String] = []
        var bluetoothPolled: [String] = []
        var adds: [(DeviceInfo, Family?, RemoteFamily?)] = []
        for raw in list.devices {
            guard let info = physicalInfo(raw), !info.leftOut else { continue }
            guard let family = Family(deviceType: info.type) else {
                if !Family.silentlySkipped.contains(info.type) {
                    logger.warning("\(info.name) is a \(info.type), which this plugin does not support yet")
                }
                continue
            }
            adds.append((info, family, nil))
        }
        for raw in list.remotes {
            guard let info = remoteInfo(raw), !info.leftOut else { continue }
            guard let family = RemoteFamily(remoteType: info.type) else {
                logger.warning("\(info.name) is an IR remote of type \(info.type), which this plugin does not support")
                continue
            }
            adds.append((info, nil, family))
        }
        for (info, family, remote) in adds where !context.isExcluded(info.deviceID) {
            let id = context.accessoryID(of: info.deviceID)
            do {
                if entries[info.deviceID] == nil { try await add(info, family: family, remote: remote) }
                kept.insert(id)
                if let entry = entries[info.deviceID], entry.polled {
                    if entry.ble == nil { polled.append(info.deviceID) } else { bluetoothPolled.append(info.deviceID) }
                }
            } catch {
                logger.error("Could not add \(info.name): \(error)")
            }
        }
        for id in await context.removeAccessories(keeping: kept) {
            if let deviceID = context.deviceID(ofAccessory: id) { forget(deviceID) }
        }
        let intervals = polled.map { entries[$0]!.interval }
        if let shortest = intervals.min() {
            let limit = budget.limit, reserve = budget.reserve
            let stretched = max(shortest, scaled(RequestBudget.pollSeconds(devices: polled.count, limit: limit, reserve: reserve)))
            if stretched > shortest {
                logger.warning("\(polled.count) devices polled every \(shortest) would use more than the day's \(limit - reserve) requests: polling every \(stretched)")
            }
            for (index, deviceID) in polled.enumerated() {
                let interval = max(entries[deviceID]!.interval, stretched)
                entries[deviceID]!.interval = interval
                // A first status for each, a moment apart.
                if pollTasks[deviceID] == nil { startPolling(deviceID, after: scaled(Double(index) * 0.2)) }
            }
        }
        // Devices on Bluetooth stay out of the day's requests: a connected read (a lock's info) at once, an advertising
        // device checked once its interval passed.
        for (index, deviceID) in bluetoothPolled.enumerated() where pollTasks[deviceID] == nil {
            guard let entry = entries[deviceID], let ble = entry.ble else { continue }
            startPolling(deviceID, after: ble.model.hasRead ? scaled(Double(index) * 0.2) : entry.interval)
        }
    }

    private func forget(_ deviceID: String) {
        pollTasks.removeValue(forKey: deviceID)?.cancel()
        if let entry = entries.removeValue(forKey: deviceID) {
            byCloudID.removeValue(forKey: normalizedID(entry.info.id))
            if let mac = entry.ble?.mac { byMAC.removeValue(forKey: mac) }
        }
    }

    /// The device's entry in the Homebridge-shaped list, by its id compared as 4.x compares it.
    func listedEntry(_ id: String, remote: Bool) -> DeviceOptions? {
        (remote ? listedRemotes : listedDevices)?[normalizedID(id)]
    }

    /// The Homebridge-shaped lists by normalised id, nil without a list: read once, the block does not change while
    /// the instance runs.
    let listedDevices: [String: DeviceOptions]?
    let listedRemotes: [String: DeviceOptions]?

    static func index(_ list: [DeviceOptions]?) -> [String: DeviceOptions]? {
        guard let list, !list.isEmpty else { return nil }
        var index: [String: DeviceOptions] = [:]
        for entry in list { if let id = entry.deviceID { index[normalizedID(id)] = index[normalizedID(id)] ?? entry } }
        return index
    }

    /// The Device Id of a device: the listed spelling of its id, or an `_accessories` key that spells it so, else the
    /// cloud's, followed by its type.
    func deviceID(cloudID: String, type: String, listed: DeviceOptions?) -> String {
        if let spelled = listed?.deviceID { return "\(spelled)-\(type)" }
        let key = normalizedID(cloudID), suffix = "-\(type)"
        if let found = context.allAccessorySettings.keys.sorted().first(where: { $0.hasSuffix(suffix) && normalizedID(String($0.dropLast(suffix.count))) == key }) {
            return found
        }
        return "\(cloudID)\(suffix)"
    }

    /// Whether a Homebridge-shaped list leaves a device out: with a list, only the devices it names (and those whose
    /// Accessory Settings it was moved into) are exposed.
    func leftOutByList(_ deviceID: String, listed: DeviceOptions?, remote: Bool) -> Bool {
        guard (remote ? listedRemotes : listedDevices) != nil else { return false }
        return listed == nil && context.allAccessorySettings[deviceID] == nil
    }

    func physicalInfo(_ raw: [String: JSONValue]) -> DeviceInfo? {
        guard let cloudID = raw["deviceId"]?.stringValue, !cloudID.isEmpty else { return nil }
        let listed = listedEntry(cloudID, remote: false)
        guard let type = raw["deviceType"]?.stringValue?.nonEmpty ?? listed?.string("configDeviceType") else { return nil }
        let deviceID = deviceID(cloudID: cloudID, type: type, listed: listed)
        var options = DeviceOptions(raw).merged(configuration.typeOptions(type, remote: false))
        if let listed { options = options.merged(listed.values) }
        options = options.merged(context.accessorySettings(for: deviceID).plugin)
        // A secondary curtain or blind of a group: its master moves the group.
        if ["Curtain", "Curtain3", "Blind Tilt"].contains(type), raw["master"]?.boolValue == false, !options.flag("disable_group") {
            logger.debug("\(raw["deviceName"]?.stringValue ?? cloudID) is the secondary device of a group: its master drives it")
            return nil
        }
        return DeviceInfo(
            id: cloudID, deviceID: deviceID, type: type, name: displayName(options, raw), options: options, isRemote: false,
            firmware: normalizedVersion(options.string("firmware") ?? raw["version"]?.stringValue) ?? "0.0.0",
            leftOut: options.flag("hide_device") || leftOutByList(deviceID, listed: listed, remote: false))
    }

    func remoteInfo(_ raw: [String: JSONValue]) -> DeviceInfo? {
        guard let cloudID = raw["deviceId"]?.stringValue, !cloudID.isEmpty, raw["hubDeviceId"]?.stringValue?.nonEmpty != nil else { return nil }
        let listed = listedEntry(cloudID, remote: true)
        guard let type = raw["remoteType"]?.stringValue?.nonEmpty ?? listed?.string("configRemoteType") else {
            logger.error("The IR remote \(raw["deviceName"]?.stringValue ?? cloudID) has no remoteType: give it a configRemoteType")
            return nil
        }
        let deviceID = deviceID(cloudID: cloudID, type: type, listed: listed)
        var options = DeviceOptions(raw).merged(configuration.typeOptions(type, remote: true))
        if let listed { options = options.merged(listed.values) }
        options = options.merged(context.accessorySettings(for: deviceID).plugin)
        return DeviceInfo(
            id: cloudID, deviceID: deviceID, type: type, name: displayName(options, raw), options: options, isRemote: true,
            firmware: normalizedVersion(options.string("firmware")) ?? "0.0.0",
            leftOut: options.flag("hide_device") || leftOutByList(deviceID, listed: listed, remote: true))
    }

    func displayName(_ options: DeviceOptions, _ raw: [String: JSONValue]) -> String {
        let name = options.string("configDeviceName") ?? raw["deviceName"]?.stringValue ?? raw["deviceId"]?.stringValue ?? "SwitchBot"
        guard !configuration.platformOptions.flag("allowInvalidCharacters") else { return name }
        let cleaned = cleanedName(name)
        if cleaned != name { logger.debug("\(name) has characters HomeKit does not take: named \(cleaned)") }
        return cleaned.isEmpty ? (raw["deviceId"]?.stringValue ?? "SwitchBot") : cleaned
    }

    // MARK: Accessories

    private func deviceLogger(_ options: DeviceOptions) -> Logger {
        var logger = context.logger
        switch options.string("logging") ?? configuration.platformOptions.string("logging") {
        case "debug": logger.logLevel = min(logger.logLevel, .debug)
        case "none": logger.logLevel = .critical
        default: break
        }
        return logger
    }

    private func add(_ info: DeviceInfo, family: Family?, remote: RemoteFamily?) async throws {
        let logger = deviceLogger(info.options)
        let debounce = scaled(info.options.number("pushRate") ?? configuration.debounceSeconds)
        let update = scaled(max(info.options.number("updateRate") ?? configuration.platformOptions.number("updateRate") ?? 5, 1))
        var route = route(info)
        if route.bluetooth != nil {
            await openBluetooth()
            if bluetooth == nil, route.cloud { route.bluetooth = nil }
        }
        let usable = (usable: route.usable, reason: route.reason)
        let link = makeLink(info, usable: usable.usable)
        let accessory: DeviceAccessory
        if let remote {
            let meter = info.options.string("meterId").map(normalizedID)
            let meterType = info.options.string("meterType")
            let lookup: @Sendable () -> Double? = { [weak self] in
                guard let self, let meter else { return nil }
                return self.meterTemperatures.withLockedValue { $0[meter] }.flatMap { meterType == nil || $0.type == meterType ? $0.celsius : nil }
            }
            accessory = RemoteAccessory(info: info, family: remote, link: link, settle: scaled(1.5), meterTemperature: lookup, logger: logger)
        } else {
            switch family! {
            case .bot, .relay, .plug:
                accessory = SwitchAccessory(
                    info: info, family: family!, link: link, debounce: debounce, pressInterval: scaled(info.options.number("pushRatePress") ?? 15), logger: logger)
            case .curtain, .rollerShade, .blindTilt:
                accessory = CoveringAccessory(info: info, family: family!, link: link, debounce: debounce, updateRate: update, logger: logger)
            case .meter, .hub, .motion, .contact, .presence, .waterDetector:
                accessory = SensorAccessory(
                    info: info, family: family!, co2Threshold: configuration.co2AbnormalThreshold ?? 1000, link: link, debounce: debounce, logger: logger)
            case .lock: accessory = LockAccessory(info: info, link: link, debounce: debounce, logger: logger)
            case .light: accessory = LightAccessory(info: info, link: link, debounce: debounce, logger: logger)
            case .humidifier: accessory = HumidifierAccessory(info: info, link: link, debounce: debounce, logger: logger)
            case .fan: accessory = FanAccessory(info: info, link: link, debounce: debounce, logger: logger)
            case .vacuum: accessory = VacuumAccessory(info: info, link: link, debounce: debounce, logger: logger)
            case .airPurifier: accessory = AirPurifierAccessory(info: info, link: link, debounce: debounce, logger: logger)
            }
        }
        let id = context.accessoryID(of: info.deviceID)
        if let light = accessory as? LightAccessory, light.wantsAdaptiveLighting {
            light.adaptiveLighting = context.adaptiveLighting(for: light.lightbulb, accessoryID: id, customTemperatureAdjustment: light.adaptiveLightingShift)
        }
        let hap = Accessory(
            id: id, name: info.name, manufacturer: "SwitchBot", model: info.isRemote ? info.type : modelCode(info.type), serialNumber: info.id,
            firmwareRevision: info.firmware, category: accessory.category, services: accessory.services)
        hap.information.characteristic(adding: .hardwareRevision).value = .string(info.firmware)
        hap.information.characteristic(adding: .appMatchingIdentifier).value = .string("id1087374760")
        if let cached = context.accessory(id: id) { hap.takeValues(from: cached) }
        if !usable.usable {
            logger.debug("\(info.type) \(info.name): \(usable.reason); no requests are sent")
            if info.options.flag("offline") { accessory.showOffline() }
        }
        let external = (accessory as? RemoteAccessory)?.isExternal ?? info.options.flag("external")
        if external { try await context.publishExternal(hap) } else { try context.add(hap) }
        let pollMilliseconds = info.options.number("blePollIntervalMs") ?? configuration.blePollIntervalMs ?? 600_000
        entries[info.deviceID] = Entry(
            info: info, accessory: accessory, hap: hap, polled: !info.isRemote && usable.usable,
            interval: scaled(max(info.options.number("refreshRate") ?? configuration.refreshRate, Self.minimumRefreshRate)), update: update,
            ble: route.bluetooth, cloud: route.cloud, bleInterval: scaled(max(pollMilliseconds, 60_000) / 1000),
            blePolling: info.options.bool("blePollingEnabled") ?? configuration.blePollingEnabled ?? true)
        byCloudID[normalizedID(info.id)] = info.deviceID
        if let ble = route.bluetooth {
            byMAC[ble.mac] = info.deviceID
            logger.debug("\(info.type) \(info.name): over Bluetooth at \(colonMAC(ble.mac))\(route.cloud ? ", the cloud as its fallback" : "")")
        }
    }

    // The route of each device (`connectionType`) is in SwitchBotPlugin+Bluetooth.swift.

    /// The last temperature of each meter, by normalised id, for linked air conditioners.
    nonisolated let meterTemperatures = NIOLockedValueBox<[String: (type: String, celsius: Double)]>([:])

    private func makeLink(_ info: DeviceInfo, usable: Bool) -> DeviceLink {
        DeviceLink { [weak self] commands in
            guard let self, usable else { throw HAPStatusError(.serviceCommunicationFailure) }
            return try await self.send(commands, to: info)
        }
    }

    /// Sends commands in turn; a refusal is logged and stops the rest. The cloud's silence throws, as No Response.
    func send(_ commands: [Command], to info: DeviceInfo) async throws -> Bool {
        guard let entry = entries[info.deviceID] else { throw HAPStatusError(.serviceCommunicationFailure) }
        if entry.ble != nil, let accepted = try await sendOverBluetooth(commands, entry: entry) { return accepted }
        guard let client, entry.cloud else { throw HAPStatusError(.serviceCommunicationFailure) }
        let logger = entry.accessory.logger
        var accepted = true
        for command in commands {
            let response: OpenAPI.Response
            do {
                response = try await client.send(command, to: info.id)
            } catch {
                logger.error("\(info.type) \(info.name): \(command) failed: \(error)")
                markUnreachable(info.deviceID, true)
                throw HAPStatusError(.serviceCommunicationFailure)
            }
            markUnreachable(info.deviceID, false)
            if response.succeeded {
                logger.debug("\(info.type) \(info.name): sent \(command)")
            } else {
                logger.error("\(info.type) \(info.name): \(command) refused: \(response.failure)")
                accepted = false
                break
            }
        }
        // A refresh shortly after, to show what the device did (sooner while a curtain moves).
        if entry.polled { startPolling(info.deviceID, after: entry.accessory.isMoving ? entry.update : scaled(15)) }
        return accepted
    }

    func markUnreachable(_ deviceID: String, _ unreachable: Bool) {
        // Unreachable, not unavailable: No Response shows, and HomeKit's next write still tries the cloud (an IR remote is
        // never polled, so only a write can find it answering again).
        guard let entry = entries[deviceID], entry.hap.isUnreachable != unreachable else { return }
        entry.hap.isUnreachable = unreachable
    }

    // MARK: Polling

    func startPolling(_ deviceID: String, after delay: Duration) {
        pollTasks[deviceID]?.cancel()
        pollTasks[deviceID] = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                do { try await Task.sleep(for: wait) } catch { return }
                guard let self, let next = await self.poll(deviceID) else { return }
                wait = next
            }
        }
    }

    /// One status of a device, then the wait before the next: its interval, or `updateRate` while it moves.
    func poll(_ deviceID: String) async -> Duration? {
        guard let entry = entries[deviceID] else { return nil }
        let info = entry.info
        let logger = entry.accessory.logger
        if entry.accessory.isWriting { return entry.update }
        if entry.ble != nil {
            switch await pollOverBluetooth(entry) {
            case .next(let wait): return wait
            case .stop: return nil
            case .cloud: break
            }
        }
        guard entry.cloud, let client else { return nil }
        let allowed = await budget.allowsPoll { used in
            logger.warning("\(used) SwitchBot requests made today: polls stop until midnight, keeping the rest for commands")
        }
        guard allowed else { return entry.interval }
        do {
            let response = try await client.status(info.id)
            if failing.remove(deviceID) != nil { logger.info("\(info.type) \(info.name) answers again") }
            markUnreachable(deviceID, false)
            if response.succeeded, let status = response.body.objectValue {
                show(status, on: entry, webhook: false)
            } else if !response.succeeded {
                logger.error("\(info.type) \(info.name): status refused: \(response.failure)")
            }
        } catch is CancellationError {
            return nil
        } catch {
            if failing.insert(deviceID).inserted { logger.error("\(info.type) \(info.name): \(error)") }
            markUnreachable(deviceID, true)
        }
        return entry.accessory.isMoving ? entry.update : entry.interval
    }

    func show(_ status: [String: JSONValue], on entry: Entry, webhook: Bool) {
        // A write waiting for its debounce or on its way wins over a report that crossed it: the refresh after its
        // command shows what the device did.
        guard !entry.accessory.isWriting || entry.accessory is SensorAccessory else { return }
        entry.accessory.show(status, webhook: webhook)
        if let sensor = entry.accessory as? SensorAccessory, let celsius = sensor.lastTemperature {
            meterTemperatures.withLockedValue { $0[normalizedID(entry.info.id)] = (entry.info.type, celsius) }
        }
        if let version = normalizedVersion(status["version"]?.stringValue), entry.info.options.string("firmware") == nil {
            entry.hap.information.characteristic(.firmwareRevision).value = .string(version)
            entry.hap.information[.hardwareRevision]?.value = .string(version)
        }
    }

    // MARK: Webhooks

    /// The secret last segment of the webhook's path, made once and kept in the vault.
    struct WebhookSecret: Codable { var segment: String }

    /// The URL registered with the cloud: `webhookURL` with the secret segment after its path.
    func webhookAddress(_ url: URL) -> (url: String, path: String) {
        // In the vault; a plain webhook.json (an earlier build's) moves there the first time it is read.
        let file = context.secretFile("webhook.json", as: WebhookSecret.self)
        let segment: String
        if let saved = file.load()?.segment, saved.count >= 32 {
            segment = saved
        } else {
            segment = Secrets.randomToken()
            try? file.save(WebhookSecret(segment: segment))
        }
        var base = url.path
        while base.hasSuffix("/") { base.removeLast() }
        let path = "\(base)/\(segment)"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        return (components?.string ?? url.absoluteString, path)
    }

    /// The port the webhook listener bound, once it listens.
    var webhookListeningPort: Int? { webhook?.port }

    private func startWebhook() async {
        guard webhook == nil, let url = configuration.webhookURL, let client else { return }
        let (address, path) = webhookAddress(url)
        let server = WebhookServer(path: path, logger: logger) { [weak self] event in await self?.handleWebhook(event) }
        let port = dependencies.webhookPort ?? url.port ?? (url.scheme == "https" ? 443 : 80)
        do {
            try await server.start(host: dependencies.webhookHost, port: port)
        } catch {
            logger.error("Could not listen for SwitchBot's webhook on port \(port): \(error)")
            return
        }
        webhook = server
        logger.info("Listening for SwitchBot's webhook on port \(server.port ?? port)")
        let retry = scaled(1)
        let setup = try? await client.webhook("setupWebhook", ["action": "setupWebhook", "url": .string(address), "deviceList": "ALL"], attempts: 3, retryDelay: retry)
        var registered = setup?.succeeded == true
        if !registered, let query = try? await client.webhook("queryWebhook", ["action": "queryUrl"], attempts: 1) {
            let urls = query.body["urls"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if urls.contains(address) {
                // This URL already: make sure it is on.
                let update = try? await client.webhook("updateWebhook", ["action": "updateWebhook", "config": ["url": .string(address), "enable": true]], attempts: 3, retryDelay: retry)
                registered = update?.succeeded == true
            } else if !urls.isEmpty {
                // The account keeps one URL: another integration's (or an earlier one of this bridge's) goes.
                logger.warning("Replacing the webhook URL registered for the SwitchBot account (\(urls.count) URL\(urls.count == 1 ? "" : "s"))")
                for url in urls { _ = try? await client.webhook("deleteWebhook", ["action": "deleteWebhook", "url": .string(url)], attempts: 1) }
                let again = try? await client.webhook("setupWebhook", ["action": "setupWebhook", "url": .string(address), "deviceList": "ALL"], attempts: 3, retryDelay: retry)
                registered = again?.succeeded == true
            }
        }
        if registered {
            registeredWebhookURL = address
            logger.info("SwitchBot's webhook is registered")
        } else {
            logger.error("Could not register SwitchBot's webhook: \(setup?.failure ?? "no answer")")
        }
    }

    /// A webhook event: its `context` shown on the device whose id is `deviceMac`, when the device has `webhook`.
    func handleWebhook(_ event: JSONValue) {
        guard let fields = (event["context"] ?? event).objectValue, let mac = fields["deviceMac"]?.stringValue,
              let deviceID = byCloudID[normalizedID(mac)], let entry = entries[deviceID] else { return }
        guard entry.info.options.flag("webhook") else { return }
        logger.debug("Webhook for \(entry.info.type) \(entry.info.name)")
        show(fields, on: entry, webhook: true)
    }
}

/// The account's keys as the vault keeps them (Setup's).
struct AccountKeys: Codable, Sendable, Equatable {
    var token: String
    var secret: String
}
