import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// One HTTP request to a device: a method, a URL, headers, a body and a deadline.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [(name: String, value: String)]
    public var body: Data?
    /// From the connection attempt to the last byte of the response.
    public var timeout: Duration

    public init(method: String = "GET", url: URL, headers: [(name: String, value: String)] = [], body: Data? = nil, timeout: Duration = .seconds(10)) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Sets a header, replacing one with the same name.
    public mutating func setHeader(_ name: String, _ value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name, value))
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A complete response: the body is read before it is handed back.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// The SHA-256 fingerprint of the server's certificate (lowercase hex, no separators) when the
    /// request went over TLS to a client that records it (`HTTPClient.TLS.any` and `.pinned`).
    public var certificateFingerprint: String?

    public init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data(), certificateFingerprint: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.certificateFingerprint = certificateFingerprint
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The first header with this name, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Something that answers HTTP requests: the real client, or a fake device in tests.
public protocol HTTPSending: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidURL(String)
    /// The connection failed: nothing listens, no route, the host is asleep. `code` is the errno when
    /// the system gave one (`ECONNREFUSED` for a port nothing listens on).
    case cannotConnect(host: String, port: Int, code: Int32?, reason: String)
    case timeout
    /// The server's certificate is not the pinned one. Both are SHA-256 fingerprints.
    case certificateMismatch(expected: String, observed: String)
    case connectionClosed
    case responseTooLarge(limit: Int)

    public var description: String {
        switch self {
        case .invalidURL(let url): "cannot request \(url)"
        case .cannotConnect(let host, let port, _, let reason): "cannot connect to \(host):\(port): \(reason)"
        case .timeout: "the request timed out"
        case .certificateMismatch(let expected, let observed): "the certificate (\(observed)) is not the pinned one (\(expected))"
        case .connectionClosed: "the connection closed before the response ended"
        case .responseTooLarge(let limit): "the response is larger than \(limit) bytes"
        }
    }
}

/// An HTTP/1.1 client for devices on the LAN, on NIO so it behaves the same on macOS and Linux.
///
/// One connection per request, closed afterwards: the devices this is for answer a handful of requests a
/// minute, and keep-alive would only hold a socket open on a TV that drops it anyway. A request whose connection
/// the server closes before any of the response arrived goes once more on a new one, when its method is
/// idempotent or it never went out. The TLS mode decides what the client accepts from a server: the system's
/// roots (`.system`), any certificate (`.any`, trust on first use), or exactly one (`.pinned`). The last two
/// record the certificate's fingerprint on the response so the caller can pin it from then on.
public final class HTTPClient: HTTPSending, Sendable {
    public enum TLS: Sendable, Equatable {
        /// Verify the server's certificate against the system's trusted roots.
        case system
        /// Accept any certificate, and report its fingerprint on the response.
        case any
        /// Accept only the certificate with this SHA-256 fingerprint, in any spelling (`aa:bb:…` or hex).
        case pinned(String)
    }

    public let tls: TLS
    /// The TLS 1.2 cipher suites offered, as an OpenSSL cipher list (`"DEFAULT"`,
    /// `"ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256"`); nil for NIOSSL's own list. They shape the
    /// ClientHello, which some cloud firewalls fingerprint. A list that leaves no suite fails every HTTPS request with
    /// `TLSCipherListError`.
    public let cipherSuites: String?
    /// Responses larger than this fail instead of filling memory.
    public let maximumBodySize: Int
    private let group: any EventLoopGroup
    private let sslContext: NIOLockedValueBox<NIOSSLContext?> = .init(nil)

    public init(
        tls: TLS = .system, cipherSuites: String? = nil, maximumBodySize: Int = 4 * 1024 * 1024,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.tls = tls
        self.cipherSuites = cipherSuites
        self.maximumBodySize = maximumBodySize
        self.group = group
    }

    /// A fingerprint as the client compares it: lowercase hex without separators.
    public static func normalizeFingerprint(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter(\.isHexDigit)
    }

    /// The SHA-256 fingerprint of a DER certificate.
    public static func fingerprint(der: [UInt8]) -> String {
        hexString(SHA256.hash(data: der))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = request.url.host, !host.isEmpty else {
            throw HTTPClientError.invalidURL(request.url.absoluteString)
        }
        let secure = scheme == "https"
        let port = request.url.port ?? (secure ? 443 : 80)
        let start = ContinuousClock.now
        do {
            return try await exchange(request, host: host, port: port, secure: secure, timeout: request.timeout)
        } catch let dropped as DroppedConnection {
            // The server closed the connection without a byte of an answer (a restart, a connection limit, an idle
            // timeout): once more on a fresh connection, when the request never went out or may be seen twice.
            let remaining = request.timeout - (ContinuousClock.now - start)
            guard dropped.unsent || Self.idempotentMethods.contains(request.method.uppercased()), remaining > .zero else { throw dropped.error }
            do {
                return try await exchange(request, host: host, port: port, secure: secure, timeout: remaining)
            } catch let dropped as DroppedConnection {
                throw dropped.error
            }
        }
    }

    /// Methods a server may receive twice without harm (RFC 9110, 9.2.2).
    static let idempotentMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"]

    /// One request on one new connection. A connection that closed before any of the response arrived throws
    /// `DroppedConnection`, which `send` may retry.
    private func exchange(_ request: HTTPRequest, host: String, port: Int, secure: Bool, timeout: Duration) async throws -> HTTPResponse {
        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<HTTPClientError?>(nil)
        let progress = NIOLockedValueBox(ResponseCollector.Progress())
        let eventLoop = group.next()
        let promise = eventLoop.makePromise(of: HTTPResponse.self)
        let limit = maximumBodySize
        let channel: any Channel
        do {
            channel = try await connect(
                host: host, port: port, secure: secure, eventLoop: eventLoop, observed: observed, mismatch: mismatch, timeout: timeout
            ) { ResponseCollector(promise: promise, limit: limit, progress: progress) }
        } catch {
            promise.fail(error)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
        let deadline = channel.eventLoop.scheduleTask(in: TimeAmount(timeout)) {
            promise.fail(HTTPClientError.timeout)
            channel.close(promise: nil)
        }
        do {
            var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method.uppercased()), uri: requestTarget(of: request.url))
            head.headers.add(name: "Host", value: port == (secure ? 443 : 80) ? host : "\(host):\(port)")
            head.headers.add(name: "Connection", value: "close")
            if let body = request.body {
                head.headers.add(name: "Content-Length", value: String(body.count))
            }
            for header in request.headers {
                head.headers.replaceOrAdd(name: header.name, value: header.value)
            }
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body = request.body, !body.isEmpty {
                channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
            }
            // The collector is in the pipeline from the start, so a connection that closes first fails the response
            // with what it saw (`connectionClosed`, a TLS error), not NIO's "I/O on closed channel" for the write.
            channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { error in
                promise.fail(error is ChannelError ? HTTPClientError.connectionClosed : error)
                channel.close(promise: nil)
            }
            var response = try await withTaskCancellationHandler {
                try await promise.futureResult.get()
            } onCancel: {
                promise.fail(CancellationError())
                channel.close(promise: nil)
            }
            deadline.cancel()
            channel.close(promise: nil)
            response.certificateFingerprint = observed.withLockedValue { $0 }
            return response
        } catch {
            deadline.cancel()
            promise.fail(error)
            channel.close(promise: nil)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            let progress = progress.withLockedValue { $0 }
            if !progress.responseStarted, Self.isDrop(error) {
                let unsent = !progress.flushed || progress.handshakeIncomplete
                throw DroppedConnection(error: error is ChannelError ? HTTPClientError.connectionClosed : error, unsent: unsent)
            }
            throw error
        }
    }

    /// A connection the server closed (or reset) under the request, as opposed to a refusal, a timeout or a TLS
    /// failure.
    private static func isDrop(_ error: any Error) -> Bool {
        switch error {
        case let error as HTTPClientError: error == .connectionClosed
        case let error as ChannelError: error == .ioOnClosedChannel || error == .eof || error == .alreadyClosed
        case let error as IOError: [ECONNRESET, EPIPE, ECONNABORTED].contains(error.errnoCode)
        case let error as NIOSSLError: error == .uncleanShutdown || closedDuringHandshake(error)
        default: false
        }
    }

    /// NIOSSL's error for a connection closed during the TLS handshake.
    private static func closedDuringHandshake(_ error: any Error) -> Bool {
        guard let error = error as? NIOSSLError else { return false }
        return error == .handshakeFailed(.sslError([.eofDuringHandshake])) || error == .handshakeFailed(.sslError([.eofDuringAdditionalCertficiateChainValidation]))
    }

    private func connect(
        host: String, port: Int, secure: Bool, eventLoop: any EventLoop, observed: NIOLockedValueBox<String?>,
        mismatch: NIOLockedValueBox<HTTPClientError?>, timeout: Duration, collector: @escaping @Sendable () -> ResponseCollector
    ) async throws -> any Channel {
        let tls = tls
        let context = secure ? try self.context() : nil
        // SNI carries host names only; a TV is reached by its address.
        let serverName = host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) ? nil : host
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(TimeAmount(timeout))
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context {
                        let handler: NIOSSLClientHandler
                        switch tls {
                        case .system:
                            handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
                        case .any, .pinned:
                            handler = try NIOSSLClientHandler(context: context, serverHostname: serverName) { certificates, promise in
                                guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                                    promise.succeed(.failed)
                                    return
                                }
                                let fingerprint = HTTPClient.fingerprint(der: der)
                                observed.withLockedValue { $0 = fingerprint }
                                if case .pinned(let expected) = tls, HTTPClient.normalizeFingerprint(expected) != fingerprint {
                                    mismatch.withLockedValue { $0 = .certificateMismatch(expected: HTTPClient.normalizeFingerprint(expected), observed: fingerprint) }
                                    promise.succeed(.failed)
                                    return
                                }
                                promise.succeed(.certificateVerified)
                            }
                        }
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(collector())
                }
            }
        do {
            return try await bootstrap.connect(host: host, port: port).get()
        } catch {
            let (code, reason) = connectionFailure(error)
            throw HTTPClientError.cannotConnect(host: host, port: port, code: code, reason: reason)
        }
    }

    private func context() throws -> NIOSSLContext {
        try sslContext.withLockedValue { cached in
            if let cached { return cached }
            var configuration = TLSConfiguration.makeClientConfiguration()
            if case .system = tls {} else {
                // The callback decides; nothing a self-signed certificate lacks should fail the handshake first.
                configuration.certificateVerification = .noHostnameVerification
            }
            if let cipherSuites {
                // NIOSSL stops the process on a list BoringSSL refuses.
                guard TLSCipherList.isUsable(cipherSuites) else { throw TLSCipherListError(list: cipherSuites) }
                configuration.cipherSuites = cipherSuites
            }
            let context = try NIOSSLContext(configuration: configuration)
            cached = context
            return context
        }
    }
}

/// The request target of a URL as the request line carries it: the path and query still percent-encoded, `/` for
/// no path. (`URL.path` decodes: `%20` would put a space in the request line, `%2F` would become a separator.)
/// Shared by the HTTP and WebSocket clients.
func requestTarget(of url: URL) -> String {
    let path = url.path(percentEncoded: true)
    var target = path.isEmpty ? "/" : path
    if let query = url.query(percentEncoded: true) { target += "?\(query)" }
    return target
}

/// A failure `send` may retry: the connection closed before any of the response arrived. `unsent`: before any of
/// the request went out either.
private struct DroppedConnection: Error {
    var error: any Error
    var unsent: Bool
}

/// The errno of a failed connection when the system gave one, and a short reason: its message, else the error.
/// Shared by the HTTP, WebSocket and MQTT clients.
func connectionFailure(_ error: any Error) -> (code: Int32?, reason: String) {
    let underlying = (error as? NIOConnectionError)?.connectionErrors.first?.error ?? error
    if let io = underlying as? IOError { return (io.errnoCode, String(cString: strerror(io.errnoCode)).lowercased()) }
    return (nil, "\(underlying)")
}

/// Collects the parts of one response into an `HTTPResponse`, in the pipeline from the start so that it sees how a
/// connection ends, and records how far the exchange got for the retry.
private final class ResponseCollector: ChannelDuplexHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    struct Progress {
        /// The request was flushed while the connection was open: some of it may have reached the server.
        var flushed = false
        /// The connection ended before the server's certificate arrived, so before the TLS handshake completed:
        /// the TLS handler still held the request.
        var handshakeIncomplete = false
        var responseStarted = false
    }

    private let promise: EventLoopPromise<HTTPResponse>
    private let limit: Int
    private let progress: NIOLockedValueBox<Progress>
    private var status = 0
    private var headers: [(name: String, value: String)] = []
    private var body = Data()
    private var done = false

    init(promise: EventLoopPromise<HTTPResponse>, limit: Int, progress: NIOLockedValueBox<Progress>) {
        self.promise = promise
        self.limit = limit
        self.progress = progress
    }

    func flush(context: ChannelHandlerContext) {
        if context.channel.isActive { progress.withLockedValue { $0.flushed = true } }
        context.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        progress.withLockedValue { $0.responseStarted = true }
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headers = head.headers.map { (name: $0.name, value: $0.value) }
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= limit else {
                done = true
                promise.fail(HTTPClientError.responseTooLarge(limit: limit))
                context.close(promise: nil)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            done = true
            promise.succeed(HTTPResponse(status: status, headers: headers, body: body))
        }
    }

    /// Before the response fails: whether the TLS handshake got as far as the server's certificate.
    private func noteHandshake(context: ChannelHandlerContext) {
        guard !done, let tls = try? context.pipeline.syncOperations.handler(type: NIOSSLHandler.self), tls.peerCertificate == nil else { return }
        progress.withLockedValue { $0.handshakeIncomplete = true }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        noteHandshake(context: context)
        done = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        noteHandshake(context: context)
        if !done {
            done = true
            promise.fail(HTTPClientError.connectionClosed)
        }
        context.fireChannelInactive()
    }
}
