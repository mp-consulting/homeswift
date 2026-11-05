import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Reolink cameras, doorbells, NVRs and Home Hubs on the local network: each channel is a camera accessory of its own
/// (`context.publishExternal`) with live video and snapshots through FFmpeg, HomeKit Secure Video, motion and AI sensors,
/// the doorbell, the floodlight, the siren and IR lights. Events come by Baichuan push (TCP 9000), with HTTP polling only
/// while push is not active. A clean-room implementation written from docs/clean-room/Reolink.md; see README.md.
public actor ReolinkPlugin: HomeswiftPlugin {
    /// What the plugin reaches the world with; tests swap them.
    struct Dependencies: Sendable {
        var makeSender: ReolinkHTTPClient.MakeSender = { HTTPClient(tls: $0, cipherSuites: "DEFAULT") }
        var connectBaichuan: BaichuanSession.Connect = { host, port, timeout in try await TCPStream.connect(host: host, port: port, timeout: timeout) }
        var timing = ReolinkTiming()
        var ports = RtpPortAllocator()
        /// The ARP table's entries (IP and MAC), for discovery.
        var neighbours: @Sendable () async -> [(ip: String, mac: String)] = { await ARPTable.entries() }
        /// Whether something accepts TCP on a port, for discovery.
        var accepts: @Sendable (_ host: String, _ port: Int) async -> Bool = { host, port in
            guard let stream = try? await TCPStream.connect(host: host, port: port, timeout: .seconds(1)) else { return false }
            await stream.close()
            return true
        }
        /// How long discovery looks on the network (the ARP table, then each candidate's Baichuan port).
        var networkSearchTime: Duration = .seconds(3)
        var now: @Sendable () -> Date = { Date() }
        /// The bridge's address on a camera's network, for its webhook.
        var localAddress: @Sendable (_ toward: String) -> String? = { ReolinkWebhookServer.localAddress(toward: $0) }
        /// Where the battery cameras' webhook listens.
        var webhookBindHost = "0.0.0.0"
        /// Replaces FFmpeg's decoding of HomeKit's return audio (tests).
        var returnAudioDecoder: ReturnAudioDecoderFactory?
    }

    /// A siren waits this long for a Talk on its channel to end (ReolinkTalk.md 7).
    static let sirenTalkWait: Double = 10

    /// A standalone battery camera and its accessory.
    struct BatteryRuntime {
        let device: Device
        let host: ReolinkBatteryHost
        let camera: ReolinkCamera
    }

    /// A host and its cameras, once connected.
    struct HostRuntime {
        let device: Device
        let host: ReolinkHost
        var hostID: String?
        var info: ReolinkHostInfo?
        var cameras: [Int: ReolinkCamera] = [:]
    }

    /// The login Setup keeps in the vault, under the host's Device Id.
    struct Login: Codable, Sendable {
        var username: String
        var password: String
    }

    public static let platform = "Reolink"
    public static let name = "Reolink"
    public static let icon: String? = "camera"
    public static let summary: String? = "Reolink cameras, doorbells, NVRs and Home Hubs: live video, motion, people and vehicles, floodlights"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let cameraKind = "camera"
    static let nvrKind = "nvr"
    static let backoff = Backoff(initial: .seconds(5), maximum: .seconds(120), jitter: .proportional(0.1))
    /// Characters known to work in every stream URL (2.2).
    static let safePasswordCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@$*~_-+=!?.,:;'()[]")

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    private(set) var runtimes: [String: HostRuntime] = [:]
    /// The battery cameras by address (ReolinkBattery.md).
    var batteryRuntimes: [String: BatteryRuntime] = [:]
    /// What each battery camera said of itself, by UID: its accessory is published while it sleeps.
    let batteryRecords: PersistedDictionary<ReolinkBatteryHost.Record>
    /// The battery cameras' webhook listener, started with the first of them.
    var webhookServer: Task<ReolinkWebhookServer?, Never>?
    private var ffmpegOptions: FfmpegOptions?
    /// What FFmpeg has, probed once (return audio's decoder).
    private(set) var ffmpegCodecs: FfmpegCodecs?
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        certificates = context.persistedDictionary("certificates.json", of: String.self, autosave: nil)
        batteryRecords = context.persistedDictionary("battery-cameras.json", of: ReolinkBatteryHost.Record.self, autosave: nil)
    }

    // MARK: Ids (6.1)

    /// A channel's Device Id: the host id for a camera on its own; `<host id>:<channel UID>`, or `<host id>:ch<n>`
    /// without one, for a channel of an NVR or a hub.
    static func deviceID(hostID: String, info: ReolinkHostInfo, channel: ReolinkChannel) -> String {
        deviceID(hostID: hostID, info: info, channel: channel.channel, uid: channel.uid)
    }

    static func deviceID(hostID: String, info: ReolinkHostInfo, channel: Int, uid: String?) -> String {
        guard info.isMultiChannel else { return hostID }
        if let uid { return "\(hostID):\(uid)" }
        return "\(hostID):ch\(channel)"
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// The host ids last seen for each address, so a host that does not answer at launch shows its cached cameras as
    /// not responding.
    var hostsFile: JSONFile<[String: String]> { context.jsonFile("hosts.json", as: [String: String].self) }
    /// Each host's pinned HTTPS certificate (fingerprints, not secrets).
    /// Locked: hosts connect in parallel and each pins from its own TLS handshake.
    private let certificates: PersistedDictionary<String>

    // MARK: The hosts

    /// The block's `devices`, with the login Setup kept for the same address, then the hosts set up through Setup only.
    func hostEntries() -> [Device] {
        var setUp: [(deviceID: String, device: Device)] = []
        for (deviceID, settings, login) in context.setUpDevices(credentials: Login.self) {
            var fields: [String: JSONValue] = [:]
            for key in Device.settingKeys { if let value = settings.plugin[key] { fields[key] = value } }
            fields["username"] = .string(login.username)
            fields["password"] = .string(login.password)
            if let device = Device(json: .object(fields)) { setUp.append((deviceID, device)) }
        }
        func key(_ host: String) -> String { host.lowercased() }
        var entries = configuration.devices.map { entry -> Device in
            guard let kept = setUp.first(where: { key($0.device.host) == key(entry.host) }) else { return entry }
            var entry = entry
            entry.username = kept.device.username
            entry.password = kept.device.password
            return entry
        }
        let listed = Set(entries.map { key($0.host) })
        entries += setUp.map(\.device).filter { !listed.contains(key($0.host)) }
        return entries
    }

    // MARK: Lifecycle

    public func start() async throws {
        let entries = hostEntries()
        guard !entries.isEmpty else { return }
        let known = hostsFile.load() ?? [:]
        for entry in entries {
            if let hostID = known[entry.host.lowercased()], context.isExcluded(hostID) { continue }
            if entry.batteryCamera {
                tasks.add { [weak self] in await self?.startBattery(entry) }
                continue
            }
            if entry.streamProtocol != "rtsp" {
                logger.warning("[\(entry.host)] streamProtocol \(entry.streamProtocol) puts the password in the stream URL's query, readable on the network (rtmp) or over HTTPS that FFmpeg does not check (flv): prefer rtsp.")
            }
            if !entry.password.isEmpty, entry.password.contains(where: { !Self.safePasswordCharacters.contains($0) }) || entry.password.count > 31 {
                logger.warning("[\(entry.host)] The password has characters Reolink devices do not take in every URL, or more than 31: if streams fail, change it to letters, digits and @$*~_-+=!?.,:;'()[] only.")
            }
            let host = makeHost(entry)
            runtimes[entry.host] = HostRuntime(device: entry, host: host, hostID: known[entry.host.lowercased()])
            tasks.add { [weak self] in await self?.connect(entry.host) }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        for runtime in runtimes.values {
            for camera in runtime.cameras.values { await camera.stop() }
            await runtime.host.stop()
        }
        for runtime in batteryRuntimes.values {
            await runtime.camera.stop()
            await runtime.host.stop()
        }
        await webhookServer?.value?.stop()
    }

    /// `trustingAgain` (Setup) forgets the host's pinned certificate: the next one is pinned in its place.
    func makeHost(_ entry: Device, trustingAgain: Bool = false) -> ReolinkHost {
        let base = logger
        let log = Logger(label: base.label, factory: { _ in ReolinkLogHandler(base: base, prefix: "[\(entry.host)] ") })
        let pins = certificates
        let hostKey = entry.host.lowercased()
        let trust = HTTPClient.TrustOnFirstUse(pinned: trustingAgain ? nil : pins[hostKey]) { fingerprint in
            pins[hostKey] = fingerprint
            try? pins.flush()
        }
        let http = ReolinkHTTPClient(host: entry.host, port: entry.port, useHttps: entry.useHttps, username: entry.username, password: entry.password,
                                     makeSender: dependencies.makeSender, trust: trust, log: log, timing: dependencies.timing, now: dependencies.now)
        return ReolinkHost(device: entry, http: http, connectBaichuan: dependencies.connectBaichuan, log: log, timing: dependencies.timing)
    }

    /// Connects a host, retrying with `Backoff` and logging once per outage; then publishes its channels and runs it.
    private func connect(_ address: String) async {
        guard let runtime = runtimes[address] else { return }
        var attempt = 0
        var privacyLogged = false
        while !Task.isCancelled {
            do {
                try await runtime.host.connect()
                break
            } catch ReolinkError.privacy {
                // Not an outage: the camera turned its HTTP API off itself. No login is tried until a push says it ended
                // (or a minute passed, to ask again over Baichuan), so the device never sees a run of refused logins.
                if !privacyLogged { logger.info("[\(address)] Privacy mode is on: the camera is added when it ends.") }
                privacyLogged = true
                await runtime.host.waitForPrivacyOff(timeout: dependencies.timing.seconds(60))
            } catch {
                if attempt == 0 {
                    logger.error("[\(address)] Cannot reach the Reolink device: \(error)")
                    markUnavailable(hostID: runtime.hostID)
                }
                let delay: Duration
                switch error {
                case ReolinkError.credentials: delay = .seconds(600)
                case ReolinkError.frequentLogins: delay = .seconds(60)
                default: delay = Self.backoff.delay(attempt: attempt)
                }
                attempt += 1
                try? await Task.sleep(for: delay * dependencies.timing.scale)
            }
        }
        guard !Task.isCancelled else { return }
        if attempt > 0 { logger.info("[\(address)] The Reolink device answers again.") }
        await publishChannels(address)
        await runtime.host.run()
    }

    private func markUnavailable(hostID: String?) {
        guard let hostID else { return }
        for accessory in context.accessories where Self.belongs(accessory.id, to: hostID) { accessory.isUnavailable = true }
    }

    static func belongs(_ id: String, to hostID: String) -> Bool {
        let prefix = accessoryID(deviceID: hostID)
        return id == prefix || id.hasPrefix(prefix + ":")
    }

    /// Publishes the channels of a connected host that are not published yet, and takes away those it no longer has.
    private func publishChannels(_ address: String) async {
        guard var runtime = runtimes[address] else { return }
        let host = runtime.host
        let info = await host.info
        guard let hostID = info.hostID ?? info.serial.nonEmptyText else { return }
        runtime.hostID = hostID
        runtime.info = info
        var known = hostsFile.load() ?? [:]
        if known[address.lowercased()] != hostID {
            known[address.lowercased()] = hostID
            try? hostsFile.save(known)
        }
        let channels = await host.channels.values.sorted { $0.channel < $1.channel }
        let deviceIDs = Dictionary(uniqueKeysWithValues: channels.map { ($0.channel, Self.deviceID(hostID: hostID, info: info, channel: $0)) })
        let canWrite = await host.isAdmin
        // A channel whose camera was swapped (its UID changed) is another device: the old one's accessory goes, and
        // the new one gets its own Device Id rather than the old one's rooms and settings.
        for channel in channels {
            guard let camera = runtime.cameras[channel.channel], let deviceID = deviceIDs[channel.channel],
                  camera.accessory.id != Self.accessoryID(deviceID: deviceID) else { continue }
            await camera.stop()
            runtime.cameras[channel.channel] = nil
        }
        var published = Set(runtime.cameras.values.map(\.accessory.id))
        for channel in channels where runtime.cameras[channel.channel] == nil {
            guard let deviceID = deviceIDs[channel.channel], !context.isExcluded(deviceID) else { continue }
            let options = (runtime.device.cameras[String(channel.channel)] ?? .defaults).with(settings: context.accessorySettings(for: deviceID).plugin)
            var started: ReolinkCamera?
            // Asked before the camera is made: only a camera published with two-way audio has a Speaker.
            let talk = options.twoWayAudio ? await host.talkConfig(channel: channel.channel, name: options.name ?? channel.name) : nil
            do {
                let camera = try await makeCamera(deviceID: deviceID, channel: channel, info: info, options: options, host: host, canWrite: canWrite, talk: talk)
                started = camera
                await camera.start()
                camera.apply(channel.state)
                try await context.publishExternal(camera.accessory)
                runtime.cameras[channel.channel] = camera
                published.insert(camera.accessory.id)
                // In the background: the next channel is published without waiting for the device's settings.
                let settings = options.deviceSettings, ch = channel.channel, name = camera.accessory.name
                if !settings.isEmpty { tasks.add { await host.apply(settings, channel: ch, name: name) } }
                if options.siren, !channel.siren { logger.info("[\(address)] \(camera.accessory.name): this camera has no siren.") }
            } catch {
                // Its streamer and prebuffer were started: they would hold one of the camera's RTSP sessions.
                await started?.stop()
                logger.error("[\(address)] Could not publish channel \(channel.channel + 1): \(error)")
                published.insert(Self.accessoryID(deviceID: deviceID))
            }
        }
        // A channel the host still lists but offline (or asleep, or another brand's) keeps its accessory, not
        // responding (7.4): taking it away would lose its room and automations in Apple Home.
        let wanted = runtime.device.channels
        let listed = Set(info.channels.filter { wanted?.contains($0.channel) ?? true }.map {
            Self.accessoryID(deviceID: Self.deviceID(hostID: hostID, info: info, channel: $0.channel, uid: $0.uid))
        })
        for accessory in context.accessories where Self.belongs(accessory.id, to: hostID) && !published.contains(accessory.id) {
            let excluded = context.isExcluded(String(accessory.id.dropFirst(Self.platform.count + 1)))
            if !excluded, listed.contains(accessory.id) || !info.isMultiChannel || !info.hasChannelStatus {
                accessory.isUnavailable = true
            } else {
                try? await context.remove(id: accessory.id)
            }
        }
        runtimes[address] = runtime
        let cameras = runtime.cameras
        await host.setListener({ channel, state in cameras[channel]?.apply(state) }, onTopologyChange: { [weak self] in
            Task { await self?.channelsChanged(address) }
        })
    }

    private func channelsChanged(_ address: String) async {
        guard let host = runtimes[address]?.host else { return }
        do {
            try await host.reloadChannels()
            await publishChannels(address)
        } catch {
            logger.debug("[\(address)] Could not read the new channels: \(error)")
        }
    }

    func ffmpeg() -> FfmpegOptions {
        if let ffmpegOptions { return ffmpegOptions }
        let codecs = FfmpegCodecs(ffmpegExec: configuration.videoProcessor, log: logger)
        let options = FfmpegOptions(FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: logger, name: { "Reolink" }))
        ffmpegOptions = options
        ffmpegCodecs = codecs
        // What FFmpeg has (its AAC encoder for audio): asked once, in the background.
        tasks.add { _ = await codecs.probe() }
        return options
    }

    private func makeCamera(deviceID: String, channel: ReolinkChannel, info: ReolinkHostInfo, options: CameraOptions, host: ReolinkHost, canWrite: Bool,
                            talk: ReolinkTalkConfig?) async throws -> ReolinkCamera {
        let ch = channel.channel
        let ffmpeg = ffmpeg()
        let name = options.name ?? channel.name
        let link = await host.talkLink(channel: ch)
        let talker = talk.map { ReolinkTalker(channel: ch, config: $0, link: link, name: name, log: logger, timing: dependencies.timing) }
        let source = ReolinkCameraSource(
            snapshot: { sub in try await host.snapshot(channel: ch, sub: sub) },
            stream: { sub in
                guard let url = await host.streamURL(channel: ch, sub: sub), let info = await host.channelInfo(ch) else { return nil }
                return (url, sub ? info.sub : info.main)
            },
            // A sleeping battery camera, or one in privacy mode, keeps its last snapshot.
            asleep: { await host.channelInfo(ch).map { ($0.battery && $0.state.asleep) || $0.state.privacy == true } ?? false })
        let streamer = ReolinkStreamer(name: name, options: options, ffmpeg: ffmpeg, ports: dependencies.ports, source: source, log: logger,
                                       timing: dependencies.timing, returnAudio: talker?.returnAudioOptions, codecs: ffmpegCodecs,
                                       returnAudioDecoder: dependencies.returnAudioDecoder)
        let recorder = options.recording ? ReolinkRecorder(name: name, fps: channel.main.fps, log: logger) {
            // RTSP whatever `streamProtocol` says: the recording's livestream reads RTSP over TCP.
            guard let url = await host.streamURL(channel: ch, sub: false, protocol: "rtsp") else { return nil }
            return RTSPRecordingSource(options: ffmpeg, url: url, codec: channel.main.codec, keepsPrebuffer: options.prebuffer)
        } : nil
        let writes = ReolinkCamera.Writes(
            floodlight: { on, brightness in try await host.setFloodlight(channel: ch, on: on, brightness: brightness) },
            siren: { [logger, timing = dependencies.timing] on in
                try await Self.waitForTalk(talker, siren: on, name: name, log: logger, timing: timing)
                try await host.setSiren(channel: ch, on: on)
            },
            ir: { on in try await host.setIRLights(channel: ch, on: on) },
            goToPreset: { id in try await host.ptzControl(channel: ch, op: "ToPos", id: id) },
            privacy: { on in try await host.setPrivacy(channel: ch, on: on) },
            floodlightColour: { mireds in try await host.setFloodlightColour(channel: ch, mireds: mireds) },
            chime: { [tone = options.chimeTone] id in try await host.playChime(channel: ch, chime: id, tone: tone) },
            recording: { on in try await host.setRecording(channel: ch, on: on) },
            patrol: { on in try await host.setPatrol(channel: ch, on: on) })
        let camera = try ReolinkCamera(
            id: Self.accessoryID(deviceID: deviceID), channel: channel, host: info, options: options, canWrite: canWrite,
            streamer: streamer, recorder: recorder, writes: writes, log: logger, timing: dependencies.timing, talker: talker)
        // A floodlight with Brightness and Color Temperature gets Adaptive Lighting, before the accessory is published.
        if let floodlight = camera.services.floodlight {
            camera.adaptiveLighting = context.adaptiveLighting(for: floodlight, accessoryID: camera.accessory.id)
        }
        return camera
    }

    /// A siren is not started while a Talk runs on its channel (ReolinkTalk.md 7): it waits for the Talk to end, a while.
    static func waitForTalk(_ talker: ReolinkTalker?, siren on: Bool, name: String, log: Logger, timing: ReolinkTiming) async throws {
        guard on, let talker, await talker.isTalking else { return }
        log.info("\(name): the siren waits for the Talk to end.")
        guard await talker.waitUntilIdle(timeout: timing.seconds(sirenTalkWait)) else { throw ReolinkError.unsupported("the siren while a Talk runs") }
    }

    // MARK: Tests

    func camera(host address: String, channel: Int) -> ReolinkCamera? { runtimes[address]?.cameras[channel] }
}

/// Puts the host's address before each line of the plugin's log.
struct ReolinkLogHandler: LogHandler {
    var base: Logger
    var prefix: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level {
        get { base.logLevel }
        set {}
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        base.log(level: event.level, "\(prefix)\(event.message)", metadata: event.metadata, source: event.source, file: event.file,
                 function: event.function, line: event.line)
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        base.log(level: level, "\(prefix)\(message)", metadata: metadata, source: source, file: file, function: function, line: line)
    }
}
