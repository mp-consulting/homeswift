import Foundation
import Homeswift
import HomeswiftPlugin

/// A Protect doorbell (`ProtectDoorbell`): a camera with the doorbell service, its package camera, the
/// fingerprint/NFC authentication sensor, LCD messages and physical chimes.
@ProtectActor
final class ProtectDoorbell: ProtectCamera {
    private(set) var chimes: DoorbellChimes!
    private(set) var lcdMessages: DoorbellLcdMessages!
    var packageCamera: ProtectCameraPackage?

    static func makeDoorbell(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) async -> ProtectDoorbell {
        let doorbell = ProtectDoorbell(nvr: nvr, device: device, accessory: accessory)
        await doorbell.setUp()
        return doorbell
    }

    override func configureDevice() {
        chimes = DoorbellChimes(doorbell: self)
        lcdMessages = DoorbellLcdMessages(doorbell: self)
        packageCamera = nil
        guard ufp.feature("isDoorbell") else { return }
        super.configureDevice()
        configurePackageCamera()
        configureVideoDoorbell()
        configureAuthSensor()
        lcdMessages.configure()
        chimes.configure()
        subscribe("updateEvent." + (nvr.ufp.string("id") ?? "")) { [weak self] packet in self?.lcdMessages.nvrEventHandler(packet) }
        subscribe("updateEvent.chime") { [weak self] packet in await self?.chimes.chimeEventHandler(packet) }
    }

    override func configureDeviceAsync() async {
        guard ufp.feature("isDoorbell") else { return }
        await super.configureDeviceAsync()
        if let packageCamera { await packageCamera.configurePackageStream() }
    }

    override func cleanup() {
        timers.cancel(id + ".Doorbell.AuthSensor")
        packageCamera?.cleanup()
        packageCamera = nil
        super.cleanup()
    }

    /// The package camera of a doorbell that has one, as an accessory of its own.
    @discardableResult
    private func configurePackageCamera() -> Bool {
        guard ufp.feature("hasPackageCamera") else { return false }
        if packageCamera != nil { return true }
        let id = ProtectPlatform.accessoryID(ufp.mac + ".PackageCamera")
        let accessory = ProtectAccessory(id: id, name: platform.host.cachedName(id: id) ?? accessoryName + " Package Camera", category: .ipCamera, host: platform.host, log: nvr.log)
        accessory.isStandalone = hasFeature("Device.Standalone")
        packageCamera = ProtectCameraPackage(nvr: nvr, device: packageJSON, accessory: accessory)
        packageCamera?.configureHints()
        packageCamera?.configureDevice()
        return true
    }

    /// The doorbell's JSON as its package camera sees it: the same device, named `<name> Package Camera`.
    var packageJSON: JSONValue {
        ufp.json.setting("name", .string((ufp.name ?? ufp.marketName ?? "") + " Package Camera"))
    }

    /// A contact sensor that opens when a fingerprint or NFC card is recognized (`Doorbell.AuthSensor`).
    @discardableResult
    private func configureAuthSensor() -> Bool {
        let enabled = hasFeature("Doorbell.AuthSensor") && (ufp.json.bool("enableNfc") || ufp.feature("hasFingerprintSensor"))
        guard accessory.valid(.contactSensor, enabled, subtype: ProtectReservedNames.contactAuthSensor) else { return false }
        let service = accessory.acquire(.contactSensor, name: accessoryName + " Authenticated", subtype: ProtectReservedNames.contactAuthSensor)
        service[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
        log.info("Enabling Protect authentication contact sensor.")
        return true
    }

    override func configureMqtt() {
        super.configureMqtt()
        chimes.configureMqtt()
        lcdMessages.configureMqtt()
    }

    override func updateDevice() {
        super.updateDevice()
        packageCamera?.accessory.firstService(.motionSensor)?[.statusActive]?.value = .bool(isOnline)
        chimes.update()
    }

    override func eventHandler(_ packet: ProtectEventPacket) async {
        let payload = packet.payload
        await super.eventHandler(packet)
        packageCamera?.ufp = ProtectDeviceConfig(packageJSON)
        // HKSV needs a motion sensor on the package camera's accessory; the doorbell's motion drives it.
        if payload.at("lastMotion")?.isTruthy == true, let packageCamera, packageCamera.stream?.isRecording == true {
            nvr.events.motionEventHandler(packageCamera)
        }
        if let message = payload.at("lcdMessage"), message.isTruthy { lcdMessages.update(message) }
    }

    override func addEventHandler(_ packet: ProtectEventPacket) async {
        await super.addEventHandler(packet)
        let payload = packet.payload
        guard let type = payload.string("type"), ["fingerprintIdentified", "nfcCardScanned"].contains(type) else { return }
        timers.cancel(id + ".Doorbell.AuthSensor")
        let service = accessory.service(.contactSensor, subtype: ProtectReservedNames.contactAuthSensor)
        guard payload.isSet("metadata.fingerprint.ulpId") || payload.isSet("metadata.nfc.ulpId") else {
            service?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
            return
        }
        service?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactNotDetected)
        var info: [String: JSONValue] = ["type": "fingerprint"]
        if type == "nfcCardScanned" {
            info["id"] = .string(payload.string("metadata.nfc.nfcId") ?? "")
            info["type"] = "nfc"
        }
        publish("authenticate", JSONValue.object(info).text())
        timers.reset(id + ".Doorbell.AuthSensor", after: ProtectSettings.doorbellAuthSensorDuration) {
            service?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
        }
    }
}

/// The package camera of a doorbell (`ProtectCameraPackage`): the doorbell's second lens, with the doorbell's
/// motion, and a flashlight that stays on while it is on.
@ProtectActor
final class ProtectCameraPackage: ProtectCamera {
    private var flashlightState = false
    private var flashlightTimer: Task<Void, Never>?

    override var id: String { ufp.mac + ".PackageCamera" }

    override func configureDevice() {
        if let parent = nvr.getDevice(id: ufp.id) {
            // The hints a package camera takes from its doorbell.
            let shared: [WritableKeyPath<ProtectHints, Bool>] = [\.hardwareDecoding, \.hardwareTranscoding, \.highResSnapshots, \.logHksv, \.transcode, \.transcodeHighLatency, \.tsbStreaming]
            for key in shared { hints[keyPath: key] = parent.hints[keyPath: key] }
            hints.transcodeBitrate = parent.hints.transcodeBitrate
            hints.transcodeHighLatencyBitrate = parent.hints.transcodeHighLatencyBitrate
        }
        flashlightState = false
        hints.probesize = ProtectSettings.ffmpegProbesizePackage
        initializeContext()
        // A package camera is synthetic: no MAC of its own, its doorbell's instead.
        context.packageCamera = ufp.mac
        configureInfo()
        configureMotionSensor()
        configureFlashlight()
    }

    override func configureDeviceAsync() async {}

    /// The resolutions of the package camera: its channel, and the sizes HomeKit requires at 15 fps.
    func configurePackageStream() async {
        let native = findRtsp(width: 0, height: 0)?.resolution ?? VideoResolution(1600, 1200, 2)
        var valid = [native]
        let sizes: [(Int, Int)] = Double(native.width) / Double(native.height) == 16.0 / 9.0
            ? [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720), (640, 360), (480, 270), (320, 180)]
            : [(3840, 2880), (2560, 1920), (1920, 1440), (1280, 960), (640, 480), (480, 360), (320, 240)]
        for (width, height) in sizes {
            if width >= native.width, ![1920, 1280].contains(width) { continue }
            let entry = VideoResolution(width, height, 15)
            if !valid.contains(entry) { valid.append(entry) }
        }
        if hasFeature("Debug.Video.Startup") {
            for entry in valid { log.info("Mapping resolution: \(entry.formatted) => \(native.formatted).") }
        }
        if stream == nil, let ffmpeg = platform.ffmpeg {
            stream = ProtectStreamingDelegate(camera: self, resolutions: valid, ffmpeg: ffmpeg)
        }
    }

    override func cleanup() {
        flashlightTimer?.cancel()
        flashlightTimer = nil
        super.cleanup()
    }

    /// The package camera's channel, on the doorbell's second lens.
    override func findRtsp(width: Int, height: Int, biasHigher: Bool = false, maxPixels: Int? = nil) -> RtspEntry? {
        guard let channel = ufp.channels.first(where: { $0.name == "Package Camera" }) else { return nil }
        let resolution = VideoResolution(channel.width, channel.height, channel.fps)
        let codec = ufp.videoCodec.replacingOccurrences(of: "h265", with: "hevc").uppercased()
        return RtspEntry(channel: channel, lens: 2, name: resolution.formatted + " (\(channel.name)) [\(codec)]", resolution: resolution,
                         url: "rtsps://\(nvr.config.address):\(nvr.ufp.int("ports.rtsps").map(String.init) ?? "")/\(channel.rtspAlias)?enableSrtp")
    }

    override func findRecordingRtsp(width: Int, height: Int) -> RtspEntry? {
        findRtsp(width: width, height: height)
    }

    /// A light for the package camera's flashlight (`Doorbell.PackageCamera.Flashlight`), turned on again
    /// every 20 seconds while it is on, and only in the dark.
    @discardableResult
    private func configureFlashlight() -> Bool {
        guard accessory.valid(.lightbulb, hasFeature("Doorbell.PackageCamera.Flashlight"), subtype: ProtectReservedNames.lightbulbPackageFlashlight) else { return false }
        let service = accessory.acquire(.lightbulb, name: accessoryName + " Flashlight", subtype: ProtectReservedNames.lightbulbPackageFlashlight)
        service[.on]?.onRead { [weak self] in .bool(await self?.flashlightState ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            guard value.boolValue == true else {
                self.flashlightTimer?.cancel()
                self.flashlightTimer = nil
                self.flashlightState = false
                return
            }
            self.flashlightTimer?.cancel()
            guard self.ufp.json.bool("isDark") else {
                self.timers.after(ProtectSettings.homeKitUpdateDelay) { service[.on]?.value = .bool(false) }
                return
            }
            guard await self.activateFlashlight(service) else {
                self.log.error("Unable to turn on the flashlight.")
                throw HAPStatusError(.serviceCommunicationFailure)
            }
            let interval = self.timers.duration(milliseconds: 20_000)
            self.flashlightTimer = Task { @ProtectActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    _ = await self.activateFlashlight(service)
                }
            }
        }
        service[.on]?.value = .bool(flashlightState)
        return true
    }

    /// One heartbeat of the flashlight, tried three times a second apart.
    private func activateFlashlight(_ service: Service) async -> Bool {
        var success = false
        for attempt in 0..<3 {
            if attempt > 0 { await timers.sleep(1000) }
            guard isOnline else { continue }
            let url = await api.endpoint(modelKey: ufp.modelKey) + "/" + ufp.id + "/turnon-flashlight"
            if let response = await api.retrieve(url, method: "POST"), response.isSuccess {
                success = true
                break
            }
        }
        flashlightState = success
        service[.on]?.value = .bool(success)
        if !success {
            flashlightTimer?.cancel()
            flashlightTimer = nil
        }
        return success
    }
}

/// The messages of a doorbell's screen (`DoorbellLcdMessages`): a switch per message saved on the controller
/// (`Doorbell.Messages.FromDoorbell`) and per preset of the configuration, MQTT `message` get and set.
@ProtectActor
final class DoorbellLcdMessages {
    struct MessageSwitch {
        var duration: Int
        var service: Service
        var state: Bool
        var text: String
        var type: String
    }

    private unowned let doorbell: ProtectDoorbell
    let defaultMessageDuration: Int
    private let isMessagesEnabled: Bool
    private let isMessagesFromControllerEnabled: Bool
    private(set) var messageSwitches: [String: MessageSwitch] = [:]

    init(doorbell: ProtectDoorbell) {
        self.doorbell = doorbell
        defaultMessageDuration = doorbell.nvr.ufp.int("doorbellSettings.defaultMessageResetTimeoutMs") ?? ProtectSettings.doorbellMessageDuration
        isMessagesEnabled = doorbell.hasFeature("Doorbell.Messages")
        isMessagesFromControllerEnabled = doorbell.hasFeature("Doorbell.Messages.FromDoorbell")
    }

    @discardableResult
    func configure() -> Bool {
        guard doorbell.ufp.modelKey == "camera", doorbell.ufp.feature("hasLcdScreen") else { return false }
        var current: Set<String> = []
        for var entry in messages() {
            if entry.text.count > 30 { entry.text = String(entry.text.prefix(30)) }
            let index = entry.type + "." + entry.text
            guard !doorbell.isReservedName(index) else { continue }
            current.insert(index)
            guard messageSwitches[index] == nil else { continue }
            doorbell.log.info("Enabled doorbell message switch\(entry.duration != 0 ? " (\(entry.duration / 1000) seconds)" : ""): \(entry.text).")
            let service = doorbell.accessory.acquire(.switch, name: entry.text, subtype: index)
            messageSwitches[index] = MessageSwitch(duration: entry.duration, service: service, state: false, text: entry.text, type: entry.type)
            service[.on]?.onWrite { @ProtectActor [weak self] value in
                guard let self, let message = self.messageSwitches[index], message.state != (value.boolValue ?? false) else { return }
                if value.boolValue == true {
                    try await self.setMessage(["duration": .number(Double(message.duration)), "text": .string(message.text), "type": .string(message.type)])
                } else {
                    try await self.setMessage(["resetAt": .number((Date().timeIntervalSince1970 * 1000).rounded())])
                }
            }
        }
        if let message = doorbell.ufp.json.at("lcdMessage"), message.objectValue != nil { update(message) }
        validateMessageSwitches(current: current)
        return true
    }

    func configureMqtt() {
        let mac = doorbell.ufp.mac
        doorbell.nvr.mqtt?.subscribeGet(mac, "message", type: "doorbell message", log: doorbell.log) { [weak self] in
            await self?.currentMessageJSON() ?? ""
        }
        doorbell.nvr.mqtt?.subscribeSet(mac, "message", type: "doorbell message", log: doorbell.log) { [weak self] _, raw in
            await self?.handleMQTTMessage(raw)
        }
    }

    private func currentMessageJSON() -> String {
        guard let message = doorbell.ufp.json.at("lcdMessage"), message.objectValue != nil else { return "" }
        let duration = message.double("resetAt").flatMap { Int(saturating: (($0 - Date().timeIntervalSince1970 * 1000) / 1000).rounded()) } ?? 0
        return JSONValue.object(["duration": .number(Double(duration)), "message": .string(message.string("text") ?? "")]).text()
    }

    /// `{ "message": "…", "duration": 30 }`: no duration (or a negative one) uses the default, 0 never
    /// expires, an empty message resets the screen.
    func handleMQTTMessage(_ raw: String) async {
        guard let payload = try? JSONValue(string: raw) else {
            doorbell.log.error("Unable to process MQTT message: \"\(raw)\". Invalid JSON.")
            return
        }
        guard let message = payload.string("message"), !payload.has("duration") || payload.at("duration")?.doubleValue?.isFinite == true else {
            doorbell.log.error("Unable to process MQTT message: \"\(raw)\".")
            return
        }
        let duration = Self.mqttDuration(payload.double("duration"), default: defaultMessageDuration)
        let outbound: JSONValue
        if message.isEmpty {
            outbound = ["resetAt": .number((Date().timeIntervalSince1970 * 1000).rounded())]
            doorbell.log.info("Received MQTT doorbell message reset.")
        } else {
            outbound = ["duration": .number(Double(duration)), "text": .string(message), "type": "CUSTOM_MESSAGE"]
            doorbell.log.info("Received MQTT doorbell message\(duration != 0 ? " (\(ProtectCamera.number(Double(duration) / 1000)) seconds)" : ""): \(message).")
        }
        do {
            try await setMessage(outbound)
        } catch {
            // Logged by the write.
        }
    }

    /// Milliseconds from an MQTT duration in seconds: the default when missing or negative.
    nonisolated static func mqttDuration(_ seconds: Double?, default defaultDuration: Int) -> Int {
        guard let seconds, seconds >= 0 else { return defaultDuration }
        return protectMilliseconds(seconds: seconds) ?? defaultDuration
    }

    /// The controller's saved messages changed: our copy of its message list first (the controller does
    /// not send it), then the switches.
    func nvrEventHandler(_ packet: ProtectEventPacket) {
        guard let settings = packet.payload.at("doorbellSettings"), settings.isTruthy else { return }
        if let custom = settings.at("customMessages")?.arrayValue, doorbell.nvr.ufp.at("doorbellSettings") != nil {
            let builtin = doorbell.nvr.ufp.array("doorbellSettings.allMessages").filter { $0.string("type") != "CUSTOM_MESSAGE" }
            let customs = custom.compactMap(\.stringValue).map { JSONValue.object(["text": .string($0), "type": "CUSTOM_MESSAGE"]) }
            let doorbellSettings = (doorbell.nvr.ufp.at("doorbellSettings") ?? .object([:])).setting("allMessages", .array(builtin + customs))
            doorbell.nvr.ufp = doorbell.nvr.ufp.setting("doorbellSettings", doorbellSettings)
        }
        configure()
        Task { await doorbell.accessory.publish() }
    }

    /// The screen changed: the switch of the message on it on, the others off.
    func update(_ payload: JSONValue) {
        if payload.objectValue?.isEmpty ?? true {
            for key in messageSwitches.keys {
                messageSwitches[key]?.state = false
                messageSwitches[key]?.service[.on]?.value = .bool(false)
            }
            return
        }
        guard let type = payload.string("type"), let text = payload.string("text") else { return }
        for key in messageSwitches.keys.sorted() {
            guard var entry = messageSwitches[key] else { continue }
            if key != type + "." + text {
                entry.state = false
                entry.service[.on]?.value = .bool(false)
                messageSwitches[key] = entry
                continue
            }
            guard !entry.state else { continue }
            entry.state = true
            entry.service[.on]?.value = .bool(true)
            messageSwitches[key] = entry
            let remaining = payload.double("resetAt").flatMap { Int(saturating: (($0 - Date().timeIntervalSince1970 * 1000) / 1000).rounded()) }.map { " (\($0) seconds)" } ?? ""
            doorbell.log.info("Doorbell message set\(remaining): \(text).")
            doorbell.publish("message", JSONValue.object(["duration": .number(Double(entry.duration) / 1000), "message": .string(entry.text)]).text())
        }
    }

    /// The controller's messages (unless turned off) and the configuration's presets.
    func messages() -> [(duration: Int, text: String, type: String)] {
        guard doorbell.nvr.ufp.at("doorbellSettings") != nil, isMessagesEnabled else { return [] }
        var result: [(duration: Int, text: String, type: String)] = doorbell.nvr.config.doorbellMessages.map { entry in
            let duration = entry.duration.flatMap { $0 >= 0 ? protectMilliseconds(seconds: $0) : nil } ?? defaultMessageDuration
            return (duration, entry.message, "CUSTOM_MESSAGE")
        }
        if isMessagesFromControllerEnabled {
            let controller = doorbell.nvr.ufp.array("doorbellSettings.allMessages").compactMap { message -> (Int, String, String)? in
                guard let text = message.string("text"), let type = message.string("type") else { return nil }
                return (message.int("duration") ?? defaultMessageDuration, text, type)
            }
            result = controller + result
        }
        return result
    }

    /// Removes the switches of messages that are gone, from the controller or the configuration.
    private func validateMessageSwitches(current: Set<String>) {
        for (key, entry) in messageSwitches where !current.contains(key) {
            doorbell.log.info("Removing saved doorbell message: \(entry.text).")
            doorbell.accessory.remove(entry.service)
            messageSwitches[key] = nil
        }
        for service in doorbell.accessory.services(.switch) {
            guard let subtype = service.subtype, !doorbell.isReservedName(subtype), messageSwitches[subtype] == nil else { continue }
            doorbell.log.info("Removing saved doorbell message: \(subtype.split(separator: ".", maxSplits: 1).last ?? "").")
            doorbell.accessory.remove(service)
        }
    }

    /// Shows a message, or resets the screen with an empty payload. A duration becomes Protect's `resetAt`.
    func setMessage(_ payload: JSONValue) async throws {
        var message = payload.objectValue ?? [:]
        if let duration = message.removeValue(forKey: "duration") {
            let milliseconds = duration.doubleValue ?? 0
            message["resetAt"] = milliseconds != 0 ? .number((Date().timeIntervalSince1970 * 1000 + milliseconds).rounded()) : .null
        }
        try await doorbell.writeDevice(["lcdMessage": .object(message)],
            "Unable to set doorbell message. Please ensure this username has the Administrator role in UniFi Protect.")
    }
}

/// The physical chimes and chime volume of a doorbell (`DoorbellChimes`).
@ProtectActor
final class DoorbellChimes {
    nonisolated static let physicalChimeSwitches = [ProtectReservedNames.switchDoorbellChimeNone, ProtectReservedNames.switchDoorbellChimeMechanical, ProtectReservedNames.switchDoorbellChimeDigital]

    private unowned let doorbell: ProtectDoorbell
    let chimeDigitalDuration: Int

    init(doorbell: ProtectDoorbell) {
        self.doorbell = doorbell
        chimeDigitalDuration = Self.clampDigitalDuration(doorbell.getFeatureInt("Doorbell.PhysicalChime.Duration.Digital", in: 0...Int(Int32.max)))
    }

    /// A digital chime rings between one and ten seconds.
    nonisolated static func clampDigitalDuration(_ value: Int?) -> Int {
        min(max(value ?? ProtectSettings.doorbellChimeDurationDigital, 1000), 10_000)
    }

    func configure() {
        configurePhysicalChimes()
        configureVolumeLightbulb()
    }

    func configureMqtt() {
        let mac = doorbell.ufp.mac
        doorbell.nvr.mqtt?.subscribeGet(mac, "chime", type: "chime volume", log: doorbell.log) { [weak self] in
            guard let self else { return "0" }
            return ProtectCamera.number(await self.currentChimeVolume())
        }
        doorbell.nvr.mqtt?.subscribeSet(mac, "chime", type: "chime volume", log: doorbell.log) { [weak self] value, _ in
            guard let volume = Int(value.trimmingCharacters(in: .whitespaces)), (0...100).contains(volume), let self else { return }
            let service = await self.volumeService
            try await service?[.brightness]?.write(.int(volume))
            try await service?[.on]?.write(.bool(volume > 0))
        }
    }

    private var volumeService: Service? {
        doorbell.accessory.service(.lightbulb, subtype: ProtectReservedNames.lightbulbDoorbellVolume)
    }

    func update() {
        guard doorbell.ufp.feature("hasChime"), doorbell.hasFeature("Doorbell.PhysicalChime") else { return }
        let current = doorbell.ufp.json.int("chimeDuration")
        for type in Self.physicalChimeSwitches {
            doorbell.accessory.service(.switch, subtype: type)?[.on]?.value = .bool(current == physicalChimeDuration(type))
        }
    }

    /// A chime changed on the controller: our copy of it, and the volume dimmer.
    func chimeEventHandler(_ packet: ProtectEventPacket) async {
        let payload = packet.payload
        guard let bootstrap = await doorbell.api.bootstrap, payload.string("nvrMac") == doorbell.nvr.mac,
              payload.strings("cameraIds").contains(doorbell.ufp.id), payload.has("ringSettings") else { return }
        guard let chime = bootstrap.array("chimes").first(where: { $0.string("id") == packet.id }) else { return }
        // The packet's id names the chime; an update payload carries only what changed, usually without it.
        let merged = chime.shallowMerged(payload)
        let chimeID = packet.id
        await doorbell.api.updateBootstrap { bootstrap in
            bootstrap = bootstrap.setting("chimes", .array(bootstrap.array("chimes").filter { $0.string("id") != chimeID } + [merged]))
        }
        if let ring = payload.array("ringSettings").first(where: { $0.string("cameraId") == doorbell.ufp.id }), let volume = ring.double("volume") {
            volumeService?[.brightness]?.value = .int(Int(saturating: volume, in: 0...100) ?? 0)
            volumeService?[.on]?.value = .bool(volume > 0)
        }
    }

    /// Milliseconds of each physical chime mode, as Protect sets them.
    func physicalChimeDuration(_ type: String) -> Int {
        switch type {
        case ProtectReservedNames.switchDoorbellChimeDigital: chimeDigitalDuration
        case ProtectReservedNames.switchDoorbellChimeMechanical: ProtectSettings.doorbellChimeDurationMechanical
        default: 0
        }
    }

    /// Switches for the physical chime modes (`Doorbell.PhysicalChime`): none, mechanical, digital.
    private func configurePhysicalChimes() {
        var enabled: [String] = []
        let available = doorbell.ufp.feature("hasChime") && doorbell.hasFeature("Doorbell.PhysicalChime")
        for type in Self.physicalChimeSwitches {
            let setting = String(type.split(separator: ".").last ?? "")
            guard doorbell.accessory.valid(.switch, available, subtype: type) else { continue }
            let service = doorbell.accessory.acquire(.switch, name: doorbell.accessoryName + " Physical Chime " + toCamelCase(setting), subtype: type)
            service[.on]?.onRead { [weak self] in
                guard let self else { return .bool(false) }
                return .bool(await self.doorbell.ufp.json.int("chimeDuration") == self.physicalChimeDuration(type))
            }
            service[.on]?.onWrite { @ProtectActor [weak self] value in
                guard let self else { return }
                guard value.boolValue == true else {
                    self.doorbell.timers.after(ProtectSettings.homeKitUpdateDelay) { [weak self] in self?.doorbell.updateDevice() }
                    return
                }
                try await self.doorbell.writeDevice(["chimeDuration": .number(Double(self.physicalChimeDuration(type)))], "Unable to set the physical chime mode to \(setting).")
                for other in Self.physicalChimeSwitches where other != type {
                    self.doorbell.accessory.service(.switch, subtype: other)?[.on]?.value = .bool(false)
                }
                self.doorbell.log.info("Physical chime type set to \(setting).")
            }
            service[.on]?.value = .bool(doorbell.ufp.json.int("chimeDuration") == physicalChimeDuration(type))
            enabled.append(setting)
        }
        if !enabled.isEmpty {
            let duration = ProtectStreamingDelegate.grouped(chimeDigitalDuration)
            doorbell.log.info("Enabling physical chime switches: \(enabled.joined(separator: ", ")) (digital chime duration: \(duration) ms).")
        }
    }

    /// A dimmer for the volume of the doorbell's chimes (`Doorbell.Volume.Dimmer`).
    @discardableResult
    private func configureVolumeLightbulb() -> Bool {
        guard doorbell.accessory.valid(.lightbulb, doorbell.hasFeature("Doorbell.Volume.Dimmer"), subtype: ProtectReservedNames.lightbulbDoorbellVolume) else { return false }
        let service = doorbell.accessory.acquire(.lightbulb, name: doorbell.accessoryName + " Chime Volume", subtype: ProtectReservedNames.lightbulbDoorbellVolume, optional: [.brightness])
        service[.on]?.onRead { [weak self] in .bool((await self?.currentChimeVolume() ?? 0) > 0) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard value.boolValue != true else { return }
            try await self?.setChimeVolume(0)
        }
        service[.brightness]?.onRead { [weak self] in .int(Int(saturating: await self?.currentChimeVolume() ?? 0, in: 0...100) ?? 0) }
        service[.brightness]?.onWrite { @ProtectActor [weak self] value in try await self?.setChimeVolume(value.intValue ?? 0) }
        Task { @ProtectActor [weak self] in
            guard let self else { return }
            let volume = await self.currentChimeVolume()
            service[.on]?.value = .bool(volume > 0)
            service[.brightness]?.value = .int(Int(saturating: volume, in: 0...100) ?? 0)
        }
        doorbell.log.info("Enabling Protect chime volume control.")
        return true
    }

    /// The average volume of the chimes this doorbell rings (as last read).
    private(set) var chimeVolume = 0.0

    /// Reads the average volume from the bootstrap.
    func currentChimeVolume() async -> Double {
        guard let bootstrap = await doorbell.api.bootstrap else { return 0 }
        let id = doorbell.ufp.id
        let volumes = bootstrap.array("chimes").filter { $0.strings("cameraIds").contains(id) }.compactMap { chime in
            chime.array("ringSettings").first { $0.string("cameraId") == id }?.double("volume")
        }
        chimeVolume = volumes.isEmpty ? 0 : volumes.reduce(0, +) / Double(volumes.count)
        return chimeVolume
    }

    /// Sets the volume on every chime this doorbell rings.
    func setChimeVolume(_ value: Int) async throws {
        guard let bootstrap = await doorbell.api.bootstrap else { return }
        let volume = max(value, 0)
        let id = doorbell.ufp.id
        for chime in bootstrap.array("chimes") where chime.strings("cameraIds").contains(id) {
            guard let ring = chime.array("ringSettings").first(where: { $0.string("cameraId") == id }) else { continue }
            let updated = try await doorbell.writeDeviceConfig(chime, ["ringSettings": [ring.setting("volume", .number(Double(volume)))]],
                "Unable to set the chime volume. Please ensure this username has the Administrator role in UniFi Protect.")
            let mac = chime.string("mac")
            await doorbell.api.updateBootstrap { bootstrap in
                bootstrap = bootstrap.setting("chimes", .array(bootstrap.array("chimes").filter { $0.string("mac") != mac } + [updated]))
            }
        }
        _ = await currentChimeVolume()
        doorbell.publish("chime", String(volume))
    }
}
