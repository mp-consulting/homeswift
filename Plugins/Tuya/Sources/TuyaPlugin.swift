import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Tuya and Smart Life devices through the Tuya Cloud OpenAPI: a Smart Home project (the app's account linked to a
/// cloud project) or a Custom project. Lights, switches, plugs, climate, covers, locks, sensors, cameras' events, IR
/// remotes and the account's scenes; states come from Tuya's MQTT push, writes from HomeKit go to the cloud, coalesced.
///
/// The configuration is the one of homebridge-tuya-platform, so a Homebridge block works unchanged; the account's
/// secrets move into the vault. See README.md in this directory, and docs/clean-room/Tuya.md for the specification it
/// was written from.
public actor TuyaPlugin: HomeswiftPlugin {
    public typealias Configuration = TuyaConfiguration

    /// What the plugin uses to reach the cloud; tests swap them for fakes and shorten its delays.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        var makeMQTT: @Sendable (MQTTConfiguration) -> any MQTTConnection = { MQTTClient($0) }
        /// Multiplies the plugin's own delays (the write debounce, a scene switch's reset, a bound device's wait).
        var timeScale: Double = 1
        var now: @Sendable () -> Date = { Date() }
        var nonce: @Sendable () -> String = { UUID().uuidString.lowercased() }
        var loginBackoff = Backoff(initial: .seconds(30), maximum: .seconds(1800), jitter: .proportional(0.2))
        var pushBackoff = Backoff(initial: .seconds(5), maximum: .seconds(600), jitter: .proportional(0.2))
        var requestBackoff = Backoff(initial: .milliseconds(100), maximum: .seconds(60), jitter: .additive(.milliseconds(100)))
    }

    public static let platform = "TuyaPlatform"
    public static let name = "Tuya"
    public static let icon: String? = "switch"
    public static let summary: String? = "Tuya and Smart Life devices through the Tuya cloud"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    var logger: Logger { context.logger }
    private(set) var settings: TuyaSettings?
    private(set) var api: TuyaOpenAPI?
    private var push: TuyaPush?
    /// Each device's accessory, by device id.
    private(set) var runtimes: [String: TuyaRuntime] = [:]
    /// The home ids (Smart Home) or asset ids (Custom) the devices come from.
    private var ownerIDs: Set<String> = []

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// The block's options checked, with the vault's secrets.
    func validatedSettings() -> Result<TuyaSettings, TuyaConfigurationError> {
        TuyaSettings.validate(configuration.options, credentials: context.credentials(as: TuyaAccountCredentials.self))
    }

    public func start() async throws {
        switch validatedSettings() {
        case .failure(let error):
            for problem in error.problems { logger.error("\(problem)") }
            logger.error("Tuya is not started: run its Setup, or correct the block")
        case .success(let settings):
            self.settings = settings
            tasks.add { [weak self] in await self?.connect() }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        await push?.stop()
    }

    func makeAPI(_ settings: TuyaSettings) -> TuyaOpenAPI {
        TuyaOpenAPI(
            accessID: settings.accessID, accessKey: settings.accessKey, host: settings.endpointHost, transport: dependencies.transport, logger: logger,
            debug: settings.debugAPI, now: dependencies.now, nonce: dependencies.nonce, retryBackoff: dependencies.requestBackoff)
    }

    /// Signs in (again after a failure, with a growing delay, unless the credentials are refused), starts the push and
    /// adds the accessories.
    private func connect() async {
        guard let settings else { return }
        var attempt = 0
        while !Task.isCancelled {
            let api = makeAPI(settings)
            do {
                let owners = try await signIn(api, settings)
                self.api = api
                let push = TuyaPush(
                    api: api, version: settings.projectType == .custom ? "2.0" : "1.0", logger: logger, debug: settings.debug,
                    timeScale: dependencies.timeScale, backoff: dependencies.pushBackoff, now: dependencies.now, makeConnection: dependencies.makeMQTT
                ) { [weak self] message in await self?.handle(message) }
                self.push = push
                await push.start()
                let devices = try await loadDevices(api, settings, owners: owners)
                await addAccessories(devices)
                return
            } catch let error as TuyaAPIError where [1004, 1106, 1114, 2401, 2406, 28841002].contains(error.code) {
                logger.error("Could not sign in to Tuya: \(error)")
                return
            } catch is CancellationError {
                return
            } catch {
                logger.error("Could not reach Tuya, trying again: \(error)")
                try? await Task.sleep(for: dependencies.loginBackoff.delay(attempt: attempt))
                attempt += 1
            }
        }
    }

    /// The project's token; answers the owner ids (assets) a Custom project's login gives.
    func signIn(_ api: TuyaOpenAPI, _ settings: TuyaSettings) async throws -> [String] {
        switch settings.projectType {
        case .smartHome:
            try await api.loginSmartHome(countryCode: settings.countryCode, username: settings.username, password: settings.password, appSchema: settings.appSchema)
            return []
        case .custom:
            return try await api.loginCustom()
        }
    }

    // MARK: Devices

    /// The override for a device: its Accessory Settings', else `deviceOverrides` (its id or uuid, product, `global`).
    func override(id: String, uuid: String?, productID: String?) -> TuyaConfiguration.DeviceOverride? {
        let own = context.accessorySettings(for: id).plugin
        if !own.isEmpty, var item = try? JSONValue.object(own).decode(TuyaConfiguration.DeviceOverride.self, withID: id) {
            item.id = id
            return item
        }
        return settings?.override(id: id, uuid: uuid, productID: productID)
    }

    /// The homes' (or assets') devices with their specifications, the scenes, the overrides' categories, and the IR remotes.
    func loadDevices(_ api: TuyaOpenAPI, _ settings: TuyaSettings, owners: [String]) async throws -> [TuyaDevice] {
        var records: [JSONValue] = []
        var scenes: [TuyaDevice] = []
        var ownerIDs = Set<String>()
        switch settings.projectType {
        case .smartHome:
            logger.info("Fetching the home list")
            for home in try await api.homes() {
                let id = TuyaDevice.text(home["home_id"])
                let included = settings.homeWhitelist.map { list in Int(id).map(list.contains) ?? false } ?? true
                logger.info("Home \(id) (\(home["name"]?.stringValue ?? "")) is \(included ? "included" : "excluded by homeWhitelist")")
                if included { ownerIDs.insert(id) }
            }
            logger.info("Fetching the device list")
            for home in ownerIDs.sorted() { records += try await api.homeDevices(home) }
            logger.info("Fetching the scene list")
            for home in ownerIDs.sorted() {
                do {
                    for scene in try await api.scenes(home) where scene["enabled"]?.boolValue == true && TuyaDevice.text(scene["status"]) == "1" {
                        let id = TuyaDevice.text(scene["scene_id"])
                        guard !id.isEmpty else { continue }
                        let name = scene["name"]?.stringValue ?? "Scene"
                        logger.info("Scene \(id) (\(name))")
                        let override = override(id: id, uuid: id, productID: "scene")
                        scenes.append(TuyaDevice(
                            id: id, uuid: id, name: name, online: true, productID: "scene", ownerID: home,
                            category: override?.category.flatMap { $0.isEmpty ? nil : $0 } ?? "scene", status: [:], schema: [:], override: override,
                            isScene: true, logger: logger))
                    }
                } catch {
                    logger.warning("Could not fetch the scenes of home \(home): \(error)")
                }
            }
        case .custom:
            ownerIDs = Set(owners)
            var ids: [String] = []
            for asset in owners { ids += try await api.assetDeviceIDs(asset) }
            logger.info("Fetching the device list")
            records = try await api.devices(ids: ids)
        }
        self.ownerIDs = ownerIDs
        // The specifications, six at a time, in the records' order.
        var devices: [TuyaDevice] = []
        for start in stride(from: 0, to: records.count, by: 6) {
            let chunk = Array(records[start..<min(start + 6, records.count)])
            devices += await withTaskGroup(of: (Int, TuyaDevice).self) { group in
                for (index, record) in chunk.enumerated() { group.addTask { (index, await self.makeDevice(record, api: api)) } }
                var made: [(Int, TuyaDevice)] = []
                for await item in group { made.append(item) }
                return made.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        devices = await discoverRemotes(devices, api: api)
        logger.info("Got \(devices.count + scenes.count) device(s) and scene(s)")
        return devices + scenes
    }

    /// A device from its record, with its specification and override.
    func makeDevice(_ record: JSONValue, api: TuyaOpenAPI, applyCategory: Bool = true) async -> TuyaDevice {
        let id = TuyaDevice.text(record["id"])
        var specification: JSONValue?
        do {
            specification = try await api.specification(id)
        } catch {
            logger.warning("Could not fetch the specification of \(record["name"]?.stringValue ?? id): \(error)")
        }
        var override = override(id: id, uuid: record["uuid"]?.stringValue, productID: record["product_id"]?.stringValue)
        if !applyCategory { override?.category = nil }
        let device = TuyaDevice(record: record, specification: specification, override: override, logger: logger)
        if let category = override?.category, !category.isEmpty, category != record["category"]?.stringValue {
            logger.warning("\(device.name)'s category is overridden from \(record["category"]?.stringValue ?? "") to \(category)")
        }
        return device
    }

    /// Each IR hub's remotes that are devices of the list: their keys, an AC's state, a DIY remote's learned codes.
    func discoverRemotes(_ devices: [TuyaDevice], api: TuyaOpenAPI) async -> [TuyaDevice] {
        var byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for hub in devices where TuyaAccessoryBuilder.irHubCategories.contains(hub.category) {
            let remotes: [JSONValue]
            do {
                remotes = try await api.remotes(hub: hub.id)
            } catch {
                logger.warning("Could not list the remotes of \(hub.name): \(error)")
                continue
            }
            for remote in remotes {
                let remoteID = TuyaDevice.text(remote["remote_id"])
                guard let device = byID[remoteID] else { continue }
                do {
                    var keys = TuyaRemoteKeys(try await api.remoteKeys(hub: hub.id, remote: remoteID))
                    var status: [String: JSONValue]?
                    if device.category == "infrared_ac" {
                        status = try await api.airConditionerStatus(hub: hub.id, remote: remoteID).objectValue ?? [:]
                    } else if remote["category_id"]?.intValue == 999 {
                        let learned = try await api.learnedCodes(hub: hub.id, remote: remoteID)
                        for index in keys.keys.indices {
                            let key = keys.keys[index]
                            keys.keys[index].learnedCode = learned.first {
                                $0["id"]?.intValue == key.keyID && $0["key"]?.stringValue == key.key
                            }?["code"]?.stringValue
                        }
                    }
                    byID[remoteID] = device.with(parentID: hub.id, remote: keys, status: status, schema: [:])
                } catch {
                    logger.warning("Could not read the remote \(device.name) of \(hub.name): \(error)")
                }
            }
        }
        return devices.map { byID[$0.id] ?? $0 }
    }

    // MARK: Accessories

    private func addAccessories(_ devices: [TuyaDevice]) async {
        var keep = Set<String>()
        for device in devices {
            guard device.category != "hidden" else {
                logger.info("\(device.name) is hidden by its override")
                continue
            }
            guard !context.isExcluded(device.id) else { continue }
            if await add(device, among: devices) { keep.insert(Self.accessoryID(deviceID: device.id)) }
        }
        await context.removeAccessories(keeping: keep, message: "Removing an accessory no Tuya device has")
    }

    /// Builds and adds a device's accessory; false when it could not be added.
    @discardableResult
    func add(_ device: TuyaDevice, among devices: [TuyaDevice]) async -> Bool {
        guard let api else { return false }
        let id = Self.accessoryID(deviceID: device.id)
        let link = TuyaDeviceLink(device: device, api: api, logger: logger, timeScale: dependencies.timeScale)
        let builder = TuyaAccessoryBuilder(device: device, link: link, logger: logger)
        if let parentID = device.parentID { builder.parent = devices.first { $0.id == parentID } ?? runtimes[parentID]?.device }
        if !builder.build() {
            builder.drafts = []
            builder.events = []
            builder.adaptiveLights = []
        }
        builder.finish()
        let runtime = TuyaRuntime(device: device)
        let services = runtime.makeServices(builder.drafts)
        let accessory = Accessory(
            id: id, name: device.name, manufacturer: "Tuya Inc.", model: device.productID.isEmpty ? "Tuya" : device.productID,
            serialNumber: device.uuid.isEmpty ? device.id : device.uuid, category: Self.category(builder.drafts.first?.type), services: services)
        runtime.bind(accessory.information.characteristic(adding: .statusActive), onlineCheck: false) { .bool(device.online) }
        for light in builder.adaptiveLights {
            light.controller = light.service.flatMap { context.adaptiveLighting(for: $0, accessoryID: id) }
        }
        runtime.events = builder.events
        runtime.lights = builder.adaptiveLights
        if let cached = context.accessory(id: id) { accessory.takeValues(from: cached) }
        runtime.refresh()
        link.onRefresh = { [weak runtime] in runtime?.refresh() }
        do {
            if device.override?.unbridged == true {
                logger.info("\(device.name) is unbridged: add it in the Home app as an accessory of its own")
                try await context.publishExternal(accessory)
            } else {
                try context.add(accessory)
            }
        } catch {
            logger.error("Could not add \(device.name): \(error)")
            return false
        }
        runtimes[device.id] = runtime
        return true
    }

    static func category(_ type: ServiceType?) -> AccessoryCategory {
        guard let type else { return .other }
        let categories: [(ServiceType, AccessoryCategory)] = [
            (.lightbulb, .lightbulb), (.switch, .switch), (.outlet, .outlet), (.fan, .fan), (.fanv2, .fan), (.heaterCooler, .airConditioner),
            (.thermostat, .thermostat), (.windowCovering, .windowCovering), (.garageDoorOpener, .garageDoorOpener), (.lockMechanism, .doorLock),
            (.securitySystem, .securitySystem), (.airPurifier, .airPurifier), (.humidifierDehumidifier, .humidifier), (.valve, .sprinkler),
            (.statelessProgrammableSwitch, .programmableSwitch), (.doorbell, .videoDoorbell),
        ]
        return categories.first { $0.0.uuid == type.uuid }?.1 ?? .sensor
    }

    // MARK: Push

    func handle(_ message: TuyaPushMessage) async {
        switch message {
        case .status(let deviceID, let items, _):
            guard let runtime = runtimes[deviceID] else { return }
            let changed = runtime.device.apply(items.map { ($0.code, $0.value) })
            runtime.pushed(items, changed: changed)
            // An IR hub's remotes show its temperature and humidity.
            if changed, TuyaAccessoryBuilder.irHubCategories.contains(runtime.device.category) {
                for remote in runtimes.values where remote.device.parentID == deviceID { remote.refresh() }
            }
        case .lifecycle(let code, let deviceID, let data):
            await lifecycle(code, deviceID: deviceID, data: data)
        }
    }

    private func lifecycle(_ code: String, deviceID: String, data: JSONValue) async {
        switch code {
        case "online", "offline":
            guard let runtime = runtimes[deviceID] else { return }
            runtime.device.online = code == "online"
            runtime.refresh()
        case "nameUpdate":
            guard let runtime = runtimes[deviceID], let name = data["name"]?.stringValue else { return }
            runtime.device.name = name
            runtime.refresh()
        case "bindUser":
            let owner = TuyaDevice.text(data["ownerId"])
            guard ownerIDs.contains(owner) else {
                logger.warning("A device was bound to \(owner), which is not a loaded home or asset: ignored")
                return
            }
            tasks.add { [weak self] in await self?.bind(deviceID) }
        case "delete":
            let owner = TuyaDevice.text(data["ownerId"])
            guard ownerIDs.contains(owner) else {
                logger.warning("A device was removed from \(owner), which is not a loaded home or asset: ignored")
                return
            }
            runtimes.removeValue(forKey: deviceID)
            try? await context.remove(id: Self.accessoryID(deviceID: deviceID))
            logger.info("Removed the accessory of \(deviceID), deleted from Tuya")
        case "event_notify", "p2pSignal":
            break
        default:
            logger.debug("Unhandled Tuya lifecycle message \(code)")
        }
    }

    /// A device bound since the start: after 10 seconds, its record and specification, a new MQTT connection, and its
    /// accessory.
    private func bind(_ deviceID: String) async {
        try? await Task.sleep(for: .seconds(10) * dependencies.timeScale)
        guard !Task.isCancelled, let api else { return }
        do {
            let record = try await api.device(deviceID)
            let device = await makeDevice(record, api: api, applyCategory: false)
            await push?.restart()
            guard device.category != "hidden", !context.isExcluded(device.id) else { return }
            await add(device, among: runtimes.values.map(\.device))
            logger.info("Added \(device.name), bound to the account")
        } catch {
            logger.warning("Could not add the device \(deviceID) bound to the account: \(error)")
        }
    }
}

/// A device's accessory once built: what each characteristic reads, the events, Adaptive Lighting.
final class TuyaRuntime: Sendable {
    let device: TuyaDevice

    private struct State {
        var bindings: [(characteristic: Characteristic, onlineCheck: Bool, get: TuyaGetter)] = []
        var events: [TuyaEventHandler] = []
        var lights: [TuyaAdaptiveLight] = []
    }

    private let state = NIOLockedValueBox(State())

    init(device: TuyaDevice) {
        self.device = device
    }

    var events: [TuyaEventHandler] {
        get { state.withLockedValue { $0.events } }
        set { state.withLockedValue { $0.events = newValue } }
    }

    var lights: [TuyaAdaptiveLight] {
        get { state.withLockedValue { $0.lights } }
        set { state.withLockedValue { $0.lights = newValue } }
    }

    func bind(_ characteristic: Characteristic, onlineCheck: Bool, get: @escaping TuyaGetter) {
        state.withLockedValue { $0.bindings.append((characteristic, onlineCheck, get)) }
    }

    /// The drafts' services, with their handlers and bindings.
    func makeServices(_ drafts: [TuyaServiceDraft]) -> [Service] {
        let device = device
        return drafts.enumerated().map { index, draft in
            var optional = draft.specs.map(\.type)
            if draft.configuredName != nil { optional.append(.configuredName) }
            let service = Service(draft.type, name: draft.name, subtype: draft.subtype, optional: optional, isPrimary: index == 0)
            if let name = draft.configuredName { service.characteristic(.configuredName).value = .string(name) }
            for spec in draft.specs {
                guard let characteristic = service[spec.type] else { continue }
                spec.ref.characteristic = characteristic
                if let value = spec.value { characteristic.value = value }
                if let get = spec.get {
                    bind(characteristic, onlineCheck: spec.onlineCheck, get: get)
                    if spec.onlineCheck {
                        let ref = spec.ref
                        characteristic.onRead {
                            guard device.online else { throw HAPStatusError(.serviceCommunicationFailure) }
                            return get() ?? ref.characteristic?.value ?? .null
                        }
                    }
                }
                if let set = spec.set { characteristic.onWrite(set) }
            }
            draft.onBuild?(service)
            return service
        }
    }

    /// Every characteristic read again from the device's state; those that fail while offline are left.
    func refresh() {
        let online = device.online
        for binding in state.withLockedValue({ $0.bindings }) where online || !binding.onlineCheck {
            if let value = binding.get() { binding.characteristic.value = value }
        }
    }

    /// A push's items: Adaptive Lighting checked against them first, then the values, then the events.
    /// `items` are the device's codes; the handlers see the accessories' (an override's `newCode`). The characteristics are
    /// read again only when the push changed a value.
    func pushed(_ items: [TuyaPushMessage.StatusItem], changed: Bool) {
        let items = items.map { item in
            var item = item
            item.code = device.requestedCode(for: item.code)
            return item
        }
        for light in lights { light.check(items) }
        if changed { refresh() }
        for event in events { event(items) }
    }
}

extension JSONValue {
    /// An override from Accessory Settings: the `id` they lack is filled in.
    func decode(_ type: TuyaConfiguration.DeviceOverride.Type, withID id: String) throws -> TuyaConfiguration.DeviceOverride {
        var fields = objectValue ?? [:]
        fields["id"] = .string(id)
        return try JSONValue.object(fields).decode(type)
    }
}
