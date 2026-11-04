import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSonos

/// The wire formats, against the spec's vectors (docs/clean-room/Sonos.md, section 8).
@Suite struct ProtocolTests {
    @Test func theBlockIsReadLeniently() throws {
        let json = #"{"platform":"ZP","leds":"yes","alarms":1,"tv":"off","heartrate":"0x0A","maxFavourites":200,"port":80,"resetTimeout":1000,"subscriptionTimeout":"5","service":"radio","timeout":"many"}"#
        let configuration = try JSONDecoder().decode(SonosPlugin.Configuration.self, from: Data(json.utf8))
        let settings = SonosPlugin.Settings(configuration)
        #expect(settings.leds && settings.alarms && !settings.tv)
        #expect(settings.heartrate == 10)
        #expect(settings.maxFavourites == 96)
        #expect(settings.port == 0)
        #expect(settings.resetTimeout == 1000)
        #expect(settings.subscriptionTimeout == 300)
        #expect(settings.service == .switch)
        #expect(settings.timeout == 15)
        #expect(settings.warnings.contains { $0.contains("service") })
        #expect(settings.warnings.contains { $0.contains("timeout") })
        #expect(settings.warnings.contains { $0.contains("maxFavourites") })
    }

    @Test func aMinimalBlockHasTheDefaults() throws {
        let settings = SonosPlugin.Settings(try JSONDecoder().decode(SonosPlugin.Configuration.self, from: Data(#"{"platform":"ZP"}"#.utf8)))
        #expect(settings == SonosPlugin.Settings())
        #expect(settings.resetTimeout == 500 && settings.subscriptionTimeout == 1800 && settings.mdns && settings.tvIdPrefix == "TV")
        #expect(settings.volumeType == .volume)
    }

    @Test func brightnessAppliesToSwitchAndSpeakerOnly() throws {
        func settings(_ json: String) throws -> SonosPlugin.Settings {
            SonosPlugin.Settings(try JSONDecoder().decode(SonosPlugin.Configuration.self, from: Data(json.utf8)))
        }
        #expect(try settings(#"{"brightness":true}"#).volumeType == .brightness)
        #expect(try settings(#"{"brightness":true,"service":"speaker"}"#).volumeType == .brightness)
        let light = try settings(#"{"brightness":true,"service":"fan"}"#)
        #expect(light.volumeType == .rotationSpeed)
        #expect(light.warnings.contains { $0.contains("ignoring brightness for service fan") })
    }

    @Test func ssdpAnswersAndAnnouncementsGiveThePlayer() throws {
        let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nEXT:\r\nLOCATION: http://192.168.1.10:1400/xml/device_description.xml\r\n"
            + "SERVER: Linux UPnP/1.0 Sonos/80.1-55240 (ZPS18)\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n"
            + "USN: uuid:RINCON_000E58A1B2C301400::urn:schemas-upnp-org:device:ZonePlayer:1\r\nX-RINCON-HOUSEHOLD: Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d\r\n"
            + "X-RINCON-BOOTSEQ: 42\r\nBOOTID.UPNP.ORG: 42\r\nX-RINCON-WIFIMODE: 0\r\nX-RINCON-VARIANT: 2\r\n\r\n"
        let message = try #require(SSDPMessage.parse(Data(answer.utf8)))
        let expected = DiscoveryHit(id: Fixtures.livingRoom, address: "192.168.1.10", household: Fixtures.household, bootSeq: 42)
        #expect(Discovery.hit(message, from: "192.168.1.10") == expected)
        let alive = answer.replacingOccurrences(of: "HTTP/1.1 200 OK", with: "NOTIFY * HTTP/1.1")
            .replacingOccurrences(of: "ST: ", with: "NTS: ssdp:alive\r\nNT: ")
        #expect(Discovery.hit(try #require(SSDPMessage.parse(Data(alive.utf8))), from: "192.168.1.10") == expected)
        let byebye = alive.replacingOccurrences(of: "ssdp:alive", with: "ssdp:byebye")
        #expect(Discovery.hit(try #require(SSDPMessage.parse(Data(byebye.utf8))), from: "192.168.1.10") == nil)
        let other = answer.replacingOccurrences(of: "ZonePlayer:1\r\nUSN", with: "MediaRenderer:1\r\nUSN")
        #expect(Discovery.hit(try #require(SSDPMessage.parse(Data(other.utf8))), from: "192.168.1.10") == nil)
    }

    @Test func mdnsServicesGiveThePlayer() {
        let service = BonjourService(
            name: "Kitchen", type: "_sonos._tcp", domain: "local.", hostName: "Sonos-000E58A1B2C3.local.", port: 1443,
            txt: ["uuid": Fixtures.livingRoom, "hhid": Fixtures.household, "bootseq": "42", "info": "/api/v1/players/x/info"],
            addresses: ["fe80::1", "192.168.1.10"], interfaceIndex: 1)
        #expect(Discovery.hit(service) == DiscoveryHit(id: Fixtures.livingRoom, address: "192.168.1.10", household: Fixtures.household, bootSeq: 42))
        var missing = service
        missing.txt["hhid"] = nil
        #expect(Discovery.hit(missing) == nil)
    }

    @Test func theDeviceDescriptionIsRead() throws {
        let description = try DeviceDescription(xml: Data(Fixtures.description(id: Fixtures.livingRoom, model: "Sonos Beam", number: "S14", room: "Living Room", tvIn: true).utf8))
        #expect(description.id == Fixtures.livingRoom)
        #expect(description.roomName == "Living Room")
        #expect(description.manufacturer == "Sonos")
        #expect(description.model == "Beam (S14)")
        #expect(description.displayVersion == "16.4")
        #expect(description.generation == "S2")
        #expect(description.tvIn && !description.audioIn)
    }

    @Test func soapRequestsAreBuiltAsSonosTakesThem() throws {
        #expect(SOAP.envelope(service: .deviceProperties, action: "GetLEDState", arguments: []) ==
            #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetLEDState xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"></u:GetLEDState></s:Body></s:Envelope>"#)
        #expect(SOAP.envelope(service: .groupRenderingControl, action: "SetGroupVolume", arguments: [("InstanceID", "0"), ("DesiredVolume", "25")]).contains(
            #"<u:SetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID><DesiredVolume>25</DesiredVolume></u:SetGroupVolume>"#))
        #expect(UPnPService.groupRenderingControl.controlPath == "/MediaRenderer/GroupRenderingControl/Control")
        #expect(UPnPService.zoneGroupTopology.eventPath == "/ZoneGroupTopology/Event")
        let response = #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetLEDStateResponse xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"><CurrentLEDState>On</CurrentLEDState></u:GetLEDStateResponse></s:Body></s:Envelope>"#
        #expect(try SOAP.response(Data(response.utf8), action: "GetLEDState") == ["CurrentLEDState": "On"])
        let fault = #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#
        #expect(throws: SonosError.soapFault(action: "Play", code: "701")) { try SOAP.response(Data(fault.utf8), action: "Play") }
    }

    @Test func theTopologyIsDerived() throws {
        let topology = try Topology(event: Data(Fixtures.topologyEvent().utf8))
        #expect(topology.household == Fixtures.household)
        #expect(topology.vanished == [Fixtures.office])
        let living = try #require(topology.players[Fixtures.livingRoom])
        #expect(living.role == .master && living.homeTheatre && living.airPlay)
        #expect(living.channel == "")
        #expect(living.zoneDisplayName == "Living Room (LS+RS+Sub)")
        #expect(living.groupName == "Living Room + Kitchen")
        #expect(living.groupShortName == "Living Room + 1")
        #expect(living.address == "192.168.1.10")
        #expect(living.satellites == [Fixtures.sub])
        #expect(living.accessoryName == "Living Room")
        let sub = try #require(topology.players[Fixtures.sub])
        // The positional quirk: the sub gets the label at its position in the sorted list.
        #expect(sub.role == .satellite && sub.zone == Fixtures.livingRoom && sub.channel == "LS" && sub.invisible)
        #expect(sub.zonePlayerName == "Living Room (LS)")
        #expect(sub.accessoryName == "Living Room LS")
        let kitchen = try #require(topology.players[Fixtures.kitchen])
        #expect(kitchen.role == .master && kitchen.zoneGroup == Fixtures.livingRoom && kitchen.channel == nil)
        let garden = try #require(topology.players[Fixtures.garden])
        #expect(garden.battery == TopologyPlayer.Battery(level: 85, charging: false))
        #expect(topology.order == [Fixtures.garden, Fixtures.kitchen, Fixtures.livingRoom, Fixtures.sub])
    }

    @Test func stereoPairsAndOlderTopologies() throws {
        let set = "RINCON_A:LF,LF;RINCON_B:RF,RF"
        let state = #"<ZoneGroups><ZoneGroup Coordinator="RINCON_A" ID="x"><ZoneGroupMember UUID="RINCON_A" ZoneName="Bedroom" ChannelMapSet="\#(set)"/><ZoneGroupMember UUID="RINCON_B" ZoneName="Bedroom" ChannelMapSet="\#(set)"/></ZoneGroup></ZoneGroups>"#
        let topology = try Topology(zoneGroupState: state)
        #expect(topology.players["RINCON_A"]?.zoneDisplayName == "Bedroom (L+R)")
        #expect(topology.players["RINCON_A"]?.channel == "L")
        #expect(topology.players["RINCON_A"]?.accessoryName == "Bedroom L")
        #expect(topology.players["RINCON_B"]?.role == .slave)
        #expect(topology.players["RINCON_B"]?.channel == "R")
        #expect(topology.players["RINCON_A"]?.slaves == ["RINCON_B"])
        #expect(Topology.label("LR,RR") == "LS+RS" && Topology.label("XY") == "XY")
    }

    @Test func avTransportEventsAreDecoded() throws {
        let variables = try Events.lastChange(try Events.properties(Data(Fixtures.avTransportEvent.utf8))["LastChange"])
        let update = TransportUpdate(variables)
        #expect(update.on == true)
        #expect(update.track == "Artist X - Song Y")
        #expect(update.uri == "x-sonosapi-stream:s1234?sid=254&amp;flags=8224&amp;sn=0")
        #expect(update.actions == ["Set", "Stop", "Pause", "Play"])
        #expect(update.validPlayModes == ["CROSSFADE"])
        #expect(update.repeatMode == 0 && update.shuffle == true && update.crossfade == false)
        #expect(update.sleepTimerChanged)
        #expect(!update.isTVTrack && !update.tvSignal)
    }

    @Test func tracksFollowTheirScheme() {
        func didl(_ inner: String) -> String {
            #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/"><item id="-1">\#(inner)</item></DIDL-Lite>"#
        }
        let tv = TransportUpdate(["CurrentTrackURI": "x-sonos-htastream:RINCON_X01400:spdif", "CurrentTrackMetaData": didl("<r:streamInfo>2</r:streamInfo>")])
        #expect(tv.track == "TV" && tv.isTVTrack && tv.tvSignal)
        #expect(TransportUpdate(["CurrentTrackURI": "x-sonos-htastream:RINCON_X01400:spdif"]).tvSignal == false)
        #expect(TransportUpdate(["CurrentTrackURI": "x-rincon-buzzer:0"]).track == "Sonos Chime")
        #expect(TransportUpdate(["CurrentTrackURI": "x-sonos-vli:RINCON_X:1,airplay:abc", "CurrentTrackMetaData": didl("<dc:title>Song</dc:title>")]).uri == "x-sonos-vli:RINCON_X:1")
        #expect(TransportUpdate(["CurrentTrackURI": "hls-radio:x", "CurrentTrackMetaData": didl("<r:streamContent>TYPE=SNG|TITLE Song|ARTIST Band|ALBUM A</r:streamContent>")]).track == "Band - Song")
        #expect(TransportUpdate(["CurrentTrackURI": "x-rincon:RINCON_Y"]).track == nil)
        #expect(TransportUpdate(["CurrentTrackURI": "x-file-cifs://a", "CurrentTrackMetaData": didl("<dc:title>ZPSTR_BUFFERING</dc:title>")]).track == nil)
        #expect(TransportUpdate(["CurrentTrackURI": "https://a", "CurrentTrackMetaData": didl("<dc:title>Tom &amp;amp; Jerry</dc:title>")]).track == "Tom & Jerry")
        #expect(TransportUpdate(["CurrentTrackURI": "weird:1"]).unknownScheme == "weird")
        #expect(TransportUpdate(["CurrentTransportActions": "Set", "CurrentTrackURI": "https://a", "CurrentTrackMetaData": didl("<dc:title>X</dc:title>")]).track == "")
        let long = String(repeating: "é", count: 40)
        #expect(TransportUpdate.truncated(long, toBytes: 64).utf8.count == 64)
    }

    @Test func renderingEventsParseSignedNumbers() throws {
        let variables = try Events.lastChange(try Events.properties(Data(Fixtures.renderingEvent.utf8))["LastChange"])
        #expect(variables["Volume"] == "30" && variables["Volume:LF"] == "100" && variables["Volume:RF"] == "80")
        #expect(Events.int(variables["Treble"]) == -1)
        #expect(Events.int(variables["Bass"]) == 2)
        let group = try Events.properties(Data(Fixtures.groupRenderingEvent.utf8))
        #expect(group["GroupVolume"] == "14" && group["GroupMute"] == "0")
        #expect(try Events.lastChange("") == [:])
    }

    @Test func alarmsAreReadAndWrittenBack() throws {
        let alarms = try Alarm.list(Fixtures.alarmList)
        let alarm = try #require(alarms.first)
        #expect(alarm.id == "12" && alarm.enabled && alarm.startTime == "07:30:00" && alarm.track == "Sonos Chime")
        let arguments = alarm.updateArguments(enabled: false)
        #expect(arguments.map(\.0) == ["ID", "StartLocalTime", "Duration", "Recurrence", "Enabled", "RoomUUID", "ProgramURI", "ProgramMetaData", "PlayMode", "Volume", "IncludeLinkedZones"])
        #expect(arguments.map(\.1) == ["12", "07:30:00", "01:00:00", "WEEKDAYS", "0", Fixtures.kitchen, "x-rincon-buzzer:0", "", "SHUFFLE_NOREPEAT", "20", "0"])
    }

    @Test func favouritesKeepTheirMetadata() throws {
        let favourites = Favourite.list(Fixtures.favourites)
        let jazz = try #require(favourites.first)
        #expect(favourites.count == 1)
        #expect(jazz.title == "Jazz Radio" && !jazz.isContainer)
        #expect(jazz.uri == "x-sonosapi-stream:s5678?sid=254&amp;flags=8224&amp;sn=0")
        let metadata = XML.decodeEntities(jazz.metadata)
        let item = try #require(DIDLItem.parse(metadata))
        #expect(item.id == "F00092020s5678" && item.parentID == "L" && item.restricted == "true")
        #expect(item.title == "Jazz Radio" && item.upnpClass == "object.item.audioItem.audioBroadcast")
        #expect(item.description == "TuneIn Station" && item.desc == "SA_RINCON65031_")
        #expect(metadata.hasPrefix(#"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">"#))
    }

    @Test func helpers() throws {
        #expect(SleepTimer.seconds("00:29:41") == 1781)
        #expect(SleepTimer.seconds("") == 0)
        #expect(SleepTimer.text(5400) == "01:30:00")
        let order = try #require(Data(base64Encoded: TVAccessory.displayOrder(count: 16)))
        #expect(Array(order.prefix(12)) == [1, 4, 1, 0, 0, 0, 1, 4, 2, 0, 0, 0])
        #expect(Array(order.suffix(2)) == [0, 0] && order.count == 16 * 6 + 2)
        #expect(TVAccessory.seed(playerID: Fixtures.livingRoom, prefix: "TV") == "TV_000E58A1B2C301400")
        #expect(SonosPlugin.deviceID(ofAccessory: "TV_000E58A1B2C301400") == Fixtures.livingRoom)
        #expect(SonosPlugin.deviceID(ofAccessory: Fixtures.livingRoom) == nil)
        #expect(PlayMode.encode(repeatMode: 1, shuffle: true) == "SHUFFLE_REPEAT_ONE")
        #expect(PlayerClient.seconds("Second-1830") == 1830)
        #expect(SonosCharacteristic.bass.uuid == HAPUUID("00000041-0000-1000-8000-656261617577"))
        #expect(SonosCharacteristic.heightLevel.uuid == HAPUUID("00000090-0000-1000-8000-656261617577"))
    }

    @Test func xmlIsParsedSafely() throws {
        let element = try XML.parse(#"<?xml version="1.0"?><!-- c --><a x='1' y="&lt;&#65;&#x42;"><b>t&amp;u</b><![CDATA[<raw>]]><c/></a>"#)
        #expect(element.attribute("y") == "<AB" && element.attribute("x") == "1")
        #expect(element.value("b") == "t&u")
        #expect(element.text == "<raw>")
        #expect(throws: XMLError.self) { try XML.parse("<a><b></a>") }
        #expect(throws: XMLError.tooDeep) { try XML.parse(String(repeating: "<a>", count: 100) + String(repeating: "</a>", count: 100)) }
        #expect(XML.escape("a&b<'`") == "a&amp;b&lt;&apos;&#96;")
    }

    @Test func theCallbackServerTakesNotifies() async throws {
        let seen = NIOLockedBox()
        let server = try await CallbackServer.bind(port: 0) { request in
            seen.append("\(request.method) \(request.path) \(request.remoteAddress) \(request.body.count)")
            return (200, nil, "")
        }
        defer { Task { await server.close() } }
        let client = HTTPClient()
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/notify/RINCON_X/ZoneGroupTopology/Event"))
        let response = try await client.send(HomeswiftNetwork.HTTPRequest(method: "NOTIFY", url: url, headers: [("NT", "upnp:event")], body: Data("<x/>".utf8)))
        #expect(response.status == 200)
        #expect(seen.values == ["NOTIFY /notify/RINCON_X/ZoneGroupTopology/Event 127.0.0.1 4"])
        let large = try await client.send(HomeswiftNetwork.HTTPRequest(method: "NOTIFY", url: url, body: Data(count: CallbackServer.maximumBodySize + 1)))
        #expect(large.status == 413)
        await server.close()
    }
}

/// Lines a handler saw.
final class NIOLockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
