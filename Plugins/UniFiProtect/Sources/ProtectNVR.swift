import Foundation
import Homeswift
import HomeswiftPlugin

/// One UniFi Protect controller (`ProtectNvr`): logs in, keeps the bootstrap fresh, turns its devices into
/// accessories and keeps them in step with the realtime events, and removes the ones that disappear.
@ProtectActor
final class ProtectNVR {
    let platform: ProtectPlatform
    let config: UniFiProtectPlugin.Configuration.Controller
    let api: ProtectAPI
    private(set) var log: ProtectLog
    private(set) var events: ProtectEvents!
    /// The NVR's own JSON (`bootstrap.nvr`), kept up to date by the events.
    var ufp: JSONValue = .object([:])
    private(set) var mqtt: ProtectMQTTClient?
    private(set) var systemInfo: ProtectNvrSystemInfo?
    private(set) var liveviews: ProtectLiveviews?
    private(set) var playlist: ProtectPlaylistServer?

    /// The devices by accessory id, and by Protect id for the events.
    private(set) var configuredDevices: [String: ProtectDevice] = [:]
    private var devicesByID: [String: ProtectDevice] = [:]
    private var deviceRemovalQueue: [String: ContinuousClock.Instant] = [:]
    private var featureLog: Set<String> = []
    private var unsupportedDevices: Set<String> = []
    private var name: String
    private let tasks = TaskBag()
    private var isStopped: Bool { tasks.isStopped }

    nonisolated static let deviceCategories = ["camera", "chime", "light", "sensor", "viewer"]

    init(platform: ProtectPlatform, config: UniFiProtectPlugin.Configuration.Controller) {
        self.platform = platform
        self.config = config
        name = config.name ?? config.address
        log = platform.log.named(config.name ?? config.address)
        let pins = platform.tlsPins
        let address = config.address
        let nvrLog = platform.log.named(config.name ?? config.address)
        let pinOptions = ProtectTLSPin.Options(
            pinnedFingerprint: config.verifyTls == true ? nil : pins.get(address),
            onFingerprint: { pins.set(address, fingerprint: $0) },
            onFingerprintMismatch: { _, _ in
                nvrLog.error("If you have intentionally replaced or regenerated the certificate on this controller, remove the entry for \(address) from \(pins.url.path) and restart Homeswift to trust the new certificate.")
            })
        api = ProtectAPI(log: platform.log, options: ProtectAPI.Options(
            verifyTls: config.verifyTls == true, pin: pinOptions, transport: platform.dependencies.transport, webSockets: platform.dependencies.webSockets,
            timeScale: platform.dependencies.timeScale))
        events = ProtectEvents(nvr: self)
    }

    var featureOptions: FeatureOptions { platform.featureOptions }
    var timers: ProtectTimers { platform.timers }
    var host: any ProtectAccessoryHost { platform.host }
    var mac: String { ufp.string("mac") ?? "" }
    var bootstrap: JSONValue? { get async { await api.bootstrap } }

    /// The ids a controller-scoped feature option may be written with: the NVR's MAC (the Homebridge
    /// plugin's runtime) and the configured address (what its settings page writes).
    var controllerScopes: [String] {
        [mac, config.address].filter { !$0.isEmpty }
    }

    // MARK: Lifecycle

    /// Logs in, bootstraps and starts the device sync. Returns once the controller's devices are in HomeKit,
    /// or when it gave up.
    func login() async {
        guard hasFeature("Device") else {
            log.info("Disabling this UniFi Protect controller.")
            return
        }
        // Keep trying: the controller or the network may not be up yet.
        while !isStopped {
            if await api.login(address: config.address, username: config.username, password: config.password) { break }
            await timers.sleep(ProtectSettings.controllerRetryInterval * 1000)
        }
        guard !isStopped else { return }
        for _ in 0..<5 where await api.bootstrap == nil && !isStopped {
            await bootstrapNVR()
        }
        guard !isStopped else { return }
        guard let bootstrap = await api.bootstrap else {
            log.error("Unable to initialize. This may be due to the Protect controller rebooting or becoming unavailable.")
            return
        }
        ufp = bootstrap.at("nvr") ?? .object([:])
        let controllerName = await api.name
        guard !isStopped else { return }
        name = config.name ?? controllerName
        log = platform.log.named(name)
        let version = ufp.string("version") ?? "0"
        if (Int(version.prefix { $0.isNumber }) ?? 0) < 6 {
            log.error("This version of the UniFi Protect plugin requires running UniFi Protect v6.0 or above using the official Protect release channel only.")
            await api.logout()
            return
        }
        log.info("Connected to \(config.address) (UniFi Protect \(version) running on UniFi OS \(ufp.string("firmwareVersion") ?? "")).")

        guard hasFeature("Device") else {
            await api.logout()
            log.info("Disabling this UniFi Protect controller in HomeKit.")
            for id in host.accessoryIDs where platform.contexts[id].nvr == mac {
                await removeHomeKitDevice(id: id, noRemovalDelay: true)
            }
            return
        }

        liveviews = ProtectLiveviews(nvr: self)
        systemInfo = await ProtectNvrSystemInfo.make(nvr: self)
        // `stop()` may have run during any await of the start-up: nothing more starts, and what started
        // after it is undone (`abandonStartup`).
        guard !isStopped else { return await abandonStartup() }
        if mqtt == nil, let url = config.mqttUrl {
            mqtt = ProtectMQTTClient(brokerURL: url, topicPrefix: config.mqttTopic, log: log, verifyTLS: config.mqttVerifyTls != false, connect: platform.dependencies.mqtt)
        }
        if hasFeature("Nvr.Service.Playlist"), platform.dependencies.allowPlaylistServer {
            playlist = ProtectPlaylistServer(api: api, log: log, address: config.playlistAddress, port: getFeatureInt("Nvr.Service.Playlist", in: 0...65535),
                                             token: config.playlistToken)
            await playlist?.start()
        }
        guard !isStopped else { return await abandonStartup() }

        let devices = [ufp] + Self.deviceCategories.flatMap { bootstrap.array($0 + "s") }
        for device in devices {
            let config = ProtectDeviceConfig(device)
            if config.modelKey != "nvr", config.isAdoptedByOther || config.isAdopting || !config.isAdopted { continue }
            log.info("Discovered \(config.modelKey): \(ProtectAPI.deviceName(device, name: config.name ?? config.marketName, deviceInfo: true)).")
        }

        await syncUfpHomeKit()
        guard !isStopped else { return await abandonStartup() }
        let packets = api.packets
        tasks.add { @ProtectActor [weak self] in
            for await packet in packets {
                guard let self else { return }
                await self.events.handle(packet)
            }
        }
        tasks.add { @ProtectActor [weak self] in
            while let self, !self.isStopped {
                await self.timers.sleep(ProtectSettings.controllerRefreshInterval * 1000)
                guard !Task.isCancelled, !self.isStopped else { return }
                await self.bootstrapNVR()
                await self.syncUfpHomeKit()
            }
        }
    }

    /// Stops the streams, timers and connections of this controller. A start-up still running notices at its
    /// next step and undoes what it started after this.
    func stop() async {
        tasks.cancelAll()
        await shutDown()
    }

    /// The start-up went on while `stop()` ran: stop what it started since.
    private func abandonStartup() async {
        await shutDown()
    }

    private func shutDown() async {
        let devices = Array(configuredDevices.values)
        for device in devices { device.cleanup() }
        systemInfo?.cleanup()
        await playlist?.close()
        await mqtt?.end()
        await api.logout()
    }

    /// Fetches the bootstrap until it works, every ten seconds.
    private func bootstrapNVR() async {
        while !isStopped {
            if await api.getBootstrap() { return }
            await timers.sleep(ProtectSettings.controllerRetryInterval * 1000)
        }
    }

    /// The device sync, and the accessories published again when one changed shape.
    func syncUfpHomeKit() async {
        _ = await discoverAndSyncAccessories()
    }

    // MARK: Devices

    func devices(_ modelKey: String) -> [ProtectDevice] {
        configuredDevices.values.filter { $0.ufp.modelKey == modelKey }
    }

    var deviceList: [ProtectDevice] { Array(configuredDevices.values) }

    func getDevice(id: String) -> ProtectDevice? { devicesByID[id] }

    /// Adds a device of the bootstrap, or refreshes the one we have. False when it is not ours or not
    /// supported or disabled.
    @discardableResult
    func addHomeKitDevice(_ device: JSONValue) async -> Bool {
        let config = ProtectDeviceConfig(device)
        guard !mac.isEmpty, !config.mac.isEmpty, !config.isAdoptedByOther, config.isAdopted else { return false }
        guard Self.deviceCategories.contains(config.modelKey) else {
            if !unsupportedDevices.contains(config.mac) {
                unsupportedDevices.insert(config.mac)
                log.info("UniFi Protect device type \(config.modelKey) is not currently supported, ignoring: \(ProtectAPI.deviceName(device)).")
            }
            return false
        }
        let id = ProtectPlatform.accessoryID(config.mac)
        guard hasFeature("Device", device: config.mac) else {
            if host.accessoryIDs.contains(id) || configuredDevices[id] != nil { await removeHomeKitDevice(id: id, noRemovalDelay: true) }
            return false
        }
        if let existing = configuredDevices[id] {
            events.ufpUpdates(ProtectEventPacket(header: ["action": "update", "hbupBootstrap": true, "id": .string(config.id), "modelKey": .string(config.modelKey)], payload: device))
            _ = existing
            return true
        }
        let standalone = hasFeature("Device.Standalone", device: config.mac)
        if !host.accessoryIDs.contains(id) {
            log.info("\(ProtectAPI.deviceName(device)): Adding \(config.modelKey) to HomeKit\(standalone ? " as a standalone device" : "").")
        }
        guard let protectDevice = await makeDevice(device, id: id) else { return false }
        // Stopped while the device was set up: it goes nowhere, and starts nothing.
        guard !isStopped else {
            protectDevice.cleanup()
            return false
        }
        configuredDevices[id] = protectDevice
        devicesByID[config.id] = protectDevice
        await protectDevice.accessory.publish()
        guard !isStopped else { return false }
        if let doorbell = protectDevice as? ProtectDoorbell { await doorbell.packageCamera?.accessory.publish() }
        return true
    }

    private func makeDevice(_ device: JSONValue, id: String) async -> ProtectDevice? {
        let config = ProtectDeviceConfig(device)
        let accessory = ProtectAccessory(id: id, name: host.cachedName(id: id) ?? config.displayName, category: .other, host: host, log: log)
        accessory.isStandalone = hasFeature("Device.Standalone", device: config.mac)
        switch config.modelKey {
        case "camera":
            accessory.category = config.feature("isDoorbell") ? .videoDoorbell : .ipCamera
            return config.feature("isDoorbell") ? await ProtectDoorbell.makeDoorbell(nvr: self, device: device, accessory: accessory)
                : await ProtectCamera.make(nvr: self, device: device, accessory: accessory)
        case "chime":
            accessory.category = .switch
            return ProtectChime(nvr: self, device: device, accessory: accessory)
        case "light":
            accessory.category = .lightbulb
            return ProtectLight(nvr: self, device: device, accessory: accessory)
        case "sensor":
            accessory.category = .sensor
            return ProtectSensor(nvr: self, device: device, accessory: accessory)
        case "viewer":
            accessory.category = .switch
            return await ProtectViewer.make(nvr: self, device: device, accessory: accessory)
        default:
            log.error("Unknown device class \(config.modelKey) detected for \(config.name ?? config.marketName ?? "").")
            return nil
        }
    }

    /// Adds the controller's devices, removes those it no longer has, and refreshes the rest.
    private func discoverAndSyncAccessories() async -> Bool {
        guard let bootstrap = await api.bootstrap, !(await api.isThrottled) else {
            if !deviceRemovalQueue.isEmpty {
                log.info("Communication with the controller has been lost. Clearing out the device removal queue as a precaution until connectivity returns.")
                deviceRemovalQueue = [:]
            }
            return false
        }
        for category in Self.deviceCategories {
            for device in bootstrap.array(category + "s") where !isStopped { await addHomeKitDevice(device) }
        }
        guard !isStopped else { return false }
        await cleanupDevices(bootstrap: bootstrap)
        for chime in devices("chime") { await (chime as? ProtectChime)?.updateDevice() }
        await liveviews?.configureLiveviews()
        for viewer in devices("viewer") { _ = await (viewer as? ProtectViewer)?.updateDevice() }
        for device in deviceList where !isStopped {
            device.configureInfo()
            await device.accessory.publish()
            if let doorbell = device as? ProtectDoorbell { await doorbell.packageCamera?.accessory.publish() }
        }
        return true
    }

    /// Removes the accessories of devices the controller no longer has, the orphans of a restart, and
    /// moves devices between the bridge and their own server when `Device.Standalone` changed.
    private func cleanupDevices(bootstrap: JSONValue) async {
        for id in host.accessoryIDs where deviceRemovalQueue[id] != nil {
            let serial = platform.contexts[id].mac ?? ""
            await removeHomeKitDevice(id: id, noRemovalDelay: !featureOptions.test("Device", device: serial, controllers: controllerScopes))
        }
        for id in host.accessoryIDs where platform.contexts[id].nvr == mac {
            guard let device = configuredDevices[id] else {
                let serial = platform.contexts[id].mac ?? ""
                await removeHomeKitDevice(id: id, noRemovalDelay: !featureOptions.test("Device", device: serial))
                continue
            }
            let stillThere = bootstrap.array(device.ufp.modelKey + "s").contains { ProtectDeviceConfig($0).mac == device.ufp.mac }
            let external = host.isExternal(id: id)
            if stillThere, device.hints.enabled, external == device.hints.standalone {
                deviceRemovalQueue[id] = nil
                continue
            }
            if device.hints.enabled, external != device.hints.standalone {
                await removeHomeKitDevice(id: id, noRemovalDelay: true)
                await addHomeKitDevice(device.ufp.json)
                continue
            }
            await removeHomeKitDevice(id: id, noRemovalDelay: !hasFeature("Device", device: device.ufp.mac))
        }
    }

    /// Removes a device's accessory, after the `Nvr.DelayDeviceRemoval` delay unless `noRemovalDelay`, with
    /// its package camera.
    func removeHomeKitDevice(id: String, noRemovalDelay: Bool = false) async {
        let context = platform.contexts[id]
        guard host.accessoryIDs.contains(id) || configuredDevices[id] != nil else { return }
        guard context.nvr == mac else { return }
        if context.systemInfo == true || context.liveview != nil || id.hasSuffix(".Security") { return }
        if context.mac == nil {
            guard let parent = context.packageCamera, !host.accessoryIDs.contains(where: { platform.contexts[$0].mac == parent }) else { return }
        }
        let delay = getFeatureInt("Nvr.DelayDeviceRemoval", in: ProtectSettings.durationRange) ?? 0
        if !noRemovalDelay, delay > 0 {
            guard let queued = deviceRemovalQueue[id] else {
                deviceRemovalQueue[id] = ContinuousClock.now
                log.info("\(host.cachedName(id: id) ?? id): Delaying device removal for at least \(delay) second\(delay > 1 ? "s" : "").")
                return
            }
            if ContinuousClock.now - queued < timers.duration(milliseconds: delay * 1000) { return }
        }
        deviceRemovalQueue[id] = nil
        let device = configuredDevices[id]
        var ufpDevice = device?.ufp.json
        if ufpDevice == nil, let bootstrap = await api.bootstrap {
            ufpDevice = Self.deviceCategories.flatMap { bootstrap.array($0 + "s") }.first { ProtectDeviceConfig($0).mac == context.mac }
        }
        let external = host.isExternal(id: id)
        let label = ufpDevice.map { ProtectAPI.deviceName($0) } ?? device?.accessory.name ?? host.cachedName(id: id) ?? id
        log.info("\(label): Removing \(ufpDevice.map { ProtectDeviceConfig($0).modelKey } ?? "device") from HomeKit.\(external ? " You will need to manually delete the device in the Home app to complete the removal." : "")")
        var removing = [id]
        if ufpDevice == nil || ufpDevice.map({ ProtectDeviceConfig($0).modelKey }) == "camera" {
            if let packageID = host.accessoryIDs.first(where: { platform.contexts[$0].packageCamera == context.mac && context.mac != nil }) { removing.append(packageID) }
        }
        device?.cleanup()
        configuredDevices[id] = nil
        if let device, devicesByID[device.ufp.id] === device { devicesByID[device.ufp.id] = nil }
        for target in removing {
            if host.accessoryIDs.contains(target) {
                do { try await host.remove(id: target) } catch { log.warning("Could not remove \(target): \(error)") }
            }
            platform.contexts.remove(target)
        }
    }

    // MARK: Feature options

    func hasFeature(_ option: String, device: String? = nil) -> Bool {
        featureOptions.test(option, device: device, controllers: controllerScopes)
    }

    func getFeatureNumber(_ option: String) -> Double? {
        featureOptions.getInteger(option, device: nil, controllers: controllerScopes).orNil
    }

    /// An integer option, truncated and clamped to `range`.
    func getFeatureInt(_ option: String, in range: ClosedRange<Int>) -> Int? {
        getFeatureNumber(option).flatMap { Int(saturating: $0, in: range) }
    }

    func getFeatureFloat(_ option: String) -> Double? {
        featureOptions.getFloat(option, device: nil, controllers: controllerScopes).orNil
    }

    /// Whether the option is set for the controller or globally (`isNvrFeature`).
    func isNvrFeature(_ option: String, device: String? = nil) -> Bool {
        [.global, .controller].contains(featureOptions.scope(option, device: device, controllers: controllerScopes))
    }

    /// Logs a controller-wide option once.
    func logFeature(_ option: String, _ message: String) {
        let key = option.lowercased()
        guard !featureLog.contains(key), isNvrFeature(option) else { return }
        featureLog.insert(key)
        log.info(message)
    }

    // MARK: MQTT

    func publish(_ id: String, _ topic: String, _ message: String) {
        mqtt?.publish(id, topic, message)
    }
}
