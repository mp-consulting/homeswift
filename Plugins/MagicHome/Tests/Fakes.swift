import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftMagicHome

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Devices on a pretend LAN: they answer the discovery probe and `AT+LVER`, take connections on 5577, answer the state
/// query (wrapped when their family wraps), apply the power and level frames they are sent to their state, and record
/// it all. Nothing leaves the process.
final class FakeLAN: Sendable {
    struct Device: Sendable {
        var mac: String
        var module: String
        var state: MagicHomeState
        /// `AT+LVER`'s answer; nil answers nothing.
        var lver: String?
        var wrapsReplies = false
    }

    struct Frame: Sendable, Equatable {
        var host: String
        /// As sent, wrapped or not.
        var bytes: [UInt8]
        /// Inside the wrapper.
        var inner: [UInt8]
        var wrapCounter: UInt8?
    }

    private struct State {
        var devices: [String: Device] = [:]
        var silent: Set<String> = []
        /// Devices that answer on TCP only: the broadcast does not reach them.
        var unreachedByScans: Set<String> = []
        var frames: [Frame] = []
        var probes: [(data: Data, host: String)] = []
        var connections: [String: Int] = [:]
        var streams: [String: [FakeStream]] = [:]
        var socket: AsyncStream<(data: Data, address: String)>.Continuation?
    }

    private let state = NIOLockedValueBox(State())
    /// This machine's own address: the probe it broadcasts comes back from it.
    static let ownAddress = "192.168.1.2"

    func put(_ device: Device, at host: String) { state.withLockedValue { $0.devices[host] = device } }
    func remove(at host: String) { state.withLockedValue { _ = $0.devices.removeValue(forKey: host) } }
    func silence(_ host: String, _ silent: Bool = true) {
        let streams = state.withLockedValue { state -> [FakeStream] in
            if silent { state.silent.insert(host) } else { state.silent.remove(host) }
            return silent ? state.streams[host] ?? [] : []
        }
        for stream in streams { stream.finish() }
    }
    func hideFromScans(_ host: String) { state.withLockedValue { _ = $0.unreachedByScans.insert(host) } }
    func update(at host: String, _ change: (inout MagicHomeState) -> Void) {
        state.withLockedValue { state in
            if var device = state.devices[host] {
                change(&device.state)
                state.devices[host] = device
            }
        }
    }
    func device(at host: String) -> Device? { state.withLockedValue { $0.devices[host] } }

    var frames: [Frame] { state.withLockedValue { $0.frames } }
    /// What was sent to `host` other than state queries.
    func commands(to host: String) -> [[UInt8]] {
        frames.filter { $0.host == host && $0.inner != MagicHomeFrame.stateQuery }.map(\.inner)
    }
    func queries(to host: String) -> Int { frames.filter { $0.host == host && $0.inner == MagicHomeFrame.stateQuery }.count }
    func connections(to host: String) -> Int { state.withLockedValue { $0.connections[host] ?? 0 } }
    var probes: [(data: Data, host: String)] { state.withLockedValue { $0.probes } }

    /// A state pushed by the device at `host` on its open connections.
    func push(from host: String) {
        let (streams, device) = state.withLockedValue { ($0.streams[host] ?? [], $0.devices[host]) }
        guard let device else { return }
        for stream in streams { stream.yield(Self.reply(device)) }
    }

    static func reply(_ device: Device) -> [UInt8] {
        let state = device.state
        let bytes = MagicHomeFrame.sealed([
            0x81, state.model, state.isOn ? 0x23 : 0x24, state.pattern, state.mode, state.speed, state.red, state.green, state.blue, state.warm,
            state.version, state.cool, state.colourMode,
        ])
        return device.wrapsReplies ? MagicHomeWrapper.wrap(bytes, version: 1, counter: 0) : bytes
    }

    // MARK: Discovery

    func socket() -> FakeDiscoverySocket {
        let (stream, continuation) = AsyncStream<(data: Data, address: String)>.makeStream()
        state.withLockedValue { $0.socket = continuation }
        return FakeDiscoverySocket(lan: self, datagrams: stream, continuation: continuation)
    }

    fileprivate func received(_ data: Data, to host: String, from continuation: AsyncStream<(data: Data, address: String)>.Continuation) {
        let answers: [(Data, String)] = state.withLockedValue { state in
            state.probes.append((data, host))
            let hosts = host.hasSuffix(".255") ? Array(state.devices.keys).sorted() : (state.devices[host] != nil ? [host] : [])
            return hosts.filter { !state.silent.contains($0) && !state.unreachedByScans.contains($0) }.compactMap { address in
                let device = state.devices[address]!
                if data == MagicHomeDiscovery.probe { return (Data("\(address),\(device.mac),\(device.module)\r\n".utf8), address) }
                if data == MagicHomeDiscovery.versionQuery, let lver = device.lver { return (Data("+ok=\(lver)\r".utf8), address) }
                return nil
            }
        }
        // The broadcast heard back by the socket that sent it.
        if host.hasSuffix(".255") { continuation.yield((data, Self.ownAddress)) }
        for (reply, address) in answers { continuation.yield((reply, address)) }
    }

    // MARK: TCP

    fileprivate func connect(_ host: String) throws -> FakeStream {
        try state.withLockedValue { state in
            guard state.devices[host] != nil, !state.silent.contains(host) else {
                throw HTTPClientError.cannotConnect(host: host, port: 5577, code: nil, reason: "refused")
            }
            state.connections[host, default: 0] += 1
            let stream = FakeStream(lan: self, host: host)
            state.streams[host, default: []].append(stream)
            return stream
        }
    }

    fileprivate func closed(_ stream: FakeStream) {
        state.withLockedValue { state in state.streams[stream.host]?.removeAll { $0 === stream } }
    }

    /// A frame from the bridge: recorded, applied, answered.
    fileprivate func received(_ bytes: [UInt8], on stream: FakeStream) {
        let host = stream.host
        let inner = MagicHomeWrapper.unwrap(bytes) ?? bytes
        let counter: UInt8? = bytes.first == 0xB0 && bytes.count > 7 ? bytes[7] : nil
        let reply: [UInt8]? = state.withLockedValue { state in
            state.frames.append(Frame(host: host, bytes: bytes, inner: inner, wrapCounter: counter))
            guard !state.silent.contains(host), var device = state.devices[host] else { return nil }
            defer { state.devices[host] = device }
            if inner == MagicHomeFrame.stateQuery { return Self.reply(device) }
            Self.apply(inner, to: &device.state)
            return nil
        }
        if let reply { stream.yield(reply) }
    }

    /// What a real device would show after the frame.
    static func apply(_ frame: [UInt8], to state: inout MagicHomeState) {
        switch (frame.first, frame.count) {
        case (0x71, 4):
            state.isOn = frame[1] == 0x23
        case (0x31, 8):
            state.isOn = true
            (state.red, state.green, state.blue, state.warm) = (frame[1], frame[2], frame[3], frame[4])
        case (0x31, 9):
            state.isOn = true
            (state.red, state.green, state.blue, state.warm, state.cool) = (frame[1], frame[2], frame[3], frame[4], frame[5])
        case (0x35, 9):
            state.isOn = true
            (state.warm, state.cool) = (frame[2], frame[3])
        default:
            break
        }
    }
}

final class FakeDiscoverySocket: MagicHomeDiscoverySocket {
    let lan: FakeLAN
    let datagrams: AsyncStream<(data: Data, address: String)>
    let continuation: AsyncStream<(data: Data, address: String)>.Continuation

    init(lan: FakeLAN, datagrams: AsyncStream<(data: Data, address: String)>, continuation: AsyncStream<(data: Data, address: String)>.Continuation) {
        self.lan = lan
        self.datagrams = datagrams
        self.continuation = continuation
    }

    func send(_ data: Data, to host: String, port: Int) async throws { lan.received(data, to: host, from: continuation) }
    func close() async { continuation.finish() }
}

final class FakeStream: ByteStream, @unchecked Sendable {
    let lan: FakeLAN
    let host: String
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

    init(lan: FakeLAN, host: String) {
        self.lan = lan
        self.host = host
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    func yield(_ bytes: [UInt8]) {
        // Cut in two, as TCP may deliver it.
        let half = bytes.count / 2
        continuation.yield(Array(bytes[..<half]))
        continuation.yield(Array(bytes[half...]))
    }

    func finish() {
        continuation.finish()
        lan.closed(self)
    }

    func send(_ bytes: [UInt8]) async throws { lan.received(bytes, on: self) }
    func close() async { finish() }
}

struct FakeTransport: MagicHomeTransport {
    let lan: FakeLAN
    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream { try lan.connect(host) }
}

/// A host with one platform block whose plugin talks to `lan`, every timing in milliseconds.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-MagicHome-tests-\(UUID().uuidString)")
    let lan = FakeLAN()
    private let plugins = NIOLockedValueBox<[MagicHomePlugin]>([])

    var plugin: MagicHomePlugin? { plugins.withLockedValue { $0.last } }

    static var timing: MagicHomeTiming {
        var timing = MagicHomeTiming()
        // The fakes answer at once or refuse at once: these only bound a wait that no test sits out, so they are the real
        // ones, which a process running thousands of tests on a few cores can take a reply's several hops close to.
        timing.connection = MagicHomeConnection.Timing(connect: .seconds(2), reply: .seconds(2), idle: .milliseconds(150))
        timing.poll = .milliseconds(200)
        timing.pushPoll = .milliseconds(400)
        timing.retry = Backoff(initial: .milliseconds(20), maximum: .milliseconds(80))
        timing.coalesce = .milliseconds(20)
        timing.slider = .milliseconds(15)
        timing.powerToLevels = .milliseconds(10)
        timing.settle = .milliseconds(250)
        timing.identifyStep = .milliseconds(5)
        timing.identifyTicks = 4
        // A scan long enough for a loaded runner to answer in, and a device missed by one tried again soon: with the real
        // five minutes, one late reply would leave it out for the rest of the test.
        timing.scanWindow = .milliseconds(300)
        timing.retryRejected = .milliseconds(400)
        timing.periodicDiscovery = .milliseconds(150)
        timing.addAttempts = 2
        return timing
    }

    func dependencies(timing: MagicHomeTiming = TestEnvironment.timing) -> MagicHomePlugin.Dependencies {
        let lan = lan
        return MagicHomePlugin.Dependencies(
            transport: FakeTransport(lan: lan), bindDiscovery: { lan.socket() },
            networks: { [IPv4Network(address: IPv4Network.parse("192.168.1.2")!, netmask: 0xFFFF_FF00)] },
            ownAddresses: { [FakeLAN.ownAddress] }, timing: timing)
    }

    func start(settings: [String: Any] = [:], timing: MagicHomeTiming = TestEnvironment.timing) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = dependencies(timing: timing)
        registry.register(platform: MagicHomePlugin.platform, name: MagicHomePlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(MagicHomePlugin.Configuration.self, from: json)
            let plugin = MagicHomePlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: MagicHomePlugin.platform, name: "Magic Home", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

extension PluginHost {
    func accessory(_ mac: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == "\(MagicHomePlugin.platform):\(mac)" }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Runs the write handler of `characteristic` for `value`.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    let handler = try #require(characteristic?.writeHandler(for: value))
    try await handler(value)
}

/// Bytes from hex, spaces allowed: `"81 8A 8B 96"`.
func bytes(_ hex: String) -> [UInt8] {
    let digits = hex.filter { !$0.isWhitespace }
    var result: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        result.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return result
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// Demonstration devices (the spec's invented ones).
enum Fixtures {
    static let stripMAC = "ACCF23A1B2C3"
    static let bulbMAC = "6001940EDC1F"
    static let socketMAC = "600194AABBCC"
    static let cctMAC = "B4E842010203"
    static let tableMAC = "B4E842040506"

    static func state(_ hex: String) -> MagicHomeState { MagicHomeState(standard: bytes(hex))! }

    /// 0x25, version 5, mode 07 (RGB/CCT), on, red.
    static var strip: FakeLAN.Device {
        FakeLAN.Device(mac: stripMAC, module: "AK001-ZJ2145", state: MagicHomeState(model: 0x25, isOn: true, mode: 0x07, red: 255, version: 5, colourMode: 0xF0))
    }
    /// 0x35 bulb, version 8 (RGBWW Non-Simultaneous): white, warm 192, cool 64.
    static var bulb: FakeLAN.Device { FakeLAN.Device(mac: bulbMAC, module: "HF-LPB100-ZJ200", state: state("81 35 23 61 01 10 00 00 00 C0 08 40 0F 62")) }
    static var socket: FakeLAN.Device { FakeLAN.Device(mac: socketMAC, module: "AK001-ZJ2104", state: state("81 97 23 61 41 10 00 00 00 00 01 00 00 EE")) }
    /// 0x09, version 5: 30 %, 80 %.
    static var cct: FakeLAN.Device { FakeLAN.Device(mac: cctMAC, module: "AK001-ZJ2147", state: state("81 09 23 61 00 10 00 00 00 1E 05 50 0F A0"), lver: "09_05_20220103_ZG-BL") }
    /// 0x1C table light: wrapped queries and pushes.
    static var table: FakeLAN.Device {
        FakeLAN.Device(mac: tableMAC, module: "ZG-BL", state: MagicHomeState(model: 0x1C, isOn: true, warm: 50, version: 2, cool: 100, colourMode: 0x0F), wrapsReplies: true)
    }
}
