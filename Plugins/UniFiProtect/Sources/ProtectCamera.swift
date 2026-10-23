import Foundation
import Homeswift
import HomeswiftPlugin

/// An RTSP stream of a camera mapped to a resolution HomeKit may ask for.
struct RtspEntry: Sendable, Equatable {
    var channel: ProtectChannel
    var lens: Int?
    var name: String
    var resolution: VideoResolution
    var url: String
}

/// The FFmpeg audio filters for noise reduction (`Audio.Filter.Noise`).
func buildAudioFilterPipeline(fftNr: Double, highpass: Double?, lowpass: Double?) -> [String] {
    var filters: [String] = []
    let nr = max(0.01, min(97, fftNr))
    func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
    if let highpass { filters.append("highpass=p=2:f=" + number(highpass)) }
    if let lowpass { filters.append("lowpass=p=2:f=" + number(lowpass)) }
    filters.append("asendcmd=c='1.0 afftdn sn start ; 3.0 afftdn sn stop', afftdn=nt=c:tn=1:nr=" + number(nr))
    return filters
}

/// A Protect camera (`ProtectCamera`): motion, smart detection, occupancy, tamper and ambient light sensors,
/// night vision, recording and access controls, doorbell switches for automations, MQTT, and the video
/// streams HomeKit sees.
@ProtectActor
class ProtectCamera: ProtectDevice {
    var isRinging = false
    var stream: ProtectStreamingDelegate?
    // The sensors delegate.
    var ambientLight = 0.0
    var ambientLightTimer: Task<Void, Never>?
    var detectLicensePlate: [String] = []
    var isTampered = false
    // The video delegate.
    var rtspEntries: [RtspEntry] = []
    /// The camera's livestream API sessions, shared by the timeshift buffer and live streams.
    private(set) lazy var livestream = ProtectLivestreamManager(camera: self)

    /// Creates and configures a camera.
    static func make(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) async -> ProtectCamera {
        let camera = ProtectCamera(nvr: nvr, device: device, accessory: accessory)
        await camera.setUp()
        return camera
    }

    func setUp() async {
        configureHints()
        configureDevice()
        await configureDeviceAsync()
    }

    override func configureHints() {
        super.configureHints()
        hints.tsbStreaming = hasFeature("Video.Stream.UseApi")
        hints.crop = hasFeature("Video.Crop")
        hints.hardwareDecoding = true
        hints.hardwareTranscoding = hasFeature("Video.Transcode.Hardware")
        hints.highResSnapshots = hasFeature("Video.HighResSnapshots")
        hints.hksvRecordingIndicator = hasFeature("Video.HKSV.StatusLedIndicator")
        hints.ledStatus = ufp.feature("hasLedStatus") && hasFeature("Device.StatusLed")
        hints.logDoorbell = hasFeature("Log.Doorbell")
        hints.logHksv = hasFeature("Log.HKSV")
        hints.nightVision = ufp.feature("hasInfrared") && hasFeature("Device.NightVision")
        hints.nightVisionDimmer = ufp.feature("hasInfrared") && ufp.feature("hasIcrSensitivity") && hasFeature("Device.NightVision.Dimmer")
        hints.nvrRecordingSwitch = hasFeature("Nvr.Recording.Switch")
        hints.probesize = ProtectSettings.ffmpegProbesize
        let override = ufp.isThirdPartyCamera ? nvr.config.cameraOverride(mac: ufp.mac) : nil
        hints.rtspOverride = override?.rtspUrl?.trimmingCharacters(in: .whitespaces) ?? ""
        hints.snapshotUrlOverride = override?.snapshotUrl?.trimmingCharacters(in: .whitespaces) ?? ""
        hints.smartDetect = ufp.feature("hasSmartDetect") && hasFeature("Motion.SmartDetect")
        hints.smartDetectSensors = hints.smartDetect && hasFeature("Motion.SmartDetect.ObjectSensors")
        hints.transcode = hasFeature("Video.Transcode")
        hints.transcodeBitrate = getFeatureNumber("Video.Transcode.Bitrate").map { Int($0) } ?? ProtectSettings.transcodeBitrate
        hints.transcodeHighLatency = hasFeature("Video.Transcode.HighLatency")
        hints.transcodeHighLatencyBitrate = getFeatureNumber("Video.Transcode.HighLatency.Bitrate").map { Int($0) } ?? ProtectSettings.transcodeHighLatencyBitrate
        hints.statusLedSwitch = hasFeature("Device.StatusLed.Switch")
        hints.twoWayAudio = ufp.feature("hasSpeaker") && hasFeature("Audio") && hasFeature("Audio.TwoWay")
        hints.twoWayAudioDirect = ufp.feature("hasSpeaker") && hasFeature("Audio") && hasFeature("Audio.TwoWay.Direct")
    }

    /// Resets the context to what a camera keeps: motion detection, the controller, HKSV recording. Returns
    /// what was there before.
    @discardableResult
    func initializeContext() -> ProtectAccessoryContext {
        let saved = context
        var fresh = ProtectAccessoryContext(detectMotion: saved.detectMotion ?? true, nvr: nvr.mac)
        if hasFeature("Video.HKSV.Recording.Switch") {
            fresh.hksvRecordingDisabled = saved.hksvRecording.map { !$0 } ?? saved.hksvRecordingDisabled ?? false
        }
        context = fresh
        return saved
    }

    /// The synchronous part of the configuration, which a doorbell extends.
    func configureDevice() {
        let saved = initializeContext()
        context.mac = ufp.mac
        if hasFeature("Doorbell.Mute") { context.doorbellMuted = saved.doorbellMuted ?? false }
        if ufp.json.string("recordingSettings.mode") == "never" {
            log.warning("Motion events will not be generated by the Protect controller when the controller's camera recording options are set to \"never\".")
        }
        if hints.smartDetect {
            let types = (ufp.smartDetectAudioTypes + ufp.smartDetectTypes).sorted()
            log.info("Smart motion detection enabled\(types.isEmpty ? "" : ": " + types.joined(separator: ", ")).")
        }
        configureInfo()
        configureMqtt()
        configureMotionSensor(isEnabled: isHksvCapable, optional: motionSensorCharacteristics)
        configureSensors()
        configureOccupancySensor()
        configureCrop()
        configureHksv()
        configureHksvRecordingSwitch()
    }

    /// The part that waits for the controller: the light sensor, the video streams, the controls, the
    /// switches that need the doorbell service, and the event subscriptions.
    func configureDeviceAsync() async {
        await configureAmbientLight()
        await configureVideo()
        configureControls()
        configureStatusLedSwitch()
        configureDoorbellMuteSwitch()
        configureDoorbellTrigger()
        let id = ufp.id
        subscribe("addEvent." + id) { [weak self] packet in await self?.addEventHandler(packet) }
        subscribe("updateEvent." + id) { [weak self] packet in await self?.eventHandler(packet) }
    }

    override func cleanup() {
        cleanupSensors()
        timers.cancel(id + ".Access.Unlock")
        if let stream, stream.isRecording {
            Task { await stream.updateRecordingActive(false) }
        }
        livestream.shutdown()
        stream?.shutdown()
        stream?.removeController()
        // The streaming delegate holds the camera: let both go.
        stream = nil
        super.cleanup()
    }

    /// The optional characteristics of the motion sensor: StatusActive, and StatusTampered with tamper
    /// detection on.
    var motionSensorCharacteristics: [CharacteristicType] {
        hasTamperDetection ? [.statusActive, .statusTampered] : [.statusActive]
    }

    var hasTamperDetection: Bool {
        ufp.feature("hasTamperDetection") && ufp.json.bool("smartDetectSettings.enableTamperDetection")
    }

    // MARK: Events

    func eventHandler(_ packet: ProtectEventPacket) async {
        let payload = packet.payload
        let has: ([String]) -> Bool = { keys in keys.contains { payload.has($0) } }
        if has(["channels", "videoCodec"]) { await configureVideo() }
        if has(["lastMotion"]) {
            // With HKSV recording, or without smart detection, every motion counts; else smart events do.
            if stream?.isRecording == true || (ufp.smartDetectAudioTypes.isEmpty && ufp.smartDetectTypes.isEmpty) || !hints.smartDetect {
                nvr.events.motionEventHandler(self)
            }
        }
        if has(["lastRing"]) { nvr.events.doorbellEventHandler(self, lastRing: payload.double("lastRing")) }
        if hints.smartDetect {
            var metadata = payload.at("metadata")
            if let thumbnails = metadata?.at("detectedThumbnails")?.arrayValue {
                metadata = metadata?.setting("detectedThumbnails", .array(thumbnails.filter { $0.string("type") != "motion" }))
            }
            let types = payload.strings("smartDetectTypes")
            if !types.isEmpty || !(metadata?.array("detectedThumbnails").isEmpty ?? true) {
                nvr.events.motionEventHandler(self, detectedObjects: types, metadata: metadata)
            }
        }
        if has(["smartDetectSettings"]) {
            configureTamperDetection()
            await accessory.publish()
        }
        if has(["isConnected", "ispSettings", "name", "ledSettings", "recordingSettings"]) { updateDevice() }
    }

    func addEventHandler(_ packet: ProtectEventPacket) async {
        let payload = packet.payload
        // A UniFi Access door opened from Protect.
        if packet.modelKey == "event", payload.string("metadata.action") == "open_door", payload.bool("metadata.openSuccess") {
            guard let lock = accessory.service(.lockMechanism, subtype: ProtectReservedNames.lockAccess) else { return }
            lock[.lockTargetState]?.value = .int(HAPConstants.LockTargetState.unsecured)
            lock[.lockCurrentState]?.value = .int(HAPConstants.LockCurrentState.unsecured)
            log.info("Unlocked.")
            timers.reset(id + ".Access.Unlock", after: 2000) {
                lock[.lockTargetState]?.value = .int(HAPConstants.LockTargetState.secured)
                lock[.lockCurrentState]?.value = .int(HAPConstants.LockCurrentState.secured)
            }
            return
        }
        if !isTampered, payload.string("type") == "smartDetectTamper" {
            isTampered = true
            accessory.firstService(.motionSensor)?[.statusTampered]?.value = .int(1)
            log.info("Tamper event detected. To clear the indicator, toggle tamper detection in the Protect web UI or restart Homeswift.")
        }
        let type = payload.string("type") ?? ""
        let types = payload.strings("smartDetectTypes")
        let isSmart = packet.modelKey == "smartDetectObject"
            || (packet.modelKey == "event" && ["smartDetectLine", "smartDetectZone"].contains(type) && type != "motion" && !types.isEmpty)
        guard hints.smartDetect, isSmart else { return }
        nvr.events.motionEventHandler(self, detectedObjects: packet.modelKey == "smartDetectObject" ? [type] : types, metadata: payload.at("metadata"))
    }

    // MARK: Doorbell switches

    /// A switch that mutes the doorbell's ring in HomeKit (`Doorbell.Mute`).
    @discardableResult
    func configureDoorbellMuteSwitch() -> Bool {
        guard accessory.valid(.switch, hasFeature("Doorbell.Mute"), subtype: ProtectReservedNames.switchDoorbellMute), accessory.firstService(.doorbell) != nil else {
            accessory.valid(.switch, false, subtype: ProtectReservedNames.switchDoorbellMute)
            context.doorbellMuted = nil
            return false
        }
        let service = accessory.acquire(.switch, name: accessoryName + " Doorbell Mute", subtype: ProtectReservedNames.switchDoorbellMute)
        service[.on]?.onRead { [weak self] in .bool(await self?.context.doorbellMuted ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let muted = value.boolValue ?? false
            self.context.doorbellMuted = muted
            self.log.info("Doorbell chime \(muted ? "disabled" : "enabled").")
        }
        service[.on]?.value = .bool(context.doorbellMuted ?? false)
        log.info("Enabling doorbell mute switch.")
        return true
    }

    /// A switch that rings the doorbell, for automations (`Doorbell.Trigger`); a camera that is not a
    /// doorbell gets a doorbell service for it.
    @discardableResult
    func configureDoorbellTrigger() -> Bool {
        let doorbell = accessory.firstService(.doorbell)
        guard accessory.valid(.switch, hasFeature("Doorbell.Trigger"), subtype: ProtectReservedNames.switchDoorbellTrigger) else {
            if !ufp.feature("isDoorbell"), let doorbell { accessory.remove(doorbell) }
            return false
        }
        if doorbell == nil { configureVideoDoorbell() }
        let trigger = accessory.acquire(.switch, name: accessoryName + " Doorbell Trigger", subtype: ProtectReservedNames.switchDoorbellTrigger)
        trigger[.on]?.onRead { [weak self] in .bool(await self?.isRinging ?? false) }
        trigger[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            if value.boolValue == true {
                self.nvr.events.doorbellEventHandler(self, lastRing: Date().timeIntervalSince1970 * 1000)
                self.log.info("Doorbell ring event triggered.")
            } else if self.isRinging {
                self.timers.after(ProtectSettings.homeKitUpdateDelay) { trigger[.on]?.value = .bool(true) }
            }
        }
        trigger[.on]?.value = .bool(false)
        log.info("Enabling doorbell automation trigger.")
        return true
    }

    /// The doorbell service, primary as HomeKit requires.
    @discardableResult
    func configureVideoDoorbell() -> Bool {
        accessory.acquire(.doorbell, name: accessoryName, isPrimary: true)
        return true
    }

    // MARK: Crop, HKSV

    private func configureCrop() {
        guard hints.crop else { return }
        func clamp(_ value: Double?, _ fallback: Double) -> Double {
            guard let value, value >= 0, value <= 100 else { return fallback }
            return value
        }
        let height = clamp(getFeatureNumber("Video.Crop.Height") ?? 100, 100)
        let width = clamp(getFeatureNumber("Video.Crop.Width") ?? 100, 100)
        let x = clamp(getFeatureNumber("Video.Crop.X") ?? 0, 0)
        let y = clamp(getFeatureNumber("Video.Crop.Y") ?? 0, 0)
        func text(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
        log.info("Cropping the video stream to \(text(width))x\(text(height))% starting at \(text(x))x\(text(y))%.")
        hints.cropOptions = (height: height / 100, width: width / 100, x: x / 100, y: y / 100)
    }

    private func configureHksv() {
        if hasFeature("Debug.Video.HKSV.UseRtsp") {
            log.warning("Enabling RTSP-based HKSV events are for debugging purposes only and unsupported. It consumes more resources on both the Protect controller and the system running Homeswift.")
        }
        if isHksvCapable, hints.smartDetect {
            log.warning("WARNING: Smart motion detection and HomeKit Secure Video provide overlapping functionality. "
                + "Only HomeKit Secure Video, when event recording is enabled in the Home app, will be used to trigger motion event notifications for this camera."
                + (hints.smartDetectSensors ? " Smart motion contact sensors will continue to function using telemetry from UniFi Protect." : ""))
        }
    }

    /// A switch that turns HKSV event recording on and off (`Video.HKSV.Recording.Switch`).
    @discardableResult
    private func configureHksvRecordingSwitch() -> Bool {
        guard accessory.valid(.switch, hasFeature("Video.HKSV.Recording.Switch"), subtype: ProtectReservedNames.switchHKSVRecording) else {
            context.hksvRecordingDisabled = nil
            return false
        }
        let service = accessory.acquire(.switch, name: accessoryName + " HKSV Recording", subtype: ProtectReservedNames.switchHKSVRecording)
        service[.on]?.onRead { [weak self] in .bool(!(await self?.context.hksvRecordingDisabled ?? false)) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if self.context.hksvRecordingDisabled != !on { self.log.info("HKSV event recording \(on ? "enabled" : "disabled").") }
            self.context.hksvRecordingDisabled = !on
        }
        service[.on]?.value = .bool(!(context.hksvRecordingDisabled ?? false))
        log.info("Enabling HKSV recording switch.")
        return true
    }

    // MARK: MQTT

    func configureMqtt() {
        subscribeGet("rtsp", "RTSP information") { [weak self] in
            guard let self else { return "{}" }
            var urls: [String: JSONValue] = [:]
            let host = self.nvr.config.overrideAddress ?? self.ufp.connectionHost ?? self.nvr.ufp.string("host") ?? ""
            let port = self.nvr.ufp.int("ports.rtsp").map(String.init) ?? ""
            for channel in self.ufp.channels where channel.isRtspEnabled {
                urls[channel.name] = .string("rtsps://\(host):\(port)/\(channel.rtspAlias)?enableSrtp")
            }
            return JSONValue.object(urls).text()
        }
        subscribeSet("snapshot", "snapshot trigger") { [weak self] value, _ in
            guard value == "true" else { return }
            await self?.stream?.handleSnapshotRequest()
        }
        if ufp.feature("isDoorbell") || hasFeature("Doorbell.Trigger") {
            subscribeSet("doorbell", "doorbell ring trigger") { [weak self] value, _ in
                guard value == "true", let self else { return }
                self.nvr.events.doorbellEventHandler(self, lastRing: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    /// Refreshes the values that follow the camera's state.
    func updateDevice() {
        updateSensors()
        updateControls()
    }

    // MARK: Streams

    /// The stream for a livestream of this size (`Video.Stream.Only.*` wins).
    func findRtsp(width: Int, height: Int, biasHigher: Bool = false, maxPixels: Int? = nil) -> RtspEntry? {
        RtspSelection.find(rtspEntries, width: width, height: height, options: .init(biasHigher: biasHigher, preferred: hints.streamingDefault, maxPixels: maxPixels))
    }

    /// The stream for an HKSV recording of this size: the next higher one, or `Video.HKSV.Record.Only.*`.
    func findRecordingRtsp(width: Int, height: Int) -> RtspEntry? {
        RtspSelection.find(rtspEntries, width: width, height: height, options: .init(biasHigher: true, preferred: hints.recordingDefault))
    }

    // MARK: Properties

    /// HKSV works with native cameras, and third-party cameras paired with an AI Port.
    var isHksvCapable: Bool {
        (!ufp.isThirdPartyCamera && !ufp.isAdoptedByAccessApp) || (ufp.isThirdPartyCamera && ufp.isPairedWithAiPort)
    }

    /// The FFmpeg audio filters, with `Audio.Filter.Noise`.
    var audioFilters: [String] {
        guard hasFeature("Audio.Filter.Noise") else { return [] }
        return buildAudioFilterPipeline(
            fftNr: getFeatureFloat("Audio.Filter.Noise.FftNr") ?? Double(ProtectSettings.ffmpegAudioFilterFFTNR),
            highpass: getFeatureNumber("Audio.Filter.Noise.HighPass"), lowpass: getFeatureNumber("Audio.Filter.Noise.LowPass"))
    }
}
