import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Dyson Pure Cool, Hot+Cool, Humidify+Cool and Big+Quiet purifiers and the Cool fan, over their local MQTT
/// broker: found by mDNS or at a configured address, with the credentials the settings page fetches from the
/// Dyson account. See README.md.
///
/// The configuration is the one of `@mp-consulting/homebridge-dyson-pure-cool`, so a Homebridge block works
/// unchanged; the plugin's page in the web UI is the Homebridge plugin's setup wizard.
public actor DysonPureCoolPlugin: HomeswiftPlugin {
    public static let platform = "DysonPureCool"
    public static let name = "Dyson Pure Cool"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// A device that cannot be reached is tried again this often.
    static let offlineRetry: Duration = .seconds(300)
    /// The settings page looks for a device this long.
    static let pageDiscoveryDuration: Duration = .seconds(5)
    /// The settings page's MQTT connections give up after this long.
    static let pageMQTTTimeout: Duration = .seconds(10)
    /// The password the sign-in holds until the emailed code comes back.
    static let pendingSignInLifetime: Duration = .seconds(600)
    static let ipOverridesFile = "ip-overrides.json"

    /// What the plugin uses to reach devices and the cloud; tests swap them for fakes.
    struct Dependencies: Sendable {
        var mqtt: DysonMQTTClient.Connect = { MQTTClient($0) }
        var discover: @Sendable (Duration, Logger) async -> [String: String] = Discovery.discover
        var http: any HTTPSending = HTTPClient(tls: .system)
        var backoff: @Sendable (Int) -> Duration = DysonMQTTClient.exponentialBackoff
        var offlineRetry: Duration = DysonPureCoolPlugin.offlineRetry
        var pendingSignInLifetime: Duration = DysonPureCoolPlugin.pendingSignInLifetime
    }

    /// One configured device and what runs it.
    struct Managed: Sendable {
        var device: DysonDevice
        var accessory: DysonAccessory
        /// The address in config.json, if any.
        var configuredIP: String?
        var settings: Configuration.Device
        var observers: [UUID]
    }

    /// The sign-in between the code request and the code.
    private struct PendingSignIn {
        var email: String
        var password: String
        var countryCode: String
        var challengeID: String?
        var expires: ContinuousClock.Instant
        /// Tells this sign-in from a later one, for the timer that drops it.
        var id = UUID()
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var logger: Logger { context.logger }
    private var managed: [String: Managed] = [:]
    private var retries: [String: Task<Void, Never>] = [:]
    private let tasks = TaskBag()
    private var discovery: Task<[String: String], Never>?
    private var pendingSignIn: PendingSignIn? {
        didSet { if pendingSignIn?.id != oldValue?.id { pendingSignInExpiry?.cancel() } }
    }
    /// Drops the pending sign-in, and the password with it, when its time is up.
    private var pendingSignInExpiry: Task<Void, Never>?
    private var stopping = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(serial: String) -> String { "\(platform):\(serial)" }

    // MARK: Lifecycle

    public func start() async throws {
        let entries = configuration.devices ?? []
        guard !entries.isEmpty else {
            logger.warning("No devices configured. Please use the plugin settings to add your Dyson devices.")
            return
        }
        logger.info("Found \(entries.count) device(s) in configuration")

        var overrides = loadIPOverrides()
        var configured: [Configuration.Device] = []
        for entry in entries {
            guard let serial = entry.serial?.trimmingCharacters(in: .whitespaces), !serial.isEmpty else {
                logger.error("Skipping device configuration without a serial number")
                continue
            }
            guard !configured.contains(where: { $0.serial == serial }) else {
                logger.warning("Skipping a second entry for device \(serial)")
                continue
            }
            var device = configuration.merged(entry)
            device.serial = serial
            configured.append(device)
        }
        // Devices taken out of the configuration leave HomeKit.
        await context.removeAccessories(keeping: Set(configured.compactMap(\.serial).map(Self.accessoryID)), message: "Removing accessory no longer in config")

        for settings in configured {
            // stop() during start-up: nothing more is added or connected.
            guard !stopping else { return }
            guard let serial = settings.serial, validate(settings) else { continue }
            let configuredIP = settings.ipAddress?.trimmingCharacters(in: .whitespaces).nonEmpty
            var ip = configuredIP
            // An address found by mDNS after the configured one stopped answering, while config.json still has
            // the address it replaced.
            if let override = overrides[serial] {
                if let configuredIP, override.from == configuredIP {
                    logger.info("Using previously rediscovered IP \(override.to) for device \(serial)")
                    ip = override.to
                } else {
                    overrides[serial] = nil
                }
            }
            await add(settings, serial: serial, ip: ip, configuredIP: configuredIP)
        }
        guard !stopping else { return }
        saveIPOverrides(overrides)

        // Devices with an address connect at once; the others after an mDNS scan.
        var waiting: [String] = []
        for (serial, entry) in managed.sorted(by: { $0.key < $1.key }) {
            if await entry.device.ipAddress != nil {
                tasks.add { await self.connect(serial: serial) }
            } else {
                waiting.append(serial)
            }
        }
        if !waiting.isEmpty {
            tasks.add { [waiting] in await self.discoverAndConnect(waiting) }
        }
    }

    public func stop() async {
        stopping = true
        pendingSignIn = nil
        pendingSignInExpiry?.cancel()
        tasks.cancelAll()
        for task in retries.values { task.cancel() }
        retries.removeAll()
        discovery?.cancel()
        logger.info("Shutting down, disconnecting devices...")
        for entry in managed.values {
            for observer in entry.observers { await entry.device.removeObserver(observer) }
            await entry.device.disconnect()
        }
        logger.info("All devices disconnected")
    }

    /// The checks of the Homebridge plugin's `DysonPlatformAccessory`.
    private func validate(_ settings: Configuration.Device) -> Bool {
        let serial = settings.serial ?? ""
        guard let productType = settings.productType?.nonEmpty else {
            logger.error("Device \(serial) missing product type")
            return false
        }
        guard (settings.credentials ?? settings.localCredentials)?.nonEmpty != nil else {
            logger.error("Device \(serial) missing credentials")
            return false
        }
        guard DeviceCatalog.isSupported(productType) else {
            logger.warning("Unsupported device type: \(DeviceCatalog.modelName(productType)). Device will not be added.")
            return false
        }
        return true
    }

    private func add(_ settings: Configuration.Device, serial: String, ip: String?, configuredIP: String?) async {
        let productType = settings.productType ?? ""
        let name = settings.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Dyson \(serial)"
        logger.info("Initializing \(DeviceCatalog.modelName(productType)) (\(serial))")
        let credentials = settings.credentials?.nonEmpty ?? settings.localCredentials ?? ""
        let device = DysonDevice(
            serial: serial, productType: productType, name: name, credentials: credentials, ipAddress: ip,
            mqtt: dependencies.mqtt, logger: logger, backoff: dependencies.backoff)
        if let interval = configuration.pollingInterval, interval > 0 {
            await device.setPollingInterval(seconds: Int(saturating: interval) ?? 60)
        }
        let id = Self.accessoryID(serial: serial)
        let accessory = await DysonAccessory(
            device: device, id: id, name: name, options: DeviceOptions(settings), firmwareVersion: settings.firmwareVersion,
            cached: context.accessory(id: id), logger: logger)
        do {
            if context.accessory(id: id) == nil { logger.info("Adding new accessory: \(name)") }
            try context.add(accessory.accessory)
        } catch {
            logger.error("Failed to initialize device \(serial): \(error)")
            return
        }
        guard !stopping else { return }
        let forAccessory = await device.observe { event in accessory.handle(event) }
        let forPlugin = await device.observe { [weak self] event in
            guard let self else { return }
            Task { await self.deviceEvent(event, serial: serial) }
        }
        managed[serial] = Managed(device: device, accessory: accessory, configuredIP: configuredIP, settings: settings, observers: [forAccessory, forPlugin])
    }

    // MARK: Connections

    private func discoverAndConnect(_ serials: [String]) async {
        logger.info("Discovering IP addresses for \(serials.count) device(s) via mDNS...")
        let found = await discoverIPs()
        logger.info("mDNS discovery found \(found.count) device(s)")
        for (serial, ip) in found.sorted(by: { $0.key < $1.key }) { logger.debug("Discovered device \(serial) at \(ip)") }
        guard !Task.isCancelled, !stopping else { return }
        for serial in serials {
            guard let entry = managed[serial] else { continue }
            if let ip = found[serial] {
                logger.info("Using discovered IP \(ip) for device \(serial)")
                await entry.device.setIPAddress(ip)
                tasks.add { await self.connect(serial: serial) }
            } else {
                logger.warning("Device \(serial) has no IP address configured. Device discovery may be needed.")
                scheduleRetry(serial: serial)
            }
        }
    }

    /// One mDNS scan at a time, shared by everyone who needs one.
    func discoverIPs(duration: Duration? = nil) async -> [String: String] {
        if let discovery { return await discovery.value }
        let discover = dependencies.discover
        let logger = logger
        let duration = duration ?? configuration.discoveryDuration
        let task = Task { await discover(duration, logger) }
        discovery = task
        let found = await task.value
        discovery = nil
        return found
    }

    /// Connects; when the device does not answer at its address, looks for it over mDNS once, then tries again
    /// every five minutes.
    func connect(serial: String) async {
        guard let entry = managed[serial], !stopping else { return }
        retries[serial]?.cancel()
        retries[serial] = nil
        let device = entry.device
        logger.debug("Connecting to device \(serial)...")
        do {
            try await device.connect()
            // stop() while connecting: the connection does not outlive the plugin.
            guard !stopping else {
                await device.disconnect()
                return
            }
            if let variant = await device.activeVariant, variant.label != "default" {
                logger.info("Connected to \(serial) using fallback variant '\(variant.label)' (protocolVersion=\(variant.protocolLevel), clean=\(variant.clean))")
            } else {
                logger.info("Connected to \(serial)")
            }
            return
        } catch {
            // A connection stop() cut short is no failure.
            guard !stopping else { return }
            logger.warning("Failed to connect to device \(serial): \(error)")
        }
        if let ip = await device.ipAddress {
            logger.info("Attempting to rediscover IP for \(serial) via mDNS...")
            let found = await discoverIPs()[serial]
            guard !stopping else { return }
            if let found, found != ip {
                logger.warning("Device \(serial) answered mDNS at \(found) instead of \(ip). Set a static IP for the device if this was not expected.")
                await device.setIPAddress(found)
                do {
                    try await device.connect()
                    guard !stopping else {
                        await device.disconnect()
                        return
                    }
                    logger.info("Connected to \(serial) at new IP \(found)")
                    persistDiscoveredIP(serial: serial, ip: found)
                    return
                } catch {
                    logger.warning("Failed to connect to \(serial) at new IP \(found): \(error)")
                    await device.setIPAddress(ip)
                }
            } else if found == ip {
                logger.warning("Device \(serial) found at same IP \(ip) but not responding")
            } else {
                logger.warning("Device \(serial) not found on network — it may be offline")
            }
        }
        logger.info("[\(serial)] Will retry connection in 5 min")
        scheduleRetry(serial: serial)
    }

    private func scheduleRetry(serial: String) {
        guard !stopping else { return }
        retries[serial]?.cancel()
        let delay = dependencies.offlineRetry
        retries[serial] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.retry(serial: serial)
        }
    }

    private func retry(serial: String) async {
        guard !stopping, managed[serial] != nil else { return }
        // This runs in the retry's own task: forgotten here, so connect() does not cancel it.
        retries[serial] = nil
        logger.info("[\(serial)] Retrying connection to offline device...")
        if await managed[serial]?.device.ipAddress == nil {
            if let ip = await discoverIPs()[serial] {
                await managed[serial]?.device.setIPAddress(ip)
            } else {
                logger.warning("Device \(serial) not found on network — it may be offline")
                scheduleRetry(serial: serial)
                return
            }
        }
        await connect(serial: serial)
    }

    private func deviceEvent(_ event: DeviceEvent, serial: String) {
        switch event {
        case .error(let message):
            logger.error("[\(serial)] Device error: \(message)")
        case .reconnectFailed:
            guard !stopping else { return }
            logger.warning("[\(serial)] MQTT reconnection exhausted — device is offline. Will retry in 5 min.")
            scheduleRetry(serial: serial)
        default:
            break
        }
    }

    // MARK: Rediscovered addresses

    struct IPOverride: Codable, Equatable, Sendable {
        /// The address config.json had when the device moved.
        var from: String?
        var to: String
    }

    private var ipOverridesStore: JSONFile<[String: IPOverride]> { context.jsonFile(Self.ipOverridesFile) }

    func loadIPOverrides() -> [String: IPOverride] { ipOverridesStore.load() ?? [:] }

    private func saveIPOverrides(_ overrides: [String: IPOverride]) {
        guard overrides != loadIPOverrides() else { return }
        do {
            try ipOverridesStore.save(overrides)
        } catch {
            logger.warning("Could not save the rediscovered addresses: \(error)")
        }
    }

    /// Remembers an address mDNS found so the next launch connects to it directly, while config.json keeps the
    /// address it replaced.
    private func persistDiscoveredIP(serial: String, ip: String) {
        guard let configuredIP = managed[serial]?.configuredIP else { return }
        var overrides = loadIPOverrides()
        overrides[serial] = IPOverride(from: overrides[serial]?.from ?? configuredIP, to: ip)
        saveIPOverrides(overrides)
    }

    // MARK: For the page and tests

    func device(serial: String) -> DysonDevice? { managed[serial]?.device }
    func accessory(serial: String) -> DysonAccessory? { managed[serial]?.accessory }

    /// Waits for the connections started so far. For tests.
    func settle() async {
        await tasks.idle()
    }

    // MARK: The web page

    /// The routes of the Homebridge plugin's UI server (`authenticate`, `verify-otp`, `get-devices`,
    /// `get-product-types`, `get-device-state`, `set-continuous-monitoring`), plus `devices`: the devices this
    /// instance runs and whether they are connected. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        do {
            switch request.path {
            case "authenticate": return try await authenticate(request.body)
            case "verify-otp": return try await verifyCode(request.body)
            case "get-devices": return try await cloudDevices(request.body)
            case "get-product-types": return productTypes()
            case "get-device-state": return try await deviceState(request.body, retried: false)
            case "set-continuous-monitoring": return try await setContinuousMonitoring(request.body, retried: false)
            case "devices": return await runningDevices()
            default: return .error(404, "nothing at \(request.method) \(request.path)")
            }
        } catch let failure as DysonCloud.Failure {
            return .error(failure.status, failure.message)
        }
    }

    private var cloud: DysonCloud { DysonCloud(transport: dependencies.http, logger: logger) }

    private func authenticate(_ body: JSONValue) async throws -> PluginWebResponse {
        let email = try CloudInput.email(body["email"])
        let password = try CloudInput.password(body["password"])
        let countryCode = try CloudInput.countryCode(body["countryCode"])
        // A new attempt drops the previous challenge; the password is held for ten minutes at most.
        let lifetime = dependencies.pendingSignInLifetime
        let signIn = PendingSignIn(email: email, password: password, countryCode: countryCode, expires: .now + lifetime)
        pendingSignIn = signIn
        pendingSignInExpiry = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            await self?.expirePendingSignIn(signIn.id)
        }
        do {
            switch try await cloud.requestCode(email: email, countryCode: countryCode) {
            case .code(let challengeID):
                pendingSignIn?.challengeID = challengeID
                return PluginWebResponse(["success": true, "requires2FA": true])
            case .token(let token):
                pendingSignIn = nil
                return PluginWebResponse(["success": true, "requires2FA": false, "token": .string(token)])
            }
        } catch {
            logger.error("Auth error: \(error)")
            pendingSignIn = nil
            throw error
        }
    }

    private func expirePendingSignIn(_ id: UUID) {
        guard pendingSignIn?.id == id else { return }
        logger.info("Clearing stale pending auth (timeout)")
        pendingSignIn = nil
    }

    /// Whether a sign-in waits for its code. For tests.
    var hasPendingSignIn: Bool { pendingSignIn != nil }

    private func verifyCode(_ body: JSONValue) async throws -> PluginWebResponse {
        let code = try CloudInput.code(body["otpCode"])
        if let pending = pendingSignIn, pending.expires < .now {
            logger.info("Clearing stale pending auth (timeout)")
            pendingSignIn = nil
        }
        guard let pending = pendingSignIn, let challengeID = pending.challengeID else {
            throw DysonCloud.Failure(status: 400, message: "No pending authentication")
        }
        logger.info("Verify OTP")
        do {
            let token = try await cloud.verify(email: pending.email, password: pending.password, challengeID: challengeID, code: code, countryCode: pending.countryCode)
            pendingSignIn = nil
            logger.info("Verify success")
            return PluginWebResponse(["success": true, "token": .string(token)])
        } catch let failure as DysonCloud.Failure where failure.message.contains("Invalid") {
            // A mistyped code can be tried again while the sign-in lasts.
            logger.error("Verify error: \(failure)")
            throw DysonCloud.Failure(status: 401, message: "Invalid verification code")
        } catch {
            logger.error("Verify error: \(error)")
            pendingSignIn = nil
            throw error
        }
    }

    private func cloudDevices(_ body: JSONValue) async throws -> PluginWebResponse {
        guard let token = body["token"]?.stringValue, !token.isEmpty else { throw DysonCloud.Failure(status: 400, message: "Token is required") }
        let names = DeviceCatalog.displayNames
        let devices: [JSONValue] = try await cloud.devices(token: token).map { device in
            let features = DeviceCatalog.features(device.productType)
            var entry: [String: JSONValue] = [
                "serial": .string(device.serial), "productType": .string(device.productType),
                "productName": .string(names[device.productType] ?? "Unknown (\(device.productType))"), "version": .string(device.version),
                "localCredentials": .string(device.localCredentials), "autoUpdate": .bool(device.autoUpdate),
                "newVersionAvailable": .bool(device.newVersionAvailable), "hasHeating": .bool(features.heating),
                "hasHumidifier": .bool(features.humidifier), "hasOscillation": .bool(features.oscillation), "hasJetFocus": .bool(features.frontAirflow),
            ]
            entry["name"] = device.name.map { .string($0) } ?? .null
            return .object(entry)
        }
        return PluginWebResponse(["success": true, "devices": .array(devices)])
    }

    private func productTypes() -> PluginWebResponse {
        let names = DeviceCatalog.displayNames
        return PluginWebResponse([
            "success": true,
            "productTypes": .object(names.mapValues { .string($0) }),
            "heatingProductTypes": .array(DeviceCatalog.heatingProductTypes.map { .string($0) }),
            "jetFocusProductTypes": .array(DeviceCatalog.jetFocusProductTypes.map { .string($0) }),
        ])
    }

    private func runningDevices() async -> PluginWebResponse {
        var list: [JSONValue] = []
        for (serial, entry) in managed.sorted(by: { $0.key < $1.key }) {
            let state = await entry.device.state
            let connected = await entry.device.isConnected
            var device: [String: JSONValue] = [
                "serial": .string(serial), "name": .string(entry.device.name), "productType": .string(entry.device.productType),
                "model": .string(DeviceCatalog.modelName(entry.device.productType)), "connected": .bool(connected),
                "on": .bool(state.isOn), "autoMode": .bool(state.autoMode), "fanSpeed": .number(Double(state.fanSpeed)),
                "retrying": .bool(retries[serial] != nil),
            ]
            if let ip = await entry.device.ipAddress { device["ipAddress"] = .string(ip) }
            if let monitoring = state.continuousMonitoring { device["continuousMonitoring"] = .bool(monitoring) }
            if let celsius = MessageCodec.decodeCelsius(state.temperature) { device["temperature"] = .number(celsius) }
            if let humidity = state.humidity { device["humidity"] = .number(Double(humidity)) }
            if let pm25 = state.pm25 { device["pm25"] = .number(Double(pm25)) }
            if let life = DysonAccessory.filterLife(state) { device["filterLife"] = .number(Double(life)) }
            list.append(.object(device))
        }
        return PluginWebResponse(["devices": .array(list)])
    }

    /// The address to reach a device at from the page: the one given, else an mDNS scan's.
    private func pageAddress(serial: String, given: String?, previous: String? = nil) async -> (ip: String?, discovered: Bool) {
        if let given {
            logger.info("Using cached IP for \(serial)")
            return (given, false)
        }
        logger.info("Discovering device \(serial) via mDNS...")
        let found = await dependencies.discover(Self.pageDiscoveryDuration, logger)
        logger.info("mDNS found \(found.count) devices")
        guard let ip = found[serial] else { return (nil, false) }
        // mDNS answers are unauthenticated: the credentials only go to the private LAN.
        guard Discovery.isPrivateIPv4(ip) else {
            logger.warning("Ignoring mDNS address for \(serial): not a private IPv4 address")
            return (nil, false)
        }
        if let previous, ip != previous { logger.warning("mDNS-discovered IP for \(serial) differs from the cached/configured IP") }
        return (ip, true)
    }

    private struct PageDevice {
        var serial: String
        var productType: String
        var credentials: String
        var ipAddress: String?
    }

    /// The device a page request names: serial, product type and credential as the settings page sends them,
    /// or (for the Assistant) only the serial of a device this instance runs, whose settings fill in the rest.
    private func pageDevice(_ body: JSONValue) async throws -> PageDevice {
        let given = try CloudInput.optionalIPAddress(body["ipAddress"])
        if let serial = body["serial"]?.stringValue?.nonEmpty, let productType = body["productType"]?.stringValue?.nonEmpty,
           let credentials = body["localCredentials"]?.stringValue?.nonEmpty {
            return PageDevice(serial: serial, productType: productType, credentials: credentials, ipAddress: given)
        }
        if body["productType"] == nil, body["localCredentials"] == nil, let serial = body["serial"]?.stringValue?.nonEmpty, let entry = managed[serial],
           let credentials = (entry.settings.credentials?.nonEmpty ?? entry.settings.localCredentials)?.nonEmpty {
            let ip = await entry.device.ipAddress
            return PageDevice(serial: serial, productType: entry.device.productType, credentials: credentials, ipAddress: given ?? ip)
        }
        throw DysonCloud.Failure(status: 400, message: "Missing device info (serial, productType, localCredentials)")
    }

    /// The running device with this serial, when it is connected: the page uses its connection rather than
    /// opening a second one.
    private func connectedDevice(serial: String) async -> DysonDevice? {
        guard let device = managed[serial]?.device, await device.isConnected else { return nil }
        return device
    }

    private func oneOffClient(_ device: PageDevice, ip: String) -> DysonMQTTClient {
        DysonMQTTClient(
            settings: .init(host: ip, serial: device.serial, credentials: device.credentials, productType: device.productType, timeout: Self.pageMQTTTimeout, autoReconnect: false),
            mqtt: dependencies.mqtt)
    }

    private func deviceState(_ body: JSONValue, retried: Bool) async throws -> PluginWebResponse {
        let page = try await pageDevice(body)
        if !retried, let device = await connectedDevice(serial: page.serial) {
            let state = await device.state
            return PluginWebResponse(["success": true, "continuousMonitoring": .bool(state.continuousMonitoring == true)])
        }
        let (ip, discovered) = await pageAddress(serial: page.serial, given: page.ipAddress)
        guard let ip else { throw DysonCloud.Failure(status: 404, message: "Device \(page.serial) not found on network") }
        logger.info("Connecting to \(page.serial)")
        let client = oneOffClient(page, ip: ip)
        do {
            try await client.connect()
            try await client.subscribeToStatus()
            let state = try await currentState(client)
            await client.disconnect()
            await client.finish()
            let monitoring = MessageCodec.value(state.objectValue.flatMap(MessageCodec.stateFields)?["rhtm"]) == MessageCodec.on
            logger.info("Device state: continuousMonitoring=\(monitoring)")
            var answer: [String: JSONValue] = ["success": true, "continuousMonitoring": .bool(monitoring)]
            // A retry after rediscovery passes the new address as if it were cached: still report it to be saved.
            if discovered || retried { answer["discoveredIp"] = .string(ip) }
            return PluginWebResponse(.object(answer))
        } catch {
            logger.error("MQTT error: \(error)")
            await client.disconnect()
            await client.finish()
            if let given = page.ipAddress, !discovered, !retried {
                logger.info("Cached IP failed, trying mDNS discovery...")
                let fresh = await pageAddress(serial: page.serial, given: nil, previous: given)
                if let freshIP = fresh.ip, freshIP != given {
                    var retry = body.objectValue ?? [:]
                    retry["ipAddress"] = .string(freshIP)
                    return try await deviceState(.object(retry), retried: true)
                }
            }
            throw DysonCloud.Failure(status: 500, message: "Failed to get device state: \(error)")
        }
    }

    /// Asks for the current state and waits for the `CURRENT-STATE` answer.
    private func currentState(_ client: DysonMQTTClient) async throws -> JSONValue {
        let events = client.events
        let timeout = Self.pageMQTTTimeout
        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                for await event in events {
                    guard case .message(_, let payload) = event, let message = try? JSONValue(data: payload) else { continue }
                    if message["msg"]?.stringValue == "CURRENT-STATE" { return message }
                }
                return nil
            }
            group.addTask {
                try await client.requestCurrentState()
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            if let result = try await group.next(), let message = result { return message }
            throw DysonMQTTError.unreachable("Timeout waiting for device state")
        }
    }

    private func setContinuousMonitoring(_ body: JSONValue, retried: Bool) async throws -> PluginWebResponse {
        let page = try await pageDevice(body)
        guard let enabled = body["enabled"], case .bool(let on) = enabled else { throw DysonCloud.Failure(status: 400, message: "enabled must be a boolean") }
        logger.info("Setting continuous monitoring to \(on) for \(page.serial)")
        if !retried, let device = await connectedDevice(serial: page.serial) {
            do {
                try await device.setContinuousMonitoring(on)
            } catch {
                throw DysonCloud.Failure(status: 500, message: "Failed to set continuous monitoring: \(error)")
            }
            return PluginWebResponse(["success": true, "continuousMonitoring": .bool(on)])
        }
        let (ip, discovered) = await pageAddress(serial: page.serial, given: page.ipAddress)
        guard let ip else { throw DysonCloud.Failure(status: 404, message: "Device \(page.serial) not found on network") }
        let client = oneOffClient(page, ip: ip)
        do {
            try await client.connect()
            try await client.publishCommand(MessageCodec.stateSet(["rhtm": on ? MessageCodec.on : MessageCodec.off]))
            await client.disconnect()
            await client.finish()
            logger.info("Continuous monitoring set to \(on)")
            var answer: [String: JSONValue] = ["success": true, "continuousMonitoring": .bool(on)]
            if discovered || retried { answer["discoveredIp"] = .string(ip) }
            return PluginWebResponse(.object(answer))
        } catch {
            logger.error("MQTT error: \(error)")
            await client.disconnect()
            await client.finish()
            if let given = page.ipAddress, !discovered, !retried {
                logger.info("Cached IP failed, trying mDNS discovery...")
                let fresh = await pageAddress(serial: page.serial, given: nil, previous: given)
                if let freshIP = fresh.ip, freshIP != given {
                    var retry = body.objectValue ?? [:]
                    retry["ipAddress"] = .string(freshIP)
                    return try await setContinuousMonitoring(.object(retry), retried: true)
                }
            }
            throw DysonCloud.Failure(status: 500, message: "Failed to set continuous monitoring: \(error)")
        }
    }
}
