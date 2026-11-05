import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The Sync Box's REST API (docs/clean-room/HueSyncBox.md, sections 3 and 4): HTTPS on its own address, a Bearer token,
/// the whole state in one `GET /api/v1/`, writes as `PUT /api/v1/execution` and `PUT /api/v1/hue`.
///
/// The box handles few connections, so every request of a client goes through one lock, one at a time and in order: a
/// caller waits at most `Timing.lockWait` for its turn. A request has `Timing.budget` in all, `Timing.attempt` per attempt;
/// a transport failure (no connection, TLS, a timeout) is tried again after `Timing.retryDelays`, while the budget allows,
/// and a status that is not 2xx or a state that does not validate is not.
actor SyncBoxClient {
    /// The request timings of section 6.3, scaled for tests.
    struct Timing: Sendable {
        var attempt: Duration = .seconds(8)
        var budget: Duration = .seconds(12)
        var retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var lockWait: Duration = .seconds(15)

        static let standard = Timing()

        func scaled(_ factor: Double) -> Timing {
            func scale(_ duration: Duration) -> Duration { duration * factor }
            return Timing(attempt: scale(attempt), budget: scale(budget), retryDelays: retryDelays.map(scale), lockWait: scale(lockWait))
        }
    }

    /// Answers larger than this are refused (section 4.1).
    static let maximumBodySize = 100_000

    let baseURL: URL
    private let token: String?
    private let transport: any HTTPSending
    private let timing: Timing
    private let lock: RequestLock
    private let logger: Logger

    /// `address` is `syncBoxIpAddress`: an IPv4 address or a host name, with `:port` when it is not 443.
    init?(address: String, token: String?, transport: any HTTPSending, timing: Timing = .standard, logger: Logger) {
        guard let url = Self.baseURL(address) else { return nil }
        baseURL = url
        self.token = token
        self.transport = transport
        self.timing = timing
        lock = RequestLock()
        self.logger = logger
    }

    /// `https://<address>/api/v1/`; an IPv6 address goes in brackets. nil for an address no URL can hold.
    static func baseURL(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        // A host and a port only: no path, query, fragment or user that would move the requests elsewhere.
        guard !trimmed.isEmpty, !trimmed.contains(where: { "/@?#\\".contains($0) || $0.isWhitespace }) else { return nil }
        let host = trimmed.filter { $0 == ":" }.count > 1 && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
        guard let url = URL(string: "https://\(host)/api/v1/"), url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Reading and writing

    /// The whole state, validated (section 4.1).
    func state() async throws -> SyncBoxState {
        let response = try await send("GET", path: "", body: nil)
        return try SyncBoxState.parse(response.body)
    }

    /// `PUT /api/v1/execution` with a partial execution object: `{"mode":"video"}`, `{"brightness":80}`,
    /// `{"hdmiSource":"input2"}`, `{"music":{"intensity":"high"}}`.
    func setExecution(_ body: JSONValue) async throws {
        _ = try await send("PUT", path: "execution", body: body)
    }

    /// `PUT /api/v1/hue` with `{"groupId": <id>}`: the entertainment area.
    func setGroup(_ groupID: String) async throws {
        _ = try await send("PUT", path: "hue", body: ["groupId": .string(groupID)])
    }

    /// One request through the lock, retried on transport failures within the budget.
    private func send(_ method: String, path: String, body: JSONValue?) async throws -> HTTPResponse {
        try await lock.acquire(within: timing.lockWait)
        do {
            let response = try await attempts(method, path: path, body: body)
            await lock.release()
            return response
        } catch {
            await lock.release()
            throw error
        }
    }

    private func attempts(_ method: String, path: String, body: JSONValue?) async throws -> HTTPResponse {
        let url = path.isEmpty ? baseURL : baseURL.appendingPathComponent(path)
        var request = HTTPRequest(method: method, url: url, body: body?.encoded())
        // The token goes on the request only: never in a log line (the debug line says [REDACTED]).
        if let token { request.setHeader("Authorization", "Bearer \(token)") }
        request.setHeader("Content-Type", "application/json")
        let deadline = ContinuousClock.now + timing.budget
        var attempt = 0
        while true {
            request.timeout = min(timing.attempt, max(.milliseconds(1), deadline - .now))
            logger.debug("\(method) \(url.path) (Authorization: [REDACTED])")
            do {
                let response = try await transport.send(request)
                guard response.isSuccess else { throw SyncBoxError(response: response) }
                return response
            } catch let error where Self.isTransportFailure(error) {
                guard attempt < timing.retryDelays.count else { throw error }
                let delay = timing.retryDelays[attempt]
                // Not when the next try would start past the budget.
                guard ContinuousClock.now + delay < deadline else { throw error }
                attempt += 1
                logger.debug("Retrying \(method) \(url.path) in \(delay): \(error)")
                try await Task.sleep(for: delay)
            }
        }
    }

    /// A failure to reach the box rather than an answer from it: retried.
    static func isTransportFailure(_ error: any Error) -> Bool {
        switch error {
        case is SyncBoxError, is CancellationError: false
        case let error as HTTPClientError:
            switch error {
            case .invalidURL, .responseTooLarge: false
            default: true
            }
        default: true
        }
    }

    // MARK: Registration (section 3.1)

    struct Registration: Codable, Sendable, Equatable {
        var registrationId: String
        var accessToken: String
    }

    /// `POST /api/v1/registrations` without a token (a stale one makes it fail). `SyncBoxError.buttonNotPressed` until
    /// the button was pressed; the registration once it was.
    static func register(address: String, appName: String, instanceName: String, transport: any HTTPSending, timeout: Duration = .seconds(8)) async throws -> Registration {
        guard let base = baseURL(address), let url = URL(string: "registrations", relativeTo: base)?.absoluteURL else {
            throw HTTPClientError.invalidURL(address)
        }
        var request = HTTPRequest(method: "POST", url: url, body: JSONValue.object(["appName": .string(appName), "instanceName": .string(instanceName)]).encoded(), timeout: timeout)
        request.setHeader("Content-Type", "application/json")
        let response = try await transport.send(request)
        guard response.isSuccess else {
            let error = SyncBoxError(response: response)
            throw error.code == 16 ? SyncBoxError.buttonNotPressed : error
        }
        guard let json = try? JSONValue(data: response.body), let id = json["registrationId"].flatMap(Self.text), let token = json["accessToken"]?.stringValue, !token.isEmpty else {
            throw SyncBoxError.invalidAnswer("the registration answer has no access token")
        }
        return Registration(registrationId: id, accessToken: token)
    }

    /// A registration id as text: the box sends a string; a number is read as one too.
    private static func text(_ value: JSONValue) -> String? {
        if let text = value.stringValue, !text.isEmpty { return text }
        return value.intValue.map(String.init)
    }
}

/// What the box answered that is not a success.
struct SyncBoxError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The HTTP status, 0 when the error is not one.
    var status: Int
    /// The `code` of the box's JSON error (1, 2, 3 unauthorized; 16 invalid state).
    var code: Int?
    var detail: String

    static let buttonNotPressed = SyncBoxError(status: 0, code: 16, detail: "the button on the Sync Box was not pressed")

    static func invalidAnswer(_ detail: String) -> SyncBoxError { SyncBoxError(status: 0, code: nil, detail: detail) }

    init(status: Int, code: Int?, detail: String) {
        self.status = status
        self.code = code
        self.detail = detail
    }

    /// "Error: <status> - <status text>. <first 500 characters of the body>" (section 6.3).
    init(response: HTTPResponse) {
        status = response.status
        let json = try? JSONValue(data: response.body)
        code = json?["code"]?.intValue
        let text = String(decoding: response.body.prefix(2_000), as: UTF8.self)
        let excerpt = String(text.prefix(500))
        detail = "Error: \(response.status) - \(Self.statusText(response.status)).\(excerpt.isEmpty ? "" : " \(excerpt)")"
    }

    /// The box refused the token: a code of 1, 2 or 3, or a 401 without one.
    var isUnauthorized: Bool { code.map { (1...3).contains($0) } ?? (status == 401) }

    var description: String { detail }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "HTTP \(status)"
        }
    }
}

/// One request at a time, in the order they came: a waiter gives up after its wait, or when its task is cancelled.
actor RequestLock {
    private var busy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var next = 0

    struct Timeout: Error, CustomStringConvertible {
        var description: String { "the Sync Box is busy with other requests" }
    }

    func acquire(within wait: Duration) async throws {
        guard busy else {
            busy = true
            return
        }
        next += 1
        let id = next
        let timer = Task { [weak self] in
            try await Task.sleep(for: wait)
            await self?.fail(id, Timeout())
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // The lock passes to the first waiter: it stays busy.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func fail(_ id: Int, _ error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }
}

/// The Hue Sync Box root CA, as Philips publishes it (developers.meethue.com, `hsb_cacert.pem`): the same in every box,
/// `C=NL, O=Philips Hue, CN=root-hsb`, EC P-256, valid to 9999. Each box's certificate is signed by it and names the
/// box's `uniqueId`, not its address.
enum SyncBoxCertificate {
    static let rootPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBwDCCAWagAwIBAgIBATAKBggqhkjOPQQDAjA2MQswCQYDVQQGEwJOTDEUMBIG
        A1UECgwLUGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMCAXDTE3MDEwMTAw
        MDAwMFoYDzk5OTkxMjMxMjM1OTU5WjA2MQswCQYDVQQGEwJOTDEUMBIGA1UECgwL
        UGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMFkwEwYHKoZIzj0CAQYIKoZI
        zj0DAQcDQgAEr9FgOxnsonsrnUZr3C4ggST7YCR9wISvDuwlNdZcAz4HiVCNmAAP
        tAnAFDG0U19Rmc4MfRYBMO8GrOHrOkZ7sKNjMGEwHQYDVR0OBBYEFCK+VIWZqp++
        DHqmGLWEZHYdH9v7MB8GA1UdIwQYMBaAFCK+VIWZqp++DHqmGLWEZHYdH9v7MA8G
        A1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMCA0gAMEUC
        IAFDI0Q4IOPxV7cY4wSVOJAn4y5AdZwrItJ1XuNpmCltAiEA5c6wcu6qmF596uyA
        r7xLnr3/F5zJxrE3AyLD4t+5oKs=
        -----END CERTIFICATE-----
        """

    /// Its SHA-256 fingerprint, as section 3.3 gives it: the tests check the PEM against it.
    static let rootFingerprint = "A8:4F:E4:D6:E4:B7:24:4D:45:D0:A0:03:4F:7E:E1:49:85:2C:EC:B5:2E:BA:7F:C1:2A:3A:CA:76:6E:E6:8C:74"

    /// Trusts only the root; with the box's `uniqueId`, its certificate must name it (sent as SNI too).
    static func tls(uniqueID: String?) -> HTTPClient.TLS {
        .authority(pem: rootPEM, serverName: uniqueID.flatMap { $0.isEmpty ? nil : $0 })
    }
}
