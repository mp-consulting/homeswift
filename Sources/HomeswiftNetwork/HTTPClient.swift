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
    let group: any EventLoopGroup
    /// `tls` and `cipherSuites` as the WebSocket and MQTT clients take them; it builds the context once per client.
    private let tlsOptions: TLSOptions

    public init(
        tls: TLS = .system, cipherSuites: String? = nil, maximumBodySize: Int = 4 * 1024 * 1024,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.tls = tls
        self.cipherSuites = cipherSuites
        self.maximumBodySize = maximumBodySize
        self.group = group
        var tlsOptions = TLSOptions(tls)
        tlsOptions.cipherSuites = cipherSuites
        self.tlsOptions = tlsOptions
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
            throw HTTPClientError.invalidURL(redactingPassword(request.url))
        }
        let secure = scheme == "https"
        let port = request.url.port ?? (secure ? 443 : 80)
        let deadline = ContinuousClock.now + request.timeout
        do {
            return try await exchange(request, host: host, port: port, secure: secure, deadline: deadline)
        } catch let dropped as DroppedConnection {
            // The server closed the connection without a byte of an answer (a restart, a connection limit, an idle
            // timeout): once more on a fresh connection, when the request never went out or may be seen twice.
            guard dropped.unsent || Self.idempotentMethods.contains(request.method.uppercased()), deadline > .now else { throw dropped.error }
            do {
                return try await exchange(request, host: host, port: port, secure: secure, deadline: deadline)
            } catch let dropped as DroppedConnection {
                throw dropped.error
            }
        }
    }

    /// Methods a server may receive twice without harm (RFC 9110, 9.2.2).
    static let idempotentMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"]

    /// One request on one new connection, connecting and answering before `deadline`. A connection that closed before
    /// any of the response arrived throws `DroppedConnection`, which `send` may retry.
    private func exchange(_ request: HTTPRequest, host: String, port: Int, secure: Bool, deadline: ContinuousClock.Instant) async throws -> HTTPResponse {
        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<(any Error)?>(nil)
        let progress = NIOLockedValueBox(ResponseCollector.Progress())
        let eventLoop = group.next()
        let promise = eventLoop.makePromise(of: HTTPResponse.self)
        let limit = maximumBodySize
        let channel: any Channel
        do {
            channel = try await connect(
                host: host, port: port, secure: secure, eventLoop: eventLoop, observed: observed, mismatch: mismatch, timeout: deadline - .now
            ) { ResponseCollector(promise: promise, limit: limit, progress: progress) }
        } catch {
            promise.fail(error)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
        // What the connection left of the request's time, not the whole of it again.
        let timer = channel.eventLoop.scheduleTask(in: TimeAmount(max(.zero, deadline - .now))) {
            promise.fail(HTTPClientError.timeout)
            channel.close(promise: nil)
        }
        do {
            writeRequest(request, on: channel, host: host, port: port, secure: secure) { promise.fail($0) }
            var response = try await withTaskCancellationHandler {
                try await promise.futureResult.get()
            } onCancel: {
                promise.fail(CancellationError())
                channel.close(promise: nil)
            }
            timer.cancel()
            channel.close(promise: nil)
            response.certificateFingerprint = observed.withLockedValue { $0 }
            return response
        } catch {
            timer.cancel()
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

    /// Writes `request` on a connected channel, `Connection: close`. A write that fails (the connection closed first)
    /// calls `failed` and closes the channel; the collector is in the pipeline from the start, so it fails the response
    /// with what it saw (`connectionClosed`, a TLS error), not NIO's "I/O on closed channel" for the write.
    func writeRequest(_ request: HTTPRequest, on channel: any Channel, host: String, port: Int, secure: Bool, failed: @escaping @Sendable (any Error) -> Void) {
        var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method.uppercased()), uri: requestTarget(of: request.url))
        head.headers.add(name: "Host", value: hostHeader(host: host, port: port, defaultPort: secure ? 443 : 80))
        head.headers.add(name: "Connection", value: "close")
        if let body = request.body {
            head.headers.add(name: "Content-Length", value: String(body.count))
        }
        head.headers.applying(request.headers)
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body = request.body, !body.isEmpty {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { error in
            failed(error is ChannelError ? HTTPClientError.connectionClosed : error)
            channel.close(promise: nil)
        }
    }

    /// A connection the server closed (or reset) under the request, as opposed to a refusal, a timeout or a TLS
    /// failure. The WebSocket client ends its stream on the same errors as a dropped connection.
    static func isDrop(_ error: any Error) -> Bool {
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

    func connect(
        host: String, port: Int, secure: Bool, eventLoop: any EventLoop, observed: NIOLockedValueBox<String?>,
        mismatch: NIOLockedValueBox<(any Error)?>, timeout: Duration, collector: @escaping @Sendable () -> any ChannelHandler
    ) async throws -> any Channel {
        let tlsOptions = tlsOptions
        let context = secure ? try tlsOptions.makeContext() : nil
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(TimeAmount(max(.zero, timeout)))
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context {
                        try channel.pipeline.syncOperations.addHandler(
                            tlsOptions.makeHandler(context: context, host: host, observed: observed, mismatch: mismatch)
                        )
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
}

/// The `Host` header for a host and port: an IPv6 address in brackets, no port when it is the scheme's default.
/// Shared by the HTTP and WebSocket clients and AWS signing, so the signed `Host` is the one sent.
func hostHeader(host: String, port: Int, defaultPort: Int) -> String {
    let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return port == defaultPort ? name : "\(name):\(port)"
}

/// A URL for an error message, without its password (`mqtt://user:pass@host` is a broker URL users write).
func redactingPassword(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.password != nil else { return url.absoluteString }
    components.percentEncodedPassword = "***"
    return components.string ?? "(a URL with a password)"
}

extension HTTPHeaders {
    /// Adds a request's own headers: each name it sets replaces the client's default (`Host`, `Connection`), and a
    /// name it repeats (`Cookie`) is sent once for each value.
    mutating func applying(_ headers: [(name: String, value: String)]) {
        for name in Set(headers.map { $0.name.lowercased() }) { remove(name: name) }
        for header in headers { add(name: header.name, value: header.value) }
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
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= limit else {
                done = true
                promise.fail(HTTPClientError.responseTooLarge(limit: limit))
                context.close(promise: nil)
                return
            }
            body.append(contentsOf: buffer.readableBytesView)
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

/// A response body as one log line: an HTML page (a server answering an error with a web page) by its title, else by its
/// text without the tags, scripts and styles; any other text with its runs of spaces and line breaks made one space;
/// cut to `limit` characters, nil when there is nothing. Only the start of a long body is read.
public func logExcerpt(_ text: String, limit: Int = 200) -> String? {
    let head = text.prefix(4 * limit + 1024)
    if head.range(of: "<html", options: .caseInsensitive) != nil || head.range(of: "<!doctype html", options: .caseInsensitive) != nil {
        let title = head.range(of: "<title>", options: .caseInsensitive).flatMap { start in
            head.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<head.endIndex).map { head[start.upperBound..<$0.lowerBound] }
        }
        let text = title.map(String.init) ?? head.replacingOccurrences(of: "(?is)<(script|style)\\b.*?</\\1>|<[^>]*>", with: " ", options: .regularExpression)
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? "an HTML page" : "an HTML page, \(words.prefix(limit))"
    }
    let words = head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return words.isEmpty ? nil : String(words.prefix(limit))
}
