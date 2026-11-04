import Foundation
import HomeswiftNetwork
import Logging

/// Opens connections to devices; tests give one that answers in memory.
protocol ESPHomeTransport: Sendable {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream
}

struct TCPTransport: ESPHomeTransport {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream {
        try await TCPStream.connect(host: host, port: port, timeout: timeout)
    }
}

/// The delays of a connection, from the reference client's: tests scale them down.
struct ESPHomeTiming: Sendable {
    var connectTimeout: Duration = .seconds(60)
    /// The Noise handshake: slow ESP8266 boards take about 30 seconds.
    var handshakeTimeout: Duration = .seconds(60)
    /// Each answer of the session's opening (HelloResponse, DeviceInfoResponse, the entity list).
    var responseTimeout: Duration = .seconds(30)
    /// A PingRequest this often.
    var keepalive: Duration = .seconds(20)
    /// Nothing at all received for this long closes the connection.
    var liveness: Duration = .seconds(90)
    /// How often the session checks its timers: coarse, as the shortest is the 20 s keepalive.
    var tick: Duration = .seconds(5)
    /// The wait before reconnecting to a device that said it disconnects (it is rebooting).
    var rebootDelay: Duration = .seconds(5)
    var retryInitial: Duration = .seconds(1)
    /// The longest wait between attempts; `retryAfter` lowers it.
    var retryMaximum: Duration = .seconds(60)
    /// A button's switch turns back off after this.
    var buttonReset: Duration = .seconds(1)
    /// Quick writes to one light within this become one command (a slider's drag).
    var lightCoalescing: Duration = .milliseconds(100)

    func scaled(by factor: Double) -> ESPHomeTiming {
        var timing = self
        for path in [\ESPHomeTiming.connectTimeout, \.handshakeTimeout, \.responseTimeout, \.keepalive, \.liveness, \.tick, \.rebootDelay, \.retryInitial,
                     \.retryMaximum, \.buttonReset, \.lightCoalescing] {
            timing[keyPath: path] = timing[keyPath: path] * factor
        }
        return timing
    }
}

/// Where a device answers and how it is opened.
struct ESPHomeEndpoint: Sendable, Equatable {
    var host: String
    var port: Int = ESPHomeEndpoint.defaultPort
    /// base64 of 32 bytes: the connection is encrypted (Noise) when set, plaintext otherwise.
    var encryptionKey: String?
    /// The legacy API password, for firmware before 2026.1.
    var password: String?
    /// The canonical MAC the device was set up with: another answering is refused (encrypted connections).
    var expectedMAC: String?

    static let defaultPort = 6053
}

/// The sending half of a connection: frames go out one after the other, in the order sent (the Noise counter depends
/// on it), encrypted once the handshake is done.
actor ESPHomeLink {
    private let stream: any ByteStream
    private var cipher: NoiseCipherState?
    private var tail: Task<Void, any Error>?
    private var isClosed = false

    init(stream: any ByteStream) {
        self.stream = stream
    }

    func encrypt(with cipher: NoiseCipherState) {
        self.cipher = cipher
    }

    func send(_ frame: ESPHomeFrame) async throws {
        let bytes: [UInt8]
        if var cipher {
            bytes = NoiseFramer.encode(try cipher.encrypt(ESPHomeNoise.plaintext(frame)))
            self.cipher = cipher
        } else {
            bytes = PlaintextFramer.encode(frame)
        }
        try await sendRaw(bytes)
    }

    func sendRaw(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw ESPHomeError.connectionLost }
        let previous = tail
        let stream = stream
        let task = Task {
            _ = await previous?.result
            try await stream.send(bytes)
        }
        tail = task
        try await task.value
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await stream.close()
    }
}

/// One connection's life: connect, the Noise handshake when there is a key, Hello (and the legacy password), the device's
/// information, its entities, then the subscription to their states until the connection ends. Answers the device's
/// PingRequest, DisconnectRequest and GetTimeRequest, pings it every `keepalive` and gives up after `liveness` of silence.
enum ESPHomeSession {
    struct Ready: Sendable {
        let link: ESPHomeLink
        let info: DeviceInfo
        let entities: [EntityInfo]
        /// The names of entities of types the plugin does not map.
        let unsupported: [String]
    }

    private enum Input {
        case bytes([UInt8])
        case closed
        case tick
    }

    private enum Phase: String {
        case handshake = "encryption handshake"
        case hello = "hello"
        case deviceInfo = "device information"
        case listing = "entity list"
        case running
    }

    /// Runs until the connection ends; throws why (`ESPHomeError`, a connection error, or `CancellationError`).
    static func run(
        endpoint: ESPHomeEndpoint, transport: any ESPHomeTransport, timing: ESPHomeTiming, logger: Logger,
        onReady: @Sendable (Ready) async -> Void, onState: @Sendable (EntityKind, ProtobufMessage) async -> Void
    ) async throws {
        let psk = try endpoint.encryptionKey.map(ESPHomeNoise.psk(fromBase64:))
        let stream = try await transport.connect(host: endpoint.host, port: endpoint.port, timeout: timing.connectTimeout)
        let link = ESPHomeLink(stream: stream)
        let (inbox, input) = AsyncStream.makeStream(of: Input.self)
        let pump = Task {
            do {
                for try await chunk in stream.incoming { input.yield(.bytes(chunk)) }
            } catch {}
            input.yield(.closed)
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: timing.tick)
                input.yield(.tick)
            }
        }
        defer {
            pump.cancel()
            ticker.cancel()
            input.finish()
        }

        let clock = ContinuousClock()
        var phase = Phase.hello
        var deadline = clock.now + timing.responseTimeout
        var lastReceived = clock.now
        var lastPing = clock.now
        var handshake: NoiseHandshake?
        var serverHello: ESPHomeNoise.ServerHello?
        var receive: NoiseCipherState?
        var noiseFramer = NoiseFramer()
        var plainFramer = PlaintextFramer()
        var info: DeviceInfo?
        var entities: [EntityInfo] = []
        var unsupported: [String] = []

        /// The password goes in the clear, so only once DeviceInfo (which firmware answers before it) showed the device's
        /// MAC: the expected one when it is known, so an impostor at its address (a spoofed mDNS answer, a reused IP) never
        /// gets it. Not waited for: firmware since 2026.1 ignores it and never answers.
        let password = endpoint.password.flatMap { $0.isEmpty ? nil : $0 }

        func sendHello() async throws {
            try await link.send(ESPHomeRequest.hello())
        }

        func handle(_ frame: ESPHomeFrame) async throws {
            lastReceived = clock.now
            switch frame.type {
            case MessageType.pingRequest:
                try await link.send(ESPHomeRequest.empty(MessageType.pingResponse))
                return
            case MessageType.disconnectRequest:
                try? await link.send(ESPHomeRequest.empty(MessageType.disconnectResponse))
                throw ESPHomeError.disconnectedByDevice
            case MessageType.getTimeRequest:
                try await link.send(ESPHomeRequest.time(Date()))
                return
            case MessageType.authenticationResponse:
                if ProtobufMessage(frame.body)?.bool(1) == true { throw ESPHomeError.invalidPassword }
                return
            default:
                break
            }
            guard let message = ProtobufMessage(frame.body) else {
                logger.debug("Ignoring a malformed message of type \(frame.type)")
                return
            }
            switch (phase, frame.type) {
            case (.hello, MessageType.helloResponse):
                let major = message.uint32(1)
                guard major <= 2 else { throw ESPHomeError.incompatibleAPI(major: major) }
                phase = .deviceInfo
                deadline = clock.now + timing.responseTimeout
                try await link.send(ESPHomeRequest.empty(MessageType.deviceInfoRequest))
            case (.deviceInfo, MessageType.deviceInfoResponse):
                let received = DeviceInfo(message)
                if let expected = endpoint.expectedMAC, let found = MACAddress.canonical(received.mac), found != expected {
                    throw ESPHomeError.wrongDevice(expected: expected, found: found)
                }
                if received.usesPassword, password == nil { throw ESPHomeError.passwordRequired }
                if let password {
                    if let expected = endpoint.expectedMAC, MACAddress.canonical(received.mac) != expected {
                        logger.warning("Not sending the password to \(endpoint.host): it did not show the MAC \(expected)")
                        throw ESPHomeError.wrongDevice(expected: expected, found: "none")
                    }
                    try await link.send(ESPHomeRequest.authentication(password: password))
                }
                info = received
                phase = .listing
                deadline = clock.now + timing.responseTimeout
                try await link.send(ESPHomeRequest.empty(MessageType.listEntitiesRequest))
            case (.listing, MessageType.listEntitiesDone):
                guard let info else { return }
                phase = .running
                lastPing = clock.now
                await onReady(Ready(link: link, info: info, entities: entities, unsupported: unsupported))
                try await link.send(ESPHomeRequest.empty(MessageType.subscribeStates))
            case (.listing, let type):
                if let kind = EntityKind(listType: type) {
                    entities.append(EntityInfo(kind: kind, message: message))
                } else if unsupportedListTypes.contains(type) {
                    unsupported.append(Sanitized.text(message.string(3)))
                }
            case (.running, let type):
                if let kind = EntityKind(stateType: type) { await onState(kind, message) }
            default:
                break
            }
        }

        func receiveNoise(_ payload: [UInt8]) async throws {
            if var current = handshake {
                lastReceived = clock.now
                if serverHello == nil {
                    let hello = try ESPHomeNoise.ServerHello(payload)
                    if let expected = endpoint.expectedMAC, let mac = hello.mac.flatMap(MACAddress.canonical), mac != expected {
                        throw ESPHomeError.wrongDevice(expected: expected, found: mac)
                    }
                    serverHello = hello
                    return
                }
                let answer = try ESPHomeNoise.handshakeResult(payload)
                do {
                    _ = try current.readMessage(answer)
                } catch NoiseError.decryptionFailed {
                    throw ESPHomeError.invalidEncryptionKey
                } catch {
                    throw ESPHomeError.handshakeFailed("malformed answer")
                }
                let (send, received) = try current.split()
                handshake = nil
                receive = received
                await link.encrypt(with: send)
                phase = .hello
                deadline = clock.now + timing.responseTimeout
                try await sendHello()
                return
            }
            guard var cipher = receive else { return }
            let plaintext: [UInt8]
            do {
                plaintext = try cipher.decrypt(payload)
            } catch {
                throw ESPHomeError.encryptionError
            }
            receive = cipher
            try await handle(try ESPHomeNoise.frame(plaintext))
        }

        do {
            if let psk {
                var opening = try NoiseHandshake(role: .initiator, prologue: ESPHomeNoise.prologue, psk: psk)
                let first = try opening.writeMessage()
                handshake = opening
                phase = .handshake
                deadline = clock.now + timing.handshakeTimeout
                try await link.sendRaw(NoiseFramer.encode([]) + NoiseFramer.encode([0x00] + first))
            } else {
                try await sendHello()
            }

            for await event in inbox {
                switch event {
                case .bytes(let chunk):
                    if psk != nil {
                        noiseFramer.append(chunk)
                        while let payload = try noiseFramer.next() { try await receiveNoise(payload) }
                    } else {
                        plainFramer.append(chunk)
                        while let frame = try plainFramer.next() { try await handle(frame) }
                    }
                case .closed:
                    // A device without encryption resets the connection right after the Noise hello.
                    if phase == .handshake, serverHello == nil { throw ESPHomeError.usesPlaintext }
                    throw ESPHomeError.connectionLost
                case .tick:
                    let now = clock.now
                    if phase != .running {
                        if now > deadline {
                            if password != nil, phase == .deviceInfo {
                                logger.warning("Not sending the password to \(endpoint.host): it did not show its MAC first")
                            }
                            throw ESPHomeError.timedOut(phase.rawValue)
                        }
                    } else {
                        if now - lastReceived > timing.liveness { throw ESPHomeError.connectionLost }
                        if now - lastPing >= timing.keepalive {
                            lastPing = now
                            try await link.send(ESPHomeRequest.empty(MessageType.pingRequest))
                        }
                    }
                }
            }
            // The inbox ends when the task is cancelled: say goodbye.
            try? await link.send(ESPHomeRequest.empty(MessageType.disconnectRequest))
            await link.close()
            throw CancellationError()
        } catch {
            await link.close()
            throw error
        }
    }
}
