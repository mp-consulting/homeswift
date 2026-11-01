import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One controller's TCP connection.
///
/// Everything that arrives (bytes from the socket, events to push) goes through one queue that a
/// single task drains, so requests, responses and events stay in order and the session counters
/// never race. Only the controller identity and subscriptions are read from other threads.
final class HAPConnection: @unchecked Sendable {
    enum Work {
        case data(ByteBuffer)
        /// Time to send the queued events (`Shared.queuedEvents`) as one message.
        case flushEvents
    }

    /// What to do after a response has gone out.
    enum After {
        case none
        case startSession(SecureSession)
        case closeControllers(Set<String>?)
    }

    struct Shared {
        /// When bytes last came in or went out, for the idle check (`HAPServer.closeIdleConnections`).
        var lastActivity = NIODeadline.now()
        var controllerID: String?
        var subscriptions: Set<CharacteristicKey> = []
        /// The events waiting for `Work.flushEvents`, in the order the values changed.
        var queuedEvents: [CharacteristicJSON] = []
        /// Whether a flush is on its way, so a burst of changes schedules one.
        var flushScheduled = false
        /// When the last event message went, for `HAPServer.Options.minimumEventInterval`.
        var lastEventSent = NIODeadline.distantPast
        var closeHandlers = CloseHandlers()
        var closed = false
    }

    final class InboundHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<Work>.Continuation

        init(continuation: AsyncStream<Work>.Continuation) { self.continuation = continuation }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(.data(unwrapInboundIn(data)))
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }

    let channel: any Channel
    let server: HAPServer
    let shared = NIOLockedValueBox(Shared())
    let inboundHandler: InboundHandler
    private let stream: AsyncStream<Work>
    private let continuation: AsyncStream<Work>.Continuation

    // Only touched by the task in `run()`.
    private var raw = Data()
    private var plain = Data()
    private(set) var session: SecureSession?
    var pairSetup: PairSetupState?
    var pairVerify: PairVerifyState?
    var timedWrite: (pid: UInt64, expires: ContinuousClock.Instant)?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var controllerID: String? { shared.withLockedValue { $0.controllerID } }
    /// Read from the pairings, as HAP-NodeJS does, so a changed permission counts at once: an admin made a user
    /// manages pairings no more, though its session started as an admin's.
    var isAdmin: Bool {
        guard let controllerID else { return false }
        return server.state.withLockedValue { $0.persisted.pairings.first { $0.identifier == controllerID }?.isAdmin ?? false }
    }
    var isVerified: Bool { session != nil }
    var lastActivity: NIODeadline { shared.withLockedValue { $0.lastActivity } }

    /// The largest body before pair verify: pair setup's and pair verify's TLVs take a few hundred bytes, and a
    /// connection nobody verified must not make the server hold a megabyte.
    static let maxUnverifiedBody = 16 * 1024

    init(channel: any Channel, server: HAPServer) {
        self.channel = channel
        self.server = server
        (stream, continuation) = AsyncStream.makeStream(of: Work.self)
        inboundHandler = InboundHandler(continuation: continuation)
    }

    func run() async {
        server.logger.debug("Connection opened", metadata: ["remote": "\(channel.remoteAddress.map { "\($0)" } ?? "?")"])
        for await work in stream {
            switch work {
            case .data(let buffer):
                shared.withLockedValue { $0.lastActivity = .now() }
                raw.append(contentsOf: buffer.readableBytesView)
                await processInbound()
            case .flushEvents:
                // Behind any request in progress, as HAP-NodeJS holds events while it answers one.
                let events = shared.withLockedValue { shared in
                    defer {
                        shared.queuedEvents = []
                        shared.flushScheduled = false
                    }
                    // A subscription dropped in the meantime hears nothing more.
                    return shared.queuedEvents.filter { shared.subscriptions.contains(CharacteristicKey(aid: $0.aid ?? 0, iid: $0.iid)) }
                }
                guard session != nil, !events.isEmpty else { continue }
                shared.withLockedValue { $0.lastEventSent = .now() }
                write(HTTPResponse.json(200, CharacteristicsJSON(characteristics: events)).serialized(protocol: "EVENT/1.0"))
            }
        }
        server.unregister(self)
        let handlers = shared.withLockedValue { shared in
            shared.closed = true
            return shared.closeHandlers.takeAll()
        }
        for handler in handlers { handler() }
        server.logger.debug("Connection closed", metadata: ["controller": "\(controllerID ?? "-")"])
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Runs `handler` once the connection has closed (at once when it already has): camera streams and data
    /// streams end with the controller connection that set them up. Returns the token for `removeCloseHandler(_:)`,
    /// nil when the handler already ran.
    @discardableResult
    func onClose(_ handler: @escaping @Sendable () -> Void) -> Int? {
        let token = shared.withLockedValue { shared -> Int? in
            guard !shared.closed else { return nil }
            return shared.closeHandlers.add(handler)
        }
        if token == nil { handler() }
        return token
    }

    /// Drops a close handler whose stream or session ended before the connection.
    func removeCloseHandler(_ token: Int) {
        shared.withLockedValue { $0.closeHandlers.remove(token) }
    }

    /// What handlers may know of this connection while they serve one of its requests.
    var requestContext: HAPRequestContext {
        let controllerID = controllerID
        let isAdmin = isAdmin
        return HAPRequestContext(
            connectionID: id, controllerID: controllerID, isAdmin: isAdmin,
            localAddress: Self.plainAddress(channel.localAddress?.ipAddress), remoteAddress: Self.plainAddress(channel.remoteAddress?.ipAddress),
            sharedSecret: session?.sharedSecret, connection: self)
    }

    /// An IPv4 client of the dual-stack socket shows as `::ffff:a.b.c.d`; streams want the IPv4 address.
    static func plainAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        if address.lowercased().hasPrefix("::ffff:"), address.contains(".") { return String(address.dropFirst(7)) }
        return address
    }

    /// Queues an event for a characteristic this connection subscribed to, sent with the others queued within `delay`
    /// as one `EVENT/1.0` message (HAP-NodeJS's `HAPConnection.sendEvent`), and no sooner than `interval` after the
    /// previous message (the ADK's rate limit). The same value queued twice in a row goes once; a different one is
    /// kept, for the automations it triggers. `immediate` sends the queue now.
    func queueEvent(_ key: CharacteristicKey, value: HAPValue, immediate: Bool, delay: TimeAmount, interval: TimeAmount) {
        enum Next { case none, schedule(TimeAmount), flush }
        let now = NIODeadline.now()
        let next = shared.withLockedValue { shared -> Next in
            guard shared.subscriptions.contains(key) else { return .none }
            if !immediate, let last = shared.queuedEvents.last(where: { $0.aid == key.aid && $0.iid == key.iid }), last.value == value {
                return .none
            }
            shared.queuedEvents.append(CharacteristicJSON(aid: key.aid, iid: key.iid, value: value))
            let wait = max(delay, shared.lastEventSent + interval - now)
            if immediate || wait <= .zero { return .flush }
            guard !shared.flushScheduled else { return .none }
            shared.flushScheduled = true
            return .schedule(wait)
        }
        switch next {
        case .none:
            break
        case .flush:
            continuation.yield(.flushEvents)
        case .schedule(let wait):
            let continuation = continuation
            channel.eventLoop.scheduleTask(in: wait) { continuation.yield(.flushEvents) }
        }
    }

    func isSubscribed(to key: CharacteristicKey) -> Bool {
        shared.withLockedValue { $0.subscriptions.contains(key) }
    }

    func setSubscribed(_ subscribed: Bool, to key: CharacteristicKey) {
        shared.withLockedValue {
            if subscribed { $0.subscriptions.insert(key) } else { $0.subscriptions.remove(key) }
        }
    }

    func setController(_ identifier: String) {
        shared.withLockedValue { $0.controllerID = identifier }
    }

    private func processInbound() async {
        do {
            try drainRaw()
            while let request = try HTTPRequest.parse(&plain, maxBody: isVerified ? HTTPRequest.maxBody : Self.maxUnverifiedBody) {
                let (response, after) = await handle(request)
                write(response.serialized())
                switch after {
                case .none:
                    break
                case .startSession(let newSession):
                    session = newSession
                    // Anything already buffered after the verify request is encrypted.
                    raw = plain + raw
                    plain = Data()
                    try drainRaw()
                case .closeControllers(let controllers):
                    server.closeConnections(controllers: controllers)
                }
            }
        } catch {
            server.logger.debug("Dropping connection", metadata: ["error": "\(error)"])
            close()
        }
    }

    private func drainRaw() throws {
        if session != nil {
            plain.append(try session!.decrypt(&raw))
        } else {
            plain.append(raw)
            raw = Data()
        }
    }

    private func write(_ data: Data) {
        shared.withLockedValue { $0.lastActivity = .now() }
        do {
            let out = session != nil ? try session!.encrypt(data) : data
            channel.writeAndFlush(ByteBuffer(bytes: out), promise: nil)
        } catch {
            close()
        }
    }

    /// A request body for the trace log: pairing bodies as their size, and in characteristic writes the values of
    /// confidential characteristics (Setup Endpoints carries SRTP master keys) as their size.
    static func traceBody(_ request: HTTPRequest, isConfidential: (_ aid: Int, _ iid: Int) -> Bool) -> String {
        if request.path.hasPrefix("/pair") { return "<\(request.body.count) bytes>" }
        let text = String(decoding: request.body, as: UTF8.self)
        guard request.path == "/characteristics", !request.body.isEmpty else { return text }
        guard var object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
            var items = object["characteristics"] as? [[String: Any]]
        else { return "<\(request.body.count) bytes>" }
        var redacted = false
        for index in items.indices {
            guard let value = items[index]["value"], let aid = items[index]["aid"] as? Int, let iid = items[index]["iid"] as? Int,
                isConfidential(aid, iid)
            else { continue }
            items[index]["value"] = "<\((value as? String)?.utf8.count ?? 0) bytes>"
            redacted = true
        }
        guard redacted else { return text }
        object["characteristics"] = items
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "<\(request.body.count) bytes>" }
        return String(decoding: data, as: UTF8.self)
    }

    private func handle(_ request: HTTPRequest) async -> (HTTPResponse, After) {
        if server.logger.logLevel <= .trace {
            let server = server
            server.logger.trace("Request", metadata: [
                "method": "\(request.method)", "target": "\(request.target)",
                "body": "\(Self.traceBody(request) { server.characteristic(aid: $0, iid: $1)?.isConfidential ?? false })",
            ])
        }
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            return (handlePairSetup(request.body), .none)
        case ("POST", "/pair-verify"):
            return handlePairVerify(request.body)
        case ("POST", "/identify"):
            return (await handleIdentify(), .none)
        default:
            break
        }

        guard isVerified else {
            return (.hapStatus(470, .insufficientPrivileges), .none)
        }

        switch (request.method, request.path) {
        case ("POST", "/pairings"):
            return handlePairings(request.body)
        case ("GET", "/accessories"):
            return (HTTPResponse(status: 200, contentType: HTTPResponse.hapJSON, body: Data(server.accessoriesBody())), .none)
        case ("GET", "/characteristics"):
            return (await handleRead(request.query), .none)
        case ("PUT", "/characteristics"):
            return (await handleWrite(request.body), .none)
        case ("PUT", "/prepare"):
            return (handlePrepare(request.body), .none)
        case (_, "/resource"):
            return (await handleResource(request), .none)
        default:
            return (HTTPResponse(status: 404), .none)
        }
    }
}
