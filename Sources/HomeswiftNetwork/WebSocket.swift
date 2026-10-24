import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// One WebSocket message: text (UTF-8) or binary.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    /// The message's bytes, the UTF-8 of a text message.
    public var data: Data {
        switch self {
        case .text(let text): Data(text.utf8)
        case .binary(let data): data
        }
    }

    /// The message as text: a text message, or a binary one that is valid UTF-8.
    public var text: String? {
        switch self {
        case .text(let text): text
        case .binary(let data): String(data: data, encoding: .utf8)
        }
    }
}

public enum WebSocketError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidURL(String)
    /// The connection failed before the handshake. `code` is the errno when the system gave one.
    case cannotConnect(host: String, port: Int, code: Int32?, reason: String)
    /// The server answered the upgrade request with this status instead of 101.
    case handshakeFailed(status: Int)
    /// The server chose a subprotocol the client did not offer.
    case unexpectedSubprotocol(String)
    case timeout
    /// The peer sent nothing, not even a pong, for a whole heartbeat interval.
    case heartbeatTimeout
    /// A message larger than `Options.maximumMessageSize`.
    case messageTooLarge(limit: Int)
    /// The connection dropped without a close frame.
    case connectionLost
    /// A send after the connection closed.
    case notConnected
    case protocolError(String)

    public var description: String {
        switch self {
        case .invalidURL(let url): "cannot open a WebSocket to \(url)"
        case .cannotConnect(let host, let port, _, let reason): "cannot connect to \(host):\(port): \(reason)"
        case .handshakeFailed(let status): "the server refused the WebSocket upgrade (HTTP \(status))"
        case .unexpectedSubprotocol(let name): "the server chose a subprotocol that was not offered (\(name))"
        case .timeout: "the WebSocket handshake timed out"
        case .heartbeatTimeout: "the server stopped answering pings"
        case .messageTooLarge(let limit): "a message is larger than \(limit) bytes"
        case .connectionLost: "the connection dropped"
        case .notConnected: "the WebSocket is closed"
        case .protocolError(let reason): "WebSocket protocol error: \(reason)"
        }
    }
}

/// An open WebSocket: the real client, or a fake server in a plugin's tests.
public protocol WebSocketConnection: AnyObject, Sendable {
    /// Incoming messages, for one reader. Ends when the connection closes with a close frame (see
    /// `closeCode`), and throws when it drops (`WebSocketError.connectionLost`, `.heartbeatTimeout`, …).
    var messages: AsyncThrowingStream<WebSocketMessage, any Error> { get }
    func send(_ message: WebSocketMessage) async throws
    /// Sends a ping and waits for the pong.
    func ping(timeout: Duration) async throws
    /// Sends a close frame, waits briefly for the server's, then closes the connection.
    func close(code: UInt16, reason: String) async
    /// The code and reason of the close frame the server sent (or that answered ours), once closed; nil before,
    /// and for a connection that dropped without one.
    var closeCode: UInt16? { get }
    var closeReason: String? { get }
}

extension WebSocketConnection {
    public var closeCode: UInt16? { nil }
    public var closeReason: String? { nil }
    public func send(text: String) async throws { try await send(.text(text)) }
    public func send(binary: Data) async throws { try await send(.binary(binary)) }
    public func close() async { await close(code: 1000, reason: "") }
}

/// A WebSocket client (RFC 6455) on NIO: `ws` and `wss`, custom headers (cookies, tokens), subprotocols, the
/// TLS modes of `HTTPClient` plus client certificates, fragmented messages, ping/pong and an optional heartbeat.
///
/// ```swift
/// var options = WebSocket.Options(tls: TLSOptions(trust: .any))
/// options.headers = [("Cookie", "TOKEN=\(token)")]
/// options.heartbeat = .seconds(10)
/// let socket = try await WebSocket.connect(to: URL(string: "wss://192.168.1.1/proxy/protect/ws/updates")!, options: options)
/// Task { for try await message in socket.messages { handle(message) } }
/// try await socket.send(text: #"{"action":"ping"}"#)
/// ```
public final class WebSocket: WebSocketConnection {
    public struct Options: Sendable {
        /// Extra request headers: cookies, authorization, origin, user agent.
        public var headers: [(name: String, value: String)]
        /// Offered in `Sec-WebSocket-Protocol`, e.g. `["mqtt"]`.
        public var subprotocols: [String]
        public var tls: TLSOptions
        /// From the connection attempt to the end of the handshake.
        public var timeout: Duration
        /// When set, a ping goes out every interval and a peer that sent nothing for a whole interval is
        /// declared dead: the stream throws `WebSocketError.heartbeatTimeout`.
        public var heartbeat: Duration?
        /// Larger messages close the connection with 1009 and throw `WebSocketError.messageTooLarge`.
        public var maximumMessageSize: Int

        public init(
            headers: [(name: String, value: String)] = [], subprotocols: [String] = [], tls: TLSOptions = .system,
            timeout: Duration = .seconds(30), heartbeat: Duration? = nil, maximumMessageSize: Int = 64 * 1024 * 1024
        ) {
            self.headers = headers
            self.subprotocols = subprotocols
            self.tls = tls
            self.timeout = timeout
            self.heartbeat = heartbeat
            self.maximumMessageSize = maximumMessageSize
        }
    }

    public let url: URL
    /// The subprotocol the server chose, if any.
    public let subprotocol: String?
    /// The headers of the server's 101 response.
    public let responseHeaders: [(name: String, value: String)]
    /// The SHA-256 fingerprint of the server's certificate for `wss` with trust `.any` or `.pinned`.
    public let certificateFingerprint: String?
    public let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    private let channel: any Channel
    private let core: WebSocketCore

    private init(url: URL, channel: any Channel, core: WebSocketCore, head: HTTPResponseHead, fingerprint: String?) {
        self.url = url
        self.channel = channel
        self.core = core
        self.messages = core.stream
        self.subprotocol = head.headers.first(name: "Sec-WebSocket-Protocol")
        self.responseHeaders = head.headers.map { (name: $0.name, value: $0.value) }
        self.certificateFingerprint = fingerprint
    }

    /// The code of the close frame the server sent (or that answered ours), once closed.
    public var closeCode: UInt16? { core.state.withLockedValue { $0.closeCode } }
    public var closeReason: String? { core.state.withLockedValue { $0.closeReason } }
    public var isOpen: Bool { core.state.withLockedValue { !$0.finished && !$0.closeSent } }

    /// Opens a WebSocket: connects, upgrades, and returns once the server accepted.
    public static func connect(
        to url: URL, options: Options = Options(), group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> WebSocket {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss", let host = url.host, !host.isEmpty else {
            throw WebSocketError.invalidURL(redactingPassword(url))
        }
        let secure = scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        let uri = requestTarget(of: url)
        let deadline = ContinuousClock.now + options.timeout

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: hostHeader(host: host, port: port, defaultPort: secure ? 443 : 80))
        if !options.subprotocols.isEmpty { headers.add(name: "Sec-WebSocket-Protocol", value: options.subprotocols.joined(separator: ", ")) }
        headers.applying(options.headers)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)

        let context = secure ? try options.tls.makeContext() : nil
        let tls = options.tls
        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<(any Error)?>(nil)
        let core = WebSocketCore()
        let eventLoop = group.next()
        let upgraded = eventLoop.makePromise(of: HTTPResponseHead.self)
        let maximumMessageSize = options.maximumMessageSize
        let heartbeat = options.heartbeat

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(TimeAmount(options.timeout))
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context {
                        try channel.pipeline.syncOperations.addHandler(tls.makeHandler(context: context, host: host, observed: observed, mismatch: mismatch))
                    }
                    let upgrader = NIOWebSocketClientUpgrader(
                        maxFrameSize: min(maximumMessageSize, Int(UInt32.max)), automaticErrorHandling: false
                    ) { channel, head in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                WebSocketFrameHandler(core: core, maximumMessageSize: maximumMessageSize, heartbeat: heartbeat)
                            )
                            // The upgrade handler leaves the pipeline once this returns; until then a write would reach it.
                            channel.eventLoop.execute { upgraded.succeed(head) }
                        }
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes,
                        withClientUpgrade: (upgraders: [upgrader], completionHandler: { context in
                            context.pipeline.removeHandler(name: HandshakeHandler.name, promise: nil)
                        })
                    )
                    try channel.pipeline.syncOperations.addHandler(HandshakeHandler(request: requestHead, promise: upgraded), name: HandshakeHandler.name)
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            upgraded.fail(error)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            let (code, reason) = connectionFailure(error)
            throw WebSocketError.cannotConnect(host: host, port: port, code: code, reason: reason)
        }
        // What the connection left of the timeout, not the whole of it again.
        let timer = channel.eventLoop.scheduleTask(in: TimeAmount(max(.zero, deadline - .now))) {
            upgraded.fail(WebSocketError.timeout)
            channel.close(promise: nil)
        }
        channel.closeFuture.whenComplete { _ in upgraded.fail(WebSocketError.connectionLost) }
        do {
            let head = try await withTaskCancellationHandler {
                try await upgraded.futureResult.get()
            } onCancel: {
                upgraded.fail(CancellationError())
                channel.close(promise: nil)
            }
            timer.cancel()
            if let chosen = head.headers.first(name: "Sec-WebSocket-Protocol"), !options.subprotocols.contains(chosen) {
                channel.close(promise: nil)
                throw WebSocketError.unexpectedSubprotocol(chosen)
            }
            core.attach(channel)
            return WebSocket(url: url, channel: channel, core: core, head: head, fingerprint: observed.withLockedValue { $0 })
        } catch {
            timer.cancel()
            channel.close(promise: nil)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        guard isOpen else { throw WebSocketError.notConnected }
        let frame: WebSocketFrame
        switch message {
        case .text(let text):
            frame = WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: text))
        case .binary(let data):
            frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: ByteBuffer(bytes: data))
        }
        do {
            try await channel.writeAndFlush(frame).get()
        } catch {
            throw WebSocketError.notConnected
        }
    }

    public func ping(timeout: Duration = .seconds(10)) async throws {
        guard isOpen else { throw WebSocketError.notConnected }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let core = core
        core.state.withLockedValue { $0.pings.append(promise) }
        let deadline = channel.eventLoop.scheduleTask(in: TimeAmount(timeout)) {
            // A peer that never answers must not have every ping kept until the connection ends.
            core.state.withLockedValue { $0.pings.removeAll { $0.futureResult === promise.futureResult } }
            promise.fail(WebSocketError.timeout)
        }
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, maskKey: .random(), data: ByteBuffer()), promise: nil)
        defer { deadline.cancel() }
        try await promise.futureResult.get()
    }

    public func close(code: UInt16 = 1000, reason: String = "") async {
        let alreadyClosing = core.state.withLockedValue { state -> Bool in
            defer { state.closeSent = true }
            return state.closeSent || state.finished
        }
        if !alreadyClosing {
            var data = ByteBuffer()
            data.writeInteger(code)
            data.writeString(reason)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: data), promise: nil)
            // The server answers with its own close frame and drops the connection; don't wait long for it.
            let channel = channel
            let force = channel.eventLoop.scheduleTask(in: .seconds(2)) { channel.close(promise: nil) }
            try? await channel.closeFuture.get()
            force.cancel()
        } else {
            try? await channel.close()
        }
        core.finish(nil)
    }
}

/// What the channel's handlers and the `WebSocket` share: the message stream and the close state.
final class WebSocketCore: Sendable {
    struct State {
        var closeCode: UInt16?
        var closeReason: String?
        var closeSent = false
        var finished = false
        var pings: [EventLoopPromise<Void>] = []
        var channel: (any Channel)?
    }

    let state = NIOLockedValueBox(State())
    let stream: AsyncThrowingStream<WebSocketMessage, any Error>
    private let continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [state] termination in
            // The reader went away: nobody will read the messages, so close the connection.
            if case .cancelled = termination {
                let channel = state.withLockedValue { $0.channel }
                channel?.close(promise: nil)
            }
        }
    }

    func attach(_ channel: any Channel) {
        state.withLockedValue { $0.channel = channel }
    }

    func deliver(_ message: WebSocketMessage) {
        continuation.yield(message)
    }

    func pong() {
        let pings = state.withLockedValue { state in
            defer { state.pings = [] }
            return state.pings
        }
        for ping in pings { ping.succeed() }
    }

    func received(close code: UInt16?, reason: String) -> Bool {
        state.withLockedValue { state in
            state.closeCode = code ?? 1005
            state.closeReason = reason
            defer { state.closeSent = true }
            return state.closeSent
        }
    }

    /// Ends the stream: normally after a close frame, else with `error`.
    func finish(_ error: (any Error)?) {
        let (first, pings, closedCleanly) = state.withLockedValue { state in
            defer {
                state.finished = true
                state.pings = []
            }
            return (!state.finished, state.pings, state.closeCode != nil || state.closeSent)
        }
        guard first else { return }
        for ping in pings { ping.fail(error ?? WebSocketError.notConnected) }
        if let error {
            continuation.finish(throwing: error)
        } else if closedCleanly {
            continuation.finish()
        } else {
            continuation.finish(throwing: WebSocketError.connectionLost)
        }
    }
}

/// Sends the upgrade request once connected, and fails the handshake on a response that is not an upgrade.
private final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    static let name = "homeswift-websocket-handshake"

    private let request: HTTPRequestHead
    private let promise: EventLoopPromise<HTTPResponseHead>

    init(request: HTTPRequestHead, promise: EventLoopPromise<HTTPResponseHead>) {
        self.request = request
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(wrapOutboundOut(.head(request)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            promise.fail(WebSocketError.handshakeFailed(status: Int(head.status.code)))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

/// Reassembles messages, answers pings and close frames, runs the heartbeat.
private final class WebSocketFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let core: WebSocketCore
    private let maximumMessageSize: Int
    private let heartbeat: Duration?
    private var fragments: ByteBuffer?
    private var fragmentOpcode: WebSocketOpcode = .binary
    private var sawFrame = true
    private var heartbeatTask: RepeatedTask?

    init(core: WebSocketCore, maximumMessageSize: Int, heartbeat: Duration?) {
        self.core = core
        self.maximumMessageSize = maximumMessageSize
        self.heartbeat = heartbeat
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard let heartbeat else { return }
        let interval = TimeAmount(heartbeat)
        let bound = NIOLoopBound((handler: self, context: context), eventLoop: context.eventLoop)
        heartbeatTask = context.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { _ in
            let (handler, context) = bound.value
            handler.tick(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        heartbeatTask?.cancel()
    }

    private func tick(context: ChannelHandlerContext) {
        guard sawFrame else {
            heartbeatTask?.cancel()
            core.finish(WebSocketError.heartbeatTimeout)
            context.close(promise: nil)
            return
        }
        sawFrame = false
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .ping, maskKey: .random(), data: ByteBuffer())), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        sawFrame = true
        switch frame.opcode {
        case .text, .binary:
            guard fragments == nil else { return fail(context: context, "a new message started inside a fragmented one") }
            if frame.fin {
                deliver(frame.opcode, frame.unmaskedData, context: context)
            } else {
                fragmentOpcode = frame.opcode
                fragments = frame.unmaskedData
                checkSize(context: context)
            }
        case .continuation:
            guard var buffer = fragments else { return fail(context: context, "a continuation frame without a message") }
            // The only reference while it grows: with `fragments` still holding it, every frame would copy the message so far.
            fragments = nil
            var data = frame.unmaskedData
            buffer.writeBuffer(&data)
            fragments = buffer
            guard checkSize(context: context) else { return }
            if frame.fin {
                fragments = nil
                deliver(fragmentOpcode, buffer, context: context)
            }
        case .ping:
            var data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: data.readSlice(length: data.readableBytes) ?? ByteBuffer())
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            core.pong()
        case .connectionClose:
            var data = frame.unmaskedData
            let code = data.readInteger(as: UInt16.self)
            let reason = data.readString(length: data.readableBytes) ?? ""
            let weClosed = core.received(close: code, reason: reason)
            if !weClosed {
                var echo = ByteBuffer()
                if let code { echo.writeInteger(code) }
                writeThenClose(context: context, WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: echo))
            } else {
                context.close(promise: nil)
            }
            core.finish(nil)
        default:
            fail(context: context, "unknown opcode")
        }
    }

    @discardableResult
    private func checkSize(context: ChannelHandlerContext) -> Bool {
        guard let fragments, fragments.readableBytes > maximumMessageSize else { return true }
        self.fragments = nil
        close(context: context, code: 1009, error: WebSocketError.messageTooLarge(limit: maximumMessageSize))
        return false
    }

    private func deliver(_ opcode: WebSocketOpcode, _ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard buffer.readableBytes <= maximumMessageSize else {
            return close(context: context, code: 1009, error: WebSocketError.messageTooLarge(limit: maximumMessageSize))
        }
        if opcode == .text {
            guard let text = String(bytes: buffer.readableBytesView, encoding: .utf8) else {
                return close(context: context, code: 1007, error: WebSocketError.protocolError("a text message is not valid UTF-8"))
            }
            core.deliver(.text(text))
        } else {
            core.deliver(.binary(Data(buffer.readableBytesView)))
        }
    }

    private func fail(context: ChannelHandlerContext, _ reason: String) {
        close(context: context, code: 1002, error: WebSocketError.protocolError(reason))
    }

    private func close(context: ChannelHandlerContext, code: UInt16, error: WebSocketError) {
        core.finish(error)
        var data = ByteBuffer()
        data.writeInteger(code)
        writeThenClose(context: context, WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: data))
    }

    private func writeThenClose(context: ChannelHandlerContext, _ frame: WebSocketFrame) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in bound.value.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // The frame decoder's errors: answer with a close frame, as RFC 6455 asks.
        switch error as? NIOWebSocketError {
        case .invalidFrameLength?:
            close(context: context, code: 1009, error: WebSocketError.messageTooLarge(limit: maximumMessageSize))
        case .some(let error):
            close(context: context, code: 1002, error: WebSocketError.protocolError("\(error)"))
        case nil:
            core.finish(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        heartbeatTask?.cancel()
        core.finish(nil)
        context.fireChannelInactive()
    }
}
