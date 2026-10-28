import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// A response handed back once its head arrives, its body following as the server sends it: an event stream
/// (`text/event-stream`), a long download.
public struct HTTPStreamingResponse: Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    /// The server's certificate, as `HTTPResponse.certificateFingerprint`.
    public var certificateFingerprint: String?
    /// The body's bytes as they come. It finishes when the server ends the response and throws when the connection
    /// fails; leaving its loop (or cancelling the task) closes the connection.
    public var body: Body

    public init(status: Int, headers: [(name: String, value: String)] = [], certificateFingerprint: String? = nil, body: Body) {
        self.status = status
        self.headers = headers
        self.certificateFingerprint = certificateFingerprint
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The first header with this name, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body read as server-sent events (`ServerSentEvents`).
    public var events: Events { Events(body: body) }

    /// A streamed body. The connection closes when its stream ends on the consumer's side (a loop that breaks, a
    /// cancelled task, the sequence released), through the stream's `onTermination`.
    public struct Body: AsyncSequence, Sendable {
        public typealias Element = [UInt8]
        let stream: AsyncThrowingStream<[UInt8], any Error>

        public init(_ stream: AsyncThrowingStream<[UInt8], any Error>) { self.stream = stream }

        public func makeAsyncIterator() -> AsyncThrowingStream<[UInt8], any Error>.Iterator { stream.makeAsyncIterator() }
    }

    /// The body's server-sent events, as they complete.
    public struct Events: AsyncSequence, Sendable {
        public typealias Element = ServerSentEvent
        let body: Body

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(body: body.makeAsyncIterator()) }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var body: AsyncThrowingStream<[UInt8], any Error>.Iterator
            var parser = ServerSentEvents()
            var ready: [ServerSentEvent] = []

            public mutating func next() async throws -> ServerSentEvent? {
                while ready.isEmpty {
                    guard let chunk = try await body.next() else { return nil }
                    ready = parser.feed(chunk)
                }
                return ready.removeFirst()
            }
        }
    }
}

/// Something that answers a request with a streamed body: the real client, or a fake device in tests.
public protocol HTTPStreaming: Sendable {
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse
}

extension HTTPClient: HTTPStreaming {
    /// Sends `request` and answers once the response's head arrives; `request.timeout` covers connecting and the head,
    /// not the body, which may go on for hours. The body's bytes come on `HTTPStreamingResponse.body`.
    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = request.url.host, !host.isEmpty else {
            throw HTTPClientError.invalidURL(redactingPassword(request.url))
        }
        let secure = scheme == "https"
        let port = request.url.port ?? (secure ? 443 : 80)
        let deadline = ContinuousClock.now + request.timeout
        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<(any Error)?>(nil)
        let eventLoop = group.next()
        let head = eventLoop.makePromise(of: (status: Int, headers: [(name: String, value: String)]).self)
        let (body, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        let channel: any Channel
        do {
            channel = try await connect(
                host: host, port: port, secure: secure, eventLoop: eventLoop, observed: observed, mismatch: mismatch, timeout: deadline - .now
            ) { StreamingCollector(head: head, body: continuation) }
        } catch {
            head.fail(error)
            continuation.finish(throwing: error)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
        continuation.onTermination = { _ in channel.close(promise: nil) }
        let timer = channel.eventLoop.scheduleTask(in: TimeAmount(max(.zero, deadline - .now))) {
            head.fail(HTTPClientError.timeout)
            channel.close(promise: nil)
        }
        writeRequest(request, on: channel, host: host, port: port, secure: secure) { head.fail($0) }
        do {
            let answer = try await withTaskCancellationHandler {
                try await head.futureResult.get()
            } onCancel: {
                head.fail(CancellationError())
                channel.close(promise: nil)
            }
            timer.cancel()
            return HTTPStreamingResponse(status: answer.status, headers: answer.headers, certificateFingerprint: observed.withLockedValue { $0 }, body: HTTPStreamingResponse.Body(body))
        } catch {
            timer.cancel()
            channel.close(promise: nil)
            continuation.finish(throwing: error)
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw error
        }
    }
}

/// Hands the response's head to a promise and its body, piece by piece, to a stream.
private final class StreamingCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let head: EventLoopPromise<(status: Int, headers: [(name: String, value: String)])>
    private let body: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private var done = false

    init(head: EventLoopPromise<(status: Int, headers: [(name: String, value: String)])>, body: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
        self.head = head
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let response):
            head.succeed((Int(response.status.code), response.headers.map { (name: $0.name, value: $0.value) }))
        case .body(let buffer):
            body.yield(Array(buffer.readableBytesView))
        case .end:
            done = true
            body.finish()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(throwing: HTTPClientError.connectionClosed)
        context.fireChannelInactive()
    }

    private func finish(throwing error: any Error) {
        head.fail(error)
        guard !done else { return }
        done = true
        body.finish(throwing: error)
    }
}

/// One event of a `text/event-stream`: its `event` name (`message` when the server gives none), its data lines joined
/// with newlines, and its `id`.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Reads server-sent events from a body's bytes as they arrive, after the HTML standard's parsing rules: lines end with
/// LF, CR or CRLF, a blank line dispatches the event, `data:` lines are joined with newlines, a line starting with `:`
/// is a comment (a keep-alive), and an event without data is dropped.
public struct ServerSentEvents: Sendable {
    private var pending: [UInt8] = []
    private var event = ""
    private var data: [String] = []
    private var id: String?
    /// A CR ended the last chunk: an LF opening the next one belongs to it.
    private var afterCR = false

    public init() {}

    /// The events `chunk` completes.
    public mutating func feed(_ chunk: [UInt8]) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in chunk {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A, 0x0D:
                afterCR = byte == 0x0D
                if let event = line(String(decoding: pending, as: UTF8.self)) { events.append(event) }
                pending.removeAll(keepingCapacity: true)
            default:
                pending.append(byte)
            }
        }
        return events
    }

    private mutating func line(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { event = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return ServerSentEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let rest = line[line.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            (field, value) = (line[...], "")
        }
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        case "id" where !value.contains("\0"): id = String(value)
        default: break
        }
        return nil
    }
}
