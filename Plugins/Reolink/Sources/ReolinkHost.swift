import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// One host (a camera, a doorbell, an NVR or a Home Hub) and its channels (section 7): the start-up batches, Baichuan
/// push with polling while it is not active, the full refresh, and the writes, all over one HTTP session and one
/// Baichuan connection.
actor ReolinkHost {
    typealias Listener = @Sendable (_ channel: Int, _ state: ReolinkChannelState) -> Void

    let device: ReolinkPlugin.Device
    let http: ReolinkHTTPClient
    private let connectBaichuan: BaichuanSession.Connect
    private let log: Logger
    private let timing: ReolinkTiming

    private(set) var info = ReolinkHostInfo()
    private(set) var channels: [Int: ReolinkChannel] = [:]
    private(set) var pushActive = false
    private(set) var baichuan: BaichuanSession?
    private var listener: Listener?
    private var onTopologyChange: (@Sendable () -> Void)?
    private var online = true
    private var pollFailing = false
    private let tasks = TaskBag()
    /// The port the Baichuan session was opened on.
    private var baichuanPort: Int?
    /// A camera on its own whose login reply has `sleep`: it has privacy mode (addendum C).
    private var hasLoginPrivacy = false
    /// Privacy mode of a camera on its own before its channels are read (its first channel, by push or at login).
    private var privacyBeforeConnect: Bool?
    /// `cmd_id` 199's abilities by channel, when Baichuan answered before the channels were read.
    private var baichuanAbilities: [Int: [String: Int]] = [:]
    /// Who waits for privacy mode to end (`waitForPrivacyOff`).
    private var privacyWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    init(device: ReolinkPlugin.Device, http: ReolinkHTTPClient, connectBaichuan: @escaping BaichuanSession.Connect, log: Logger, timing: ReolinkTiming) {
        self.device = device
        self.http = http
        self.connectBaichuan = connectBaichuan
        self.log = log
        self.timing = timing
    }

    static let eventCommandNames: Set<String> = ["GetEvents", "GetMdState", "GetAiState"]

    /// A channel's motion and AI commands (5.5): `GetEvents`, or `GetMdState` and `GetAiState` without it.
    static func eventCommands(for channel: ReolinkChannel) -> [ReolinkCommand] {
        if channel.hasGetEvents { return [.channel("GetEvents", channel.channel)] }
        return (channel.motion ? [.channel("GetMdState", channel.channel)] : []) + (channel.aiTypes.isEmpty ? [] : [.channel("GetAiState", channel.channel)])
    }

    func setListener(_ listener: @escaping Listener, onTopologyChange: @escaping @Sendable () -> Void) {
        self.listener = listener
        self.onTopologyChange = onTopologyChange
    }

    var hostID: String? { info.hostID }
    var isAdmin: Bool { info.isAdmin ?? true }

    // MARK: Start-up (4.1, 4.2)

    static func hostCommands(username: String) -> [ReolinkCommand] {
        [ReolinkCommand(cmd: "GetChannelstatus", action: nil, param: nil)]
            + ["GetDevInfo", "GetLocalLink", "GetNetPort", "GetP2p", "GetHddInfo", "GetUser", "GetNtp", "GetTime", "GetPushCfg"].map { ReolinkCommand(cmd: $0) }
            + [ReolinkCommand(cmd: "GetAbility", param: ["User": ["userName": .string(username)]])]
    }

    /// Logs in and reads the host and its channels. With push, the Baichuan session comes first: a camera in privacy
    /// mode refuses HTTP logins, so it is asked over Baichuan before one is tried (addendum C), and `privacy` is thrown
    /// rather than a login error.
    func connect() async throws {
        if let session = startBaichuan(port: device.baichuanPort ?? 9000), await session.waitUntilReady(timeout: timing.timeout(10)) {
            if let deviceInfo = await session.deviceInfo, !Self.multiChannelTypes.contains(deviceInfo.value("type")?.lowercased() ?? ""),
               let sleep = deviceInfo.value("sleep") {
                hasLoginPrivacy = true
                // The login's `sleep` is as old as the session: asked again.
                let on = ((try? await session.privacy(channel: 0)) ?? nil) ?? (sleep == "1")
                privacyBeforeConnect = on
                if on { throw ReolinkError.privacy }
            }
        }
        let commands = Self.hostCommands(username: device.username)
        let replies = try await http.execute(commands)
        var info = ReolinkHostInfo()
        for reply in replies {
            if reply.cmd == "GetUser" { info.applyUsers(reply, username: device.username) } else { info.apply(reply) }
        }
        guard !info.serial.isEmpty || info.hostID != nil else { throw ReolinkError.invalidResponse("GetDevInfo gave no serial") }
        if info.isAdmin == false { log.warning("The user \(device.username) is not an administrator: floodlights, sirens and IR lights stay read-only.") }
        self.info = info
        if let baichuan, await baichuan.isConnected, let abilities = try? await baichuan.abilities() { baichuanAbilities = abilities }
        channels = try await readWantedChannels()
        await readPrivacy()
        setOnline(true)
        log.info("Connected to \(info.model.isEmpty ? "the Reolink device" : info.model) (firmware \(info.firmware), \(channels.count) channel\(channels.count == 1 ? "" : "s")).")
    }

    private func readChannels(_ statuses: [ReolinkChannelStatus]) async throws -> [Int: ReolinkChannel] {
        var commands: [ReolinkCommand] = []
        var ranges: [(status: ReolinkChannelStatus, range: Range<Int>, battery: Bool)] = []
        let v20 = info.hostAbility("scheduleVersion") >= 1
        for status in statuses {
            let ch = status.channel
            let battery = info.ability("battery", channel: ch) > 0
            let start = commands.count
            if info.isMultiChannel { commands.append(.channel("GetChnTypeInfo", ch)) }
            // Waking commands are left out for battery cameras behind a hub (4.3).
            if !battery { commands.append(.channel("GetEnc", ch)) }
            if info.hostAbility("rtsp") >= 3 { commands.append(.channel("GetRtspUrl", ch)) }
            commands += [.channel("GetMdState", ch), .channel("GetAiState", ch), .channel("GetEvents", ch)]
            if !battery { commands.append(.channel("GetWhiteLed", ch)) }
            commands.append(.channel("GetIrLights", ch))
            if v20 { commands.append(.channel("GetAudioAlarmV20", ch)) } else if !battery { commands.append(.channel("GetAudioAlarm", ch)) }
            if battery { commands.append(.channel("GetBatteryInfo", ch)) }
            commands += Self.ptzCommands(info: info, channel: ch, battery: battery)
            // A battery doorbell on a hub is left out, as reolink-aio does.
            if info.ability("supportDingDongCtrl", channel: ch) > 0, !(battery && info.isHub) { commands.append(.channel("GetDingDongList", ch)) }
            ranges.append((status, start..<commands.count, battery))
        }
        let replies = try await http.execute(commands)
        var result: [Int: ReolinkChannel] = [:]
        for (status, range, battery) in ranges {
            let items = Dictionary(range.map { (replies[$0].cmd, replies[$0]) }, uniquingKeysWith: { first, _ in first })
            result[status.channel] = channel(status: status, items: items, battery: battery)
        }
        return result
    }

    private func channel(status: ReolinkChannelStatus, items: [String: ReolinkReply], battery: Bool) -> ReolinkChannel {
        let ch = status.channel
        let typeInfo = items["GetChnTypeInfo"].flatMap { $0.ok ? $0.value : nil }
        let model = typeInfo?["typeInfo"]?.stringValue?.nonEmptyText ?? status.model ?? info.model
        let defaultName = info.isMultiChannel ? "Channel \(ch + 1)" : (info.name.nonEmptyText ?? "Reolink")
        var channel = ReolinkChannel(
            channel: ch, name: status.name ?? defaultName, model: model,
            firmware: ReolinkParse.firmware(typeInfo?["firmVer"]?.stringValue ?? info.firmware),
            hardware: typeInfo?["boardInfo"]?.stringValue ?? info.hardware, uid: status.uid)
        channel.battery = battery
        channel.state.asleep = status.asleep
        let h265 = info.ability("mainEncType", channel: ch) > 0
        channel.main.codec = h265 ? "h265" : "h264"
        if let enc = items["GetEnc"], enc.ok {
            channel.main = ReolinkParse.stream(enc.value?["Enc"]?["mainStream"], fallback: channel.main)
            channel.sub = ReolinkParse.stream(enc.value?["Enc"]?["subStream"], fallback: channel.sub)
        }
        if let urls = items["GetRtspUrl"], urls.ok {
            channel.main.rtspURL = urls.value?["rtspUrl"]?["mainStream"]?.stringValue
            channel.sub.rtspURL = urls.value?["rtspUrl"]?["subStream"]?.stringValue
        }
        if let events = items["GetEvents"].flatMap({ ReolinkParse.events($0, channel: ch) }) {
            channel.hasGetEvents = true
            channel.motion = events.motion?.supported ?? false
            for (type, flag) in events.ai where flag.supported && type != "other" { channel.aiTypes.insert(type) }
            if battery, events.ai["other"]?.supported == true { channel.motion = true }
            if events.visitor?.supported == true { channel.doorbell = true }
        } else {
            if items["GetMdState"]?.ok == true { channel.motion = true }
            for (type, flag) in items["GetAiState"].flatMap({ ReolinkParse.aiState($0, channel: ch) }) ?? [:] where flag.supported {
                channel.aiTypes.insert(type)
            }
        }
        if channel.aiTypes.contains("dog_cat"), info.ability("supportAiAnimal", channel: ch) == 0, info.hostAbility("supportAiAnimal") == 0 {
            channel.aiTypes.remove("dog_cat")
        }
        if model.contains("Doorbell") || info.ability("supportDoorbellLight", channel: ch) > 0 { channel.doorbell = true }
        if items["GetWhiteLed"]?.ok == true, info.ability("floodLight", channel: ch) > 0 || info.ability("supportFLswitch", channel: ch) > 0 {
            channel.floodlight = true
            let ledCtrl = baichuanAbilities[ch]?["ledCtrl"]
            channel.floodlightColour = (ledCtrl ?? 0) & (1 << 17) != 0
            channel.floodlightModes = ReolinkFloodlight.offeredModes(
                ledCtrl: ledCtrl, flSchedule: info.ability("supportFLSchedule", channel: ch) > 0, flKeepOn: info.ability("supportFLKeepOn", channel: ch) > 0,
                autoBrightness: info.ability("supportLightAutoBrightness", channel: ch) > 0)
        }
        if info.ability("ledControl", channel: ch) > 0, items["GetIrLights"]?.ok == true { channel.irLights = true }
        let audio = items["GetAudioAlarmV20"] ?? items["GetAudioAlarm"]
        if audio?.ok == true, info.ability("alarmAudio", channel: ch) > 0 || info.ability("supportAudioAlarm", channel: ch) > 0 || info.hostAbility("alarmAudio") > 0 {
            channel.siren = true
        }
        channel.ptz = Self.ptz(info: info, channel: ch, items: items)
        if let list = items["GetDingDongList"], list.ok { channel.chimes = ReolinkChime.paired(list.value) }
        for reply in items.values { apply(reply, to: &channel) }
        return channel
    }

    /// The PTZ reads of a channel's start-up batch (addendum B): presets, patrols and the guard for a camera that pans,
    /// the zoom's range for one that zooms. A battery camera is not woken for the guard or the zoom.
    static func ptzCommands(info: ReolinkHostInfo, channel ch: Int, battery: Bool) -> [ReolinkCommand] {
        guard let ptz = ReolinkPTZ.capabilities(ptzType: info.ability("ptzType", channel: ch), speedAbility: nil) else { return [] }
        var commands: [ReolinkCommand] = []
        if ptz.pan {
            if info.ability("ptzPreset", channel: ch) > 0 { commands.append(.channel("GetPtzPreset", ch)) }
            commands.append(.channel("GetPtzPatrol", ch))
            if !battery { commands.append(.channel("GetPtzGuard", ch)) }
        }
        if ptz.zoom, !battery { commands.append(ReolinkCommand(cmd: "GetZoomFocus", action: 1, param: ["channel": .number(Double(ch))])) }
        return commands
    }

    static func ptz(info: ReolinkHostInfo, channel ch: Int, items: [String: ReolinkReply]) -> ReolinkPTZ? {
        guard var ptz = ReolinkPTZ.capabilities(ptzType: info.ability("ptzType", channel: ch), speedAbility: info.reportedAbility("supportPtzSpeed", channel: ch))
        else { return nil }
        if let reply = items["GetPtzPreset"], reply.ok { ptz.presets = ReolinkPTZ.entries(reply.value?["PtzPreset"], fallback: "Preset") }
        if let reply = items["GetPtzPatrol"], reply.ok { ptz.patrols = ReolinkPTZ.entries(reply.value?["PtzPatrol"], fallback: "patrol") }
        ptz.hasGuard = items["GetPtzGuard"]?.ok == true
        if let reply = items["GetZoomFocus"], reply.ok {
            ptz.zoomRange = ReolinkPTZ.range(reply.range?["ZoomFocus"]?["zoom"]?["pos"])
            ptz.focusRange = ReolinkPTZ.range(reply.range?["ZoomFocus"]?["focus"]?["pos"])
        }
        return ptz
    }

    static let multiChannelTypes: Set<String> = ["nvr", "wifi_nvr", "homehub"]

    /// The Baichuan session, made once (`pushEvents`), its events handled from then on.
    private func startBaichuan(port: Int) -> BaichuanSession? {
        guard device.pushEvents else { return nil }
        if let baichuan { return baichuan }
        let session = BaichuanSession(host: device.host, port: port, username: device.username, password: device.password, connect: connectBaichuan, log: log, timing: timing)
        baichuan = session
        baichuanPort = port
        tasks.add { await session.run() }
        tasks.add { [weak self] in
            for await event in session.events { await self?.handle(event) }
        }
        return session
    }

    /// Privacy mode of each channel that may have it (a camera whose login reply had `sleep`; an NVR's channel with
    /// `remoteAbility`): a 574 reply with `sleep` says it has it.
    private func readPrivacy() async {
        guard let baichuan, await baichuan.isConnected else { return }
        for ch in channels.keys.sorted() {
            let eligible = info.isMultiChannel ? info.ability("remoteAbility", channel: ch) > 0 : hasLoginPrivacy && ch == 0
            guard eligible, let on = (try? await baichuan.privacy(channel: ch)) ?? nil else { continue }
            channels[ch]?.privacy = true
            channels[ch]?.state.privacy = on
        }
    }

    /// Whether a camera on its own is in privacy mode: its HTTP API is off, so nothing is asked of it.
    var isPrivate: Bool {
        guard !info.isMultiChannel else { return false }
        return channels.isEmpty ? privacyBeforeConnect == true : channels[0]?.state.privacy == true
    }

    /// Waits until privacy mode is off (a push says so) or `timeout` passes.
    func waitForPrivacyOff(timeout: Duration) async {
        guard isPrivate else { return }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resumePrivacyWaiter(id)
        }
        defer { timer.cancel() }
        await withCheckedContinuation { privacyWaiters[id] = $0 }
    }

    private func resumePrivacyWaiter(_ id: Int) { privacyWaiters.removeValue(forKey: id)?.resume() }

    private func privacyChanged(channel: Int, on: Bool) {
        let multi = info.isMultiChannel
        if channels.isEmpty {
            guard channel == 0 else { return }
            privacyBeforeConnect = on
        } else {
            guard channels[channel] != nil, channels[channel]?.state.privacy != on else { return }
            channels[channel]?.state.privacy = on
            publish(channel)
        }
        guard !multi, channel == 0 else { return }
        if on {
            log.info("Privacy mode is on: the camera's video and HTTP API are off until it ends.")
        } else {
            log.info("Privacy mode is off.")
            let waiters = privacyWaiters
            privacyWaiters = [:]
            for waiter in waiters.values { waiter.resume() }
            if !channels.isEmpty { tasks.add { [weak self] in await self?.refresh() } }
        }
    }

    /// Whether a failed request is privacy mode turning on (a camera on its own whose push did not say so yet).
    private func privacyExplainsFailure() async -> Bool {
        guard !info.isMultiChannel, channels[0]?.privacy == true, let baichuan, await baichuan.isConnected,
              let on = (try? await baichuan.privacy(channel: 0)) ?? nil, on else { return false }
        privacyChanged(channel: 0, on: true)
        return true
    }

    // MARK: State

    /// Applies one item of a refresh to a channel's state.
    private func apply(_ reply: ReolinkReply, to channel: inout ReolinkChannel) {
        guard reply.ok, let value = reply.value else { return }
        let ch = channel.channel
        switch reply.cmd {
        case "GetEvents":
            guard let events = ReolinkParse.events(reply, channel: ch) else { return }
            var motion = events.motion?.state ?? false
            if channel.battery, events.ai["other"]?.state == true { motion = true }
            channel.state.motion = motion
            for type in channel.aiTypes { channel.state.ai[type] = events.ai[type]?.state ?? false }
            if let visitor = events.visitor { channel.state.visitor = visitor.state }
        case "GetMdState":
            guard !channel.hasGetEvents else { return }
            channel.state.motion = value["state"]?.saturatingIntValue == 1
        case "GetAiState":
            guard !channel.hasGetEvents, let ai = ReolinkParse.aiState(reply, channel: ch) else { return }
            for type in channel.aiTypes { channel.state.ai[type] = ai[type]?.state ?? false }
        case "GetWhiteLed":
            let led = value["WhiteLed"]
            if let state = led?["state"]?.saturatingIntValue { channel.state.floodlightOn = state == 1 }
            if let bright = led?["bright"]?.saturatingIntValue(in: 0...100) { channel.state.floodlightBrightness = bright }
            if let mode = led?["mode"]?.saturatingIntValue(in: 0...255) { channel.state.floodlightMode = mode }
            if channel.floodlightColour, let value = led?["ColorTemp"]?.saturatingIntValue(in: 0...100) {
                channel.state.floodlightMireds = ReolinkFloodlight.mireds(kelvin: ReolinkFloodlight.kelvin(value))
            }
        case "GetIrLights":
            if let state = value["IrLights"]?["state"]?.stringValue { channel.state.irOn = state != "Off" }
        case "GetBatteryInfo":
            let battery = value["Battery"]
            channel.state.batteryPercent = battery?["batteryPercent"]?.saturatingIntValue(in: 0...100) ?? channel.state.batteryPercent
            if let status = battery?["chargeStatus"]?.saturatingIntValue { channel.state.charging = status == 1 }
        default:
            break
        }
    }

    private func publish(_ channel: Int) {
        guard let state = channels[channel]?.state else { return }
        listener?(channel, state)
    }

    private func setOnline(_ value: Bool) {
        guard online != value else { return }
        online = value
        for key in channels.keys {
            channels[key]?.state.online = value
            publish(key)
        }
    }

    // MARK: Running (7.1)

    /// Starts push, motion polling while push is not active, and the full refresh.
    func run() async {
        // `GetNetPort` may name another Baichuan port than the one tried before it was known.
        if device.pushEvents, device.baichuanPort == nil, let media = info.mediaPort, media != baichuanPort, let session = baichuan, await !session.isConnected {
            await session.stop()
            baichuan = nil
            _ = startBaichuan(port: media)
        }
        let motionInterval = timing.seconds(Double(device.motionPollInterval))
        tasks.add { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: motionInterval)
                guard let self, !Task.isCancelled else { return }
                await self.pollMotionIfNeeded()
            }
        }
        let refreshInterval = timing.seconds(Double(device.refreshInterval(cameras: channels.count)))
        tasks.add { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() async {
        tasks.cancelAll()
        await baichuan?.stop()
        await http.shutdown()
    }

    private func handle(_ event: BaichuanSessionEvent) {
        switch event {
        case .active(let active):
            pushActive = active
            log.info(active ? "Push events active: motion polling stops." : "Push events lost: polling motion every \(device.motionPollInterval) s.")
        case .push(let push):
            apply(push)
        }
    }

    func apply(_ push: ReolinkPush) {
        switch push {
        case .alarm(let ch, let motion, let visitor, let detected):
            guard var channel = channels[ch] else { return }
            if let motion { channel.state.motion = motion }
            if let visitor { channel.state.visitor = visitor }
            if let detected { for type in channel.aiTypes { channel.state.ai[type] = detected.contains(type) } }
            channels[ch] = channel
        case .sleep(let ch, let asleep):
            channels[ch]?.state.asleep = asleep
        case .floodlight(let ch, let on):
            channels[ch]?.state.floodlightOn = on
        case .siren(let ch, let playing):
            channels[ch]?.state.sirenPlaying = playing
        case .privacy(let ch, let on):
            privacyChanged(channel: ch, on: on)
            return
        case .dayNight:
            return
        }
        switch push {
        case .alarm(let ch, _, _, _), .sleep(let ch, _), .floodlight(let ch, _), .siren(let ch, _): publish(ch)
        case .dayNight, .privacy: break
        }
    }

    /// The motion batch of 5.5, only while push is not active.
    func pollMotionIfNeeded() async {
        guard !pushActive, !channels.isEmpty, !isPrivate else { return }
        await run(channels.values.sorted(by: { $0.channel < $1.channel }).flatMap(Self.eventCommands(for:)))
    }

    /// The full refresh of 4.3: non-waking commands for battery channels, the channel list of an NVR or hub.
    func refresh() async {
        guard !isPrivate else { return }
        let v20 = info.hostAbility("scheduleVersion") >= 1
        var commands: [ReolinkCommand] = []
        // While push is active it is the events' source: a poll's answer could come after a newer push.
        for channel in channels.values.sorted(by: { $0.channel < $1.channel }) {
            let ch = channel.channel
            if !pushActive { commands += Self.eventCommands(for: channel) }
            if channel.irLights { commands.append(.channel("GetIrLights", ch)) }
            if channel.floodlight, !channel.battery { commands.append(.channel("GetWhiteLed", ch)) }
            if channel.battery { commands.append(.channel("GetBatteryInfo", ch)) }
            if channel.siren, v20 || !channel.battery { commands.append(.channel(v20 ? "GetAudioAlarmV20" : "GetAudioAlarm", ch)) }
        }
        if info.isMultiChannel { commands.append(ReolinkCommand(cmd: "GetChannelstatus", action: 0, param: [:])) }
        await run(commands)
    }

    private func run(_ commands: [ReolinkCommand]) async {
        guard !commands.isEmpty else { return }
        do {
            let replies = try await http.execute(commands)
            if pollFailing { log.info("The device answers again.") }
            pollFailing = false
            setOnline(true)
            apply(replies, commands: commands)
        } catch {
            // Privacy mode turns the HTTP API off: not an outage, and no login is tried until it ends.
            if await privacyExplainsFailure() { return }
            if !pollFailing { log.error("Could not refresh the device: \(error)") } else { log.debug("Could not refresh the device: \(error)") }
            pollFailing = true
            setOnline(false)
        }
    }

    private func apply(_ replies: [ReolinkReply], commands: [ReolinkCommand]) {
        var touched = Set<Int>()
        for (command, reply) in zip(commands, replies) {
            if reply.cmd == "GetChannelstatus" {
                if reply.ok, let value = reply.value { channelStatus(ReolinkHostInfo.channelStatus(value)) }
                continue
            }
            if pushActive, Self.eventCommandNames.contains(reply.cmd) { continue }
            guard let ch = command.param?["channel"]?.saturatingIntValue, var channel = channels[ch] else { continue }
            apply(reply, to: &channel)
            channels[ch] = channel
            touched.insert(ch)
        }
        for ch in touched.sorted() { publish(ch) }
    }

    /// An NVR's channel list (4.3): a channel gone offline is marked so, a new one makes the plugin publish it.
    private func channelStatus(_ statuses: [ReolinkChannelStatus]) {
        var changed = false
        for status in statuses {
            if var channel = channels[status.channel] {
                // The UID only: `GetChnTypeInfo`'s model may be spelled differently from this list's, which would
                // reload the channels at every refresh.
                if channel.uid != status.uid { changed = true }
                if channel.state.online != status.online || channel.state.asleep != status.asleep {
                    channel.state.online = status.online
                    channel.state.asleep = status.asleep
                    channels[status.channel] = channel
                    publish(status.channel)
                }
            } else if status.online, !status.isForeign, device.channels?.contains(status.channel) ?? true {
                changed = true
            }
        }
        if changed {
            log.info("New Reolink device on the \(info.isHub ? "hub" : "NVR"): refreshing its channels.")
            onTopologyChange?()
        }
    }

    // MARK: Writes (4.4, 7.2)

    func setFloodlight(channel: Int, on: Bool?, brightness: Int?) async throws {
        guard channels[channel]?.state.online != false else { throw ReolinkError.offline }
        var led: [String: JSONValue] = ["channel": .number(Double(channel))]
        if let on { led["state"] = .number(on ? 1 : 0) }
        if let brightness {
            guard (0...100).contains(brightness) else { throw ReolinkError.invalidResponse("brightness out of range") }
            led["bright"] = .number(Double(brightness))
        }
        try await write(ReolinkCommand(cmd: "SetWhiteLed", action: nil, param: ["WhiteLed": .object(led)]))
        if let on { channels[channel]?.state.floodlightOn = on }
        if let brightness { channels[channel]?.state.floodlightBrightness = brightness }
        // The light settles before it is read back.
        let delay = timing.seconds(3)
        tasks.add { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.reread("GetWhiteLed", channel: channel)
        }
    }

    /// The floodlight's colour temperature, over Baichuan (D.1: 289 read, `newColorTemperature` changed, 290 back), then
    /// read back over HTTP as a brightness is.
    func setFloodlightColour(channel: Int, mireds: Int) async throws {
        guard channels[channel]?.floodlightColour == true else { throw ReolinkError.unsupported("colour temperature") }
        guard let baichuan, await baichuan.isConnected else { throw ReolinkError.unsupported("colour temperature without the Baichuan connection") }
        guard let value = ReolinkFloodlight.value(kelvin: ReolinkFloodlight.kelvin(mireds: mireds)) else {
            throw ReolinkError.outOfRange("\(mireds) mireds is outside 3000 to 6000 K")
        }
        try await baichuan.updateFloodlightTask(channel: channel, changes: ["newColorTemperature": String(value)])
        channels[channel]?.state.floodlightMireds = mireds
        let delay = timing.seconds(3)
        tasks.add { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.reread("GetWhiteLed", channel: channel)
        }
    }

    /// Plays a tone on a paired Reolink Chime (`DingDongOpt` option 4).
    func playChime(channel: Int, chime: Int, tone: Int) async throws {
        guard channels[channel]?.chimes.contains(where: { $0.id == chime }) == true else { throw ReolinkError.unsupported("DingDongOpt") }
        try await write(ReolinkCommand(cmd: "DingDongOpt", action: 0, param: ["DingDong": [
            "channel": .number(Double(channel)), "id": .number(Double(chime)), "option": 4, "musicId": .number(Double(min(9, max(0, tone)))),
        ]]))
    }

    // MARK: Accessory Settings the device keeps

    /// What a channel's Accessory Settings ask of the device itself: written once at start, in one batch, only where the
    /// device differs.
    struct DeviceSettings: Sendable, Equatable {
        var floodlightMode: String?
    }

    func apply(_ settings: DeviceSettings, channel ch: Int, name: String) async {
        guard let channel = channels[ch], !isPrivate else { return }
        var writes: [ReolinkCommand] = []
        if let mode = settings.floodlightMode, channel.floodlight {
            if let number = ReolinkFloodlight.modeNumber(mode), channel.floodlightModes.contains(mode) {
                if channel.state.floodlightMode != number {
                    writes.append(ReolinkCommand(cmd: "SetWhiteLed", action: 0, param: ["WhiteLed": ["channel": .number(Double(ch)), "mode": .number(Double(number))]]))
                }
            } else {
                log.warning("\(name): the floodlight has no mode \(mode); it offers \(channel.floodlightModes.joined(separator: ", ")).")
            }
        }
        guard !writes.isEmpty else { return }
        do {
            let replies = try await http.execute(writes)
            for (command, reply) in zip(writes, replies) where !reply.writeOK {
                log.warning("\(name): the device refused \(command.cmd) (\(reply.rspCode.map(String.init) ?? "?")).")
            }
        } catch {
            log.warning("\(name): could not write the settings: \(error)")
            return
        }
        // Read back in one batch.
        let reads = Set(writes.map { "Get" + $0.cmd.dropFirst(3) }).sorted().map { ReolinkCommand.channel($0, ch) }
        guard let replies = try? await http.execute(reads), var state = channels[ch] else { return }
        for reply in replies { apply(reply, to: &state) }
        channels[ch] = state
        publish(ch)
    }

    func setIRLights(channel: Int, on: Bool) async throws {
        guard channels[channel]?.state.online != false else { throw ReolinkError.offline }
        try await write(ReolinkCommand(cmd: "SetIrLights", action: 0, param: ["IrLights": ["channel": .number(Double(channel)), "state": .string(on ? "Auto" : "Off")]]))
        channels[channel]?.state.irOn = on
        await reread("GetIrLights", channel: channel)
    }

    /// The manual siren (4.4, 5.4.3): over Baichuan when its session is up, HTTP `AudioAlarmPlay` otherwise.
    func setSiren(channel: Int, on: Bool) async throws {
        guard channels[channel]?.state.online != false else { throw ReolinkError.offline }
        if let baichuan, await baichuan.isConnected {
            do {
                try await baichuan.siren(channel: channel, mode: .manual(on))
            } catch where on {
                log.debug("The manual siren failed (\(error)): playing it twice instead.")
                try await baichuan.siren(channel: channel, mode: .times(2))
            }
        } else {
            try await write(ReolinkCommand(cmd: "AudioAlarmPlay", action: 0, param: ["alarm_mode": "manul", "manual_switch": .number(on ? 1 : 0), "channel": .number(Double(channel))]))
        }
        channels[channel]?.state.sirenPlaying = on
    }

    // MARK: PTZ (addendum B)

    /// A `PtzCtrl` command: a move until `Stop`, `ToPos` a preset, `StartPatrol`/`StopPatrol`. `speed` goes only to a
    /// camera that takes it.
    func ptzControl(channel: Int, op: String, id: Int? = nil, speed: Int? = nil) async throws {
        guard let ptz = channels[channel]?.ptz else { throw ReolinkError.unsupported("PtzCtrl") }
        guard channels[channel]?.state.online != false else { throw ReolinkError.offline }
        var param: [String: JSONValue] = ["channel": .number(Double(channel)), "op": .string(op)]
        if let id { param["id"] = .number(Double(id)) }
        if let speed, ptz.speed { param["speed"] = .number(Double(min(64, max(1, speed)))) }
        try await write(ReolinkCommand(cmd: "PtzCtrl", action: 0, param: .object(param)))
    }

    /// Absolute zoom and focus (B.5), refused outside the ranges `GetZoomFocus` gave.
    func setZoomFocus(channel: Int, zoom: Int?, focus: Int?) async throws {
        guard let ptz = channels[channel]?.ptz, ptz.zoom else { throw ReolinkError.unsupported("StartZoomFocus") }
        var commands: [ReolinkCommand] = []
        for (op, value, range) in [("ZoomPos", zoom, ptz.zoomRange), ("FocusPos", focus, ptz.focusRange)] {
            guard let value else { continue }
            guard let range else { throw ReolinkError.unsupported(op) }
            guard range.contains(value) else { throw ReolinkError.outOfRange("\(op) \(value) is outside \(range.lowerBound)...\(range.upperBound)") }
            commands.append(ReolinkCommand(cmd: "StartZoomFocus", action: 0, param: ["ZoomFocus": ["channel": .number(Double(channel)), "op": .string(op), "pos": .number(Double(value))]]))
        }
        for command in commands { try await write(command) }
    }

    /// The guard (B.6): `toPos` goes to the home position, `setPos` saves the current one; `enable` and `timeout` (seconds
    /// idle) change the return, sent with `setPos`.
    func ptzGuard(channel: Int, goHome: Bool, saveHere: Bool, enable: Bool?, timeout: Int?) async throws {
        guard channels[channel]?.ptz?.hasGuard == true else { throw ReolinkError.unsupported("SetPtzGuard") }
        var fields: [String: JSONValue] = ["channel": .number(Double(channel)), "cmdStr": .string(goHome ? "toPos" : "setPos")]
        if !goHome {
            if saveHere { fields["bSaveCurrentPos"] = 1 }
            if let enable { fields["benable"] = .number(enable ? 1 : 0) }
            if let timeout { fields["timeout"] = .number(Double(max(1, timeout))) }
        }
        try await write(ReolinkCommand(cmd: "SetPtzGuard", action: 0, param: ["PtzGuard": .object(fields)]))
    }

    /// Starts or stops the first enabled patrol (as reolink-aio), and asks whether it runs a second later (Baichuan 64).
    func setPatrol(channel: Int, on: Bool) async throws {
        guard let patrol = channels[channel]?.ptz?.patrols.first else { throw ReolinkError.unsupported("patrol") }
        try await ptzControl(channel: channel, op: on ? "StartPatrol" : "StopPatrol", id: patrol.id)
        channels[channel]?.state.patrolling = on
        let delay = timing.seconds(1)
        tasks.add { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.readPatrol(channel)
        }
    }

    private func readPatrol(_ channel: Int) async {
        guard let baichuan, await baichuan.isConnected, let running = try? await baichuan.patrolRunning(channel: channel) else { return }
        channels[channel]?.state.patrolling = running
        publish(channel)
    }

    /// Privacy mode (addendum C, Baichuan 575), read back.
    func setPrivacy(channel: Int, on: Bool) async throws {
        guard let baichuan, await baichuan.isConnected else { throw ReolinkError.unsupported("privacy mode without the Baichuan connection") }
        let now = try await baichuan.setPrivacy(channel: channel, on: on) ?? on
        privacyChanged(channel: channel, on: now)
    }

    private func write(_ command: ReolinkCommand) async throws {
        guard !isPrivate else { throw ReolinkError.privacy }
        let replies = try await http.execute([command])
        guard let reply = replies.first, reply.writeOK else {
            let reply = replies.first
            if reply?.rspCode == -9 || reply?.rspCode == -26 { throw ReolinkError.unsupported(command.cmd) }
            throw ReolinkError.command(command.cmd, reply?.rspCode, reply?.detail)
        }
    }

    private func reread(_ cmd: String, channel: Int) async {
        guard let reply = try? await http.execute([.channel(cmd, channel)]).first, var state = channels[channel] else { return }
        apply(reply, to: &state)
        channels[channel] = state
        publish(channel)
    }

    // MARK: Snapshots and streams

    func snapshot(channel: Int, sub: Bool) async throws -> Data {
        guard channels[channel]?.state.privacy != true else { throw ReolinkError.privacy }
        let stream = channels[channel]?.sub
        return try await http.snapshot(channel: channel, sub: sub, width: sub ? stream?.width : nil, height: sub ? stream?.height : nil)
    }

    /// The URL FFmpeg reads a channel's stream from (4.6), by `streamProtocol` unless `protocol` says.
    func streamURL(channel: Int, sub: Bool, protocol name: String? = nil) async -> String? {
        guard let info = channels[channel], info.state.privacy != true else { return nil }
        let stream = sub ? info.sub : info.main
        switch name ?? device.streamProtocol {
        case "rtmp":
            return ReolinkStreamURL.rtmp(host: device.host, port: self.info.rtmpPort, username: device.username, password: device.password, channel: channel, sub: sub)
        case "flv":
            return ReolinkStreamURL.flv(https: await http.isHTTPS, host: device.host, apiPort: await http.apiPort, rtmpPort: self.info.rtmpPort,
                                        username: device.username, password: device.password, channel: channel, sub: sub)
        default:
            return ReolinkStreamURL.rtsp(host: device.host, port: self.info.rtspPort, username: device.username, password: device.password, channel: channel,
                                         sub: sub, codec: stream.codec, reported: stream.rtspURL, rtspVersion: self.info.hostAbility("rtsp"))
        }
    }

    func channelInfo(_ channel: Int) -> ReolinkChannel? { channels[channel] }

    /// Reads the channel list and channels again (a new camera on an NVR).
    func reloadChannels() async throws {
        let replies = try await http.execute([ReolinkCommand(cmd: "GetChannelstatus", action: nil, param: nil)])
        if let reply = replies.first, reply.ok, let value = reply.value {
            info.channels = ReolinkHostInfo.channelStatus(value)
            info.hasChannelStatus = true
        }
        channels = try await readWantedChannels()
    }

    /// The online channels the block asks for, read.
    private func readWantedChannels() async throws -> [Int: ReolinkChannel] {
        var statuses = info.onlineChannels
        if let wanted = device.channels { statuses = statuses.filter { wanted.contains($0.channel) } }
        return try await readChannels(statuses)
    }
}
