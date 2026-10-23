import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Which controller and which parent an accessory belongs to (`accessory-owners.json`): Homebridge kept this in
/// the accessory's context; here it is a file next to the pins, so a controller only removes its own accessories.
struct AccessoryOwner: Codable, Sendable, Equatable {
    /// The controller's MAC.
    var controller: String
    /// For an accessory split off a hub, the hub's accessory id.
    var childOf: String?
}

typealias AccessoryOwners = PersistedDictionary<AccessoryOwner>

extension PersistedDictionary where Value == AccessoryOwner {
    func ids(controller: String) -> [String] { values.filter { $0.value.controller == controller }.map(\.key).sorted() }
    func children(of parent: String) -> [String] { values.filter { $0.value.childOf == parent }.map(\.key).sorted() }
}

/// One UniFi Access controller (`AccessController` and `AccessEvents`): logs in, bootstraps every two minutes and
/// whenever the events connection comes back, keeps HomeKit in step with the controller's hubs and readers
/// (adding, updating, removing them after a delay), and routes realtime events to the hubs.
actor AccessController {
    struct Settings: Sendable, Equatable {
        var address: String
        var username: String
        var password: String
        var name: String?
        var mqttUrl: String?
        var mqttTopic: String
        var mqttVerifyTls: Bool
        var verifyTls: Bool
    }

    struct Shared: Sendable {
        var context: PluginContext
        var logger: Logger
        var options: FeatureOptions
        var ringDelay: Int
        var pins: TLSPinStore
        var owners: AccessoryOwners
        var dependencies: UniFiAccessPlugin.Dependencies
    }

    let settings: Settings
    private let shared: Shared
    private var logger: Logger { shared.logger }
    let api: AccessAPI
    private let isConfigValid: Bool
    private(set) var name: String
    private(set) var controllerInfo: AccessControllerInfo?
    private(set) var hubs: [String: AccessHub] = [:]
    /// The hubs by their device's `unique_id`, which events name.
    private var hubsByUniqueId: [String: AccessHub] = [:]
    private(set) var connected = false
    private var mqtt: AccessMQTT?
    private var removalQueue: [String: ContinuousClock.Instant] = [:]
    private var unsupported: Set<String> = []
    private var mqttPublishTelemetry = false
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    private var stopped = false
    /// Between login and bootstrap attempts, with up to 20% of jitter so controllers recovering from one outage
    /// do not retry in lockstep.
    private let retryInterval: Duration

    init(settings: Settings, shared: Shared) {
        self.settings = settings
        self.shared = shared
        name = settings.name ?? settings.address
        retryInterval = shared.dependencies.controllerRetryInterval * Double.random(in: 1...1.2)
        let logger = shared.logger
        let address = settings.address
        let pins = shared.pins
        let prefix = settings.name ?? settings.address
        let trust = HTTPClient.TrustOnFirstUse(pinned: settings.verifyTls ? nil : pins.pin(for: address)) { pins.set($0, for: address) }
        api = AccessAPI(
            logger: logger, http: shared.dependencies.http, events: shared.dependencies.events, verifyTLS: settings.verifyTls, trust: trust,
            mismatchHint:
                "\(prefix): If you have replaced or regenerated the certificate on your controller, remove the entry for \(address) from \(pins.url.path) and restart Homeswift to trust the new certificate.",
            timing: shared.dependencies.apiTiming)
        if AccessSettings.isValidAddress(settings.address) {
            isConfigValid = true
        } else {
            logger.error("\(prefix): Invalid controller address: \(settings.address). Please provide a valid network address.")
            isConfigValid = false
        }
    }

    /// The controller's id in feature options: its MAC without separators, once known.
    var id: String? { controllerInfo?.hostMAC.map(AccessSettings.normalizeMac) }

    /// The feature option, scoped to a device of this controller or to the controller.
    func hasFeature(_ option: String, device: AccessDevice? = nil) -> Bool {
        let deviceId = device.flatMap { $0.mac.isEmpty ? nil : $0.identifier }
        return shared.options.test(option, device: deviceId ?? id, controller: id)
    }

    // MARK: Lifecycle

    func start() {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.login()
        }
        tasks.append(task)
    }

    func stop() async {
        stopped = true
        for task in tasks { task.cancel() }
        tasks = []
        refreshTask?.cancel()
        refreshTask = nil
        await api.close()
        await mqtt?.end()
        mqtt = nil
        for hub in hubs.values { await hub.cleanup() }
    }

    /// Logs in and bootstraps, retrying until it works, then keeps the devices in step.
    private func login() async {
        guard isConfigValid else { return }
        guard hasFeature("Device") else {
            logger.info("\(name): Disabling this UniFi Access controller.")
            return
        }
        let retry = retryInterval
        while !Task.isCancelled, !stopped {
            if await api.login(address: settings.address, username: settings.username, password: settings.password) { break }
            try? await Task.sleep(for: retry)
        }
        while !Task.isCancelled, !stopped {
            if await api.getBootstrap() { break }
            try? await Task.sleep(for: retry)
        }
        guard !Task.isCancelled, !stopped else { return }

        controllerInfo = await api.controller
        let apiName = await api.name
        name = settings.name ?? apiName
        connected = true
        logger.info("\(name): Connected to \(settings.address) (UniFi Access \(controllerInfo?.version ?? "") running on UniFi OS \(controllerInfo?.hostFirmware ?? "")).")

        // Now that the controller's id is known: is it disabled?
        guard !stopped else { return }
        guard hasFeature("Device") else {
            await api.logout()
            logger.info("\(name): Disabling this UniFi Access controller in HomeKit.")
            if let mac = controllerInfo?.hostMAC {
                for accessoryId in shared.owners.ids(controller: mac) { await removeAccessory(accessoryId, immediately: true) }
            }
            return
        }

        mqttPublishTelemetry = hasFeature("Controller.Publish.Telemetry")
        if mqttPublishTelemetry { logger.info("\(name): Access controller telemetry enabled.") }
        if mqtt == nil, let url = settings.mqttUrl, !url.isEmpty {
            let client = AccessMQTT(
                brokerURL: url, topicPrefix: settings.mqttTopic, verifyTLS: settings.mqttVerifyTls, connector: shared.dependencies.mqtt, logger: logger, prefix: "\(name): ")
            await client.start()
            // Stopped while connecting: stop() saw no client to end.
            guard !stopped else { return await client.end() }
            mqtt = client
        }

        for device in await api.devices ?? [] where device.isManaged {
            logger.info("\(name): Discovered \(device.resolvedModel): \(AccessAPI.deviceName(device, name: device.resolvedName, deviceInfo: true)).")
        }

        // Follow the API: every bootstrap syncs the devices and restarts the refresh countdown; messages go to the hubs.
        guard !stopped else { return }
        let events = api.events
        tasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .bootstrap:
                    await self.sync()
                    await self.scheduleRefresh()
                case .message(let packet):
                    await self.dispatch(packet)
                }
            }
        })
        await sync()
        scheduleRefresh()
    }

    /// Bootstraps again after the refresh interval, retrying until it works (`bootstrapController`): a refresh
    /// that fails once, on a dropped connection, must not end the sync. A successful bootstrap reschedules.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard !stopped else { return }
        let interval = shared.dependencies.controllerRefreshInterval
        let retry = retryInterval
        let api = api
        let logger = logger
        let name = name
        refreshTask = Task {
            try? await Task.sleep(for: interval)
            var failures = 0
            while !Task.isCancelled {
                if await api.getBootstrap() { return }
                guard !Task.isCancelled else { return }
                // Once in the log; the API logs each failed request.
                if failures == 0 { logger.error("\(name): Unable to refresh the controller configuration. Retrying.") }
                failures += 1
                try? await Task.sleep(for: retry)
            }
        }
    }

    // MARK: Devices

    /// Adds new devices, updates the known ones, removes those that left (`discoverAndSyncAccessories`).
    func sync() async {
        guard !stopped, await api.bootstrap != nil else { return }
        let apiName = await api.name
        name = settings.name ?? apiName
        let devices = await api.devices ?? []
        for device in devices {
            guard !stopped else { return }
            await addDevice(device)
        }
        guard !stopped else { return }
        await cleanup(devices: devices)
        for hub in hubs.values {
            await hub.setControllerName(name)
            await hub.configureInfo()
        }
    }

    private func addDevice(_ device: AccessDevice) async {
        guard let controllerMAC = controllerInfo?.hostMAC, !controllerMAC.isEmpty, !device.mac.isEmpty, device.isManaged else { return }
        guard device.isSupported else {
            if unsupported.insert(device.mac).inserted {
                logger.info("\(name): UniFi Access device type '\(device.deviceType)' is not currently supported, ignoring: \(AccessAPI.deviceName(device)).")
            }
            return
        }
        let accessoryId = "\(UniFiAccessPlugin.platform):\(device.identifier.uppercased())"
        guard hasFeature("Device", device: device) else {
            if shared.context.accessory(id: accessoryId) != nil { await removeAccessory(accessoryId, immediately: true) }
            return
        }
        if let hub = hubs[accessoryId] {
            // A refresh: the device's state first, then the hub catches up on what it missed.
            let packet = AccessEventPacket(event: AccessEventType.deviceUpdate, eventObjectId: device.uniqueId, data: .object(device.json))
            await hub.updateDevice(device)
            await hub.handle(packet)
            return
        }
        if shared.context.accessory(id: accessoryId) == nil {
            logger.info("\(name) \(AccessAPI.deviceName(device)): Adding \(device.displayModel ?? device.deviceType) to HomeKit.")
        }
        shared.owners[accessoryId] = AccessoryOwner(controller: controllerMAC)
        let hub = AccessHub(device: device, controllerName: name, environment: hubEnvironment(for: accessoryId))
        hubs[accessoryId] = hub
        if hubsByUniqueId[device.uniqueId] == nil { hubsByUniqueId[device.uniqueId] = hub }
        await hub.configure()
    }

    private func hubEnvironment(for parent: String) -> AccessHub.Environment {
        let context = shared.context
        let owners = shared.owners
        let controllerMAC = controllerInfo?.hostMAC ?? ""
        let logger = logger
        return AccessHub.Environment(
            api: api, mqtt: mqtt, options: shared.options, controllerId: id, ringDelay: shared.ringDelay, logger: logger, timing: shared.dependencies.hubTiming,
            context: context,
            publish: { accessories in
                var published = Set<String>()
                for accessory in accessories {
                    if accessory.id != parent { owners[accessory.id] = AccessoryOwner(controller: controllerMAC, childOf: parent) }
                    do {
                        try context.add(accessory)
                        published.insert(accessory.id)
                    } catch {
                        logger.error("Could not add \(accessory.name) to HomeKit: \(error)")
                    }
                }
                // Children the hub no longer has: their services went back to the hub, or away.
                for child in owners.children(of: parent) where !published.contains(child) {
                    if let accessory = context.accessory(id: child) {
                        logger.info("\(accessory.name): Removing the separate accessory from HomeKit.")
                        try? await context.remove(id: child)
                    }
                    owners[child] = nil
                }
            })
    }

    /// Removes accessories of devices that are gone, after `Controller.DelayDeviceRemoval` (`cleanupDevices`).
    private func cleanup(devices: [AccessDevice]) async {
        guard let controllerMAC = controllerInfo?.hostMAC else { return }
        let present = Set(devices.map { $0.mac.lowercased() })
        let owned = shared.owners.ids(controller: controllerMAC)

        // Whether an accessory without a device is enabled, by the serial number it carries.
        func enabled(_ accessoryId: String) -> Bool {
            let serial = shared.context.accessory(id: accessoryId)?.information[.serialNumber]?.value.stringValue ?? ""
            return shared.options.test("Device", device: serial, controller: id)
        }

        for accessoryId in removalQueue.keys.sorted() where owned.contains(accessoryId) {
            await removeAccessory(accessoryId, immediately: !enabled(accessoryId))
        }
        for accessoryId in owned {
            if let parent = shared.owners[accessoryId]?.childOf {
                if hubs[parent] == nil {
                    if let accessory = shared.context.accessory(id: accessoryId) { logger.info("\(accessory.name): Removing the separate accessory from HomeKit.") }
                    try? await shared.context.remove(id: accessoryId)
                    shared.owners[accessoryId] = nil
                }
                continue
            }
            guard let hub = hubs[accessoryId] else {
                await removeAccessory(accessoryId, immediately: !enabled(accessoryId))
                continue
            }
            let device = await hub.uda
            if device.isSupported, present.contains(device.mac.lowercased()) {
                removalQueue[accessoryId] = nil
                continue
            }
            await removeAccessory(accessoryId, immediately: !(await hub.hasFeature("Device")))
        }
    }

    /// Removes a hub's accessories, after the removal delay unless `immediately`.
    private func removeAccessory(_ accessoryId: String, immediately: Bool) async {
        guard let owner = shared.owners[accessoryId], owner.controller == controllerInfo?.hostMAC else { return }
        if owner.childOf != nil {
            try? await shared.context.remove(id: accessoryId)
            shared.owners[accessoryId] = nil
            return
        }
        let delay = shared.options.integer("Controller.DelayDeviceRemoval", device: id, controller: id).value
            .flatMap { Int(saturating: $0, in: 0...AccessSettings.maximumOptionValue) } ?? 0
        let displayName = shared.context.accessory(id: accessoryId)?.name ?? accessoryId
        if !immediately, delay > 0 {
            guard let queued = removalQueue[accessoryId] else {
                removalQueue[accessoryId] = .now
                logger.info("\(displayName): Delaying device removal for at least \(delay) second\(delay > 1 ? "s" : "").")
                return
            }
            if ContinuousClock.now - queued < shared.dependencies.hubTiming.second * delay { return }
        }
        removalQueue[accessoryId] = nil
        let hub = hubs.removeValue(forKey: accessoryId)
        if let hub { hubsByUniqueId = hubsByUniqueId.filter { $0.value !== hub } }
        let device = await hub?.uda
        logger.info("\(device.map { AccessAPI.deviceName($0) } ?? displayName): Removing \(device?.displayModel ?? "device") from HomeKit.")
        await hub?.cleanup()
        for child in shared.owners.children(of: accessoryId) {
            if let accessory = shared.context.accessory(id: child) { logger.info("\(accessory.name): Removing the separate accessory from HomeKit.") }
            try? await shared.context.remove(id: child)
            shared.owners[child] = nil
        }
        if shared.context.accessory(id: accessoryId) != nil { try? await shared.context.remove(id: accessoryId) }
        shared.owners[accessoryId] = nil
    }

    // MARK: Events

    /// Routes one event (`AccessEvents`): device updates refresh the hub's device first, deletions remove it,
    /// and every hub the event concerns handles it. Telemetry goes to MQTT when enabled.
    func dispatch(_ packet: AccessEventPacket) async {
        if packet.event == AccessEventType.deviceUpdate, let hub = hubsByUniqueId[packet.eventObjectId], let device = AccessDevice(packet.data) {
            await hub.updateDevice(device)
        }
        if packet.event == AccessEventType.deviceDelete, let hub = hubsByUniqueId[packet.eventObjectId] {
            await removeAccessory(hub.id, immediately: false)
            return
        }
        for hub in hubs.values {
            if await hub.follows(packet) { await hub.handle(packet) }
        }
        if mqttPublishTelemetry, let mqtt, let id {
            await mqtt.publish(id, "telemetry", packet.telemetry)
        }
    }

    // MARK: The settings page

    /// What the page shows of this controller.
    func snapshot() async -> JSONValue {
        var devices: [JSONValue] = []
        for (accessoryId, hub) in hubs.sorted(by: { $0.key < $1.key }) {
            let device = await hub.uda
            var entry: [String: JSONValue] = [
                "id": .string(accessoryId), "name": .string(await hub.accessoryName), "model": .string(device.resolvedModel),
                "online": .bool(device.isFullyOnline), "featureId": .string(device.identifier),
            ]
            entry.merge(await hub.stateJSON()) { current, _ in current }
            devices.append(.object(entry))
        }
        return [
            "address": .string(settings.address), "name": .string(name), "connected": .bool(connected),
            "mac": controllerInfo?.hostMAC.map { .string($0) } ?? .null, "devices": .array(devices),
        ]
    }
}

extension AccessHub {
    func setControllerName(_ name: String) { controllerName = name }
}
