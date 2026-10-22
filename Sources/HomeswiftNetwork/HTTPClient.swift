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
    /// The connection failed: nothing listens, no route, the host is asleep.
    case cannotConnect(host: String, port: Int, reason: String)
    case timeout
    /// The server's certificate is not the pinned one. Both are SHA-256 fingerprints.
    case certificateMismatch(expected: String, observed: String)
    case connectionClosed
    case responseTooLarge(limit: Int)

    public var description: String {
        switch self {
        case .invalidURL(let url): "cannot request \(url)"
        case .cannotConnect(let host, let port, let reason): "cannot connect to \(host):\(port): \(reason)"
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
/// minute, and keep-alive would only hold a socket open on a TV that drops it anyway. The TLS mode decides
/// what the client accepts from a server: the system's roots (`.system`), any certificate (`.any`, trust on
/// first use), or exactly one (`.pinned`). The last two record the certificate's fingerprint on the response
/// so the caller can pin it from then on.
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
    /// Responses larger than this fail instead of filling memory.
    public let maximumBodySize: Int
    private let group: any EventLoopGroup
    private let sslContext: NIOLockedValueBox<NIOSSLContext?> = .init(nil)

    public init(tls: TLS = .system, maximumBodySize: Int = 4 * 1024 * 1024, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.tls = tls
        self.maximumBodySize = maximumBodySize
        self.group = group
    }

    /// A fingerprint as the client compares it: lowercase hex without separators.
    public static func normalizeFingerprint(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter(\.isHexDigit)
    }

    /// The SHA-256 fingerprint of a DER certificate.
    public static func fingerprint(der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = request.url.host, !host.isEmpty else {
            throw HTTPClientError.invalidURL(request.url.absoluteString)
        }
        let secure = scheme == "https"
        let port = request.url.port ?? (secure ? 443 : 80)
        var uri = request.url.path.isEmpty ? "/" : request.url.path
        if let query = request.url.query { uri += "?\(query)" }

        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<HTTPClientError?>(nil)
        let channel: any Channel
        do {
            channel = try await connect(host: host, port: port, secure: secure, observed: observed, mismatch: mismatch, timeout: request.timeout)
        } catch {
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
        let promise = channel.eventLoop.makePromise(of: HTTPResponse.self)
        let deadline = channel.eventLoop.scheduleTask(in: TimeAmount(request.timeout)) {
            promise.fail(HTTPClientError.timeout)
            channel.close(promise: nil)
        }
        do {
            try await channel.pipeline.addHandler(ResponseCollector(promise: promise, limit: maximumBodySize)).get()
            var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method.uppercased()), uri: uri)
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
            try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
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
            throw error
        }
    }

    private func connect(
        host: String, port: Int, secure: Bool, observed: NIOLockedValueBox<String?>, mismatch: NIOLockedValueBox<HTTPClientError?>, timeout: Duration
    ) async throws -> any Channel {
        let tls = tls
        let context = secure ? try self.context() : nil
        // SNI carries host names only; a TV is reached by its address.
        let serverName = host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) ? nil : host
        let bootstrap = ClientBootstrap(group: group)
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
                }
            }
        do {
            return try await bootstrap.connect(host: host, port: port).get()
        } catch let error as NIOConnectionError {
            throw HTTPClientError.cannotConnect(host: host, port: port, reason: Self.reason(for: error.connectionErrors.first?.error ?? error))
        } catch {
            throw HTTPClientError.cannotConnect(host: host, port: port, reason: Self.reason(for: error))
        }
    }

    /// A short reason for a failed connection: the system's message for an errno, else the error.
    private static func reason(for error: any Error) -> String {
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)).lowercased() }
        if error is HTTPClientError { return "\(error)" }
        return "\(error)"
    }

    private func context() throws -> NIOSSLContext {
        try sslContext.withLockedValue { cached in
            if let cached { return cached }
            var configuration = TLSConfiguration.makeClientConfiguration()
            if case .system = tls {} else {
                // The callback decides; nothing a self-signed certificate lacks should fail the handshake first.
                configuration.certificateVerification = .noHostnameVerification
            }
            let context = try NIOSSLContext(configuration: configuration)
            cached = context
            return context
        }
    }
}

/// Collects the parts of one response into an `HTTPResponse`.
private final class ResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<HTTPResponse>
    private let limit: Int
    private var status = 0
    private var headers: [(name: String, value: String)] = []
    private var body = Data()
    private var done = false

    init(promise: EventLoopPromise<HTTPResponse>, limit: Int) {
        self.promise = promise
        self.limit = limit
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        done = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            promise.fail(HTTPClientError.connectionClosed)
        }
        context.fireChannelInactive()
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let nanoseconds = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        self = .nanoseconds(max(1, nanoseconds))
    }
}
