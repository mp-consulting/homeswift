import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// The listener battery cameras post their events to (docs/clean-room/ReolinkBattery.md 6.1): plain HTTP, any method,
/// one path `/reolink/<token>` (the token a secret), bodies up to 64 KiB, `200 OK` at once and the body handled after.
final class ReolinkWebhookServer: Sendable {
    typealias Handler = @Sendable (Data) async -> Void

    static let maximumBody = 64 * 1024
    static let pathPrefix = "/reolink/"

    private let channel = NIOLockedValueBox<(any Channel)?>(nil)
    let path: String

    init(token: String) {
        path = Self.pathPrefix + token
    }

    var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    func start(host: String, port: Int, handler: @escaping Handler) async throws {
        let path = path
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: .seconds(30)))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(ReolinkWebhookHandler(path: path, handler: handler))
                }
            }
        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        let current = channel.withLockedValue { channel -> (any Channel)? in
            defer { channel = nil }
            return channel
        }
        try? await current?.close()
    }

    /// Whether a request's path is the listener's, compared in constant time.
    static func matches(_ uri: String, path: String) -> Bool {
        let requested = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return Secrets.constantTimeEqual(Array(requested.utf8), Array(path.utf8))
    }

    /// The address the camera reaches the bridge at: the interface on the camera's network, else the first that is not
    /// loopback.
    static func localAddress(toward host: String, networks: [IPv4Network] = localIPv4Networks()) -> String? {
        let usable = networks.filter { !$0.isLoopback && $0.address != 0 }
        if let target = IPv4Network.parse(host), let network = usable.first(where: { $0.netmask != 0 && $0.contains(target) }) {
            return IPv4Network.dotted(network.address)
        }
        return usable.first.map { IPv4Network.dotted($0.address) }
    }
}

private final class ReolinkWebhookHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let path: String
    private let handler: ReolinkWebhookServer.Handler
    private var head: HTTPRequestHead?
    private var body = Data()
    private var tooLarge = false

    init(path: String, handler: @escaping ReolinkWebhookServer.Handler) {
        self.path = path
        self.handler = handler
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
            tooLarge = false
        case .body(var buffer):
            if body.count + buffer.readableBytes > ReolinkWebhookServer.maximumBody {
                tooLarge = true
            } else if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let status: HTTPResponseStatus
            if tooLarge {
                status = .payloadTooLarge
            } else if ReolinkWebhookServer.matches(head.uri, path: path) {
                status = .ok
                let body = body, handler = handler
                Task { await handler(body) }
            } else {
                status = .notFound
            }
            let text = status == .ok ? "OK" : status.reasonPhrase
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain")
            headers.add(name: "Content-Length", value: "\(text.utf8.count)")
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
