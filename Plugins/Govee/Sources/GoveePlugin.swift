import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Govee lights, plugs, sensors and appliances, over Govee's cloud (the app's account API and AWS IoT), the
/// LAN API and Bluetooth: a port of `@mp-consulting/homebridge-govee` with its configuration, so a Homebridge
/// block works unchanged. See README.md in this directory.
///
/// Commands go over LAN, then AWS, then BLE (queued, one at a time; a newer command of the same kind replaces
/// a queued one). Status comes from LAN polling, AWS IoT messages (and a status request every minute), the
/// HTTP device list for sensors, and BLE advertisements for thermo-hygrometers.
public actor GoveePlugin: HomeswiftPlugin {
    public static let platform = "Govee"
    public static let name = "Govee"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// How long a periodic BLE sensor scan listens.
    static let bleScanWindow: Duration = .seconds(30)
    /// The least time between two readings forwarded from the same sensor.
    static let bleReadingThrottle: Duration = .seconds(10)
    /// The least time between two logins at runtime after the token was refused.
    static let reauthenticationInterval: TimeInterval = 10 * 60
    /// While a leak alert is active, whether it was read in the app is checked this often at most.
    static let leakRecheckInterval: TimeInterval = 5 * 60
    static let awsSyncInterval: Duration = .seconds(60)

    /// What the plugin uses to reach Govee and the devices; tests swap them for fakes.
    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient()
        /// For scene icons: refuses bodies over 512 KB.
        var icons: any HTTPSending = HTTPClient(maximumBodySize: GoveePlugin.iconMaximumBytes)
        var lanSocket: @Sendable (Logger) async throws -> any LANSocket = { try await UDPLANSocket.bind(logger: $0) }
        /// The Bluetooth adapter, or nil where there is none.
        var bleCentral: @Sendable (Logger) -> (any BLECentral)? = GoveePlugin.systemCentral
        /// The AWS IoT connection.
        var mqtt: @Sendable (MQTTConfiguration) async throws -> any MQTTConnection = { MQTTClient($0) }
        /// Whether devices keep their Eve history (fakegato's files, in the storage directory).
        var history = true
        var retryDelay: Duration = GoveeAccount.retryDelay
    }

    /// A device on the bridge and how to reach it.
    struct ManagedDevice: Sendable {
        var id: String
        var model: String
        var name: String
        var accessoryID: String
        var handler: GoveeDevice
        var transports: TransportFlags
        var awsTopic: String?
        var ble: BLETarget?
        var external: Bool
        var lastUpdate: Date?
    }

    let configuration: Configuration
    nonisolated let context: PluginContext
    let dependencies: Dependencies
    private let adaptiveLighting: AdaptiveLightingFactory
    private var logger: Logger { context.logger }
    nonisolated let debug: DebugLog
    private let deviceSettings: [String: DeviceSettings]
    private let ignoredDevices: Set<String>

    private(set) var account: GoveeAccount?
    private var credentialStore: CredentialStore?
    private var credentials: AccountCredentials?
    private(set) var awsClient: AWSClient?
    private(set) var lanClient: LANClient?
    private(set) var bleClient: BLEClient?
    private var queue: CommandQueue
    private(set) var devices: [String: ManagedDevice] = [:]
    private var httpDevices: [JSONValue] = []
    private var lanDevices: [LANDevice] = []
    var discovered: [JSONValue] = []
    let store: DeviceStore
    private let tasks = TaskBag()
    private var setup: Task<Void, Never>?
    private var httpSyncInProgress = false
    private var awsSyncInProgress = false
    private var bleSyncInProgress = false
    private var lastReauthentication: Date?
    private var bleCommandSequence = 0
    private var bleLatestCommand: [String: Int] = [:]
    private var bleLastReading: [String: ContinuousClock.Instant] = [:]
    private var leakState: [String: (lastTime: Double, checkedAt: Date, leak: Bool)] = [:]
    /// The settings page's login, kept for the session so browsing scenes does not log in each time.
    var pageSession: (key: String, token: String)?
    var iconCache: [String: String] = [:]
    private(set) var started = false
    /// Set by `stop()`: a setup still running stops at its next step and closes what it opened since.
    private(set) var stopped = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        adaptiveLighting = Self.adaptiveLighting(context: context)
        debug = DebugLog(logger: context.logger, raised: configuration.debug)
        let settings = configuration.devices
        deviceSettings = settings
        ignoredDevices = Set(settings.filter { $0.value.ignoreDevice }.keys)
        queue = CommandQueue(interval: configuration.bleQueueInterval)
        store = context.persistedDictionary("device-state.json")
    }

    /// Homeswift's `AdaptiveLightingController` in automatic mode, as the Homebridge plugin used HAP-NodeJS's,
    /// with `adaptiveLightingShift` as its custom temperature adjustment; its schedule is kept across launches.
    static func adaptiveLighting(context: PluginContext) -> AdaptiveLightingFactory {
        { [context] lightbulb, shift, deviceID in
            let controller = AdaptiveLightingController(lightbulb, mode: .automatic, customTemperatureAdjustment: shift, logger: context.logger)
            context.configureController(controller, accessoryID: "\(GoveePlugin.platform):\(deviceID)")
            return controller
        }
    }

    // MARK: Lifecycle

    public func start() async throws {
        logger.info("\(Lang.initialised).")
        for (key, value, minimum) in configuration.belowMinimum {
            logger.warning("[Config] \(key) value \(value) is below minimum \(minimum), using default")
        }
        setup = Task { await self.setUp() }
    }

    /// Waits for the setup started by `start()`. For tests.
    func settle() async {
        await setup?.value
    }

    /// Each step can await for a while (a LAN scan, logins): after each one, a `stop()` that came meanwhile ends
    /// the setup, and what the step opened after it is closed.
    private func setUp() async {
        await setUpLAN()
        guard !stopped else { return await tearDown() }
        await setUpHTTPAndAWS()
        guard !stopped else { return await tearDown() }
        setUpBLE()
        do {
            try await initializeDevices()
            guard !stopped else { return await tearDown() }
            started = true
            logger.info("\(Lang.complete).")
        } catch {
            guard !stopped else { return await tearDown() }
            logger.warning("***** \(Lang.disabling). *****")
            logger.warning("***** \(error). *****")
            await stop()
        }
    }

    public func stop() async {
        stopped = true
        setup?.cancel()
        await tearDown()
        debug("Stopped")
    }

    /// Cancels the syncs and closes every client and device handler there is; again after a setup that `stop()`
    /// interrupted, for what it opened since.
    private func tearDown() async {
        tasks.cancelAll()
        let handlers = devices.values.map(\.handler)
        for handler in handlers { await handler.destroy() }
        let (aws, lan, ble) = (awsClient, lanClient, bleClient)
        awsClient = nil
        lanClient = nil
        bleClient = nil
        if let aws { await aws.disconnect() }
        if let lan { await lan.close() }
        if let ble { await ble.shutdown() }
        try? store.flush()
    }

    private func setUpLAN() async {
        guard !configuration.lanDisable else {
            logger.warning("[LAN] \(Lang.disableClient) \(Lang.disabledInConfig).")
            return
        }
        do {
            let socket = try await dependencies.lanSocket(logger)
            // Port 4002 stays free for the next instance when stop() came while it was bound.
            guard !stopped else { return await socket.close() }
            var custom: [String: String] = [:]
            for (id, settings) in deviceSettings {
                if let ip = settings.customIPAddress { custom[id] = ip }
            }
            let client = LANClient(socket: socket, customAddresses: custom, logger: logger, debug: debug) { [weak self] id, data, ip in
                await self?.receiveUpdateLAN(id, data, ip: ip)
            }
            lanClient = client
            await client.start()
            lanDevices = await client.discover()
            logger.info("[LAN] \(Lang.availableWithDevices(lanDevices.count)).")
        } catch {
            logger.warning("[LAN] \(Lang.disableClient) \(error).")
            lanClient = nil
        }
    }

    private func setUpHTTPAndAWS() async {
        debug("[HTTP] Setting up HTTP and AWS clients...")
        guard let username = configuration.username, let password = configuration.password else {
            debug("[HTTP] No username or password configured")
            logger.warning("[HTTP] \(Lang.disableClient) \(Lang.noCreds).")
            return
        }
        let api = GoveeAPI(transport: dependencies.http, clientId: GoveeAPI.clientId(username: username))
        let account = GoveeAccount(api: api, username: username, password: password, code: configuration.code, logger: logger, retryDelay: dependencies.retryDelay)
        let store = CredentialStore(directory: context.storageDirectory, username: username, logger: logger)
        self.account = account
        credentialStore = store
        do {
            credentials = store.load()
            let usedCache = credentials != nil
            if let credentials {
                await account.setToken(credentials.token)
            } else {
                try await login()
            }
            var devices: [JSONValue]
            do {
                devices = try await account.devices()
            } catch let error as GoveeAPIError where usedCache && error.isAuthFailure {
                // A kept token can expire or be revoked: log in again once.
                logger.warning("[HTTP] \(Lang.accTokenRejected)")
                store.clear()
                try await login()
                devices = try await account.devices()
            }
            httpDevices = devices
            logger.info("[HTTP] \(Lang.availableWithDevices(devices.count)).")
            try await setUpAWS(api: api, store: store)
        } catch {
            logger.warning("[HTTP] \(Lang.disableClient) \(error).")
            self.account = nil
            awsClient = nil
        }
    }

    private func setUpAWS(api: GoveeAPI, store: CredentialStore) async throws {
        guard !configuration.awsDisable else {
            logger.warning("[AWS] \(Lang.disableClient) \(Lang.disabledInConfig).")
            return
        }
        guard let credentials, !credentials.iotPass.isEmpty, !credentials.topic.isEmpty, !credentials.accountId.isEmpty else { return }
        let identity = try GoveeIoTIdentity(pkcs12: store.certificate(), passphrase: credentials.iotPass)
        let clientID = "AP/\(credentials.accountId)/\(api.clientId)"
        let connection = try await dependencies.mqtt(Self.mqttConfiguration(endpoint: credentials.endpoint, clientID: clientID, identity: identity))
        let client = AWSClient(accountTopic: credentials.topic, connection: connection, debug: debug) { [weak self] payload in
            Task { await self?.receiveUpdateAWS(payload) }
        }
        awsClient = client
        await client.start()
        logger.info("[AWS] \(Lang.available).")
    }

    /// AWS IoT over MQTT 3.1.1 on TLS port 8883: the account's PKCS#12 certificate, Amazon's root CA. Like the AWS IoT
    /// SDK the Homebridge plugin used, the first connection is retried until it succeeds (and drops reconnect).
    /// `AP/<accountId>/<client id>`: AWS IoT drops an older connection with the same id.
    static func mqttConfiguration(endpoint: String, clientID: String, identity: GoveeIoTIdentity) -> MQTTConfiguration {
        let options = TLSOptions(trust: .amazonRootCA1, clientIdentity: .pkcs12(identity.pkcs12, passphrase: identity.passphrase))
        return MQTTConfiguration(transport: .tls(host: endpoint, port: 8883, options: options), clientID: clientID, reconnect: .init(firstConnection: true))
    }

    /// Logs in and keeps the result.
    private func login() async throws {
        guard let account, let credentialStore else { return }
        let result = try await account.login()
        credentials = result.credentials
        try credentialStore.save(result.credentials, iotCertificate: result.iot)
    }

    /// Logs in again at runtime after the token was refused, every ten minutes at most.
    private func reauthenticate() async {
        guard account != nil, let credentialStore else { return }
        if let last = lastReauthentication, Date().timeIntervalSince(last) < Self.reauthenticationInterval { return }
        lastReauthentication = Date()
        logger.warning("[HTTP] \(Lang.accTokenRejected)")
        do {
            credentialStore.clear()
            try await login()
        } catch {
            logger.warning("[HTTP] \(Lang.syncFail) \(error).")
        }
    }

    private func setUpBLE() {
        guard !configuration.bleDisable else {
            logger.warning("[BLE] \(Lang.disableClient) \(Lang.disabledInConfig).")
            return
        }
        guard let central = dependencies.bleCentral(logger) else {
            logger.warning("[BLE] \(Lang.disableClient) \(Lang.bleNoPackage).")
            return
        }
        bleClient = BLEClient(central: central, logger: logger, debug: debug)
        logger.info("[BLE] \(Lang.available).")
    }

    /// CoreBluetooth on a Mac whose binary may use Bluetooth; nothing on Linux yet.
    @Sendable static func systemCentral(_ logger: Logger) -> (any BLECentral)? {
        #if canImport(CoreBluetooth)
        guard CoreBluetoothCentral.isPermitted(infoDictionary: Bundle.main.infoDictionary) else {
            logger.info("[BLE] Bluetooth needs NSBluetoothAlwaysUsageDescription in the homeswift binary's Info.plist")
            return nil
        }
        if let app = CoreBluetoothCentral.responsibleApp, !CoreBluetoothCentral.isPermitted(infoDictionary: app.infoDictionary) {
            // macOS would abort the whole bridge at the first Bluetooth call.
            logger.warning("[BLE] disabled: macOS holds \(app.path) responsible for homeswift, and it declares no Bluetooth use. Run homeswift on its own (launchd, brew services) or from a terminal that does, to use Bluetooth.")
            return nil
        }
        return CoreBluetoothCentral(logger: logger)
        #else
        return nil
        #endif
    }

    // MARK: Devices

    /// Devices the user left out: one by one (`ignoreDevice`), or every Matter model with `ignoreMatter`.
    func isIgnored(_ id: String, model: String?) -> Bool {
        ignoredDevices.contains(id) || (configuration.ignoreMatter && model.map { GoveeConstants.matterModels.contains($0.uppercased()) } == true)
    }

    private func initializeDevices() async throws {
        var initialised = false
        var skipped = Set<String>()
        storeDiscoveredDevices()

        var lanUsed = Set<String>()
        for httpDevice in httpDevices {
            guard !stopped else { return }
            let id = Govee.colonDeviceId(httpDevice["device"]?.stringValue ?? "")
            let model = httpDevice["sku"]?.stringValue ?? ""
            guard !id.isEmpty, !isIgnored(id, model: model) else { continue }
            let onLAN = lanDevices.contains { $0.device == id }
            if onLAN { lanUsed.insert(id) }
            await initialise(id: id, model: model, name: httpDevice["deviceName"]?.stringValue ?? id, http: httpDevice, onLAN: onLAN)
            initialised = true
        }
        for lanDevice in lanDevices where !lanUsed.contains(lanDevice.device) {
            guard !stopped else { return }
            let id = lanDevice.device
            guard !isIgnored(id, model: lanDevice.sku) else { continue }
            // LAN discovery is unauthenticated: with the account's list, only its devices and the configured ones.
            if account != nil, deviceSettings[id] == nil {
                logger.info("[LAN] \(Lang.lanUnknownSkipped) [\(id)].")
                skipped.insert(id)
                continue
            }
            let name = deviceSettings[id]?.label ?? id.replacingOccurrences(of: ":", with: "")
            await initialise(id: id, model: lanDevice.sku ?? "HXXXX", name: name, http: nil, onLAN: true)
            initialised = true
        }
        guard initialised else { throw GoveeAPIError.message(Lang.noDevs) }
        guard !stopped else { return }

        // Accessories of devices no longer listed, ignored or skipped leave HomeKit.
        let known = Set(httpDevices.map { Govee.colonDeviceId($0["device"]?.stringValue ?? "") }).union(lanDevices.map(\.device))
        let prefix = "\(Self.platform):"
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) {
            let id = String(accessory.id.dropFirst(prefix.count))
            let model = devices[id]?.model ?? accessory.information[.model]?.value.stringValue
            guard !known.contains(id) || isIgnored(id, model: model) || skipped.contains(id) else { continue }
            await removeDevice(id: id, accessoryID: accessory.id, name: accessory.name)
        }

        startSyncs()
    }

    private func removeDevice(id: String, accessoryID: String, name: String) async {
        if let device = devices.removeValue(forKey: id) { await device.handler.destroy() }
        do {
            try await context.remove(id: accessoryID)
            logger.info("[\(name)] \(Lang.devRemove).")
        } catch {
            logger.warning("[\(name)] \(Lang.devNotRemove) \(error).")
        }
    }

    /// Builds a device's handler and accessory, and puts it on the bridge.
    func initialise(id: String, model: String, name: String, http: JSONValue?, onLAN: Bool) async {
        let settings = deviceSettings[id] ?? DeviceSettings()
        let name = settings.label ?? name
        var transports = TransportFlags(hasLAN: onLAN, useLAN: onLAN)
        var awsTopic: String?
        var ble: BLETarget?
        if let raw = http?["deviceExt"]?["deviceSettings"]?.stringValue {
            if let parsed = try? JSONValue(string: raw) {
                if let topic = parsed["topic"]?.stringValue, !topic.isEmpty {
                    transports.hasAWS = true
                    awsTopic = topic
                    transports.useAWS = awsClient != nil
                }
                if let bleName = parsed["bleName"]?.stringValue, !bleName.isEmpty {
                    transports.hasBLE = true
                    let address = settings.customAddress ?? parsed["address"]?.stringValue?.lowercased().nonEmpty ?? String(id.dropFirst(6)).lowercased()
                    ble = BLETarget(address: address.lowercased(), name: bleName)
                    transports.useBLE = bleClient != nil
                }
            } else {
                debug.warn("[\(name)] Failed to parse deviceSettings, skipping AWS/BLE setup")
            }
        }
        let accessoryID = "\(Self.platform):\(id)"
        let cached = context.accessory(id: accessoryID)
        let info = DeviceInfo(id: id, model: model, name: name, goodsType: http?["goodsType"]?.intValue, firmware: http?["versionSoft"]?.stringValue?.nonEmpty)
        let environment = DeviceEnvironment(
            info: info, settings: settings, platform: configuration, transports: transports,
            send: { [weak self] command in
                guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
                try await self.sendDeviceUpdate(id: id, command)
            },
            logger: logger, deviceLogging: !configuration.disableDeviceLogging, debugLogging: configuration.debug, cached: cached, store: store,
            historyDirectory: dependencies.history ? context.storageDirectory : nil, adaptiveLighting: adaptiveLighting)
        guard let handler = await GoveeDevice.make(model: model, environment: environment) else {
            logger.warning("[\(name)] \(Lang.devMaySupp) [\(model)]")
            return
        }
        await handler.configure()
        let services = await handler.services
        let history = await handler.history
        let category = await handler.category
        let accessory = Accessory(
            id: accessoryID, name: name, manufacturer: Lang.brand, model: model, serialNumber: id, firmwareRevision: info.firmware ?? "1.0.0",
            category: category, services: services + (history.map { [$0.service] } ?? []))
        let external = category == .audioReceiver || category == .tvSetTopBox || category == .tvStreamingStick
        // Building the handler awaited: after a stop() meanwhile, nothing goes on the bridge (or its own server).
        guard !stopped else { return await handler.destroy() }
        do {
            if external {
                try await context.publishExternal(accessory)
            } else {
                try context.add(accessory)
            }
        } catch {
            logger.warning("[\(name)] \(Lang.devNotInit) \(error).")
            await handler.destroy()
            return
        }
        if let previous = devices[id] { await previous.handler.destroy() }
        devices[id] = ManagedDevice(
            id: id, model: model, name: name, accessoryID: accessoryID, handler: handler, transports: transports, awsTopic: awsTopic, ble: ble, external: external)
        if cached == nil { logger.info("[\(name)] \(Lang.devAdd).") }
        logger.info("[\(name)] \(Lang.devInit) [\(id)] [\(model)].")
    }

    /// The devices of the account and of the LAN, for the settings page (`Govee_Discovered_Devices`).
    private func storeDiscoveredDevices() {
        var all: [JSONValue] = []
        var ids = Set<String>()
        for device in httpDevices {
            let id = Govee.colonDeviceId(device["device"]?.stringValue ?? "")
            let model = device["sku"]?.stringValue ?? ""
            var entry: [String: JSONValue] = [
                "deviceId": .string(id), "deviceName": .string(device["deviceName"]?.stringValue ?? ""), "model": .string(model),
                "deviceType": .string(DeviceConfigKey(model: model).rawValue),
            ]
            // The LAN address, for the page's picker when the device was found there too.
            if let ip = lanDevices.first(where: { $0.device == id })?.ip { entry["ip"] = .string(ip) }
            for key in ["goodsType", "pactType", "pactCode", "versionSoft", "versionHard"] {
                if let value = device[key], !value.isNull { entry[key] = value }
            }
            all.append(.object(entry))
            ids.insert(id)
        }
        for device in lanDevices where !ids.contains(device.device) {
            let model = device.sku ?? "HXXXX"
            all.append([
                "deviceId": .string(device.device), "deviceName": .string(deviceSettings[device.device]?.label ?? device.device.replacingOccurrences(of: ":", with: "")),
                "model": .string(model), "deviceType": .string(DeviceConfigKey(model: model).rawValue), "ip": .string(device.ip),
            ])
        }
        discovered = all
        do {
            try discoveredFile.save(all)
            debug("[Storage] Stored \(all.count) discovered devices for UI")
        } catch {
            logger.warning("[Storage] Failed to store discovered devices: \(error)")
        }
    }

    var discoveredFile: JSONFile<[JSONValue]> { context.jsonFile("discovered-devices.json") }

    // MARK: Syncs

    private func startSyncs() {
        let awsDevices = devices.values.filter { $0.transports.useAWS && $0.awsTopic != nil }
        if let awsClient, !awsDevices.isEmpty {
            // The subscription completes only once the broker answers, which may be never: setup goes on.
            tasks.add { [weak self] in
                do {
                    try await awsClient.connect()
                    await self?.awsSync()
                } catch {
                    await self?.logger.warning("[AWS] \(Lang.disableClient) \(error).")
                }
            }
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.awsSyncInterval)
                    guard !Task.isCancelled else { return }
                    await self?.awsSync()
                }
            }
        }
        // Leak sensors, thermo-hygrometers and air quality monitors report through the HTTP device list.
        if account != nil, devices.values.contains(where: { GoveeConstants.httpSensorModels.contains($0.model) }) {
            let interval = Duration.seconds(configuration.httpRefreshTime)
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    await self?.httpSync()
                    try? await Task.sleep(for: interval)
                }
            }
        }
        if let lanClient, devices.values.contains(where: { $0.transports.hasLAN }) || !lanDevices.isEmpty {
            let scan = Duration.seconds(configuration.lanScanInterval)
            let refresh = Duration.seconds(configuration.lanRefreshTime)
            tasks.add { await lanClient.startPolling(scanInterval: scan, refreshInterval: refresh) }
        }
        // Thermo-hygrometers advertise their readings: scan for them every bleRefreshTime.
        if bleClient != nil, devices.values.contains(where: isBLESensor) {
            let interval = Duration.seconds(configuration.bleRefreshTime)
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    await self?.bleSync()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    private nonisolated func isBLESensor(_ device: ManagedDevice) -> Bool {
        device.ble != nil && (GoveeConstants.Models.sensorThermo.contains(device.model) || GoveeConstants.Models.sensorThermo4.contains(device.model))
    }

    func awsSync() async {
        guard let awsClient, !awsSyncInProgress else {
            if awsSyncInProgress { debug("[AWS] Sync already in progress, skipping this cycle") }
            return
        }
        awsSyncInProgress = true
        defer { awsSyncInProgress = false }
        for device in devices.values where device.transports.useAWS {
            guard let topic = device.awsTopic else { continue }
            let handler = device.handler
            do {
                try await awsClient.requestUpdate(topic: topic, log: handler.deviceLog)
            } catch {
                await handler.logDebugWarn("[AWS] \(Lang.syncFail) \(error)")
            }
        }
    }

    func httpSync() async {
        guard let account else { return }
        guard !httpSyncInProgress else {
            debug("[HTTP] Sync already in progress, skipping this cycle")
            return
        }
        httpSyncInProgress = true
        defer { httpSyncInProgress = false }
        do {
            let list = try await account.devices()
            for raw in list {
                let sku = raw["sku"]?.stringValue ?? ""
                guard GoveeConstants.httpSensorModels.contains(sku) else { continue }
                let id = Govee.colonDeviceId(raw["device"]?.stringValue ?? "")
                guard let device = devices[id], let settingsText = raw["deviceExt"]?["deviceSettings"]?.stringValue,
                    let dataText = raw["deviceExt"]?["lastDeviceData"]?.stringValue,
                    let settings = try? JSONValue(string: settingsText), let data = try? JSONValue(string: dataText)
                else { continue }
                var update: [String: JSONValue] = [:]
                if GoveeConstants.Models.sensorLeak.contains(sku) {
                    await device.handler.logDebug("[HTTP] raw sensor data: \(data.text())")
                    let leak = await checkLeakAlerts(device, sku: sku, lastTime: data["lastTime"]?.doubleValue ?? 0)
                    if let battery = settings["battery"] { update["battery"] = battery }
                    update["leakDetected"] = .bool(leak)
                    if data["online"] != nil { update["online"] = .bool(Configuration.truthy(data["gwonline"]) && Configuration.truthy(data["online"])) }
                } else {
                    // Readings in hundredths; 65535 is Govee's "no reading" (the H5310 has no humidity sensor).
                    await device.handler.logDebug("[HTTP] raw sensor data: \(data.text())")
                    if let battery = settings["battery"] { update["battery"] = battery }
                    for (key, field) in [("tem", "temperature"), ("hum", "humidity"), ("pm25", "pm25")] {
                        if let value = data[key], value.doubleValue != 65535 { update[field] = value }
                    }
                    if let online = data["online"] { update["online"] = online }
                }
                await receiveDeviceUpdate(id: id, raw: .object(update), source: .http)
            }
        } catch {
            logger.warning("[HTTP] \(Lang.syncFail) \(error).")
            if let error = error as? GoveeAPIError, error.isAuthFailure { await reauthenticate() }
        }
    }

    /// A leak while an unread leakage alert exists. The alert list is fetched when the sensor reports a new event
    /// (`lastTime` changed), and every five minutes while an alert is active, to notice it being read.
    func checkLeakAlerts(_ device: ManagedDevice, sku: String, lastTime: Double) async -> Bool {
        guard let account, lastTime > 0 else { return false }
        let cached = leakState[device.id]
        let now = Date()
        if let cached, cached.lastTime == lastTime, !cached.leak || now.timeIntervalSince(cached.checkedAt) < Self.leakRecheckInterval {
            return cached.leak
        }
        do {
            let messages = try await account.leakWarnings(deviceId: device.id, sku: sku)
            await device.handler.logDebug("[HTTP] raw messages: \(JSONValue.array(messages).text())")
            let leak = messages.contains { message in
                !Configuration.truthy(message["read"])
                    && (message["message"].flatMap(Configuration.string) ?? "").lowercased().filter { !$0.isWhitespace }.hasPrefix("leakagealert")
            }
            leakState[device.id] = (lastTime, now, leak)
            return leak
        } catch {
            // The last state stays rather than clearing an active alert on a passing failure.
            await device.handler.logDebugWarn("[HTTP] \(Lang.syncFail) \(error)")
            let leak = cached?.leak ?? false
            leakState[device.id] = (cached?.lastTime ?? lastTime, now, leak)
            return leak
        }
    }

    /// For tests: forgets when the leak alerts were checked.
    func resetLeakCheck(_ id: String) {
        if let state = leakState[id] { leakState[id] = (state.lastTime, .distantPast, state.leak) }
    }

    func bleSync() async {
        guard let bleClient, !bleSyncInProgress else { return }
        bleSyncInProgress = true
        defer { bleSyncInProgress = false }
        do {
            try await bleClient.scan(for: { [weak self] reading in Task { await self?.receiveBLEReading(reading) } }, duration: Self.bleScanWindow)
        } catch {
            debug.warn("[BLE] \(Lang.syncFail) \(error).")
        }
    }

    /// A sensor's advertisement: by its address where the system gives it, else by its name.
    func receiveBLEReading(_ reading: BLESensorReading) async {
        let key = (reading.address ?? reading.identifier).lowercased()
        let now = ContinuousClock.now
        if let last = bleLastReading[key], now - last < Self.bleReadingThrottle { return }
        for device in devices.values where isBLESensor(device) {
            guard let target = device.ble, Self.matches(target, reading) else { continue }
            bleLastReading[key] = now
            // The handlers take readings in hundredths, as from HTTP.
            let update: JSONValue = [
                "battery": .number(Double(reading.battery)), "temperature": .number(Govee.round(reading.tempInC * 100)),
                "humidity": .number(Govee.round(reading.humidity * 100)),
            ]
            await receiveDeviceUpdate(id: device.id, raw: update, source: .ble)
        }
    }

    static func matches(_ target: BLETarget, _ reading: BLESensorReading) -> Bool {
        if let address = reading.address, !address.isEmpty { return address.lowercased() == target.address.lowercased() }
        guard !reading.model.isEmpty else { return false }
        if let name = target.name, !name.isEmpty, reading.model.caseInsensitiveCompare(name) == .orderedSame { return true }
        let suffix = target.address.replacingOccurrences(of: ":", with: "").suffix(4).uppercased()
        return suffix.count == 4 && reading.model.uppercased().hasSuffix("_" + suffix)
    }

    // MARK: Commands

    /// Sends a command over LAN, then AWS, then BLE. BLE commands are queued, and a newer command of the same
    /// kind for the same device replaces a queued one (a dragged slider).
    func sendDeviceUpdate(id: String, _ command: DeviceCommand) async throws {
        guard let device = devices[id] else { throw HAPStatusError(.serviceCommunicationFailure) }
        let handler = device.handler
        let log = handler.deviceLog
        let commands = TransportCommands(command, model: device.model, options: (deviceSettings[id] ?? DeviceSettings()).commandOptions)

        if device.transports.useLAN, let lan = commands.lan, let lanClient {
            do {
                try await lanClient.updateDevice(id: id, params: lan, log: log)
                return
            } catch {
                await handler.logWarn("\(Lang.notLANSent) \(error)")
            }
        }
        if device.transports.useAWS, let aws = commands.aws, let awsClient, let topic = device.awsTopic {
            do {
                try await awsClient.updateDevice(topic: topic, params: aws, log: log)
                return
            } catch {
                await handler.logWarn("\(Lang.notAWSSent) \(error)")
            }
        }
        // Without a BLE form the command has nowhere else to go: HomeKit hears of the failure rather than
        // showing a state the device never got.
        guard let ble = commands.ble else { throw GoveeAPIError.message(Lang.noConnMethod) }

        let kind = command.setsColourMode ? "colour" : command.name
        let coalesceKey: String? = command.name == "ptReal" ? nil : "\(id):\(kind)"
        bleCommandSequence += 1
        let sequence = bleCommandSequence
        if let coalesceKey { bleLatestCommand[coalesceKey] = sequence }
        let useBLE = device.transports.useBLE
        let target = device.ble
        try await queue.add { [weak self] in
            guard let self else { return }
            if let coalesceKey {
                guard await self.takeLatest(coalesceKey, sequence) else { return }
            }
            if useBLE, let target, let bleClient = await self.bleClient {
                do {
                    try await bleClient.updateDevice(target, params: ble, log: log)
                    return
                } catch {
                    await handler.logDebugWarn("\(Lang.notBLESent) \(error)")
                }
            }
            throw GoveeAPIError.message(Lang.noConnMethod)
        }
    }

    /// Whether the queued command is still the latest of its kind (and so is sent).
    private func takeLatest(_ key: String, _ sequence: Int) -> Bool {
        guard bleLatestCommand[key] == sequence else { return false }
        bleLatestCommand[key] = nil
        return true
    }

    /// For tests: the BLE queue.
    var commandQueue: CommandQueue { queue }

    // MARK: Reports

    func receiveUpdateLAN(_ id: String, _ data: JSONValue, ip: String) async {
        guard var device = devices[id] else { return }
        if !device.transports.useLAN {
            device.transports.hasLAN = true
            device.transports.useLAN = true
            devices[id] = device
            await device.handler.setTransports(device.transports)
        }
        if store.value(id, "ip")?.stringValue != ip {
            store.set(id, "ip", .string(ip))
            await device.handler.log("[LAN] \(Lang.curIP) [\(ip)]")
        }
        if let object = data.objectValue, !object.isEmpty {
            await receiveDeviceUpdate(id: id, raw: data, source: .lan)
        }
    }

    func receiveUpdateAWS(_ payload: JSONValue) async {
        guard let raw = payload["device"]?.stringValue else { return }
        let id = Govee.colonDeviceId(raw).uppercased()
        guard devices[id] != nil else { return }
        await receiveDeviceUpdate(id: id, raw: payload, source: .aws)
    }

    func receiveDeviceUpdate(id: String, raw: JSONValue, source: DeviceUpdate.Source) async {
        guard let device = devices[id] else { return }
        let update = DeviceUpdate(raw: raw, source: source, model: device.model)
        guard update.hasValues else { return }
        devices[id]?.lastUpdate = Date()
        await device.handler.externalUpdate(update)
    }
}

/// Lines that `debug: true` raises from debug to info (or warning), as the Homebridge plugin's `log.debug` did;
/// from any task.
struct DebugLog: Sendable {
    let logger: Logger
    let raised: Bool

    func callAsFunction(_ message: @autoclosure () -> String) {
        if raised { logger.info("\(message())") } else { logger.debug("\(message())") }
    }

    func warn(_ message: @autoclosure () -> String) {
        if raised { logger.warning("\(message())") } else { logger.debug("\(message())") }
    }
}
