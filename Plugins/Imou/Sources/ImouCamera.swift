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

    struct Services {
        let motion: Service
        let privacy: Service?
        let motionDetection: Service?
        let siren: Service?
        let light: Service?
        let battery: Service?
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
         streamID: Int, timing: Timing, log: Logger) {
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
            battery: features.battery && cloudControls ? Service(.battery, name: "\(name) Battery", subtype: "battery") : nil)
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
            try await self?.write(\.privacy, value.boolValue ?? false) { cloud, device, channel, on in
                try await cloud.setCameraStatus(device, channel: channel, "closeCamera", on)
            }
            await self?.privacyChanged(value.boolValue ?? false)
        }
        services.motionDetection?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            try await self?.write(\.motionDetection, value.boolValue ?? false) { cloud, device, channel, on in
                try await cloud.setMotionDetection(device, channel: channel, on)
            }
        }
        services.light?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
            try await self?.write(\.light, value.boolValue ?? false) { cloud, device, channel, on in
                try await cloud.setCameraStatus(device, channel: channel, "whiteLight", on)
            }
        }
        let multiChannel = multiChannel
        services.siren?.characteristic(.on).onWrite { [weak self] value in
            let on = value.boolValue ?? false
            try await self?.write(\.siren, on) { cloud, device, channel, on in
                try await cloud.siren(device, channel: channel, multiChannel: multiChannel, on)
            }
            await self?.sirenWritten(on)
        }
    }

    private func write(_ service: KeyPath<Services, Service?>, _ on: Bool,
                       _ send: @escaping @Sendable (ImouCloud, String, String, Bool) async throws -> Void) async throws {
        guard let cloud else { throw HAPStatusError(.serviceCommunicationFailure) }
        let device = deviceID, channel = channel.id
        let sleeping = online == .sleeping
        let retryWait = timing.duration(timing.dormantRetryWait)
        do {
            try await queue.run {
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

    private func privacyChanged(_ on: Bool) {
        privacyOn = on
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
    /// keeps its last state: it is never woken for a poll.
    func refresh(_ state: ImouOnline, battery level: Int? = nil) async {
        online = state
        let reachable = state == .online || state == .sleeping
        set(services.motion.characteristic(.statusActive), .bool(reachable || localEventsUp == true))
        if local == nil { accessory?.isUnavailable = !reachable }
        guard state == .online, let cloud else { return }
        if let privacy = services.privacy, let on = try? await cloud.cameraStatus(deviceID, channel: channel.id, "closeCamera", polling: true) {
            privacyOn = on
            set(privacy.characteristic(.on), .bool(on))
        }
        if let light = services.light, let on = try? await cloud.cameraStatus(deviceID, channel: channel.id, "whiteLight", polling: true) {
            set(light.characteristic(.on), .bool(on))
        }
        if let detection = services.motionDetection {
            // On when either reads on; off only when both answered off (section 4.4).
            var answers: [Bool?] = []
            for type in ["mobileDetect", "motionDetect"] {
                do { answers.append(try await cloud.cameraStatus(deviceID, channel: channel.id, type, polling: true)) } catch { answers.append(nil) }
            }
            if answers.contains(true) {
                set(detection.characteristic(.on), true)
            } else if answers.allSatisfy({ $0 == false }) {
                set(detection.characteristic(.on), false)
            }
        }
        if let battery = services.battery, let level {
            set(battery.characteristic(.batteryLevel), .int(level))
            set(battery.characteristic(.statusLowBattery), .int(level < 20 ? 1 : 0))
        }
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
