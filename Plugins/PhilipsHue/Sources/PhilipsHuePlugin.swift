import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Philips Hue lights, scenes and effects through a Hue Bridge's local API v2 (CLIP v2), without the cloud.
///
/// Each light is an accessory: its lightbulb, a switch for each effect it plays (candle, fire…), optionally a
/// Flash switch (Hue's signaling) and, on gradient lights, a lightbulb for each colour point. Each room and zone
/// with scenes is an accessory with a switch per scene: On recalls it, it shows on while the scene is active, and
/// Off switches the room off. A light's changes of one moment go in one command with the transition of
/// `transitionMs`, so moods and the Home app change colour and brightness together, as fast as the bridge allows.
///
/// The first start pairs with the bridge: the plugin's page, or the log, asks for the link button, and the
/// application key is kept in the plugin's directory (`bridge.json`), never in config.json. Changes made elsewhere (the
/// Hue app, a dimmer switch) are read every `pollingInterval` seconds in one request. See README.md in this directory.
public actor PhilipsHuePlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// The bridge's address; found on the network when unset.
        public var host: String?
        /// Milliseconds a light takes to reach a new value; 100 by default.
        public var transitionMs: Int?
        /// Seconds between polls; 1 at least, 2 by default.
        public var pollingInterval: Int?
        public var scenes: Bool?
        /// A lightbulb per room and zone, its lights' on and brightness as one command; off by default.
        public var roomLights: Bool?
        public var excludeScenes: [String]?
        public var dynamicScenes: Bool?
        public var effects: Bool?
        public var flashSwitch: Bool?
        public var gradientPoints: Bool?
        public var excludeLights: [String]?
    }

    /// What the plugin keeps of its bridge in `bridge.json`.
    struct StoredBridge: Codable, Sendable, Equatable {
        var host: String?
        var bridgeID: String?
        var applicationKey: String?
        /// The SHA-256 fingerprint of the bridge's certificate, pinned on first use.
        var fingerprint: String?
    }

    /// What the plugin uses to reach the bridge; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: @Sendable (HTTPClient.TrustOnFirstUse) -> any HTTPSending = { PinningTransport(trust: $0) }
        /// Bridges on the network: addresses from mDNS (`_hue._tcp`), else Philips' discovery service.
        var discover: @Sendable () async -> [String] = HueDiscovery.find
    }

    public static let platform = "PhilipsHue"
    public static let name = "Philips Hue"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingInterval = 2
    static let defaultTransition = 100
    /// How long a poll leaves alone a light just written: the bridge may still report the old values.
    static let settleTime = Duration.seconds(2)
    /// How long pairing waits for the link button.
    static let pairingWindow = Duration.seconds(60)
    static let flashDuration = 5000

    let configuration: Configuration
    /// `excludeLights` and `excludeScenes`, lowercased once: every poll checks each light and scene against them.
    private let excludedLights: Set<String>
    private let excludedScenes: Set<String>
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var logger: Logger { context.logger }
    private let store: JSONFile<StoredBridge>
    /// The pictures people gave scenes on the page, by scene id.
    let pictures: PluginPictures
    private var stored: StoredBridge
    private let trust: HTTPClient.TrustOnFirstUse
    private(set) var client: HueClient?
    private(set) var snapshot = HueSnapshot()
    private(set) var lastError: String?
    private var pairing: Task<Bool, Never>?
    private var pairingDeadline: ContinuousClock.Instant?
    /// The task that finds the bridge and polls it.
    private var poller: Task<Void, Never>?
    /// The bridge moved to another address: its key is sent there only once `/api/config` names the same bridge.
    private var checkBridge = false
    /// Counts reads of the bridge: a read that finishes after a later one began (the poll's, overtaken by the one after
    /// a recall) is not applied, so the older state never comes back.
    private var refreshes = 0
    private var lights: [String: LightServices] = [:]
    private var sceneAccessories: [String: SceneServices] = [:]

    /// A light's services on its accessory.
    struct LightServices {
        let accessory: Accessory
        let lightbulb: Service
        let writer: LightChangeBatcher
        let command: HueLightCommand
        var effects: [String: Service]
        let flash: Service?
        let points: [Service]
        /// The shape it was built for: a light that changes shape is rebuilt.
        let shape: String
    }

    /// A room's or zone's accessory: a switch per scene and, with `roomLights`, a lightbulb for its lights together.
    struct SceneServices {
        let accessory: Accessory
        var switches: [String: Service]
        let room: Service?
        let roomWriter: LightChangeBatcher?
        let shape: String
    }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        excludedLights = Set((configuration.excludeLights ?? []).map { $0.lowercased() })
        excludedScenes = Set((configuration.excludeScenes ?? []).map { $0.lowercased() })
        self.context = context
        self.dependencies = dependencies
        store = context.jsonFile("bridge.json")
        pictures = context.pictures("scene-pictures")
        let stored = store.load() ?? StoredBridge()
        self.stored = stored
        let store = store
        trust = HTTPClient.TrustOnFirstUse(pinned: stored.fingerprint) { fingerprint in
            var updated = store.load() ?? StoredBridge()
            updated.fingerprint = fingerprint
            try? store.save(updated)
        }
    }

    var transitionMs: Int { min(max(configuration.transitionMs ?? Self.defaultTransition, 0), 10000) }
    var pollingInterval: Duration { .seconds(max(configuration.pollingInterval ?? Self.defaultPollingInterval, 1)) }

    static func accessoryID(lightID: String) -> String { "\(platform):\(lightID)" }
    static func sceneAccessoryID(groupID: String) -> String { "\(platform):scenes:\(groupID)" }

    public func start() async throws {
        restart()
    }

    /// Starts the poll again (another address, a new key). The bag keeps it so `stop` cancels it; the bag itself is not
    /// cancelled here, as a cancelled bag starts nothing again.
    private func restart() {
        poller?.cancel()
        let task = Task<Void, Never> { [weak self] in await self?.run() }
        poller = task
        tasks.add(task)
    }

    public func stop() async {
        pairing?.cancel()
        poller?.cancel()
        tasks.cancelAll()
    }

    /// Finds the bridge, pairs when there is no key, then polls.
    private func run() async {
        guard let host = await bridgeHost() else {
            lastError = "No Hue Bridge found on the network: set its address on the plugin's page."
            logger.warning("No Hue Bridge found on the network; set host in the PhilipsHue block or on the plugin's page")
            return
        }
        connect(host: host)
        if stored.applicationKey == nil {
            logger.info("Press the link button on the Hue Bridge at \(host) to pair (the plugin waits a minute; its page can pair again)")
            guard await pair() else { return }
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: pollingInterval)
        }
    }

    private func bridgeHost() async -> String? {
        if let host = configuration.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty { return host }
        if let host = stored.host { return host }
        return await dependencies.discover().first
    }

    private func connect(host: String) {
        if stored.host != host, stored.host != nil {
            // Another bridge, or the same one at a new address: the certificate is checked again on first use.
            if configuration.host != nil { trust.reset() }
            if stored.applicationKey != nil { checkBridge = true }
        }
        stored.host = host
        save()
        client = HueClient(host: host, applicationKey: checkBridge ? nil : stored.applicationKey, transport: dependencies.transport(trust))
    }

    /// At a new address, the key goes only to the bridge it belongs to: another one (or anything else answering there,
    /// its certificate trusted on first use) loses it, and the plugin pairs again from the page.
    private func checkMovedBridge(_ client: HueClient) async -> Bool {
        guard checkBridge else { return true }
        let answered: String?
        do {
            answered = try await client.configuration()["bridgeid"]?.stringValue
        } catch {
            lastError = "\(error)"
            return false
        }
        checkBridge = false
        if let answered, let known = stored.bridgeID, answered.lowercased() == known.lowercased() {
            await client.setApplicationKey(stored.applicationKey)
            return true
        }
        logger.warning("Another Hue Bridge answers at \(client.host): pair with it from the plugin's page")
        lastError = "Another Hue Bridge answers at \(client.host): pair with it from the plugin's page."
        stored.applicationKey = nil
        save()
        return false
    }

    private func save() {
        do { try store.save(stored) } catch { logger.warning("Could not save bridge.json: \(error)") }
    }

    // MARK: Pairing

    /// Asks the bridge for a key every two seconds until its link button is pressed or `pairingWindow` passes.
    @discardableResult
    func pair() async -> Bool {
        if let pairing { return await pairing.value }
        let task = Task { await self.pairLoop() }
        pairing = task
        let paired = await task.value
        pairing = nil
        return paired
    }

    private func pairLoop() async -> Bool {
        guard let client else { return false }
        let deadline = ContinuousClock.now + Self.pairingWindow
        pairingDeadline = deadline
        defer { pairingDeadline = nil }
        while ContinuousClock.now < deadline, !Task.isCancelled {
            do {
                let key = try await client.pair(deviceType: "homeswift#\(ProcessInfo.processInfo.hostName.prefix(19))")
                stored.applicationKey = key
                if let configuration = try? await client.configuration() { stored.bridgeID = configuration["bridgeid"]?.stringValue }
                save()
                lastError = nil
                logger.info("Paired with the Hue Bridge at \(client.host)")
                return true
            } catch HueClient.Failure.linkButtonNotPressed {
                lastError = "Press the link button on the Hue Bridge."
            } catch {
                lastError = "\(error)"
                logger.debug("Pairing: \(error)")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if stored.applicationKey == nil {
            lastError = "The link button was not pressed in time: pair again from the plugin's page."
            logger.warning("The Hue Bridge's link button was not pressed in time; pair again from the plugin's page")
        }
        return stored.applicationKey != nil
    }

    // MARK: Polling

    /// Reads every resource in one request, adds the lights and scenes that are new, shows the values of the others
    /// and drops what is gone.
    func refresh() async {
        guard let client, stored.applicationKey != nil, await checkMovedBridge(client) else { return }
        refreshes += 1
        let read = refreshes
        let resources: [JSONValue]
        do {
            resources = try await client.resources()
            guard read == refreshes else { return }
        } catch HueClient.Failure.unauthorized {
            lastError = "The Hue Bridge refused the application key: pair again from the plugin's page."
            logger.warning("The Hue Bridge refused the application key; pair again from the plugin's page")
            stored.applicationKey = nil
            await client.setApplicationKey(nil)
            save()
            for services in lights.values { services.accessory.isUnavailable = true }
            return
        } catch {
            guard read == refreshes else { return }
            if lastError == nil { logger.warning("Could not reach the Hue Bridge: \(error)") }
            lastError = "\(error)"
            for services in lights.values { services.accessory.isUnavailable = true }
            return
        }
        if lastError != nil { logger.info("The Hue Bridge answers again") }
        lastError = nil
        let snapshot = HueSnapshot(resources: resources)
        self.snapshot = snapshot
        if let bridgeID = snapshot.bridgeID, stored.bridgeID != bridgeID {
            stored.bridgeID = bridgeID
            save()
        }
        var keep: Set<String> = []
        for light in snapshot.lights where !isExcluded(light) {
            keep.insert(Self.accessoryID(lightID: light.id))
            await show(light)
        }
        // A room or zone has an accessory for its scenes, its lights together (`roomLights`), or both.
        for group in snapshot.groups {
            let scenes = configuration.scenes ?? true ? visibleScenes(of: group) : []
            let roomLight = configuration.roomLights == true && group.groupedLightID != nil
            guard !scenes.isEmpty || roomLight else { continue }
            keep.insert(Self.sceneAccessoryID(groupID: group.id))
            await showRoom(group, scenes, roomLight: roomLight)
        }
        lights = lights.filter { keep.contains(Self.accessoryID(lightID: $0.key)) }
        sceneAccessories = sceneAccessories.filter { keep.contains(Self.sceneAccessoryID(groupID: $0.key)) }
        _ = await context.removeAccessories(keeping: keep, message: "Removing a Hue light or scene the bridge no longer has")
    }

    func isExcluded(_ light: HueLight) -> Bool {
        excludedLights.contains(light.name.lowercased()) || excludedLights.contains(light.id.lowercased())
    }

    func visibleScenes(of group: HueGroup) -> [HueScene] {
        let excluded = excludedScenes
        return snapshot.scenes.filter { scene in
            scene.groupID == group.id && !excluded.contains(scene.name.lowercased()) && !excluded.contains("\(group.name)/\(scene.name)".lowercased())
                && !excluded.contains(scene.id.lowercased())
        }
    }

    // MARK: Lights

    private func shape(of light: HueLight) -> String {
        var parts = [light.dims ? "d" : "", light.hasColour ? "c" : "", light.mirekRange.map { "t\($0.lowerBound)-\($0.upperBound)" } ?? ""]
        if configuration.effects ?? true { parts.append("e" + light.effects.joined(separator: ",")) }
        if configuration.flashSwitch == true, light.canFlash { parts.append("f") }
        if configuration.gradientPoints == true, light.gradientCapacity > 1 { parts.append("g\(light.gradientCapacity)") }
        return parts.joined(separator: "|")
    }

    private func show(_ light: HueLight) async {
        let shape = shape(of: light)
        if let services = lights[light.id], services.shape == shape {
            services.accessory.isUnavailable = !light.reachable
            if let sent = await services.writer.lastSent, ContinuousClock.now - sent < Self.settleTime { return }
            Self.showValues(light, on: services, keeping: services.command.lastColour)
            return
        }
        do {
            try add(light, shape: shape)
        } catch {
            logger.error("Could not add \(light.name): \(error)")
        }
    }

    /// Sets each characteristic from the light; HomeKit hears of the values that changed.
    static func showValues(_ light: HueLight, on services: LightServices, keeping sent: (xy: HueXY, hue: Double, saturation: Double)? = nil) {
        let bulb = services.lightbulb
        bulb.characteristic(.on).value = .bool(light.on)
        if let brightness = light.brightness { bulb[.brightness]?.value = .int(Int(brightness.rounded())) }
        if let point = light.xy, bulb[.hue] != nil {
            var colour = HueColor.hueSaturation(point, gamut: light.gamut ?? .c)
            if let sent, HueColor.distance(sent.xy, point) < 0.003 { colour = (sent.hue, sent.saturation) }
            bulb[.hue]?.value = .double(colour.hue.rounded())
            bulb[.saturation]?.value = .double(colour.saturation.rounded())
        }
        if let mirek = light.mirek, let characteristic = bulb[.colorTemperature] {
            characteristic.value = .int(Self.clampMirek(mirek, characteristic))
        }
        for (name, service) in services.effects { service.characteristic(.on).value = .bool(light.effect == name) }
        for (index, service) in services.points.enumerated() {
            service.characteristic(.on).value = .bool(light.on)
            if index < light.gradientPoints.count {
                let colour = HueColor.hueSaturation(light.gradientPoints[index], gamut: light.gamut ?? .c)
                service[.hue]?.value = .double(colour.hue.rounded())
                service[.saturation]?.value = .double(colour.saturation.rounded())
            }
        }
    }

    static func clampMirek(_ mirek: Int, _ characteristic: Characteristic) -> Int {
        let low = Int(characteristic.type.minValue ?? 140), high = Int(characteristic.type.maxValue ?? 500)
        return min(max(mirek, low), high)
    }

    private func add(_ light: HueLight, shape: String) throws {
        guard let client else { return }
        var optional: [CharacteristicType] = []
        if light.dims { optional.append(.brightness) }
        if light.hasColour { optional += [.hue, .saturation] }
        if let range = light.mirekRange {
            optional.append(.colorTemperature.with(minValue: Double(max(140, range.lowerBound)), maxValue: Double(min(500, range.upperBound))))
        }
        let lightbulb = Service(.lightbulb, name: light.name, optional: optional, isPrimary: true)
        let lightID = light.id
        let gamut = light.gamut ?? .c
        let command = HueLightCommand(
            lightID: lightID, gamut: gamut, transitionMs: transitionMs,
            currentColour: { [lightbulb] in (lightbulb[.hue]?.value.doubleValue ?? 0, lightbulb[.saturation]?.value.doubleValue ?? 0) })
        let writer = LightChangeBatcher { changes in try await client.put("light", id: lightID, command.body(for: changes)) }
        let fail: @Sendable (any Error) -> HAPStatusError = { _ in HAPStatusError(.serviceCommunicationFailure) }
        lightbulb.characteristic(.on).onWrite { value in
            do { try await writer.set(.on(value.boolValue ?? false)) } catch { throw fail(error) }
        }
        lightbulb[.brightness]?.onWrite { value in
            do { try await writer.set(.brightness(max(1, value.doubleValue ?? 100))) } catch { throw fail(error) }
        }
        lightbulb[.hue]?.onWrite { value in
            do { try await writer.set(.hue(value.doubleValue ?? 0)) } catch { throw fail(error) }
        }
        lightbulb[.saturation]?.onWrite { value in
            do { try await writer.set(.saturation(value.doubleValue ?? 0)) } catch { throw fail(error) }
        }
        lightbulb[.colorTemperature]?.onWrite { value in
            do { try await writer.set(.mirek(value.intValue ?? 300)) } catch { throw fail(error) }
        }

        var services = [lightbulb]
        var effects: [String: Service] = [:]
        if configuration.effects ?? true {
            for effect in light.effects {
                let service = Self.switchService(Self.effectName(effect), subtype: "effect:\(effect)")
                let v2 = light.effectsV2
                service.characteristic(.on).onWrite { value in
                    let name = value.boolValue == true ? effect : "no_effect"
                    let body: JSONValue = v2 ? ["effects_v2": ["action": ["effect": .string(name)]]] : ["effects": ["effect": .string(name)]]
                    do { try await client.put("light", id: lightID, body) } catch { throw fail(error) }
                }
                effects[effect] = service
                services.append(service)
            }
        }
        var flash: Service?
        if configuration.flashSwitch == true, light.canFlash {
            let service = Self.switchService("Flash", subtype: "flash")
            let signal = light.signals.contains("on_off") ? "on_off" : "on_off_color"
            service.characteristic(.on).onWrite { [service] value in
                let on = value.boolValue == true
                let body: JSONValue = on
                    ? ["signaling": ["signal": .string(signal), "duration": .number(Double(Self.flashDuration))]]
                    : ["signaling": ["signal": "no_signal"]]
                do { try await client.put("light", id: lightID, body) } catch { throw fail(error) }
                if on {
                    Task {
                        try? await Task.sleep(for: .milliseconds(Self.flashDuration))
                        service.characteristic(.on).value = .bool(false)
                    }
                }
            }
            flash = service
            services.append(service)
        }
        var points: [Service] = []
        if configuration.gradientPoints == true, light.gradientCapacity > 1 {
            let count = min(light.gradientCapacity, 5)
            for index in 0..<count {
                let point = Service(.lightbulb, name: "\(light.name) \(index + 1)", subtype: "point:\(index)", optional: [.hue, .saturation])
                points.append(point)
            }
            for (index, point) in points.enumerated() {
                point.characteristic(.on).onWrite { value in
                    do { try await writer.set(.on(value.boolValue ?? false)) } catch { throw fail(error) }
                }
                let write: @Sendable (Double?, Double?) async throws -> Void = { [points] hue, saturation in
                    let body = Self.gradientBody(points: points, changing: index, hue: hue, saturation: saturation, gamut: gamut)
                    do { try await client.put("light", id: lightID, body) } catch { throw fail(error) }
                }
                point[.hue]?.onWrite { value in try await write(value.doubleValue, nil) }
                point[.saturation]?.onWrite { value in try await write(nil, value.doubleValue) }
            }
            services += points
        }
        lightbulb.linked = Array(services.dropFirst())

        let accessory = Accessory(
            id: Self.accessoryID(lightID: light.id), name: light.name, manufacturer: light.manufacturer, model: light.model,
            serialNumber: light.id, firmwareRevision: light.firmware.isEmpty ? "1.0.0" : light.firmware, category: .lightbulb, services: services,
            // Identify is the device's, not the light service's (`PUT /resource/device/<id>`).
            onIdentify: { [deviceID = light.deviceID] in _ = try? await client.put("device", id: deviceID, ["identify": ["action": "identify"]]) })
        let built = LightServices(accessory: accessory, lightbulb: lightbulb, writer: writer, command: command, effects: effects, flash: flash, points: points, shape: shape)
        Self.showValues(light, on: built)
        accessory.isUnavailable = !light.reachable
        try context.add(accessory)
        lights[light.id] = built
    }

    /// Every point of a gradient, with one changed: the bridge takes the whole list.
    static func gradientBody(points: [Service], changing index: Int, hue: Double?, saturation: Double?, gamut: HueGamut) -> JSONValue {
        let list: [JSONValue] = points.enumerated().map { position, service in
            var h = service[.hue]?.value.doubleValue ?? 0, s = service[.saturation]?.value.doubleValue ?? 0
            if position == index { h = hue ?? h; s = saturation ?? s }
            let point = HueColor.xy(hue: h, saturation: s, gamut: gamut)
            return ["color": ["xy": ["x": .number(HueLightCommand.round(point.x)), "y": .number(HueLightCommand.round(point.y))]]]
        }
        return ["gradient": ["points": .array(list)]]
    }

    static func switchService(_ name: String, subtype: String, isPrimary: Bool = false) -> Service {
        let service = Service(.switch, name: name, subtype: subtype, optional: [.configuredName], isPrimary: isPrimary)
        service[.configuredName]?.value = .string(name)
        return service
    }

    /// `candle` as Candle, `glisten` as Glisten.
    static func effectName(_ effect: String) -> String {
        effect.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Scenes

    private func showRoom(_ group: HueGroup, _ scenes: [HueScene], roomLight: Bool) async {
        let shape = (roomLight ? "room|" : "") + scenes.map { "\($0.id)=\($0.name)" }.joined(separator: "|")
        if let services = sceneAccessories[group.id], services.shape == shape {
            for scene in scenes { services.switches[scene.id]?.characteristic(.on).value = .bool(scene.active) }
            if let room = services.room, let writer = services.roomWriter { await Self.showRoomValues(group, on: room, writer: writer) }
            return
        }
        guard let client else { return }
        let dynamic = configuration.dynamicScenes == true
        let transition = transitionMs
        var switches: [String: Service] = [:]
        var services: [Service] = []
        // The room's lights as one lightbulb, the grouped_light the Hue app's room controls write: one command for all.
        var room: Service?
        var roomWriter: LightChangeBatcher?
        if roomLight, let groupedLight = group.groupedLightID {
            let bulb = Service(.lightbulb, name: group.name, subtype: "room", optional: [.brightness], isPrimary: true)
            let command = HueLightCommand(lightID: groupedLight, gamut: .c, transitionMs: transition, currentColour: { (0, 0) })
            let writer = LightChangeBatcher { changes in try await client.put("grouped_light", id: groupedLight, command.body(for: changes)) }
            bulb.characteristic(.on).onWrite { value in
                do { try await writer.set(.on(value.boolValue ?? false)) } catch { throw HAPStatusError(.serviceCommunicationFailure) }
            }
            bulb[.brightness]?.onWrite { value in
                do { try await writer.set(.brightness(max(1, value.doubleValue ?? 100))) } catch { throw HAPStatusError(.serviceCommunicationFailure) }
            }
            await Self.showRoomValues(group, on: bulb, writer: writer)
            services.append(bulb)
            (room, roomWriter) = (bulb, writer)
        }
        for (index, scene) in scenes.enumerated() {
            let service = Self.switchService(scene.name, subtype: "scene:\(scene.id)", isPrimary: room == nil && index == 0)
            let groupedLight = group.groupedLightID
            service.characteristic(.on).onWrite { value in
                do {
                    if value.boolValue == true {
                        try await client.put(scene.smart ? "smart_scene" : "scene", id: scene.id, Self.recallBody(scene, dynamic: dynamic, transitionMs: transition))
                    } else if scene.smart {
                        try await client.put("smart_scene", id: scene.id, ["recall": ["action": "deactivate"]])
                    } else if let groupedLight {
                        try await client.put("grouped_light", id: groupedLight, ["on": ["on": false]])
                    }
                } catch {
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            }
            service.characteristic(.on).value = .bool(scene.active)
            switches[scene.id] = service
            services.append(service)
        }
        let zone = group.kind == "zone"
        let accessory = Accessory(
            id: Self.sceneAccessoryID(groupID: group.id), name: room == nil ? "\(group.name) Scenes" : group.name, manufacturer: "Signify",
            model: room == nil ? (zone ? "Zone scenes" : "Room scenes") : (zone ? "Zone" : "Room"),
            serialNumber: group.id, category: room == nil ? .switch : .lightbulb, services: services)
        do {
            try context.add(accessory)
            sceneAccessories[group.id] = SceneServices(accessory: accessory, switches: switches, room: room, roomWriter: roomWriter, shape: shape)
        } catch {
            logger.error("Could not add the accessory of \(group.name): \(error)")
        }
    }

    /// The room's on and brightness as the bridge sums them up; left alone just after a command, as a light's are.
    static func showRoomValues(_ group: HueGroup, on bulb: Service, writer: LightChangeBatcher) async {
        if let sent = await writer.lastSent, ContinuousClock.now - sent < settleTime { return }
        bulb.characteristic(.on).value = .bool(group.on)
        // A room switched off may say 0: the brightness it comes back on at stays.
        if let brightness = group.brightness, brightness >= 1 { bulb[.brightness]?.value = .int(Int(brightness.rounded())) }
    }

    static func recallBody(_ scene: HueScene, dynamic: Bool, transitionMs: Int) -> JSONValue {
        if scene.smart { return ["recall": ["action": "activate"]] }
        return ["recall": ["action": .string(dynamic ? "dynamic_palette" : "active"), "duration": .number(Double(transitionMs))]]
    }

    /// Recalls a scene by id (the page's tiles).
    func recall(sceneID: String) async throws {
        guard let client, let scene = snapshot.scenes.first(where: { $0.id == sceneID }) else { throw HueClient.Failure.status(404, "no such scene") }
        try await client.put(scene.smart ? "smart_scene" : "scene", id: scene.id, Self.recallBody(scene, dynamic: configuration.dynamicScenes == true, transitionMs: transitionMs))
        await refresh()
    }

    // MARK: State for the page

    var storedBridge: StoredBridge { stored }
    var isPairing: Bool { pairing != nil }
    /// The seconds left to press the link button, whoever started the pairing (the page, or the plugin at start).
    var pairingSecondsLeft: Int? {
        guard let pairingDeadline else { return nil }
        let left = (pairingDeadline - ContinuousClock.now).components
        return max(0, Int(left.seconds) + (left.attoseconds > 0 ? 1 : 0))
    }

    /// Points the plugin at another bridge address (the page's), keeping the key when it is the same bridge.
    func use(host: String) async {
        poller?.cancel()
        if stored.host != host {
            trust.reset()
            if stored.applicationKey != nil { checkBridge = true }
        }
        stored.host = host
        save()
        restart()
    }

    func startPairing() async -> Bool {
        if client == nil, let host = await bridgeHost() { connect(host: host) }
        let paired = await pair()
        if paired {
            await client?.setApplicationKey(stored.applicationKey)
            restart()
        }
        return paired
    }

    func discover() async -> [String] { await dependencies.discover() }

    /// Makes a light blink: its device's identify.
    func identify(lightID: String) async throws {
        guard let client, let light = snapshot.lights.first(where: { $0.id == lightID }) else { throw HueClient.Failure.status(404, "no light with that id") }
        try await client.put("device", id: light.deviceID, ["identify": ["action": "identify"]])
    }

    func lightAction(id: String, _ body: JSONValue) async throws {
        guard let client else { throw HueClient.Failure.unauthorized }
        try await client.put("light", id: id, body)
        await refresh()
    }
}
