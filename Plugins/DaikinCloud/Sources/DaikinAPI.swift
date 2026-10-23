import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// The quota the cloud reported on its last answer (`X-RateLimit-*` headers).
struct RateLimitStatus: Sendable, Equatable, Codable {
    var limitMinute: Int?
    var remainingMinute: Int?
    var limitDay: Int?
    var remainingDay: Int?

    init(limitMinute: Int? = nil, remainingMinute: Int? = nil, limitDay: Int? = nil, remainingDay: Int? = nil) {
        self.limitMinute = limitMinute
        self.remainingMinute = remainingMinute
        self.limitDay = limitDay
        self.remainingDay = remainingDay
    }

    init(_ response: HTTPResponse) {
        self.init(
            limitMinute: response.integer("x-ratelimit-limit-minute"), remainingMinute: response.integer("x-ratelimit-remaining-minute"),
            limitDay: response.integer("x-ratelimit-limit-day"), remainingDay: response.integer("x-ratelimit-remaining-day"))
    }

    var isEmpty: Bool { limitMinute == nil && remainingMinute == nil && limitDay == nil && remainingDay == nil }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let limitMinute { object["limitMinute"] = .number(Double(limitMinute)) }
        if let remainingMinute { object["remainingMinute"] = .number(Double(remainingMinute)) }
        if let limitDay { object["limitDay"] = .number(Double(limitDay)) }
        if let remainingDay { object["remainingDay"] = .number(Double(remainingDay)) }
        return .object(object)
    }
}

/// The API is blocked after a 429 until its Retry-After.
struct RateLimitedError: Error, CustomStringConvertible, Equatable, Sendable {
    var message: String
    /// Seconds.
    var retryAfter: Int
    var description: String { message }
}

/// 502, 503 or 504 after the retries allowed: a Daikin-side outage.
struct APIUnavailableError: Error, CustomStringConvertible, Equatable, Sendable {
    var message: String
    var statusCode: Int
    var attemptsMade: Int
    var description: String { message }
}

/// What a device needs from the API to write; tests record the calls instead.
protocol DaikinDeviceWriting: Sendable {
    func updateDevice(_ deviceID: String, embeddedID: String, dataPoint: String, value: JSONValue, path: String?) async throws
    func setHolidayMode(_ deviceID: String, embeddedID: String, enabled: Bool, startDate: String?, endDate: String?) async throws
    func triggerFirmwareUpdate(_ deviceID: String, embeddedID: String, firmwareID: String) async throws
}

/// The Onecta REST API: rate limits (headers, blocking on 429), retries with backoff, and one write queue per
/// device that keeps a gap between writes and coalesces rapid writes to the same setting into one request.
///
/// Gateway errors (502, 503, 504) are retried for writes, a dropped write being lost otherwise, and not for
/// polling reads: the next poll is the retry, and retrying only spends the daily quota.
actor DaikinAPI: DaikinDeviceWriting {
    static let baseURL = "https://api.onecta.daikineurope.com"
    static let maxRetries = 3
    static let retryBaseDelay = 1000.0
    static let retryMaxDelay = 10_000.0
    static let defaultRetryAfter = 60
    static let maxBlock = 86_400
    /// Between two writes to one device, against burst limits.
    static let writeGap: Duration = .milliseconds(400)

    struct Dependencies: Sendable {
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    }

    private let oauth: any OAuthProvider
    private let http: DaikinHTTP
    private let dependencies: Dependencies
    private let onRateLimit: @Sendable (RateLimitStatus) -> Void
    private var blockedUntil = Date.distantPast
    private var refreshing: Task<Void, any Error>?
    private var writeQueues: [String: Task<Void, Never>] = [:]
    /// Writes queued but not sent yet, by device, management point, data point and path: a newer write to
    /// the same target replaces the value (the last one wins) and shares the request.
    private var pendingWrites: [String: PendingWrite] = [:]

    private final class PendingWrite: @unchecked Sendable {
        var body: JSONValue
        var task: Task<Void, any Error>?
        init(body: JSONValue) { self.body = body }
    }

    init(oauth: any OAuthProvider, http: DaikinHTTP, dependencies: Dependencies = Dependencies(), onRateLimit: @escaping @Sendable (RateLimitStatus) -> Void = { _ in }) {
        self.oauth = oauth
        self.http = http
        self.dependencies = dependencies
        self.onRateLimit = onRateLimit
    }

    // MARK: Reads

    /// Every gateway device. `retryGatewayErrors` for one-off reads such as discovery, where a transient
    /// failure is costly.
    func devices(retryGatewayErrors: Bool = false) async throws -> [JSONValue] {
        let json = try await request("/v1/gateway-devices", method: "GET", retryGatewayErrors: retryGatewayErrors)
        guard let devices = json?.arrayValue else { throw DaikinError("Unexpected API response: the device list is not an array") }
        for device in devices {
            guard device["id"]?.stringValue != nil, device["managementPoints"]?.arrayValue != nil else {
                throw DaikinError("Unexpected API response: a device has no id or management points")
            }
        }
        return devices
    }

    // MARK: Writes

    /// PATCHes one characteristic; `path` goes in the body, as the Onecta app sends it.
    func updateDevice(_ deviceID: String, embeddedID: String, dataPoint: String, value: JSONValue, path: String?) async throws {
        let url = "\(Self.managementPointPath(deviceID, embeddedID))/characteristics/\(URLEncoding.uriComponent(dataPoint))"
        var body: [String: JSONValue] = ["value": value]
        if let path { body["path"] = .string(path) }
        let key = "\(deviceID)|\(embeddedID)|\(dataPoint)|\(path ?? "")"
        if let pending = pendingWrites[key], let task = pending.task {
            pending.body = .object(body)
            return try await task.value
        }
        let entry = PendingWrite(body: .object(body))
        pendingWrites[key] = entry
        let task = enqueueWrite(deviceID) { api in
            // Once sent, later writes queue behind it instead of merging.
            let body = await api.takePending(key, entry)
            _ = try await api.request(url, method: "PATCH", body: body)
        }
        entry.task = task
        return try await task.value
    }

    private func takePending(_ key: String, _ entry: PendingWrite) -> JSONValue {
        if pendingWrites[key] === entry { pendingWrites[key] = nil }
        return entry.body
    }

    /// Holiday (away) mode has an endpoint of its own; the dates (YYYY-MM-DD) are optional.
    func setHolidayMode(_ deviceID: String, embeddedID: String, enabled: Bool, startDate: String?, endDate: String?) async throws {
        var body: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let startDate { body["startDate"] = .string(startDate) }
        if let endDate { body["endDate"] = .string(endDate) }
        let url = "\(Self.managementPointPath(deviceID, embeddedID))/holiday-mode"
        let payload = JSONValue.object(body)
        try await enqueueWrite(deviceID) { api in _ = try await api.request(url, method: "POST", body: payload) }.value
    }

    /// Installs the firmware update staged for a management point: a PUT without a body, as the Onecta app
    /// does, with the update's id from `firmwareUpdate.value.id`.
    func triggerFirmwareUpdate(_ deviceID: String, embeddedID: String, firmwareID: String) async throws {
        let url = "\(Self.managementPointPath(deviceID, embeddedID))/firmware/\(URLEncoding.uriComponent(firmwareID))"
        try await enqueueWrite(deviceID) { api in _ = try await api.request(url, method: "PUT") }.value
    }

    /// Ids come from the cloud and are encoded, so a `/` or `?` in one cannot change the endpoint.
    static func managementPointPath(_ deviceID: String, _ embeddedID: String) -> String {
        "/v1/gateway-devices/\(URLEncoding.uriComponent(deviceID))/management-points/\(URLEncoding.uriComponent(embeddedID))"
    }

    /// Runs writes to one device one after the other with a gap between them; devices write in parallel.
    private func enqueueWrite(_ deviceID: String, _ work: @escaping @Sendable (DaikinAPI) async throws -> Void) -> Task<Void, any Error> {
        let previous = writeQueues[deviceID]
        let sleep = dependencies.sleep
        let task = Task { [self] in
            await previous?.value
            do {
                try await work(self)
            } catch {
                try? await sleep(Self.writeGap)
                throw error
            }
            try? await sleep(Self.writeGap)
        }
        writeQueues[deviceID] = Task { _ = try? await task.value }
        return task
    }

    // MARK: Rate limit

    var isRateLimited: Bool { blockedUntil > Date() }

    /// Seconds until requests may go again.
    var retryAfter: Int { max(0, Int((blockedUntil.timeIntervalSinceNow).rounded(.up))) }

    // MARK: Requests

    private func request(_ path: String, method: String, body: JSONValue? = nil, retryGatewayErrors: Bool? = nil, attempt: Int = 0) async throws -> JSONValue? {
        if isRateLimited {
            let seconds = retryAfter
            throw RateLimitedError(message: "API request blocked due to rate limit. Retry after \(seconds) seconds.", retryAfter: seconds)
        }
        let token = try await oauth.accessToken()
        guard let url = URL(string: Self.baseURL + path) else { throw DaikinError("Invalid API path \(path)") }
        var headers: [(name: String, value: String)] = [("Authorization", "Bearer \(token)"), ("Accept", "application/json")]
        let data = body.map { $0.encoded() }
        if data != nil { headers.append(("Content-Type", "application/json")) }
        let response = try await http.send(method, url, headers: headers, body: data)

        let status = RateLimitStatus(response)
        if !status.isEmpty { onRateLimit(status) }

        switch response.status {
        case 200, 204:
            return response.body.isEmpty ? nil : try JSONValue(data: response.body)
        case 400:
            throw DaikinError(Self.describeBadRequest(response.text))
        case 401:
            guard attempt < Self.maxRetries else { throw DaikinError("Unauthorized (401): Token expired or invalid") }
            do {
                try await sharedRefresh()
            } catch {
                throw DaikinError("Unauthorized (401): Token refresh failed. Please re-authenticate.")
            }
            try await dependencies.sleep(retryDelay(attempt))
            return try await request(path, method: method, body: body, retryGatewayErrors: retryGatewayErrors, attempt: attempt + 1)
        case 404:
            throw DaikinError("Not Found (404): \(response.text.isEmpty ? "Resource not found" : response.text)")
        case 409:
            throw DaikinError("Conflict (409): \(response.text.isEmpty ? "Request conflict" : response.text)")
        case 422:
            throw DaikinError("Unprocessable Entity (422): \(response.text.isEmpty ? "Invalid request" : response.text)")
        case 429:
            let after = response.integer("retry-after").flatMap { $0 == 0 ? nil : $0 } ?? Self.defaultRetryAfter
            let blocked = min(after, Self.maxBlock)
            blockedUntil = Date().addingTimeInterval(Double(blocked))
            throw RateLimitedError(message: "Rate limited. Retry after \(after) seconds.", retryAfter: blocked)
        case 502, 503, 504:
            let name = response.status == 502 ? "Bad Gateway" : response.status == 503 ? "Service Unavailable" : "Gateway Timeout"
            guard retryGatewayErrors ?? (method != "GET"), attempt < Self.maxRetries else {
                throw APIUnavailableError(
                    message: "\(name) (\(response.status)): The Daikin API is temporarily unavailable after \(attempt + 1) attempts.",
                    statusCode: response.status, attemptsMade: attempt + 1)
            }
            try await dependencies.sleep(retryDelay(attempt))
            return try await request(path, method: method, body: body, retryGatewayErrors: retryGatewayErrors, attempt: attempt + 1)
        default:
            throw DaikinError("Unexpected API error (\(response.status)): \(response.text)")
        }
    }

    /// Concurrent 401s share one refresh.
    private func sharedRefresh() async throws {
        if let refreshing { return try await refreshing.value }
        let oauth = oauth
        let task = Task { _ = try await oauth.refreshToken() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    /// Exponential backoff with jitter, capped.
    private func retryDelay(_ attempt: Int) -> Duration {
        let delay = min(Self.retryBaseDelay * pow(2, Double(attempt)) + dependencies.random() * Self.retryBaseDelay, Self.retryMaxDelay)
        return .milliseconds(Int(delay))
    }

    /// Onecta's 400 codes, in words a user can act on.
    static func describeBadRequest(_ body: String) -> String {
        if (try? JSONValue(string: body))?["code"]?.stringValue == "READ_ONLY_CHARACTERISTIC" {
            return "The unit is temporarily read-only — it is powered off, updating its firmware, or locked by another controller. "
                + "It will accept commands again once it is back online."
        }
        return "Bad Request (400): \(body.isEmpty ? "No response body" : body)"
    }

    /// One GET with a token, for the settings page (no retries, no rate-limit bookkeeping): the data and the
    /// quota the answer reported.
    static func get(_ path: String, accessToken: String, http: DaikinHTTP) async throws -> (data: JSONValue?, rateLimit: RateLimitStatus) {
        guard let url = URL(string: baseURL + path) else { throw DaikinError("Invalid API path \(path)") }
        let response = try await http.send("GET", url, headers: [("Authorization", "Bearer \(accessToken)"), ("Accept", "application/json")])
        let rateLimit = RateLimitStatus(response)
        switch response.status {
        case 401: throw DaikinError("Token expired or invalid")
        case 429: throw DaikinError("Rate limit exceeded")
        case 400...: throw DaikinError("API error: \(response.status)")
        default: return (response.body.isEmpty ? nil : try JSONValue(data: response.body), rateLimit)
        }
    }
}
