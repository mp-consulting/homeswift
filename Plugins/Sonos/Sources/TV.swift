import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// A zone's Television (`ZP:<tvIdPrefix><id without RINCON>`), published on its own: its Active is the zone's Sonos On,
/// its inputs the group entry, AirPlay, Audio In, TV, the household's favourites and the chime. The `maxFavourites`
/// InputSource services are made once and reconfigured in place, as HomeKit dislikes a changing set of services.
final class TVAccessory: @unchecked Sendable {
    struct Input: Sendable, Equatable {
        var name: String
        /// XML-escaped.
        var uri: String?
        var configured: Bool
        var shown: Bool
        var type: Int
        var favourite: Favourite?
    }

    let accessory: Accessory
    let television: Service
    let speaker: Service
    let inputs: [Service]
    private weak var zone: ZoneAccessory?
    private let zoneID: String
    private let maxFavourites: Int
    private let reset: Duration
    private let logger: Logger
    private let host: PluginReference
    private let state = NIOLockedValueBox<(table: [Input], favourites: [Favourite], observer: (Characteristic, Int)?)>(([], [], nil))

    static func seed(playerID: String, prefix: String) -> String { prefix + playerID.dropFirst(6) }

    init(zone: ZoneAccessory, settings: SonosPlugin.Settings, host: PluginReference, logger: Logger, timeScale: Double) {
        self.zone = zone
        zoneID = zone.id
        maxFavourites = settings.maxFavourites
        reset = .milliseconds(Double(settings.resetTimeout) * timeScale)
        self.logger = logger
        self.host = host
        let zoneName = zone.player.zoneName
        let sonosName = zone.sonosName
        var inputs: [Service] = []
        for n in 1...settings.maxFavourites {
            let input = Service(.inputSource, name: "Input \(n)", subtype: "tvInput\(n)", optional: [.identifier, .inputDeviceType, .targetVisibilityState])
            input.characteristic(.configuredName).value = .string("Input \(n)")
            input.characteristic(.identifier).value = .int(n)
            input.characteristic(.inputSourceType).value = .int(HAPConstants.InputSourceType.other)
            input.characteristic(.inputDeviceType).value = .int(5)
            input.characteristic(.isConfigured).value = .int(HAPConstants.IsConfigured.notConfigured)
            input.characteristic(.currentVisibilityState).value = .int(HAPConstants.CurrentVisibilityState.hidden)
            input.characteristic(.targetVisibilityState).value = .int(HAPConstants.CurrentVisibilityState.hidden)
            input.characteristic(.targetVisibilityState).onWrite { value in
                input.characteristic(.currentVisibilityState).value = .int(value.intValue ?? 1)
            }
            inputs.append(input)
        }
        self.inputs = inputs
        speaker = Service(.televisionSpeaker, name: "\(zoneName) TV Speaker", subtype: "tvSpeaker", optional: [.volumeControlType, .volumeSelector], extra: [
            Characteristic(SonosCharacteristic.configuredName, value: .string("\(zoneName) TV Speaker")),
        ])
        speaker.characteristic(.volumeControlType).value = .int(HAPConstants.VolumeControlType.absolute)
        television = Service(
            .television, name: sonosName, subtype: "tv", optional: [.displayOrder, .powerModeSelection],
            extra: [Characteristic(.activeIdentifier.with(minValue: 0, maxValue: Double(settings.maxFavourites)), value: .int(0)), Characteristic(.statusFault, value: .int(1))],
            linked: inputs + [speaker], isPrimary: true)
        television.characteristic(.configuredName).value = .string(sonosName)
        television.characteristic(.sleepDiscoveryMode).value = .int(HAPConstants.SleepDiscoveryMode.alwaysDiscoverable)
        television.characteristic(.displayOrder).value = .string(Self.displayOrder(count: settings.maxFavourites))
        let description = zone.description
        let seed = Self.seed(playerID: zone.id, prefix: settings.tvIdPrefix)
        accessory = Accessory(
            id: SonosPlugin.accessoryID(seed), name: zone.player.accessoryName, manufacturer: description.manufacturer, model: description.model,
            serialNumber: seed, firmwareRevision: description.displayVersion, category: .speaker, services: [television, speaker] + inputs,
            onIdentify: { [host, zoneID = zone.id] in try await host.plugin?.identify(zoneID) })
        wire()
    }

    /// `01 04 <id> 00 00 00` per identifier, then `00 00`, in base64.
    static func displayOrder(count: Int) -> String {
        var bytes: [UInt8] = []
        for identifier in 1...count { bytes += [0x01, 0x04, UInt8(identifier & 0xFF), 0, 0, 0] }
        bytes += [0, 0]
        return Data(bytes).base64EncodedString()
    }

    private func wire() {
        television.characteristic(.active).onWrite { [weak self] value in
            guard let sonos = self?.zone?.services?.sonos else { return }
            try await sonos.characteristic(.on).write(.bool(value.intValue == HAPConstants.Active.active))
        }
        television.characteristic(.activeIdentifier).onWrite { [weak self] value in
            await self?.select(identifier: value.intValue ?? 0)
        }
        television.characteristic(.configuredName).onWrite { [weak self] value in
            guard let name = value.stringValue, !name.isEmpty else { throw HAPStatusError(.invalidValueInRequest) }
            self?.zone?.services?.sonos[SonosCharacteristic.configuredName]?.value = .string(name)
        }
        television.characteristic(.powerModeSelection).onWrite { [weak self] _ in
            try await self?.zone?.services?.sonos[SonosCharacteristic.sonosCoordinator]?.write(.bool(true))
        }
        television.characteristic(.remoteKey).onWrite { [weak self] value in
            guard let self, let sonos = zone?.services?.sonos else { return }
            let key = value.intValue ?? -1
            switch key {
            case HAPConstants.RemoteKey.playPause:
                try await sonos.characteristic(.on).write(.bool(!(sonos.characteristic(.on).value.boolValue ?? false)))
            case HAPConstants.RemoteKey.arrowLeft:
                try await sonos[SonosCharacteristic.changeTrack]?.write(.int(-1))
            case HAPConstants.RemoteKey.arrowRight:
                try await sonos[SonosCharacteristic.changeTrack]?.write(.int(1))
            case HAPConstants.RemoteKey.arrowUp:
                await step(-1)
            case HAPConstants.RemoteKey.arrowDown:
                await step(1)
            default:
                logger.info("\(accessory.name): remote key \(Self.keyName(key))")
            }
        }
        speaker.characteristic(.volumeSelector).onWrite { [weak self] value in
            guard let services = self?.zone?.services else { return }
            let target = services.speakers ?? services.sonos
            self?.logger.info("\(target.characteristic(.name).value.stringValue ?? ""): volume \(value.intValue == 0 ? "up" : "down")")
            try await target[SonosCharacteristic.changeVolume]?.write(.int(value.intValue == 0 ? 1 : -1))
        }
        speaker.characteristic(.mute).onWrite { [weak self] value in
            guard let services = self?.zone?.services else { return }
            try await (services.speakers ?? services.sonos).characteristic(.mute).write(value)
        }
    }

    static func keyName(_ key: Int) -> String {
        switch key {
        case 0: "Rewind"
        case 1: "Fast Forward"
        case 2: "Next Track"
        case 3: "Previous Track"
        case 8: "Select"
        case 9: "Back"
        case 10: "Exit"
        case 15: "Info"
        default: "\(key)"
        }
    }

    /// Follows the zone's Sonos service (after each build of the zone's accessory): Active is its On.
    func attach(to sonos: Service) {
        let token = sonos.characteristic(.on).observe { [weak self] change in
            self?.television.characteristic(.active).value = .int(change.newValue.boolValue == true ? HAPConstants.Active.active : HAPConstants.Active.inactive)
        }
        let previous = state.withLockedValue { state -> (Characteristic, Int)? in
            defer { state.observer = (sonos.characteristic(.on), token) }
            return state.observer
        }
        if let (characteristic, oldToken) = previous { characteristic.removeObserver(oldToken) }
        television.characteristic(.active).value = .int(sonos.characteristic(.on).value.boolValue == true ? 1 : 0)
        sonos.characteristic(.activeIdentifier).value = television.characteristic(.activeIdentifier).value
    }

    func renamed(to name: String) {
        television.characteristic(.configuredName).value = .string(name)
    }

    func setFault(_ fault: Bool) {
        television.characteristic(.statusFault).value = .int(fault ? 1 : 0)
        if accessory.isUnavailable != fault { accessory.isUnavailable = fault }
    }

    // MARK: Inputs

    /// The input table for the zone now and these favourites.
    func table(favourites: [Favourite]) -> [Input] {
        guard let zone else { return [] }
        let player = zone.player
        let id = zone.id
        var group = Input(name: "none", uri: nil, configured: false, shown: false, type: HAPConstants.InputSourceType.other)
        if zone.groupShortName != player.zoneName {
            group = Input(name: "Leave \(zone.groupShortName)", uri: nil, configured: true, shown: true, type: HAPConstants.InputSourceType.other)
        } else if let target = zone.targetCoordinator, target != id {
            group = Input(name: "Join \(zone.targetGroupShortName ?? target)", uri: "x-rincon:\(target)", configured: true, shown: true, type: HAPConstants.InputSourceType.other)
        }
        var table = [
            group,
            Input(name: "AirPlay", uri: "x-sonos-vli:\(id):1", configured: true, shown: false, type: HAPConstants.InputSourceType.other),
            Input(name: "Audio In", uri: "x-rincon-stream:\(id)", configured: zone.description.audioIn, shown: zone.description.audioIn, type: HAPConstants.InputSourceType.other),
            Input(name: "TV", uri: "x-sonos-htastream:\(id):spdif", configured: zone.description.tvIn, shown: zone.description.tvIn, type: HAPConstants.InputSourceType.hdmi),
        ]
        for favourite in favourites {
            table.append(Input(
                name: TransportUpdate.truncated(favourite.title, toBytes: 64), uri: favourite.uri, configured: true, shown: true,
                type: favourite.uri.hasPrefix("x-sonosapi-stream:") ? HAPConstants.InputSourceType.tuner : HAPConstants.InputSourceType.other, favourite: favourite))
        }
        while table.count < maxFavourites - 1 {
            table.append(Input(name: "Input \(table.count + 1)", uri: nil, configured: false, shown: false, type: HAPConstants.InputSourceType.other))
        }
        table.append(Input(name: "Sonos Chime", uri: "x-rincon-buzzer:0", configured: true, shown: false, type: HAPConstants.InputSourceType.other))
        return table
    }

    /// New favourites: the table rebuilt, the services reconfigured, the visible names logged.
    func setFavourites(_ favourites: [Favourite]) {
        state.withLockedValue { $0.favourites = favourites }
        refresh(log: true)
    }

    /// The group entry again (a topology or target coordinator change), or everything.
    func refresh(log: Bool = false) {
        let favourites = state.withLockedValue { $0.favourites }
        let table = table(favourites: favourites)
        let changed = state.withLockedValue { state -> Bool in
            defer { state.table = table }
            return state.table != table
        }
        guard changed else { return }
        for (index, input) in table.prefix(maxFavourites).enumerated() {
            let service = inputs[index]
            service.characteristic(.configuredName).value = .string(input.name)
            service.characteristic(.inputSourceType).value = .int(input.type)
            service.characteristic(.isConfigured).value = .int(input.configured ? HAPConstants.IsConfigured.configured : HAPConstants.IsConfigured.notConfigured)
            let visibility = input.shown ? HAPConstants.CurrentVisibilityState.shown : HAPConstants.CurrentVisibilityState.hidden
            service.characteristic(.targetVisibilityState).value = .int(visibility)
            service.characteristic(.currentVisibilityState).value = .int(visibility)
        }
        if log {
            logger.info("\(accessory.name): inputs: \(table.prefix(maxFavourites).filter(\.shown).map(\.name).joined(separator: ", "))")
        }
        uriChanged()
    }

    /// ActiveIdentifier from the zone's URI: the first input playing it, else 0.
    func uriChanged() {
        guard let uri = zone?.uri else { return setActiveIdentifier(0) }
        let table = state.withLockedValue { $0.table }
        let index = table.prefix(maxFavourites).firstIndex { $0.uri == uri }
        setActiveIdentifier(index.map { $0 + 1 } ?? 0)
    }

    private func setActiveIdentifier(_ identifier: Int) {
        television.characteristic(.activeIdentifier).value = .int(identifier)
        zone?.services?.sonos[.activeIdentifier]?.value = .int(identifier)
    }

    /// HomeKit picked input `identifier`.
    func select(identifier: Int) async {
        guard let zone, identifier >= 1, identifier <= maxFavourites else { return }
        let table = state.withLockedValue { $0.table }
        guard identifier <= table.count else { return }
        let input = table[identifier - 1]
        zone.services?.sonos[.activeIdentifier]?.value = .int(identifier)
        guard let plugin = host.plugin else { return }
        if identifier == 1, input.uri == nil {
            guard input.configured else { return }
            do {
                try await plugin.client(zone.id)?.call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [("InstanceID", "0")])
            } catch {
                logger.warning("\(accessory.name): leave group: \(error)")
            }
            return
        }
        guard let uri = input.uri else { return }
        let target = identifier <= 4 ? zone.id : (zone.zoneGroup.isEmpty ? zone.id : zone.zoneGroup)
        guard let client = await plugin.client(target) else { return }
        do {
            if let favourite = input.favourite, favourite.isContainer {
                try await client.call(.avTransport, "RemoveAllTracksFromQueue", [("InstanceID", "0")])
                try await client.call(.avTransport, "AddURIToQueue", [
                    ("InstanceID", "0"), ("EnqueuedURI", favourite.uri), ("EnqueuedURIMetaData", favourite.metadata),
                    ("DesiredFirstTrackNumberEnqueued", "1"), ("EnqueueAsNext", "1"),
                ])
                try await client.call(.avTransport, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", "x-rincon-queue:\(target)#0"), ("CurrentURIMetaData", "")])
            } else {
                try await client.call(.avTransport, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", input.favourite?.metadata ?? "")])
            }
        } catch {
            logger.warning("\(accessory.name): input \(input.name): \(error)")
            return
        }
        do {
            try await client.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        } catch {
            logger.info("\(accessory.name): play: \(error)")
        }
        if identifier == 1 {
            // After a join the identifier goes back to the zone's, which follows the coordinator's URI.
            television.characteristic(.activeIdentifier).revert(after: reset) { [weak zone] in
                zone?.services?.sonos[.activeIdentifier]?.value ?? .int(0)
            }
        }
    }

    /// The next (+1) or previous (-1) visible input, wrapping between 2 and `maxFavourites - 1`.
    func step(_ direction: Int) async {
        let start = television.characteristic(.activeIdentifier).value.intValue ?? 0
        let low = 2
        let high = maxFavourites - 1
        var identifier = start
        for _ in 0...max(high - low, 0) {
            identifier += direction
            if identifier < low { identifier = high } else if identifier > high { identifier = low }
            if identifier == start { return }
            if inputs[identifier - 1].characteristic(.currentVisibilityState).value.intValue == HAPConstants.CurrentVisibilityState.shown {
                television.characteristic(.activeIdentifier).value = .int(identifier)
                await select(identifier: identifier)
                return
            }
        }
    }
}
