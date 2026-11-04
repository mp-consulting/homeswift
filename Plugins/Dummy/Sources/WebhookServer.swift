import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The webhook server of a block (spec 9.1): GET and POST on `/`, the query and the body's fields (form or JSON) as
/// parameters, HTTPS with the block's `key` and `cert` files. With a `passphrase`, every request carries it (the
/// `passphrase` parameter, or `Authorization: Bearer <passphrase>`), compared in constant time.
final class WebhookServer: Sendable {
    typealias Handler = @Sendable ([String: JSONValue]) async -> WebhookReply

    /// Bodies larger than this are refused: the server listens on the LAN.
    static let maximumBody = 64 * 1024
    static let idleTimeout: TimeAmount = .seconds(30)

    private let channel = NIOLockedValueBox<(any Channel)?>(nil)
    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    func start(host: String, port: Int, tls: NIOSSLContext?, passphrase: String?, handler: @escaping Handler) async throws {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: Self.idleTimeout))
                    try channel.pipeline.syncOperations.addHandler(IdleCloser())
                    if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(WebhookHTTPHandler(passphrase: passphrase, handler: handler))
                }
            }
        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel.withLockedValue { $0 = bound }
        logger.info("Webhook server listening on port \(bound.localAddress?.port ?? port) (\(tls == nil ? "http" : "https"))")
    }

    func stop() async {
        let current = channel.withLockedValue { channel -> (any Channel)? in
            defer { channel = nil }
            return channel
        }
        try? await current?.close()
    }

    /// The TLS context of PEM `key` and `cert` files.
    static func tlsContext(keyPath: String, certificatePath: String) throws -> NIOSSLContext {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: configuration)
    }

    /// The parameters of a request: the query, then the body's fields over them. Text values from a query or a form
    /// are parsed by the engine (`DummyEngine.parse`); a JSON body keeps its types.
    static func parameters(uri: String, contentType: String?, body: Data) -> [String: JSONValue]? {
        var parameters: [String: JSONValue] = [:]
        if let mark = uri.firstIndex(of: "?") {
            for (key, value) in URLEncoding.fields(String(uri[uri.index(after: mark)...])) { parameters[key] = .string(value) }
        }
        guard !body.isEmpty else { return parameters }
        let type = contentType?.lowercased() ?? ""
        if type.contains("json") || body.first == UInt8(ascii: "{") {
            guard let object = (try? JSONValue(data: body))?.objectValue else { return nil }
            for (key, value) in object { parameters[key] = value }
        } else {
            for (key, value) in URLEncoding.fields(String(decoding: body, as: UTF8.self)) { parameters[key] = .string(value) }
        }
        return parameters
    }

    static func authorized(_ parameters: [String: JSONValue], authorization: String?, passphrase: String?) -> Bool {
        guard let passphrase, !passphrase.isEmpty else { return true }
        var given = parameters["passphrase"]?.stringValue
        if given == nil, let authorization, authorization.lowercased().hasPrefix("bearer ") { given = String(authorization.dropFirst(7)) }
        guard let given else { return false }
        return Secrets.constantTimeEqual(Array(given.utf8), Array(passphrase.utf8))
    }
}

/// Closes a connection the `IdleStateHandler` before it reports idle.
private final class IdleCloser: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
    }
}

private final class WebhookHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let passphrase: String?
    private let handler: WebhookServer.Handler
    private var head: HTTPRequestHead?
    private var body = Data()
    private var tooLarge = false

    init(passphrase: String?, handler: @escaping WebhookServer.Handler) {
        self.passphrase = passphrase
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
            tooLarge = false
        case .body(var buffer):
            if body.count + buffer.readableBytes > WebhookServer.maximumBody {
                tooLarge = true
            } else if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let reply: WebhookReply?
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            var parameters: [String: JSONValue]?
            if tooLarge {
                reply = .json(413, ["error": "The request body is too large"])
            } else if head.method != .GET && head.method != .POST {
                reply = .json(405, ["error": "Only GET and POST are supported"])
            } else if path != "/" {
                reply = .json(404, ["error": "Not found"])
            } else if let parsed = WebhookServer.parameters(uri: head.uri, contentType: head.headers.first(name: "content-type"), body: body) {
                if WebhookServer.authorized(parsed, authorization: head.headers.first(name: "authorization"), passphrase: passphrase) {
                    var parameters2 = parsed
                    parameters2.removeValue(forKey: "passphrase")
                    parameters = parameters2
                    reply = nil
                } else {
                    reply = .json(401, ["error": "The request needs the webhook passphrase"])
                }
            } else {
                reply = .json(400, ["error": "The request body is not valid JSON"])
            }
            body = Data()
            let keepAlive = head.isKeepAlive
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            let handler = handler
            Task {
                let answer: WebhookReply
                if let reply { answer = reply } else { answer = await handler(parameters ?? [:]) }
                loop.execute {
                    let context = bound.value
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: answer.contentType)
                    headers.add(name: "Content-Length", value: String(answer.body.utf8.count))
                    headers.add(name: "Cache-Control", value: "no-store")
                    if !keepAlive { headers.add(name: "Connection", value: "close") }
                    let responseHead = HTTPResponseHead(version: head.version, status: HTTPResponseStatus(statusCode: answer.status), headers: headers)
                    context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                    var buffer = context.channel.allocator.buffer(capacity: answer.body.utf8.count)
                    buffer.writeString(answer.body)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                        if !keepAlive { context.close(promise: nil) }
                    }
                }
            }
        }
    }
}
