import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The HAP types the `service` option picks for the Sonos and Speakers services, and their volume characteristic.
extension SonosPlugin.Settings {
    var serviceType: ServiceType {
        switch service {
        case .switch: .switch
        case .light: .lightbulb
        case .speaker: .speaker
        case .fan: .fan
        }
    }

    var volumeType: CharacteristicType {
        switch service {
        case .light: .brightness
        case .fan: .rotationSpeed
        case .switch, .speaker: brightness ? .brightness : .volume
        }
    }
}

/// What a zone (master) player's accessory has, beyond what every zone has: it changes with the topology and the
/// alarms, and a change rebuilds the accessory (same id, aids and iids kept).
struct ZoneShape: Sendable, Equatable {
    var balance = false
    var surround = false
    var sub = false
    var alarms: [String] = []
    var battery = false
}

/// A zone's accessory (`ZP:<player id>`): the Sonos service for its group, the Speakers service for itself, its LED, its
/// alarms and its battery; and what it knows of its group, which events and the topology keep current.
final class ZoneAccessory: @unchecked Sendable {
    struct Services {
        var accessory: Accessory
        var sonos: Service
        var speakers: Service?
        var led: Service?
        var alarms: [String: Service] = [:]
        var battery: Service?
    }

    struct State {
        var player: TopologyPlayer
        var shape = ZoneShape()
        var isCoordinator = true
        var leaving = false
        var targetCoordinator: String?
        var targetGroupShortName: String?
        var validPlayModes: [String] = []
        var actions: [String] = []
        var uri: String?
        var tvFlag: Bool?
        var tvFlagChange: Task<Void, Never>?
        var alarms: [String: Alarm] = [:]
        var lost = false
    }

    let id: String
    let description: DeviceDescription
    let settings: SonosPlugin.Settings
    let host: PluginReference
    let logger: Logger
    let timeScale: Double
    private let state: NIOLockedValueBox<State>
    private let servicesBox: NIOLockedValueBox<Services?>
    private let volumeGuard = LatestCallGuard(delay: .milliseconds(300))
    /// The zone's TV (its own accessory), when `tv` is on.
    let tv = NIOLockedValueBox<TVAccessory?>(nil)
    /// Identify is blinking the LED.
    let blinking = NIOLockedValueBox(false)

    init(player: TopologyPlayer, description: DeviceDescription, settings: SonosPlugin.Settings, host: PluginReference, logger: Logger, timeScale: Double) {
        id = player.id
        self.description = description
        self.settings = settings
        self.host = host
        self.logger = logger
        self.timeScale = timeScale
        state = NIOLockedValueBox(State(player: player))
        servicesBox = NIOLockedValueBox(nil)
    }

    var services: Services? { servicesBox.withLockedValue { $0 } }
    var accessory: Accessory? { services?.accessory }
    var player: TopologyPlayer { state.withLockedValue { $0.player } }
    var currentShape: ZoneShape { state.withLockedValue { $0.shape } }
    var isCoordinator: Bool { state.withLockedValue { $0.isCoordinator } }
    var isLeaving: Bool { state.withLockedValue { $0.leaving } }
    var zoneGroup: String { state.withLockedValue { $0.player.zoneGroup } }
    var uri: String? { state.withLockedValue { $0.uri } }
    var groupShortName: String { state.withLockedValue { $0.player.groupShortName } }
    var targetCoordinator: String? { state.withLockedValue { $0.targetCoordinator } }
    var targetGroupShortName: String? { state.withLockedValue { $0.targetGroupShortName } }
    var sonosName: String { services?.sonos[.configuredName]?.value.stringValue ?? "\(player.zoneName) Sonos" }
    private var reset: Duration { settings.reset(timeScale: timeScale) }

    /// The shape the topology and alarms ask for now.
    func wantedShape(alarms: [Alarm]) -> ZoneShape {
        let player = player
        let inParentheses = player.zoneDisplayName.split(separator: "(").dropFirst().joined(separator: "(")
        return ZoneShape(
            balance: description.audioIn || player.stereoPair, surround: inParentheses.contains("LS+RS"), sub: inParentheses.contains("Sub"),
            alarms: settings.alarms ? alarms.filter { $0.roomUUID == id }.map(\.id) : [], battery: player.battery != nil)
    }

    // MARK: Building

    /// Builds the accessory for `shape`, the previous one's values carried over; the caller adds it to the bridge.
    func build(shape: ZoneShape, cached: Accessory? = nil, identify: @escaping @Sendable () async throws -> Void) -> Accessory {
        let previous = services
        let player = player
        let zoneName = player.zoneName
        let settings = settings

        func named(_ service: Service) -> Service {
            ZoneAccessory.addConfiguredName(to: service)
            return service
        }

        // The Sonos service: the group.
        var sonosExtra: [Characteristic] = [
            Characteristic(.on), Characteristic(settings.volumeType), Characteristic(.mute),
            Characteristic(.setDuration.with(maxValue: 86399), value: .int(0)), Characteristic(.remainingDuration.with(maxValue: 86399), value: .int(0)),
            Characteristic(SonosCharacteristic.changeVolume, value: .int(0)), Characteristic(SonosCharacteristic.repeatMode, value: .int(0)),
            Characteristic(SonosCharacteristic.shuffle, value: .bool(false)), Characteristic(SonosCharacteristic.crossfade, value: .bool(false)),
            Characteristic(SonosCharacteristic.currentTrack, value: .string("")), Characteristic(SonosCharacteristic.changeTrack, value: .int(0)),
        ]
        if settings.tv {
            sonosExtra.append(Characteristic(.activeIdentifier.with(minValue: 0, maxValue: Double(settings.maxFavourites)), value: .int(0)))
            sonosExtra.append(Characteristic(SonosCharacteristic.changeInput, value: .int(0)))
        }
        if description.tvIn { sonosExtra.append(Characteristic(SonosCharacteristic.tv, value: .bool(false))) }
        sonosExtra += [
            Characteristic(SonosCharacteristic.sonosGroup, value: .string("")), Characteristic(SonosCharacteristic.sonosCoordinator, value: .bool(false)),
            Characteristic(SonosCharacteristic.logLevel, value: .int(2)), Characteristic(SonosCharacteristic.lastSeen, value: .string(LastSeen.never)),
            Characteristic(.statusFault, value: .int(HAPConstants.StatusFault.generalFault)),
        ]
        let sonos = named(Service(settings.serviceType, name: "\(zoneName) Sonos", subtype: "group", extra: sonosExtra, isPrimary: true))

        var speakers: Service?
        if settings.speakers {
            var extra: [Characteristic] = [
                Characteristic(.on), Characteristic(settings.volumeType), Characteristic(.mute), Characteristic(SonosCharacteristic.changeVolume, value: .int(0)),
                Characteristic(SonosCharacteristic.loudness), Characteristic(SonosCharacteristic.bass), Characteristic(SonosCharacteristic.treble),
            ]
            if shape.balance { extra.append(Characteristic(SonosCharacteristic.balance)) }
            if description.tvIn { extra += [Characteristic(SonosCharacteristic.nightSound), Characteristic(SonosCharacteristic.speechEnhancement)] }
            if shape.surround {
                extra += [
                    Characteristic(SonosCharacteristic.surroundEnabled), Characteristic(SonosCharacteristic.tvLevel), Characteristic(SonosCharacteristic.musicLevel),
                    Characteristic(SonosCharacteristic.musicPlaybackFull), Characteristic(SonosCharacteristic.heightLevel),
                ]
            }
            if shape.sub { extra += [Characteristic(SonosCharacteristic.subEnabled), Characteristic(SonosCharacteristic.subLevel)] }
            speakers = named(Service(settings.serviceType, name: "\(zoneName) Speakers", subtype: "zone", extra: extra))
        }

        var led: Service?
        if settings.leds {
            let channel = player.channel ?? ""
            led = named(LEDService.make(name: "\(zoneName) Sonos LED", channel: channel))
        }

        var alarmServices: [String: Service] = [:]
        for alarmID in shape.alarms {
            let name = "\(zoneName) Sonos Alarm \(alarmID)"
            alarmServices[alarmID] = named(Service(.switch, name: name, subtype: "alarm\(alarmID)", extra: [
                Characteristic(SonosCharacteristic.currentTrack, value: .string("")), Characteristic(SonosCharacteristic.time, value: .string("")),
            ]))
        }

        var battery: Service?
        if shape.battery {
            battery = Self.makeBattery(for: player)
        }

        var all: [Service] = [sonos]
        if let speakers { all.append(speakers) }
        if let led { all.append(led) }
        all += shape.alarms.compactMap { alarmServices[$0] }
        if let battery { all.append(battery) }
        let accessory = Accessory(
            id: SonosPlugin.accessoryID(id), name: player.accessoryName, manufacturer: description.manufacturer, model: description.model,
            serialNumber: id, firmwareRevision: description.displayVersion, category: .speaker, services: all, onIdentify: identify)
        if let source = previous?.accessory ?? cached { accessory.takeValues(from: source) }
        let services = Services(accessory: accessory, sonos: sonos, speakers: speakers, led: led, alarms: alarmServices, battery: battery)
        servicesBox.withLockedValue { $0 = services }
        state.withLockedValue { $0.shape = shape }
        wireSonos(sonos)
        if let speakers { wireSpeakers(speakers) }
        if let led { LEDService.wire(led, settings: settings, client: { [host, id] in await host.plugin?.client(id) }, isBlinking: { [blinking] in blinking.withLockedValue { $0 } }) }
        for (alarmID, service) in alarmServices { wireAlarm(service, id: alarmID) }
        // The values the zone knows now (a new alarm's own, not its cached ones).
        refreshDerived()
        let alarms = state.withLockedValue { $0.alarms }
        for (alarmID, service) in alarmServices { if let alarm = alarms[alarmID] { Self.show(alarm, on: service) } }
        if let battery, let level = player.battery { Self.show(level, on: battery) }
        return accessory
    }

    // MARK: The Sonos service (group control: writes go to the coordinator)

    private func coordinatorClient() async -> PlayerClient? {
        await host.plugin?.client(zoneGroup.isEmpty ? id : zoneGroup)
    }

    /// Runs a write on the coordinator; failures are logged, not returned (the Homebridge plugin's Sonos service).
    private func onCoordinator(_ what: String, _ body: @escaping @Sendable (PlayerClient) async throws -> Void) async {
        guard let client = await coordinatorClient() else {
            logger.warning("\(player.zoneName): \(what): no coordinator")
            return
        }
        do { try await body(client) } catch { logger.warning("\(player.zoneName): \(what): \(error)") }
    }

    private func wireSonos(_ sonos: Service) {
        let reset = reset
        sonos.characteristic(.on).onWrite { [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            let (actions, track) = (state.withLockedValue { $0.actions }, sonos[SonosCharacteristic.currentTrack]?.value.stringValue)
            if on {
                guard actions.contains("Play"), track != "TV" else {
                    sonos.characteristic(.on).revert(to: .bool(false), after: reset)
                    return
                }
                let duration = sonos[.setDuration]?.value.intValue ?? 0
                await onCoordinator("play") { client in
                    try await client.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
                    try await client.call(.avTransport, "ConfigureSleepTimer", [("InstanceID", "0"), ("NewSleepTimerDuration", duration <= 10 ? "" : SleepTimer.text(duration))])
                }
            } else if actions.contains("Pause") || actions.contains("Stop") {
                let action = actions.contains("Pause") ? "Pause" : "Stop"
                await onCoordinator(action.lowercased()) { client in try await client.call(.avTransport, action, [("InstanceID", "0")]) }
            } else {
                sonos.characteristic(.on).revert(to: .bool(true), after: reset)
            }
        }
        sonos.characteristic(.setDuration).onWrite { value in
            if (value.intValue ?? 0) <= 10 { sonos.characteristic(.setDuration).revert(to: .int(0), after: reset) }
        }
        sonos.characteristic(.remainingDuration).onRead { [weak self] in
            guard let self, !state.withLockedValue({ $0.lost }), let client = await coordinatorClient() else { return .int(0) }
            return .int(await Self.remainingSleepTimer(client))
        }
        let volumeType = settings.volumeType
        sonos.characteristic(volumeType).onWrite { [weak self] value in
            guard let self, await volumeGuard("group") else { return }
            let volume = min(max(value.intValue ?? 0, 0), 100)
            await onCoordinator("group volume") { client in
                try await client.call(.groupRenderingControl, "SetGroupVolume", [("InstanceID", "0"), ("DesiredVolume", "\(volume)")])
            }
        }
        sonos.characteristic(SonosCharacteristic.changeVolume).onWrite { [weak self] value in
            guard let self else { return }
            sonos.characteristic(SonosCharacteristic.changeVolume).revert(to: .int(0), after: reset)
            let step = value.intValue ?? 0
            guard step != 0 else { return }
            await onCoordinator("volume change") { client in
                let answer = try await client.call(.groupRenderingControl, "SetRelativeGroupVolume", [("InstanceID", "0"), ("Adjustment", "\(step)")])
                if let volume = Events.int(answer["NewVolume"]) { sonos.characteristic(volumeType).value = .int(volume) }
            }
        }
        sonos.characteristic(.mute).onWrite { [weak self] value in
            let mute = value.boolValue ?? false
            await self?.onCoordinator("group mute") { client in
                try await client.call(.groupRenderingControl, "SetGroupMute", [("InstanceID", "0"), ("DesiredMute", mute ? "1" : "0")])
            }
        }
        sonos.characteristic(SonosCharacteristic.repeatMode).onWrite { [weak self] value in
            guard let self else { return }
            let mode = value.intValue ?? 0
            let valid = state.withLockedValue { $0.validPlayModes }
            if (mode == 1 && !valid.contains("REPEATONE")) || (mode == 2 && !valid.contains("REPEAT")) {
                sonos.characteristic(SonosCharacteristic.repeatMode).revert(to: .int(0), after: reset)
                return
            }
            await setPlayMode { current in (mode, current.1) }
        }
        sonos.characteristic(SonosCharacteristic.shuffle).onWrite { [weak self] value in
            guard let self else { return }
            let shuffle = value.boolValue ?? false
            if shuffle, !state.withLockedValue({ $0.validPlayModes }).contains("SHUFFLE") {
                sonos.characteristic(SonosCharacteristic.shuffle).revert(to: .bool(false), after: reset)
                return
            }
            await setPlayMode { current in (current.0, shuffle) }
        }
        sonos.characteristic(SonosCharacteristic.crossfade).onWrite { [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if on, !state.withLockedValue({ $0.validPlayModes }).contains("CROSSFADE") {
                sonos.characteristic(SonosCharacteristic.crossfade).revert(to: .bool(false), after: reset)
                return
            }
            await onCoordinator("crossfade") { client in
                try await client.call(.avTransport, "SetCrossfadeMode", [("InstanceID", "0"), ("CrossfadeMode", on ? "1" : "0")])
            }
        }
        sonos.characteristic(SonosCharacteristic.changeTrack).onWrite { [weak self] value in
            guard let self else { return }
            sonos.characteristic(SonosCharacteristic.changeTrack).revert(to: .int(0), after: reset)
            let step = value.intValue ?? 0
            let actions = state.withLockedValue { $0.actions }
            let action = step > 0 ? "Next" : step < 0 ? "Previous" : nil
            guard let action, actions.contains(action) else { return }
            await onCoordinator(action.lowercased()) { client in try await client.call(.avTransport, action, [("InstanceID", "0")]) }
        }
        if settings.tv {
            sonos.characteristic(.activeIdentifier).onWrite { [weak self] value in
                guard let tv = self?.tv.withLockedValue({ $0 }) else { return }
                await tv.select(identifier: value.intValue ?? 0)
            }
            sonos.characteristic(SonosCharacteristic.changeInput).onWrite { [weak self] value in
                sonos.characteristic(SonosCharacteristic.changeInput).revert(to: .int(0), after: reset)
                guard let step = value.intValue, step != 0, let tv = self?.tv.withLockedValue({ $0 }) else { return }
                await tv.step(step > 0 ? 1 : -1)
            }
        }
        sonos.characteristic(SonosCharacteristic.sonosCoordinator).onWrite { [weak self] value in
            guard let self else { return }
            guard value.boolValue == true else {
                sonos.characteristic(SonosCharacteristic.sonosCoordinator).revert(to: .bool(true), after: reset)
                return
            }
            await host.plugin?.becomeTargetCoordinator(id)
            if !isCoordinator {
                let me = id
                await onCoordinator("delegate coordination") { client in
                    try await client.call(.avTransport, "DelegateGroupCoordinationTo", [("InstanceID", "0"), ("NewCoordinator", me), ("RejoinGroup", "true")])
                }
            }
        }
        sonos.characteristic(SonosCharacteristic.configuredName).observe { [weak self] change in
            guard change.reason == .write, let name = change.newValue.stringValue, let tv = self?.tv.withLockedValue({ $0 }) else { return }
            tv.renamed(to: name)
        }
    }

    /// Reads the coordinator's play mode, so a change of repeat keeps shuffle and the other way round.
    private func setPlayMode(_ change: @escaping @Sendable ((Int, Bool)) -> (Int, Bool)) async {
        await onCoordinator("play mode") { client in
            let current = try await client.call(.avTransport, "GetTransportSettings", [("InstanceID", "0")])["PlayMode"].flatMap(PlayMode.decode) ?? (0, false)
            let (repeatMode, shuffle) = change(current)
            try await client.call(.avTransport, "SetPlayMode", [("InstanceID", "0"), ("NewPlayMode", PlayMode.encode(repeatMode: repeatMode, shuffle: shuffle))])
        }
    }

    // MARK: The Speakers service (this player only; failures go back to HomeKit)

    private func ownClient() async throws -> PlayerClient {
        guard let client = await host.plugin?.client(id) else { throw HAPStatusError(.serviceCommunicationFailure) }
        return client
    }

    private func wireSpeakers(_ speakers: Service) {
        let reset = reset
        speakers.characteristic(.on).onWrite { [weak self] value in
            guard let self else { return }
            let client = try await ownClient()
            if value.boolValue == true {
                let target = targetCoordinator
                guard let target, target != id else {
                    speakers.characteristic(.on).revert(to: .bool(false), after: reset)
                    return
                }
                try await client.call(.avTransport, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(target)"), ("CurrentURIMetaData", "")], timeout: .seconds(5))
            } else {
                try await client.call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [("InstanceID", "0")], timeout: .seconds(5))
            }
        }
        speakers.characteristic(settings.volumeType).onWrite { [weak self] value in
            guard let self, await volumeGuard("zone") else { return }
            let volume = min(max(value.intValue ?? 0, 0), 100)
            try await ownClient().call(.renderingControl, "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "\(volume)")])
        }
        let volumeType = settings.volumeType
        speakers.characteristic(SonosCharacteristic.changeVolume).onWrite { [weak self] value in
            guard let self else { return }
            speakers.characteristic(SonosCharacteristic.changeVolume).revert(to: .int(0), after: reset)
            guard let step = value.intValue, step != 0 else { return }
            do {
                let answer = try await ownClient().call(.renderingControl, "SetRelativeVolume", [("InstanceID", "0"), ("Channel", "Master"), ("Adjustment", "\(step)")])
                if let volume = Events.int(answer["NewVolume"]) { speakers.characteristic(volumeType).value = .int(volume) }
            } catch {
                logger.warning("\(player.zoneName): volume change: \(error)")
            }
        }
        func set(_ type: CharacteristicType, _ action: String, _ argument: String, bool: Bool = false) {
            speakers[type]?.onWrite { [weak self] value in
                guard let self else { return }
                let text = bool ? (value.boolValue == true ? "1" : "0") : "\(value.intValue ?? 0)"
                var arguments = [("InstanceID", "0")]
                if action != "SetBass", action != "SetTreble" { arguments.append(("Channel", "Master")) }
                arguments.append((argument, text))
                try await ownClient().call(.renderingControl, action, arguments)
            }
        }
        set(.mute, "SetMute", "DesiredMute", bool: true)
        set(SonosCharacteristic.loudness, "SetLoudness", "DesiredLoudness", bool: true)
        set(SonosCharacteristic.bass, "SetBass", "DesiredBass")
        set(SonosCharacteristic.treble, "SetTreble", "DesiredTreble")
        func equaliser(_ type: CharacteristicType, _ eqType: String, bool: Bool = false) {
            speakers[type]?.onWrite { [weak self] value in
                guard let self else { return }
                let text = bool ? (value.boolValue == true ? "1" : "0") : "\(value.intValue ?? 0)"
                try await ownClient().call(.renderingControl, "SetEQ", [("InstanceID", "0"), ("EQType", eqType), ("DesiredValue", text)])
            }
        }
        equaliser(SonosCharacteristic.nightSound, "NightMode", bool: true)
        equaliser(SonosCharacteristic.speechEnhancement, "DialogLevel", bool: true)
        equaliser(SonosCharacteristic.surroundEnabled, "SurroundEnable", bool: true)
        equaliser(SonosCharacteristic.tvLevel, "SurroundLevel")
        equaliser(SonosCharacteristic.musicLevel, "MusicSurroundLevel")
        equaliser(SonosCharacteristic.musicPlaybackFull, "SurroundMode", bool: true)
        equaliser(SonosCharacteristic.heightLevel, "HeightChannelLevel")
        equaliser(SonosCharacteristic.subEnabled, "SubEnable", bool: true)
        equaliser(SonosCharacteristic.subLevel, "SubGain")
        speakers[SonosCharacteristic.balance]?.onWrite { [weak self] value in
            guard let self else { return }
            let balance = min(max(value.intValue ?? 0, -100), 100)
            let client = try await ownClient()
            // The full side first, then the other one turned down.
            let (full, other, level) = balance < 0 ? ("LF", "RF", 100 + balance) : ("RF", "LF", 100 - balance)
            try await client.call(.renderingControl, "SetVolume", [("InstanceID", "0"), ("Channel", full), ("DesiredVolume", "100")])
            try await client.call(.renderingControl, "SetVolume", [("InstanceID", "0"), ("Channel", other), ("DesiredVolume", "\(level)")])
        }
    }

    // MARK: Alarms

    private func wireAlarm(_ service: Service, id alarmID: String) {
        service.characteristic(.on).onWrite { [weak self] value in
            guard let self, let alarm = state.withLockedValue({ $0.alarms[alarmID] }) else { return }
            let enabled = value.boolValue ?? false
            guard let client = await host.plugin?.associatedClient(of: id) else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await client.call(.alarmClock, "UpdateAlarm", alarm.updateArguments(enabled: enabled))
            state.withLockedValue { $0.alarms[alarmID]?.enabled = enabled }
        }
    }

    static func show(_ alarm: Alarm, on service: Service) {
        service.characteristic(.on).value = .bool(alarm.enabled)
        service[SonosCharacteristic.currentTrack]?.value = .string(alarm.track)
        service[SonosCharacteristic.time]?.value = .string(alarm.startTime)
    }

    static func show(_ battery: TopologyPlayer.Battery, on service: Service) {
        service[.batteryLevel]?.value = .int(battery.level)
        service[.chargingState]?.value = .int(battery.charging ? HAPConstants.ChargingState.charging : HAPConstants.ChargingState.notCharging)
        service.characteristic(.statusLowBattery).value = .int(battery.level <= 20 ? 1 : 0)
    }

    /// Keeps the zone's alarms; answers whether the services must change (an alarm came or went).
    func setAlarms(_ alarms: [Alarm]) -> Bool {
        let mine = alarms.filter { $0.roomUUID == id }
        state.withLockedValue { $0.alarms = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { $1 }) }
        guard let services else { return false }
        if wantedShape(alarms: alarms) != state.withLockedValue({ $0.shape }) { return true }
        for alarm in mine { if let service = services.alarms[alarm.id] { Self.show(alarm, on: service) } }
        return false
    }

    // MARK: Events

    /// An AVTransport event: the zone's own, or its coordinator's copied to it.
    func apply(_ update: TransportUpdate, fromCoordinator: Bool = false) {
        guard let sonos = services?.sonos else { return }
        if let unknown = update.unknownScheme, !fromCoordinator { logger.warning("\(player.zoneName): unknown uri scheme \(unknown)") }
        if let on = update.on { sonos.characteristic(.on).value = .bool(on) }
        if let track = update.track { sonos[SonosCharacteristic.currentTrack]?.value = .string(track) }
        if let repeatMode = update.repeatMode { sonos[SonosCharacteristic.repeatMode]?.value = .int(repeatMode) }
        if let shuffle = update.shuffle { sonos[SonosCharacteristic.shuffle]?.value = .bool(shuffle) }
        if let crossfade = update.crossfade { sonos[SonosCharacteristic.crossfade]?.value = .bool(crossfade) }
        let uriChanged = state.withLockedValue { state -> Bool in
            if let actions = update.actions { state.actions = actions }
            if let modes = update.validPlayModes { state.validPlayModes = modes }
            guard let uri = update.uri, uri != state.uri else { return false }
            state.uri = uri
            return true
        }
        if uriChanged, let tv = tv.withLockedValue({ $0 }) { tv.uriChanged() }
        if description.tvIn, !fromCoordinator { applyTVFlag(update) }
    }

    /// The TV flag: on at once, off 10 seconds after the TV input lost its signal unless a later event says on again.
    private func applyTVFlag(_ update: TransportUpdate) {
        guard let sonos = services?.sonos, let tvCharacteristic = sonos[SonosCharacteristic.tv] else { return }
        let flag = update.tvSignal
        let track = sonos[SonosCharacteristic.currentTrack]?.value.stringValue
        let delay = Duration.seconds(10 * timeScale)
        state.withLockedValue { state in
            if state.tvFlag == flag {
                state.tvFlagChange?.cancel()
                state.tvFlagChange = nil
                return
            }
            if flag || state.tvFlag == nil || track != "TV" {
                state.tvFlagChange?.cancel()
                state.tvFlagChange = nil
                state.tvFlag = flag
                tvCharacteristic.value = .bool(flag)
            } else if state.tvFlagChange == nil {
                state.tvFlagChange = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    self?.state.withLockedValue { state in
                        state.tvFlag = false
                        state.tvFlagChange = nil
                    }
                    tvCharacteristic.value = .bool(false)
                }
            }
        }
    }

    /// The coordinator asks for the remaining sleep timer after `SleepTimerGeneration` changed.
    func refreshRemainingDuration() async {
        guard let sonos = services?.sonos, let client = await host.plugin?.client(id) else { return }
        sonos.characteristic(.remainingDuration).value = .int(await Self.remainingSleepTimer(client))
    }

    /// The coordinator's remaining sleep timer in seconds, 0 for none or no answer within 2 seconds.
    static func remainingSleepTimer(_ client: PlayerClient) async -> Int {
        let answer = try? await client.call(.avTransport, "GetRemainingSleepTimerDuration", [("InstanceID", "0")], timeout: .seconds(2))
        return min(SleepTimer.seconds(answer?["RemainingSleepTimerDuration"]), 86399)
    }

    /// Configured Name as the Homebridge plugin gives every service (the service's name, never empty).
    static func addConfiguredName(to service: Service) {
        let configured = service.characteristic(adding: SonosCharacteristic.configuredName)
        configured.value = service[.name]?.value ?? .string("")
        configured.onWrite { value in
            guard value.stringValue?.isEmpty == false else { throw HAPStatusError(.invalidValueInRequest) }
        }
    }

    static func makeBattery(for player: TopologyPlayer) -> Service {
        Service(.battery, name: "\(player.accessoryName) Battery", optional: [.batteryLevel, .chargingState])
    }

    /// A GroupRenderingControl event (or the coordinator's, copied).
    func applyGroup(volume: Int?, mute: Bool?) {
        guard let sonos = services?.sonos else { return }
        if let volume { sonos.characteristic(settings.volumeType).value = .int(min(max(volume, 0), 100)) }
        if let mute { sonos.characteristic(.mute).value = .bool(mute) }
    }

    /// A RenderingControl event, for the Speakers service.
    func applyRendering(_ variables: [String: String]) {
        guard let speakers = services?.speakers else { return }
        func int(_ key: String) -> Int? { Events.int(variables[key]) }
        func bool(_ key: String) -> Bool? { variables[key].map { $0 == "1" } }
        if let volume = int("Volume") { speakers.characteristic(settings.volumeType).value = .int(min(max(volume, 0), 100)) }
        if let mute = bool("Mute") { speakers.characteristic(.mute).value = .bool(mute) }
        let pairs: [(CharacteristicType, String, Bool)] = [
            (SonosCharacteristic.loudness, "Loudness", true), (SonosCharacteristic.bass, "Bass", false), (SonosCharacteristic.treble, "Treble", false),
            (SonosCharacteristic.nightSound, "NightMode", true), (SonosCharacteristic.speechEnhancement, "DialogLevel", true),
            (SonosCharacteristic.surroundEnabled, "SurroundEnabled", true), (SonosCharacteristic.tvLevel, "SurroundLevel", false),
            (SonosCharacteristic.musicLevel, "MusicSurroundLevel", false), (SonosCharacteristic.musicPlaybackFull, "SurroundMode", true),
            (SonosCharacteristic.heightLevel, "HeightChannelLevel", false), (SonosCharacteristic.subEnabled, "SubEnabled", true),
            (SonosCharacteristic.subLevel, "SubGain", false),
        ]
        for (type, key, isBool) in pairs {
            guard let characteristic = speakers[type] else { continue }
            if isBool, let value = bool(key) { characteristic.value = .bool(value) }
            if !isBool, let value = int(key), let fitting = type.coerce(.int(value)) { characteristic.value = fitting }
        }
        if let balance = speakers[SonosCharacteristic.balance], int("Volume:LF") != nil || int("Volume:RF") != nil {
            // A side the event leaves out is the stored balance's.
            let current = balance.value.intValue ?? 0
            let left = int("Volume:LF") ?? (current < 0 ? 100 : 100 - current)
            let right = int("Volume:RF") ?? (current < 0 ? 100 + current : 100)
            balance.value = .int(min(max(right - left, -100), 100))
        }
    }

    /// A topology change: the zone's player and group, then what it copies from its coordinator.
    func applyTopology(_ player: TopologyPlayer, coordinator: ZoneAccessory?) {
        let isCoordinator = state.withLockedValue { state -> Bool in
            state.player = player
            state.isCoordinator = player.zoneGroup.isEmpty || player.zoneGroup == id
            if state.isCoordinator { state.leaving = false }
            return state.isCoordinator
        }
        refreshDerived()
        guard let services else { return }
        if let battery = services.battery, let level = player.battery { Self.show(level, on: battery) }
        guard !isCoordinator, !isLeaving, let coordinator, let source = coordinator.services?.sonos else { return }
        let sonos = services.sonos
        for type in [CharacteristicType.on, settings.volumeType, .mute, SonosCharacteristic.currentTrack] {
            if let value = source[type]?.value, value != .null { sonos[type]?.value = value }
        }
        let (actions, uri, modes) = coordinator.state.withLockedValue { ($0.actions, $0.uri, $0.validPlayModes) }
        state.withLockedValue { state in
            state.actions = actions
            state.uri = uri
            state.validPlayModes = modes
        }
    }

    /// An own AVTransport event while a member: the zone stops copying its coordinator (the Homebridge plugin's
    /// "leaving"), until it coordinates again.
    func markLeavingIfMember() {
        state.withLockedValue { if !$0.isCoordinator { $0.leaving = true } }
    }

    /// Group name, Speakers On, coordinator mark: what the topology and the target coordinator decide.
    func refreshDerived() {
        guard let services else { return }
        let (player, isCoordinator, target) = state.withLockedValue { ($0.player, $0.isCoordinator, $0.targetCoordinator) }
        services.sonos[SonosCharacteristic.sonosGroup]?.value = .string(player.groupShortName)
        services.sonos[SonosCharacteristic.sonosCoordinator]?.value = .bool(target == id)
        services.speakers?.characteristic(.on).value = .bool(!isCoordinator)
    }

    func setTargetCoordinator(_ target: String?, groupShortName: String?) {
        state.withLockedValue {
            $0.targetCoordinator = target
            $0.targetGroupShortName = groupShortName
        }
        refreshDerived()
    }

    /// Lost (vanished, or unseen for ten minutes): off, a general fault, No Response.
    func setLost(_ lost: Bool) {
        state.withLockedValue { $0.lost = lost }
        guard let services else { return }
        if lost {
            services.sonos.characteristic(.on).value = .bool(false)
            services.speakers?.characteristic(.on).value = .bool(false)
        }
        services.sonos[.statusFault]?.value = .int(lost ? HAPConstants.StatusFault.generalFault : HAPConstants.StatusFault.noFault)
        if services.accessory.isUnavailable != lost { services.accessory.isUnavailable = lost }
    }

    func seen(_ date: Date?) {
        services?.sonos[SonosCharacteristic.lastSeen]?.value = .string(LastSeen.text(date))
    }

    // MARK: Identify

    /// Blinks the LED ten times a second apart and puts it back; a second identify meanwhile is ignored.
    static func blink(client: PlayerClient, isBlinking: NIOLockedValueBox<Bool>, timeScale: Double) async throws {
        guard isBlinking.withLockedValue({ blinking in
            defer { blinking = true }
            return !blinking
        }) else { return }
        defer { isBlinking.withLockedValue { $0 = false } }
        let original = try await client.call(.deviceProperties, "GetLEDState")["CurrentLEDState"] == "On"
        var on = original
        for _ in 0..<10 {
            on.toggle()
            try await client.call(.deviceProperties, "SetLEDState", [("DesiredLEDState", on ? "On" : "Off")])
            try await Task.sleep(for: .seconds(timeScale))
        }
        try await client.call(.deviceProperties, "SetLEDState", [("DesiredLEDState", original ? "On" : "Off")])
    }

}

/// The LED and button lock of a player: a Lightbulb `led<channel>`, on its zone's accessory or a slave's own.
enum LEDService {
    static func make(name: String, channel: String, faultStatus: Bool = false) -> Service {
        var extra = [Characteristic(.lockPhysicalControls, value: .int(0))]
        if faultStatus { extra.append(Characteristic(.statusFault, value: .int(HAPConstants.StatusFault.noFault))) }
        return Service(.lightbulb, name: name, subtype: "led\(channel)", extra: extra)
    }

    /// Reads on each HomeKit read, or polls every `heartrate` seconds and answers from the stored value.
    static func wire(_ led: Service, settings: SonosPlugin.Settings, client: @escaping @Sendable () async -> PlayerClient?, isBlinking: @escaping @Sendable () -> Bool) {
        led.characteristic(.on).onWrite { value in
            guard let client = await client() else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await client.call(.deviceProperties, "SetLEDState", [("DesiredLEDState", value.boolValue == true ? "On" : "Off")])
        }
        led.characteristic(.lockPhysicalControls).onWrite { value in
            guard let client = await client() else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await client.call(.deviceProperties, "SetButtonLockState", [("DesiredButtonLockState", value.intValue == 1 ? "On" : "Off")])
        }
        guard settings.heartrate == nil else { return }
        led.characteristic(.on).onRead {
            guard let client = await client() else { throw HAPStatusError(.serviceCommunicationFailure) }
            return .bool(try await client.call(.deviceProperties, "GetLEDState")["CurrentLEDState"] == "On")
        }
        led.characteristic(.lockPhysicalControls).onRead {
            guard let client = await client() else { throw HAPStatusError(.serviceCommunicationFailure) }
            return .int(try await client.call(.deviceProperties, "GetButtonLockState")["CurrentButtonLockState"] == "On" ? 1 : 0)
        }
    }

    /// One poll: the LED (skipped while identify blinks) and the button lock.
    static func poll(_ led: Service, client: PlayerClient, skipLED: Bool) async throws {
        if !skipLED {
            led.characteristic(.on).value = .bool(try await client.call(.deviceProperties, "GetLEDState")["CurrentLEDState"] == "On")
        }
        led.characteristic(.lockPhysicalControls).value = .int(try await client.call(.deviceProperties, "GetButtonLockState")["CurrentButtonLockState"] == "On" ? 1 : 0)
    }
}
