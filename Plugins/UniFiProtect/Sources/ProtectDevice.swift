import Foundation
import Homeswift
import HomeswiftPlugin

/// The service subtypes the Homebridge plugin reserves (`ProtectReservedNames`), kept so services keep
/// their identity.
enum ProtectReservedNames {
    static let contactAuthSensor = "ContactAuthSensor"
    static let contactMotionSmartDetect = "ContactMotionSmartDetect"
    static let contactMotionSmartDetectLicense = "ContactMotionSmartDetectLicense"
    static let contactSensor = "ContactSensor"
    static let contactSensorAlarmSound = "ContactAlarmSound"
    static let leakSensorExternal = "External"
    static let leakSensorInternal = "Internal"
    static let lightbulbDoorbellVolume = "ChimeVolume"
    static let lightbulbNightVision = "NightVision"
    static let lightbulbPackageFlashlight = "PackageCamera.Flashlight"
    static let lockAccess = "Access"
    static let switchDoorbellChimeBuzzer = "DoorbellChime.buzzer"
    static let switchDoorbellChimeDigital = "DoorbellChime.digital"
    static let switchDoorbellChimeMechanical = "DoorbellChime.mechanical"
    static let switchDoorbellChimeNone = "DoorbellChime.none"
    static let switchDoorbellChimeSpeaker = "DoorbellChime.speaker"
    static let switchDoorbellMute = "DoorbellMute"
    static let switchDoorbellTrigger = "DoorbellTrigger"
    static let switchHKSVRecording = "HKSVRecordingSwitch"
    static let switchMotionSensor = "MotionSensorSwitch"
    static let switchMotionTrigger = "MotionSensorTrigger"
    static let switchStatusLed = "StatusLedSwitch"
    static let switchUFPRecordingAlways = "UFPRecordingSwitch.always"
    static let switchUFPRecordingDetections = "UFPRecordingSwitch.detections"
    static let switchUFPRecordingNever = "UFPRecordingSwitch.never"

    static let all: [String] = [
        contactAuthSensor, contactMotionSmartDetect, contactMotionSmartDetectLicense, contactSensor, contactSensorAlarmSound, leakSensorExternal,
        leakSensorInternal, lightbulbDoorbellVolume, lightbulbNightVision, lightbulbPackageFlashlight, lockAccess, switchDoorbellChimeBuzzer,
        switchDoorbellChimeDigital, switchDoorbellChimeMechanical, switchDoorbellChimeNone, switchDoorbellChimeSpeaker, switchDoorbellMute,
        switchDoorbellTrigger, switchHKSVRecording, switchMotionSensor, switchMotionTrigger, switchStatusLed, switchUFPRecordingAlways,
        switchUFPRecordingDetections, switchUFPRecordingNever,
    ]
    static let upperCased = Set(all.map { $0.uppercased() })
}

/// Device settings worked out from the feature options (`ProtectHints`).
struct ProtectHints: Sendable {
    var crop = false
    var cropOptions = (height: 0.0, width: 0.0, x: 0.0, y: 0.0)
    var enabled = true
    var hardwareDecoding = false
    var hardwareTranscoding = false
    var highResSnapshots = false
    var hksvRecordingIndicator = false
    var ledStatus = false
    var logDoorbell = false
    var logHksv = false
    var logMotion = false
    var motionDuration = ProtectSettings.motionDuration
    var nightVision = false
    var nightVisionDimmer = false
    var nvrRecordingSwitch = false
    var occupancyDuration = ProtectSettings.occupancyDuration
    var probesize = 0
    var recordingDefault = ""
    var rtspOverride = ""
    var snapshotUrlOverride = ""
    var smartDetect = false
    var smartDetectSensors = false
    var smartOccupancy: [String] = []
    var standalone = false
    var statusLedSwitch = false
    var streamingDefault = ""
    var syncName = false
    var transcode = false
    var transcodeBitrate = 0
    var transcodeHighLatency = false
    var transcodeHighLatencyBitrate = 0
    var tsbStreaming = false
    var twoWayAudio = false
    var twoWayAudioDirect = false
}

/// What every object of a controller has: the controller, a log, and event subscriptions that `cleanup()`
/// removes (`ProtectBase`).
@ProtectActor
class ProtectBase {
    unowned let nvr: ProtectNVR
    private var subscriptions: [String: Int] = [:]

    init(nvr: ProtectNVR) {
        self.nvr = nvr
    }

    var log: ProtectLog { nvr.log }
    var api: ProtectAPI { nvr.api }
    var platform: ProtectPlatform { nvr.platform }
    var timers: ProtectTimers { nvr.timers }

    /// Subscribes to a controller event; subscribing to the same event again replaces the handler.
    func subscribe(_ event: String, _ handler: @escaping @ProtectActor (ProtectEventPacket) async -> Void) {
        if let previous = subscriptions[event] { nvr.events.off(event, token: previous) }
        subscriptions[event] = nvr.events.on(event, handler)
    }

    /// Removes the event subscriptions; subclasses also stop their timers.
    func cleanup() {
        for (event, token) in subscriptions { nvr.events.off(event, token: token) }
        subscriptions = [:]
    }
}

/// A Protect device in HomeKit (`ProtectDevice`): its accessory, hints, JSON, and what every device type
/// shares: motion and occupancy sensors, motion switches, the status light switch, MQTT, feature options.
@ProtectActor
class ProtectDevice: ProtectBase {
    let accessory: ProtectAccessory
    var hints = ProtectHints()
    var ufp: ProtectDeviceConfig

    init(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) {
        self.accessory = accessory
        ufp = ProtectDeviceConfig(device)
        super.init(nvr: nvr)
    }

    /// The device's log: `Controller: Device [Model]: …`.
    override var log: ProtectLog { nvr.log.named(name) }

    /// `Device Name [Model]`.
    var name: String { ProtectAPI.deviceName(ufp.json) }

    /// The device's own id: its MAC (a package camera adds `.PackageCamera`).
    var id: String { ufp.mac }

    var isOnline: Bool { ufp.isConnected }

    var accessoryName: String { accessory.name }

    /// The accessory's persistent context.
    var context: ProtectAccessoryContext {
        get { platform.contexts[accessory.id] }
        set { platform.contexts[accessory.id] = newValue }
    }

    // MARK: Hints and information

    func configureHints() {
        hints.enabled = hasFeature("Device")
        hints.logMotion = hasFeature("Log.Motion")
        hints.motionDuration = getFeatureInt("Motion.Duration", in: ProtectSettings.durationRange) ?? ProtectSettings.motionDuration
        hints.occupancyDuration = getFeatureInt("Motion.OccupancySensor.Duration", in: ProtectSettings.durationRange) ?? ProtectSettings.occupancyDuration
        hints.smartOccupancy = []
        hints.standalone = hasFeature("Device.Standalone")
        hints.syncName = hasFeature("Device.SyncName")
        // A motion event needs time for the user to see it, an occupancy one longer.
        hints.motionDuration = max(hints.motionDuration, 2)
        hints.occupancyDuration = max(hints.occupancyDuration, 60)
        if hints.syncName {
            logFeature("Device.SyncName", "Syncing Protect device name to HomeKit.", nvrMessage: "Syncing Protect device names to HomeKit.")
        } else if isDeviceFeature("Device.SyncName") {
            log.info("Not syncing this Protect device name to HomeKit.")
        }
        if hints.motionDuration != ProtectSettings.motionDuration { log.info("Motion event duration set to \(hints.motionDuration) seconds.") }
        if hints.occupancyDuration != ProtectSettings.occupancyDuration { log.info("Occupancy event duration set to \(hints.occupancyDuration) seconds.") }
    }

    /// The accessory's information, and its name when `Device.SyncName` is on.
    func configureInfo() {
        if hints.syncName { accessory.rename(ufp.name ?? ufp.marketName ?? accessory.name) }
        setInfo(ufp)
    }

    func setInfo(_ device: ProtectDeviceConfig) {
        accessory.setInformation(
            manufacturer: "Ubiquiti Inc.", model: device.marketName ?? device.type, serialNumber: device.mac.isEmpty ? nil : device.mac,
            firmwareRevision: device.firmwareVersion)
    }

    // MARK: Writing to Protect

    /// Sends a change to Protect; on success our view of the device is the controller's answer. On failure
    /// the message is logged and a HAP error makes HomeKit revert the change.
    @discardableResult
    func writeDevice(_ payload: JSONValue, _ errorMessage: String) async throws -> ProtectDeviceConfig {
        let updated = try await writeDeviceConfig(ufp.json, payload, errorMessage)
        ufp = ProtectDeviceConfig(updated)
        return ufp
    }

    /// The same for another device, a chime of a doorbell for one.
    func writeDeviceConfig(_ device: JSONValue, _ payload: JSONValue, _ errorMessage: String) async throws -> JSONValue {
        guard let updated = await api.updateDevice(device, payload: payload) else {
            log.error(errorMessage)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        return updated
    }

    // MARK: MQTT

    func publish(_ topic: String, _ message: String) {
        nvr.publish(ufp.mac, topic, message)
    }

    func subscribeGet(_ topic: String, _ type: String, _ getValue: @escaping @ProtectActor () -> String) {
        nvr.mqtt?.subscribeGet(ufp.mac, topic, type: type, log: log) { await getValue() }
    }

    func subscribeSet(_ topic: String, _ type: String, _ setValue: @escaping @ProtectActor (_ value: String, _ raw: String) async throws -> Void) {
        nvr.mqtt?.subscribeSet(ufp.mac, topic, type: type, log: log) { value, raw in try await setValue(value, raw) }
    }

    // MARK: Services

    /// The optional characteristics a sensor service gets for its state.
    static let sensorStatus: [CharacteristicType] = [.statusActive, .statusTampered]

    /// The motion sensor, with its switches and MQTT topics. `isInitialized` keeps handlers already set when a
    /// sensor is reconfigured live (a UniFi sensor changing mode).
    @discardableResult
    func configureMotionSensor(isEnabled: Bool = true, isInitialized: Bool = false, optional: [CharacteristicType] = [.statusActive]) -> Bool {
        if !isEnabled {
            nvr.mqtt?.unsubscribe(ufp.mac, "motion/get")
            nvr.mqtt?.unsubscribe(ufp.mac, "motion/set")
            configureMotionSwitch(isEnabled: false)
            configureMotionTrigger(isEnabled: false)
        }
        guard accessory.valid(.motionSensor, isEnabled) else { return false }
        var initialized = isInitialized
        let service = accessory.acquire(.motionSensor, name: accessoryName, optional: optional) { _ in initialized = false }
        guard !initialized else { return true }
        service[.motionDetected]?.value = .bool(false)
        service[.statusActive]?.value = .bool(isOnline)
        service[.statusActive]?.onRead { [weak self] in .bool(await self?.isOnline ?? false) }
        subscribeGet("motion", "motion") { [weak self] in
            self?.accessory.firstService(.motionSensor)?[.motionDetected]?.value.boolValue == true ? "true" : "false"
        }
        subscribeSet("motion", "motion event trigger") { [weak self] value, _ in
            guard value == "true", let self else { return }
            self.nvr.events.motionEventHandler(self)
        }
        configureMotionSwitch(isEnabled: isEnabled)
        configureMotionTrigger(isEnabled: isEnabled)
        return true
    }

    /// A switch that turns motion detection on and off in HomeKit (`Motion.Switch`).
    @discardableResult
    private func configureMotionSwitch(isEnabled: Bool) -> Bool {
        guard accessory.valid(.switch, isEnabled && hasFeature("Motion.Switch"), subtype: ProtectReservedNames.switchMotionSensor) else {
            // Never leave motion detection off without a way to turn it back on.
            context.detectMotion = true
            return false
        }
        let service = accessory.acquire(.switch, name: accessoryName + " Motion Events", subtype: ProtectReservedNames.switchMotionSensor)
        service[.on]?.onRead { [weak self] in .bool(await self?.context.detectMotion ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if self.context.detectMotion != on { self.log.info("Motion detection \(on ? "enabled" : "disabled").") }
            self.context.detectMotion = on
        }
        if context.detectMotion == nil { context.detectMotion = true }
        service[.on]?.value = .bool(context.detectMotion ?? true)
        log.info("Enabling motion sensor switch.")
        return true
    }

    /// A switch that triggers a motion event (`Motion.Trigger`).
    @discardableResult
    private func configureMotionTrigger(isEnabled: Bool) -> Bool {
        guard accessory.valid(.switch, isEnabled && hasFeature("Motion.Trigger"), subtype: ProtectReservedNames.switchMotionTrigger) else { return false }
        let trigger = accessory.acquire(.switch, name: accessoryName + " Motion Trigger", subtype: ProtectReservedNames.switchMotionTrigger)
        trigger[.on]?.onRead { [weak self] in
            .bool(await self?.accessory.firstService(.motionSensor)?[.motionDetected]?.value.boolValue ?? false)
        }
        trigger[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let motion = self.accessory.firstService(.motionSensor)
            let motionSwitch = self.accessory.service(.switch, subtype: ProtectReservedNames.switchMotionSensor)
            if value.boolValue == true {
                if let motionSwitch, motionSwitch[.on]?.value.boolValue != true {
                    self.timers.after(ProtectSettings.homeKitUpdateDelay) { trigger[.on]?.value = .bool(false) }
                } else {
                    self.nvr.events.motionEventHandler(self)
                    self.log.info("Motion event triggered.")
                }
                return
            }
            if motion?[.motionDetected]?.value.boolValue == true {
                self.timers.after(ProtectSettings.homeKitUpdateDelay) { trigger[.on]?.value = .bool(true) }
            }
        }
        trigger[.on]?.value = .bool(false)
        log.info("Enabling motion sensor automation trigger.")
        return true
    }

    /// The occupancy sensor (`Motion.OccupancySensor`), driven by motion or by chosen smart detections.
    @discardableResult
    func configureOccupancySensor(isEnabled: Bool = true, isInitialized: Bool = false) -> Bool {
        if !isEnabled || !hasFeature("Motion.OccupancySensor") {
            nvr.mqtt?.unsubscribe(ufp.mac, "occupancy/get")
        }
        guard accessory.valid(.occupancySensor, isEnabled && hasFeature("Motion.OccupancySensor")) else { return false }
        var initialized = isInitialized
        let service = accessory.acquire(.occupancySensor, name: accessoryName, optional: [.statusActive]) { _ in initialized = false }
        guard !initialized else { return true }
        service[.occupancyDetected]?.value = .int(HAPConstants.OccupancyDetected.occupancyNotDetected)
        service[.statusActive]?.value = .bool(isOnline)
        service[.statusActive]?.onRead { [weak self] in .bool(await self?.isOnline ?? false) }
        if hints.smartDetect {
            for type in ufp.smartDetectAudioTypes + ufp.smartDetectTypes where hasFeature("Motion.OccupancySensor." + type) {
                hints.smartOccupancy.append(type)
            }
            if hints.smartOccupancy.isEmpty { hints.smartOccupancy.append("no smart motion detection object type configured") }
        }
        subscribeGet("occupancy", "occupancy") { [weak self] in
            self?.accessory.firstService(.occupancySensor)?[.occupancyDetected]?.value.intValue == HAPConstants.OccupancyDetected.occupancyDetected ? "true" : "false"
        }
        log.info("Enabling occupancy sensor\(hints.smartDetect ? " using smart motion detection: " + hints.smartOccupancy.joined(separator: ", ") : "").")
        return true
    }

    /// A switch for the device's status light (`Device.StatusLed.Switch`).
    @discardableResult
    func configureStatusLedSwitch(isEnabled: Bool = true) -> Bool {
        guard accessory.valid(.switch, isEnabled && hasFeature("Device.StatusLed.Switch"), subtype: ProtectReservedNames.switchStatusLed) else { return false }
        let service = accessory.acquire(.switch, name: accessoryName + " Status Indicator", subtype: ProtectReservedNames.switchStatusLed)
        service[.on]?.onRead { [weak self] in .bool(await self?.statusLed ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if self.statusLed != on { self.log.info("Status indicator light \(on ? "enabled" : "disabled").") }
            try await self.writeStatusLed(on)
        }
        service[.on]?.value = .bool(statusLed)
        log.info("Enabling status indicator light switch.")
        return true
    }

    /// Turns the status light on or off, throwing a HAP error on failure (for characteristic handlers).
    func writeStatusLed(_ value: Bool) async throws {
        try await writeDevice(statusLedCommand(value),
            "Unable to turn the status indicator light \(value ? "on" : "off"). Please ensure this username has the Administrator role in UniFi Protect.")
    }

    /// Turns the status light on or off; false on failure, which is logged.
    func setStatusLed(_ value: Bool) async -> Bool {
        do {
            try await writeStatusLed(value)
            return true
        } catch {
            return false
        }
    }

    /// The payload that sets the status light; lights use their own settings.
    func statusLedCommand(_ value: Bool) -> JSONValue {
        ["ledSettings": ["isEnabled": .bool(value)]]
    }

    var statusLed: Bool { ufp.json.bool("ledSettings.isEnabled") }

    // MARK: Feature options

    func getFeatureFloat(_ option: String) -> Double? {
        platform.featureOptions.getFloat(option, device: ufp.mac, controllers: nvr.controllerScopes).orNil
    }

    func getFeatureNumber(_ option: String) -> Double? {
        platform.featureOptions.getInteger(option, device: ufp.mac, controllers: nvr.controllerScopes).orNil
    }

    /// An integer option, truncated and clamped to `range`: a `1e300` in the configuration never traps.
    func getFeatureInt(_ option: String, in range: ClosedRange<Int>) -> Int? {
        getFeatureNumber(option).flatMap { Int(saturating: $0, in: range) }
    }

    func getFeatureValue(_ option: String) -> String? {
        platform.featureOptions.value(option, device: ufp.mac, controllers: nvr.controllerScopes).string
    }

    func hasFeature(_ option: String) -> Bool {
        platform.featureOptions.test(option, device: ufp.mac, controllers: nvr.controllerScopes)
    }

    /// Whether the option is set at the device scope. The Homebridge plugin asks without the device's id, so
    /// this is never true and a device's option is announced once through the controller's log; kept so.
    func isDeviceFeature(_ option: String) -> Bool {
        platform.featureOptions.scope(option) == .device
    }

    func logFeature(_ option: String, _ message: String, nvrMessage: String? = nil) {
        if isDeviceFeature(option) {
            log.info(message)
            return
        }
        nvr.logFeature(option, nvrMessage ?? message)
    }

    func isReservedName(_ name: String?) -> Bool {
        guard let name else { return false }
        return ProtectReservedNames.upperCased.contains(name.uppercased())
    }
}
