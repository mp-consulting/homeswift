import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSonos

/// The plugin on a host, against a fake household (Support.swift): discovery, accessories, events and writes.
@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    let environment = TestEnvironment()
    let living = SonosPlugin.accessoryID(Fixtures.livingRoom)
    let kitchen = SonosPlugin.accessoryID(Fixtures.kitchen)
    let garden = SonosPlugin.accessoryID(Fixtures.garden)

    private func started(_ settings: [String: Any] = [:]) async throws -> PluginHost {
        let host = try await environment.start(settings: settings)
        environment.discoverLivingRoom()
        let ids = [living, kitchen, garden]
        let ready = await eventually { ids.allSatisfy { host.accessory($0) != nil } }
        #expect(ready)
        return host
    }

    private func sonos(_ host: PluginHost, _ id: String) throws -> Service {
        try #require(host.accessory(id)?.service(.switch, subtype: "group"))
    }

    @Test func zonesBecomeSpeakersWithTheirIdentity() async throws {
        let host = try await started()
        let accessory = try #require(host.accessory(living))
        #expect(accessory.category == .speaker)
        #expect(accessory.information.characteristic(.name).value == .string("Living Room"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string(Fixtures.livingRoom))
        #expect(accessory.information.characteristic(.manufacturer).value == .string("Sonos"))
        #expect(accessory.information.characteristic(.model).value == .string("Beam (S14)"))
        #expect(accessory.information.characteristic(.firmwareRevision).value == .string("16.4"))
        let sonos = try sonos(host, living)
        #expect(sonos.isPrimary)
        #expect(sonos.characteristic(.name).value == .string("Living Room Sonos"))
        #expect(sonos[.volume] != nil && sonos[.mute] != nil && sonos[SonosCharacteristic.tv] != nil)
        #expect(sonos[.activeIdentifier] == nil)
        #expect(sonos[.setDuration]?.type.maxValue == 86399)
        // The sub is invisible, the household's other players get their own zones.
        #expect(host.accessory(SonosPlugin.accessoryID(Fixtures.sub)) == nil)
        let gardenBattery = try #require(host.accessory(garden)?.service(.battery))
        #expect(gardenBattery[.batteryLevel]?.value == .int(85))
        #expect(gardenBattery[.chargingState]?.value == .int(0))
        #expect(host.accessory(garden)?.service(.battery)?[.name]?.value == .string("Garden Battery"))
        await host.stop()
    }

    @Test func eventsReachHomeKit() async throws {
        let host = try await started()
        let sonos = try sonos(host, living)
        // The first events of each subscription: AVTransport (§8.6) and GroupRenderingControl (§8.7).
        #expect(await eventually { sonos[SonosCharacteristic.currentTrack]?.value == .string("Artist X - Song Y") })
        // The play mode is another variable of the same event, applied after the track: waited for too.
        #expect(await eventually { sonos[SonosCharacteristic.shuffle]?.value == .bool(true) })
        #expect(sonos.characteristic(.on).value == .bool(true))
        #expect(await eventually { sonos.characteristic(.volume).value == .int(14) })
        #expect(await eventually { sonos[.remainingDuration]?.value == .int(1781) })
        #expect(sonos[SonosCharacteristic.sonosGroup]?.value == .string("Living Room + 1"))
        #expect(sonos[.statusFault]?.value == .int(0))
        #expect(sonos[SonosCharacteristic.lastSeen]?.value.stringValue != LastSeen.never)
        // Kitchen is in the Living Room's group: it follows its coordinator.
        let kitchenSonos = try self.sonos(host, kitchen)
        #expect(await eventually { kitchenSonos[SonosCharacteristic.sonosGroup]?.value == .string("Living Room + 1") })
        await host.stop()
    }

    @Test func groupWritesGoToTheCoordinator() async throws {
        let host = try await started()
        let kitchenSonos = try sonos(host, kitchen)
        // Kitchen's Sonos service sets its group's volume, on the Living Room's player.
        try await kitchenSonos.characteristic(.volume).write(.int(25))
        #expect(await eventually { environment.sonos.calls("SetGroupVolume").contains { $0.address == "192.168.1.10" && $0.arguments["DesiredVolume"] == "25" } })
        try await kitchenSonos.characteristic(.mute).write(.bool(true))
        #expect(await eventually { environment.sonos.calls("SetGroupMute").last?.address == "192.168.1.10" })
        await host.stop()
    }

    @Test func sliderWritesAreCoalesced() async throws {
        let host = try await started()
        let sonos = try sonos(host, living)
        await withTaskGroup(of: Void.self) { group in
            for volume in [10, 20, 30, 40] { group.addTask { try? await sonos.characteristic(.volume).write(.int(volume)) } }
        }
        #expect(await eventually { environment.sonos.calls("SetGroupVolume").count == 1 })
        #expect(environment.sonos.calls("SetGroupVolume").first?.arguments["DesiredVolume"] != nil)
        await host.stop()
    }

    @Test func playWithASleepTimer() async throws {
        let host = try await started()
        let sonos = try sonos(host, living)
        // The event publishes On before applying its allowed transport actions. Wait for the whole event.
        #expect(await eventually { environment.sonos.hasDeliveredEvent(Fixtures.livingRoom, "/MediaRenderer/AVTransport/Event") })
        #expect(sonos.characteristic(.on).value == .bool(true))
        try await sonos.characteristic(.setDuration).write(.int(5400))
        try await sonos.characteristic(.on).write(.bool(false))
        #expect(await eventually { environment.sonos.calls("Pause").count == 1 })
        try await sonos.characteristic(.on).write(.bool(true))
        #expect(await eventually { environment.sonos.calls("ConfigureSleepTimer").last?.arguments["NewSleepTimerDuration"] == "01:30:00" })
        #expect(environment.sonos.calls("Play").count == 1)
        // A refused write: no CROSSFADE-less shuffle… repeat one needs REPEATONE, which the zone does not offer.
        try await sonos.characteristic(SonosCharacteristic.repeatMode).write(.int(1))
        #expect(await eventually { sonos.characteristic(SonosCharacteristic.repeatMode).value == .int(0) })
        #expect(environment.sonos.calls("SetPlayMode").isEmpty)
        try await sonos.characteristic(SonosCharacteristic.crossfade).write(.bool(true))
        #expect(await eventually { environment.sonos.calls("SetCrossfadeMode").last?.arguments["CrossfadeMode"] == "1" })
        // Momentary characteristics go back to 0.
        try await sonos.characteristic(SonosCharacteristic.changeVolume).write(.int(3))
        #expect(await eventually { environment.sonos.calls("SetRelativeGroupVolume").last?.arguments["Adjustment"] == "3" })
        #expect(await eventually { sonos.characteristic(SonosCharacteristic.changeVolume).value == .int(0) })
        await host.stop()
    }

    @Test func subscriptionsHonourTheConfiguredDuration() async throws {
        let host = try await started(["subscriptionTimeout": 5])
        #expect(await eventually { environment.sonos.subscribes.contains { $0.path == "/MediaRenderer/AVTransport/Event" && $0.address == "192.168.1.10" } })
        let subscribe = try #require(environment.sonos.subscribes.first { $0.path == "/MediaRenderer/AVTransport/Event" && $0.address == "192.168.1.10" })
        #expect(subscribe.headers["TIMEOUT"] == "Second-330")
        #expect(subscribe.headers["NT"] == "upnp:event")
        #expect(subscribe.headers["CALLBACK"] == "<http://192.168.1.2:58004/notify/\(Fixtures.livingRoom)/MediaRenderer/AVTransport/Event>")
        // Renewed with the SID alone (time scaled down in tests).
        #expect(await eventually { environment.sonos.subscribes.contains { $0.headers["SID"] != nil && $0.headers["CALLBACK"] == nil && $0.headers["TIMEOUT"] == "Second-330" } })
        // Probing subscribed to the topology for a moment, then unsubscribed.
        #expect(await eventually { environment.sonos.subscribes.contains { $0.method == "UNSUBSCRIBE" && $0.path == "/ZoneGroupTopology/Event" } })
        await host.stop()
    }

    @Test func notifiesComeOnlyFromThePlayer() async throws {
        let host = try await started()
        let status = await environment.sonos.notify(Fixtures.livingRoom, "/MediaRenderer/GroupRenderingControl/Event", Fixtures.groupRenderingEvent, from: "192.168.1.99")
        #expect(status == 403)
        #expect(await environment.sonos.notify("RINCON_UNKNOWN", "/MediaRenderer/AVTransport/Event", Fixtures.avTransportEvent, from: "192.168.1.10") == 403)
        await host.stop()
    }

    @Test func aSpoofedAnnouncementDoesNotMoveAPlayer() async throws {
        let host = try await started()
        let plugin = try #require(environment.plugin)
        // Another host announces the Living Room's id; its address does not answer as the Living Room.
        environment.discovery.continuation.yield(DiscoveryHit(id: Fixtures.livingRoom, address: "192.168.1.66", household: Fixtures.household))
        let asked = await eventually { await plugin.players[Fixtures.livingRoom] != nil }
        #expect(asked)
        // The Garden's address answers as the Garden, not the Living Room: no move either.
        environment.discovery.continuation.yield(DiscoveryHit(id: Fixtures.livingRoom, address: "192.168.1.13", household: Fixtures.household))
        try await sonos(host, living).characteristic(.mute).write(.bool(true))
        #expect(await eventually { environment.sonos.calls("SetGroupMute").count == 1 })
        #expect(environment.sonos.calls("SetGroupMute").first?.address == "192.168.1.10")
        #expect(await plugin.players[Fixtures.livingRoom]?.client.address == "192.168.1.10")
        await host.stop()
    }

    @Test func speakersAndBalance() async throws {
        let host = try await started(["speakers": true])
        let speakers = try #require(host.accessory(living)?.service(.switch, subtype: "zone"))
        #expect(speakers[SonosCharacteristic.surroundEnabled] != nil && speakers[SonosCharacteristic.subLevel] != nil)
        #expect(speakers[SonosCharacteristic.nightSound] != nil)
        #expect(speakers[SonosCharacteristic.balance] == nil)
        #expect(await eventually { speakers[SonosCharacteristic.treble]?.value == .int(-1) })
        #expect(speakers.characteristic(.volume).value == .int(30))
        #expect(speakers[SonosCharacteristic.subLevel]?.value == .int(3))
        #expect(speakers[SonosCharacteristic.loudness]?.value == .bool(true))
        // The Living Room coordinates its group; Kitchen is a member.
        #expect(speakers.characteristic(.on).value == .bool(false))
        let kitchenSpeakers = try #require(host.accessory(kitchen)?.service(.switch, subtype: "zone"))
        #expect(kitchenSpeakers.characteristic(.on).value == .bool(true))
        try await kitchenSpeakers.characteristic(.on).write(.bool(false))
        #expect(await eventually { environment.sonos.calls("BecomeCoordinatorOfStandaloneGroup").last?.address == "192.168.1.12" })
        try await speakers[SonosCharacteristic.bass]?.write(.int(-4))
        #expect(await eventually { environment.sonos.calls("SetBass").last?.arguments == ["InstanceID": "0", "DesiredBass": "-4"] })
        await host.stop()
    }

    @Test func ledsAndSlaves() async throws {
        let host = try await started(["leds": true])
        let led = try #require(host.accessory(living)?.service(.lightbulb, subtype: "led"))
        #expect(led.characteristic(.name).value == .string("Living Room Sonos LED"))
        // The sub's own accessory, named and subtyped by its (sorted) channel label.
        let subID = SonosPlugin.accessoryID(Fixtures.sub)
        #expect(await eventually { host.accessory(subID) != nil })
        let subLED = try #require(host.accessory(subID)?.service(.lightbulb, subtype: "ledLS"))
        #expect(subLED.characteristic(.name).value == .string("Living Room Sonos LS LED"))
        #expect(subLED[.statusFault] != nil)
        let read = try #require(led.characteristic(.on).readHandler)
        #expect(try await read() == .bool(true))
        try await led.characteristic(.lockPhysicalControls).write(.int(1))
        #expect(await eventually { environment.sonos.calls("SetButtonLockState").last?.arguments["DesiredButtonLockState"] == "On" })
        await host.stop()
    }

    @Test func alarmsAreSwitches() async throws {
        let host = try await started(["alarms": true])
        let kitchen = kitchen
        let added = await eventually { host.accessory(kitchen)?.service(.switch, subtype: "alarm12") != nil }
        #expect(added)
        let alarm = try #require(host.accessory(kitchen)?.service(.switch, subtype: "alarm12"))
        #expect(alarm.characteristic(.name).value == .string("Kitchen Sonos Alarm 12"))
        #expect(alarm.characteristic(.on).value == .bool(true))
        #expect(alarm[SonosCharacteristic.currentTrack]?.value == .string("Sonos Chime"))
        #expect(alarm[SonosCharacteristic.time]?.value == .string("07:30:00"))
        try await alarm.characteristic(.on).write(.bool(false))
        #expect(await eventually { environment.sonos.calls("UpdateAlarm").last?.arguments["Enabled"] == "0" })
        await host.stop()
    }

    @Test func tvsListTheFavourites() async throws {
        let host = try await started(["tv": true, "maxFavourites": 16])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.zones[Fixtures.livingRoom]?.tv.withLockedValue({ $0 }) != nil })
        let tv = try #require(await plugin.zones[Fixtures.livingRoom]?.tv.withLockedValue { $0 })
        #expect(tv.accessory.id == "ZP:TV_000E58A1B2C301400")
        #expect(tv.inputs.count == 16)
        #expect(tv.inputs.first?.subtype == "tvInput1")
        #expect(await eventually { tv.inputs[4].characteristic(.configuredName).value == .string("Jazz Radio") })
        #expect(tv.inputs[4].characteristic(.inputSourceType).value == .int(HAPConstants.InputSourceType.tuner))
        #expect(tv.inputs[0].characteristic(.configuredName).value == .string("Leave Living Room + 1"))
        #expect(tv.inputs[3].characteristic(.configuredName).value == .string("TV"))
        #expect(tv.inputs[15].characteristic(.configuredName).value == .string("Sonos Chime"))
        // Selecting the favourite on a zone in a group plays it on the coordinator.
        try await tv.television.characteristic(.activeIdentifier).write(.int(5))
        #expect(await eventually { environment.sonos.calls("SetAVTransportURI").last?.arguments["CurrentURI"] == "x-sonosapi-stream:s5678?sid=254&flags=8224&sn=0" })
        #expect(await eventually { environment.sonos.calls("Play").last?.address == "192.168.1.10" })
        // Active mirrors the Sonos service's On.
        #expect(tv.television.characteristic(.active).value == .int(1))
        await host.stop()
    }

    @Test func aVanishedOrSilentPlayerHasNoResponse() async throws {
        let host = try await started()
        let gardenAccessory = try #require(host.accessory(garden))
        #expect(!gardenAccessory.isUnavailable)
        // The Garden vanishes from the topology.
        let vanished = Fixtures.zoneGroupState().replacingOccurrences(of: Fixtures.office, with: Fixtures.garden)
        await environment.sonos.notify(Fixtures.livingRoom, "/ZoneGroupTopology/Event", Fixtures.topologyEvent(vanished))
        #expect(await eventually { gardenAccessory.isUnavailable })
        #expect(try sonos(host, garden)[.statusFault]?.value == .int(1))
        // Any message from it brings it back.
        await environment.sonos.notify(Fixtures.garden, "/MediaRenderer/GroupRenderingControl/Event", Fixtures.groupRenderingEvent)
        #expect(await eventually { !gardenAccessory.isUnavailable })
        // Silent for ten (scaled) minutes and not answering: lost.
        environment.sonos.setUnreachable("192.168.1.13")
        let plugin = try #require(environment.plugin)
        #expect(await eventually {
            await plugin.checkPlayers()
            return gardenAccessory.isUnavailable
        })
        await host.stop()
    }

    @Test func topologyChangesMoveZonesBetweenGroups() async throws {
        let host = try await started()
        let kitchenSonos = try sonos(host, kitchen)
        #expect(await eventually { kitchenSonos[SonosCharacteristic.sonosGroup]?.value == .string("Living Room + 1") })
        await environment.sonos.notify(Fixtures.livingRoom, "/ZoneGroupTopology/Event", Fixtures.topologyEvent(Fixtures.zoneGroupState(kitchenGroup: Fixtures.kitchen)))
        #expect(await eventually { kitchenSonos[SonosCharacteristic.sonosGroup]?.value == .string("Kitchen") })
        // Now Kitchen's writes go to its own player.
        try await kitchenSonos.characteristic(.mute).write(.bool(true))
        #expect(await eventually { environment.sonos.calls("SetGroupMute").last?.address == "192.168.1.12" })
        // Becoming the target coordinator marks it, and only it.
        try await kitchenSonos.characteristic(SonosCharacteristic.sonosCoordinator).write(.bool(true))
        #expect(await eventually { kitchenSonos[SonosCharacteristic.sonosCoordinator]?.value == .bool(true) })
        #expect(try sonos(host, living)[SonosCharacteristic.sonosCoordinator]?.value == .bool(false))
        await host.stop()
    }

    @Test func setupListsThePlayers() async throws {
        let host = try await started()
        let plugin = try #require(environment.plugin)
        let devices = try await plugin.discover()
        #expect(devices.map(\.deviceID).contains(Fixtures.livingRoom))
        #expect(devices.first { $0.deviceID == Fixtures.livingRoom }?.isSetUp == true)
        #expect(!devices.contains { $0.deviceID == Fixtures.sub })
        await host.stop()
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(SonosPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Sonos SonosPlugin")
        let schema = try JSONValue(string: try #require(SonosPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "ZP")
    }
}
