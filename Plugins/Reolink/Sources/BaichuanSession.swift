import Foundation
import Homeswift
import HomeswiftNetwork
import Logging

/// The plugin's timings, multiplied by `scale` (tests shorten them).
struct ReolinkTiming: Sendable {
    var scale: Double = 1
    /// How many times longer the waits for the device (`timeout`) are: 1 on a bridge; more in tests, whose fakes answer at
    /// once but whose machine may be too busy to pass the answer on within a real device's bound (CI runs every test at once).
    var patience: Double = 1

    func seconds(_ value: Double) -> Duration { Self.duration(value * scale) }

    /// At most a year: a configured interval can be any number, and a larger one would trap converting to `Int`.
    private static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int(min(max(0, seconds.isNaN ? 0 : seconds), 365 * 86_400) * 1000))
    }

    /// A bound on a wait for the device (a connection, a reply), never scaled: tests' fakes answer or refuse at once, and a
    /// scaled one (30 ms of 15 s) is shorter than a loaded machine takes to pass a reply on.
    func timeout(_ value: Double) -> Duration { Self.duration(value * patience) }
}

/// What a Baichuan session reports to its host.
enum BaichuanSessionEvent: Sendable, Equatable {
    case push(ReolinkPush)
    /// Push is active (an event came since the subscription), or lost (the connection closed).
    case active(Bool)
}

/// What a binary sink gets: a message's status and payload, or the end of the connection.
enum BaichuanBinaryEvent: Sendable, Equatable {
    case data(status: UInt16?, payload: [UInt8])
    case closed
}

/// A battery camera waking answers 400 (ReolinkBattery.md 3.1): asked again 1.5 s later, up to 3 times. One per request
/// (the session's) or per TalkConfig (ReolinkTalk.md 7, the session not retrying it), so that one layer retries.
struct BaichuanWaking: Sendable {
    static let retries = 3
    static let delay: Double = 1.5
    private var attempts = 0

    /// True, once the delay passed, when `status` is a 400 to ask again.
    mutating func retry(after status: UInt16?, timing: ReolinkTiming) async throws -> Bool {
        guard status == 400, attempts < Self.retries else { return false }
        attempts += 1
        try await Task.sleep(for: timing.seconds(Self.delay))
        return true
    }
}

/// One Baichuan TCP session to a host (5.3): nonce, login, the event subscription and its keepalive, reconnects with
/// `Backoff` and logins at most every 15 seconds, and the siren command. Its events come in `events`.
actor BaichuanSession {
    typealias Connect = @Sendable (_ host: String, _ port: Int, _ timeout: Duration) async throws -> any ByteStream
    typealias BinarySink = @Sendable (BaichuanBinaryEvent) -> Void

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
    let log: Logger
    let timing: ReolinkTiming
    /// Bounds on the TCP connect and the nonce's reply, in seconds (a battery camera's are shorter, ReolinkBattery.md 3.3).
    private let connectTimeout: Double
    private let nonceTimeout: Double
    /// Whether a status 400 (a battery camera waking) is retried, as `BaichuanWaking` says (3.1).
    private let retriesWaking: Bool

    private var stream: (any ByteStream)?
    private var counter: UInt32 = 0
    private var aesKey: [UInt8]?
    /// The requests waiting for their reply, each with the order it was sent in.
    private var pending: [Key: (order: UInt64, waiter: CheckedContinuation<BaichuanMessage, any Error>)] = [:]
    private var sent: UInt64 = 0
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
    /// The login reply's `DeviceInfo` (5.3.2): the device's type and, on a camera with privacy mode, `sleep`.
    private(set) var deviceInfo: BXElement?
    /// Who waits for the first connection attempt to end (`waitUntilReady`).
    private let readyWaiters = Waiters<Bool>()
    private var attempted = false
    /// The nonce reply said "full AES" (`12 dd`): the first `encryptLen` bytes of a binary payload are AES (4.4).
    private(set) var fullAES = false
    /// Who takes the binary messages of a request in binary mode (4.2): by request, or by `cmd_id` alone (snapshots).
    private var binarySinks: [Key: BinarySink] = [:]
    private var commandSinks: [UInt32: BinarySink] = [:]
    /// An `openOnce` session: its events end with its connection.
    private var onDemand = false

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

    init(host: String, port: Int, username: String, password: String, connect: @escaping Connect, log: Logger, timing: ReolinkTiming,
         connectTimeout: Double = 10, nonceTimeout: Double = 10, retriesWaking: Bool = false) {
        self.connectTimeout = connectTimeout
        self.nonceTimeout = nonceTimeout
        self.retriesWaking = retriesWaking
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
    /// Logged in, subscribed or not (an on-demand session, `openOnce`).
    var isOpen: Bool { stream != nil && aesKey != nil }

    /// Connects and logs in once, without the event subscription or reconnects: a battery camera's on-demand session
    /// (ReolinkBattery.md 3.2). `stop` logs out and closes it.
    func openOnce() async throws {
        onDemand = true
        do {
            try await open()
            firstAttemptEnded(true)
        } catch {
            close()
            firstAttemptEnded(false)
            throw error
        }
    }

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
                firstAttemptEnded(true)
                attempt = 0
                wasActive = await serve()
            } catch is CancellationError {
                break
            } catch {
                if !failing {
                    log.warning("Baichuan push unavailable: \(error). Falling back to polling, retrying in the background.")
                }
                failing = true
                firstAttemptEnded(false)
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

    /// Waits for the session to be logged in and subscribed: true once it is, false when the first attempt failed or
    /// `timeout` passed.
    func waitUntilReady(timeout: Duration) async -> Bool {
        if isConnected { return true }
        if attempted || stopped { return false }
        return await readyWaiters.wait(timeout: timeout, fallback: false)
    }

    /// The first attempt ended (or the session stopped): who waits for it hears how.
    private func firstAttemptEnded(_ ok: Bool) {
        attempted = true
        readyWaiters.resumeAll(ok)
    }

    /// Logs out (5.3.4) and closes; `run` ends.
    func stop() async {
        stopped = true
        readyWaiters.resumeAll(false)
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
        for (_, request) in pending { request.waiter.resume(throwing: BaichuanError.closed) }
        pending = [:]
        for sink in binarySinks.values { sink(.closed) }
        for sink in commandSinks.values { sink(.closed) }
        binarySinks = [:]
        commandSinks = [:]
        keepaliveWait?.cancel()
        if onDemand { continuation.finish() }
        if let stream { Task { await stream.close() } }
    }

    // MARK: Login (5.3.1, 5.3.2)

    private func open() async throws {
        if let lastLogin {
            let wait = timing.seconds(Self.loginSpacing) - (ContinuousClock.now - lastLogin)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastLogin = ContinuousClock.now
        let stream = try await connect(host, port, timing.timeout(connectTimeout))
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
        let nonceReply = try await send(Baichuan.nonceRequest(counter: counter), key: Key(command: 1, channel: Baichuan.hostChannel, counter: counter), timeout: nonceTimeout)
        fullAES = nonceReply.encryptionCode == 0x12
        let nonceXML = try BaichuanDecoder.decrypt(nonceReply.body, expected: nonceReply.declaredEncryption ?? .xor, offset: nonceReply.channel, key: nil)
        guard let root = try? BXParser.parse(nonceXML), let nonce = root.first("nonce")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !nonce.isEmpty
        else { throw BaichuanError.noNonce }
        let accountDevice = root.first("sigVer")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "v3"

        let body = Baichuan.loginBody(username: username, password: password, nonce: nonce)
        log.trace("Baichuan login: \(body.utf8.count) bytes")
        do {
            let reply = try await request(command: 1, channel: Baichuan.hostChannel, body: body, encryption: .xor)
            let xml = try? BaichuanDecoder.decrypt(reply.body, expected: reply.declaredEncryption ?? .xor, offset: reply.channel, key: nil)
            deviceInfo = xml.flatMap { try? BXParser.parse($0) }?.first("DeviceInfo")
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

    /// The next message number, for a request that sets bytes 13 to 15 itself (media, ReolinkBattery.md 4.1).
    func nextCounter() -> UInt32 {
        counter = (counter + 1) & 0xFF_FFFF
        return counter
    }

    /// Sends a request and waits for its reply (the same `cmd_id` and full message id). A status other than 200, 201 or
    /// 300 throws `status`, unless `anyStatus` hands the reply back whatever its status (a Talk's 422, ReolinkTalk.md 8);
    /// a 400 is sent again first when the session `retriesWaking`, unless `retryWaking` is false (a caller with retries of
    /// its own: a Talk's, so that one layer retries). `fixedCounter` gives bytes 13 to 15 (media messages:
    /// the stream code, then a 16-bit number; a Talk's audio, one number for all of it). `binary` follows the extension
    /// and the body in clear (ReolinkTalk.md 3.2).
    @discardableResult
    func request(command: UInt32, channel: UInt8, extension ext: String? = nil, body: String?, binary: [UInt8] = [], encryption: BaichuanEncryption,
                 timeout: Double = requestTimeout, fixedCounter: UInt32? = nil, anyStatus: Bool = false,
                 retryWaking: Bool = true) async throws -> BaichuanMessage {
        var waking = BaichuanWaking()
        while true {
            let reply = try await requestOnce(command: command, channel: channel, extension: ext, body: body, binary: binary, encryption: encryption,
                                              timeout: timeout, fixedCounter: fixedCounter)
            let status = reply.status ?? 200
            if retriesWaking, retryWaking, try await waking.retry(after: status, timing: timing) {
                log.debug("Baichuan \(command): the camera is waking up, asked again.")
                continue
            }
            if !anyStatus, ![200, 201, 300].contains(status) { throw BaichuanError.status(status) }
            return reply
        }
    }

    private func requestOnce(command: UInt32, channel: UInt8, extension ext: String?, body: String?, binary: [UInt8], encryption: BaichuanEncryption,
                             timeout: Double, fixedCounter: UInt32?) async throws -> BaichuanMessage {
        guard stream != nil else { throw BaichuanError.closed }
        let counter = fixedCounter ?? nextCounter()
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
        let message = Baichuan.header(command: command, bodyLength: extBytes.count + bodyBytes.count + binary.count, channel: channel, counter: counter,
                                      extensionLength: extBytes.count) + extBytes + bodyBytes + binary
        guard message.count <= Baichuan.maximumRequest else { throw BaichuanError.requestTooLarge(message.count) }
        return try await send(message, key: Key(command: command, channel: channel, counter: counter), timeout: timeout)
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
            pending[key]?.waiter.resume(throwing: BaichuanError.closed)
            sent += 1
            pending[key] = (sent, waiter)
            Task {
                do { try await stream.send(bytes) } catch { self.fail(key, error) }
            }
        }
    }

    private func expire(_ key: Key) { pending.removeValue(forKey: key)?.waiter.resume(throwing: BaichuanError.timeout) }
    private func fail(_ key: Key, _ error: any Error) { pending.removeValue(forKey: key)?.waiter.resume(throwing: error) }

    // MARK: Received

    private func received(_ results: [Result<BaichuanMessage, BaichuanError>]) {
        lastReceive = .now
        for result in results {
            switch result {
            case .failure(let error):
                log.debug("Baichuan: \(error)")
                // An unparsed reply fails the oldest waiting request rather than leaving it to time out.
                if error == .legacyReply, let key = pending.min(by: { $0.value.order < $1.value.order })?.key { fail(key, error) }
            case .success(let message):
                let key = Key(command: message.command, messageID: message.messageID)
                if let request = pending.removeValue(forKey: key) {
                    // A reply in binary mode carries the first bytes itself: the sink gets them before what follows.
                    if let sink = binarySinks[key] ?? commandSinks[message.command] {
                        let ext = Baichuan.BinaryExtension(extensionText(of: message))
                        if ext.isBinary {
                            let payload = binaryPayload(of: message, encryptLength: ext.encryptLength)
                            if !payload.isEmpty || message.status == 201 { sink(.data(status: message.status, payload: payload)) }
                        }
                    }
                    request.waiter.resume(returning: message)
                } else if let sink = binarySinks[key] ?? commandSinks[message.command] {
                    sink(.data(status: message.status, payload: binaryPayload(of: message)))
                } else {
                    handlePush(message)
                }
            }
        }
    }

    /// A message no request or sink takes: a push the plugin parses, or dropped quietly (the 234s that follow a reply,
    /// what a stopped stream still sends: media, a snapshot's parts).
    private func handlePush(_ message: BaichuanMessage) {
        guard BaichuanEvents.pushCommands.contains(message.command) else { return }
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

    /// A channel command (the channel extension, `ch_id` channel + 1) and its reply's XML text; "" for an empty reply.
    func channelRequest(command: UInt32, channel: Int, body: String? = nil) async throws -> String {
        let reply = try await request(command: command, channel: UInt8(clamping: channel + 1), extension: Baichuan.channelExtension(channel), body: body, encryption: .aes)
        return try replyText(reply)
    }

    // MARK: Binary mode (ReolinkBattery.md 4.2, 4.4)

    /// Hands the binary messages of a request (its `cmd_id` and full message id) to `sink` until `removeBinarySink`. Set
    /// before the request is sent, so nothing that follows its reply is missed.
    func setBinarySink(command: UInt32, channel: UInt8, counter: UInt32, _ sink: @escaping BinarySink) {
        binarySinks[Key(command: command, channel: channel, counter: counter)] = sink
    }

    /// Stops handing a stream's messages on; what it still sends is dropped.
    func removeBinarySink(command: UInt32, channel: UInt8, counter: UInt32) {
        binarySinks.removeValue(forKey: Key(command: command, channel: channel, counter: counter))
    }

    /// Hands every message of a `cmd_id` that answers no request to `sink` (a snapshot's parts come on any message
    /// number); false when one is set already.
    func setCommandSink(_ command: UInt32, _ sink: @escaping BinarySink) -> Bool {
        guard commandSinks[command] == nil else { return false }
        commandSinks[command] = sink
        return true
    }

    func removeCommandSink(_ command: UInt32) { commandSinks.removeValue(forKey: command) }

    /// A message's binary payload: what follows its extension (all of the body without one), its first `encryptLen`
    /// bytes AES-decrypted in a full-AES session.
    func binaryPayload(of message: BaichuanMessage) -> [UInt8] {
        guard fullAES, aesKey != nil, !message.extensionBytes.isEmpty else { return message.body }
        return binaryPayload(of: message, encryptLength: Baichuan.BinaryExtension(extensionText(of: message)).encryptLength)
    }

    /// The payload with the extension's `encryptLen` already read: the prefix decrypted into the one copy of the body.
    private func binaryPayload(of message: BaichuanMessage, encryptLength: Int?) -> [UInt8] {
        let body = message.body
        guard fullAES, let aesKey, let length = encryptLength, length > 0 else { return body }
        let count = min(length, body.count)
        guard let clear = try? Baichuan.aes(body[..<count], key: aesKey, decrypt: true) else { return body }
        var payload = clear
        payload.reserveCapacity(body.count)
        payload += body[count...]
        return payload
    }

    /// A message's extension as XML; nil without one.
    func extensionText(of message: BaichuanMessage) -> String? {
        guard !message.extensionBytes.isEmpty else { return nil }
        return try? BaichuanDecoder.decrypt(message.extensionBytes, expected: .aes, offset: message.channel, key: aesKey)
    }

    /// A reply's XML: its body, or its extension when it has no body.
    func replyText(_ reply: BaichuanMessage) throws -> String {
        let piece = reply.body.isEmpty ? reply.extensionBytes : reply.body
        return try BaichuanDecoder.decrypt(piece, expected: reply.declaredEncryption ?? .aes, offset: reply.channel, key: aesKey)
    }

    /// The abilities of `cmd_id` 199 by channel (addendum A.2): each list's `item` elements, by `chnID`, with every
    /// other child an ability and its integer text the version.
    func abilities() async throws -> [Int: [String: Int]] {
        let reply = try await request(command: 199, channel: Baichuan.hostChannel, body: nil, encryption: .aes)
        let xml = try replyText(reply)
        guard !xml.isEmpty, let root = try? BXParser.parse(xml) else { return [:] }
        return BaichuanEvents.abilities(root)
    }

    /// The floodlight task (`cmd_id` 289) with `changes` made to its children, sent back whole (`cmd_id` 290).
    func updateFloodlightTask(channel: Int, changes: [String: String]) async throws {
        var xml = try await channelRequest(command: 289, channel: channel)
        guard xml.contains("<FloodlightTask") else { throw BaichuanError.undecryptable }
        for (name, value) in changes {
            guard let changed = Baichuan.replacingText(of: name, with: value, in: xml) else { throw ReolinkError.unsupported(name) }
            xml = changed
        }
        _ = try await channelRequest(command: 290, channel: channel, body: xml)
    }

    /// Privacy mode (addendum C, `cmd_id` 574): the reply's `sleep`; nil when it has none (the device has no privacy mode).
    func privacy(channel: Int) async throws -> Bool? {
        let xml = try await channelRequest(command: 574, channel: channel)
        guard !xml.isEmpty, let sleep = (try? BXParser.parse(xml))?.first("sleep")?.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return sleep == "1"
    }

    /// Turns privacy mode on or off (`cmd_id` 575), then reads it again.
    func setPrivacy(channel: Int, on: Bool) async throws -> Bool? {
        _ = try await channelRequest(command: 575, channel: channel, body: Baichuan.privacyBody(on))
        return try await privacy(channel: channel)
    }

    /// Whether a patrol runs on the channel (`cmd_id` 64): any `cruising` element of the reply is 1.
    func patrolRunning(channel: Int) async throws -> Bool {
        let xml = try await channelRequest(command: 64, channel: channel)
        guard !xml.isEmpty, let root = try? BXParser.parse(xml) else { return false }
        return root.all("cruising").contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
    }

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
