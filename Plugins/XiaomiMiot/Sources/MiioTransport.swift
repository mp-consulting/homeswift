import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// The miIO transport (docs/clean-room/XiaomiMiot.md sections 5.2–5.9): one UDP socket for the instance, a client per
// device that shakes hands, stamps and numbers its requests, waits for the reply with the same id and retries.

/// Where packets go and come from: the real UDP socket, or a fake network of devices in tests.
protocol MiioNetwork: Sendable {
    /// A socket bound to a port of the system's choice, that may send to broadcast addresses.
    func open() async throws -> any MiioSocket
}

protocol MiioSocket: Sendable {
    /// What arrives, with the sender's address and port. Ends when the socket closes.
    var datagrams: AsyncStream<UDPSocket.Datagram> { get }
    func send(_ data: Data, to host: String, port: Int) async throws
    func close() async
}

/// The real network: `UDPSocket` on NIO.
struct UDPMiioNetwork: MiioNetwork {
    func open() async throws -> any MiioSocket {
        UDPMiioSocket(socket: try await UDPSocket.bind(broadcast: true, senderPorts: true))
    }
}

struct UDPMiioSocket: MiioSocket {
    let socket: UDPSocket
    var datagrams: AsyncStream<UDPSocket.Datagram> { socket.datagramsWithPorts }
    func send(_ data: Data, to host: String, port: Int) async throws { try await socket.send(data, to: host, port: port) }
    func close() async { await socket.close() }
}

/// The waits of the protocol (section 5.7); tests shorten them.
struct MiioTimings: Sendable {
    var requestTimeout: Duration = .seconds(4)
    var retries = 2
    var handshakeTimeout: Duration = .seconds(5)
    /// A packet from the device younger than this spares the next request its handshake.
    var handshakeValidity: Duration = .seconds(120)
    /// `miIO.info`'s own (section 5.8).
    var infoTimeout: Duration = .seconds(5)
    var infoRetries = 3
}

enum MiioError: Error, CustomStringConvertible, Equatable {
    /// No answer after the last try.
    case timeout
    /// The device answered with an `error`.
    case device(code: Int, message: String)
    /// The result is, or contains, `unknown_method`: the device does not know the method.
    case unknownMethod
    /// Replies came that failed the checksum or did not decrypt: the token is not the device's.
    case wrongToken
    case invalidReply

    var description: String {
        switch self {
        case .timeout: "Call to device timed out"
        case .device(let code, let message): "the device answered error \(code): \(message)"
        case .unknownMethod: "the device does not know the method"
        case .wrongToken: "the token does not open the device"
        case .invalidReply: "the device's reply is not valid"
        }
    }

    /// −30001 and −9999 ("user ack timeout"): the device is busy, retried like a timeout.
    var isBusy: Bool {
        if case .device(let code, _) = self { return code == -30001 || code == -9999 }
        return false
    }
}

/// The instance's socket, shared by its devices: replies are handed to the client of the address they come from.
actor MiioHub {
    private let network: any MiioNetwork
    private var socket: (any MiioSocket)?
    private var opening: Task<any MiioSocket, any Error>?
    private var clients: [String: MiioClient] = [:]
    private var reader: Task<Void, Never>?
    let logger: Logger

    init(network: any MiioNetwork, logger: Logger) {
        self.network = network
        self.logger = logger
    }

    func register(_ client: MiioClient, host: String) {
        clients[host] = client
    }

    func unregister(host: String, client: MiioClient) {
        if clients[host] === client { clients[host] = nil }
    }

    func send(_ data: Data, to host: String) async throws {
        try await open().send(data, to: host, port: MiioPacket.port)
    }

    private func open() async throws -> any MiioSocket {
        if let socket { return socket }
        if let opening { return try await opening.value }
        let network = network
        let task = Task { try await network.open() }
        opening = task
        defer { opening = nil }
        let socket = try await task.value
        self.socket = socket
        reader = Task { [weak self] in
            for await datagram in socket.datagrams {
                guard let self else { return }
                await self.deliver(datagram)
            }
        }
        return socket
    }

    private func deliver(_ datagram: UDPSocket.Datagram) async {
        guard let client = clients[datagram.address] else { return }
        await client.receive(datagram.data)
    }

    func close() async {
        reader?.cancel()
        reader = nil
        await socket?.close()
        socket = nil
        clients.removeAll()
    }
}

/// One device on the LAN: its handshake, stamp, ids and requests, one at a time.
actor MiioClient {
    private(set) var host: String
    let token: MiioToken
    private let hub: MiioHub
    let timings: MiioTimings
    private let logger: Logger
    private let now: @Sendable () -> ContinuousClock.Instant

    /// The did the device gives in its replies; the configured one until it answered.
    private(set) var deviceID: UInt32?
    /// The did of the last reply the token verified; nil until one came.
    private(set) var verifiedDeviceID: UInt32?
    private var stamp: (value: UInt32, at: ContinuousClock.Instant)?
    private var lastPacket: ContinuousClock.Instant?
    private var lastID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var handshakeWaiter: CheckedContinuation<Bool, Never>?
    private var handshakeGeneration = 0
    /// Packets that came but failed the checksum or the decryption, since the last request began.
    private var rejected = 0
    private let serial = SerialTasks()

    init(host: String, token: MiioToken, deviceID: UInt32? = nil, hub: MiioHub, timings: MiioTimings, logger: Logger,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.host = host
        self.token = token
        self.deviceID = deviceID
        self.hub = hub
        self.timings = timings
        self.logger = logger
        self.now = now
    }

    func attach() async {
        await hub.register(self, host: host)
    }

    func detach() async {
        await hub.unregister(host: host, client: self)
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        handshakeWaiter?.resume(returning: false)
        handshakeWaiter = nil
    }

    /// Follows the device to a new address (the hello broadcast or the cloud list saw it there).
    func move(to newHost: String) async {
        guard newHost != host else { return }
        await hub.unregister(host: host, client: self)
        host = newHost
        lastPacket = nil
        await hub.register(self, host: host)
    }

    /// A request's stamp: the device's last one plus the whole seconds since it arrived; 0xFFFFFFFF before any.
    static func requestStamp(_ stamp: (value: UInt32, at: ContinuousClock.Instant)?, now: ContinuousClock.Instant) -> UInt32 {
        guard let stamp else { return 0xFFFF_FFFF }
        let elapsed = max(0, (now - stamp.at).components.seconds)
        return stamp.value &+ UInt32(truncatingIfNeeded: elapsed)
    }

    /// The next request's id: 1, 2, … and back to 1 at 10000; a retry takes the last id + 100.
    static func nextID(after last: Int, retry: Bool) -> Int {
        let next = last + (retry ? 100 : 1)
        return next >= 10000 ? 1 : next
    }

    /// Sends `method` with `params` and answers the reply's `result` (section 5.6, 5.7).
    func call(_ method: String, _ params: OrderedJSON = .array([]), timeout: Duration? = nil, retries: Int? = nil) async throws -> JSONValue {
        let timeout = timeout ?? timings.requestTimeout
        let retries = retries ?? timings.retries
        return try await serial.run { try await self.send(method, params, timeout: timeout, retries: retries) }
    }

    private func send(_ method: String, _ params: OrderedJSON, timeout: Duration, retries: Int) async throws -> JSONValue {
        rejected = 0
        var lastError: MiioError = .timeout
        for attempt in 0...max(0, retries) {
            try Task.checkCancellation()
            if needsHandshake {
                guard await handshake() else {
                    // A handshake that timed out counts as one try.
                    lastError = .timeout
                    continue
                }
            }
            lastID = Self.nextID(after: lastID, retry: attempt > 0)
            let id = lastID
            let payload = OrderedJSON.object([("id", .int(id)), ("method", .string(method)), ("params", params)])
            let packet: Data
            do {
                packet = try MiioPacket.encode(payload: Data(payload.text.utf8), token: token, deviceID: deviceID ?? 0xFFFF_FFFF,
                                               stamp: Self.requestStamp(stamp, now: now()))
            } catch {
                throw MiioError.invalidReply
            }
            logger.debug("miIO \(method) #\(id) to \(host)")
            do {
                let result = try await exchange(packet, id: id, timeout: timeout)
                if Self.isUnknownMethod(result) { throw MiioError.unknownMethod }
                return result
            } catch let error as MiioError where error == .timeout || error.isBusy {
                lastError = error
                // The device may have forgotten us: shake hands again before the next try.
                lastPacket = nil
                continue
            }
        }
        if lastError == .timeout, rejected > 0 { throw MiioError.wrongToken }
        throw lastError
    }

    private var needsHandshake: Bool {
        guard let lastPacket, deviceID != nil else { return true }
        return now() - lastPacket >= timings.handshakeValidity
    }

    /// Sends the hello and waits for the reply; false when none came in time.
    private func handshake() async -> Bool {
        let timeout = timings.handshakeTimeout, hub = hub, host = host, logger = logger
        handshakeGeneration += 1
        let generation = handshakeGeneration
        return await withCheckedContinuation { continuation in
            handshakeWaiter?.resume(returning: false)
            // Waiting before it goes out: the reply may come at once.
            handshakeWaiter = continuation
            Task { [weak self] in
                do {
                    try await hub.send(MiioPacket.hello, to: host)
                } catch {
                    logger.debug("Could not send the hello to \(host): \(error)")
                    await self?.handshakeTimedOut(generation)
                    return
                }
                try? await Task.sleep(for: timeout)
                await self?.handshakeTimedOut(generation)
            }
        }
    }

    private func handshakeTimedOut(_ generation: Int) {
        // Only the handshake still waiting: a reply may have come meanwhile, or another handshake begun.
        guard generation == handshakeGeneration, let waiter = handshakeWaiter else { return }
        handshakeWaiter = nil
        waiter.resume(returning: false)
    }

    private func exchange(_ packet: Data, id: Int, timeout: Duration) async throws -> JSONValue {
        let hub = hub, host = host
        return try await withCheckedThrowingContinuation { continuation in
            // Waiting before it goes out: the reply may come at once.
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await hub.send(packet, to: host)
                } catch {
                    await self?.expire(id)
                    return
                }
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: MiioError.timeout)
    }

    /// A packet from the device's address. A hello reply carries no checksum: it gives the did and stamp requests are
    /// sent with, while only a reply the token verifies (its header is in the checksum) proves the did (`verifiedDeviceID`).
    func receive(_ data: Data) {
        guard let packet = MiioPacket(data) else { return }
        if packet.isHandshake {
            note(packet)
            if deviceID != packet.deviceID { deviceID = packet.deviceID }
            handshakeWaiter?.resume(returning: true)
            handshakeWaiter = nil
            return
        }
        guard packet.verifies(with: token), let plain = try? packet.decrypt(with: token) else {
            rejected += 1
            logger.debug("Dropped a packet from \(host) that the token does not open")
            return
        }
        note(packet)
        verifiedDeviceID = packet.deviceID
        guard let reply = try? JSONValue(data: plain), let id = reply["id"]?.intValue else {
            logger.debug("Dropped a reply from \(host) that is not JSON")
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = reply["error"], error.objectValue != nil {
            continuation.resume(throwing: MiioError.device(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? ""))
        } else {
            continuation.resume(returning: reply["result"] ?? .null)
        }
    }

    private func note(_ packet: MiioPacket) {
        lastPacket = now()
        if packet.stamp > 0 { stamp = (packet.stamp, now()) }
    }

    /// `unknown_method`, or a list or object holding it.
    static func isUnknownMethod(_ result: JSONValue) -> Bool {
        switch result {
        case .string(let text): text == "unknown_method"
        case .array(let items): items.contains { isUnknownMethod($0) }
        default: false
        }
    }

    // MARK: Methods

    /// `miIO.info` (section 5.8): at least `model` and `fw_ver`.
    func info() async throws -> JSONValue {
        try await call("miIO.info", .array([]), timeout: timings.infoTimeout, retries: timings.infoRetries)
    }
}

/// What the plugin learns from a hello reply: who answered, from where.
struct HelloReply: Sendable, Equatable {
    var deviceID: UInt32
    var address: String
    var stamp: UInt32
}

enum MiioDiscovery {
    /// Sends the hello to the broadcast addresses and gathers the replies for `window` (section 3.5).
    static func broadcast(network: any MiioNetwork, window: Duration, logger: Logger) async -> [HelloReply] {
        let socket: any MiioSocket
        do {
            socket = try await network.open()
        } catch {
            logger.debug("Could not open the discovery socket: \(error)")
            return []
        }
        var targets = ["255.255.255.255"]
        for network in localIPv4Networks() where !network.isLoopback {
            let address = IPv4Network.dotted(network.broadcast)
            if !targets.contains(address) { targets.append(address) }
        }
        for target in targets {
            do { try await socket.send(MiioPacket.hello, to: target, port: MiioPacket.port) } catch { logger.debug("Could not send the hello to \(target): \(error)") }
        }
        let datagrams = socket.datagrams
        let found = await datagrams.collect(for: window)
        await socket.close()
        var replies: [UInt32: HelloReply] = [:]
        for datagram in found {
            guard let packet = MiioPacket(datagram.data), packet.isHandshake, packet.deviceID != 0xFFFF_FFFF else { continue }
            replies[packet.deviceID] = HelloReply(deviceID: packet.deviceID, address: datagram.address, stamp: packet.stamp)
        }
        return replies.values.sorted { $0.deviceID < $1.deviceID }
    }
}
