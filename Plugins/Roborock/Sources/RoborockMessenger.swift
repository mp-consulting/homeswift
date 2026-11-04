import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// The two ways to a robot (section 4): its local TCP port 58867 first, the cloud's MQTT broker when the LAN does not
// answer. One actor holds both, the request ids they share and the answers waited for.

/// A local connection: a TCP socket, or a fake one in tests.
protocol LocalLink: Sendable {
    var received: AsyncStream<Data> { get }
    func send(_ data: Data) async throws
    func close() async
}

extension TCPSocket: LocalLink {}

protocol LocalDialing: Sendable {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any LocalLink
}

struct TCPDialer: LocalDialing {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any LocalLink {
        try await TCPSocket.connect(host: host, port: port, timeout: timeout)
    }
}

enum RoborockRequestError: Error, CustomStringConvertible, Equatable {
    /// Not sent: the device is unknown, offline, or the path is down. Never retried on the other path.
    case refused(String)
    case timedOut
    case sendFailed(String)
    case deviceError(String)

    /// Worth one more try through the cloud: the LAN timed out or the write failed.
    var allowsCloudFallback: Bool {
        switch self {
        case .timedOut, .sendFailed: true
        case .refused, .deviceError: false
        }
    }

    /// A failure that comes and goes (a timeout, a robot busy locating or asking to retry): logged once in a while.
    var isTransient: Bool {
        switch self {
        case .timedOut: true
        case .deviceError(let message): message.lowercased().contains("retry") || message.lowercased().contains("locating")
        case .refused, .sendFailed: false
        }
    }

    var description: String {
        switch self {
        case .refused(let reason): reason
        case .timedOut: "timed out after 10 seconds"
        case .sendFailed(let reason): "could not send: \(reason)"
        case .deviceError(let message): message
        }
    }
}

actor RoborockMessenger {
    static let localPort = 58867

    struct Device: Sendable {
        var duid: String
        var localKey: String?
        /// The home data's protocol version.
        var version: RoborockVersion
        var isShared: Bool
        var online: Bool?
    }

    /// What arrives for a device: an RPC answer or a status broadcast, to show on its accessory.
    typealias Update = @Sendable (_ duid: String, _ payload: JSONValue) async -> Void

    private final class Connection: @unchecked Sendable {
        let link: any LocalLink
        var buffer = LengthPrefixedBuffer()
        var nonces: RoborockCipher.Nonces?
        var hello: (nonce: UInt32, continuation: CheckedContinuation<UInt32, any Error>)?
        var reader: Task<Void, Never>?
        var keepalive: Task<Void, Never>?

        init(link: any LocalLink) { self.link = link }
    }

    private struct Pending {
        var duid: String
        var method: String
        var isLocal: Bool
        var continuation: CheckedContinuation<JSONValue, any Error>
        var timeout: Task<Void, Never>
    }

    let timings: RoborockTimings
    let dialer: any LocalDialing
    let makeMQTT: @Sendable (MQTTConfiguration) -> any MQTTConnection
    let logger: Logger
    private let onUpdate: Update
    /// Finds IPs on the LAN (UDP discovery), for the devices given.
    private let discoverIPs: @Sendable (Set<String>) async -> [String: String]

    private var devices: [String: Device] = [:]
    /// Devices that answer L01 locally while their home data says 1.0.
    private var localVersions: [String: RoborockVersion] = [:]
    private var ips: [String: String] = [:]
    private var connections: [String: Connection] = [:]
    /// Devices reached through the cloud only: shared ones, and those whose LAN connection failed.
    private var demoted: Set<String> = []
    private var reconnects: [String: Task<Void, Never>] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var lastNetworkInfo: [String: ContinuousClock.Instant] = [:]
    private var pending: [Int: Pending] = [:]
    private var ids = RequestIDs()
    private var seq: UInt32 = 1
    private var random: UInt32 = 4711
    private var pingSeq: UInt32 = 0x10000
    private var warnedNoKey: Set<String> = []
    private var fallbackLogged: [String: Set<String>] = [:]
    private var methodTimeouts: [String: Int] = [:]
    private var methodPausedUntil: [String: ContinuousClock.Instant] = [:]
    private var localTimeouts: [String: Int] = [:]
    private var cooldownUntil: [String: ContinuousClock.Instant] = [:]
    private var stopped = false

    // The cloud.
    private var mqtt: (any MQTTConnection)?
    private var mqttConfiguration: MQTTConfiguration?
    private var mqttTasks: [Task<Void, Never>] = []
    private var mqttUp = false
    private var subscription = ""
    private var publishPrefix = ""
    /// Set by the plugin while the cloud's API does not answer: cloud timeouts then do not count.
    private var cloudUnreachable = false
    private var cloudTimeouts = 0
    private var restartsSinceTraffic = 0
    private var lastRestart: ContinuousClock.Instant?

    init(
        timings: RoborockTimings, dialer: any LocalDialing, makeMQTT: @escaping @Sendable (MQTTConfiguration) -> any MQTTConnection, logger: Logger,
        discoverIPs: @escaping @Sendable (Set<String>) async -> [String: String], onUpdate: @escaping Update
    ) {
        self.timings = timings
        self.dialer = dialer
        self.makeMQTT = makeMQTT
        self.logger = logger
        self.discoverIPs = discoverIPs
        self.onUpdate = onUpdate
    }

    // MARK: Devices

    /// The devices of the latest home data; their online flags drive reachability.
    func setDevices(_ list: [Device]) async {
        let kept = Set(list.map(\.duid))
        for duid in devices.keys where !kept.contains(duid) { await forget(duid) }
        for device in list {
            devices[device.duid] = device
            if device.isShared { demoted.insert(device.duid) }
        }
    }

    /// A device no longer in the account: no reconnects, no connection, nothing kept about it.
    private func forget(_ duid: String) async {
        devices[duid] = nil
        reconnects.removeValue(forKey: duid)?.cancel()
        if let connection = connections.removeValue(forKey: duid) {
            connection.reader?.cancel()
            connection.keepalive?.cancel()
            await connection.link.close()
        }
        ips[duid] = nil
        localVersions[duid] = nil
        reconnectAttempts[duid] = nil
        lastNetworkInfo[duid] = nil
        fallbackLogged[duid] = nil
        localTimeouts[duid] = nil
        cooldownUntil[duid] = nil
        demoted.remove(duid)
        warnedNoKey.remove(duid)
        methodTimeouts = methodTimeouts.filter { !$0.key.hasPrefix("\(duid)|") }
        methodPausedUntil = methodPausedUntil.filter { !$0.key.hasPrefix("\(duid)|") }
    }

    func setCloudUnreachable(_ value: Bool) { cloudUnreachable = value }

    var isMQTTUp: Bool { mqttUp }

    func isConnectedLocally(_ duid: String) -> Bool { connections[duid] != nil }

    /// Reachable: connected locally, or online in the home data.
    func isReachable(_ duid: String) -> Bool { isConnectedLocally(duid) || devices[duid]?.online == true }

    /// Can take a request on the LAN with nothing in the way: connected, not cooling down.
    func isLocallyAvailable(_ duid: String) -> Bool {
        connections[duid] != nil && !inCooldown(duid) && !demoted.contains(duid)
    }

    /// The method is paused after timing out three times in a row.
    func isPaused(_ duid: String, _ method: String) -> Bool {
        guard let until = methodPausedUntil["\(duid)|\(method)"] else { return false }
        return ContinuousClock.now < until
    }

    private func inCooldown(_ duid: String) -> Bool {
        guard let until = cooldownUntil[duid] else { return false }
        return ContinuousClock.now < until
    }

    private func effectiveVersion(_ duid: String) -> RoborockVersion {
        localVersions[duid] ?? devices[duid]?.version ?? .v1
    }

    // MARK: Requests

    /// Sends `method` to the device (section 4.7) and waits for its answer. `localOnly` never asks the cloud (a scene's
    /// step, which must not run twice).
    func request(_ duid: String, _ method: String, _ params: JSONValue = [], localOnly: Bool = false) async throws -> JSONValue {
        guard !stopped else { throw RoborockRequestError.refused("stopping") }
        guard let device = devices[duid] else { throw RoborockRequestError.refused("unknown device") }
        guard isReachable(duid) else { throw RoborockRequestError.refused("the device is offline") }
        if !localOnly, demoted.contains(duid) || Self.cloudOnlyMethods.contains(method) { return try await cloudRequest(device, method, params) }
        if !localOnly, mqttUp, connections[duid] == nil || inCooldown(duid) { return try await fallBack(device, method, params) }
        do {
            let result = try await localRequest(device, method, params)
            fallbackLogged[duid] = nil
            return result
        } catch let error as RoborockRequestError where error.allowsCloudFallback && !localOnly && mqttUp {
            return try await fallBack(device, method, params)
        }
    }

    /// Methods that always go through the cloud.
    static let cloudOnlyMethods: Set<String> = ["get_network_info", "service.get_net_info"]

    private func fallBack(_ device: Device, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        logFallback(device.duid, method)
        return try await cloudRequest(device, method, params)
    }

    private func logFallback(_ duid: String, _ method: String) {
        if fallbackLogged[duid, default: []].insert(method).inserted {
            logger.info("Falling back to the cloud for \(method)", metadata: ["device": "\(Self.short(duid))"])
        } else {
            logger.debug("Using the cloud for \(method)", metadata: ["device": "\(Self.short(duid))"])
        }
    }

    private func nextCounters() -> (seq: UInt32, random: UInt32) {
        defer {
            seq &+= 1
            random &+= 1
        }
        return (seq, random)
    }

    private func now() -> UInt32 { UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)) }

    private func localRequest(_ device: Device, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let key = device.localKey else { throw RoborockRequestError.refused("no local key") }
        guard let connection = connections[device.duid] else { throw RoborockRequestError.refused("no local connection") }
        let version = effectiveVersion(device.duid)
        if version == .l01, connection.nonces == nil { await handshake(device.duid, connection) }
        let id = ids.take { pending[$0] != nil }
        let counters = nextCounters()
        var frame = RoborockFrame(
            version: version, seq: counters.seq, random: counters.random, timestamp: now(), protocolNumber: RoborockFrameProtocol.localRequest)
        let body = RoborockMessages.requestBody(id: id, method: method, params: params, protocolNumber: frame.protocolNumber, timestamp: frame.timestamp, version: version)
        do {
            frame.payload = try RoborockCipher.encrypt(body, frame: frame, localKey: key, nonces: connection.nonces)
        } catch {
            throw RoborockRequestError.sendFailed("\(error)")
        }
        logger.debug("Sending \(method) locally", metadata: ["device": "\(Self.short(device.duid))", "id": "\(id)"])
        let link = connection.link
        let data = frame.lengthPrefixed()
        return try await wait(id: id, duid: device.duid, method: method, isLocal: true) {
            try await link.send(data)
        }
    }

    private func cloudRequest(_ device: Device, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let key = device.localKey else { throw RoborockRequestError.refused("no local key") }
        guard mqttUp, let mqtt else { throw RoborockRequestError.refused("the cloud is not connected") }
        let version = device.version
        let id = ids.take { pending[$0] != nil }
        let counters = nextCounters()
        var frame = RoborockFrame(
            version: version, seq: counters.seq, random: counters.random, timestamp: now(), protocolNumber: RoborockFrameProtocol.cloudRequest)
        let body = RoborockMessages.requestBody(id: id, method: method, params: params, protocolNumber: frame.protocolNumber, timestamp: frame.timestamp, version: version)
        do {
            frame.payload = try RoborockCipher.encrypt(body, frame: frame, localKey: key, nonces: connections[device.duid]?.nonces)
        } catch {
            throw RoborockRequestError.sendFailed("\(error)")
        }
        logger.debug("Sending \(method) through the cloud", metadata: ["device": "\(Self.short(device.duid))", "id": "\(id)"])
        let topic = publishPrefix + device.duid
        let payload = frame.encoded()
        do {
            let result = try await wait(id: id, duid: device.duid, method: method, isLocal: false) {
                try await mqtt.publish(MQTTMessage(topic: topic, payload: payload, qos: .atLeastOnce))
            }
            cloudSucceeded()
            return result
        } catch RoborockRequestError.timedOut {
            await cloudTimedOut()
            throw RoborockRequestError.timedOut
        }
    }

    /// Registers the answer to wait for, sends, and waits up to the request timeout.
    private func wait(id: Int, duid: String, method: String, isLocal: Bool, send: @escaping @Sendable () async throws -> Void) async throws -> JSONValue {
        let timeout = timings.requestTimeout
        let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expire(id)
            }
            pending[id] = Pending(duid: duid, method: method, isLocal: isLocal, continuation: continuation, timeout: timer)
            Task { [weak self] in
                do {
                    try await send()
                } catch {
                    await self?.fail(id, RoborockRequestError.sendFailed("\(error)"))
                }
            }
        }
        methodTimeouts["\(duid)|\(method)"] = nil
        methodPausedUntil["\(duid)|\(method)"] = nil
        if isLocal {
            localTimeouts[duid] = nil
            cooldownUntil[duid] = nil
        }
        return result
    }

    private func fail(_ id: Int, _ error: any Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func expire(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        let key = "\(entry.duid)|\(entry.method)"
        let count = methodTimeouts[key, default: 0] + 1
        methodTimeouts[key] = count
        if count >= 3, methodPausedUntil[key] == nil {
            methodPausedUntil[key] = ContinuousClock.now + timings.methodPause
            logger.info("Pausing \(entry.method) for 30 minutes: it timed out 3 times", metadata: ["device": "\(Self.short(entry.duid))"])
        }
        if entry.isLocal {
            connections[entry.duid]?.buffer.reset()
            let local = localTimeouts[entry.duid, default: 0] + 1
            localTimeouts[entry.duid] = local
            if local >= 3, !inCooldown(entry.duid) {
                cooldownUntil[entry.duid] = ContinuousClock.now + timings.localCooldown
                localTimeouts[entry.duid] = 0
                logger.info("The robot does not answer on the LAN: preferring the cloud for 5 minutes", metadata: ["device": "\(Self.short(entry.duid))"])
            }
        }
        entry.continuation.resume(throwing: RoborockRequestError.timedOut)
    }

    /// An answer: completes its request, and shows on the device's accessory.
    private func deliver(_ duid: String, _ incoming: RoborockMessages.Incoming) async {
        switch incoming {
        case .response(let id, let result):
            if let entry = pending[id], entry.duid == duid {
                pending[id] = nil
                entry.timeout.cancel()
                if let error = result["error"], result.objectValue?.count == 1 {
                    let message = error["message"]?.stringValue ?? error.stringValue ?? error.text()
                    entry.continuation.resume(throwing: RoborockRequestError.deviceError(message))
                    return
                }
                entry.continuation.resume(returning: result)
            }
            await onUpdate(duid, result)
        case .status(let fields):
            await onUpdate(duid, .object(fields))
        }
    }

    // MARK: The LAN

    /// Connects to the device at its IP (and keeps trying, section 4.5).
    func connectLocal(_ duid: String, ip: String?) async {
        if let ip { ips[duid] = ip }
        guard !stopped, connections[duid] == nil, let device = devices[duid], device.localKey != nil, !device.isShared else { return }
        guard let host = ips[duid] else { return scheduleReconnect(duid) }
        if device.version == .v1, localVersions[duid] == nil {
            let l01 = await probeL01(host)
            localVersions[duid] = l01 ? .l01 : .v1
            if l01 { logger.info("The robot reports protocol 1.0 but answers L01 on the LAN", metadata: ["device": "\(Self.short(duid))"]) }
        }
        let link: any LocalLink
        do {
            link = try await dialer.connect(host: host, port: Self.localPort, timeout: timings.requestTimeout)
        } catch {
            if devices[duid]?.online == true, demoted.insert(duid).inserted {
                logger.info("Cannot reach the robot on the LAN: using the cloud", metadata: ["device": "\(Self.short(duid))", "error": "\(error)"])
            }
            return scheduleReconnect(duid)
        }
        guard !stopped else { return await link.close() }
        let connection = Connection(link: link)
        connections[duid] = connection
        reconnectAttempts[duid] = nil
        if demoted.remove(duid) != nil {
            logger.info("Reaching the robot on the LAN again", metadata: ["device": "\(Self.short(duid))"])
        }
        connection.reader = Task { [weak self] in
            for await chunk in link.received {
                await self?.received(chunk, duid: duid, connection: connection)
            }
            await self?.closed(duid, connection)
        }
        if effectiveVersion(duid) == .l01 {
            await handshake(duid, connection)
            let interval = timings.keepalive
            connection.keepalive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await self?.ping(duid, connection)
                }
            }
        }
    }

    /// Asks with an L01 HELLO on a throwaway connection whether the device answers L01.
    private func probeL01(_ host: String) async -> Bool {
        guard let link = try? await dialer.connect(host: host, port: Self.localPort, timeout: timings.probe) else { return false }
        let hello = RoborockFrame(version: .l01, seq: 1, random: UInt32.random(in: 10000...32767), timestamp: now(), protocolNumber: RoborockFrameProtocol.helloRequest)
        let timeout = timings.probe
        let answered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard (try? await link.send(hello.lengthPrefixed())) != nil else { return false }
                var seen = Data()
                for await chunk in link.received {
                    seen.append(chunk)
                    if seen.count >= 7 { return Array(seen[seen.startIndex + 4..<seen.startIndex + 7]) == RoborockVersion.l01.bytes }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await link.close()
        return answered
    }

    private func handshake(_ duid: String, _ connection: Connection) async {
        let nonce = UInt32.random(in: 10000...32767)
        let hello = RoborockFrame(version: .l01, seq: 1, random: nonce, timestamp: now(), protocolNumber: RoborockFrameProtocol.helloRequest)
        let timeout = timings.handshake
        do {
            let ack: UInt32 = try await withCheckedThrowingContinuation { continuation in
                connection.hello?.continuation.resume(throwing: RoborockRequestError.refused("another handshake"))
                connection.hello = (nonce, continuation)
                let link = connection.link
                Task { [weak self] in
                    do { try await link.send(hello.lengthPrefixed()) } catch { await self?.failHello(connection, error) }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.failHello(connection, RoborockRequestError.timedOut)
                }
            }
            connection.nonces = .init(connect: nonce, ack: ack)
            logger.debug("L01 handshake done", metadata: ["device": "\(Self.short(duid))"])
        } catch {
            logger.debug("L01 handshake failed: \(error)", metadata: ["device": "\(Self.short(duid))"])
        }
    }

    private func failHello(_ connection: Connection, _ error: any Error) {
        guard let hello = connection.hello else { return }
        connection.hello = nil
        hello.continuation.resume(throwing: error)
    }

    private func ping(_ duid: String, _ connection: Connection) async {
        guard connections[duid] === connection else { return }
        let frame = RoborockFrame(
            version: .l01, seq: pingSeq, random: UInt32.random(in: 10000...32767), timestamp: now(), protocolNumber: RoborockFrameProtocol.ping)
        pingSeq &+= 1
        try? await connection.link.send(frame.lengthPrefixed())
    }

    private func received(_ chunk: Data, duid: String, connection: Connection) async {
        let segments: [Data]
        do {
            segments = try connection.buffer.append(chunk)
        } catch {
            logger.warning("Corrupt frame from the robot: closing the connection", metadata: ["device": "\(Self.short(duid))"])
            await connection.link.close()
            return
        }
        for segment in segments {
            guard let frame = decodeFrame(segment, duid: duid) else { continue }
            if RoborockFrameProtocol.isHeaderOnly(frame.protocolNumber) || segment.count == 17 || segment.count == 21 {
                if frame.protocolNumber == RoborockFrameProtocol.helloResponse, let hello = connection.hello {
                    connection.hello = nil
                    hello.continuation.resume(returning: frame.random)
                }
                continue
            }
            guard frame.protocolNumber == RoborockFrameProtocol.localRequest, let payload = decrypt(frame, duid: duid, nonces: connection.nonces, length: segment.count) else { continue }
            guard let incoming = RoborockMessages.incoming(payload), case .response = incoming else { continue }
            await deliver(duid, incoming)
        }
    }

    private func decodeFrame(_ data: Data, duid: String?) -> RoborockFrame? {
        do {
            return try RoborockFrame.decode(data)
        } catch {
            logger.error("Could not read a frame: \(error)", metadata: ["length": "\(data.count)", "start": "\(RoborockCipher.hex(data.prefix(12)))"])
            return nil
        }
    }

    private func decrypt(_ frame: RoborockFrame, duid: String, nonces: RoborockCipher.Nonces?, length: Int) -> Data? {
        guard let key = devices[duid]?.localKey else {
            if warnedNoKey.insert(duid).inserted {
                logger.warning("Skipping messages of a robot without a local key", metadata: ["device": "\(Self.short(duid))"])
            }
            return nil
        }
        do {
            return try RoborockCipher.decrypt(frame.payload, frame: frame, localKey: key, nonces: nonces)
        } catch {
            logger.error("Could not decrypt a frame: \(error)", metadata: ["length": "\(length)", "device": "\(Self.short(duid))"])
            return nil
        }
    }

    private func closed(_ duid: String, _ connection: Connection) {
        failHello(connection, RoborockRequestError.refused("connection closed"))
        connection.keepalive?.cancel()
        connection.nonces = nil
        guard connections[duid] === connection else { return }
        connections[duid] = nil
        logger.debug("Local connection closed", metadata: ["device": "\(Self.short(duid))"])
        scheduleReconnect(duid)
    }

    private func scheduleReconnect(_ duid: String) {
        guard !stopped, reconnects[duid] == nil else { return }
        let attempt = reconnectAttempts[duid, default: 0]
        reconnectAttempts[duid] = attempt + 1
        let delay = timings.reconnectBackoff.delay(attempt: attempt)
        reconnects[duid] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnect(duid)
        }
    }

    private func reconnect(_ duid: String) async {
        reconnects[duid] = nil
        guard !stopped else { return }
        let ip = await refreshIP(duid)
        await connectLocal(duid, ip: ip)
    }

    /// The device's IP: from a UDP discovery, else `get_network_info` over the cloud (once a minute at most), else the
    /// last known.
    private func refreshIP(_ duid: String) async -> String? {
        if let found = await discoverIPs([duid])[duid] { return found }
        if mqttUp, let device = devices[duid], ContinuousClock.now - (lastNetworkInfo[duid] ?? .now - timings.networkInfoInterval) >= timings.networkInfoInterval {
            lastNetworkInfo[duid] = .now
            if let ip = try? await networkInfo(device) { return ip }
        }
        return ips[duid]
    }

    /// The device's IP from `get_network_info` (`service.get_net_info` for B01), through the cloud.
    func networkInfo(_ duid: String) async throws -> String? {
        guard let device = devices[duid] else { return nil }
        return try await networkInfo(device)
    }

    private func networkInfo(_ device: Device) async throws -> String? {
        let method = device.version == .b01 ? "service.get_net_info" : "get_network_info"
        let result = try await request(device.duid, method)
        let info = RoborockMessages.firstObject(result)
        return (info?["ip"] ?? info?["ipAddress"] ?? info?["ipAdress"])?.stringValue
    }

    // MARK: The cloud

    /// Connects to the account's broker (section 4.4).
    func startCloud(session: RoborockSession) async {
        guard !stopped, let broker = session.broker, let url = URL(string: broker) else {
            logger.warning("The session has no MQTT broker: the cloud is not used")
            return
        }
        let credentials = RoborockAuth.MQTTCredentials(u: session.u, s: session.s, k: session.k)
        subscription = "rr/m/o/\(session.u)/\(credentials.username)/#"
        publishPrefix = "rr/m/i/\(session.u)/\(credentials.username)/"
        do {
            var configuration = try MQTTConfiguration(url: url, clientID: credentials.username)
            configuration.username = credentials.username
            configuration.password = credentials.password
            configuration.keepAlive = .seconds(30)
            configuration.cleanSession = true
            configuration.reconnect = .init(delay: .seconds(5), maximumDelay: .seconds(300), jitter: .proportional(0.2), firstConnection: true)
            mqttConfiguration = configuration
        } catch {
            logger.error("Cannot use the MQTT broker: \(error)")
            return
        }
        openMQTT()
        logger.info("MQTT initialised")
        let warning = timings.mqttUpWarning, forced = timings.mqttForcedReconnect
        mqttTasks.append(Task { [weak self] in
            try? await Task.sleep(for: warning)
            guard !Task.isCancelled, await self?.isMQTTUp == false else { return }
            self?.logger.warning("MQTT is not connected after 30 seconds; still trying")
        })
        mqttTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: forced)
                guard !Task.isCancelled else { return }
                await self?.restartMQTT(reason: "the 3-hour reconnect")
            }
        })
    }

    private var mqttSessionTasks: [Task<Void, Never>] = []

    private func openMQTT() {
        guard let configuration = mqttConfiguration, !stopped else { return }
        let client = makeMQTT(configuration)
        mqtt = client
        mqttUp = false
        let topic = subscription
        mqttSessionTasks.append(Task { [weak self] in
            for await message in client.messages {
                await self?.cloudMessage(message)
            }
        })
        mqttSessionTasks.append(Task { [weak self] in
            for await state in client.states {
                guard let self else { return }
                switch state {
                case .connected:
                    do {
                        try await client.subscribe(topic, qos: .atLeastOnce)
                        await self.setMQTTUp(true, client)
                    } catch {
                        self.logger.error("The MQTT subscription was refused: \(error)")
                        await self.setMQTTUp(false, client)
                    }
                case .connectionLost(let reason):
                    if await self.isMQTTUp { self.logger.info("MQTT connection closed, reconnecting: \(reason)") }
                    await self.setMQTTUp(false, client)
                case .disconnected, .connecting:
                    await self.setMQTTUp(false, client)
                }
            }
        })
        mqttSessionTasks.append(Task { [weak self] in
            do {
                try await client.connect()
            } catch {
                self?.logger.error("MQTT error: \(error)")
            }
        })
    }

    private func setMQTTUp(_ value: Bool, _ client: any MQTTConnection) {
        guard let mqtt, (mqtt as AnyObject) === (client as AnyObject) else { return }
        mqttUp = value
    }

    private func restartMQTT(reason: String) async {
        guard !stopped, mqttConfiguration != nil else { return }
        logger.info("Restarting the MQTT session: \(reason)")
        let old = mqtt
        mqttSessionTasks.forEach { $0.cancel() }
        mqttSessionTasks = []
        mqtt = nil
        mqttUp = false
        await old?.disconnect()
        openMQTT()
    }

    private func cloudSucceeded() {
        cloudTimeouts = 0
        restartsSinceTraffic = 0
    }

    /// A cloud timeout while MQTT says it is connected: three in a row with nothing received restart the session, at
    /// most every 30 minutes, doubling up to 6 hours while no traffic comes (section 8.5).
    private func cloudTimedOut() async {
        guard mqttUp, !cloudUnreachable else { return }
        cloudTimeouts += 1
        guard cloudTimeouts >= 3 else { return }
        let wait = restartsSinceTraffic == 0 ? .zero : timings.mqttRestart.delay(attempt: restartsSinceTraffic - 1)
        if let lastRestart, ContinuousClock.now - lastRestart < wait { return }
        cloudTimeouts = 0
        restartsSinceTraffic += 1
        lastRestart = .now
        await restartMQTT(reason: "three requests timed out with no message from the broker")
    }

    private func cloudMessage(_ message: MQTTMessage) async {
        cloudTimeouts = 0
        restartsSinceTraffic = 0
        guard let duid = duid(ofTopic: message.topic) else {
            logger.debug("A message for no known robot")
            return
        }
        guard let frame = decodeFrame(message.payload, duid: duid) else { return }
        switch frame.protocolNumber {
        case RoborockFrameProtocol.response:
            guard let payload = decrypt(frame, duid: duid, nonces: connections[duid]?.nonces, length: message.payload.count),
                let incoming = RoborockMessages.incoming(payload)
            else { return }
            await deliver(duid, incoming)
        case RoborockFrameProtocol.deviceEvent:
            // Plain JSON: not encrypted beyond the frame.
            guard let json = try? JSONValue(data: frame.payload) else { return }
            if json["online"] == false {
                logger.info("The robot is offline", metadata: ["device": "\(Self.short(duid))"])
            } else if json["online"] == true {
            } else if let ota = json["mqttOtaData"] {
                let status = ota["mqttOtaStatus"]?["status"]?.stringValue ?? "?"
                let progress = ota["mqttOtaProgress"]?["progress"]?.intValue.map { " \($0) %" } ?? ""
                logger.info("Firmware update: \(status)\(progress)", metadata: ["device": "\(Self.short(duid))"])
            } else {
                logger.warning("Unrecognised device message", metadata: ["device": "\(Self.short(duid))"])
            }
        default:
            logger.debug("Ignoring protocol \(frame.protocolNumber)", metadata: ["device": "\(Self.short(duid))"])
        }
    }

    /// The device of a topic: its last segment, or the last segment that is a known device (section 4.4).
    func duid(ofTopic topic: String) -> String? {
        let segments = topic.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if devices.isEmpty { return segments.last }
        return segments.reversed().first { devices[$0] != nil }
    }

    // MARK: Shutdown

    func stop() async {
        stopped = true
        reconnects.values.forEach { $0.cancel() }
        reconnects = [:]
        mqttTasks.forEach { $0.cancel() }
        mqttSessionTasks.forEach { $0.cancel() }
        for (id, entry) in pending {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: RoborockRequestError.refused("stopping"))
            pending[id] = nil
        }
        for connection in connections.values {
            connection.reader?.cancel()
            connection.keepalive?.cancel()
            failHello(connection, RoborockRequestError.refused("stopping"))
            await connection.link.close()
        }
        connections = [:]
        await mqtt?.disconnect()
        mqtt = nil
        mqttUp = false
    }

    /// A device id for the log: its first characters.
    static func short(_ duid: String) -> String { duid.count > 6 ? String(duid.prefix(6)) + "…" : duid }
}
