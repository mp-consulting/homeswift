import Foundation
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// MCP over Streamable HTTP on SwiftNIO: `POST /mcp` carries the client's messages (the reply is JSON, or
/// an SSE stream when the server needs to ask something first), `GET /mcp` is the standing stream for
/// server-initiated messages, `DELETE /mcp` ends the session.
///
/// Every request needs a bearer token; the token's scope decides what the session may do. Browser
/// origins other than loopback and the server's own address are refused unless listed. Repeated bad
/// tokens from an address are slowed down, and idle sessions expire.
public final class MCPHTTPServer: Sendable {
    public struct Options: Sendable {
        public var host: String
        public var port: Int
        public var path = "/mcp"
        public var allowedOrigins: [String]
        /// How long a session may sit idle; the configuration's `sessionIdleMinutes` when nil.
        public var idleTimeout: Duration?
        /// At most this many sessions: a new one ends the least recently used idle one, or is refused with 503
        /// when all are busy. The configuration's `maxSessions` when nil.
        public var maxSessions: Int?
        /// How often an SSE stream gets a comment: it keeps proxies and client timeouts quiet, and a write that fails
        /// is how a client gone away is found (NIO's HTTP pipeline stops reading while a response is open).
        public var keepAliveInterval: Duration = .seconds(15)
        public var logger = Logger(label: "homeswift.mcp")

        public init(host: String = MCPConfiguration.defaultHost, port: Int = MCPConfiguration.defaultPort, allowedOrigins: [String] = []) {
            self.host = host
            self.port = port
            self.allowedOrigins = allowedOrigins
        }
    }

    public let server: MCPServer
    public let configuration: MCPConfiguration
    public let options: Options
    private let channel = NIOLockedValueBox<(any Channel)?>(nil)
    private let stopActions = NIOLockedValueBox<[@Sendable () -> Void]>([])
    private let expiry = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private let throttle = FailureThrottle(window: 600, threshold: 3, maxDelay: 5)
    private let attached = NIOLockedValueBox<Set<String>>([])
    /// The sessions with a standing stream open.
    var standingStreams: Int { attached.withLockedValue { $0.count } }
    var logger: Logger { options.logger }

    public init(server: MCPServer, configuration: MCPConfiguration, options: Options? = nil) {
        self.server = server
        self.configuration = configuration
        self.options = options ?? Options(host: configuration.host, port: configuration.port, allowedOrigins: configuration.allowedOrigins)
    }

    /// The bound port, once started.
    public var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    public var idleTimeout: Duration { options.idleTimeout ?? .seconds(configuration.sessionIdleMinutes * 60) }
    public var maxSessions: Int { max(1, options.maxSessions ?? configuration.maxSessions) }

    public func start() async throws {
        guard configuration.hasTokens else { throw MCPTransportError.noToken }
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(RequestHandler(transport: self))
                }
            }
        let bound = try await bootstrap.bind(host: options.host, port: options.port).get()
        channel.withLockedValue { $0 = bound }
        let server = self.server
        let timeout = idleTimeout
        // Swept every minute, or twice per timeout when it is shorter.
        let sweep = min(Duration.seconds(60), max(Duration.seconds(1), timeout / 2))
        expiry.withLockedValue {
            $0 = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: sweep)
                    server.expireSessions(idleFor: timeout)
                }
            }
        }
        logger.info("MCP server listening", metadata: ["url": "http://\(options.host):\(bound.localAddress?.port ?? options.port)\(options.path)"])
    }

    /// Runs `action` when the server stops: what it subscribed to, it lets go of.
    public func onStop(_ action: @escaping @Sendable () -> Void) {
        stopActions.withLockedValue { $0.append(action) }
    }

    public func stop() async {
        for action in stopActions.withLockedValue({ actions in defer { actions = [] }; return actions }) { action() }
        expiry.withLockedValue { $0?.cancel(); $0 = nil }
        for session in server.activeSessions { server.endSession(session) }
        let bound = channel.withLockedValue { channel -> (any Channel)? in
            defer { channel = nil }
            return channel
        }
        try? await bound?.close()
    }

    // MARK: Requests

    /// One request, headers lower-cased. The web UI hands its `/mcp` requests over in this shape (`handle`).
    public struct Request: Sendable {
        public var method: HTTPMethod
        public var path: String
        public var headers: [String: String]
        public var body: Data
        public var remote: String
        /// The body was longer than `RequestHandler.maxBody`: answered 413, never parsed.
        public var tooLarge = false

        public init(method: HTTPMethod, path: String, headers: [String: String], body: Data, remote: String, tooLarge: Bool = false) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
            self.remote = remote
            self.tooLarge = tooLarge
        }
    }

    public enum Reply: Sendable {
        case json(status: Int, body: Data, headers: [String: String] = [:])
        case empty(status: Int, headers: [String: String] = [:])
        case events(status: Int, headers: [String: String], stream: AsyncStream<Data>)
    }

    func reply(to request: Request) async -> Reply {
        guard request.path == options.path || request.path == options.path + "/" else {
            return .json(status: 404, body: Self.errorBody("not found"))
        }
        if let origin = request.headers["origin"], !originAllowed(origin) {
            logger.warning("MCP request from a forbidden origin", metadata: ["origin": "\(origin)", "remote": "\(request.remote)"])
            return .json(status: 403, body: Self.errorBody("origin not allowed"))
        }
        guard let principal = await authenticate(request) else {
            return .json(status: 401, body: Self.errorBody("a bearer token is required"), headers: ["WWW-Authenticate": "Bearer"])
        }
        return await handle(request, principal: principal)
    }

    /// Answers a request whose caller is already known: the web UI's `/mcp`, which checks the origin and the bearer
    /// token itself (its OAuth tokens as well as this configuration's).
    public func handle(_ request: Request, principal: Principal) async -> Reply {
        if request.tooLarge {
            return .json(status: 413, body: Self.errorBody("the request body is larger than \(RequestHandler.maxBody / (1024 * 1024)) MB"))
        }
        switch request.method {
        case .POST: return await post(request, principal: principal)
        case .GET: return get(request, principal: principal)
        case .DELETE: return delete(request, principal: principal)
        default: return .json(status: 405, body: Self.errorBody("method not allowed"), headers: ["Allow": "GET, POST, DELETE"])
        }
    }

    /// Loopback, this server's own address (or `host`, the name the request reached it by), or an allowed origin.
    public func originAllowed(_ origin: String, host: String? = nil) -> Bool {
        guard let url = URL(string: origin), let originHost = url.host.map(HostName.of) else { return false }
        if HostName.isLoopback(originHost) || originHost == HostName.of(options.host) || host.map(HostName.of) == originHost { return true }
        return options.allowedOrigins.contains { $0 == "*" || $0.lowercased() == origin.lowercased() || URL(string: $0)?.host.map(HostName.of) == originHost }
    }

    /// The principal of the bearer token. Repeated failures from an address are slowed down.
    private func authenticate(_ request: Request) async -> Principal? {
        if let token = Self.bearerToken(request.headers["authorization"]), let principal = configuration.principal(for: token) {
            throttle.succeeded(request.remote)
            return principal
        }
        logger.warning("MCP request with a bad token", metadata: ["remote": "\(request.remote)"])
        await throttle.failAndWait(request.remote)
        return nil
    }

    /// The token of an `Authorization: Bearer …` header (the scheme in any case, RFC 9110 §11.1); nil for another
    /// scheme or none. The web UI reads its API and OAuth tokens with it too.
    public static func bearerToken(_ header: String?) -> String? {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return nil }
        let token = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    public static func errorBody(_ message: String, code: Int = JSONRPCError.invalidRequest) -> Data {
        JSONRPCMessage.failure(id: .null, error: JSONRPCError(code: code, message: message)).json.encoded()
    }

    /// An event stream's headers. `no-transform` keeps a proxy that compresses (Cloudflare's Brotli) from holding
    /// events until it has enough to compress; `X-Accel-Buffering: no` keeps nginx (DSM's reverse proxy) from
    /// buffering them.
    public static let streamHeaders = ["Content-Type": "text/event-stream", "Cache-Control": "no-store, no-transform", "X-Accel-Buffering": "no"]

    enum SessionLookup {
        case none
        case found(MCPSession)
        case rejected(Reply)
    }

    private func session(for request: Request, principal: Principal) -> SessionLookup {
        guard let id = request.headers["mcp-session-id"] else { return .none }
        guard let session = server.session(id: id) else { return .rejected(.json(status: 404, body: Self.errorBody("unknown or expired session; initialize again"))) }
        guard session.principal == principal else { return .rejected(.json(status: 403, body: Self.errorBody("this session belongs to another token"))) }
        return .found(session)
    }

    private func post(_ request: Request, principal: Principal) async -> Reply {
        let messages: [JSONRPCMessage]
        do {
            messages = try JSONRPCMessage.parse(data: request.body)
        } catch {
            return .json(status: 400, body: JSONRPCMessage.failure(id: .null, error: error).json.encoded())
        }
        let session: MCPSession
        switch self.session(for: request, principal: principal) {
        case .rejected(let reply):
            return reply
        case .found(let existing):
            session = existing
        case .none:
            guard messages.contains(where: { if case .request(_, "initialize", _) = $0 { true } else { false } }) else {
                return .json(status: 400, body: Self.errorBody("Mcp-Session-Id is required; initialize first"))
            }
            guard let created = server.makeSession(principal: principal, limit: maxSessions) else {
                logger.warning("MCP session refused: every session is busy", metadata: ["limit": "\(maxSessions)", "remote": "\(request.remote)"])
                return .json(status: 503, body: Self.errorBody("too many active sessions (at most \(maxSessions))"), headers: ["Retry-After": "5"])
            }
            session = created
        }
        let requests = messages.filter(\.isRequest)
        let acceptsEvents = (request.headers["accept"] ?? "").contains("text/event-stream")
        var headers = ["Mcp-Session-Id": session.id]
        if requests.isEmpty {
            for message in messages { for await _ in server.handle(message, session: session) {} }
            return .empty(status: 202, headers: headers)
        }
        if acceptsEvents {
            headers.merge(Self.streamHeaders) { $1 }
            let server = self.server
            // A client that disconnects has not cancelled its requests (the Streamable HTTP transport's rule): they run
            // to the end, their answers going nowhere, and the session is busy until then.
            let stream = AsyncStream<Data> { continuation in
                Task {
                    for message in messages {
                        for await outgoing in server.handle(message, session: session) {
                            continuation.yield(Self.event(outgoing))
                        }
                    }
                    continuation.finish()
                }
            }
            return .events(status: 200, headers: headers, stream: stream)
        }
        // JSON only: nothing can be asked of the client on this exchange.
        var responses: [JSONValue] = []
        for message in messages {
            for await outgoing in server.handle(message, session: session, serverRequests: false) where outgoing.isResponse {
                responses.append(outgoing.json)
            }
        }
        headers["Content-Type"] = "application/json"
        let body = responses.count == 1 && messages.count == 1 ? responses[0] : .array(responses)
        return .json(status: 200, body: body.encoded(), headers: headers)
    }

    private func get(_ request: Request, principal: Principal) -> Reply {
        guard (request.headers["accept"] ?? "").contains("text/event-stream") else {
            return .json(status: 405, body: Self.errorBody("GET needs Accept: text/event-stream"))
        }
        let session: MCPSession
        switch self.session(for: request, principal: principal) {
        case .rejected(let reply): return reply
        case .none: return .json(status: 400, body: Self.errorBody("Mcp-Session-Id is required"))
        case .found(let existing): session = existing
        }
        let first = attached.withLockedValue { $0.insert(session.id).inserted }
        guard first else { return .json(status: 409, body: Self.errorBody("a stream is already open for this session")) }
        session.setStandingStream(true)
        let attached = self.attached
        // This stream's own listener: when the client goes away it ends, and a later GET opens the next.
        let messages = session.openOutbound()
        let stream = AsyncStream<Data> { continuation in
            let task = Task {
                for await message in messages {
                    continuation.yield(Self.event(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                session.setStandingStream(false)
                _ = attached.withLockedValue { $0.remove(session.id) }
            }
        }
        return .events(status: 200, headers: Self.streamHeaders.merging(["Mcp-Session-Id": session.id]) { $1 }, stream: stream)
    }

    private func delete(_ request: Request, principal: Principal) -> Reply {
        switch self.session(for: request, principal: principal) {
        case .rejected(let reply): return reply
        case .none: return .json(status: 400, body: Self.errorBody("Mcp-Session-Id is required"))
        case .found(let existing):
            server.endSession(existing)
            return .empty(status: 204)
        }
    }

    static func event(_ message: JSONRPCMessage) -> Data {
        SSE.frame(event: "message", data: message.json.text())
    }
}

public enum MCPTransportError: Error, CustomStringConvertible, Sendable {
    case noToken

    public var description: String {
        switch self {
        case .noToken: "the MCP server needs a client token: set mcp.http.token (homeswift mcp --generate-token makes one)"
        }
    }
}

/// Collects one HTTP request, hands it to the transport, writes the reply.
final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    let transport: MCPHTTPServer
    private var head: HTTPRequestHead?
    private var body = Data()
    private var tooLarge = false
    /// The largest request body read; a longer one is answered 413 and the rest of it dropped as it arrives.
    static let maxBody = 4 * 1024 * 1024

    init(transport: MCPHTTPServer) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
            tooLarge = false
        case .body(let buffer):
            guard !tooLarge else { return }
            guard body.count + buffer.readableBytes <= Self.maxBody else {
                tooLarge = true
                body = Data()
                return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { return }
            var headers: [String: String] = [:]
            for (name, value) in head.headers { headers[name.lowercased()] = value }
            let request = MCPHTTPServer.Request(
                method: head.method, path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""), headers: headers, body: body,
                remote: context.remoteAddress?.ipAddress ?? "?", tooLarge: tooLarge)
            self.head = nil
            body = Data()
            Self.respond(to: request, keepAlive: head.isKeepAlive, channel: context.channel, transport: transport)
        }
    }

    /// Answers off the event loop; every argument is Sendable, which keeps the isolation checker happy.
    private static func respond(to request: MCPHTTPServer.Request, keepAlive: Bool, channel: any Channel, transport: MCPHTTPServer) {
        Task {
            let reply = await transport.reply(to: request)
            await write(reply, to: channel, keepAlive: keepAlive, interval: transport.options.keepAliveInterval)
        }
    }

    private static func write(_ reply: MCPHTTPServer.Reply, to channel: any Channel, keepAlive: Bool, interval: Duration) async {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        func finish(_ body: Data?) {
            if let body, !body.isEmpty {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            if !keepAlive { channel.close(promise: nil) }
        }
        switch reply {
        case .json(let status, let body, let headers):
            head.status = .init(statusCode: status)
            head.headers.add(name: "Content-Type", value: headers["Content-Type"] ?? "application/json")
            head.headers.add(name: "Content-Length", value: "\(body.count)")
            for (name, value) in headers where name != "Content-Type" { head.headers.add(name: name, value: value) }
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            finish(body)
        case .empty(let status, let headers):
            head.status = .init(statusCode: status)
            head.headers.add(name: "Content-Length", value: "0")
            for (name, value) in headers { head.headers.add(name: name, value: value) }
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            finish(nil)
        case .events(let status, let headers, let stream):
            head.status = .init(statusCode: status)
            for (name, value) in headers { head.headers.add(name: name, value: value) }
            head.headers.add(name: "Connection", value: "close")
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
            // A comment every 15 seconds keeps proxies and client timeouts quiet while the user is asked something,
            // and finds a client that went away: the write fails and NIO closes the channel.
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: ": keepalive\n\n"))), promise: nil)
                }
            }
            // A closed channel ends the stream: a standing one would otherwise stay open on a dead connection, holding
            // its session busy (never expired, never evicted) and refusing the client's next GET.
            let forward = Task {
                for await chunk in stream {
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk))), promise: nil)
                }
            }
            channel.closeFuture.whenComplete { _ in forward.cancel() }
            await forward.value
            keepalive.cancel()
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
