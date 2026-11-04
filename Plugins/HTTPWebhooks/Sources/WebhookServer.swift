import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The webhook server: HTTP, or HTTPS with `tls`, on the LAN. Every request goes to the router once its body has
/// arrived (the body itself is ignored). It listens on the network without a user in front of it, so it bounds what a
/// client can hold: a body of `maximumBodySize` at most, `maximumConnections` at once, and a connection quiet for
/// `idleTimeout` is closed.
final class WebhookServer: Sendable {
    typealias Handler = @Sendable (_ method: String, _ uri: String, _ authorization: String?) -> WebhookHTTPResponse

    static let maximumBodySize = 64 * 1024
    static let maximumConnections = 64
    static let idleTimeout: TimeAmount = .seconds(30)

    private let channel: NIOLockedValueBox<(any Channel)?> = NIOLockedValueBox(nil)
    /// The open connections, by identity: counted against `maximumConnections`, closed by `stop()`.
    private let connections = NIOLockedValueBox<(open: [ObjectIdentifier: any Channel], stopped: Bool)>(([:], false))
    private let logger: Logger
    private let group: any EventLoopGroup

    init(logger: Logger, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.logger = logger
        self.group = group
    }

    /// The port it listens on, once started.
    var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    func start(host: String, port: Int, tls: NIOSSLContext?, handler: @escaping Handler) async throws {
        let connections = connections
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let key = ObjectIdentifier(channel)
                let admitted = connections.withLockedValue { state -> Bool in
                    guard !state.stopped, state.open.count < Self.maximumConnections else { return false }
                    state.open[key] = channel
                    return true
                }
                guard admitted else { return channel.close() }
                channel.closeFuture.whenComplete { _ in _ = connections.withLockedValue { $0.open.removeValue(forKey: key) } }
                return channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(IdleStateHandler(allTimeout: Self.idleTimeout))
                    try pipeline.addHandler(IdleCloser())
                    if let tls { try pipeline.addHandler(NIOSSLServerHandler(context: tls)) }
                    try pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    try pipeline.addHandler(WebhookHandler(handler: handler))
                }
            }
            .childChannelOption(.allowRemoteHalfClosure, value: false)
        connections.withLockedValue { $0.stopped = false }
        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        let bound = channel.withLockedValue { channel in
            defer { channel = nil }
            return channel
        }
        try? await bound?.close()
        let open = connections.withLockedValue { state in
            state.stopped = true
            return Array(state.open.values)
        }
        for connection in open { try? await connection.close() }
    }
}

/// Closes a connection when the `IdleStateHandler` before it reports it idle.
private final class IdleCloser: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// One connection's requests: reads the head, counts the body without keeping it, and answers at its end.
private final class WebhookHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: WebhookServer.Handler
    private var head: HTTPRequestHead?
    private var bodySize = 0
    private var refused = false

    init(handler: @escaping WebhookServer.Handler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            bodySize = 0
            refused = false
        case .body(let buffer):
            bodySize += buffer.readableBytes
            if bodySize > WebhookServer.maximumBodySize, !refused {
                refused = true
                write(context: context, WebhookHTTPResponse(status: 413, contentType: "text/plain", body: "Request body too large"), keepAlive: false)
            }
        case .end:
            guard let head, !refused else { return }
            self.head = nil
            let response = handler(head.method.rawValue, head.uri, head.headers.first(name: "Authorization"))
            write(context: context, response, keepAlive: head.isKeepAlive)
        }
    }

    private func write(context: ChannelHandlerContext, _ response: WebhookHTTPResponse, keepAlive: Bool) {
        var headers = HTTPHeaders()
        if let contentType = response.contentType { headers.add(name: "Content-Type", value: contentType) }
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { headers.add(name: name, value: value) }
        let body = ByteBuffer(string: response.body)
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        let written = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            written.whenComplete { _ in bound.value.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
