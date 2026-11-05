import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// One command of a batch (section 4): `{"cmd": …, "action": …, "param": …}`.
struct ReolinkCommand: Sendable, Equatable {
    var cmd: String
    var action: Int? = 0
    var param: JSONValue? = [:]

    static func channel(_ cmd: String, _ channel: Int) -> ReolinkCommand {
        ReolinkCommand(cmd: cmd, action: 0, param: ["channel": .number(Double(channel))])
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["cmd": .string(cmd)]
        if let action { object["action"] = .number(Double(action)) }
        if let param { object["param"] = param }
        return .object(object)
    }
}

/// One item of a response: its `value`, or the `error`'s `rspCode` and `detail`.
struct ReolinkReply: Sendable, Equatable {
    var cmd: String
    var code: Int
    var value: JSONValue?
    /// The `range` block an `action: 1` read returns beside `value` (limits such as a zoom's).
    var range: JSONValue?
    var rspCode: Int?
    var detail: String?

    var ok: Bool { code == 0 }
    /// A write's success: `code` 0 and `value.rspCode` 200 (3.5).
    var writeOK: Bool { code == 0 && value?["rspCode"]?.saturatingIntValue == 200 }

    init(cmd: String, code: Int, value: JSONValue? = nil, range: JSONValue? = nil, rspCode: Int? = nil, detail: String? = nil) {
        self.cmd = cmd
        self.code = code
        self.value = value
        self.range = range
        self.rspCode = rspCode
        self.detail = detail
    }

    init?(json: JSONValue) {
        guard let cmd = json["cmd"]?.stringValue else { return nil }
        self.cmd = cmd
        code = json["code"]?.saturatingIntValue ?? 1
        value = json["value"]
        range = json["range"]
        rspCode = json["error"]?["rspCode"]?.saturatingIntValue
        detail = json["error"]?["detail"]?.stringValue
    }

    /// A command left out for the session (it timed out on its own before).
    static func skipped(_ cmd: String) -> ReolinkReply { ReolinkReply(cmd: cmd, code: 1, rspCode: -8, detail: "skipped") }

    var isLoginRequired: Bool { rspCode == -6 || detail?.lowercased().contains("please login first") == true }
}

enum ReolinkError: Error, CustomStringConvertible, Equatable {
    /// The device refused the user name or password; `detail` is its message.
    case credentials(String)
    /// `-105`: too many logins; the next waits a minute.
    case frequentLogins
    /// `-5` / `-507`: the device has no session left.
    case maxSessions
    /// Neither HTTPS on 443 nor HTTP on 80 answered.
    case unreachable(String)
    case http(Int)
    case invalidResponse(String)
    case command(String, Int?, String?)
    case unsupported(String)
    case outOfRange(String)
    case offline
    /// Privacy mode is on: the camera's HTTP API and streams are off until it ends (addendum C).
    case privacy

    var description: String {
        switch self {
        case .credentials(let detail): "the device refused the login (\(detail))"
        case .frequentLogins: "the device refuses frequent logins: waiting a minute"
        case .maxSessions: "the device has no session left (the Reolink app or another client holds them; they last up to an hour)"
        case .unreachable(let reason): "the device does not answer on its HTTP(S) API: \(reason). If it is on, enable HTTP or HTTPS in the Reolink app (a battery camera on its own has no HTTP API: connect it to a Reolink Home Hub or NVR and add that instead)"
        case .http(let status): "HTTP status \(status)"
        case .invalidResponse(let reason): "an answer the plugin cannot read (\(reason))"
        case .command(let cmd, let code, let detail): "\(cmd) failed (\(code.map(String.init) ?? "?")\(detail.map { ": \($0)" } ?? ""))"
        case .unsupported(let cmd): "\(cmd) is not supported by the device"
        case .outOfRange(let reason): reason
        case .offline: "the channel is offline"
        case .privacy: "privacy mode is on: the camera's video and HTTP API are off until it ends"
        }
    }
}

/// Runs one operation at a time, in order: an actor's methods interleave at every `await`, and the devices want one
/// request in flight.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
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
}

/// Callers waiting for something (a connection, privacy mode ending) until it happens or a timeout passes.
final class Waiters<Value: Sendable>: Sendable {
    private struct State {
        var next = 0
        var waiting: [Int: CheckedContinuation<Value, Never>] = [:]
        /// Timeouts that fired before their caller was registered.
        var expired: Set<Int> = []
    }

    private let state = NIOLockedValueBox(State())

    /// Waits for `resumeAll`, or `fallback` after `timeout`.
    func wait(timeout: Duration, fallback: Value) async -> Value {
        let id = state.withLockedValue { state -> Int in
            state.next += 1
            return state.next
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(id, fallback)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let expired = state.withLockedValue { state -> Bool in
                if state.expired.remove(id) != nil { return true }
                state.waiting[id] = continuation
                return false
            }
            if expired { continuation.resume(returning: fallback) }
        }
    }

    func resumeAll(_ value: Value) {
        let waiting = state.withLockedValue { state in
            defer { state.waiting = [:] }
            return state.waiting
        }
        for continuation in waiting.values { continuation.resume(returning: value) }
    }

    private func expire(_ id: Int, _ fallback: Value) {
        let continuation = state.withLockedValue { state -> CheckedContinuation<Value, Never>? in
            guard let continuation = state.waiting.removeValue(forKey: id) else {
                state.expired.insert(id)
                return nil
            }
            return continuation
        }
        continuation?.resume(returning: fallback)
    }
}

/// The HTTP JSON API of one host (section 3): a long session's token, reused, renewed 300 s before it expires with a
/// logout first, one login and one request at a time, batches of at most 35 commands, three attempts each.
actor ReolinkHTTPClient {
    typealias MakeSender = @Sendable (HTTPClient.TLS) -> any HTTPSending

    static let batchLimit = 35
    static let attempts = 3
    static let renewalMargin: TimeInterval = 300

    let host: String
    private let username: String
    private let password: String
    private let makeSender: MakeSender
    private let trust: HTTPClient.TrustOnFirstUse
    private let log: Logger
    private let timing: ReolinkTiming
    private let now: @Sendable () -> Date
    private let gate = SerialGate()

    /// The scheme and port in use; nil until a login found them.
    private var endpoint: (https: Bool, port: Int)?
    private let candidates: [(https: Bool, port: Int)]
    private var token: String?
    private var expiry = Date.distantPast
    private var nextLoginAllowed = Date.distantPast
    private var sender: (tls: HTTPClient.TLS, client: any HTTPSending)?
    /// Commands that timed out (`-8`) on their own: skipped for the rest of the session.
    private var skipped: Set<String> = []
    private(set) var requestCount = 0

    init(host: String, port: Int?, useHttps: Bool?, username: String, password: String, makeSender: @escaping MakeSender,
         trust: HTTPClient.TrustOnFirstUse, log: Logger, timing: ReolinkTiming, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.username = username
        self.password = password
        self.makeSender = makeSender
        self.trust = trust
        self.log = log
        self.timing = timing
        self.now = now
        switch (useHttps, port) {
        case (let https?, let port?): candidates = [(https, port)]
        case (let https?, nil): candidates = [(https, https ? 443 : 80)]
        case (nil, let port?): candidates = port == 80 ? [(false, 80)] : [(true, port), (false, port)]
        case (nil, nil): candidates = [(true, 443), (false, 80)]
        }
    }

    var isHTTPS: Bool { (endpoint ?? candidates[0]).https }
    var apiPort: Int { (endpoint ?? candidates[0]).port }

    // MARK: Commands

    /// Runs the commands, at most 35 per request, and answers an item per command in order (an item that failed
    /// keeps its `rspCode`).
    func execute(_ commands: [ReolinkCommand]) async throws -> [ReolinkReply] {
        try await gate.run { try await self.executeLocked(commands) }
    }

    private func executeLocked(_ commands: [ReolinkCommand]) async throws -> [ReolinkReply] {
        var replies: [ReolinkReply] = []
        var index = 0
        while index < commands.count {
            let batch = Array(commands[index..<min(index + Self.batchLimit, commands.count)])
            replies += try await post(batch)
            index += batch.count
        }
        return replies
    }

    private func post(_ batch: [ReolinkCommand]) async throws -> [ReolinkReply] {
        // Decided once: a login on the way empties `skipped`, and the answers must still line up with what was sent.
        let isSkipped = batch.map { skipped.contains($0.cmd) }
        let runnable = zip(batch, isSkipped).filter { !$0.1 }.map(\.0)
        guard !runnable.isEmpty else { return batch.map { ReolinkReply.skipped($0.cmd) } }
        var lastError: any Error = ReolinkError.invalidResponse("no answer")
        for attempt in 1...Self.attempts {
            do {
                try await ensureLogin()
                guard let token else { throw ReolinkError.invalidResponse("no token") }
                let response = try await send(method: "POST", query: "cmd=\(runnable[0].cmd)&token=\(token)", body: .array(runnable.map(\.json)))
                if response.status == 404 || response.status == 502 {
                    dropSession()
                    lastError = ReolinkError.http(response.status)
                    continue
                }
                guard response.status < 400 else { throw ReolinkError.http(response.status) }
                let items = try Self.parse(response.body)
                if items.contains(where: \.isLoginRequired) {
                    dropSession()
                    lastError = ReolinkError.credentials("please login first")
                    continue
                }
                if runnable.count > 1, items.count == 1, items[0].code != 0, (items[0].rspCode ?? 0) < 0 {
                    // Some firmware answers a whole batch with one error item: each on its own.
                    return try await individually(batch)
                }
                guard items.count == runnable.count else {
                    if attempt < Self.attempts {
                        try await Task.sleep(for: timing.seconds(5))
                        continue
                    }
                    // A command on its own has nothing to split into: it failed.
                    guard runnable.count > 1 else {
                        return zip(batch, isSkipped).map { command, isSkipped in
                            isSkipped ? ReolinkReply.skipped(command.cmd) : ReolinkReply(cmd: command.cmd, code: 1)
                        }
                    }
                    return try await individually(batch)
                }
                var byIndex = items.makeIterator()
                return zip(batch, isSkipped).map { command, isSkipped in
                    isSkipped ? ReolinkReply.skipped(command.cmd) : byIndex.next() ?? ReolinkReply(cmd: command.cmd, code: 1)
                }
            } catch let error as ReolinkError {
                switch error {
                case .credentials, .frequentLogins, .maxSessions, .unreachable: throw error
                default: lastError = error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A timeout or a reset: the session may still be held on the device, so the next login logs it out
                // first (3.2) rather than leaving it to linger for an hour.
                lastError = error
                expiry = .distantPast
            }
        }
        throw lastError
    }

    private func individually(_ batch: [ReolinkCommand]) async throws -> [ReolinkReply] {
        var replies: [ReolinkReply] = []
        for command in batch {
            if skipped.contains(command.cmd) {
                replies.append(ReolinkReply.skipped(command.cmd))
                continue
            }
            let reply = try await post([command]).first ?? ReolinkReply(cmd: command.cmd, code: 1)
            if reply.rspCode == -8 { skipped.insert(command.cmd) }
            replies.append(reply)
        }
        return replies
    }

    static func parse(_ body: Data) throws -> [ReolinkReply] {
        guard let json = try? JSONValue(data: body) else { throw ReolinkError.invalidResponse("not JSON") }
        let items = json.arrayValue ?? [json]
        return items.compactMap(ReolinkReply.init(json:))
    }

    // MARK: Snapshot (4.7)

    /// `Snap` of a channel's main or sub stream; the JPEG.
    func snapshot(channel: Int, sub: Bool, width: Int?, height: Int?) async throws -> Data {
        try await gate.run {
            try await self.ensureLogin()
            guard let token = await self.token else { throw ReolinkError.invalidResponse("no token") }
            var query = "cmd=Snap&channel=\(channel)&snapType=\(sub ? "sub" : "main")"
            if sub, let width, let height { query += "&width=\(width)&height=\(height)" }
            query += "&token=\(token)"
            let response = try await self.send(method: "GET", query: query, body: nil)
            let type = response.header("Content-Type")?.lowercased() ?? ""
            guard response.status < 400 else { throw ReolinkError.http(response.status) }
            guard !response.body.isEmpty else {
                await self.dropSession()
                throw ReolinkError.invalidResponse("an empty snapshot")
            }
            guard type.contains("image") else {
                let items = (try? Self.parse(response.body)) ?? []
                if items.contains(where: \.isLoginRequired) { await self.dropSession() }
                throw ReolinkError.command("Snap", items.first?.rspCode, items.first?.detail)
            }
            return response.body
        }
    }

    // MARK: Session (3.2)

    private func ensureLogin() async throws {
        if token != nil, expiry.timeIntervalSince(now()) > Self.renewalMargin { return }
        try await login()
    }

    private func login() async throws {
        guard now() >= nextLoginAllowed else { throw ReolinkError.frequentLogins }
        await logout()
        let body: JSONValue = [["cmd": "Login", "action": 0, "param": ["User": ["userName": .string(username), "password": .string(password)]]]]
        // Once a certificate is pinned the device has answered HTTPS: plain HTTP is not tried any more (unless the block
        // asks for it), so a man in the middle that blocks HTTPS does not get the password in clear.
        var options = endpoint.map { [$0] } ?? (trust.fingerprint != nil && candidates.contains(where: \.https) ? candidates.filter(\.https) : candidates)
        var lastError: any Error = ReolinkError.unreachable("no answer")
        var index = 0
        while index < options.count {
            let option = options[index]
            index += 1
            endpoint = option
            let response: HTTPResponse
            do {
                response = try await send(method: "POST", query: "cmd=Login&token=null", body: body)
            } catch let error as HTTPClientError {
                if case .certificateMismatch(_, let observed) = error {
                    if trust.reportMismatch(observed: observed) {
                        log.error("The device's HTTPS certificate changed since it was first seen: the plugin refuses it. Set the device up again to trust the new one.")
                    }
                    // Not another candidate: the login must not go to plain HTTP behind a refused certificate.
                    endpoint = nil
                    throw ReolinkError.unreachable(error.description)
                }
                lastError = ReolinkError.unreachable(error.description)
                continue
            }
            if response.status == 300, !option.https {
                // HTTP where HTTPS is expected.
                let https = (https: true, port: option.port == 80 ? 443 : option.port)
                if !options.contains(where: { $0.https == https.https && $0.port == https.port }) { options.insert(https, at: index) }
                continue
            }
            guard response.status < 400 else {
                lastError = ReolinkError.http(response.status)
                continue
            }
            let items = try Self.parse(response.body)
            guard let item = items.first else { throw ReolinkError.invalidResponse("no login item") }
            guard item.ok, let name = item.value?["Token"]?["name"]?.stringValue else {
                throw Self.loginError(item, setting: &nextLoginAllowed, now: now(), timing: timing)
            }
            token = name
            // Bounded to a day: the device's number, a huge one included, is logged as an `Int`.
            let lease = min(max(item.value?["Token"]?["leaseTime"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 3600, 0), 86_400)
            expiry = now().addingTimeInterval(lease)
            skipped = []
            log.trace("Reolink login: token for \(Int(lease)) s")
            return
        }
        endpoint = nil
        throw lastError
    }

    static func loginError(_ item: ReolinkReply, setting nextLogin: inout Date, now: Date, timing: ReolinkTiming) -> ReolinkError {
        let detail = item.detail ?? "code \(item.rspCode.map(String.init) ?? "?")"
        let lower = detail.lowercased()
        switch item.rspCode {
        case -105:
            nextLogin = now.addingTimeInterval(60 * timing.scale)
            return .frequentLogins
        case -5, -507:
            return .maxSessions
        default:
            break
        }
        if [-7, -27, -502, -506].contains(item.rspCode ?? 0) || ["invalid user", "login failed", "password wrong", "login has been locked"].contains(where: lower.contains) {
            return .credentials(detail)
        }
        return .command("Login", item.rspCode, item.detail)
    }

    /// Logs out the current token (never without one); the answer is ignored.
    private func logout() async {
        guard let token else { return }
        self.token = nil
        expiry = .distantPast
        _ = try? await send(method: "POST", query: "cmd=Logout&token=\(token)", body: [["cmd": "Logout", "action": 0, "param": [:]]])
    }

    func shutdown() async {
        await gate.run { await self.logout() }
    }

    /// Forgets a token the device no longer accepts.
    private func dropSession() {
        token = nil
        expiry = .distantPast
    }

    // MARK: Transport

    private func send(method: String, query: String, body: JSONValue?) async throws -> HTTPResponse {
        let option = endpoint ?? candidates[0]
        let scheme = option.https ? "https" : "http"
        let defaultPort = option.https ? 443 : 80
        let authority = ReolinkStreamURL.bracketed(host)
        let portPart = option.port == defaultPort ? "" : ":\(option.port)"
        guard let url = URL(string: "\(scheme)://\(authority)\(portPart)/cgi-bin/api.cgi?\(query)") else { throw HTTPClientError.invalidURL(host) }
        var request = HTTPRequest(method: method, url: url, body: body.map { $0.encoded() }, timeout: timing.timeout(30))
        if body != nil { request.setHeader("Content-Type", "application/json") }
        let tls = option.https ? trust.tls : HTTPClient.TLS.system
        if sender?.tls != tls { sender = (tls, makeSender(tls)) }
        requestCount += 1
        let response = try await sender!.client.send(request)
        if option.https, trust.observe(response.certificateFingerprint) {
            log.info("Trusting the device's HTTPS certificate from now on (pinned on first use).")
        }
        return response
    }
}
