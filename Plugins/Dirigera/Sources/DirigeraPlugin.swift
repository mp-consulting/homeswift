import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// IKEA lights, outlets, door and window sensors and scenes through DIRIGERA hubs' local API, without the cloud.
///
/// Each light is a lightbulb (brightness, colour, white temperature as the bulb takes them), each outlet an outlet,
/// each door and window sensor (PARASOLL) a contact sensor with its battery,
/// and each hub's scenes a switch apiece on one accessory: On triggers the scene, the switch goes back off, and Off
/// within the hub's undo window undoes it. A light's changes of one moment are sent in order (on, brightness, then
/// colour, as the hub wants them one at a time) with the transition of `transitionMs`. The hub pushes changes over its
/// websocket, so the Home app follows the IKEA app and the remotes at once.
///
/// The block is homebridge-dirigera's (`hubs`, each with `host` and an optional `token`). A hub without a token pairs
/// from the plugin's page: the page asks for the hub's action button, and the token is kept in the plugin's directory
/// (`hubs.json`), never in config.json. See README.md in this directory.
public actor DirigeraPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Hub: Decodable, Sendable {
            public var host: String
            public var token: String?
            public var name: String?
        }

        public var name: String?
        public var hubs: [Hub]?
        /// Milliseconds a light takes to reach a new level or colour; 100 by default.
        public var transitionMs: Int?
        public var scenes: Bool?
        public var excludeDevices: [String]?
        public var excludeScenes: [String]?
    }

    /// What the plugin keeps of a hub in `hubs.json`, by address.
    struct StoredHub: Codable, Sendable, Equatable {
        var token: String?
        var fingerprint: String?
        var name: String?
    }

    struct Dependencies: Sendable {
        var transport: @Sendable (HTTPClient.TrustOnFirstUse) -> any HTTPSending = { PinningTransport(trust: $0) }
        var events: @Sendable (_ host: String, _ token: String, _ tls: HTTPClient.TLS) async throws -> AsyncThrowingStream<JSONValue, any Error> = DirigeraEvents.connect
        var discover: @Sendable () async -> [String] = DirigeraDiscovery.find
        /// How long to wait before connecting the events again.
        var reconnectDelay: Duration = .seconds(5)
    }

    public static let platform = "Dirigera"
    public static let name = "IKEA DIRIGERA"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultTransition = 100
    static let pairingWindow = Duration.seconds(60)
    /// A scene switch goes back off after this.
    static let sceneSwitchReset = Duration.seconds(1)
    /// How long Off can still undo a scene (the hub's `undoAllowedDuration`, 30 s).
    static let undoWindow = Duration.seconds(30)

    let configuration: Configuration
    /// `excludeDevices` and `excludeScenes`, lowercased once: every refresh checks each device and scene against them.
    private let excludedDevices: Set<String>
    private let excludedScenes: Set<String>
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var logger: Logger { context.logger }
    private let store: JSONFile<[String: StoredHub]>
    /// The pictures people gave scenes on the page, by scene id.
    let pictures: PluginPictures
    private var stored: [String: StoredHub]

    /// One hub's connection and what it shows.
    final class Hub: @unchecked Sendable {
        let host: String
        let client: DirigeraClient
        let trust: HTTPClient.TrustOnFirstUse
        var devices: [String: DirigeraDevice] = [:]
        var scenes: [DirigeraScene] = []
        var error: String?
        var connected = false
        var pairing = false
        var pairingDeadline: ContinuousClock.Instant?

        init(host: String, client: DirigeraClient, trust: HTTPClient.TrustOnFirstUse) {
            self.host = host
            self.client = client
            self.trust = trust
        }
    }

    private(set) var hubs: [String: Hub] = [:]
    private var accessories: [String: DeviceServices] = [:]
    private var sceneAccessories: [String: SceneServices] = [:]
    private var lastTriggered: [String: ContinuousClock.Instant] = [:]

    struct DeviceServices {
        let accessory: Accessory
        let service: Service
        var battery: Service? = nil
        let writer: LightChangeBatcher?
        let shape: String
    }

    struct SceneServices {
        let accessory: Accessory
        var switches: [String: Service]
        let shape: String
    }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        excludedDevices = Set((configuration.excludeDevices ?? []).map { $0.lowercased() })
        excludedScenes = Set((configuration.excludeScenes ?? []).map { $0.lowercased() })
        self.context = context
        self.dependencies = dependencies
        store = context.jsonFile("hubs.json")
        pictures = context.pictures("scene-pictures")
        stored = store.load() ?? [:]
    }

    var transitionMs: Int { min(max(configuration.transitionMs ?? Self.defaultTransition, 0), 10000) }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }
    static func sceneAccessoryID(host: String) -> String { "\(platform):scenes:\(host)" }

    /// The hubs to run: config.json's, then the ones paired from the page.
    var hubHosts: [String] {
        var hosts = (configuration.hubs ?? []).map { $0.host.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for host in stored.keys.sorted() where !hosts.contains(host) && stored[host]?.token != nil { hosts.append(host) }
        return hosts
    }

    public func start() async throws {
        for host in hubHosts { open(host) }
        if hubHosts.isEmpty { logger.info("No DIRIGERA hub yet: find and pair one on the plugin's page") }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    private func token(for host: String) -> String? {
        configuration.hubs?.first { $0.host == host }?.token?.nonEmpty ?? stored[host]?.token
    }

    @discardableResult
    private func open(_ host: String) -> Hub {
        if let hub = hubs[host] { return hub }
        let store = store
        let trust = HTTPClient.TrustOnFirstUse(pinned: stored[host]?.fingerprint) { fingerprint in
            var hubs = store.load() ?? [:]
            hubs[host, default: StoredHub()].fingerprint = fingerprint
            try? store.save(hubs)
        }
        let hub = Hub(host: host, client: DirigeraClient(host: host, token: token(for: host), transport: dependencies.transport(trust)), trust: trust)
        hubs[host] = hub
        if token(for: host) != nil { tasks.add { [weak self] in await self?.run(hub) } }
        return hub
    }

    private func save() {
        do { try store.save(stored) } catch { logger.warning("Could not save hubs.json: \(error)") }
    }

    // MARK: Running a hub

    /// Reads the hub, then follows its events; reconnects when they stop.
    private func run(_ hub: Hub) async {
        while !Task.isCancelled {
            await refresh(hub)
            guard let token = await hub.client.token else { return }
            do {
                let events = try await dependencies.events(hub.host, token, hub.trust.tls)
                hub.connected = true
                for try await event in events { await handle(event, from: hub) }
            } catch {
                if hub.error == nil { logger.warning("Lost the DIRIGERA hub's events at \(hub.host): \(error)") }
            }
            hub.connected = false
            try? await Task.sleep(for: dependencies.reconnectDelay)
        }
    }

    /// Reads every device and scene of the hub and shows them.
    func refresh(_ hub: Hub) async {
        do {
            // Both at once: two requests, each with its own round trip.
            async let readDevices = hub.client.devices()
            async let readScenes = (configuration.scenes ?? true) ? hub.client.scenes() : []
            let devices = try await readDevices.compactMap(DirigeraDevice.init)
            let scenes = try await readScenes.compactMap(DirigeraScene.init)
            if hub.error != nil { logger.info("The DIRIGERA hub at \(hub.host) answers again") }
            hub.error = nil
            hub.devices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            hub.scenes = scenes.sorted { $0.name < $1.name }
        } catch DirigeraClient.Failure.unauthorized {
            hub.error = "The DIRIGERA hub refused the token: pair again from the plugin's page."
            logger.warning("The DIRIGERA hub at \(hub.host) refused the token; pair again from the plugin's page")
            stored[hub.host]?.token = nil
            save()
            await hub.client.setToken(nil)
            markUnavailable(hub)
            return
        } catch {
            if hub.error == nil { logger.warning("Could not reach the DIRIGERA hub at \(hub.host): \(error)") }
            hub.error = "\(error)"
            markUnavailable(hub)
            return
        }
        await show(hub)
    }

    /// Refreshes every hub: for tests and the page.
    func refreshAll() async {
        for hub in hubs.values { await refresh(hub) }
    }

    private func markUnavailable(_ hub: Hub) {
        for id in hub.devices.keys { accessories[id]?.accessory.isUnavailable = true }
    }

    private func handle(_ event: JSONValue, from hub: Hub) async {
        switch event["type"]?.stringValue {
        case "deviceStateChanged":
            guard let id = event["data"]?["id"]?.stringValue, var device = hub.devices[id] else { return }
            device.apply(event["data"]?["attributes"], reachable: event["data"]?["isReachable"]?.boolValue)
            hub.devices[id] = device
            if let services = accessories[id] {
                if let writer = services.writer, await writer.isSettling { return }
                Self.showValues(device, on: services)
            }
        case "deviceAdded", "deviceRemoved", "sceneCreated", "sceneUpdated", "sceneDeleted", "deviceConfigurationChanged":
            await refresh(hub)
        default:
            break
        }
    }

    // MARK: Accessories

    func isExcluded(_ device: DirigeraDevice) -> Bool {
        excludedDevices.contains(device.name.lowercased()) || excludedDevices.contains(device.id.lowercased())
    }

    func visibleScenes(_ hub: Hub) -> [DirigeraScene] {
        hub.scenes.filter { !excludedScenes.contains($0.name.lowercased()) && !excludedScenes.contains($0.id.lowercased()) }
    }

    private func show(_ hub: Hub) async {
        var keep: Set<String> = []
        for hub in hubs.values {
            keep.formUnion(hub.devices.values.filter { !isExcluded($0) }.map { Self.accessoryID(deviceID: $0.id) })
            if !visibleScenes(hub).isEmpty { keep.insert(Self.sceneAccessoryID(host: hub.host)) }
        }
        for device in hub.devices.values.sorted(by: { $0.name < $1.name }) where !isExcluded(device) {
            let shape = Self.shape(of: device)
            if let services = accessories[device.id], services.shape == shape {
                services.accessory.isUnavailable = !device.reachable
                if let writer = services.writer, await writer.isSettling { continue }
                Self.showValues(device, on: services)
                continue
            }
            do { try add(device, on: hub, shape: shape) } catch { logger.error("Could not add \(device.name): \(error)") }
        }
        showScenes(hub)
        accessories = accessories.filter { keep.contains(Self.accessoryID(deviceID: $0.key)) }
        _ = await context.removeAccessories(keeping: keep, message: "Removing an IKEA device or scene the hub no longer has")
    }

    static func shape(of device: DirigeraDevice) -> String {
        [device.kind.rawValue, device.battery != nil ? "b" : "", device.brightness != nil ? "d" : "", device.hasColour ? "c" : "", device.mirekRange.map { "t\($0.lowerBound)-\($0.upperBound)" } ?? ""]
            .joined(separator: "|")
    }

    /// A sensor's battery is low below this.
    static let lowBattery = 10

    static func showValues(_ device: DirigeraDevice, on services: DeviceServices) {
        let service = services.service
        if device.kind == .contact {
            // 0 is contact detected (closed), 1 not detected (open).
            service.characteristic(.contactSensorState).value = .int(device.open ? 1 : 0)
            if let battery = device.battery, let level = services.battery {
                level.characteristic(.batteryLevel).value = .int(min(max(battery, 0), 100))
                level.characteristic(.statusLowBattery).value = .int(battery < lowBattery ? 1 : 0)
            }
            return
        }
        service.characteristic(.on).value = .bool(device.on)
        if let brightness = device.brightness { service[.brightness]?.value = .int(brightness) }
        if let hue = device.hue { service[.hue]?.value = .double(hue.rounded()) }
        if let saturation = device.saturation { service[.saturation]?.value = .double(saturation.rounded()) }
        if let mirek = device.mirek, let characteristic = service[.colorTemperature] {
            let low = Int(characteristic.type.minValue ?? 140), high = Int(characteristic.type.maxValue ?? 500)
            characteristic.value = .int(min(max(mirek, low), high))
        }
    }

    private func add(_ device: DirigeraDevice, on hub: Hub, shape: String) throws {
        let client = hub.client
        let deviceID = device.id
        let fail: @Sendable (any Error) -> HAPStatusError = { _ in HAPStatusError(.serviceCommunicationFailure) }
        let service: Service
        var writer: LightChangeBatcher?
        var battery: Service?
        switch device.kind {
        case .contact:
            service = Service(.contactSensor, name: device.name, isPrimary: true)
            if device.battery != nil {
                battery = Service(.battery, name: "Battery", optional: [.batteryLevel])
                service.linked = [battery!]
            }
        case .outlet:
            service = Service(.outlet, name: device.name, isPrimary: true)
            service.characteristic(.on).onWrite { value in
                do { try await client.patch(deviceID: deviceID, attributes: ["isOn": .bool(value.boolValue ?? false)]) } catch { throw fail(error) }
            }
        case .light:
            var optional: [CharacteristicType] = []
            if device.brightness != nil { optional.append(.brightness) }
            if device.hasColour { optional += [.hue, .saturation] }
            if let range = device.mirekRange {
                optional.append(.colorTemperature.with(minValue: Double(max(140, range.lowerBound)), maxValue: Double(min(500, range.upperBound))))
            }
            let bulb = Service(.lightbulb, name: device.name, optional: optional, isPrimary: true)
            let commands = DirigeraLightCommands(
                transitionMs: transitionMs,
                currentColour: { [bulb] in (bulb[.hue]?.value.doubleValue ?? 0, bulb[.saturation]?.value.doubleValue ?? 0) })
            let lightWriter = LightChangeBatcher { changes in
                for (attributes, transition) in commands.commands(for: changes) { try await client.patch(deviceID: deviceID, attributes: attributes, transitionMs: transition) }
            }
            bulb.characteristic(.on).onWrite { value in
                do { try await lightWriter.set(.on(value.boolValue ?? false)) } catch { throw fail(error) }
            }
            bulb[.brightness]?.onWrite { value in
                do { try await lightWriter.set(.brightness(Double(max(1, value.intValue ?? 100)))) } catch { throw fail(error) }
            }
            bulb[.hue]?.onWrite { value in
                do { try await lightWriter.set(.hue(value.doubleValue ?? 0)) } catch { throw fail(error) }
            }
            bulb[.saturation]?.onWrite { value in
                do { try await lightWriter.set(.saturation(value.doubleValue ?? 0)) } catch { throw fail(error) }
            }
            bulb[.colorTemperature]?.onWrite { value in
                do { try await lightWriter.set(.mirek(value.intValue ?? 300)) } catch { throw fail(error) }
            }
            service = bulb
            writer = lightWriter
        }
        let accessory = Accessory(
            id: Self.accessoryID(deviceID: device.id), name: device.name, manufacturer: device.manufacturer, model: device.model,
            serialNumber: device.serial, firmwareRevision: device.firmware.isEmpty ? "1.0.0" : device.firmware,
            category: device.kind == .outlet ? .outlet : device.kind == .contact ? .sensor : .lightbulb, services: [service] + (battery.map { [$0] } ?? []),
            onIdentify: { try? await client.identify(deviceID: deviceID) })
        let built = DeviceServices(accessory: accessory, service: service, battery: battery, writer: writer, shape: shape)
        Self.showValues(device, on: built)
        accessory.isUnavailable = !device.reachable
        if let room = device.room { accessory.suggestedRoom = room }
        try context.add(accessory)
        accessories[device.id] = built
    }

    private func showScenes(_ hub: Hub) {
        let scenes = visibleScenes(hub)
        let shape = scenes.map { "\($0.id)=\($0.name)" }.joined(separator: "|")
        guard !scenes.isEmpty else { sceneAccessories[hub.host] = nil; return }
        if sceneAccessories[hub.host]?.shape == shape { return }
        let client = hub.client
        var switches: [String: Service] = [:]
        var services: [Service] = []
        for (index, scene) in scenes.enumerated() {
            let service = Service(.switch, name: scene.name, subtype: "scene:\(scene.id)", optional: [.configuredName], isPrimary: index == 0)
            service[.configuredName]?.value = .string(scene.name)
            let sceneID = scene.id
            service.characteristic(.on).onWrite { [weak self, service] value in
                do {
                    if value.boolValue == true {
                        try await client.trigger(sceneID: sceneID)
                        await self?.triggered(sceneID)
                        Task {
                            try? await Task.sleep(for: Self.sceneSwitchReset)
                            service.characteristic(.on).value = .bool(false)
                        }
                    } else if await self?.canUndo(sceneID) == true {
                        try await client.undo(sceneID: sceneID)
                    }
                } catch {
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            }
            switches[scene.id] = service
            services.append(service)
        }
        let name = configuration.hubs?.first { $0.host == hub.host }?.name?.nonEmpty.map { "\($0) Scenes" } ?? "IKEA Scenes"
        let accessory = Accessory(
            id: Self.sceneAccessoryID(host: hub.host), name: name, manufacturer: "IKEA of Sweden", model: "DIRIGERA scenes",
            serialNumber: hub.host, category: .switch, services: services)
        do {
            try context.add(accessory)
            sceneAccessories[hub.host] = SceneServices(accessory: accessory, switches: switches, shape: shape)
        } catch {
            logger.error("Could not add the DIRIGERA scenes: \(error)")
        }
    }

    private func triggered(_ sceneID: String) { lastTriggered[sceneID] = .now }

    private func canUndo(_ sceneID: String) -> Bool {
        guard let at = lastTriggered[sceneID] else { return false }
        return ContinuousClock.now - at < Self.undoWindow
    }

    // MARK: For the page

    /// Pairs with the hub at `host`: a code, then the token once its action button is pressed.
    func pair(host: String) async throws {
        let hub = open(host)
        guard !hub.pairing else { return }
        hub.pairing = true
        defer { hub.pairing = false; hub.pairingDeadline = nil }
        let verifier = DirigeraClient.makeVerifier()
        let code = try await hub.client.authorize(verifier: verifier)
        let deadline = ContinuousClock.now + Self.pairingWindow
        hub.pairingDeadline = deadline
        let name = "homeswift-\(ProcessInfo.processInfo.hostName.prefix(20))"
        while ContinuousClock.now < deadline {
            do {
                let token = try await hub.client.token(code: code, verifier: verifier, name: name)
                stored[host, default: StoredHub()].token = token
                save()
                hub.error = nil
                logger.info("Paired with the DIRIGERA hub at \(host)")
                tasks.add { [weak self] in await self?.run(hub) }
                return
            } catch DirigeraClient.Failure.buttonNotPressed {
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw DirigeraClient.Failure.buttonNotPressed
    }

    func unpair(host: String) async {
        stored[host]?.token = nil
        save()
        await hubs[host]?.client.setToken(nil)
    }

    func discover() async -> [String] { await dependencies.discover() }

    func hubStatus(_ host: String) async -> (paired: Bool, connected: Bool, pairing: Bool, pairingSecondsLeft: Int?, error: String?, devices: Int, scenes: Int) {
        let hub = hubs[host]
        let paired = await hub?.client.token != nil
        let secondsLeft = hub?.pairingDeadline.map { deadline in
            let left = (deadline - ContinuousClock.now).components
            return max(0, Int(left.seconds) + (left.attoseconds > 0 ? 1 : 0))
        }
        return (paired, hub?.connected ?? false, hub?.pairing ?? false, secondsLeft, hub?.error, hub?.devices.count ?? 0, hub?.scenes.count ?? 0)
    }

    /// Runs one of the hub's scenes: only an id the hub listed, as the page's and the Assistant's ids come from outside.
    func trigger(host: String, sceneID: String) async throws {
        guard let hub = hubs[host] else { throw DirigeraClient.Failure.status(404, "no such hub") }
        guard hub.scenes.contains(where: { $0.id == sceneID }) else { throw DirigeraClient.Failure.status(404, "no such scene") }
        try await hub.client.trigger(sceneID: sceneID)
        triggered(sceneID)
    }

    func identify(host: String, deviceID: String) async throws {
        guard let hub = hubs[host] else { throw DirigeraClient.Failure.status(404, "no such hub") }
        guard hub.devices[deviceID] != nil else { throw DirigeraClient.Failure.status(404, "no such device") }
        try await hub.client.identify(deviceID: deviceID)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
