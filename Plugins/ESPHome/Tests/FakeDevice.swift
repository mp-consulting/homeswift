import Foundation
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

@testable import HomeswiftESPHome

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

enum FakeError: Error { case unreachable }

/// A message as the tests write them: a type and its fields.
func frame(_ type: Int, _ build: (inout ProtobufWriter) -> Void = { _ in }) -> ESPHomeFrame {
    var writer = ProtobufWriter()
    build(&writer)
    return ESPHomeFrame(type: type, body: writer.bytes)
}

/// An ESPHome device in memory, speaking the native API as firmware does: plaintext, or Noise with its key; Hello,
/// the legacy password, DeviceInfo, the entity list, states once subscribed, pings, and commands it records.
final class FakeDevice: @unchecked Sendable {
    struct Configuration {
        var name = "kitchen"
        var mac = "AC:BC:32:89:0E:A9"
        var friendlyName = "Kitchen"
        /// base64 of 32 bytes: the device encrypts.
        var encryptionKey: String?
        /// The legacy API password: the device says it uses one, and refuses another.
        var password: String?
        var entities: [ESPHomeFrame] = []
        var states: [ESPHomeFrame] = []
    }

    private let lock = NIOLock()
    private var configuration: Configuration
    private var connection: FakeConnection?
    private var _commands: [ESPHomeFrame] = []
    private var _connections = 0
    var reachable = true
    /// Answers a switch command with the state it asked for, as firmware does.
    var echoesSwitches = true

    init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    var commands: [ESPHomeFrame] { lock.withLock { _commands } }
    /// The body of the last command.
    var lastMessage: ProtobufMessage? { commands.last.flatMap { ProtobufMessage($0.body) } }
    var connections: Int { lock.withLock { _connections } }
    var isConnected: Bool { lock.withLock { connection != nil } }
    var config: Configuration {
        get { lock.withLock { configuration } }
        set { lock.withLock { configuration = newValue } }
    }

    func connect() throws -> FakeConnection {
        guard reachable else { throw FakeError.unreachable }
        let connection = FakeConnection(device: self, configuration: config)
        lock.withLock {
            self.connection = connection
            _connections += 1
        }
        return connection
    }

    private var _pings = 0
    /// The PingRequests answered.
    var pings: Int { lock.withLock { _pings } }
    func pinged() { lock.withLock { _pings += 1 } }

    private var _authentications = 0
    /// The AuthenticationRequests received: each carried the password.
    var authentications: Int { lock.withLock { _authentications } }
    func authenticated() { lock.withLock { _authentications += 1 } }

    func record(_ command: ESPHomeFrame) {
        lock.withLock { _commands.append(command) }
    }

    func closed(_ closed: FakeConnection) {
        lock.withLock { if connection === closed { connection = nil } }
    }

    /// A state change made on the device.
    func push(_ state: ESPHomeFrame) {
        lock.withLock { connection }?.deliver(state)
    }

    /// The Wi-Fi drops.
    func drop() {
        lock.withLock { connection }?.shut()
    }
}

/// One connection to a fake device: the device's side of the byte stream.
final class FakeConnection: ByteStream, @unchecked Sendable {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let lock = NIOLock()
    private weak var device: FakeDevice?
    private let configuration: FakeDevice.Configuration
    private var plain = PlaintextFramer()
    private var noise = NoiseFramer()
    private var responder: NoiseHandshake?
    private var send: NoiseCipherState?
    private var receive: NoiseCipherState?
    private var sawHello = false
    private var subscribed = false
    private var closed = false

    init(device: FakeDevice, configuration: FakeDevice.Configuration) {
        self.device = device
        self.configuration = configuration
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
        if let key = configuration.encryptionKey {
            responder = try? NoiseHandshake(role: .responder, prologue: ESPHomeNoise.prologue, psk: ESPHomeNoise.psk(fromBase64: key))
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        lock.withLock { receiveBytes(bytes) }
    }

    func close() async { shut() }

    func shut() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        continuation.finish()
        device?.closed(self)
    }

    /// What the device sends of its own accord.
    func deliver(_ frame: ESPHomeFrame) {
        lock.withLock { write(frame) }
    }

    private func write(_ frame: ESPHomeFrame) {
        guard !closed else { return }
        if var cipher = send {
            guard let sealed = try? cipher.encrypt(ESPHomeNoise.plaintext(frame)) else { return }
            send = cipher
            continuation.yield(NoiseFramer.encode(sealed))
        } else {
            continuation.yield(PlaintextFramer.encode(frame))
        }
    }

    private func fail() {
        closed = true
        continuation.finish()
        let device = device
        let me = self
        Task { device?.closed(me) }
    }

    // Called with the lock held.
    private func receiveBytes(_ bytes: [UInt8]) {
        guard !closed else { return }
        if configuration.encryptionKey == nil {
            // A plaintext device resets a client that speaks Noise.
            if bytes.first == 0x01 { return fail() }
            plain.append(bytes)
            while let frame = try? plain.next() { handle(frame) }
            return
        }
        if bytes.first == 0x00, !sawHello {
            // An encrypted device answers a plaintext client with a Noise frame.
            continuation.yield([0x01, 0x00, 0x00])
            return
        }
        noise.append(bytes)
        while let payload = try? noise.next() {
            if !sawHello {
                sawHello = true
                continue
            }
            if var handshake = responder {
                responder = nil
                var hello: [UInt8] = [0x01] + Array(configuration.name.utf8) + [0]
                hello += Array(configuration.mac.replacingOccurrences(of: ":", with: "").lowercased().utf8) + [0]
                continuation.yield(NoiseFramer.encode(hello))
                do {
                    _ = try handshake.readMessage(Array(payload.dropFirst()))
                    let answer = try handshake.writeMessage()
                    continuation.yield(NoiseFramer.encode([0x00] + answer))
                    let (sending, receiving) = try handshake.split()
                    send = sending
                    receive = receiving
                } catch {
                    continuation.yield(NoiseFramer.encode([0x01] + Array(ESPHomeNoise.handshakeMACFailure.utf8)))
                    fail()
                    return
                }
                continue
            }
            guard var cipher = receive, let plaintext = try? cipher.decrypt(payload), let frame = try? ESPHomeNoise.frame(plaintext) else { return fail() }
            receive = cipher
            handle(frame)
        }
    }

    private func handle(_ request: ESPHomeFrame) {
        let message = ProtobufMessage(request.body)
        switch request.type {
        case MessageType.helloRequest:
            write(frame(MessageType.helloResponse) {
                $0.uint32(1, 1)
                $0.uint32(2, 10)
                $0.string(3, "2025.1.0")
                $0.string(4, configuration.name)
            })
        case MessageType.authenticationRequest:
            device?.authenticated()
            if let password = configuration.password, message?.string(1) != password {
                write(frame(MessageType.authenticationResponse) { $0.bool(1, true) })
            }
        case MessageType.deviceInfoRequest:
            write(frame(MessageType.deviceInfoResponse) {
                $0.bool(1, configuration.password != nil)
                $0.string(2, configuration.name)
                $0.string(3, configuration.mac)
                $0.string(4, "2025.1.0")
                $0.string(6, "esp32dev")
                $0.string(13, configuration.friendlyName)
            })
        case MessageType.listEntitiesRequest:
            for entity in configuration.entities { write(entity) }
            write(ESPHomeFrame(type: MessageType.listEntitiesDone, body: []))
        case MessageType.subscribeStates:
            subscribed = true
            for state in configuration.states { write(state) }
        case MessageType.pingRequest:
            device?.pinged()
            write(ESPHomeFrame(type: MessageType.pingResponse, body: []))
        case MessageType.disconnectRequest:
            write(ESPHomeFrame(type: MessageType.disconnectResponse, body: []))
            fail()
        case MessageType.pingResponse, MessageType.disconnectResponse, MessageType.getTimeResponse:
            break
        default:
            device?.record(request)
            if request.type == MessageType.switchCommand, device?.echoesSwitches == true, let message {
                write(frame(26) {
                    $0.fixed32(1, message.fixed32(1))
                    $0.bool(2, message.bool(2))
                })
            }
        }
    }
}

/// Connects to the fake device at each host.
final class FakeTransport: ESPHomeTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private var devices: [String: FakeDevice] = [:]

    func add(_ device: FakeDevice, at host: String) {
        lock.withLock { devices[host] = device }
    }

    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream {
        guard let device = lock.withLock({ devices[host] }) else { throw FakeError.unreachable }
        return try device.connect()
    }
}

// MARK: Entities as firmware lists them

func switchEntity(_ name: String, key: UInt32, objectID: String? = nil) -> ESPHomeFrame {
    frame(17) {
        $0.string(1, objectID ?? name.lowercased().replacingOccurrences(of: " ", with: "_"))
        $0.fixed32(2, key)
        $0.string(3, name)
    }
}

func switchState(key: UInt32, on: Bool) -> ESPHomeFrame {
    frame(26) {
        $0.fixed32(1, key)
        $0.bool(2, on)
    }
}

func sensorEntity(_ name: String, key: UInt32, unit: String, deviceClass: String = "", icon: String = "") -> ESPHomeFrame {
    frame(16) {
        $0.string(1, name.lowercased())
        $0.fixed32(2, key)
        $0.string(3, name)
        $0.string(5, icon)
        $0.string(6, unit)
        $0.string(9, deviceClass)
    }
}

func sensorState(key: UInt32, _ value: Float, missing: Bool = false) -> ESPHomeFrame {
    frame(25) {
        $0.fixed32(1, key)
        $0.float(2, value)
        $0.bool(3, missing)
    }
}

func binarySensorEntity(_ name: String, key: UInt32, deviceClass: String) -> ESPHomeFrame {
    frame(12) {
        $0.string(1, name.lowercased())
        $0.fixed32(2, key)
        $0.string(3, name)
        $0.string(5, deviceClass)
    }
}

func binarySensorState(key: UInt32, _ on: Bool) -> ESPHomeFrame {
    frame(21) {
        $0.fixed32(1, key)
        $0.bool(2, on)
    }
}

func lightEntity(_ name: String, key: UInt32, modes: [Int], effects: [String] = [], minMireds: Float = 153, maxMireds: Float = 500) -> ESPHomeFrame {
    frame(15) {
        $0.string(1, name.lowercased())
        $0.fixed32(2, key)
        $0.string(3, name)
        $0.float(9, minMireds)
        $0.float(10, maxMireds)
        for effect in effects { $0.string(11, effect) }
        var packed: [UInt8] = []
        for mode in modes { packed += Protobuf.varint(UInt64(mode)) }
        if !packed.isEmpty { $0.bytes(12, packed) }
    }
}
