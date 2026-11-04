import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// The HTTP listener SwitchBot's cloud posts webhook events to (`options.webhookURL`). It answers `POST <path>` with
/// `200 OK` and hands the JSON body on, where `path` ends with a random segment only the cloud learns, so a guess of the
/// URL posts nothing; any other method or path is `403 NG`. Bodies over `maximumBody` are refused, and a connection idle
/// for `idleTimeout` is closed.
final class WebhookServer: Sendable {
    typealias Handler = @Sendable (JSONValue) async -> Void

    static let maximumBody = 64 * 1024
    static let idleTimeout: TimeAmount = .seconds(30)

    private let channel: NIOLockedValueBox<(any Channel)?> = NIOLockedValueBox(nil)
    let path: String
    private let handler: Handler
    private let logger: Logger

    init(path: String, logger: Logger, handler: @escaping Handler) {
        self.path = path
        self.logger = logger
        self.handler = handler
    }

    /// The port bound (0 picks one).
    var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    func start(host: String = "0.0.0.0", port: Int) async throws {
        let path = path, handler = handler, logger = logger
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: Self.idleTimeout))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(WebhookHandler(path: path, logger: logger, handler: handler))
                }
            }
        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        let bound = channel.withLockedValue { channel in
            defer { channel = nil }
            return channel
        }
        try? await bound?.close()
    }
}

private final class WebhookHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let path: String
    private let logger: Logger
    private let handler: WebhookServer.Handler
    private var accepted = false
    private var tooLarge = false
    private var body = ByteBuffer()

    init(path: String, logger: Logger, handler: @escaping WebhookServer.Handler) {
        self.path = path
        self.logger = logger
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            let requestPath = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
            accepted = head.method == .POST && Self.equal(requestPath, path)
            tooLarge = false
            body.clear()
            if !accepted {
                // The method only: the path may be a guess of the secret one.
                logger.debug("Webhook: refused a \(head.method.rawValue) request")
            }
        case .body(var part):
            guard accepted, !tooLarge else { return }
            if body.readableBytes + part.readableBytes > WebhookServer.maximumBody {
                tooLarge = true
                body.clear()
            } else {
                body.writeBuffer(&part)
            }
        case .end:
            let ok = accepted && !tooLarge
            respond(context: context, status: ok ? .ok : tooLarge ? .payloadTooLarge : .forbidden, text: ok ? "OK" : "NG")
            if ok, let json = try? JSONValue(data: Data(body.readableBytesView)) {
                let handler = handler
                Task { await handler(json) }
            }
            body.clear()
        }
    }

    /// The paths compared in constant time: the secret segment is not leaked by timing.
    static func equal(_ lhs: String, _ rhs: String) -> Bool { Secrets.constantTimeEqual(Array(lhs.utf8), Array(rhs.utf8)) }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, text: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "Content-Length", value: String(text.utf8.count))
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
