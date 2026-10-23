import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The temporary HTTPS server the Developer Portal login redirects the browser to
/// (`https://<callbackServerExternalAddress>:<callbackServerPort>/?code=…&state=…`). It runs only during a
/// login, stops by itself when the ten-minute window closes, and answers every request with a small page.
final class CallbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ uri: String) async -> (status: Int, html: String)

    private let state = NIOLockedValueBox<State>(State())
    private let logger: Logger
    private let group: any EventLoopGroup

    private struct State {
        var channel: (any Channel)?
        var port: Int?
        var stopTask: Task<Void, Never>?
    }

    init(logger: Logger, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.logger = logger
        self.group = group
    }

    var isRunning: Bool { state.withLockedValue { $0.channel != nil } }
    var port: Int? { state.withLockedValue { $0.port } }

    /// Starts listening on `bindAddress:port` with a certificate for `hostname`. A port still held by the
    /// previous run is tried three times, a second apart.
    func start(port: Int, hostname: String, bindAddress: String, certificateDirectory: URL, lifetime: Duration, handler: @escaping Handler) async throws {
        await stop()
        let material = try SelfSignedCertificate.load(for: hostname, in: certificateDirectory)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: material.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(material.privateKeyPEM.utf8), format: .pem)))
        let context = try NIOSSLContext(configuration: configuration)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(CallbackHandler(handler: handler))
                }
            }
        var attempt = 1
        while true {
            do {
                let channel = try await bootstrap.bind(host: bindAddress, port: port).get()
                logger.info("HTTPS callback server listening on \(bindAddress):\(port)")
                let stopTask = Task { [weak self] in
                    guard (try? await Task.sleep(for: lifetime)) != nil else { return }
                    self?.logger.info("[DaikinCloud] Authorization window expired, stopping callback server")
                    await self?.stop()
                }
                state.withLockedValue {
                    $0.channel = channel
                    $0.port = port
                    $0.stopTask = stopTask
                }
                return
            } catch let error as IOError where error.errnoCode == EADDRINUSE && attempt < 3 {
                logger.warning("Port \(port) in use, retrying in 1 second (attempt \(attempt)/3)...")
                attempt += 1
                try await Task.sleep(for: .seconds(1))
            } catch {
                logger.error("Callback server error: \(error)")
                throw error
            }
        }
    }

    func stop() async {
        let (channel, stopTask) = state.withLockedValue { state -> ((any Channel)?, Task<Void, Never>?) in
            defer { state = State() }
            return (state.channel, state.stopTask)
        }
        stopTask?.cancel()
        guard let channel else { return }
        try? await channel.close()
        logger.info("HTTPS callback server stopped")
    }

    /// The page the browser shows after the redirect.
    static func page(success: Bool, message: String) -> String {
        let icon = success
            ? ##"<svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#4caf50" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>"##
            : ##"<svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#f44336" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>"##
        return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Daikin Authentication</title>
                <style>
                    * { box-sizing: border-box; }
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; padding: 1rem; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
                    .container { text-align: center; padding: 2.5rem; background: white; border-radius: 16px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); max-width: 400px; width: 100%; }
                    .icon { margin-bottom: 1.5rem; }
                    h1 { margin: 0 0 0.75rem; font-size: 1.75rem; font-weight: 600; color: \(success ? "#4caf50" : "#f44336"); }
                    .message { color: #333; font-size: 1rem; line-height: 1.5; margin: 0 0 1.5rem; }
                    .hint { color: #888; font-size: 0.875rem; margin: 0; }
                </style>
            </head>
            <body>
                <div class="container">
                    <div class="icon">\(icon)</div>
                    <h1>\(success ? "Success!" : "Error")</h1>
                    <p class="message">\(escapeHTML(message))</p>
                    <p class="hint">You can close this window and return to Homeswift.</p>
                </div>
            </body>
            </html>
            """
    }

    static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Answers each request with the handler's page, under a policy that allows nothing but inline styles.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: CallbackServer.Handler
    private var uri = "/"

    init(handler: @escaping CallbackServer.Handler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            uri = head.uri
        case .body:
            break
        case .end:
            let uri = uri
            let handler = handler
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            Task {
                let (status, html) = await handler(uri)
                loop.execute {
                    let context = bound.value
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
                    headers.add(name: "Content-Security-Policy", value: "default-src 'none'; style-src 'unsafe-inline'")
                    headers.add(name: "X-Content-Type-Options", value: "nosniff")
                    headers.add(name: "Connection", value: "close")
                    let body = ByteBuffer(string: html)
                    headers.add(name: "Content-Length", value: String(body.readableBytes))
                    context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))), promise: nil)
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(body))), promise: nil)
                    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
