import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// HTTP plumbing shared by the provider adapters: POST JSON with retries, and Server-Sent Events.

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(method: String = "POST", url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// A streaming response: the status and headers at once, the body as it arrives.
public struct HTTPStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How requests reach a provider. Tests replace it with canned responses.
public protocol HTTPTransport: Sendable {
    func post(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

public struct URLSessionTransport: HTTPTransport {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    private func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    static func headers(of response: URLResponse) -> (Int, [String: String]) {
        guard let http = response as? HTTPURLResponse else { return (0, [:]) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return (http.statusCode, headers)
    }

    public func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: urlRequest(request))
        let (status, headers) = Self.headers(of: response)
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    #if canImport(FoundationNetworking)
    /// Linux's Foundation has no `URLSession.bytes(for:)`: a delegate hands the body over as it arrives.
    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let delegate = StreamingDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest(request))
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            delegate.attach(continuation)
            continuation.onTermination = { _ in task.cancel() }
        }
        task.resume()
        let (status, headers) = try await delegate.response()
        return HTTPStream(status: status, headers: headers, body: body)
    }
    #else
    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest(request))
        let (status, headers) = Self.headers(of: response)
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(line)
                            line = Data()
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStream(status: status, headers: headers, body: body)
    }
    #endif
}

#if canImport(FoundationNetworking)
/// Resolves `response()` with the status and headers, then feeds the body to the attached stream.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var body: AsyncThrowingStream<Data, any Error>.Continuation?
    private var waiting: CheckedContinuation<(Int, [String: String]), any Error>?
    private var head: (Int, [String: String])?
    private var failure: (any Error)?

    func attach(_ continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        lock.withLock { body = continuation }
    }

    func response() async throws -> (Int, [String: String]) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let head {
                continuation.resume(returning: head)
            } else if let failure {
                continuation.resume(throwing: failure)
            } else {
                waiting = continuation
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let head = URLSessionTransport.headers(of: response)
        lock.lock()
        self.head = head
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(returning: head)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { body }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        failure = error
        let waiting = self.waiting
        self.waiting = nil
        let body = self.body
        lock.unlock()
        if let error {
            waiting?.resume(throwing: error)
            body?.finish(throwing: error)
        } else {
            body?.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
#endif

/// How `postJSON` retries transient failures: network errors and 408, 429, 5xx (Anthropic's 529 too).
public struct RetryOptions: Sendable {
    /// Retries after the first attempt (default 2; 0 disables retrying).
    public var maxRetries = 2
    /// First backoff step; doubles per attempt, with full jitter.
    public var baseDelay: Duration = .milliseconds(500)
    /// Upper bound of one backoff step.
    public var maxDelay: Duration = .seconds(8)
    /// Longest `retry-after` the client waits for; a longer one fails at once.
    public var maxRetryAfter: Duration = .seconds(60)

    public init(maxRetries: Int = 2) {
        self.maxRetries = maxRetries
    }

    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || status >= 500
    }

    /// The longest wait a header can ask for; anything beyond is capped (and then exceeds `maxRetryAfter`).
    static let longestRetryAfter: Double = 86_400_000

    /// The wait a `retry-after` (seconds or an HTTP date) or `retry-after-ms` header asks for.
    public static func retryAfter(_ headers: [String: String], now: Date = Date()) -> Duration? {
        func milliseconds(_ value: Double) -> Duration? {
            guard value.isFinite, value >= 0 else { return nil }
            return .milliseconds(Int(min(value, longestRetryAfter)))
        }
        if let ms = headers["retry-after-ms"].flatMap(Double.init) {
            return milliseconds(ms)
        }
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) {
            return milliseconds(seconds * 1000)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .milliseconds(max(0, Int(date.timeIntervalSince(now) * 1000)))
    }

    /// Full-jitter exponential backoff for retry `attempt` (0-based).
    func backoff(attempt: Int, random: Double = Double.random(in: 0...1)) -> Duration {
        let base = Double(baseDelay.components.seconds) + Double(baseDelay.components.attoseconds) / 1e18
        let cap = Double(maxDelay.components.seconds) + Double(maxDelay.components.attoseconds) / 1e18
        let step = min(cap, base * pow(2, Double(attempt)))
        return .milliseconds(Int(random * step * 1000))
    }
}

/// POST JSON, turning network failures and non-2xx statuses into a `ProviderError`, retrying transient
/// ones with jittered exponential backoff and honouring `retry-after`. A streaming request retries only
/// until the response starts.
enum HTTPClient {
    static func post(_ provider: String, transport: any HTTPTransport, request: HTTPRequest, retry: RetryOptions) async throws -> HTTPResponse {
        try await attempt(provider, retry: retry) {
            let response = try await transport.post(request)
            return (response.status, response.headers, response, String(decoding: response.body.prefix(2000), as: UTF8.self))
        }
    }

    static func stream(_ provider: String, transport: any HTTPTransport, request: HTTPRequest, retry: RetryOptions) async throws -> HTTPStream {
        try await attempt(provider, retry: retry) {
            let stream = try await transport.stream(request)
            if (200..<300).contains(stream.status) { return (stream.status, stream.headers, stream, "") }
            var detail = Data()
            for try await chunk in stream.body where detail.count < 2000 { detail.append(chunk) }
            return (stream.status, stream.headers, stream, String(decoding: detail, as: UTF8.self))
        }
    }

    private static func attempt<T>(
        _ provider: String, retry: RetryOptions,
        _ send: () async throws -> (status: Int, headers: [String: String], value: T, errorBody: String)
    ) async throws -> T {
        for attempt in 0... {
            var failure: ProviderError
            var retryAfter: Duration?
            do {
                let (status, headers, value, errorBody) = try await send()
                if (200..<300).contains(status) { return value }
                let error = ProviderError(provider: provider, message: "HTTP \(status): \(errorDetail(errorBody))", status: status)
                guard RetryOptions.isRetryable(status: status) else { throw error }
                failure = error
                retryAfter = RetryOptions.retryAfter(headers)
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = ProviderError(provider: provider, message: "cannot reach the provider: \(error.localizedDescription)")
            }
            if attempt >= retry.maxRetries { throw failure }
            if let retryAfter, retryAfter > retry.maxRetryAfter { throw failure }
            let wait = max(retryAfter ?? .zero, retry.backoff(attempt: attempt))
            try await Task.sleep(for: wait)
        }
        fatalError("unreachable")
    }

    /// The useful part of a provider error body, with anything key-like redacted.
    static func errorDetail(_ text: String) -> String {
        if let json = try? JSONValue(string: text) {
            let message = json["error"]?.stringValue ?? json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue
            if let message, !message.isEmpty { return Redaction.redactText(message) }
        }
        let trimmed = Redaction.redactText(String(text.prefix(500)))
        return trimmed.isEmpty ? "no details" : trimmed
    }
}

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
}

/// Parses a `text/event-stream` body into events.
public enum SSE {
    public static func events(_ body: AsyncThrowingStream<Data, any Error>) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Bytes, not Characters: Swift folds "\r\n" into one Character, which would hide the newline.
                var buffer: [UInt8] = []
                var event: String?
                var data: [String] = []
                func flush() {
                    if !data.isEmpty {
                        continuation.yield(SSEEvent(event: event, data: data.joined(separator: "\n")))
                    }
                    event = nil
                    data = []
                }
                func handle(_ bytes: ArraySlice<UInt8>) {
                    var line = bytes
                    if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    if text.isEmpty {
                        flush()
                    } else if text.hasPrefix("data:") {
                        var value = String(text.dropFirst(5))
                        if value.hasPrefix(" ") { value.removeFirst() }
                        data.append(value)
                    } else if text.hasPrefix("event:") {
                        event = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    }
                }
                do {
                    for try await chunk in body {
                        buffer.append(contentsOf: chunk)
                        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            handle(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                        }
                    }
                    if !buffer.isEmpty { handle(buffer[...]) }
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses the JSON payload of an event.
    public static func parse(_ provider: String, _ data: String) throws -> JSONValue {
        do {
            return try JSONValue(string: data)
        } catch {
            throw ProviderError(provider: provider, message: "malformed stream event: \(data.prefix(200))")
        }
    }
}

/// Parses tool-call arguments, which providers send as a JSON string.
func parseArguments(_ provider: String, _ raw: String?) throws -> JSONValue {
    guard let raw, !raw.isEmpty else { return .object([:]) }
    do {
        let value = try JSONValue(string: raw)
        return value.objectValue == nil ? .object([:]) : value
    } catch {
        throw ProviderError(provider: provider, message: "tool call arguments are not valid JSON: \(raw.prefix(200))")
    }
}
