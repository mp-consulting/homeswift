import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The errors of the Homebridge plugin, with LG's result codes.
public enum ThinQError: Error, CustomStringConvertible, Equatable, Sendable {
    /// LG rejected the account or the sign-in.
    case authentication(String)
    /// The token exchange or the session failed.
    case token(String)
    /// `0102`, or HTTP 401/403: the access token has expired.
    case tokenExpired(String)
    /// `0106`, `0111`, `9999`, or no answer: the device or LG is unreachable.
    case notConnected(String)
    /// `0110`: LG wants the user in its app, usually to accept new terms.
    case manualProcessNeeded(String)
    /// A ThinQ v1 monitoring answer other than `0000`.
    case monitor(String)
    /// An HTTP error none of the above covers; `body` is LG's answer.
    case http(status: Int, body: JSONValue)
    case invalid(String)

    public static let tokenExpiredCode = "0102"
    public static let manualProcessNeededCode = "0110"
    public static let notConnectedCodes = ["0106", "0111"]

    public var description: String {
        switch self {
        case .authentication(let message), .token(let message), .tokenExpired(let message), .notConnected(let message),
            .manualProcessNeeded(let message), .monitor(let message), .invalid(let message):
            message
        case .http(let status, let body):
            "Request failed with status code \(status)" + (Self.excerpt(body.stringValue ?? body.text()).map { ": \($0)" } ?? "")
        }
    }

    /// A body for one log line: an HTML page by its title (LG answers some errors with a whole web page), any other text
    /// with its runs of spaces and line breaks made one space, cut to 200 characters.
    static func excerpt(_ text: String) -> String? {
        let lowered = text.lowercased()
        if lowered.contains("<html") || lowered.contains("<!doctype html") {
            let title = text.range(of: "<title>", options: .caseInsensitive).flatMap { start in
                text.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<text.endIndex).map { text[start.upperBound..<$0.lowerBound] }
            }
            let words = title.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
            return words.isEmpty ? "an HTML page" : "an HTML page, \(words.prefix(200))"
        }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : String(words.prefix(200))
    }
}

/// LG's shared request pipeline, as the Homebridge plugin's axios client: one request at a time (LG throttles
/// accounts), up to two retries two and four seconds apart for connection errors and 5xx answers, and LG's
/// result codes turned into `ThinQError`s.
@ThinQActor
final class RequestClient {
    static let timeout: Duration = .seconds(60)
    static let retries = 2
    static let retryDelay: Duration = .seconds(2)

    let transport: any HTTPSending
    let logger: Logger
    /// Overridable in tests so retries do not wait.
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any HTTPSending, logger: Logger) {
        self.transport = transport
        self.logger = logger
    }

    /// Sends a request and answers its JSON body (or text). Throws `ThinQError`s for LG's error codes and HTTP errors.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await slot { try await self.transport.send(request) }
            } catch let error as ThinQNetworkError {
                if error.isConnectionError, attempt < Self.retries {
                    attempt += 1
                    await sleep(Self.retryDelay * attempt)
                    continue
                }
                throw ThinQError.notConnected(error.message)
            }
            if (500...504).contains(response.status), attempt < Self.retries {
                attempt += 1
                await sleep(Self.retryDelay * attempt)
                continue
            }
            logger.debug("[request] \(request.method.lowercased()) \(request.url.absoluteString.split(separator: "?").first ?? "")")
            return try check(response)
        }
    }

    /// The response interceptors: ThinQ v1 answers carry `lgedmRoot.returnCd` on HTTP 200, errors carry `resultCode`.
    func check(_ response: HTTPResponse) throws -> HTTPResponse {
        let data = response.data
        if (200..<300).contains(response.status) {
            if let root = data["lgedmRoot"], let code = root["returnCd"] {
                let codeString = JS.string(code)
                let message = root["returnMsg"]?.stringValue ?? ""
                if ThinQError.notConnectedCodes.contains(codeString) { throw ThinQError.notConnected(message) }
                if codeString == ThinQError.tokenExpiredCode { throw ThinQError.tokenExpired(message) }
                if codeString != "0000" { throw ThinQError.monitor("\(codeString) - \(message)") }
            }
            return response
        }
        let resultCode = data["resultCode"].map { JS.string($0) }
        if resultCode == "9999" { throw ThinQError.notConnected("") }
        if resultCode == ThinQError.tokenExpiredCode { throw ThinQError.tokenExpired("") }
        if response.status == 401 || response.status == 403 { throw ThinQError.tokenExpired("HTTP \(response.status)") }
        if resultCode == ThinQError.manualProcessNeededCode {
            throw ThinQError.manualProcessNeeded("Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.")
        }
        throw ThinQError.http(status: response.status, body: data)
    }

    /// Only the network call holds the slot, so a retry never waits on its own attempt.
    private func slot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: Building requests

    func get(_ url: String, headers: [(name: String, value: String)] = []) async throws -> HTTPResponse {
        try await send(HTTPRequest(method: "GET", url: try Self.url(url), headers: headers, timeout: Self.timeout))
    }

    /// A form body, already encoded.
    func post(_ url: String, form: String, headers: [(name: String, value: String)]) async throws -> HTTPResponse {
        var headers = headers
        if !headers.contains(where: { $0.name.lowercased() == "content-type" }) { headers.append(("Content-Type", "application/x-www-form-urlencoded")) }
        return try await send(HTTPRequest(method: "POST", url: try Self.url(url), headers: headers, body: Data(form.utf8), timeout: Self.timeout))
    }

    /// A JSON body.
    func post(_ url: String, json: JSONValue, headers: [(name: String, value: String)]) async throws -> HTTPResponse {
        var headers = headers
        if !headers.contains(where: { $0.name.lowercased() == "content-type" }) { headers.append(("Content-Type", "application/json")) }
        return try await send(HTTPRequest(method: "POST", url: try Self.url(url), headers: headers, body: json.encoded(), timeout: Self.timeout))
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil else { throw ThinQError.invalid("Invalid URL: \(string)") }
        return url
    }
}

/// Everything that touches the ThinQ API runs here, one task at a time between suspension points, as the
/// Homebridge plugin's code runs on Node's single thread: the device handlers, the API's session and the
/// platform share their state without locks.
@globalActor
public actor ThinQActor {
    public static let shared = ThinQActor()
}

/// A cancellable `setTimeout` on the ThinQ actor.
@ThinQActor
final class Timeout {
    private var task: Task<Void, Never>?

    var isScheduled: Bool { task != nil }

    func schedule(after delay: Duration, _ action: @escaping @ThinQActor () async -> Void) {
        task?.cancel()
        task = Task { @ThinQActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.task = nil
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
