import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The HomeKit Data Stream TCP server of one accessory (HAP-NodeJS's DataStreamServer).
///
/// A controller asks for a session through Setup Data Stream Transport on its HAP connection; the server derives
/// the session keys from that connection's shared secret, listens (on a port the system picks) and tells the
/// controller where to connect. The first frame on a new socket tells which prepared session it belongs to: the
/// one whose key opens it. The server stops listening when it has no session left, as HAP-NodeJS does.
final class DataStreamServer: @unchecked Sendable {
    static let version = "1.0"

    typealias RequestHandler = @Sendable (DataStreamConnection, Int64, HDSDictionary) -> Void

    struct PreparedSession {
        let id = UUID()
        let context: HAPRequestContext
        let accessoryToControllerKey: SymmetricKey
        let controllerToAccessoryKey: SymmetricKey
        let accessoryKeySalt: Data
        var timeout: Task<Void, Never>?
    }

    private struct State {
        var channel: (any Channel)?
        var binding: Task<Int, any Error>?
        var preparedSessions: [PreparedSession] = []
        var connections: [ObjectIdentifier: DataStreamConnection] = [:]
        var requestHandlers: [String: [RequestHandler]] = [:]
        var destroyed = false
    }

    private let state = NIOLockedValueBox(State())
    let logger: Logger
    /// How long a prepared session waits for its socket (10 s, as HAP-NodeJS).
    let connectTimeout: Duration

    init(logger: Logger = Logger(label: "homeswift.datastream"), connectTimeout: Duration = .seconds(10)) {
        self.logger = logger
        self.connectTimeout = connectTimeout
    }

    /// The listening port, while listening.
    var port: Int? { state.withLockedValue { $0.channel?.localAddress?.port } }

    func onRequestMessage(_ proto: String, _ topic: String, _ handler: @escaping RequestHandler) {
        state.withLockedValue { $0.requestHandlers[proto + "-r-" + topic, default: []].append(handler) }
    }

    /// Derives the keys of a new session for the HAP connection and makes sure the server listens. Returns the port
    /// and the accessory's salt for the Setup Data Stream Transport response.
    func prepareSession(context: HAPRequestContext, sharedSecret: Data, controllerKeySalt: Data) async throws -> (port: Int, accessoryKeySalt: Data) {
        let salt = Secrets.randomBytes(32)
        let keys = HDSFrame.keys(sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt, accessoryKeySalt: salt)
        var session = PreparedSession(
            context: context, accessoryToControllerKey: keys.accessoryToController, controllerToAccessoryKey: keys.controllerToAccessory,
            accessoryKeySalt: salt)
        let id = session.id
        let timeout = connectTimeout
        session.timeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.timeoutPreparedSession(id)
        }
        state.withLockedValue { $0.preparedSessions.append(session) }
        do {
            return (try await listen(), salt)
        } catch {
            timeoutPreparedSession(id)
            throw error
        }
    }

    private func timeoutPreparedSession(_ id: UUID) {
        let removed = state.withLockedValue { state -> Bool in
            guard let index = state.preparedSessions.firstIndex(where: { $0.id == id }) else { return false }
            state.preparedSessions.remove(at: index)
            return true
        }
        if removed { checkCloseable() }
    }

    /// Binds once; concurrent callers wait for the same bind.
    private func listen() async throws -> Int {
        let task = state.withLockedValue { state -> Task<Int, any Error> in
            if let binding = state.binding { return binding }
            let binding = Task<Int, any Error> { [weak self] in
                guard let self else { throw ChannelError.ioOnClosedChannel }
                let channel = try await self.bind()
                let port = channel.localAddress?.port ?? 0
                self.logger.debug("Data stream server listening", metadata: ["port": "\(port)"])
                return port
            }
            state.binding = binding
            return binding
        }
        return try await task.value
    }

    private func bind() async throws -> any Channel {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                let connection = DataStreamConnection(channel: channel, server: self)
                self.state.withLockedValue { $0.connections[ObjectIdentifier(connection)] = connection }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(connection.inboundHandler)
                    Task { await connection.run() }
                }
            }
        var channel: (any Channel)?
        for host in ["::", "0.0.0.0"] where channel == nil {
            channel = try? await bootstrap.bind(host: host, port: 0).get()
        }
        guard let channel else { throw ChannelError.ioOnClosedChannel }
        let keep = state.withLockedValue { state -> Bool in
            guard !state.destroyed else { return false }
            state.channel = channel
            return true
        }
        if !keep {
            try? await channel.close()
            throw ChannelError.ioOnClosedChannel
        }
        return channel
    }

    /// The prepared session whose controller-to-accessory key opens the first frame of a new socket.
    func identify(_ frame: HDSFrame.Sealed) -> (PreparedSession, Data)? {
        let sessions = state.withLockedValue { $0.preparedSessions }
        for session in sessions {
            if let plaintext = try? HDSFrame.open(frame, key: session.controllerToAccessoryKey, counter: 0) {
                state.withLockedValue { $0.preparedSessions.removeAll { $0.id == session.id } }
                session.timeout?.cancel()
                return (session, plaintext)
            }
        }
        return nil
    }

    /// Dispatches a message no protocol handler of the connection took.
    func handleMessageGlobally(_ connection: DataStreamConnection, _ message: HDSFrame.Message) {
        switch message.kind {
        case .event:
            logger.debug("No handler for data stream event", metadata: ["protocol": "\(message.protocol)", "topic": "\(message.topic)"])
        case .request(let id):
            let handlers = state.withLockedValue { $0.requestHandlers[message.protocol + "-r-" + message.topic] ?? [] }
            if handlers.isEmpty { logger.debug("No handler for data stream request", metadata: ["protocol": "\(message.protocol)", "topic": "\(message.topic)"]) }
            for handler in handlers { handler(connection, id, message.message) }
        case .response:
            break
        }
    }

    func connectionClosed(_ connection: DataStreamConnection) {
        state.withLockedValue { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        checkCloseable()
    }

    /// Stops listening once no session is prepared or connected.
    private func checkCloseable() {
        let channel = state.withLockedValue { state -> (any Channel)? in
            guard state.connections.isEmpty, state.preparedSessions.isEmpty, let channel = state.channel else { return nil }
            state.channel = nil
            state.binding = nil
            return channel
        }
        channel?.close(promise: nil)
    }

    /// Closes the server and every connection; handlers are dropped.
    func destroy() {
        let (channel, connections, sessions) = state.withLockedValue { state in
            state.destroyed = true
            defer {
                state.channel = nil
                state.binding = nil
                state.preparedSessions = []
                state.requestHandlers = [:]
            }
            return (state.channel, Array(state.connections.values), state.preparedSessions)
        }
        sessions.forEach { $0.timeout?.cancel() }
        channel?.close(promise: nil)
        connections.forEach { $0.close() }
    }
}

/// One controller's data stream socket (HAP-NodeJS's DataStreamConnection).
final class DataStreamConnection: @unchecked Sendable {
    enum ConnectionState: Int, Comparable {
        case unidentified, expectingHello, ready, closing, closed
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum ConnectionError: Error, Equatable {
        case closedSocket
        case maxPayloadLength
    }

    /// What one protocol (`dataSend`, ...) handles on this connection, by topic.
    final class ProtocolHandler: Sendable {
        let events: [String: @Sendable (HDSDictionary) -> Void]
        let requests: [String: @Sendable (Int64, HDSDictionary) -> Void]

        init(events: [String: @Sendable (HDSDictionary) -> Void] = [:], requests: [String: @Sendable (Int64, HDSDictionary) -> Void] = [:]) {
            self.events = events
            self.requests = requests
        }
    }

    final class InboundHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<ByteBuffer>.Continuation
        init(continuation: AsyncStream<ByteBuffer>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { continuation.yield(unwrapInboundIn(data)) }
        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
    }

    private struct State {
        var state = ConnectionState.unidentified
        var readKey: SymmetricKey?
        var writeKey: SymmetricKey?
        var readCounter: UInt64 = 0
        var writeCounter: UInt64 = 0
        var protocolHandlers: [String: ProtocolHandler] = [:]
        var closeHandlers: [@Sendable () -> Void] = []
        var helloTimer: Task<Void, Never>?
    }

    let channel: any Channel
    weak var server: DataStreamServer?
    let remoteAddress: String
    let inboundHandler: InboundHandler
    private let stream: AsyncStream<ByteBuffer>
    private let state = NIOLockedValueBox(State())
    private var buffer = Data()

    init(channel: any Channel, server: DataStreamServer) {
        self.channel = channel
        self.server = server
        remoteAddress = HAPConnection.plainAddress(channel.remoteAddress?.ipAddress) ?? "?"
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        self.stream = stream
        inboundHandler = InboundHandler(continuation: continuation)
        let helloTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close()
        }
        state.withLockedValue { $0.helloTimer = helloTimer }
        _ = addProtocolHandler("control", ProtocolHandler(requests: [
            "hello": { [weak self] id, _ in self?.handleHello(id) }
        ]))
    }

    var isConsideredClosed: Bool { state.withLockedValue { $0.state >= .closing } }

    func run() async {
        for await bytes in stream {
            buffer.append(contentsOf: bytes.readableBytesView)
            onSocketData()
        }
        let handlers = state.withLockedValue { state in
            state.state = .closed
            state.helloTimer?.cancel()
            defer { state.closeHandlers = []; state.protocolHandlers = [:] }
            return state.closeHandlers
        }
        for handler in handlers { handler() }
        server?.connectionClosed(self)
    }

    /// Runs `handler` once the socket has closed.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLockedValue { state in
            if state.state != .closed { state.closeHandlers.append(handler) }
            return state.state == .closed
        }
        if closed { handler() }
    }

    func addProtocolHandler(_ proto: String, _ handler: ProtocolHandler) -> Bool {
        state.withLockedValue { state in
            guard state.protocolHandlers[proto] == nil else { return false }
            state.protocolHandlers[proto] = handler
            return true
        }
    }

    func removeProtocolHandler(_ proto: String, _ handler: ProtocolHandler) {
        state.withLockedValue { state in
            if state.protocolHandlers[proto] === handler { state.protocolHandlers[proto] = nil }
        }
    }

    private func handleHello(_ id: Int64) {
        state.withLockedValue { state in
            state.helloTimer?.cancel()
            state.helloTimer = nil
            state.state = .ready
        }
        _ = try? sendResponse("control", "hello", id: id)
    }

    // MARK: Sending

    /// An event; dropped unless the connection is ready, as in HAP-NodeJS. The future completes once written.
    @discardableResult
    func sendEvent(_ proto: String, _ event: String, _ message: HDSDictionary = [:]) throws -> EventLoopFuture<Void>? {
        guard state.withLockedValue({ $0.state == .ready }) else { return nil }
        return try send(header: ["protocol": .string(proto), "event": .string(event)], message: message)
    }

    @discardableResult
    func sendResponse(_ proto: String, _ response: String, id: Int64, status: HDSStatus = .success, _ message: HDSDictionary = [:]) throws -> EventLoopFuture<Void> {
        try send(
            header: ["protocol": .string(proto), "response": .string(response), "id": .int64(id), "status": .int64(status.rawValue)],
            message: message)
    }

    private func send(header: HDSDictionary, message: HDSDictionary) throws -> EventLoopFuture<Void> {
        let payload = HDSFrame.payload(header: header, message: message)
        guard payload.count <= HDSFrame.maxPayloadLength else { throw ConnectionError.maxPayloadLength }
        // Sealed and handed to the channel under the lock: frames leave in nonce order.
        return try state.withLockedValue { state in
            guard state.state < .closing, let key = state.writeKey else { throw ConnectionError.closedSocket }
            let frame = try HDSFrame.seal(payload: payload, key: key, counter: state.writeCounter)
            state.writeCounter += 1
            return channel.writeAndFlush(ByteBuffer(bytes: frame))
        }
    }

    func close() {
        let close = state.withLockedValue { state -> Bool in
            guard state.state < .closing else { return false }
            state.state = .closing
            return true
        }
        if close { channel.close(promise: nil) }
    }

    // MARK: Receiving

    private func onSocketData() {
        guard !isConsideredClosed else { return }
        var frames: [HDSFrame.Sealed]
        do {
            frames = try HDSFrame.split(&buffer)
        } catch {
            close()
            return
        }
        guard !frames.isEmpty else { return }
        var payloads: [Data] = []
        if state.withLockedValue({ $0.state == .unidentified }) {
            let first = frames.removeFirst()
            guard let (session, plaintext) = server?.identify(first) else {
                // The first message was not a valid hello for any prepared session.
                close()
                return
            }
            state.withLockedValue { state in
                state.readKey = session.controllerToAccessoryKey
                state.writeKey = session.accessoryToControllerKey
                state.readCounter = 1
                state.state = .expectingHello
            }
            session.context.onClose { [weak self] in self?.close() }
            payloads.append(plaintext)
        }
        for frame in frames {
            let plaintext = state.withLockedValue { state -> Data? in
                guard let key = state.readKey, let plaintext = try? HDSFrame.open(frame, key: key, counter: state.readCounter) else { return nil }
                state.readCounter += 1
                return plaintext
            }
            guard let plaintext else {
                close()
                return
            }
            payloads.append(plaintext)
        }
        let messages = payloads.compactMap(HDSFrame.message(from:))
        if state.withLockedValue({ $0.state == .expectingHello }) {
            guard let first = messages.first, first.protocol == "control", case .request = first.kind, first.topic == "hello" else {
                close()
                return
            }
        }
        for message in messages { dispatch(message) }
    }

    private func dispatch(_ message: HDSFrame.Message) {
        if case .response = message.kind { return }
        guard let handler = state.withLockedValue({ $0.protocolHandlers[message.protocol] }) else {
            server?.handleMessageGlobally(self, message)
            return
        }
        switch message.kind {
        case .event: handler.events[message.topic]?(message.message)
        case .request(let id): handler.requests[message.topic]?(id, message.message)
        case .response: break
        }
    }
}
