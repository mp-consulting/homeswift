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
        public var idleTimeout: Duration = .seconds(1800)
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
    private let expiry = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private let failures = NIOLockedValueBox<[String: (count: Int, last: Date)]>([:])
    private let attached = NIOLockedValueBox<Set<String>>([])
    var logger: Logger { options.logger }

    public init(server: MCPServer, configuration: MCPConfiguration, options: Options? = nil) {
        self.server = server
        self.configuration = configuration
        self.options = options ?? Options(host: configuration.host, port: configuration.port, allowedOrigins: configuration.allowedOrigins)
    }

    /// The bound port, once started.
    public var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

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
        let timeout = options.idleTimeout
        expiry.withLockedValue {
            $0 = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    server.expireSessions(idleFor: timeout)
                }
            }
        }
        logger.info("MCP server listening", metadata: ["url": "http://\(options.host):\(bound.localAddress?.port ?? options.port)\(options.path)"])
    }

    public func stop() async {
        expiry.withLockedValue { $0?.cancel(); $0 = nil }
        for session in server.activeSessions { server.endSession(session) }
        let bound = channel.withLockedValue { channel -> (any Channel)? in
            defer { channel = nil }
            return channel
        }
        try? await bound?.close()
    }

    // MARK: Requests

    struct Request: Sendable {
        var method: HTTPMethod
        var path: String
        var headers: [String: String]
        var body: Data
        var remote: String
    }

    enum Reply: Sendable {
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
        switch request.method {
        case .POST: return await post(request, principal: principal)
        case .GET: return get(request, principal: principal)
        case .DELETE: return delete(request, principal: principal)
        default: return .json(status: 405, body: Self.errorBody("method not allowed"), headers: ["Allow": "GET, POST, DELETE"])
        }
    }

    private func originAllowed(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return true }
        if host == options.host.lowercased() { return true }
        return options.allowedOrigins.contains { $0 == "*" || $0.lowercased() == origin.lowercased() || URL(string: $0)?.host?.lowercased() == host }
    }

    /// The principal of the bearer token. Repeated failures from an address are slowed down.
    private func authenticate(_ request: Request) async -> Principal? {
        let header = request.headers["authorization"] ?? ""
        let token = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        if !token.isEmpty, let principal = configuration.principal(for: token) {
            failures.withLockedValue { $0[request.remote] = nil }
            return principal
        }
        let count = failures.withLockedValue { failures -> Int in
            let previous = failures[request.remote].map { Date().timeIntervalSince($0.last) < 600 ? $0.count : 0 } ?? 0
            failures[request.remote] = (previous + 1, Date())
            return previous + 1
        }
        logger.warning("MCP request with a bad token", metadata: ["remote": "\(request.remote)", "failures": "\(count)"])
        if count >= 3 { try? await Task.sleep(for: .seconds(min(count - 2, 5))) }
        return nil
    }

    static func errorBody(_ message: String, code: Int = JSONRPCError.invalidRequest) -> Data {
        JSONRPCMessage.failure(id: .null, error: JSONRPCError(code: code, message: message)).json.encoded()
    }

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
            session = server.makeSession(principal: principal)
        }
        let requests = messages.filter(\.isRequest)
        let acceptsEvents = (request.headers["accept"] ?? "").contains("text/event-stream")
        var headers = ["Mcp-Session-Id": session.id]
        if requests.isEmpty {
            for message in messages { for await _ in server.handle(message, session: session) {} }
            return .empty(status: 202, headers: headers)
        }
        if acceptsEvents {
            headers["Content-Type"] = "text/event-stream"
            headers["Cache-Control"] = "no-cache"
            let server = self.server
            let stream = AsyncStream<Data> { continuation in
                let task = Task {
                    for message in messages {
                        for await outgoing in server.handle(message, session: session) {
                            continuation.yield(Self.event(outgoing))
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
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
        let attached = self.attached
        let stream = AsyncStream<Data> { continuation in
            let task = Task {
                for await message in session.outbound {
                    continuation.yield(Self.event(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                _ = attached.withLockedValue { $0.remove(session.id) }
            }
        }
        return .events(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Mcp-Session-Id": session.id], stream: stream)
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
        Data("event: message\ndata: \(message.json.text())\n\n".utf8)
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

    init(transport: MCPHTTPServer) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            if body.count < 4 * 1024 * 1024, let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            var headers: [String: String] = [:]
            for (name, value) in head.headers { headers[name.lowercased()] = value }
            let request = MCPHTTPServer.Request(
                method: head.method, path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""), headers: headers, body: body,
                remote: context.remoteAddress?.ipAddress ?? "?")
            self.head = nil
            Self.respond(to: request, keepAlive: head.isKeepAlive, channel: context.channel, transport: transport)
        }
    }

    /// Answers off the event loop; every argument is Sendable, which keeps the isolation checker happy.
    private static func respond(to request: MCPHTTPServer.Request, keepAlive: Bool, channel: any Channel, transport: MCPHTTPServer) {
        Task {
            let reply = await transport.reply(to: request)
            await write(reply, to: channel, keepAlive: keepAlive)
        }
    }

    private static func write(_ reply: MCPHTTPServer.Reply, to channel: any Channel, keepAlive: Bool) async {
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
            // A comment every 15 seconds keeps proxies and client timeouts quiet while the user is asked something.
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: ": keepalive\n\n"))), promise: nil)
                }
            }
            for await chunk in stream {
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk))), promise: nil)
            }
            keepalive.cancel()
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
