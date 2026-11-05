import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging

// Standalone battery cameras in the plugin (docs/clean-room/ReolinkBattery.md), Experimental: detected at Setup by their
// abilities when the HTTP API does not answer, published from what they said of themselves (so a sleeping camera is in
// HomeKit at launch without being woken), events by their webhook.
extension ReolinkPlugin {
    /// The Baichuan session of a battery camera's Setup and identification: the short timeouts of 3.3.
    func batterySession(_ entry: Device) -> BaichuanSession {
        BaichuanSession(host: entry.host, port: entry.baichuanPort ?? 9000, username: entry.username, password: entry.password,
                        connect: dependencies.connectBaichuan, log: hostLogger(entry.host), timing: dependencies.timing,
                        connectTimeout: ReolinkBatteryHost.connectTimeout, nonceTimeout: ReolinkBatteryHost.nonceTimeout, retriesWaking: true)
    }

    func hostLogger(_ address: String) -> Logger {
        let base = logger
        return Logger(label: base.label, factory: { _ in ReolinkLogHandler(base: base, prefix: "[\(address)] ") })
    }

    /// Publishes a battery camera from its record, or from what it says once it answers (a block written by hand).
    func startBattery(_ entry: Device) async {
        let known = hostsFile.load() ?? [:]
        var record = known[entry.host.lowercased()].flatMap { batteryRecords[$0] }
        var attempt = 0
        while record == nil, !Task.isCancelled {
            do {
                record = try await identifyBattery(entry)
            } catch {
                if attempt == 0 { logger.warning("[\(entry.host)] The battery camera does not answer (asleep or out of reach): it is added once it does (\(error)).") }
                try? await Task.sleep(for: Self.backoff.delay(attempt: attempt) * dependencies.timing.scale)
                attempt += 1
            }
        }
        guard let record, !Task.isCancelled, !context.isExcluded(record.identity.uid) else { return }
        do {
            try await publishBattery(entry, record: record)
        } catch {
            logger.error("[\(entry.host)] Could not publish the battery camera: \(error)")
        }
    }

    /// Logs in once and reads the camera's identity and battery; the record is kept.
    private func identifyBattery(_ entry: Device) async throws -> ReolinkBatteryHost.Record {
        let session = batterySession(entry)
        do {
            try await session.openOnce()
            let identity = try await session.batteryIdentity()
            let battery = try? await session.battery(channel: 0)
            await session.stop()
            let record = ReolinkBatteryHost.Record(identity: identity, battery: battery, webhookSupported: nil)
            keep(record, address: entry.host)
            return record
        } catch {
            await session.stop()
            throw error
        }
    }

    private func keep(_ record: ReolinkBatteryHost.Record, address: String) {
        batteryRecords[record.identity.uid] = record
        try? batteryRecords.flush()
        var known = hostsFile.load() ?? [:]
        if known[address.lowercased()] != record.identity.uid {
            known[address.lowercased()] = record.identity.uid
            try? hostsFile.save(known)
        }
    }

    /// The camera as an external accessory (9): Camera, Motion Sensor, Doorbell for a battery doorbell, Battery; no
    /// HomeKit Secure Video, no lights or siren.
    private func publishBattery(_ entry: Device, record: ReolinkBatteryHost.Record) async throws {
        let identity = record.identity
        let deviceID = identity.uid
        var options = (entry.cameras["0"] ?? .defaults).with(settings: context.accessorySettings(for: deviceID).plugin)
        options.recording = false
        options.prebuffer = false
        options.maxStreams = 1
        options.siren = false
        options.irLights = false
        let log = hostLogger(entry.host)
        let ffmpeg = ffmpeg()
        let records = batteryRecords
        let imageFile = context.storageDirectory.appendingPathComponent("snapshots").appendingPathComponent("\(Slug.make(identity.uid)).jpg")
        let host = ReolinkBatteryHost(
            device: entry, record: record, connect: dependencies.connectBaichuan, log: log, timing: dependencies.timing,
            motionTimeout: Double(options.motionTimeout), imageFile: imageFile,
            saveRecord: { record in
                records[record.identity.uid] = record
                try? records.flush()
            },
            toJPEG: { codec, keyframe in
                let arguments = ["-hide_banner", "-loglevel", "error", "-f", codec.demuxer, "-i", "pipe:0", "-frames:v", "1", "-f", "image2", "-"]
                return await FfmpegExec(ffmpeg, commandLineArgs: arguments, logErrors: false).exec(Data(keyframe), timeout: 10_000)?.stdout
            })
        var channel = ReolinkChannel(channel: 0, name: identity.name.nonEmptyText ?? identity.model.nonEmptyText ?? "Reolink Camera", model: identity.model,
                                     firmware: identity.firmware, hardware: identity.hardware, uid: identity.uid)
        channel.battery = true
        channel.motion = true
        // A battery doorbell says so in its model name; the `doorbell` option decides otherwise.
        channel.doorbell = identity.model.lowercased().contains("doorbell")
        var info = ReolinkHostInfo()
        info.type = "ipc"
        info.name = identity.name
        info.model = identity.model
        info.serial = identity.serial
        info.hardware = identity.hardware
        info.firmware = identity.firmware
        info.uid = identity.uid
        let source = ReolinkCameraSource(
            snapshot: { _ in throw ReolinkError.unsupported("Snap") }, stream: { _ in nil }, asleep: { true },
            media: { sub, audio in try await host.liveFeed(sub: sub, audio: audio) },
            snapshotRequest: { request in try await host.snapshot(for: request) })
        let name = options.name ?? channel.name
        // Asked before the camera is made: only a camera published with two-way audio has a Speaker.
        let talk = options.twoWayAudio ? await host.talkConfig(name: name) : nil
        let talker = talk.map { config in
            ReolinkTalker(channel: 0, config: config, link: ReolinkTalkLink(withSession: { body in try await host.talking(body) }), name: name, log: log,
                          timing: dependencies.timing)
        }
        let streamer = ReolinkStreamer(name: name, options: options, ffmpeg: ffmpeg, ports: dependencies.ports, source: source, log: log,
                                       timing: dependencies.timing, returnAudio: talker?.returnAudioOptions, codecs: ffmpegCodecs,
                                       returnAudioDecoder: dependencies.returnAudioDecoder)
        let refused: @Sendable () throws -> Void = { throw ReolinkError.unsupported("this control") }
        let writes = ReolinkCamera.Writes(
            floodlight: { _, _ in try refused() }, siren: { _ in try refused() }, ir: { _ in try refused() }, goToPreset: { _ in try refused() },
            privacy: { _ in try refused() }, floodlightColour: { _ in try refused() }, chime: { _ in try refused() }, recording: { _ in try refused() },
            patrol: { _ in try refused() })
        let camera = try ReolinkCamera(id: Self.accessoryID(deviceID: deviceID), channel: channel, host: info, options: options, canWrite: false,
                                       streamer: streamer, recorder: nil, writes: writes, log: log, timing: dependencies.timing, talker: talker)
        await camera.start()
        await host.setListener { state in camera.apply(state) }
        // Events find the camera from the moment it is in HomeKit.
        batteryRuntimes[entry.host] = BatteryRuntime(device: entry, host: host, camera: camera)
        do {
            try await context.publishExternal(camera.accessory)
        } catch {
            batteryRuntimes[entry.host] = nil
            await camera.stop()
            await host.stop()
            throw error
        }
        logger.info("[\(entry.host)] Battery camera \(camera.accessory.name) published (Experimental): it is reached only when HomeKit asks for video or a snapshot.")
        if let webhook = await webhook(toward: entry.host) {
            await host.setWebhook(url: webhook.url, path: webhook.path, takeOver: entry.takeOverEventPush)
        }
    }

    // MARK: The webhook (6.1)

    /// The URL a camera posts its events to, with the listener started on first use; nil when it cannot listen.
    func webhook(toward address: String) async -> (url: String, path: String)? {
        let task = webhookServer ?? Task { await self.startWebhookServer() }
        webhookServer = task
        guard let server = await task.value, let port = server.port, let local = dependencies.localAddress(address) else { return nil }
        return ("http://\(local):\(port)\(server.path)", server.path)
    }

    private func startWebhookServer() async -> ReolinkWebhookServer? {
        let tokenFile = context.secretFile("webhook", as: String.self)
        let token: String
        if let saved = tokenFile.load(), saved.count >= 16 {
            token = saved
        } else {
            token = Secrets.hex(Secrets.randomBytes(16))
            try? tokenFile.save(token)
        }
        let portFile = context.jsonFile("webhook.json", as: [String: Int].self)
        let wanted = configuration.webhookPort ?? portFile.load()?["port"] ?? 0
        let server = ReolinkWebhookServer(token: token)
        let handler: ReolinkWebhookServer.Handler = { [weak self] body in await self?.webhookReceived(body) }
        do {
            try await server.start(host: dependencies.webhookBindHost, port: wanted, handler: handler)
        } catch {
            // The kept port is taken: another one, kept in its place.
            guard wanted != 0, configuration.webhookPort == nil, (try? await server.start(host: dependencies.webhookBindHost, port: 0, handler: handler)) != nil else {
                logger.error("Battery cameras' event push cannot listen on port \(wanted): \(error)")
                return nil
            }
        }
        if configuration.webhookPort == nil, let port = server.port { try? portFile.save(["port": port]) }
        logger.info("Battery cameras' event push listens on port \(server.port ?? wanted).")
        return server
    }

    /// A body a camera posted: handed to the camera whose UID it carries.
    func webhookReceived(_ body: Data) async {
        guard let json = try? JSONValue(data: body), json.objectValue != nil else {
            logger.debug("Battery camera push: a body that is not JSON, ignored.")
            return
        }
        for runtime in batteryRuntimes.values where await runtime.host.handleWebhook(json) { return }
        logger.debug("Battery camera push for a camera that is not set up, ignored.")
    }

    // MARK: Setup (2.1)

    /// A device whose HTTP API did not answer, tried as a battery camera over Baichuan: its outcome when it is one; nil
    /// when it is not (or does not answer either).
    func authorizeBattery(address: String, username: String, password: String) async throws -> SetupOutcome? {
        guard var entry = Device(json: ["host": .string(address), "username": .string(username), "password": .string(password)]) else { return nil }
        entry.batteryCamera = true
        let session = batterySession(entry)
        do {
            try await session.openOnce()
        } catch BaichuanError.unauthorized {
            throw SetupError("The camera refused the user name or password.")
        } catch BaichuanError.accountDevice {
            throw SetupError("The camera is bound to a Reolink cloud account (an account device), which refuses local sign-in: switch it back to a local device in the Reolink app.")
        } catch {
            return nil
        }
        do {
            let kind = try await session.batteryKind()
            guard kind.isBatteryCamera else {
                await session.stop()
                return nil
            }
            guard !kind.udpOnly else {
                await session.stop()
                throw SetupError("This battery camera talks only over Reolink's UDP protocol, which Homeswift does not support yet: add it to a Reolink Home Hub or NVR, then add that instead.")
            }
            let identity = try await session.batteryIdentity()
            var record = ReolinkBatteryHost.Record(identity: identity, battery: try? await session.battery(channel: 0), webhookSupported: nil)
            if let webhook = await webhook(toward: address),
               let outcome = try? await ReolinkBatteryHost.subscribe(session, url: webhook.url, path: webhook.path, takeOver: false) {
                record.webhookSupported = outcome != .unsupported
                ReolinkBatteryHost.report(outcome, log: hostLogger(address))
            }
            await session.stop()
            keep(record, address: address)
            logger.info("Signed in to the \(identity.model.nonEmptyText ?? "Reolink") battery camera at \(address) through Setup (Experimental).")
            return try SetupOutcome(encoding: Login(username: username, password: password),
                                    settings: ["host": .string(address), "batteryCamera": true], deviceID: identity.uid)
        } catch let error as SetupError {
            throw error
        } catch {
            await session.stop()
            logger.info("The Reolink device at \(address) answered over Baichuan but not as a battery camera: \(error)")
            return nil
        }
    }
}
