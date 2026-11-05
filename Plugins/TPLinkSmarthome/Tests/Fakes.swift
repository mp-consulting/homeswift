import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftTPLinkSmarthome

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Devices on a pretend LAN: they answer the discovery broadcast with their sysinfo and the commands with canned
/// replies, and record what they were sent. Nothing leaves the process.
final class FakeLAN: Sendable {
    struct Sent: Sendable, Equatable {
        var json: String
        var host: String
        var port: Int
    }

    private struct State {
        var sysinfo: [String: String] = [:]
        var silent: Set<String> = []
        var replies: [String: String] = [:]
        var commands: [Sent] = []
        var packets: [Sent] = []
        var continuation: AsyncStream<UDPSocket.Datagram>.Continuation?
    }

    private let state = NIOLockedValueBox(State())

    /// A device at `host`: its `get_sysinfo` object, as JSON.
    func put(_ sysinfo: String, at host: String) { state.withLockedValue { $0.sysinfo[host] = sysinfo } }
    func remove(at host: String) { state.withLockedValue { _ = $0.sysinfo.removeValue(forKey: host) } }
    func silence(_ host: String, _ silent: Bool = true) {
        state.withLockedValue { if silent { $0.silent.insert(host) } else { $0.silent.remove(host) } }
    }
    /// The inner reply of `module.method` (with its `err_code`).
    func reply(_ key: String, _ json: String) { state.withLockedValue { $0.replies[key] = json } }

    var commands: [Sent] { state.withLockedValue { $0.commands } }
    var packets: [Sent] { state.withLockedValue { $0.packets } }
    func commands(_ method: String) -> [Sent] { commands.filter { $0.json.contains("\"\(method)\"") } }

    /// A datagram as from a device.
    func deliver(_ text: String, from host: String, port: Int = 9999) {
        let continuation = state.withLockedValue { $0.continuation }
        continuation?.yield(UDPSocket.Datagram(data: Data(KasaCipher.encrypt(text)), address: host, port: port))
    }

    func socket() -> FakeSocket {
        let (stream, continuation) = AsyncStream<UDPSocket.Datagram>.makeStream()
        state.withLockedValue { $0.continuation = continuation }
        return FakeSocket(lan: self, datagrams: stream)
    }

    fileprivate func received(_ data: Data, host: String, port: Int) {
        let text = String(decoding: KasaCipher.decrypt(data), as: UTF8.self)
        // A broadcast is answered from 9999; a packet to a host from the port it went to (a port forward).
        let from = host.hasSuffix(".255") ? 9999 : port
        let answers: [(String, String)] = state.withLockedValue { state in
            state.packets.append(Sent(json: text, host: host, port: port))
            let hosts = host.hasSuffix(".255") ? state.sysinfo.keys.filter { Self.broadcast(host, reaches: $0) } : (state.sysinfo[host] != nil ? [host] : [])
            return hosts.filter { !state.silent.contains($0) }.map { ($0, #"{"system":{"get_sysinfo":\#(state.sysinfo[$0]!)}}"#) }
        }
        for (address, reply) in answers { deliver(reply, from: address, port: from) }
    }

    /// 255.255.255.255 reaches the whole pretend LAN, a subnet's broadcast (`10.0.0.255`) the hosts of its /24: not
    /// a device behind a port forward, whose replies would otherwise come from 9999 as well as from its own port.
    private static func broadcast(_ broadcast: String, reaches host: String) -> Bool {
        broadcast == "255.255.255.255" || host.split(separator: ".").dropLast() == broadcast.split(separator: ".").dropLast()
    }

    fileprivate func command(_ json: String, host: String, port: Int) throws -> String {
        try state.withLockedValue { state in
            state.commands.append(Sent(json: json, host: host, port: port))
            if state.silent.contains(host) { throw KasaConnectionClosed() }
            let request = try JSONValue(string: json)
            guard let (module, methods) = request.objectValue?.first(where: { $0.key != "context" }), let method = methods.objectValue?.keys.first else {
                throw KasaConnectionClosed()
            }
            // A device shows what it was set to on the next round, as a real one does: without it, a round that
            // lands between a write and the test's look at the value would put back the state from before it.
            if var sysinfo = state.sysinfo[host], let arguments = methods.objectValue?[method]?.objectValue {
                let childIDs = request.objectValue?["context"]?.objectValue?["child_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if method == "set_relay_state", let on = arguments["state"]?.intValue {
                    if childIDs.isEmpty {
                        sysinfo = sysinfo.replacingOccurrences(of: #""relay_state":\#(1 - on)"#, with: #""relay_state":\#(on)"#)
                    }
                    // A strip of short ids (an older firmware) lists its outlets by their last two digits.
                    for id in childIDs.flatMap({ [$0, String($0.suffix(2))] }) {
                        sysinfo = sysinfo.replacingOccurrences(of: #"{"id":"\#(id)","state":\#(1 - on)"#, with: #"{"id":"\#(id)","state":\#(on)"#)
                    }
                } else if method.hasSuffix("light_state"), let on = arguments["on_off"]?.intValue {
                    sysinfo = sysinfo.replacingOccurrences(of: #""light_state":{"on_off":\#(1 - on)"#, with: #""light_state":{"on_off":\#(on)"#)
                }
                state.sysinfo[host] = sysinfo
            }
            let inner = module == "system" && method == "get_sysinfo"
                ? state.sysinfo[host] ?? #"{"err_code":0}"#
                : state.replies["\(module).\(method)"] ?? #"{"err_code":0}"#
            return #"{"\#(module)":{"\#(method)":\#(inner)}}"#
        }
    }
}

final class FakeSocket: KasaDiscoverySocket {
    let lan: FakeLAN
    let datagramsWithPorts: AsyncStream<UDPSocket.Datagram>

    init(lan: FakeLAN, datagrams: AsyncStream<UDPSocket.Datagram>) {
        self.lan = lan
        self.datagramsWithPorts = datagrams
    }

    func send(_ data: Data, to host: String, port: Int) async throws { lan.received(data, host: host, port: port) }
    func close() async {}
}

struct FakeTransport: KasaTransport {
    let lan: FakeLAN
    func send(_ json: String, host: String, port: Int, udp: Bool, timeout: Duration?) async throws -> String {
        try lan.command(json, host: host, port: port)
    }
}

/// A host with one platform block whose plugin talks to `lan`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-TPLinkSmarthome-tests-\(UUID().uuidString)")
    let lan = FakeLAN()
    private let plugins = NIOLockedValueBox<[TPLinkSmarthomePlugin]>([])

    var plugin: TPLinkSmarthomePlugin? { plugins.withLockedValue { $0.last } }

    /// A second lasts 20 ms: the default 10-second round is 200 ms.
    func start(settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let lan = lan
        registry.register(platform: TPLinkSmarthomePlugin.platform, name: TPLinkSmarthomePlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(TPLinkSmarthomePlugin.Configuration.self, from: json)
            let dependencies = TPLinkSmarthomePlugin.Dependencies(
                transport: FakeTransport(lan: lan), bindDiscovery: { _ in lan.socket() }, second: .milliseconds(20), identifyStep: .milliseconds(10),
                discoveryWindow: .milliseconds(100))
            let plugin = TPLinkSmarthomePlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: TPLinkSmarthomePlugin.platform, name: "TplinkSmarthome", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

extension PluginHost {
    func accessory(_ deviceID: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == "TplinkSmarthome:\(deviceID)" }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Sysinfo of the spec's examples (section 9.3), demonstration values.
enum Fixtures {
    static let hs110 = #"{"sw_ver":"1.0.8 Build 151113 Rel.24658","hw_ver":"1.0","type":"IOT.SMARTPLUGSWITCH","model":"HS110(US)","mac":"50:C7:BF:01:02:03","deviceId":"8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A","alias":"Kitchen Kettle","relay_state":1,"feature":"TIM:ENE","led_off":0,"latitude":0,"longitude":0,"err_code":0}"#
    static let hs200 = #"{"sw_ver":"1.1.0 Build 160521 Rel.085826","hw_ver":"1.0","type":"IOT.SMARTPLUGSWITCH","model":"HS200(US)","mac":"50:C7:BF:04:05:06","deviceId":"8006AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","alias":"Porch","relay_state":0,"feature":"TIM","led_off":0,"err_code":0}"#
    static let hs220 = #"{"sw_ver":"1.5.7 Build 180912 Rel.104837","hw_ver":"1.0","mic_type":"IOT.SMARTPLUGSWITCH","model":"HS220(US)","mac":"50:C7:BF:0A:0B:0C","deviceId":"80069A1B2C3D4E5F60718293A4B5C6D7E8F90A1B","alias":"Hall Dimmer","relay_state":0,"brightness":50,"feature":"TIM","led_off":0,"err_code":0}"#
    static func hs300(shortIDs: Bool = false, firstOn: Int = 1) -> String {
        let device = "8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C"
        let names = ["Monitor", "Lamp", "Speakers", "Charger", "Printer", "Router"]
        let children = names.enumerated().map { index, name in
            let id = (shortIDs ? "" : device) + String(format: "%02d", index)
            return #"{"id":"\#(id)","state":\#(index == 0 ? firstOn : 0),"alias":"\#(name)"}"#
        }.joined(separator: ",")
        return #"{"sw_ver":"1.0.6 Build 180627 Rel.081000","hw_ver":"1.0","model":"HS300(US)","mic_type":"IOT.SMARTPLUGSWITCH","mac":"B0:BE:76:11:22:33","deviceId":"\#(device)","alias":"Desk Strip","feature":"TIM:ENE","led_off":0,"children":[\#(children)],"err_code":0}"#
    }
    static func lb130(light: String = #"{"on_off":1,"mode":"normal","hue":120,"saturation":80,"color_temp":0,"brightness":60}"#) -> String {
        #"{"sw_ver":"1.6.0 Build 170703 Rel.141938","hw_ver":"1.0","model":"LB130(US)","description":"Smart Wi-Fi LED Bulb with Color Changing","alias":"Reading Lamp","mic_type":"IOT.SMARTBULB","mic_mac":"50C7BF445566","deviceId":"8012A1B2C3D4E5F60718293A4B5C6D7E8F901234","light_state":\#(light),"is_dimmable":1,"is_color":1,"is_variable_color_temp":1,"err_code":0}"#
    }
    static let lb120Off = #"{"sw_ver":"1.6.0 Build 170703 Rel.141938","hw_ver":"1.0","model":"LB120(US)","description":"Smart Wi-Fi LED Bulb with Tunable White Light","alias":"Hall Bulb","mic_type":"IOT.SMARTBULB","mic_mac":"50C7BF778899","deviceId":"8012BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","light_state":{"on_off":0,"dft_on_state":{"mode":"normal","hue":0,"saturation":0,"color_temp":2700,"brightness":100}},"is_dimmable":1,"is_color":0,"is_variable_color_temp":1,"err_code":0}"#
    static let kl430Off = #"{"sw_ver":"1.0.9 Build 200305 Rel.090639","hw_ver":"1.0","mic_type":"IOT.SMARTBULB","model":"KL430(US)","deviceId":"801222BAA511374991036875D0A280AD1D35A16F","alias":"TV Backlight","description":"Kasa Smart Light Strip, Multicolor","mic_mac":"1C3BF3778899","length":16,"is_dimmable":1,"is_color":1,"is_variable_color_temp":1,"light_state":{"on_off":0,"dft_on_state":{"mode":"normal","hue":0,"saturation":0,"color_temp":9000,"brightness":100}},"err_code":0}"#

    static let hs110ID = "8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A"
    static let hs200ID = "8006AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let hs220ID = "80069A1B2C3D4E5F60718293A4B5C6D7E8F90A1B"
    static let hs300ID = "8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C"
    static let lb130ID = "8012A1B2C3D4E5F60718293A4B5C6D7E8F901234"
    static let lb120ID = "8012BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    static let kl430ID = "801222BAA511374991036875D0A280AD1D35A16F"
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
