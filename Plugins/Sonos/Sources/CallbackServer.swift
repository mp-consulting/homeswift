import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// What the event server hears: a request's method, path, the sender's address and body.
struct CallbackRequest: Sendable {
    var method: String
    var path: String
    var remoteAddress: String
    var body: Data
}

/// The server the players' GENA events come to: one HTTP listener for every player, on the configured port (0: the
/// system's choice). It reads at most `maximumBodySize` of a request and closes a connection quiet for 30 seconds.
protocol EventListening: Sendable {
    var port: Int { get }
    func close() async
}

typealias EventHandler = @Sendable (CallbackRequest) async -> (status: Int, contentType: String?, body: String)

/// Binds the event server; tests may stand in for it.
typealias EventListenerFactory = @Sendable (_ port: Int, _ handler: @escaping EventHandler) async throws -> any EventListening

final class CallbackServer: EventListening {
    /// A full topology of a large household is some hundred kilobytes.
    static let maximumBodySize = 1 << 20
    static let idleTimeout: TimeAmount = .seconds(30)

    private let channel: any Channel
    let port: Int

    private init(channel: any Channel) {
        self.channel = channel
        port = channel.localAddress?.port ?? 0
    }

    static func bind(port: Int, handler: @escaping EventHandler) async throws -> any EventListening {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: idleTimeout))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(RequestHandler(handler: handler))
                }
            }
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        return CallbackServer(channel: channel)
    }

    func close() async {
        try? await channel.close()
    }

    private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let handler: EventHandler
        private var head: HTTPRequestHead?
        private var body = ByteBuffer()
        private var tooLarge = false

        init(handler: @escaping EventHandler) { self.handler = handler }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body.clear()
                tooLarge = false
            case .body(var chunk):
                if body.readableBytes + chunk.readableBytes > CallbackServer.maximumBodySize {
                    tooLarge = true
                } else if !tooLarge {
                    body.writeBuffer(&chunk)
                }
            case .end:
                guard let head else { return }
                self.head = nil
                if tooLarge {
                    respond(context, status: 413, contentType: nil, body: "", keepAlive: false)
                    return
                }
                let request = CallbackRequest(
                    method: head.method.rawValue, path: head.uri, remoteAddress: context.remoteAddress?.ipAddress ?? "",
                    body: Data(body.readableBytesView))
                let keepAlive = head.isKeepAlive
                let handler = handler
                let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
                let loop = context.eventLoop
                Task {
                    let answer = await handler(request)
                    loop.execute {
                        let (handler, context) = bound.value
                        handler.respond(context, status: answer.status, contentType: answer.contentType, body: answer.body, keepAlive: keepAlive)
                    }
                }
            }
        }

        private func respond(_ context: ChannelHandlerContext, status: Int, contentType: String?, body: String, keepAlive: Bool) {
            var headers = HTTPHeaders()
            let buffer = ByteBuffer(string: body)
            if let contentType { headers.add(name: "Content-Type", value: contentType) }
            headers.add(name: "Content-Length", value: String(buffer.readableBytes))
            if !keepAlive { headers.add(name: "Connection", value: "close") }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
            if !keepAlive { done.whenComplete { _ in context.close(promise: nil) } }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}
