import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// IMOU (Dahua's consumer brand) cameras in HomeKit, local first: each camera channel is a camera accessory of its own
/// (`context.publishExternal`) whose video and snapshots come from its RTSP stream and CGI on the LAN, signed in with the
/// safety code on its label; motion and doorbell presses from its Dahua event stream. The IMOU Open Platform (a developer
/// app's App Id and App Secret, optional) lists the account's cameras for Setup and adds privacy mode, the siren, the
/// spotlight and the camera's own motion detection, cloud live video and snapshots when the LAN cannot, and the cloud's
/// alarms for a camera whose local event stream is down. No Homebridge plugin exists for IMOU; docs/clean-room/Imou.md is
/// the functional specification this was written from. See README.md.
public actor ImouPlugin: HomeswiftPlugin {
    /// What the plugin reaches the world with; tests swap them.
    struct Dependencies: Sendable {
        var cloudTransport: any HTTPSending = HTTPClient()
        /// Cloud snapshots: an HTTPS object-storage address, 8 MiB at most (section 4.7).
        var download: any HTTPSending = HTTPClient(maximumBodySize: 8 * 1024 * 1024)
        var local: any DahuaTransport = HTTPClient()
        var now: @Sendable () -> Date = { Date() }
        var nonce: (@Sendable () -> String)?
        /// Multiplies every timer and wait (polls, holds, retries): tests shorten them.
        var timeScale: Double = 1
        var ffmpeg: @Sendable (_ executable: String, _ logger: Logger) -> RTSPCameraFFmpeg = { RTSPCameraFFmpeg(executable: $0, name: "IMOU", logger: $1, debug: false) }
        var ports = RtpPortAllocator()
        /// A local event stream that sends nothing (not even its heartbeat) this long is dead (section 5.3).
        var eventSilence: Duration = .seconds(30)
    }

    public static let platform = "Imou"
    public static let name = "IMOU"
    public static let icon: String? = "camera"
    public static let summary: String? = "IMOU cameras and doorbells on the local network, with the IMOU cloud's privacy mode and siren"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// Every device is a camera.
    static let cameraKind = "camera"
    /// The cloud's device list is read again this often (section 7.1).
    static let rediscoveryInterval: Double = 600
    /// The cloud's alarms, when they stand in for a camera's local events and no interval is set.
    static let defaultAlarmPollInterval = 60

    /// The sizes HomeKit may ask for.
    static let resolutions = RTSPCameraStreamer.standardResolutions

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    /// The cameras by accessory id.
    private(set) var cameras: [String: ImouCamera] = [:]
    /// The cloud's camera devices, by Device Id, from its last listing.
    private(set) var cloudDevices: [String: ImouDevice] = [:]
    private var queues: [String: SerialQueue] = [:]
    private var eventStreams: [String: Task<Void, Never>] = [:]
    private var ffmpeg: RTSPCameraFFmpeg?
    private(set) var cloud: ImouCloud?
    private var cloudOutage = false
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String, channel: String) -> String { "\(platform):\(deviceID):\(channel)" }

    private func scaled(_ seconds: Double) -> Duration { ImouCamera.Timing(scale: dependencies.timeScale).duration(seconds) }

    // MARK: Lifecycle

    public func start() async throws {
        cloud = makeCloud()
        // Nothing configured costs nothing: no task, no socket, no timer.
        guard cloud != nil || !localCameras().isEmpty else { return }
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        tasks.cancelAll()
        for task in eventStreams.values { task.cancel() }
        eventStreams = [:]
        for camera in cameras.values { await camera.shutdown() }
    }

    /// The cloud client, when the block has an App Id and a secret is known (Setup's in the vault, or the block's).
    func makeCloud() -> ImouCloud? {
        guard let appID = configuration.appID, let secret = appSecret else { return nil }
        return makeCloud(appID: appID, appSecret: secret, region: configuration.cloudRegion)
    }

    func makeCloud(appID: String, appSecret: String, region: ImouRegion) -> ImouCloud {
        var environment = ImouCloud.Environment(transport: dependencies.cloudTransport, now: dependencies.now)
        if let nonce = dependencies.nonce { environment.nonce = nonce }
        return ImouCloud(appID: appID, appSecret: appSecret, region: region, apiURL: configuration.apiURL, environment: environment, logger: logger)
    }

    var appSecret: String? {
        context.credentials(as: ImouAccountCredentials.self)?.appSecret ?? configuration.appSecret
    }

    private func run() async {
        if let cloud {
            var attempt = 0
            let backoff = Backoff(initial: .seconds(30), maximum: .seconds(900), jitter: .proportional(0.2))
            while !Task.isCancelled {
                do {
                    await sync(try await cloud.listDevices())
                    break
                } catch let error as ImouError where error.isAuthRefused {
                    context.accountRefused("the IMOU cloud refused the App Id and App Secret (\(error))")
                    self.cloud = nil
                    break
                } catch {
                    if Task.isCancelled { return }
                    if attempt == 0 {
                        logger.warning("Cannot list the IMOU account's cameras: \(error). Trying again.")
                        // The cameras with a local address run meanwhile.
                        await publishLocalCameras()
                        startEventStreams()
                    }
                    try? await Task.sleep(for: backoff.delay(attempt: attempt) * dependencies.timeScale)
                    attempt += 1
                }
            }
        }
        guard !Task.isCancelled else { return }
        // Without a cloud account, the cameras of the LAN are all there is; a refused account keeps its cameras (No Response)
        // until it is set up again.
        await publishLocalCameras()
        if context.accountRefusal == nil, self.cloud == nil {
            await context.removeAccessories(keeping: Set(cameras.keys))
        }
        startEventStreams()
        for camera in cameras.values where await !camera.needsAlarmPolling(interval: configuration.alarmPollInterval) && camera.local == nil {
            await camera.noteSilentSensor()
        }
        guard self.cloud != nil else { return }
        estimateCalls()
        tasks.add { [weak self] in await self?.pollLoop() }
        tasks.add { [weak self] in await self?.alarmLoop() }
        tasks.add { [weak self] in await self?.rediscoveryLoop() }
    }

    // MARK: Cameras

    /// The cameras set up without the cloud: Accessory Settings with an address and a safety code in the vault, and the
    /// block's `devices` entries with a Device Id and an address. Those the cloud lists are left to it.
    func localCameras() -> [(deviceID: String, name: String?)] {
        var found: [String: String?] = [:]
        for (deviceID, settings) in context.allAccessorySettings where !settings.excluded && settings.plugin["host"]?.stringValue != nil {
            if context.credentials(for: deviceID, as: ImouCameraCredentials.self)?.password != nil { found[deviceID] = settings.name }
        }
        for entry in configuration.devices {
            guard let deviceID = entry.deviceID, entry.host != nil, entry.password != nil, !context.isExcluded(deviceID), found[deviceID] == nil else { continue }
            found[deviceID] = entry.name
        }
        return found.filter { cloudDevices[$0.key] == nil }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// A camera's options: its Accessory Settings over its `devices` entry, its safety code from the vault.
    func cameraSettings(deviceID: String) -> CameraSettings {
        let entry = configuration.devices.first { $0.deviceID == deviceID }
        var fields = entry?.options ?? [:]
        if let host = entry?.host { fields["host"] = .string(host) }
        for (key, value) in context.accessorySettings(for: deviceID).plugin where CameraSettings.keys.contains(key) && !value.isNull { fields[key] = value }
        let credentials = context.credentials(for: deviceID, as: ImouCameraCredentials.self)
        return CameraSettings(fields: fields, password: credentials?.password ?? entry?.password, defaults: configuration)
    }

    /// Follows the cloud's listing: a camera for each channel of each new device, the cameras of devices gone removed.
    func sync(_ devices: [ImouDevice]) async {
        var listed: [String: ImouDevice] = [:]
        for device in devices {
            guard device.productID == nil else {
                logger.debug("Skipping \(device.name): IoT devices are not supported")
                continue
            }
            listed[device.deviceID] = device
        }
        let previous = cloudDevices
        cloudDevices = listed
        for device in listed.values.sorted(by: { $0.deviceID < $1.deviceID }) where !context.isExcluded(device.deviceID) {
            let changed = previous[device.deviceID] != device
            for channel in device.cameraChannels {
                let id = Self.accessoryID(deviceID: device.deviceID, channel: channel.id)
                guard cameras[id] == nil || changed, !context.isExcluded(accessoryID: id) else { continue }
                var events: Bool?
                if let old = cameras.removeValue(forKey: id) {
                    events = await old.localEventsUp
                    await old.shutdown()
                }
                await publish(device: device, channel: channel)
                // The event stream goes on: the new camera knows where it stands.
                if let events { await cameras[id]?.localEvents(up: events) }
            }
        }
        var keep = Set(localCameras().map { Self.accessoryID(deviceID: $0.deviceID, channel: "0") })
        for device in listed.values { for channel in device.cameraChannels { keep.insert(Self.accessoryID(deviceID: device.deviceID, channel: channel.id)) } }
        for (id, camera) in cameras where !keep.contains(id) {
            await camera.shutdown()
            cameras.removeValue(forKey: id)
        }
        await context.removeAccessories(keeping: keep)
    }

    private func queue(for deviceID: String) -> SerialQueue {
        if let queue = queues[deviceID] { return queue }
        let queue = SerialQueue()
        queues[deviceID] = queue
        return queue
    }

    private func sharedFFmpeg() -> RTSPCameraFFmpeg {
        if let ffmpeg { return ffmpeg }
        let made = dependencies.ffmpeg(configuration.videoProcessor ?? "ffmpeg", logger)
        ffmpeg = made
        return made
    }

    /// The cameras set up on the LAN alone that are not published yet.
    private func publishLocalCameras() async {
        for (deviceID, name) in localCameras() where cameras[Self.accessoryID(deviceID: deviceID, channel: "0")] == nil {
            let device = ImouDevice(deviceID: deviceID, name: name ?? "IMOU \(deviceID)")
            await publish(device: device, channel: device.cameraChannels[0])
        }
    }

    /// Builds a channel's camera accessory (section 6) and publishes it on its own server.
    private func publish(device: ImouDevice, channel: ImouChannel) async {
        guard !tasks.isStopped else { return }
        let settings = cameraSettings(deviceID: device.deviceID)
        let features = ImouFeatures(abilities: device.abilities(of: channel))
        let name = channel.id == "0" || device.isIPC ? device.name : channel.name
        let id = Self.accessoryID(deviceID: device.deviceID, channel: channel.id)
        let local = settings.isLocal ? settings.host.flatMap {
            DahuaClient(host: $0, port: settings.httpPort, username: settings.username, password: settings.password ?? "", transport: dependencies.local)
        } : nil
        let ffmpeg = sharedFFmpeg()
        let camera = ImouCamera(
            accessoryID: id, deviceID: device.deviceID, channel: channel, name: name, features: features, settings: settings,
            multiChannel: !device.isIPC, cloud: cloudDevices[device.deviceID] != nil ? cloud : nil, local: local, queue: queue(for: device.deviceID),
            download: dependencies.download, ffmpeg: ffmpeg, streamID: configuration.streamID,
            timing: ImouCamera.Timing(scale: dependencies.timeScale, snapshotWait: configuration.snapshotWaitSeconds, wakeWait: configuration.wakeWaitSeconds,
                                      dormantRetryWait: Double(configuration.dormantRetrySeconds)),
            log: logger)
        let options = RTSPCameraOptions(encoder: (settings.encoder ?? "").split(whereSeparator: \.isWhitespace).map(String.init), rtspOverTCP: true)
        let open: RTSPSourceOpener = { [weak camera] purpose in
            guard let camera else { throw HAPStatusError(.serviceCommunicationFailure) }
            return try await camera.source(for: purpose)
        }
        let streamer = RTSPCameraStreamer(
            name: name, options: options, ffmpeg: ffmpeg, ports: dependencies.ports, open: open,
            snapshot: { [weak camera] _ in
                guard let camera else { throw HAPStatusError(.serviceCommunicationFailure) }
                return try await camera.snapshotImage()
            }, log: logger, timeScale: dependencies.timeScale)
        // HomeKit Secure Video from the local stream only (section 6.2).
        let recorder = settings.isLocal && settings.recording ? RTSPCameraRecorder(name: name, options: options, ffmpeg: ffmpeg, open: open, log: logger) : nil
        do {
            let controllerOptions = CameraControllerOptions(
                cameraStreamCount: 2, delegate: streamer,
                streamingOptions: CameraStreamingOptions(
                    supportedCryptoSuites: [.aesCM128HMACSHA1_80],
                    video: VideoStreamingOptions(
                        codec: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]), resolutions: Self.resolutions),
                    audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])], twoWayAudio: false)),
                recording: recorder.map {
                    CameraRecordingSetup(options: RTSPCameraRecorder.options(resolutions: Self.resolutions, triggers: features.doorbell ? [.motion, .doorbell] : [.motion]),
                                         delegate: $0)
                },
                sensors: CameraSensorOptions(motion: .service(camera.services.motion)))
            let controller: CameraController = features.doorbell
                ? try DoorbellController(controllerOptions, name: name, logger: logger)
                : try CameraController(controllerOptions, logger: logger)
            await streamer.attach(controller)
            let services = camera.services
            let accessory = Accessory(
                id: id, name: name, manufacturer: "Imou", model: device.model, serialNumber: device.deviceID,
                firmwareRevision: Self.firmwareRevision(device.firmware), category: features.doorbell ? .videoDoorbell : .ipCamera,
                services: [services.motion, services.privacy, services.motionDetection, services.siren, services.light, services.battery].compactMap { $0 })
            camera.bindWrites()
            accessory.configureController(controller)
            context.configureController(controller, accessoryID: id)
            await camera.attach(accessory: accessory, controller: controller, streamer: streamer, recorder: recorder)
            try await context.publishExternal(accessory)
            cameras[id] = camera
            logger.info("Added \(name) (\(device.model), \(device.deviceID))\(local == nil ? "" : ", on the local network at \(local?.host ?? "")")")
        } catch {
            logger.error("Could not publish \(name): \(error)")
        }
    }

    /// The leading numbers of a firmware version, as HomeKit takes them (`2.840.0000000.12.R` is `2.840.0`).
    static func firmwareRevision(_ text: String?) -> String {
        let numbers = (text ?? "").split(separator: ".").prefix(3).map { part in Int(part.prefix(9)).map(String.init) ?? "0" }
        guard let first = numbers.first, first != "0" || numbers.count > 1 else { return "1.0.0" }
        return (numbers + Array(repeating: "0", count: max(0, 3 - numbers.count))).joined(separator: ".")
    }

    // MARK: Local events

    /// One event stream per camera address (an NVR's channels share it), told to the channels by `index`.
    private func startEventStreams() {
        var byHost: [String: (client: DahuaClient, deviceID: String, doorbell: Bool)] = [:]
        for camera in cameras.values {
            guard let client = camera.local, camera.settings.localEvents else { continue }
            let key = "\(client.host):\(client.port)"
            var entry = byHost[key] ?? (client, camera.deviceID, false)
            entry.doorbell = entry.doorbell || camera.features.doorbell
            byHost[key] = entry
        }
        // A camera gone, or moved to another address: its stream stops.
        for (key, task) in eventStreams where byHost[key] == nil {
            task.cancel()
            eventStreams[key] = nil
        }
        for (key, entry) in byHost where eventStreams[key] == nil {
            let codes = ImouEvents.localCodes + (entry.doorbell ? ImouEvents.localDoorbellCodes.sorted() : [])
            let silence = dependencies.eventSilence
            let scale = dependencies.timeScale
            let logger = logger
            let deviceID = entry.deviceID
            // The device's cameras as they are now: one published again (the cloud listed it) takes the old one's place.
            let lookup: @Sendable () async -> [String: ImouCamera] = { [weak self] in await self?.cameras(of: deviceID) ?? [:] }
            // In the bag, so `stop()` ends it even when it starts after (a listing still in flight then).
            eventStreams[key] = tasks.add {
                await Self.runEvents(client: entry.client, cameras: lookup, codes: codes, silence: silence, timeScale: scale, logger: logger)
            }
        }
    }

    /// A device's cameras, by channel.
    private func cameras(of deviceID: String) -> [String: ImouCamera] {
        var found: [String: ImouCamera] = [:]
        for camera in cameras.values where camera.deviceID == deviceID { found[camera.channel.id] = camera }
        return found
    }

    /// Reads a camera's event stream for as long as the plugin runs: reconnected with backoff (1 s to 60 s), logged once
    /// per outage; a refused safety code or a camera without the CGI stops it, and the cloud's alarms stand in. A
    /// connection counts as back once it has stayed up for `silence`: one the camera drops at once keeps backing off,
    /// unlogged.
    static func runEvents(client: DahuaClient, cameras: @escaping @Sendable () async -> [String: ImouCamera], codes: [String], silence: Duration,
                          timeScale: Double, logger: Logger) async {
        let backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: .proportional(0.2))
        let outage = EventStreamOutage()
        var everything = false
        let host = client.host
        @Sendable func report(_ up: Bool) async { for camera in await cameras().values { await camera.localEvents(up: up) } }
        while !Task.isCancelled {
            do {
                let response = try await client.events(codes: everything ? ["All"] : codes)
                // Up once it has stayed up: a camera that drops the stream at once leaves the cloud's alarms standing in.
                try await read(response, cameras: cameras, silence: silence) {
                    if await outage.steady() { logger.info("The event stream of \(host) is back") }
                    await report(true)
                }
                throw DahuaError.silent
            } catch is CancellationError {
                return
            } catch DahuaError.wrongPassword {
                logger.warning("The camera at \(client.host) refused the safety code: its events come from the cloud, if at all. Set it up again.")
                await report(false)
                return
            } catch DahuaError.unsupported(let status) {
                logger.info("The camera at \(client.host) has no event stream (HTTP \(status)): its events come from the cloud, if at all")
                await report(false)
                return
            } catch DahuaError.http(400) where !everything {
                // The camera refused the list of codes: all of them, then.
                everything = true
                continue
            } catch {
                if Task.isCancelled { return }
                if await outage.failed() { logger.warning("The event stream of \(host) stopped: \(error). Reconnecting.") }
                await report(false)
            }
            try? await Task.sleep(for: backoff.delay(attempt: await outage.nextAttempt()) * timeScale)
        }
    }

    /// The parts of one connection, until it ends or goes silent; `steady` is called once it has been up for `silence`.
    static func read(_ response: HTTPStreamingResponse, cameras: @escaping @Sendable () async -> [String: ImouCamera], silence: Duration,
                     steady: @escaping @Sendable () async -> Void = {}) async throws {
        let last = LastActivity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var parser = DahuaMultipartParser(contentType: response.header("Content-Type"))
                for try await chunk in response.body {
                    await last.touch()
                    for text in parser.feed(chunk) {
                        guard let event = DahuaEvent(text: text), let camera = await cameras()[String(event.index)] else { continue }
                        await camera.handle(local: event)
                    }
                }
            }
            group.addTask {
                let opened = ContinuousClock.now
                var announced = false
                while !Task.isCancelled {
                    try await Task.sleep(for: silence / 3)
                    if await last.idle() > silence { throw DahuaError.silent }
                    if !announced, ContinuousClock.now - opened >= silence {
                        announced = true
                        await steady()
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: Cloud polling

    /// The cameras of each cloud device, by Device Id.
    private func camerasByDevice() -> [String: [ImouCamera]] {
        var grouped: [String: [ImouCamera]] = [:]
        for camera in cameras.values where cloudDevices[camera.deviceID] != nil { grouped[camera.deviceID, default: []].append(camera) }
        return grouped
    }

    /// Every `pollingInterval`, twice that once the day's calls pass 18,000: `deviceOnline` per device, then the switches of
    /// those online (section 7.1).
    private func pollLoop() async {
        while !Task.isCancelled {
            await poll()
            let slow = await cloud?.isOverBudget() ?? false
            try? await Task.sleep(for: scaled(Double(configuration.pollSeconds * (slow ? 2 : 1))))
        }
    }

    func poll() async {
        guard let cloud else { return }
        for (deviceID, cameras) in camerasByDevice().sorted(by: { $0.key < $1.key }) where !context.isExcluded(deviceID) {
            do {
                let state = try await cloud.online(deviceID, polling: true)
                // The battery is the device's: read once for all its channels.
                var battery: Int?
                if state.device == .online, cameras.contains(where: { $0.services.battery != nil }) { battery = try? await cloud.batteryLevel(deviceID) }
                for camera in cameras {
                    let channel = state.channels.isEmpty ? state.device : state.channels[camera.channel.id] ?? .offline
                    await camera.refresh(channel, battery: battery)
                }
                if cloudOutage { logger.info("The IMOU cloud answers again") }
                cloudOutage = false
            } catch ImouError.overBudget {
                return
            } catch let error as ImouError where error.isAuthRefused {
                context.accountRefused("the IMOU cloud refused the App Id and App Secret (\(error))")
                return
            } catch let error as ImouError where error.code == "OP1009" || error.code == "FL1001" {
                for camera in cameras { await camera.refresh(.offline) }
                logger.warning("\(deviceID): \(error)")
            } catch {
                if !cloudOutage { logger.warning("Cannot reach the IMOU cloud: \(error)") }
                cloudOutage = true
                return
            }
        }
    }

    /// The cloud's alarms for the cameras whose local events are down, or that have none when an interval is set.
    private func alarmLoop() async {
        let interval = configuration.alarmPollInterval.map { max($0, 30) } ?? Self.defaultAlarmPollInterval
        guard configuration.alarmPollInterval != 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: scaled(Double(interval)))
            await pollAlarms()
        }
    }

    func pollAlarms() async {
        guard let cloud else { return }
        for camera in cameras.values.sorted(by: { $0.accessoryID < $1.accessoryID }) where await camera.needsAlarmPolling(interval: configuration.alarmPollInterval) {
            do {
                if let alarm = try await cloud.latestAlarm(camera.deviceID, channel: camera.channel.id, now: dependencies.now()) { await camera.handle(alarm: alarm) }
            } catch {
                logger.debug("\(camera.name): no alarms from the cloud: \(error)")
                if case ImouError.overBudget = error { return }
            }
        }
    }

    private func rediscoveryLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: scaled(Self.rediscoveryInterval))
            guard let cloud else { return }
            if let devices = try? await cloud.listDevices(), !Task.isCancelled {
                await sync(devices)
                startEventStreams()
            }
        }
    }

    /// What the polls will cost a day, warned of above 15,000 (section 7.2).
    private func estimateCalls() {
        var perPoll = 0
        for device in cloudDevices.values {
            perPoll += 1
            for channel in device.cameraChannels {
                let features = ImouFeatures(abilities: device.abilities(of: channel))
                perPoll += (features.privacy ? 1 : 0) + (features.whiteLight ? 1 : 0) + (features.motionDetectSwitch ? 2 : 0)
            }
            if device.cameraChannels.contains(where: { ImouFeatures(abilities: device.abilities(of: $0)).battery }) { perPoll += 1 }
        }
        var daily = perPoll * 86_400 / configuration.pollSeconds
        if let interval = configuration.alarmPollInterval, interval > 0 { daily += cameras.count * 86_400 / max(interval, 30) }
        daily += 144
        if daily > ImouUsage.warnAbove {
            logger.warning("These cameras and intervals cost about \(daily) IMOU cloud calls a day; the account's limit is 20,000: raise pollingInterval")
        } else {
            logger.debug("About \(daily) IMOU cloud calls a day")
        }
    }

    // MARK: For tests

    func camera(_ accessoryID: String) -> ImouCamera? { cameras[accessoryID] }
}

/// An event stream's outage: logged once, over when a connection stays up; the backoff's attempt.
actor EventStreamOutage {
    private var down = false
    private var attempt = 0

    /// A connection stayed up: true when an outage was logged and is over.
    func steady() -> Bool {
        attempt = 0
        defer { down = false }
        return down
    }

    /// A connection failed: true when this starts an outage to log.
    func failed() -> Bool {
        defer { down = true }
        return !down
    }

    func nextAttempt() -> Int {
        defer { attempt += 1 }
        return attempt
    }
}

/// When a stream last sent something.
actor LastActivity {
    private var last = ContinuousClock.now
    func touch() { last = .now }
    func idle() -> Duration { .now - last }
}
