import Foundation
import HomeswiftNetwork
import Logging

/// The plugin's timings, multiplied by `scale` (tests shorten them).
struct ReolinkTiming: Sendable {
    var scale: Double = 1

    func seconds(_ value: Double) -> Duration { .milliseconds(Int(max(0, value * scale * 1000))) }

    /// A bound on a wait for the device (a connection, a reply), never scaled: tests' fakes answer or refuse at once, and a
    /// scaled one (30 ms of 15 s) is shorter than a loaded machine takes to pass a reply on.
    func timeout(_ value: Double) -> Duration { .milliseconds(Int(max(0, value * 1000))) }
}

/// What a Baichuan session reports to its host.
enum BaichuanSessionEvent: Sendable, Equatable {
    case push(ReolinkPush)
    /// Push is active (an event came since the subscription), or lost (the connection closed).
    case active(Bool)
}

/// One Baichuan TCP session to a host (5.3): nonce, login, the event subscription and its keepalive, reconnects with
/// `Backoff` and logins at most every 15 seconds, and the siren command. Its events come in `events`.
actor BaichuanSession {
    typealias Connect = @Sendable (_ host: String, _ port: Int, _ timeout: Duration) async throws -> any ByteStream

    static let loginSpacing: Double = 15
    static let defaultKeepalive: Double = 30
    static let requestTimeout: Double = 15
    static let backoff = ReolinkPlugin.backoff
    /// The unknown tags and AI types logged once each, at most.
    static let unknownLimit = 64

    nonisolated let events: AsyncStream<BaichuanSessionEvent>
    private let continuation: AsyncStream<BaichuanSessionEvent>.Continuation
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let connect: Connect
    private let log: Logger
    private let timing: ReolinkTiming

    private var stream: (any ByteStream)?
    private var counter: UInt32 = 0
    private var aesKey: [UInt8]?
    private var pending: [Key: CheckedContinuation<BaichuanMessage, any Error>] = [:]
    private var lastLogin: ContinuousClock.Instant?
    private var lastReceive = ContinuousClock.now
    private var eventsActive = false
    private var subscribed = false
    private var keepaliveInterval = defaultKeepalive
    private var lastIntervalRaise = ContinuousClock.now
    private var lastImmediateReconnect: ContinuousClock.Instant?
    private var unknownLogged: Set<String> = []
    private var stopped = false
    /// Whether the last connection attempt failed: an outage is logged once.
    private var failing = false

    private struct Key: Hashable {
        var command: UInt32
        var messageID: UInt32

        init(command: UInt32, messageID: UInt32) {
            self.command = command
            self.messageID = messageID
        }

        init(command: UInt32, channel: UInt8, counter: UInt32) {
            self.init(command: command, messageID: BaichuanMessage.messageID(channel: channel, counter: counter))
        }
    }

    init(host: String, port: Int, username: String, password: String, connect: @escaping Connect, log: Logger, timing: ReolinkTiming) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.connect = connect
        self.log = log
        self.timing = timing
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    var isConnected: Bool { stream != nil && subscribed }

    // MARK: The session's life

    /// Connects, logs in and subscribes, then serves until cancelled, reconnecting as 5.3.4 says.
    func run() async {
        var attempt = 0
        while !Task.isCancelled, !stopped {
            let started = ContinuousClock.now
            var wasActive = false
            do {
                try await open()
                try await subscribe()
                if failing { log.info("Baichuan push connection to the device is back.") }
                failing = false
                attempt = 0
                wasActive = await serve()
            } catch is CancellationError {
                break
            } catch {
                if !failing {
                    log.warning("Baichuan push unavailable: \(error). Falling back to polling, retrying in the background.")
                }
                failing = true
            }
            close()
            if eventsActive { continuation.yield(.active(false)) }
            eventsActive = false
            guard !Task.isCancelled, !stopped else { break }
            // A connection that was delivering events reconnects at once, no more than once a minute.
            let now = ContinuousClock.now
            if wasActive, lastImmediateReconnect.map({ now - $0 >= timing.seconds(60) }) ?? true {
                lastImmediateReconnect = now
                // In the session's own seconds (tests scale them).
                let idle = Double((now - lastReceive) / .seconds(1)) / max(timing.scale, .ulpOfOne)
                if now - started < timing.seconds(3600), idle >= 11 {
                    // The camera dropped a connection idle for a while, early: keep it alive more often. A drop right
                    // after traffic (a reboot, the network) says nothing of idleness and leaves the interval.
                    keepaliveInterval = max(9, min(idle - 2, keepaliveInterval - 1))
                }
                continue
            }
            try? await Task.sleep(for: Self.backoff.delay(attempt: attempt) * timing.scale)
            attempt += 1
        }
        close()
    }

    /// Logs out (5.3.4) and closes; `run` ends.
    func stop() async {
        stopped = true
        if stream != nil, aesKey != nil {
            _ = try? await request(command: 2, channel: Baichuan.hostChannel, body: Baichuan.logoutBody, encryption: .aes, timeout: 2)
        }
        close()
        continuation.finish()
    }

    private func close() {
        let stream = self.stream
        self.stream = nil
        subscribed = false
        aesKey = nil
        for (_, waiter) in pending { waiter.resume(throwing: BaichuanError.closed) }
        pending = [:]
        keepaliveWait?.cancel()
        if let stream { Task { await stream.close() } }
    }

    // MARK: Login (5.3.1, 5.3.2)

    private func open() async throws {
        if let lastLogin {
            let wait = timing.seconds(Self.loginSpacing) - (ContinuousClock.now - lastLogin)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastLogin = ContinuousClock.now
        let stream = try await connect(host, port, timing.timeout(10))
        self.stream = stream
        counter = 0
        lastReceive = .now
        let reader = Task { [weak self] in
            var framer = BaichuanFramer()
            do {
                for try await chunk in stream.incoming {
                    let results = framer.push(chunk)
                    await self?.received(results)
                }
            } catch {}
            await self?.closedByPeer(stream)
        }
        readerTask = reader

        // The nonce: a legacy header-only message, answered with BC-encrypted XML.
        counter += 1
        let nonceReply = try await send(Baichuan.nonceRequest(counter: counter), key: Key(command: 1, channel: Baichuan.hostChannel, counter: counter), timeout: 10)
        let nonceXML = try BaichuanDecoder.decrypt(nonceReply.body, expected: nonceReply.declaredEncryption ?? .xor, offset: nonceReply.channel, key: nil)
        guard let root = try? BXParser.parse(nonceXML), let nonce = root.first("nonce")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !nonce.isEmpty
        else { throw BaichuanError.noNonce }
        let accountDevice = root.first("sigVer")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "v3"

        let body = Baichuan.loginBody(username: username, password: password, nonce: nonce)
        log.trace("Baichuan login: \(body.utf8.count) bytes")
        do {
            try await request(command: 1, channel: Baichuan.hostChannel, body: body, encryption: .xor)
        } catch BaichuanError.status(401) {
            throw accountDevice ? BaichuanError.accountDevice : BaichuanError.unauthorized
        } catch BaichuanError.status where accountDevice {
            throw BaichuanError.accountDevice
        }
        aesKey = Baichuan.aesKey(nonce: nonce, password: password)
    }

    private var readerTask: Task<Void, Never>?
    /// The keepalive loop's wait, ended early by `close`.
    private var keepaliveWait: Task<Void, Never>?

    private func subscribe() async throws {
        try await request(command: 31, channel: Baichuan.subscribeChannel, body: nil, encryption: .aes)
        subscribed = true
        lastIntervalRaise = .now
    }

    /// Runs the keepalive until the connection closes; true when events were active.
    private func serve() async -> Bool {
        while !Task.isCancelled, stream != nil {
            let idle = ContinuousClock.now - lastReceive
            let interval = timing.seconds(keepaliveInterval)
            if idle >= interval {
                do {
                    try await request(command: eventsActive ? 93 : 31, channel: eventsActive ? Baichuan.hostChannel : Baichuan.subscribeChannel,
                                      body: nil, encryption: .aes)
                } catch {
                    log.debug("Baichuan keepalive failed: \(error)")
                    break
                }
            }
            if ContinuousClock.now - lastIntervalRaise >= timing.seconds(3600) {
                lastIntervalRaise = .now
                keepaliveInterval = min(Self.defaultKeepalive, keepaliveInterval + 1)
            }
            let wait = max(timing.seconds(keepaliveInterval) - (ContinuousClock.now - lastReceive), timing.seconds(0.05))
            // `close` ends the wait: a connection the camera dropped falls back to polling at once, not at the next
            // keepalive.
            let sleeper = Task { _ = try? await Task.sleep(for: wait) }
            keepaliveWait = sleeper
            await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
            keepaliveWait = nil
        }
        readerTask?.cancel()
        return eventsActive
    }

    private func closedByPeer(_ closed: any ByteStream) {
        guard let stream, stream as AnyObject === closed as AnyObject else { return }
        close()
    }

    // MARK: Requests

    /// Sends a request and waits for its reply (the same `cmd_id` and full message id). A status other than 200, 201 or
    /// 300 throws `status`.
    @discardableResult
    func request(command: UInt32, channel: UInt8, extension ext: String? = nil, body: String?, encryption: BaichuanEncryption,
                 timeout: Double = requestTimeout) async throws -> BaichuanMessage {
        guard stream != nil else { throw BaichuanError.closed }
        counter = (counter + 1) & 0xFF_FFFF
        func encode(_ text: String?) throws -> [UInt8] {
            guard let text else { return [] }
            let bytes = Array(text.utf8)
            switch encryption {
            case .none: return bytes
            case .xor: return Baichuan.xor(bytes, offset: channel)
            case .aes:
                guard let aesKey else { throw BaichuanError.closed }
                return try Baichuan.aes(bytes, key: aesKey, decrypt: false)
            }
        }
        let extBytes = try encode(ext)
        let bodyBytes = try encode(body)
        let message = Baichuan.header(command: command, bodyLength: extBytes.count + bodyBytes.count, channel: channel, counter: counter,
                                      extensionLength: extBytes.count) + extBytes + bodyBytes
        guard message.count <= Baichuan.maximumRequest else { throw BaichuanError.requestTooLarge(message.count) }
        let reply = try await send(message, key: Key(command: command, channel: channel, counter: counter), timeout: timeout)
        if let status = reply.status, ![200, 201, 300].contains(status) { throw BaichuanError.status(status) }
        return reply
    }

    private func send(_ bytes: [UInt8], key: Key, timeout: Double) async throws -> BaichuanMessage {
        guard let stream else { throw BaichuanError.closed }
        let timer = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.timeout(timeout))
            guard !Task.isCancelled else { return }
            await self?.expire(key)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<BaichuanMessage, any Error>) in
            pending[key]?.resume(throwing: BaichuanError.closed)
            pending[key] = waiter
            Task {
                do { try await stream.send(bytes) } catch { self.fail(key, error) }
            }
        }
    }

    private func expire(_ key: Key) { pending.removeValue(forKey: key)?.resume(throwing: BaichuanError.timeout) }
    private func fail(_ key: Key, _ error: any Error) { pending.removeValue(forKey: key)?.resume(throwing: error) }

    // MARK: Received

    private func received(_ results: [Result<BaichuanMessage, BaichuanError>]) {
        lastReceive = .now
        for result in results {
            switch result {
            case .failure(let error):
                log.debug("Baichuan: \(error)")
                // An unparsed reply fails the oldest waiting request rather than leaving it to time out.
                if error == .legacyReply, let key = pending.keys.first { fail(key, error) }
            case .success(let message):
                let key = Key(command: message.command, messageID: message.messageID)
                if let waiter = pending.removeValue(forKey: key) {
                    waiter.resume(returning: message)
                } else {
                    handlePush(message)
                }
            }
        }
    }

    private func handlePush(_ message: BaichuanMessage) {
        guard message.command != 234 else { return }
        let xml: String
        do {
            let pieces = message.extensionBytes.isEmpty ? message.body : message.extensionBytes
            xml = try BaichuanDecoder.decrypt(pieces, expected: message.declaredEncryption ?? .aes, offset: message.channel, key: aesKey)
        } catch {
            log.debug("Baichuan push \(message.command): \(error)")
            return
        }
        log.trace("Baichuan push \(message.command): \(xml.utf8.count) bytes")
        if message.command == 33, !eventsActive {
            eventsActive = true
            log.info("Baichuan push events active.")
            continuation.yield(.active(true))
        }
        var unknown: Set<String> = []
        for push in BaichuanEvents.parse(command: message.command, xml: xml, unknown: &unknown) {
            continuation.yield(.push(push))
        }
        for item in unknown where unknownLogged.count < Self.unknownLimit && unknownLogged.insert(item).inserted {
            log.debug("Baichuan push: unknown \(item), ignored.")
        }
    }

    // MARK: Commands

    /// The siren (5.4.3): `channel` nil is a hub's own.
    func siren(channel: Int?, mode: Baichuan.SirenMode) async throws {
        let body = Baichuan.sirenBody(channel: channel, mode: mode)
        if let channel {
            try await request(command: 263, channel: UInt8(clamping: channel + 1), extension: Baichuan.channelExtension(channel), body: body, encryption: .aes)
        } else {
            try await request(command: 263, channel: Baichuan.hostChannel, body: body, encryption: .aes)
        }
    }
}
