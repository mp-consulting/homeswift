import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// One channel as an external camera accessory (section 6): the camera and its doorbell, the motion and AI sensors, the
/// floodlight, siren, IR lights and battery, each set only when its value changes.
final class ReolinkCamera: @unchecked Sendable {
    /// The sizes HomeKit may ask for, up to the main stream's.
    static let resolutions: [VideoResolution] = [
        VideoResolution(320, 180, 30), VideoResolution(320, 240, 15), VideoResolution(320, 240, 30), VideoResolution(480, 270, 30),
        VideoResolution(480, 360, 30), VideoResolution(640, 360, 30), VideoResolution(640, 480, 30), VideoResolution(1280, 720, 30),
        VideoResolution(1280, 960, 30), VideoResolution(1920, 1080, 30), VideoResolution(1600, 1200, 30),
    ]
    /// A detection stays on at least this long after the device clears it (6.3).
    static let motionHold: Double = 2
    /// The siren switch turns itself off after this long (6.6).
    static let sirenReset: Double = 60
    /// A momentary switch (a preset, a chime) turns itself off after this long.
    static let momentaryReset: Double = 1

    let accessory: Accessory
    let controller: CameraController
    let streamer: ReolinkStreamer
    let recorder: ReolinkRecorder?
    /// Two-way talk, when the camera was published with it (ReolinkTalk.md).
    let talker: ReolinkTalker?
    let channel: Int
    private let name: String
    private let log: Logger
    private let timing: ReolinkTiming
    private let ringThrottle: Double
    private let motion: Service?
    private let aiServices: [String: Service]
    private let doorbell: Service?
    private let floodlight: Service?
    private let siren: Service?
    private let ir: Service?
    private let battery: Service?
    /// "Go to <preset>" switches, by preset id.
    private let presets: [Int: Service]
    private let patrol: Service?
    private let privacy: Service?
    /// Recording on the device's own storage.
    private let recordingSwitch: Service?
    /// A momentary switch per paired Reolink Chime, by id.
    private let chimes: [Int: Service]
    /// HomeKit's Camera Active (with HomeKit Secure Video): off while privacy mode is on, and the other way round.
    private let cameraActive: Characteristic?
    private let sensors: [Service]

    private struct State {
        var last: ReolinkChannelState?
        var visitor = false
        var lastRing: ContinuousClock.Instant?
        var holds: [String: Task<Void, Never>] = [:]
        var sirenReset: Task<Void, Never>?
        var momentary: [String: Task<Void, Never>] = [:]
        var adaptiveLighting: AdaptiveLightingController?
        var lastColourWrite: ContinuousClock.Instant?
    }

    private let state = NIOLockedValueBox(State())

    struct Writes: Sendable {
        var floodlight: @Sendable (_ on: Bool?, _ brightness: Int?) async throws -> Void
        var siren: @Sendable (_ on: Bool) async throws -> Void
        var ir: @Sendable (_ on: Bool) async throws -> Void
        var goToPreset: @Sendable (_ id: Int) async throws -> Void
        var privacy: @Sendable (_ on: Bool) async throws -> Void
        var floodlightColour: @Sendable (_ mireds: Int) async throws -> Void
        var chime: @Sendable (_ id: Int) async throws -> Void
        var recording: @Sendable (_ on: Bool) async throws -> Void
        var patrol: @Sendable (_ on: Bool) async throws -> Void
    }

    /// The services a channel gets, from what it supports and its options.
    init(id: String, channel info: ReolinkChannel, host: ReolinkHostInfo, options: ReolinkPlugin.CameraOptions, canWrite: Bool,
         streamer: ReolinkStreamer, recorder: ReolinkRecorder?, writes: Writes, log: Logger, timing: ReolinkTiming, talker: ReolinkTalker? = nil) throws {
        self.talker = talker
        let name = options.name ?? info.name
        self.name = name
        self.channel = info.channel
        self.log = log
        self.timing = timing
        self.streamer = streamer
        self.recorder = recorder
        ringThrottle = Double(options.ringThrottleSeconds)

        let motion = (options.motionSensor ?? true) && info.motion ? Service(.motionSensor, name: "\(name) Motion", subtype: "motion", optional: [.statusActive]) : nil
        self.motion = motion
        let wanted = Set(options.aiSensors ?? ReolinkChannel.aiSensors.map(\.subtype))
        var ai: [String: Service] = [:]
        for sensor in ReolinkChannel.aiSensors where info.aiTypes.contains(sensor.type) && wanted.contains(sensor.subtype) {
            ai[sensor.type] = Service(.motionSensor, name: "\(name) \(sensor.title)", subtype: sensor.subtype, optional: [.statusActive])
        }
        aiServices = ai
        let isDoorbell = options.doorbell ?? info.doorbell
        let doorbell = isDoorbell ? Service(.doorbell, name: name, subtype: "doorbell", isPrimary: true) : nil
        self.doorbell = doorbell
        let floodlight = (options.floodlight ?? true) && info.floodlight
            ? Service(.lightbulb, name: "\(name) Floodlight", subtype: "floodlight",
                      optional: [.brightness] + (info.floodlightColour ? [.colorTemperature.with(minValue: Double(ReolinkFloodlight.miredRange.lowerBound), maxValue: Double(ReolinkFloodlight.miredRange.upperBound))] : []))
            : nil
        self.floodlight = floodlight
        // A siren sounds through the house: a security control, as IMOU's is, so MCP clients confirm before they change it.
        let siren = options.siren && info.siren ? Service(.switch, name: "\(name) Siren", subtype: "siren") : nil
        siren?.characteristic(.on).securityControl()
        self.siren = siren
        let ir = options.irLights && info.irLights ? Service(.switch, name: "\(name) Infrared", subtype: "ir") : nil
        self.ir = ir
        let battery = info.battery ? Service(.battery, name: "\(name) Battery", subtype: "battery", optional: [.batteryLevel, .chargingState]) : nil
        self.battery = battery
        // PTZ (addendum B.7): HomeKit has no PTZ service; presets and the patrol are switches, when asked for.
        var presets: [Int: Service] = [:]
        if options.presetSwitches, let ptz = info.ptz {
            for preset in ptz.presets { presets[preset.id] = Service(.switch, name: "\(name) Go to \(preset.name)", subtype: "preset\(preset.id)") }
        }
        self.presets = presets
        let patrol = options.patrolSwitch && info.ptz?.patrols.isEmpty == false ? Service(.switch, name: "\(name) Patrol", subtype: "patrol") : nil
        self.patrol = patrol
        // Privacy mode blinds the camera: a security control, so MCP clients confirm before they change it.
        let privacy = info.privacy && options.privacySwitch ? Service(.switch, name: "\(name) Privacy", subtype: "privacy") : nil
        privacy?.characteristic(.on).securityControl()
        self.privacy = privacy
        // Recording off blinds the camera's own storage: a security control, so MCP clients confirm.
        let recordingSwitch = options.recordingSwitch && info.recording ? Service(.switch, name: "\(name) Recording", subtype: "recording") : nil
        recordingSwitch?.characteristic(.on).securityControl()
        self.recordingSwitch = recordingSwitch
        var chimes: [Int: Service] = [:]
        if options.chimeSwitch {
            for chime in info.chimes { chimes[chime.id] = Service(.switch, name: "\(name) Chime \(chime.name)", subtype: "chime\(chime.id)") }
        }
        self.chimes = chimes
        sensors = [motion].compactMap { $0 } + ReolinkChannel.aiSensors.compactMap { ai[$0.type] }

        let streaming = CameraStreamingOptions(
            supportedCryptoSuites: [.aesCM128HMACSHA1_80],
            video: VideoStreamingOptions(codec: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]),
                                         resolutions: Self.resolutions(upTo: info.main)),
            audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])], twoWayAudio: talker != nil))
        let controllerOptions = CameraControllerOptions(
            cameraStreamCount: options.maxStreams, delegate: streamer, streamingOptions: streaming,
            recording: recorder.map { CameraRecordingSetup(options: ReolinkRecorder.options(resolutions: Self.resolutions(upTo: info.main)), delegate: $0) },
            sensors: motion.map { CameraSensorOptions(motion: .service($0)) })
        if let doorbell {
            controller = try DoorbellController(controllerOptions, name: name, externalDoorbellService: doorbell, logger: log)
        } else {
            controller = try CameraController(controllerOptions, logger: log)
        }
        let serial = host.isMultiChannel ? (info.uid ?? "\(host.serial)-ch\(info.channel)") : host.serial
        accessory = Accessory(
            id: id, name: name, manufacturer: "Reolink", model: info.model.nonEmptyText ?? "Reolink", serialNumber: serial.nonEmptyText ?? id,
            firmwareRevision: info.firmware, category: isDoorbell ? .videoDoorbell : .ipCamera,
            services: [doorbell].compactMap { $0 } + sensors + [floodlight, siren, ir, battery].compactMap { $0 }
                + presets.keys.sorted().compactMap { presets[$0] } + [patrol, privacy, recordingSwitch].compactMap { $0 } + chimes.keys.sorted().compactMap { chimes[$0] },
            onIdentify: { [log] in log.info("\(name): identify requested.") })
        accessory.configureController(controller)
        cameraActive = info.privacy ? accessory.service(.cameraOperatingMode)?.characteristic(.homeKitCameraActive) : nil
        // It drives privacy mode too: a security control as the Privacy switch is, so no surface of the bridge writes it
        // unconfirmed.
        cameraActive?.securityControl()
        for service in sensors { service.characteristic(.motionDetected).value = false }

        // Writes (7.2): the value is kept optimistically, put back when the device refuses.
        func guarded(_ body: @escaping @Sendable (HAPValue) async throws -> Void) -> @Sendable (HAPValue) async throws -> Void {
            { value in
                guard canWrite else { throw HAPStatusError(.insufficientPrivileges) }
                do { try await body(value) } catch {
                    log.warning("\(name): the device refused the change: \(error)")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            }
        }
        if let floodlight {
            let lightGuard = LatestCallGuard(delay: timing.seconds(0.3))
            floodlight.characteristic(.on).onWrite(changesOnly: true, guarded { value in
                // Only the field that changes (4.4): a model that refuses `bright` still turns on and off.
                try await writes.floodlight(value.boolValue ?? false, nil)
            })
            floodlight.characteristic(.brightness).onWrite(changesOnly: true, guarded { value in
                guard let level = value.intValue else { return }
                guard await lightGuard() else { return }
                try await writes.floodlight(level > 0, level > 0 ? min(100, level) : nil)
            })
            if let colour = floodlight[.colorTemperature] {
                colour.value = .int(ReolinkFloodlight.mireds(kelvin: 4500))
                let colourGuard = LatestCallGuard(delay: timing.seconds(0.3))
                colour.onWrite(guarded { [weak self] value in
                    guard let mireds = value.intValue else { return }
                    // From the write on, reports are of the colour before it or its echo.
                    self?.state.withLockedValue { $0.lastColourWrite = .now }
                    guard await colourGuard() else { return }
                    try await writes.floodlightColour(min(ReolinkFloodlight.miredRange.upperBound, max(ReolinkFloodlight.miredRange.lowerBound, mireds)))
                })
            }
        }
        if let siren {
            siren.characteristic(.on).onWrite(changesOnly: true, guarded { [weak self] value in
                let on = value.boolValue ?? false
                try await writes.siren(on)
                self?.scheduleSirenReset(on)
            })
        }
        if let ir {
            ir.characteristic(.on).onWrite(changesOnly: true, guarded { value in try await writes.ir(value.boolValue ?? false) })
        }
        func momentary(_ service: Service, key: String, _ action: @escaping @Sendable () async throws -> Void) {
            service.characteristic(.on).value = false
            service.characteristic(.on).onWrite(guarded { [weak self, weak service] value in
                guard value.boolValue == true else { return }
                try await action()
                if let service { self?.resetMomentary(service, key: key) }
            })
        }
        for (id, service) in presets { momentary(service, key: "preset\(id)") { try await writes.goToPreset(id) } }
        for (id, service) in chimes { momentary(service, key: "chime\(id)") { try await writes.chime(id) } }
        /// A switch whose quick flips send the last only.
        func toggle(_ service: Service?, _ action: @escaping @Sendable (Bool) async throws -> Void) {
            guard let service else { return }
            let latest = LatestCallGuard(delay: timing.seconds(0.3))
            service.characteristic(.on).onWrite(changesOnly: true, guarded { value in
                guard await latest() else { return }
                try await action(value.boolValue ?? false)
            })
        }
        toggle(privacy, writes.privacy)
        toggle(recordingSwitch, writes.recording)
        toggle(patrol, writes.patrol)
        if let cameraActive {
            // The Home app's camera off is privacy mode on. The value shown follows the device (`apply`).
            cameraActive.observe { [log, name, weak cameraActive] change in
                guard change.reason == .write, change.oldValue != change.newValue, let active = change.newValue.intValue else { return }
                Task {
                    do { try await writes.privacy(active == 0) } catch {
                        log.warning("\(name): the device refused privacy mode: \(error)")
                        cameraActive?.value = change.oldValue
                    }
                }
            }
        }
    }

    /// Turns a momentary switch off again, `momentaryReset` after it went on.
    private func resetMomentary(_ service: Service, key: String) {
        let delay = timing.seconds(Self.momentaryReset)
        let task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            service.characteristic(.on).value = false
        }
        state.withLockedValue { $0.momentary.updateValue(task, forKey: key) }?.cancel()
    }

    static func resolutions(upTo main: ReolinkStream) -> [VideoResolution] {
        let fitting = resolutions.filter { $0.width <= max(main.width, 640) && $0.height <= max(main.height, 360) }
        return fitting.isEmpty ? resolutions : fitting
    }

    func start() async {
        await streamer.attach(controller)
        await recorder?.start()
    }

    func stop() async {
        state.withLockedValue { state in
            state.holds.values.forEach { $0.cancel() }
            state.sirenReset?.cancel()
            state.momentary.values.forEach { $0.cancel() }
        }
        recorder?.shutdown()
        await streamer.stopAll()
        controller.destroy()
    }

    // MARK: State to HomeKit

    /// Sets what changed since the last state.
    func apply(_ new: ReolinkChannelState) {
        let previous = state.withLockedValue { state -> ReolinkChannelState? in
            defer { state.last = new }
            return state.last
        }
        if previous?.online != new.online {
            for service in sensors { service.characteristic(.statusActive).value = .bool(new.online) }
            accessory.isUnavailable = !new.online
        }
        if let motion, previous?.motion != new.motion { detected(motion, key: "motion", new.motion) }
        for (type, service) in aiServices {
            let value = new.ai[type] ?? false
            if (previous?.ai[type] ?? false) != value || previous == nil { detected(service, key: type, value) }
        }
        if new.visitor != state.withLockedValue({ $0.visitor }) {
            state.withLockedValue { $0.visitor = new.visitor }
            if new.visitor { ring() }
        }
        if let floodlight {
            if let on = new.floodlightOn, previous?.floodlightOn != on { floodlight.characteristic(.on).value = .bool(on) }
            if let level = new.floodlightBrightness, previous?.floodlightBrightness != level, let brightness = floodlight[.brightness], level > 0 {
                brightness.value = .int(level)
            }
            if let mireds = new.floodlightMireds, previous?.floodlightMireds != mireds, let colour = floodlight[.colorTemperature] {
                reportColour(mireds, to: colour)
            }
        }
        if let siren, let playing = new.sirenPlaying, previous?.sirenPlaying != playing {
            siren.characteristic(.on).value = .bool(playing)
            scheduleSirenReset(playing)
        }
        /// A switch's On, when the device reported a new value.
        func reflect(_ service: Service?, _ key: KeyPath<ReolinkChannelState, Bool?>) {
            guard let service, let on = new[keyPath: key], previous?[keyPath: key] != on else { return }
            service.characteristic(.on).value = .bool(on)
        }
        reflect(ir, \.irOn)
        reflect(patrol, \.patrolling)
        reflect(recordingSwitch, \.recordingOn)
        if let on = new.privacy, previous?.privacy != on {
            privacy?.characteristic(.on).value = .bool(on)
            cameraActive?.value = .int(on ? 0 : 1)
        }
        if let battery, let percent = new.batteryPercent,
           previous?.batteryPercent != percent || previous?.charging != new.charging || previous?.batteryLow != new.batteryLow {
            battery.characteristic(.batteryLevel).value = .int(percent)
            battery.characteristic(.statusLowBattery).value = .int(percent < 20 || new.batteryLow == true ? 1 : 0)
            battery.characteristic(.chargingState).value = .int(new.charging == true ? 1 : 0)
        }
    }

    /// Adaptive Lighting of the floodlight (with Brightness and Color Temperature), set by the plugin before the
    /// accessory is published; kept here, as the service holds it weakly.
    var adaptiveLighting: AdaptiveLightingController? {
        get { state.withLockedValue { $0.adaptiveLighting } }
        set { state.withLockedValue { $0.adaptiveLighting = newValue } }
    }

    /// How long after the bridge's own colour write a report is taken as its echo.
    static let colourEcho: Double = 10

    /// A colour the device reports: shown, and Adaptive Lighting turned off when it was set elsewhere (the Reolink app),
    /// not when it is the echo of the bridge's own write.
    /// Soon after the bridge's own colour write, a report is its echo, or older: what was written stays shown.
    var isColourEchoWindowOpen: Bool {
        guard let written = state.withLockedValue({ $0.lastColourWrite }) else { return false }
        return ContinuousClock.now - written < timing.seconds(Self.colourEcho)
    }

    private func reportColour(_ mireds: Int, to colour: Characteristic) {
        if isColourEchoWindowOpen { return }
        let adaptive = state.withLockedValue { $0.adaptiveLighting }
        adaptive?.disableIfChangedElsewhere(mireds: mireds)
        colour.value = .int(mireds)
    }

    /// A detection on at once; off no sooner than `motionHold` after it went on.
    private func detected(_ service: Service, key: String, _ value: Bool) {
        let characteristic = service.characteristic(.motionDetected)
        state.withLockedValue { $0.holds.removeValue(forKey: key) }?.cancel()
        if value {
            characteristic.value = true
            let hold = timing.seconds(Self.motionHold)
            let task = Task { _ = try? await Task.sleep(for: hold) }
            state.withLockedValue { $0.holds["\(key).on"] = task }
            return
        }
        let onHold = state.withLockedValue { $0.holds.removeValue(forKey: "\(key).on") }
        guard let onHold else {
            characteristic.value = false
            return
        }
        let task = Task {
            await onHold.value
            guard !Task.isCancelled else { return }
            characteristic.value = false
        }
        state.withLockedValue { $0.holds[key] = task }
    }

    /// The doorbell's rising edge (6.4), at most once per `ringThrottleSeconds`.
    private func ring() {
        let now = ContinuousClock.now
        let throttle = timing.seconds(ringThrottle)
        let passes = state.withLockedValue { state -> Bool in
            if let last = state.lastRing, now - last < throttle { return false }
            state.lastRing = now
            return true
        }
        guard passes, let doorbell = controller as? DoorbellController else { return }
        log.info("\(name): doorbell pressed.")
        doorbell.ringDoorbell()
    }

    private func scheduleSirenReset(_ on: Bool) {
        let siren = siren
        let delay = timing.seconds(Self.sirenReset)
        let task: Task<Void, Never>? = on ? Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            siren?.characteristic(.on).value = false
        } : nil
        state.withLockedValue { state in
            state.sirenReset?.cancel()
            state.sirenReset = task
        }
    }

    var services: (motion: Service?, ai: [String: Service], doorbell: Service?, floodlight: Service?, siren: Service?, ir: Service?, battery: Service?) {
        (motion, aiServices, doorbell, floodlight, siren, ir, battery)
    }

    var ptzServices: (presets: [Int: Service], patrol: Service?) { (presets, patrol) }
    var privacyControls: (privacy: Service?, cameraActive: Characteristic?) { (privacy, cameraActive) }
    var chimeServices: [Int: Service] { chimes }
    var recordingService: Service? { recordingSwitch }
}
