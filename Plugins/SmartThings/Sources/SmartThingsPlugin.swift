import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Samsung SmartThings through its cloud API (docs/clean-room/SmartThings.md): every device of the authorized location
/// as an accessory whose services come from its capabilities (lights, switches, outlets, fans, thermostats, air
/// conditioners and purifiers, locks, garage doors, shades, valves, sensors, buttons, security systems), Samsung
/// appliances with a power or Start switch and a "Running" sensor, TVs as Televisions published on their own, and
/// SmartThings scenes as momentary switches.
///
/// The blocks of homebridge-smartthings-oauth and homebridge-smartthings-ik load unchanged (`HomeBridgeSmartThings`,
/// SmartThingsSettings.swift). Signing in is Setup's (SmartThingsSetup.swift): the person's own OAuth-In app, its
/// redirect caught by an HTTPS callback server or pasted. Updates come by server-sent events when the token has the
/// `sse` scope, else by one device list call per period. See README.md in this directory.
public actor SmartThingsPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// The block as it is: read leniently (SmartThingsSettings.swift).
        public var raw: JSONValue

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder)
        }

        init(raw: JSONValue) { self.raw = raw }
    }

    /// What the plugin reaches SmartThings with; tests swap them.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        var streaming: any HTTPStreaming = HTTPClient()
        var timing = SmartThingsTiming()
        var now: @Sendable () -> Date = Date.init
        var addresses: @Sendable () -> [String] = NetworkAddresses.ipv4
        /// SmartThings' per-device limit (12 a minute); tests count against a shorter one.
        var deviceLimiter: RateLimiter?
        /// Where the callback server listens.
        var callbackBindAddress = "0.0.0.0"
        /// No message on the event stream for this long is a gap (section 5.1); seconds, scaled by `timing`.
        var watchdogSeconds: Double = 300
    }

    public static let platform = "HomeBridgeSmartThings"
    public static let name = "SmartThings"
    public static let icon: String? = "house"
    public static let summary: String? = "Devices, appliances, TVs and scenes of a SmartThings location"
    public static let assistantBackground: String? = """
        The SmartThings plugin reaches Samsung's SmartThings cloud (api.smartthings.com) with the person's own OAuth-In app, signed in \
        through Setup; since 2026 the API needs a SmartThings Developer plan (100,000 calls a month). Updates come by server-sent events \
        when the app has the sse scope, else by one device list call per poll period (60 s at the least). "HTTP 403" means no plan or a \
        missing scope; "refused the saved sign-in" means the refresh token is gone: sign in again on Add accessories. Devices copied from \
        Homeswift's own Matter bridge are skipped. A Matter device may already be in Apple Home: set it Not in Home with update_settings.
        """
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    static let tokenFileName = "smartthings_tokens.json"
    static let certificateDirectoryName = "smartthings-certs"
    static let authorizationWindow: Duration = .seconds(600)

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let settings: SmartThingsSettings
    let tokens: TokenStore
    let api: SmartThingsAPI
    let callbackServer: CallbackServer
    let tasks = TaskBag()
    var logger: Logger { context.logger }
    var timing: SmartThingsTiming { dependencies.timing }

    // The devices.
    var bindings: [String: DeviceBinding] = [:]
    var listed: [SmartThingsDevice] = []
    var listedAt: Date?
    var copies: [String: (device: SmartThingsDevice, match: MatterCopies.Match)] = [:]
    var unsupported: [String: SmartThingsDevice] = [:]
    var kinds: [String: String] = [:]
    var missing: [String: Int] = [:]
    var locationNames: [String: String] = [:]
    var locationID: String?
    var rooms: [String: String] = [:]
    var roomsReadAt: Date?
    var scenes: [SmartThingsScene] = []
    var sceneAccessories: [String: Accessory] = [:]
    var loggedOnce = Set<String>()
    var followUps: [String: Task<Void, Never>] = [:]
    var statusFailures: [String: Date] = [:]
    var rediscovery: Task<Void, Never>?
    var stopped = false

    // The event stream.
    var sseActive = false
    var sseNote: String?
    var subscriptionID: String?
    var lastReconcileFailure: String?

    // Setup's sign-in, on the instance whose callback server listens.
    var pendingAuth: PendingAuth?
    var authResult: Result<Void, SetupError>?

    struct PendingAuth: Sendable {
        var state: String
        var clientID: String
        var clientSecret: String
        var redirectURI: String
        var createdAt: Date
    }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        let settings = SmartThingsSettings(configuration.raw, credentials: context.credentials())
        self.settings = settings
        let oauth = settings.clientID.flatMap { id in
            settings.clientSecret.map { SmartThingsOAuth(base: settings.baseURL, clientID: id, clientSecret: $0, http: dependencies.transport) }
        }
        var refresh: TokenStore.Refresh?
        if let oauth { refresh = { token in try await oauth.refresh(token) } }
        let refused: @Sendable (String) -> Void = { [context] reason in context.accountRefused(reason) }
        tokens = TokenStore(file: context.secretFile(Self.tokenFileName, as: StoredTokens.self), refresh: refresh, now: dependencies.now,
                            logger: context.logger, onRefused: refused)
        api = SmartThingsAPI(base: settings.baseURL, http: dependencies.transport, streaming: dependencies.streaming, tokens: tokens,
                             timing: dependencies.timing, logger: context.logger, deviceLimiter: dependencies.deviceLimiter)
        callbackServer = CallbackServer(logger: context.logger)
        locationID = settings.locationID
    }

    // MARK: Lifecycle

    public func start() async throws {
        do {
            _ = try settings.checkedBaseURL()
        } catch {
            logger.error("\(error)")
            return
        }
        for key in settings.presentIgnoredKeys { logger.debug("\(key) is kept from the Homebridge plugin and has no effect in Homeswift") }
        if settings.hasWebhookOptions {
            logger.info("The webhook options are ignored: a webhook needs a public HTTPS address. Updates come by server-sent events or polling.")
        }
        await importTokens()
        guard await tokens.isSignedIn else {
            logger.warning("Not signed in to SmartThings: sign in on Add accessories (Setup) with your own SmartThings app")
            return
        }
        if await tokens.isPersonal {
            logger.warning("Signed in with a personal access token (AccessToken): it expires after 24 hours and cannot be refreshed. Sign in with your own SmartThings app on Add accessories.")
        }
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        stopped = true
        tasks.cancelAll()
        rediscovery?.cancel()
        for task in followUps.values { task.cancel() }
        followUps.removeAll()
        if let subscriptionID { await api.deleteSubscription(subscriptionID) }
        await callbackServer.stop()
    }

    /// The first reconciliation, then events or polling, and the proactive token refresh.
    private func run() async {
        await readLocations()
        await reconcile()
        await refreshScenes()
        tasks.add { [weak self] in await self?.refreshLoop() }
        if await tokens.grantsSSE {
            tasks.add { [weak self] in await self?.eventLoop() }
        } else if !(await tokens.isPersonal) {
            logger.info("The SmartThings app has no sse scope: updates come by polling")
        }
        await pollLoop()
    }

    /// Refreshes the access token when 75 % of its life has gone (section 3.6).
    private func refreshLoop() async {
        while !Task.isCancelled, !stopped {
            guard let due = await tokens.refreshDue else { return }
            let wait = due.timeIntervalSince(dependencies.now())
            if wait > 0 {
                try? await Task.sleep(for: .seconds(min(wait, 3600)))
                continue
            }
            do {
                try await tokens.refresh()
            } catch let failure as TokenStore.Failure {
                if case .refused = failure { return }
                try? await Task.sleep(for: timing.seconds(60))
            } catch {
                try? await Task.sleep(for: timing.seconds(60))
            }
        }
    }

    /// The poll period (section 5.3): one reconciliation a period, every 30 minutes while events come.
    var pollPeriod: Double {
        if sseActive { return 1800 }
        return settings.pollSeconds() ?? 1800
    }

    private func pollLoop() async {
        var projected: Double?
        while !Task.isCancelled, !stopped {
            let period = pollPeriod
            if projected != period, !sseActive {
                projected = period
                let calls = Int(Double(max(1, await api.lastListPages)) * 86400 / period * 30)
                let message = "Polling SmartThings every \(Int(period)) s: about \(calls) calls a month for the device list (the Developer plan allows 100,000)"
                if calls > 60000 { logger.warning("\(message): set a longer Poll*Seconds") } else { logger.info("\(message)") }
            }
            try? await Task.sleep(for: timing.seconds(period))
            guard !Task.isCancelled, !stopped else { return }
            if await tokens.refusal != nil { return }
            await reconcile()
        }
    }

    // MARK: Tokens

    /// The block's starting tokens (sections 3.9 and 3.10), when the vault has none or the wizard ran again.
    func importTokens() async {
        let raw = settings
        let now = dependencies.now()
        if let refresh = raw.text("oauth_refresh_token"), let access = raw.text("oauth_access_token") {
            let hash = StoredTokens.sha256(refresh)
            let current = await tokens.tokens
            // The vault wins, unless it was seeded from another refresh token of the block (aziz66's rule, section 3.7).
            if current == nil || (current?.seeded_from_config_refresh_token_sha256.map { $0 != hash } ?? false) {
                var seeded = StoredTokens(accessToken: access, refreshToken: refresh, expiresIn: Double(raw.integer("oauth_expires_in") ?? 86400), now: now)
                seeded.seeded_from_config_refresh_token_sha256 = hash
                seeded.location_id = locationID
                do {
                    try await tokens.seed(seeded)
                    logger.info("Took the SmartThings tokens of the block into the vault")
                } catch {
                    logger.error("Could not save the SmartThings tokens to the vault: \(error)")
                }
            }
        } else if let pat = raw.text("AccessToken"), await tokens.tokens == nil {
            do {
                try await tokens.seed(StoredTokens(accessToken: pat, refreshToken: nil, expiresIn: 86400, now: now, personal: true))
            } catch {
                logger.error("Could not save the SmartThings access token to the vault: \(error)")
            }
        }
        if locationID == nil { locationID = await tokens.tokens?.location_id }
    }

    // MARK: Locations

    func readLocations() async {
        do {
            let items = try await api.locations()
            locationNames = Dictionary(items.compactMap { item in item["locationId"]?.stringValue.map { ($0, item["name"]?.stringValue ?? $0) } }, uniquingKeysWith: { a, _ in a })
            if locationID == nil, locationNames.count == 1 { locationID = locationNames.keys.first }
        } catch {
            logger.debug("Could not list the SmartThings locations: \(error)")
        }
    }

    // MARK: Reconciliation (section 5.2)

    /// Reads every device's status and health in one list call, adds the new ones, rebuilds the changed ones.
    func reconcile() async {
        let requestedAt = dependencies.now()
        let items: [JSONValue]
        do {
            items = try await api.devices(locationID: locationID)
        } catch {
            await failed(error)
            return
        }
        if lastReconcileFailure != nil {
            logger.info("SmartThings answers again")
            lastReconcileFailure = nil
        }
        context.accountAccepted()
        apply(items, requestedAt: requestedAt)
    }

    func failed(_ error: any Error) async {
        let message = "\(error)"
        if let failure = error as? TokenStore.Failure, case .refused = failure { return }
        if case SmartThingsError.http(403, _, _)? = error as? SmartThingsError {
            context.accountRefused("SmartThings refused access: check your Developer plan and the app's scopes")
        }
        if lastReconcileFailure == nil { logger.warning("Could not read the SmartThings devices: \(message)") }
        lastReconcileFailure = message
    }

    func apply(_ items: [JSONValue], requestedAt: Date) {
        let pairs = items.compactMap { item in SmartThingsDevice(item).map { (item, $0) } }
        let devices = pairs.map(\.1)
        listed = devices
        listedAt = dependencies.now()
        let found = MatterCopies.find(in: devices, homeswiftIDs: context.hostAccessories.map(\.id))
        copies = [:]
        var present = Set<String>()
        for (item, device) in pairs {
            let id = device.deviceID
            present.insert(id)
            if let match = found[id] {
                copies[id] = (device, match)
                // Found after it was shown (the host's accessories were not all up yet): it leaves the bridge now.
                if let binding = bindings.removeValue(forKey: id) {
                    followUps.removeValue(forKey: id)?.cancel()
                    removeAccessory(binding.accessory.id)
                }
                missing[id] = nil
                if loggedOnce.insert("copy:\(id)").inserted {
                    logger.info("Skipping \(device.displayName): it is Homeswift's own accessory through Homeswift's Matter bridge")
                }
                continue
            }
            missing[id] = nil
            let status = DeviceStatus(listed: item)
            let listedOut = settings.excludedByLists(device, locationNames: locationNames)
            if context.isExcluded(id) || listedOut || device.isHub {
                if device.isHub { unsupported[id] = device; kinds[id] = "unsupported" }
                bindings[id] = nil
                // The runtime takes an Excluded device's accessory off; one the block's own lists leave out goes here.
                if listedOut || device.isHub { removeAccessory(Self.accessoryID(id)) }
                continue
            }
            show(device, status: status, requestedAt: requestedAt)
        }
        // A device gone from the list: No Response until the next list confirms, then removed.
        for (id, binding) in bindings where !present.contains(id) {
            missing[id, default: 0] += 1
            binding.accessory.isUnavailable = true
            if missing[id, default: 0] >= 2 {
                bindings[id] = nil
                missing[id] = nil
                let accessoryID = binding.accessory.id
                Task { try? await self.context.remove(id: accessoryID) }
            }
        }
        unsupported = unsupported.filter { present.contains($0.key) }
    }

    /// Updates a device's accessory, or builds it (again) when it is new or its shape changed.
    func show(_ device: SmartThingsDevice, status: DeviceStatus, requestedAt: Date) {
        let id = device.deviceID
        let options = deviceOptions(device)
        let signature = Self.signature(device, status: status, options: options, settings: settings)
        if let binding = bindings[id], binding.signature == signature {
            let previous = binding.box.status
            binding.box.merge(status, requestedAt: requestedAt)
            if !sseActive, binding.hasEventHooks { binding.pollPresses(previous: previous, current: binding.box.status) }
            return
        }
        guard let binding = build(device, status: status, options: options, signature: signature, context: context) else {
            unsupported[id] = device
            kinds[id] = "unsupported"
            bindings[id] = nil
            removeAccessory(Self.accessoryID(id))
            return
        }
        unsupported[id] = nil
        kinds[id] = binding.kind
        let old = bindings[id]
        if let old { binding.accessory.services.forEach { service in
            if let previous = old.accessory.services.first(where: { $0.type == service.type && $0.subtype == service.subtype }) { service.takeValues(from: previous) }
        } }
        bindings[id] = binding
        binding.show(binding.box.status)
        let accessory = binding.accessory
        if binding.isTelevision, settings.publishTVsAsExternal {
            Task { [context, logger] in
                do { try await context.publishExternal(accessory) } catch { logger.error("Could not publish \(device.displayName): \(error)") }
            }
        } else {
            do {
                try context.add(accessory)
            } catch {
                logger.error("Could not add \(device.displayName): \(error)")
            }
        }
        if device.isMatter, loggedOnce.insert("matter:\(id)").inserted {
            logger.info("\(device.displayName) is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.")
        }
    }

    /// Takes an accessory the cache still has off the bridge.
    func removeAccessory(_ accessoryID: String) {
        guard context.accessory(id: accessoryID) != nil else { return }
        Task { [context] in try? await context.remove(id: accessoryID) }
    }

    func deviceOptions(_ device: SmartThingsDevice) -> DeviceOptions {
        DeviceOptions(settings: settings, plugin: context.accessorySettings(for: device.deviceID).plugin, deviceName: device.label ?? device.name ?? "")
    }

    /// What a device's accessory is built from: its capabilities, its options and the status values that shape it (lists
    /// of modes, ranges, which sensors reported).
    static func signature(_ device: SmartThingsDevice, status: DeviceStatus, options: DeviceOptions, settings: SmartThingsSettings) -> String {
        var parts = [device.displayName, device.type ?? "", device.allowed?.joined(separator: ",") ?? ""]
        parts += device.components.map { "\($0.id):\($0.capabilities.sorted().joined(separator: ","))|\($0.categories.joined(separator: ","))|\($0.label ?? "")" }
        parts.append("\(options)")
        for (component, capabilities) in status.components.sorted(by: { $0.key < $1.key }) {
            for (capability, attributes) in capabilities.sorted(by: { $0.key < $1.key }) {
                for (attribute, value) in attributes.sorted(by: { $0.key < $1.key }) {
                    let shaping = attribute.hasPrefix("supported") || attribute.hasPrefix("available") || attribute.hasSuffix("Range")
                        || attribute.hasSuffix("Map") || attribute == "disabledComponents"
                    if shaping { parts.append("\(component).\(capability).\(attribute)=\(value.value.text())") }
                    if Sensor.all.contains(where: { $0.capability == capability && $0.attribute == attribute }) {
                        parts.append("\(component).\(capability).\(attribute)?\(value.value.nonNull != nil)")
                    }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Builds a device's accessory; nil when nothing maps (section 7.6). `context` nil builds without side effects (no
    /// Adaptive Lighting, no Meter): what discovery uses for a device's kind.
    func build(_ device: SmartThingsDevice, status: DeviceStatus, options: DeviceOptions, signature: String, context: PluginContext?) -> DeviceBinding? {
        let id = device.deviceID
        let box = StatusBox(status)
        let env = BindingEnvironment(
            deviceID: id, timing: timing, logger: logger, now: dependencies.now,
            send: { [weak self] commands, watched in
                guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
                try await self.send(deviceID: id, commands, watched: watched)
            },
            controllable: device.isControllable, sliders: LatestCallGuard(delay: timing.seconds(0.3)))
        let name = context.map { _ in device.displayName } ?? device.displayName
        var builder = AccessoryBuilder(device: device, status: status, settings: settings, options: options, box: box, env: env, context: context,
                                       accessoryID: Self.accessoryID(id), name: name)
        let isTelevision = settings.enableTelevisionService && TelevisionDetection.isTelevision(device)
        if isTelevision { builder.television() } else { builder.build() }
        guard builder.services.contains(where: { $0.type != .battery && $0.type != .serviceLabel }) else { return nil }
        let accessory = Accessory(
            id: Self.accessoryID(id), name: name, manufacturer: device.manufacturer, model: device.model, serialNumber: id,
            firmwareRevision: device.firmware ?? "1.0.0", category: builder.category, services: builder.services)
        return DeviceBinding(device: device, accessory: accessory, kind: builder.kind ?? "unsupported", box: box, signature: signature, isTelevision: isTelevision,
                             updaters: builder.updaters, eventHooks: builder.eventHooks, details: builder.details,
                             adaptiveLighting: builder.adaptiveLighting, meters: builder.meters)
    }

    static func accessoryID(_ deviceID: String) -> String { "\(platform):\(deviceID)" }

    // MARK: Commands (section 5.5)

    /// Sends a write's commands; a status read follows when no event confirms them.
    func send(deviceID: String, _ commands: [DeviceCommand], watched: [String]) async throws {
        let sentAt = dependencies.now()
        do {
            try await api.commands(deviceID: deviceID, commands)
        } catch {
            logger.warning("SmartThings did not take the command for \(bindings[deviceID]?.device.displayName ?? deviceID): \(error)")
            if let failure = error as? SmartThingsError, let status = failure.status, status == 400 || status == 422 {
                throw HAPStatusError(.invalidValueInRequest)
            }
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        followUps[deviceID]?.cancel()
        let delay = timing.seconds(sseActive ? 10 : 3)
        let events = sseActive
        followUps[deviceID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.followUp(deviceID: deviceID, watched: watched, sentAt: sentAt, events: events)
        }
    }

    private func followUp(deviceID: String, watched: [String], sentAt: Date, events: Bool) async {
        followUps[deviceID] = nil
        guard let binding = bindings[deviceID] else { return }
        if events, !watched.isEmpty, binding.box.eventCame(for: watched, since: sentAt) { return }
        await readStatus(deviceID)
    }

    /// One device's status (`GET devices/{id}/status`); 60 s of failures shows No Response (section 6.4).
    func readStatus(_ deviceID: String) async {
        let requestedAt = dependencies.now()
        do {
            let json = try await api.status(deviceID: deviceID)
            statusFailures[deviceID] = nil
            bindings[deviceID]?.box.merge(DeviceStatus(status: json), requestedAt: requestedAt)
        } catch {
            let since = statusFailures[deviceID] ?? requestedAt
            statusFailures[deviceID] = since
            if requestedAt.timeIntervalSince(since) >= timing.timeInterval(60) { bindings[deviceID]?.box.setHealth("OFFLINE") }
        }
    }

    /// Lists and adds the devices again soon, once for a burst of lifecycle events (section 5.1).
    func scheduleRediscovery(scenes refreshScenes: Bool = false) {
        guard rediscovery == nil else { return }
        let delay = timing.seconds(30)
        rediscovery = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.rediscover(scenes: refreshScenes)
        }
    }

    private func rediscover(scenes refreshScenes: Bool) async {
        rediscovery = nil
        await reconcile()
        if refreshScenes { await self.refreshScenes() }
    }

    // MARK: Scenes (section 11)

    func refreshScenes() async {
        do {
            scenes = try await api.scenes(locationID: locationID).compactMap(SmartThingsScene.init)
        } catch {
            logger.debug("Could not list the SmartThings scenes: \(error)")
            return
        }
        var keep = Set<String>()
        for scene in scenes where !context.isExcluded("scene:\(scene.id)") {
            let id = Self.accessoryID("scene:\(scene.id)")
            keep.insert(id)
            guard sceneAccessories[id] == nil || sceneAccessories[id]?.information.characteristic(.name).value.stringValue != scene.name else { continue }
            let service = Service(.switch, name: scene.name, subtype: "main/scene", isPrimary: true)
            let sceneID = scene.id
            let reset = timing.seconds(1)
            service.characteristic(.on).onRead { .bool(false) }
            service.characteristic(.on).onWrite { [weak self] value in
                guard value.boolValue == true else { return }
                guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
                do {
                    try await self.api.executeScene(sceneID)
                } catch {
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                // Momentary: back to Off a second later.
                Task {
                    try? await Task.sleep(for: reset)
                    service.characteristic(.on).value = .bool(false)
                }
            }
            let accessory = Accessory(id: id, name: scene.name, manufacturer: "SmartThings", model: "SmartThings scene", serialNumber: scene.id,
                                      category: .switch, services: [service])
            do {
                try context.add(accessory)
                sceneAccessories[id] = accessory
            } catch {
                logger.error("Could not add the scene \(scene.name): \(error)")
            }
        }
        for (id, _) in sceneAccessories where !keep.contains(id) {
            sceneAccessories[id] = nil
            try? await context.remove(id: id)
        }
        // With the devices and the scenes both read, a cached accessory neither has is gone (removed while the bridge was off).
        if listedAt != nil, lastReconcileFailure == nil {
            keep.formUnion(bindings.values.map(\.accessory.id))
            _ = await context.removeAccessories(keeping: keep)
        }
    }

    public func scenes() async -> [PluginScene] {
        scenes.filter { !context.isExcluded("scene:\($0.id)") }.map { PluginScene(id: $0.id, name: $0.name) }
    }

    public func recallScene(id: String) async throws {
        try await api.executeScene(id)
    }
}

/// This host's IPv4 addresses, for the redirect URI's default.
enum NetworkAddresses {
    @Sendable static func ipv4() -> [String] {
        guard let devices = try? System.enumerateDevices() else { return [] }
        var addresses: [String] = []
        for device in devices {
            guard let address = device.address, case .v4 = address, let ip = address.ipAddress, !ip.hasPrefix("127.") else { continue }
            if !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }
}
