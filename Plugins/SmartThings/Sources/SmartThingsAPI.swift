import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's clock: every wait it makes, scaled so tests take SmartThings' minutes in milliseconds.
struct SmartThingsTiming: Sendable {
    /// 1 in the bridge; tests make it 0.001 (a minute becomes 60 ms).
    var scale: Double = 1

    func seconds(_ value: Double) -> Duration {
        let scaled = value * scale
        guard scaled.isFinite, scaled > 0 else { return .zero }
        return .nanoseconds(Int64(min(scaled, 9e9) * 1e9))
    }

    func timeInterval(_ value: Double) -> TimeInterval { value * scale }
}

/// Requests a minute per key (a device, the SSE API): SmartThings allows 12 status reads or command requests a minute
/// per device, and 20 SSE calls a minute (docs/clean-room/SmartThings.md, 6.1). A request over the limit waits for a slot.
actor RateLimiter {
    let limit: Int
    let window: Duration
    private var sent: [String: [ContinuousClock.Instant]] = [:]
    /// How many requests waited for a slot: for tests.
    private(set) var waits = 0

    init(limit: Int, window: Duration) {
        self.limit = limit
        self.window = window
    }

    func acquire(_ key: String) async throws {
        while true {
            let now = ContinuousClock.now
            var stamps = sent[key, default: []].filter { now - $0 < window }
            if stamps.count < limit {
                stamps.append(now)
                sent[key] = stamps
                // Keys whose window has passed are dropped, so the table does not grow with uptime.
                if sent.count > 256 { sent = sent.filter { !$0.value.allSatisfy { now - $0 >= window } } }
                return
            }
            sent[key] = stamps
            waits += 1
            let wait = window - (now - stamps[0])
            try await Task.sleep(for: max(wait, .milliseconds(1)))
        }
    }
}

/// An answer of the API that is not a success, in words the log can carry (never a token).
enum SmartThingsError: Error, CustomStringConvertible, Equatable {
    case http(status: Int, path: String, message: String)
    /// SmartThings said to slow down; reads wait out the back-off.
    case rateLimited(path: String)
    case network(path: String, message: String)
    case invalidAnswer(path: String)

    var description: String {
        switch self {
        case .http(let status, let path, let message): "SmartThings answered HTTP \(status) to \(path)\(message.isEmpty ? "" : ": \(message)")"
        case .rateLimited(let path): "SmartThings is limiting the requests (HTTP 429); \(path) waits"
        case .network(let path, let message): "SmartThings did not answer \(path): \(message)"
        case .invalidAnswer(let path): "SmartThings answered \(path) with something unexpected"
        }
    }

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        if case .rateLimited = self { return 429 }
        return nil
    }
}

/// The SmartThings REST API (section 4): the bearer of the token store on every call, a 401 refreshed once, 429s backed
/// off for the whole plugin, network failures and 5xx retried, list pages followed, commands at most ten a request.
actor SmartThingsAPI {
    static let userAgent = "Homeswift/\(PluginHost.version) (SmartThings plugin; https://homeswift.dev)"
    static let deviceAccept = "application/vnd.smartthings+json;v=20170916"
    static let maximumCommandsPerRequest = 10

    let base: URL
    let http: any HTTPSending
    let streaming: any HTTPStreaming
    let tokens: TokenStore
    let deviceLimiter: RateLimiter
    let sseLimiter: RateLimiter
    let timing: SmartThingsTiming
    let logger: Logger
    private var backoffUntil: ContinuousClock.Instant?
    private var backoffAttempt = 0
    private var forbiddenLogged = Set<String>()
    /// Requests sent since start: what the Developer plan's monthly quota counts.
    private(set) var requestCount = 0
    /// The pages the last device list took: what a poll costs (section 5.3).
    private(set) var lastListPages = 1

    init(base: URL, http: any HTTPSending, streaming: any HTTPStreaming, tokens: TokenStore, timing: SmartThingsTiming, logger: Logger,
         deviceLimiter: RateLimiter? = nil) {
        self.base = base
        self.http = http
        self.streaming = streaming
        self.tokens = tokens
        self.timing = timing
        self.logger = logger
        self.deviceLimiter = deviceLimiter ?? RateLimiter(limit: 12, window: timing.seconds(60))
        sseLimiter = RateLimiter(limit: 20, window: timing.seconds(60))
    }

    // MARK: Calls

    func locations() async throws -> [JSONValue] { try await list("locations", query: []) }

    /// Every device of the location with its status and health, all pages (sections 4.3 and 5.2).
    func devices(locationID: String?) async throws -> [JSONValue] {
        var query: [(String, String)] = []
        if let locationID { query.append(("locationId", locationID)) }
        query += [("includeStatus", "true"), ("includeHealth", "true")]
        return try await list("devices", query: query, accept: Self.deviceAccept)
    }

    func status(deviceID: String) async throws -> JSONValue {
        try await deviceLimiter.acquire(deviceID)
        return try await send("GET", path: "devices/\(deviceID)/status", isWrite: false)
    }

    /// Sends the commands for one device, ten a request at most (section 4.3).
    func commands(deviceID: String, _ commands: [DeviceCommand]) async throws {
        var start = 0
        while start < commands.count {
            let batch = Array(commands[start..<min(start + Self.maximumCommandsPerRequest, commands.count)])
            try await deviceLimiter.acquire(deviceID)
            _ = try await send("POST", path: "devices/\(deviceID)/commands", body: ["commands": .array(batch.map(\.json))], isWrite: true)
            start += Self.maximumCommandsPerRequest
        }
    }

    func scenes(locationID: String?) async throws -> [JSONValue] {
        try await list("scenes", query: locationID.map { [("locationId", $0)] } ?? [])
    }

    func executeScene(_ sceneID: String) async throws {
        _ = try await send("POST", path: "scenes/\(sceneID)/execute", isWrite: true)
    }

    func rooms(locationID: String) async throws -> [JSONValue] { try await list("locations/\(locationID)/rooms", query: []) }

    // MARK: Server-sent events (section 5.1)

    struct Subscription: Sendable {
        var id: String
        var registrationURL: URL
    }

    static let eventTypes = ["DEVICE_EVENT", "DEVICE_HEALTH_EVENT", "DEVICE_LIFECYCLE_EVENT", "SCENE_LIFECYCLE_EVENT"]

    func createSubscription(name: String, locationID: String) async throws -> Subscription {
        try await sseLimiter.acquire("sse")
        let body: JSONValue = [
            "name": .string(name),
            "subscriptionFilters": [["type": "LOCATIONIDS", "value": [.string(locationID)], "eventType": .array(Self.eventTypes.map(JSONValue.string))]],
        ]
        let answer = try await send("POST", path: "sse/subscriptions", body: body, isWrite: true)
        // The stream's host is not documented, so it is not pinned; the bearer token only ever goes over https.
        guard let id = answer["subscriptionId"]?.stringValue, let text = answer["registrationUrl"]?.stringValue, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw SmartThingsError.invalidAnswer(path: "sse/subscriptions")
        }
        return Subscription(id: id, registrationURL: url)
    }

    func deleteSubscription(_ id: String) async {
        try? await sseLimiter.acquire("sse")
        _ = try? await send("DELETE", path: "sse/subscriptions/\(id)", isWrite: true)
    }

    /// Opens the stream of a subscription with the same token, within its minute; a 401 is refreshed once.
    func openStream(_ subscription: Subscription) async throws -> HTTPStreamingResponse {
        try await sseLimiter.acquire("sse")
        var token = try await tokens.accessToken()
        for attempt in 0..<2 {
            requestCount += 1
            let request = HTTPRequest(method: "GET", url: subscription.registrationURL, headers: [
                ("Authorization", "Bearer \(token)"), ("Accept", "text/event-stream"), ("User-Agent", Self.userAgent),
            ], timeout: .seconds(15))
            let response: HTTPStreamingResponse
            do {
                response = try await streaming.stream(request)
            } catch {
                throw SmartThingsError.network(path: "the event stream", message: "\(error)")
            }
            if response.status == 401, attempt == 0 {
                token = try await tokens.refresh(replacing: token).access_token
                continue
            }
            guard response.isSuccess else { throw SmartThingsError.http(status: response.status, path: "the event stream", message: "") }
            return response
        }
        throw SmartThingsError.http(status: 401, path: "the event stream", message: "")
    }

    // MARK: The request

    /// A list and its next pages (`_links.next.href`), a next page on another origin refused (section 4.1).
    private func list(_ path: String, query: [(String, String)], accept: String = "application/json") async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var url = endpoint(path, query: query)
        var pages = 0
        while true {
            let answer = try await send("GET", url: url, path: path, accept: accept, isWrite: false)
            items += answer["items"]?.arrayValue ?? []
            pages += 1
            guard let next = answer["_links"]?["next"]?["href"]?.stringValue, !next.isEmpty, pages < 100 else { break }
            guard let nextURL = URL(string: next, relativeTo: base)?.absoluteURL, nextURL.scheme == base.scheme, nextURL.host == base.host,
                  nextURL.port == base.port else {
                logger.warning("SmartThings gave a next page on another host for \(path): not followed")
                break
            }
            url = nextURL
        }
        if path == "devices" { lastListPages = pages }
        return items
    }

    private func endpoint(_ path: String, query: [(String, String)] = []) -> URL {
        let text = base.absoluteString + path + (query.isEmpty ? "" : "?" + URLEncoding.query(query))
        return URL(string: text) ?? base.appendingPathComponent(path)
    }

    func send(_ method: String, path: String, body: JSONValue? = nil, isWrite: Bool) async throws -> JSONValue {
        try await send(method, url: endpoint(path), path: path, body: body, isWrite: isWrite)
    }

    /// One call with the rules of section 6.2.
    private func send(_ method: String, url: URL, path: String, body: JSONValue? = nil, accept: String = "application/json", isWrite: Bool) async throws -> JSONValue {
        if let until = backoffUntil, ContinuousClock.now < until {
            // During a 429 back-off reads are not sent; a write waits only a short one (section 6.2).
            let wait = until - ContinuousClock.now
            guard isWrite, wait <= timing.seconds(5) else { throw SmartThingsError.rateLimited(path: path) }
            try await Task.sleep(for: wait)
        }
        var token = try await tokens.accessToken()
        var refreshed = false
        var rateRetried = false
        var transientTries = 0
        let readBackoff = Backoff(initial: timing.seconds(1), maximum: timing.seconds(10), jitter: .proportional(0.2))
        /// Waits before trying a network failure or a 5xx again; false once the tries are spent (two for a write, three for a read).
        func retryTransient(_ tries: inout Int) async throws -> Bool {
            tries += 1
            guard tries < (isWrite ? 2 : 3) else { return false }
            try await Task.sleep(for: isWrite ? timing.seconds(1) : readBackoff.delay(attempt: tries - 1))
            return true
        }
        while true {
            var headers: [(name: String, value: String)] = [("Authorization", "Bearer \(token)"), ("Accept", accept), ("User-Agent", Self.userAgent)]
            if body != nil { headers.append(("Content-Type", "application/json;charset=utf-8")) }
            let request = HTTPRequest(method: method, url: url, headers: headers, body: body?.encoded(), timeout: .seconds(15))
            requestCount += 1
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch {
                if try await retryTransient(&transientTries) { continue }
                throw SmartThingsError.network(path: path, message: "\(error)")
            }
            switch response.status {
            case 200..<300:
                backoffAttempt = 0
                if response.body.isEmpty { return .object([:]) }
                return (try? JSONValue(data: response.body)) ?? .object([:])
            case 401 where !refreshed:
                refreshed = true
                token = try await tokens.refresh(replacing: token).access_token
                continue
            case 429:
                let wait = rateLimitWait(response)
                backoffUntil = ContinuousClock.now + wait
                backoffAttempt += 1
                logger.warning("SmartThings is limiting the requests (HTTP 429): waiting \(Int((Double(wait.components.seconds) / max(timing.scale, 1e-9)).rounded())) s")
                if isWrite, !rateRetried, wait <= timing.seconds(5) {
                    rateRetried = true
                    try await Task.sleep(for: wait)
                    continue
                }
                throw SmartThingsError.rateLimited(path: path)
            case 500..<600:
                if try await retryTransient(&transientTries) { continue }
                throw SmartThingsError.http(status: response.status, path: path, message: Self.excerpt(response.body))
            case 403:
                let key = "\(method) \(Self.pathShape(path))"
                if forbiddenLogged.insert(key).inserted {
                    logger.warning("SmartThings refused \(method) \(path) (HTTP 403): \(Self.excerpt(response.body)). Check the Developer plan and the app's scopes.")
                }
                throw SmartThingsError.http(status: 403, path: path, message: Self.excerpt(response.body))
            default:
                throw SmartThingsError.http(status: response.status, path: path, message: Self.excerpt(response.body))
            }
        }
    }

    /// `X-RateLimit-Reset` seconds, else `Retry-After`, else 5 s doubling to 10 minutes, ±20 % (section 6.2).
    private func rateLimitWait(_ response: HTTPResponse) -> Duration {
        for header in ["X-RateLimit-Reset", "Retry-After"] {
            if let text = response.header(header), let seconds = Double(text.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 {
                return timing.seconds(min(seconds, 600))
            }
        }
        return Backoff(initial: timing.seconds(5), maximum: timing.seconds(600), jitter: .proportional(0.2)).delay(attempt: backoffAttempt)
    }

    /// A device path without its id, so a 403 is logged once per kind of call.
    static func pathShape(_ path: String) -> String {
        path.split(separator: "/").map { $0.count >= 32 && $0.contains("-") ? "{id}" : String($0) }.joined(separator: "/")
    }

    /// The first 200 characters of an error body: SmartThings' error JSON, never a token.
    static func excerpt(_ body: Data) -> String {
        let text = String(decoding: body.prefix(200), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
