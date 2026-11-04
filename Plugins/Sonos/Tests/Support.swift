import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftSonos

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

enum Fixtures {
    static let livingRoom = "RINCON_000E58A1B2C301400"
    static let sub = "RINCON_000E58D4E5F601400"
    static let kitchen = "RINCON_000E58998877601400"
    static let garden = "RINCON_000E58AABBCC01400"
    static let office = "RINCON_000E58FFEEDD01400"
    static let household = "Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d"

    static func description(id: String, model: String, number: String, room: String, tvIn: Bool = false, audioIn: Bool = false) -> String {
        var services = """
            <service><serviceType>urn:schemas-upnp-org:service:AlarmClock:1</serviceType><serviceId>urn:upnp-org:serviceId:AlarmClock</serviceId></service>
            <service><serviceType>urn:schemas-upnp-org:service:DeviceProperties:1</serviceType><serviceId>urn:upnp-org:serviceId:DeviceProperties</serviceId></service>
            """
        if tvIn { services += "<service><serviceType>urn:schemas-upnp-org:service:HTControl:1</serviceType><serviceId>urn:upnp-org:serviceId:HTControl</serviceId></service>" }
        if audioIn { services += "<service><serviceType>urn:schemas-upnp-org:service:AudioIn:1</serviceType><serviceId>urn:upnp-org:serviceId:AudioIn</serviceId></service>" }
        return """
            <?xml version="1.0" encoding="utf-8" ?>
            <root xmlns="urn:schemas-upnp-org:device-1-0">
             <specVersion><major>1</major><minor>0</minor></specVersion>
             <device>
              <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
              <manufacturer>Sonos, Inc.</manufacturer>
              <modelNumber>\(number)</modelNumber>
              <modelName>\(model)</modelName>
              <UDN>uuid:\(id)</UDN>
              <displayVersion>16.4</displayVersion>
              <roomName>\(room)</roomName>
              <serviceList>\(services)</serviceList>
              <deviceList><!-- MediaServer and MediaRenderer sub-devices --></deviceList>
             </device>
            </root>
            """
    }

    /// §8.8's household: a Beam with a Sub (and surrounds), Kitchen in its group, Garden on battery, Office vanished.
    static func zoneGroupState(vanished: Bool = true, kitchenGroup: String = livingRoom) -> String {
        let kitchen = #"<ZoneGroupMember UUID="\#(Fixtures.kitchen)" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="Kitchen" BootSeq="9"/>"#
        let kitchenAlone = kitchenGroup == Fixtures.kitchen
        return """
            <ZoneGroupState><ZoneGroups>
             <ZoneGroup Coordinator="\(livingRoom)" ID="\(livingRoom):3141">
              <ZoneGroupMember UUID="\(livingRoom)" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Living Room" BootSeq="42" AirPlayEnabled="1"
                 HTSatChanMapSet="\(livingRoom):LF,RF;\(sub):SW;RINCON_000E58112233401400:LR;RINCON_000E58556677801400:RR">
               <Satellite UUID="\(sub)" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Living Room" BootSeq="17" Invisible="1"
                 HTSatChanMapSet="\(livingRoom):LF,RF;\(sub):SW;RINCON_000E58112233401400:LR;RINCON_000E58556677801400:RR"/>
              </ZoneGroupMember>
              \(kitchenAlone ? "" : kitchen)
             </ZoneGroup>
             \(kitchenAlone ? #"<ZoneGroup Coordinator="\#(Fixtures.kitchen)" ID="\#(Fixtures.kitchen):1">\#(kitchen)</ZoneGroup>"# : "")
             <ZoneGroup Coordinator="\(garden)" ID="\(garden):77">
              <ZoneGroupMember UUID="\(garden)" Location="http://192.168.1.13:1400/xml/device_description.xml" ZoneName="Garden" BootSeq="5" MoreInfo="RawBattPct:87,BattPct:85,BattChg:NOT_CHARGING,BattTmp:31"/>
             </ZoneGroup>
            </ZoneGroups>\(vanished ? #"<VanishedDevices><Device UUID="\#(office)" ZoneName="Office" Reason="powered off"/></VanishedDevices>"# : "")</ZoneGroupState>
            """
    }

    static func propertySet(_ properties: [(String, String)]) -> String {
        "<e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">"
            + properties.map { "<e:property><\($0.0)>\(XML.escape($0.1))</\($0.0)></e:property>" }.joined() + "</e:propertyset>"
    }

    static func topologyEvent(_ state: String = zoneGroupState()) -> String {
        propertySet([("ZoneGroupState", state), ("MuseHouseholdId", "\(household).hJ7k")])
    }

    /// §8.6, the body as Sonos sends it.
    static let avTransportEvent = #"<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot; xmlns:r=&quot;urn:schemas-rinconnetworks-com:metadata-1-0/&quot;&gt;&lt;InstanceID val=&quot;0&quot;&gt;&lt;TransportState val=&quot;PLAYING&quot;/&gt;&lt;CurrentPlayMode val=&quot;SHUFFLE_NOREPEAT&quot;/&gt;&lt;CurrentCrossfadeMode val=&quot;0&quot;/&gt;&lt;CurrentTrackURI val=&quot;x-sonosapi-stream:s1234?sid=254&amp;amp;flags=8224&amp;amp;sn=0&quot;/&gt;&lt;CurrentTrackMetaData val=&quot;&amp;lt;DIDL-Lite xmlns:dc=&amp;quot;http://purl.org/dc/elements/1.1/&amp;quot; xmlns:upnp=&amp;quot;urn:schemas-upnp-org:metadata-1-0/upnp/&amp;quot; xmlns:r=&amp;quot;urn:schemas-rinconnetworks-com:metadata-1-0/&amp;quot; xmlns=&amp;quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&amp;quot;&amp;gt;&amp;lt;item id=&amp;quot;-1&amp;quot; parentID=&amp;quot;-1&amp;quot; restricted=&amp;quot;true&amp;quot;&amp;gt;&amp;lt;res protocolInfo=&amp;quot;x-sonosapi-stream:*:*:*&amp;quot;&amp;gt;x-sonosapi-stream:s1234?sid=254&amp;amp;amp;flags=8224&amp;amp;amp;sn=0&amp;lt;/res&amp;gt;&amp;lt;r:streamContent&amp;gt;Artist X - Song Y&amp;lt;/r:streamContent&amp;gt;&amp;lt;dc:title&amp;gt;s1234&amp;lt;/dc:title&amp;gt;&amp;lt;upnp:class&amp;gt;object.item&amp;lt;/upnp:class&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&quot;/&gt;&lt;r:EnqueuedTransportURI val=&quot;x-sonosapi-stream:s1234?sid=254&amp;amp;flags=8224&amp;amp;sn=0&quot;/&gt;&lt;r:EnqueuedTransportURIMetaData val=&quot;&quot;/&gt;&lt;CurrentTransportActions val=&quot;Set, Stop, Pause, Play&quot;/&gt;&lt;r:CurrentValidPlayModes val=&quot;CROSSFADE&quot;/&gt;&lt;r:SleepTimerGeneration val=&quot;0&quot;/&gt;&lt;/InstanceID&gt;&lt;/Event&gt;</LastChange></e:property></e:propertyset>"#

    static func lastChange(_ variables: String) -> String {
        propertySet([("LastChange", #"<Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/"><InstanceID val="0">\#(variables)</InstanceID></Event>"#)])
    }

    /// §8.7.
    static let renderingEvent = lastChange(
        #"<Volume channel="Master" val="30"/><Volume channel="LF" val="100"/><Volume channel="RF" val="80"/><Mute channel="Master" val="0"/>"#
            + #"<Loudness channel="Master" val="1"/><Bass val="2"/><Treble val="-1"/><NightMode val="1"/><DialogLevel val="0"/><SubEnabled val="1"/><SubGain val="3"/>"#)

    static let groupRenderingEvent = #"<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><GroupMute>0</GroupMute></e:property><e:property><GroupVolume>14</GroupVolume></e:property><e:property><GroupVolumeChangeable>1</GroupVolumeChangeable></e:property></e:propertyset>"#

    /// §8.9, unescaped.
    static let alarmList = #"<Alarms><Alarm ID="12" StartTime="07:30:00" Duration="01:00:00" Recurrence="WEEKDAYS" Enabled="1" RoomUUID="\#(kitchen)" ProgramURI="x-rincon-buzzer:0" ProgramMetaData="" PlayMode="SHUFFLE_NOREPEAT" Volume="20" IncludeLinkedZones="0"/></Alarms>"#

    /// §8.10, unescaped.
    static let favourites = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="FV:2/5" parentID="FV:2" restricted="false"><dc:title>Jazz Radio</dc:title><upnp:class>object.itemobject.item.sonos-favorite</upnp:class><res protocolInfo="x-sonosapi-stream:*:*:*">x-sonosapi-stream:s5678?sid=254&amp;flags=8224&amp;sn=0</res><r:description>TuneIn Station</r:description><r:resMD>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"&gt;&lt;item id="F00092020s5678" parentID="L" restricted="true"&gt;&lt;dc:title&gt;Jazz Radio&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.audioBroadcast&lt;/upnp:class&gt;&lt;desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/"&gt;SA_RINCON65031_&lt;/desc&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</r:resMD></item></DIDL-Lite>"#
}

/// The event server, in memory: the plugin's handler, which the fake players call.
final class FakeListener: EventListening, @unchecked Sendable {
    let port = 58004
    let handler: EventHandler
    init(handler: @escaping EventHandler) { self.handler = handler }
    func close() async {}
}

/// A household of zone players behind one fake HTTP transport: device descriptions by IP, SOAP actions recorded and
/// answered, subscriptions answered with an SID and followed by each service's first event, as the players do.
final class FakeSonos: HTTPSending, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        var address: String
        var action: String
        var arguments: [String: String]
    }

    struct SubscribeRequest: Sendable {
        var address: String
        var method: String
        var path: String
        var headers: [String: String]
    }

    private let state = NIOLockedValueBox<(calls: [Call], subscribes: [SubscribeRequest], unreachable: Set<String>, topology: String, sid: Int)>(([], [], [], Fixtures.topologyEvent(), 0))
    let listener = NIOLockedValueBox<FakeListener?>(nil)

    let descriptions: [String: String] = [
        "192.168.1.10": Fixtures.description(id: Fixtures.livingRoom, model: "Sonos Beam", number: "S14", room: "Living Room", tvIn: true),
        "192.168.1.11": Fixtures.description(id: Fixtures.sub, model: "Sonos Sub", number: "S20", room: "Living Room"),
        "192.168.1.12": Fixtures.description(id: Fixtures.kitchen, model: "Sonos One", number: "S18", room: "Kitchen"),
        "192.168.1.13": Fixtures.description(id: Fixtures.garden, model: "Sonos Roam", number: "S27", room: "Garden"),
    ]
    static let addresses = [
        Fixtures.livingRoom: "192.168.1.10", Fixtures.sub: "192.168.1.11", Fixtures.kitchen: "192.168.1.12", Fixtures.garden: "192.168.1.13",
    ]

    var calls: [Call] { state.withLockedValue { $0.calls } }
    var subscribes: [SubscribeRequest] { state.withLockedValue { $0.subscribes } }
    func calls(_ action: String) -> [Call] { calls.filter { $0.action == action } }
    func setUnreachable(_ address: String, _ unreachable: Bool = true) {
        state.withLockedValue { state in
            if unreachable { state.unreachable.insert(address) } else { state.unreachable.remove(address) }
        }
    }
    func setTopology(_ body: String) { state.withLockedValue { $0.topology = body } }

    func makeListener(port: Int, handler: @escaping EventHandler) async throws -> any EventListening {
        let listener = FakeListener(handler: handler)
        self.listener.withLockedValue { $0 = listener }
        return listener
    }

    /// A NOTIFY from the player at its own address (or `from`).
    @discardableResult
    func notify(_ id: String, _ eventPath: String, _ body: String, from address: String? = nil) async -> Int {
        guard let listener = listener.withLockedValue({ $0 }) else { return 0 }
        let request = CallbackRequest(method: "NOTIFY", path: "/notify/\(id)\(eventPath)", remoteAddress: address ?? Self.addresses[id] ?? "", body: Data(body.utf8))
        return await listener.handler(request).status
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let address = request.url.host ?? ""
        if state.withLockedValue({ $0.unreachable.contains(address) }) { throw HTTPClientError.timeout }
        let path = request.url.path
        switch request.method {
        case "GET":
            guard path == "/xml/device_description.xml", let description = descriptions[address] else { return HomeswiftNetwork.HTTPResponse(status: 404) }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(description.utf8))
        case "SUBSCRIBE":
            var headers: [String: String] = [:]
            for header in request.headers { headers[header.name.uppercased()] = header.value }
            let sid = state.withLockedValue { state -> Int in
                state.subscribes.append(SubscribeRequest(address: address, method: "SUBSCRIBE", path: path, headers: headers))
                state.sid += 1
                return state.sid
            }
            guard headers["SID"] == nil else { return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("SID", headers["SID"]!), ("TIMEOUT", headers["TIMEOUT"] ?? "")]) }
            let id = Self.addresses.first { $0.value == address }?.key ?? ""
            let body: String? = switch path {
            case "/ZoneGroupTopology/Event": state.withLockedValue { $0.topology }
            case "/MediaRenderer/AVTransport/Event": Fixtures.avTransportEvent
            case "/MediaRenderer/GroupRenderingControl/Event": Fixtures.groupRenderingEvent
            case "/MediaRenderer/RenderingControl/Event": Fixtures.renderingEvent
            case "/AlarmClock/Event": Fixtures.propertySet([("AlarmListVersion", "RINCON:1")])
            case "/MediaServer/ContentDirectory/Event": Fixtures.propertySet([("FavoritesUpdateID", "RINCON:3")])
            default: nil
            }
            if let body { Task { await self.notify(id, path, body) } }
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("SID", "uuid:\(id)_sub\(sid)"), ("TIMEOUT", headers["TIMEOUT"] ?? "")])
        case "UNSUBSCRIBE":
            state.withLockedValue { $0.subscribes.append(SubscribeRequest(address: address, method: "UNSUBSCRIBE", path: path, headers: [:])) }
            return HomeswiftNetwork.HTTPResponse(status: 200)
        case "POST":
            let soapAction = request.header("SOAPaction") ?? ""
            let action = String(soapAction.split(separator: "#").last ?? "").replacingOccurrences(of: "\"", with: "")
            let root = try XML.parse(String(decoding: request.body ?? Data(), as: UTF8.self))
            var arguments: [String: String] = [:]
            for child in root.first(action)?.children ?? [] { arguments[child.localName] = child.text }
            state.withLockedValue { $0.calls.append(Call(address: address, action: action, arguments: arguments)) }
            let fields: [(String, String)] = switch action {
            case "GetLEDState": [("CurrentLEDState", "On")]
            case "GetButtonLockState": [("CurrentButtonLockState", "Off")]
            case "GetHouseholdID": [("CurrentHouseholdID", Fixtures.household)]
            case "GetRemainingSleepTimerDuration": [("RemainingSleepTimerDuration", "00:29:41")]
            case "GetTransportSettings": [("PlayMode", "SHUFFLE_NOREPEAT")]
            case "SetRelativeGroupVolume": [("NewVolume", "20")]
            case "ListAlarms": [("CurrentAlarmList", Fixtures.alarmList)]
            case "Browse": [("Result", Fixtures.favourites)]
            default: []
            }
            let inner = fields.map { "<\($0.0)>\(XML.escape($0.1))</\($0.0)>" }.joined()
            let service = soapAction.split(separator: "#").first.map { String($0).replacingOccurrences(of: "\"", with: "") } ?? ""
            let body = #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:\#(action)Response xmlns:u="\#(service)">\#(inner)</u:\#(action)Response></s:Body></s:Envelope>"#
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(body.utf8))
        default:
            return HomeswiftNetwork.HTTPResponse(status: 405)
        }
    }
}

/// A host running the plugin against `FakeSonos`, with discovery the test feeds.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Sonos-tests-\(UUID().uuidString)")
    let sonos = FakeSonos()
    let discovery: (stream: AsyncStream<DiscoveryHit>, continuation: AsyncStream<DiscoveryHit>.Continuation) = AsyncStream.makeStream()
    private let plugins = NIOLockedValueBox<[SonosPlugin]>([])

    var plugin: SonosPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = [:], timeScale: Double = 0.001) async throws -> PluginHost {
        var registry = PluginRegistry()
        let sonos = sonos
        let stream = discovery.stream
        registry.register(platform: SonosPlugin.platform, name: SonosPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(SonosPlugin.Configuration.self, from: json)
            var dependencies = SonosPlugin.Dependencies()
            dependencies.http = sonos
            dependencies.listen = { port, handler in try await sonos.makeListener(port: port, handler: handler) }
            dependencies.discover = { _, _ in stream }
            dependencies.localAddress = { _ in "192.168.1.2" }
            dependencies.timeScale = timeScale
            dependencies.discoveryWindow = .milliseconds(100)
            let plugin = SonosPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: SonosPlugin.platform, name: SonosPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// The Living Room's SSDP answer: the plugin probes it and, through its topology, the household.
    func discoverLivingRoom() {
        discovery.continuation.yield(DiscoveryHit(id: Fixtures.livingRoom, address: "192.168.1.10", household: Fixtures.household, bootSeq: 42))
    }
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == id }
    }
}
