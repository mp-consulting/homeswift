import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Runs one write at a time for a device, in order (section 7.3): a second toggle waits for the first.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            _ = await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// One camera channel on its own accessory (docs/clean-room/Imou.md, section 6): its services, what it knows of the device,
/// and where its video, snapshots and events come from: the LAN first, the cloud when the LAN cannot.
actor ImouCamera {
    /// The plugin's timers and waits; tests shorten them.
    struct Timing: Sendable {
        var scale: Double = 1
        var snapshotWait: Double = 3
        var wakeWait: Double = 4
        var dormantRetryWait: Double = 5

        func duration(_ seconds: Double) -> Duration { .milliseconds(Int((seconds * 1000 * scale).rounded())) }
    }

    /// How long a snapshot answers the requests that follow: a local one 3 seconds, a cloud one a minute (section 6.2).
    static let localSnapshotWindow: Double = 3
    static let cloudSnapshotWindow: Double = 60
    /// The siren goes back to off on its own after this long (section 6.5).
    static let sirenHold: Double = 15
    /// After three local failures in a row, the LAN is tried again only every five minutes (section 7.5).
    static let localCooldown: Double = 300
    /// What a read of a switch answers for a camera without it (addendum, section 2.1).
    static let unsupportedCodes: Set<String> = ["DV1019", "DV1026"]

    struct Services {
        let motion: Service
        let privacy: Service?
        let motionDetection: Service?
        let siren: Service?
        let light: Service?
        let battery: Service?
        /// Human detection, the status light (without HomeKit Secure Video), the siren and the light on alarm.
        let toggles: [Toggle]
        let nightVision: Service?
    }

    struct Toggle {
        let spec: ImouSwitch
        let service: Service
    }

    /// The switches of the addendum's table (section 2.2) a channel's abilities and settings give it; the status light
    /// is the Camera Operating Mode's indicator instead when HomeKit Secure Video is on (`indicator`). enableTypes the
    /// cloud said the camera lacks are left out.
    static func switches(features: ImouFeatures, settings: ImouPlugin.CameraSettings, unsupported: Set<String>, indicator: Bool) -> [ImouSwitch] {
        var found: [ImouSwitch] = []
        if settings.personDetectSwitch { found.append(ImouSwitch(subtype: "personDetection", label: "Person Detection", enableTypes: features.humanDetection)) }
        if settings.statusLightSwitch, features.statusLight, !indicator { found.append(.statusLight) }
        if settings.linkageSirenSwitch, features.linkageSiren {
            found.append(ImouSwitch(subtype: "alarmSiren", label: "Siren on Alarm", enableTypes: ["linkageSiren"]))
        }
        if settings.linkageLightSwitch, features.linkageLight {
            found.append(ImouSwitch(subtype: "alarmLight", label: "Light on Alarm", enableTypes: ["linkageWhiteLight"]))
        }
        return found.compactMap { spec in
            var spec = spec
            spec.enableTypes.removeAll { unsupported.contains($0) }
            return spec.enableTypes.isEmpty ? nil : spec
        }
    }

    nonisolated let accessoryID: String
    nonisolated let deviceID: String
    nonisolated let channel: ImouChannel
    nonisolated let name: String
    nonisolated let features: ImouFeatures
    nonisolated let settings: ImouPlugin.CameraSettings
    nonisolated let services: Services
    nonisolated let multiChannel: Bool
    let cloud: ImouCloud?
    let local: DahuaClient?
    private let queue: SerialQueue
    private let download: any HTTPSending
    private let ffmpeg: RTSPCameraFFmpeg?
    private let streamID: Int
    private let timing: Timing
    private let log: Logger
    private(set) var accessory: Accessory?
    private(set) var controller: CameraController?
    private(set) var streamer: RTSPCameraStreamer?
    private(set) var recorder: RTSPCameraRecorder?

    private(set) var online: ImouOnline = .online
    private(set) var privacyOn = false
    /// HomeKit Camera Active, on the Camera Operating Mode of a camera with HomeKit Secure Video: kept the inverse of
    /// privacy (addendum, section 5).
    private var cameraActive: Characteristic?
    /// The status light as the Camera Operating Mode's indicator.
    private var indicator: (spec: ImouSwitch, characteristic: Characteristic)?
    /// enableTypes the cloud said this camera lacks, not read again; `takeUnsupported` hands the new ones to the plugin.
    private var unsupported: Set<String>
    private var newlyUnsupported: Set<String> = []
    /// The status light read with `breathingLightStatus`: the camera does not answer its enableType.
    private var legacyStatusLight = false
    private(set) var nightVisionMode: String?
    private(set) var nightVisionModes: [String] = []
    /// Lets the last of quick successive writes to a switch through: those it overtook while queued are never sent.
    private let writes = LatestCallGuard(delay: .zero)
    private var snapshot: (data: Data, at: ContinuousClock.Instant, cloud: Bool)?
    private var fetching: Task<Data, any Error>?
    private var lastCloudSnapshot: ContinuousClock.Instant?
    private var localFailures = 0
    private var localRetryAt: ContinuousClock.Instant?
    /// Whether the local event stream is connected: nil before it first tried, or when there is none.
    private(set) var localEventsUp: Bool?
    private var lastAlarm: String?
    /// The timers that turn motion and the siren back off: one each, replaced by the next event or write.
    private var motionHold: Task<Void, Never>?
    private var sirenHold: Task<Void, Never>?
    private var silentSensorLogged = false

    init(accessoryID: String, deviceID: String, channel: ImouChannel, name: String, features: ImouFeatures, settings: ImouPlugin.CameraSettings,
         multiChannel: Bool, cloud: ImouCloud?, local: DahuaClient?, queue: SerialQueue, download: any HTTPSending, ffmpeg: RTSPCameraFFmpeg?,
         streamID: Int, timing: Timing, log: Logger, unsupported: Set<String> = [], recording: Bool = false) {
        self.unsupported = unsupported
        self.accessoryID = accessoryID
        self.deviceID = deviceID
        self.channel = channel
        self.name = name
        self.features = features
        self.settings = settings
        self.multiChannel = multiChannel
        self.cloud = cloud
        self.local = local
        self.queue = queue
        self.download = download
        self.ffmpeg = ffmpeg
        self.streamID = streamID
        self.timing = timing
        self.log = log
        let motion = Service(.motionSensor, name: name, optional: [.statusActive])
        motion.characteristic(.statusActive).value = .bool(true)
        let cloudControls = cloud != nil
        func control(_ wanted: Bool, _ type: ServiceType, _ label: String, _ subtype: String) -> Service? {
            wanted && cloudControls ? Service(type, name: "\(name) \(label)", subtype: subtype) : nil
        }
        services = Services(
            motion: motion,
            privacy: control(features.privacy && settings.privacySwitch, .switch, "Privacy", "privacy"),
            motionDetection: control(features.motionDetectSwitch && settings.motionDetectSwitch, .switch, "Motion Detection", "motionDetection"),
            siren: control(features.siren && settings.sirenSwitch, .switch, "Siren", "siren"),
            light: control(features.whiteLight && settings.lightSwitch, .lightbulb, "Spotlight", "spotlight"),
            battery: features.battery && cloudControls ? Service(.battery, name: "\(name) Battery", subtype: "battery") : nil,
            toggles: cloudControls
                ? Self.switches(features: features, settings: settings, unsupported: unsupported, indicator: recording).map {
                    Toggle(spec: $0, service: Service(.switch, name: "\(name) \($0.label)", subtype: $0.subtype))
                } : [],
            nightVision: control(features.nightVision && settings.nightVisionSwitch && !unsupported.contains("nightVision"), .switch, "Night Vision", "nightVision"))
        // The siren unlocks nothing, but it is loud: MCP and the Assistant change it only after the user confirms.
        services.siren?.characteristic(.on).isSecurityControl = true
    }

    func attach(accessory: Accessory, controller: CameraController, streamer: RTSPCameraStreamer?, recorder: RTSPCameraRecorder?) {
        self.accessory = accessory
        self.controller = controller
        self.streamer = streamer
        self.recorder = recorder
    }

    /// The write handlers: each goes to the cloud, one at a time per device; the state is set at once and put back on a
    /// failure (sections 7.3 and 7.1.5).
    nonisolated func bindWrites() {
        services.privacy?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            try await self?.setPrivacy(value.boolValue ?? false)
        }
        services.motionDetection?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            try await self?.write("motionDetection", value.boolValue ?? false) { cloud, device, channel, on in
                try await cloud.setMotionDetection(device, channel: channel, on)
            }
        }
        services.light?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            try await self?.write("light", value.boolValue ?? false) { cloud, device, channel, on in
                try await cloud.setCameraStatus(device, channel: channel, "whiteLight", on)
            }
        }
        let multiChannel = multiChannel
        services.siren?.characteristic(.on).onWrite { [weak self] value in
            let on = value.boolValue ?? false
            try await self?.write("siren", on) { cloud, device, channel, on in
                try await cloud.siren(device, channel: channel, multiChannel: multiChannel, on)
            }
            await self?.sirenWritten(on)
        }
        for toggle in services.toggles {
            let spec = toggle.spec
            toggle.service.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
                try await self?.write(spec, value.boolValue ?? false)
            }
        }
        services.nightVision?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            guard let self else { return }
            try await self.setNightVision(mode: await self.nightVisionMode(on: value.boolValue ?? false))
        }
    }

    /// The Camera Operating Mode of a camera with HomeKit Secure Video, before it is published: HomeKit Camera Active kept
    /// the inverse of privacy, and the status light as its indicator (addendum, sections 2.8 and 5).
    func attach(operatingMode: Service) {
        guard cloud != nil else { return }
        if features.privacy {
            let active = operatingMode.characteristic(.homeKitCameraActive)
            cameraActive = active
            active.onWrite(changesOnly: true) { [weak self] value in
                // Only an admin turns the camera off in the Home app, as without this handler.
                try HAPRequestContext.requireAdmin()
                try await self?.setPrivacy((value.intValue ?? 1) == 0)
            }
        }
        if settings.statusLightSwitch, features.statusLight, !unsupported.contains("breathingLight") {
            let spec = ImouSwitch.statusLight
            let characteristic = operatingMode.characteristic(adding: .cameraOperatingModeIndicator)
            indicator = (spec, characteristic)
            characteristic.onWrite(changesOnly: true) { [weak self] value in
                try await self?.write(spec, value.boolValue ?? false)
            }
        }
    }

    /// Opens or closes the camera, from the Privacy switch or HomeKit Camera Active, and keeps the other in step.
    func setPrivacy(_ closed: Bool) async throws {
        try await write("privacy", closed) { cloud, device, channel, on in
            try await cloud.setCameraStatus(device, channel: channel, "closeCamera", on)
        }
        privacyChanged(closed)
    }

    /// A write to every enableType of a switch; it fails only when all of them fail.
    private func write(_ spec: ImouSwitch, _ on: Bool) async throws {
        try await write(spec.subtype, on) { cloud, device, channel, on in
            var failure: (any Error)?
            var sent = false
            for type in spec.enableTypes {
                do {
                    try await cloud.setCameraStatus(device, channel: spec.deviceLevel ? nil : channel, type, on)
                    sent = true
                } catch {
                    failure = error
                }
            }
            if !sent, let failure { throw failure }
        }
    }

    private func write(_ key: String, _ on: Bool, _ send: @escaping @Sendable (ImouCloud, String, String, Bool) async throws -> Void) async throws {
        guard let cloud else { throw HAPStatusError(.serviceCommunicationFailure) }
        let device = deviceID, channel = channel.id
        let sleeping = online == .sleeping
        let retryWait = timing.duration(timing.dormantRetryWait)
        let isLatest = writes.claim(key)
        do {
            try await queue.run {
                // A later write to the same switch came in while this one waited: only that one is sent.
                guard isLatest() else { return }
                do {
                    try await send(cloud, device, channel, on)
                } catch let error as ImouError where sleeping && error.isDormant {
                    // A sleeping camera: once more, after it had time to wake (section 7.4).
                    try await Task.sleep(for: retryWait)
                    try await send(cloud, device, channel, on)
                }
            }
        } catch {
            log.warning("\(name): could not change the camera: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
    }

    /// The mode the Night Vision switch sets: off, or the camera's smart mode (another of its modes without one).
    func nightVisionMode(on: Bool) -> String {
        guard on else { return "Off" }
        if nightVisionModes.isEmpty || nightVisionModes.contains("Intelligent") { return "Intelligent" }
        return nightVisionModes.first { $0 != "Off" } ?? "Intelligent"
    }

    private func privacyChanged(_ on: Bool) {
        privacyOn = on
        if let privacy = services.privacy { set(privacy.characteristic(.on), .bool(on)) }
        if let cameraActive { set(cameraActive, .int(on ? 0 : 1)) }
        updateStatusActive()
    }

    /// The siren's state cannot be read: it shows off again once it has had its time.
    private func sirenWritten(_ on: Bool) {
        sirenHold?.cancel()
        sirenHold = nil
        guard on else { return }
        let hold = timing.duration(Self.sirenHold)
        sirenHold = Task { [weak self] in
            guard (try? await Task.sleep(for: hold)) != nil else { return }
            await self?.sirenOff()
        }
    }

    /// Runs on the hold's task: a hold replaced meanwhile was cancelled and does nothing.
    private func sirenOff() {
        guard !Task.isCancelled else { return }
        services.siren?.characteristic(.on).value = false
    }

    // MARK: State from the cloud

    /// What a poll found: whether the device answers, and the switches it reads (section 7.1). A sleeping or offline camera
    /// keeps its last state: it is never woken for a poll. `extras` reads the switches beyond privacy, the light and motion
    /// detection: the plugin's quota governor leaves them out of some polls.
    func refresh(_ state: ImouOnline, battery level: Int? = nil, extras: Bool = true) async {
        online = state
        let reachable = state == .online || state == .sleeping
        updateStatusActive()
        if local == nil { accessory?.isUnavailable = !reachable }
        guard state == .online, let cloud else { return }
        if services.privacy != nil || cameraActive != nil, let on = try? await cloud.cameraStatus(deviceID, channel: channel.id, "closeCamera", polling: true) {
            privacyChanged(on)
        }
        if let light = services.light, let on = try? await cloud.cameraStatus(deviceID, channel: channel.id, "whiteLight", polling: true) {
            set(light.characteristic(.on), .bool(on))
        }
        if let detection = services.motionDetection {
            await read(.motionDetection, into: detection.characteristic(.on))
        }
        if let battery = services.battery, let level {
            set(battery.characteristic(.batteryLevel), .int(level))
            set(battery.characteristic(.statusLowBattery), .int(level < 20 ? 1 : 0))
        }
        guard extras else { return }
        for toggle in services.toggles { await read(toggle.spec, into: toggle.service.characteristic(.on)) }
        if let indicator { await read(indicator.spec, into: indicator.characteristic) }
        if let nightVision = services.nightVision, !unsupported.contains("nightVision") {
            do {
                let read = try await cloud.nightVision(deviceID, channel: channel.id)
                nightVisionModes = read.modes
                if let mode = read.mode {
                    nightVisionMode = mode
                    set(nightVision.characteristic(.on), .bool(mode.lowercased() != "off"))
                }
            } catch let error as ImouError where error.code.map(Self.unsupportedCodes.contains) == true {
                lacks("nightVision")
            } catch {}
        }
    }

    /// The reads a poll of an online camera makes: `base` every poll, `extras` those the quota governor may spread.
    func pollReads() -> (base: Int, extras: Int) {
        let base = (services.privacy != nil || cameraActive != nil ? 1 : 0) + (services.light != nil ? 1 : 0)
            + (services.motionDetection != nil ? ImouSwitch.motionDetection.enableTypes.count : 0)
        var extras = services.toggles.reduce(0) { $0 + $1.spec.enableTypes.count } + (indicator != nil ? 1 : 0)
        if services.nightVision != nil { extras += 1 }
        return (base, extras)
    }

    /// Reads a switch's enableTypes (addendum, section 2.1): on when any reads on, off only when all answered off; a failed
    /// read never turns it off. One the camera lacks is not read again.
    private func read(_ spec: ImouSwitch, into characteristic: Characteristic) async {
        guard let cloud else { return }
        var answers: [Bool?] = []
        for type in spec.enableTypes where !unsupported.contains(type) {
            do {
                if type == "breathingLight", legacyStatusLight {
                    answers.append(try await cloud.breathingLightStatus(deviceID))
                } else {
                    answers.append(try await cloud.cameraStatus(deviceID, channel: spec.deviceLevel ? nil : channel.id, type, polling: true))
                }
            } catch let error as ImouError where error.code.map(Self.unsupportedCodes.contains) == true {
                if type == "breathingLight", !legacyStatusLight, let on = try? await cloud.breathingLightStatus(deviceID) {
                    legacyStatusLight = true
                    answers.append(on)
                } else {
                    lacks(type)
                }
            } catch {
                answers.append(nil)
            }
        }
        if answers.contains(true) {
            set(characteristic, true)
        } else if !answers.isEmpty, answers.allSatisfy({ $0 == false }) {
            set(characteristic, false)
        }
    }

    private func lacks(_ type: String) {
        guard unsupported.insert(type).inserted else { return }
        newlyUnsupported.insert(type)
        log.info("\(name): the camera does not have \(type): it is no longer read, and its switch goes at the next start")
    }

    /// The enableTypes found missing since the last call, for the plugin to keep.
    func takeUnsupported() -> Set<String> {
        defer { newlyUnsupported = [] }
        return newlyUnsupported
    }

    // MARK: Actions

    /// What an action asked of a camera that cannot do it, or with values out of range.
    struct ActionRefused: Error, CustomStringConvertible {
        var description: String
    }

    /// Sets the night vision mode, one of those the camera has once they are known (addendum, section 2.6).
    func setNightVision(mode: String) async throws {
        guard let cloud, features.nightVision else { throw ActionRefused(description: "\(name) has no night vision modes") }
        guard nightVisionModes.isEmpty || nightVisionModes.contains(mode) else {
            throw ActionRefused(description: "\(name)'s modes are \(nightVisionModes.joined(separator: ", "))")
        }
        let device = deviceID, channel = channel.id
        let isLatest = writes.claim("nightVision")
        try await queue.run {
            guard isLatest() else { return }
            try await cloud.setNightVision(device, channel: channel, mode: mode)
        }
        nightVisionMode = mode
        if let service = services.nightVision { set(service.characteristic(.on), .bool(mode != "Off")) }
    }

    /// What the plugin's `cameras` action says of the camera.
    func summary() -> [String: JSONValue] {
        var switches: [String: JSONValue] = [:]
        let all = [services.privacy, services.motionDetection, services.siren, services.light, services.nightVision].compactMap { $0 } + services.toggles.map(\.service)
        for service in all { switches[service.subtype ?? ""] = service.characteristic(.on).value.boolValue.map(JSONValue.bool) ?? .null }
        if let indicator { switches["statusLight"] = indicator.characteristic.value.boolValue.map(JSONValue.bool) ?? .null }
        return [
            "accessoryId": .string(accessoryID), "deviceId": .string(deviceID), "channel": .string(channel.id), "name": .string(name),
            "online": .string("\(online)"), "privacy": .bool(privacyOn), "switches": .object(switches),
            "nightVision": features.nightVision ? ["mode": nightVisionMode.map(JSONValue.string) ?? .null, "modes": .array(nightVisionModes.map(JSONValue.string))] : .null,
        ]
    }

    /// The motion sensor is active while the camera answers (or its local events do) and is open.
    private func updateStatusActive() {
        let reachable = online == .online || online == .sleeping || localEventsUp == true
        set(services.motion.characteristic(.statusActive), .bool(reachable && !privacyOn))
    }

    /// Sets a value only when it changed, so HomeKit hears of changes alone.
    private func set(_ characteristic: Characteristic, _ value: HAPValue) {
        if characteristic.value != value { characteristic.value = value }
    }

    // MARK: Events

    /// What the event sources say: the LAN's event stream, or the cloud's newest alarm.
    enum Event: Sendable, Equatable {
        case motionStart, motionStop, motionPulse, ring
    }

    func handle(_ event: Event) {
        let motion = services.motion.characteristic(.motionDetected)
        switch event {
        case .motionStart, .motionPulse:
            motionHold?.cancel()
            set(motion, true)
            // A Start whose Stop never comes, or a pulse, ends after `motionTimeout`; each new one restarts it.
            let hold = timing.duration(Double(settings.motionTimeout))
            motionHold = Task { [weak self] in
                guard (try? await Task.sleep(for: hold)) != nil else { return }
                await self?.motionEnded()
            }
        case .motionStop:
            motionHold?.cancel()
            motionHold = nil
            set(motion, false)
        case .ring:
            (controller as? DoorbellController)?.ringDoorbell()
        }
    }

    private func motionEnded() {
        guard !Task.isCancelled else { return }
        set(services.motion.characteristic(.motionDetected), false)
    }

    /// A local event of this channel (section 5.3).
    func handle(local event: DahuaEvent) {
        if ImouEvents.localMotionCodes.contains(event.code) {
            switch event.action {
            case .start: handle(.motionStart)
            case .stop: handle(.motionStop)
            case .pulse: handle(.motionPulse)
            }
        } else if features.doorbell, event.code == "CallNoAnswered" ? event.action == .start
            : event.code == "BackKeyLight" && (event.data?["State"]?.saturatingIntValue == 1) {
            handle(.ring)
        }
    }

    /// The newest cloud alarm (section 5.1): one not seen before is a motion pulse, or a ring; the first is only noted.
    func handle(alarm: ImouAlarm) {
        let key = "\(alarm.id):\(alarm.time)"
        defer { lastAlarm = key }
        guard let last = lastAlarm, last != key else { return }
        let type = ImouEvents.normalized(alarm.messageType)
        if ImouEvents.motionMessages.contains(type) {
            handle(.motionPulse)
        } else if features.doorbell, ImouEvents.doorbellMessages.contains(type) {
            handle(.ring)
        }
    }

    func localEvents(up: Bool) {
        // The cloud's alarms seen before the stream came back are old news when it drops again: the first is only noted.
        if up { lastAlarm = nil }
        localEventsUp = up
        if cloud == nil { set(services.motion.characteristic(.statusActive), .bool(up)) }
    }

    /// The event source nobody has: the sensor never triggers, said once.
    func noteSilentSensor() {
        guard !silentSensorLogged else { return }
        silentSensorLogged = true
        log.info("\(name): no event source (no local address, and the cloud's alarms are not polled): its motion sensor never triggers")
    }

    /// Whether the cloud's alarms stand in for the local events now.
    func needsAlarmPolling(interval: Int?) -> Bool {
        guard cloud != nil, online != .offline, interval != 0 else { return false }
        if local != nil && settings.localEvents { return localEventsUp == false }
        return interval != nil
    }

    // MARK: Snapshots

    struct SnapshotUnavailable: Error, CustomStringConvertible {
        var description: String
    }

    /// The picture HomeKit asks for (section 6.2): the camera's CGI snapshot, a frame of its local sub stream, else the
    /// cloud's (slow, and costs quota: kept a minute). Requests while one is fetched share it. A camera closed or offline
    /// answers its last picture.
    func snapshotImage() async throws -> Data {
        if privacyOn || online == .offline {
            if let snapshot { return snapshot.data }
            throw SnapshotUnavailable(description: privacyOn ? "privacy mode is on" : "the camera is offline")
        }
        if let snapshot {
            let window = snapshot.cloud ? Self.cloudSnapshotWindow : Self.localSnapshotWindow
            if ContinuousClock.now - snapshot.at < timing.duration(window) { return snapshot.data }
        }
        if let fetching { return try await fetching.value }
        let task = Task { try await self.fetchSnapshot() }
        fetching = task
        defer { fetching = nil }
        return try await task.value
    }

    private func fetchSnapshot() async throws -> Data {
        if let local, usesLocal {
            do {
                let image = try await local.snapshot(channel: channel.localChannel)
                localSucceeded()
                snapshot = (image, .now, false)
                return image
            } catch {
                log.debug("\(name): no snapshot from the camera's CGI: \(error)")
                if let image = await frameFromStream() {
                    localSucceeded()
                    snapshot = (image, .now, false)
                    return image
                }
                localFailed()
            }
        }
        guard let cloud else {
            if let snapshot { return snapshot.data }
            throw SnapshotUnavailable(description: "the camera gave no snapshot")
        }
        // At most one cloud capture a second (section 6.2).
        if let lastCloudSnapshot, ContinuousClock.now - lastCloudSnapshot < timing.duration(1), let snapshot { return snapshot.data }
        lastCloudSnapshot = .now
        try await wakeIfSleeping()
        let url = try await cloud.snapshotURL(deviceID, channel: channel.id)
        try await Task.sleep(for: timing.duration(timing.snapshotWait))
        // The address's query is a credential: never logged.
        let response = try await download.send(HomeswiftNetwork.HTTPRequest(url: url, timeout: .seconds(30)))
        guard response.isSuccess, response.body.starts(with: [0xFF, 0xD8]) else {
            throw SnapshotUnavailable(description: "the cloud's snapshot did not download (HTTP \(response.status))")
        }
        snapshot = (response.body, .now, true)
        return response.body
    }

    /// One frame of the local sub stream, through FFmpeg; nil when FFmpeg cannot.
    private func frameFromStream() async -> Data? {
        guard let ffmpeg, let url = localURL(subStream: true) else { return nil }
        let input = RTSPCameraArguments.input(url: url, options: RTSPCameraOptions(analyzeDuration: 2_000_000, probeSize: 5_000_000, rtspOverTCP: true))
        guard let result = await FfmpegExec(ffmpeg.options, commandLineArgs: RTSPCameraArguments.frame(input: input), logErrors: false).exec(timeout: 15_000),
              result.stdout.starts(with: [0xFF, 0xD8]) else { return nil }
        return result.stdout
    }

    // MARK: Video

    /// The local RTSP address of the channel; nil without an address and a password.
    func localURL(subStream: Bool) -> String? {
        guard let host = settings.host, let password = settings.password else { return nil }
        return dahuaRTSPURL(host: host, port: settings.rtspPort, username: settings.username, password: password, channel: channel.localChannel,
                            subStream: subStream)
    }

    /// The LAN is tried: it has not failed three times in a row lately, or it is the only way.
    private var usesLocal: Bool {
        guard settings.isLocal else { return false }
        guard cloud != nil, let localRetryAt else { return true }
        return ContinuousClock.now >= localRetryAt
    }

    private func localSucceeded() {
        if localRetryAt != nil { log.info("\(name): the camera answers on the local network again") }
        localFailures = 0
        localRetryAt = nil
    }

    func localFailed() {
        localFailures += 1
        guard localFailures >= 3, cloud != nil else { return }
        if localRetryAt == nil {
            log.warning("\(name): the camera does not answer on the local network (\(settings.host ?? "")): using the cloud, and trying again every 5 minutes")
        }
        localRetryAt = .now + timing.duration(Self.localCooldown)
    }

    /// Where a stream reads from (section 6.2): the local RTSP stream, else a cloud stream made for this session. Recordings
    /// are local only (the cloud's live quota is no place for them). A closed camera refuses at once.
    func source(for purpose: RTSPSourcePurpose) async throws -> RTSPSource {
        if privacyOn { throw SnapshotUnavailable(description: "privacy mode is on") }
        if online == .offline, local == nil { throw SnapshotUnavailable(description: "the camera is offline") }
        if usesLocal || purpose == .recording, let url = localURL(subStream: false) {
            return RTSPSource(url: url, failed: { [weak self] in await self?.localFailed() }, started: { [weak self] in await self?.localSucceeded() })
        }
        guard purpose == .live, let cloud else { throw SnapshotUnavailable(description: "the camera has no local stream") }
        try await wakeIfSleeping()
        let url = try await cloud.streamURL(deviceID, channel: channel.id, streamID: streamID)
        return RTSPSource(url: url)
    }

    /// Wakes a sleeping camera before a stream or a snapshot (section 7.4), never for a poll.
    private func wakeIfSleeping() async throws {
        guard online == .sleeping, let cloud else { return }
        log.debug("\(name): waking the camera")
        do {
            try await cloud.wakeUp(deviceID)
            try await Task.sleep(for: timing.duration(timing.wakeWait))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warning("\(name): failed to wake up: \(error)")
        }
    }

    func shutdown() async {
        await streamer?.stopAll()
        recorder?.shutdown()
        controller?.destroy()
        fetching?.cancel()
        motionHold?.cancel()
        sirenHold?.cancel()
    }
}
