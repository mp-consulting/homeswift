import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The waits of the plugin, from docs/clean-room/Ring.md; tests shorten the delays (never the timeouts).
struct RingTiming: Sendable {
    /// After a request that got no answer at all (Backoff from this, up to a minute).
    var transportRetry: Duration = .seconds(5)
    /// After a 504.
    var gatewayRetry: Duration = .seconds(5)
    /// After a 404 with a known code (the device is offline, updating…), Backoff from this up to five minutes.
    var knownErrorRetry: Duration = .seconds(20)
    /// A session is made again this often, or Ring drops it (and with it the pushes) outside the US.
    var sessionRenewal: Duration = .seconds(12 * 3600)
    /// When a 429 on the session has no Retry-After.
    var sessionRateLimit: Duration = .seconds(200)
    var requestTimeout: Duration = .seconds(20)
    /// Before a location socket connects again.
    var hubReconnect: Duration = .seconds(1)
    /// The longest the start waits for a hub's device lists (the original waits forever).
    var hubListTimeout: Duration = .seconds(30)
    /// The longest an alarm mode change waits for the panel's answer (the original waits forever).
    var alarmModeTimeout: Duration = .seconds(30)
    /// How long a ding or motion notification stays active.
    var notificationLifetime: Duration = .seconds(65)
    /// Pushes this soon after connecting are dropped (redelivered ones).
    var pushQuiet: Duration = .seconds(2)
    var doorbellThrottle: Duration = .seconds(15)
    var intercomUnlocked: Duration = .seconds(5)
    /// Slider writes: only the last of a burst goes out.
    var levelDebounce: Duration = .milliseconds(500)
    /// After a camera light write, the written value is shown whatever a poll says.
    var lightOverride: Duration = .seconds(30)
    var refreshThrottle: Duration = .milliseconds(500)
    var playSwitchReset: Duration = .seconds(1)
    var snapshotTimeout: Duration = .seconds(15)
    var snapshotUUIDWait: Duration = .seconds(2)
    /// A cached snapshot is kept this long past its lifetime, for clients polling every minute.
    var snapshotKeep: Duration = .seconds(120)
    var locationModeTargetPush: Duration = .milliseconds(100)
    var resubscribeThrottle: Duration = .seconds(1)
}

enum RingError: Error, CustomStringConvertible, Equatable {
    /// The refresh token was refused: Setup has to sign in again.
    case notAuthorized
    /// The account needs a 2FA code; the text says where it went.
    case needsCode(String)
    case wrongCode
    case rateLimited
    case tokenFailed(String)
    case http(status: Int, path: String)
    case notFound(path: String)
    case unexpected(String)

    var description: String {
        switch self {
        case .notAuthorized: "Ring refused the refresh token; sign in again through Setup (Add accessories)"
        case .needsCode(let prompt): prompt
        case .wrongCode: "The code is wrong or expired; check the code and try again"
        case .rateLimited: "Ring allows 10 codes per 10 minutes; wait 10 minutes and try again"
        case .tokenFailed(let reason): "Failed to fetch an OAuth token from Ring (\(reason)); verify the email and password"
        case .http(let status, let path): "Ring answered HTTP \(status) to \(path)"
        case .notFound(let path): "Ring has nothing at \(path)"
        case .unexpected(let text): text
        }
    }
}

/// A response with the two headers snapshots need: `date` (as milliseconds) and `x-time-millis`.
struct RingResponse: Sendable {
    var status: Int
    var body: Data
    var responseTimestamp: Double?
    var timeMillis: Double?

    var json: JSONValue { (try? JSONValue(data: body)) ?? .null }
}

/// Ring's cloud API (docs/clean-room/Ring.md, 2 and 3): OAuth with a rotating refresh token, a session made lazily
/// when Ring answers "Session not found" and renewed every 12 hours, and the retry rules of each status.
actor RingClient {
    static let clientsAPI = "https://api.ring.com/clients_api/"
    static let devicesAPI = "https://api.ring.com/devices/v1/"
    static let commandsAPI = "https://api.ring.com/commands/v1/"
    static let appAPI = "https://prd-api-us.prd.rings.solutions/api/v1/"
    static let oauthURL = URL(string: "https://oauth.ring.com/oauth/token")!
    static let userAgent = "android:com.ringapp"

    enum Grant: Sendable {
        case refresh(String)
        case password(email: String, password: String)
    }

    struct Token: Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int
    }

    private let http: any HTTPSending
    private(set) var account: RingAccount
    let displayName: String
    private let timing: RingTiming
    private let logger: Logger
    /// Called with the account each time its refresh token rotates: it must be stored at once.
    private let onAccountChange: @Sendable (_ previous: RingAccount, _ rotated: RingAccount) -> Void
    /// Called after each session is made: re-subscribe the cameras, register the push token again.
    private var onSessionCreated: (@Sendable () async -> Void)?
    private var accessToken: (token: String, expires: ContinuousClock.Instant)?
    private var tokenTask: Task<String, any Error>?
    private var sessionTask: Task<Void, any Error>?
    private var renewal: Task<Void, Never>?

    init(
        http: any HTTPSending, account: RingAccount, displayName: String, timing: RingTiming, logger: Logger,
        onAccountChange: @escaping @Sendable (_ previous: RingAccount, _ rotated: RingAccount) -> Void
    ) {
        self.http = http
        self.account = account
        self.displayName = displayName
        self.timing = timing
        self.logger = logger
        self.onAccountChange = onAccountChange
    }

    func setOnSessionCreated(_ handler: @escaping @Sendable () async -> Void) { onSessionCreated = handler }

    func shutdown() {
        renewal?.cancel()
        tokenTask?.cancel()
        sessionTask?.cancel()
    }

    // MARK: OAuth

    /// One token request (2.4). 412 asks for a 2FA code, 400 "Verification Code…" says the code was wrong.
    static func requestToken(http: any HTTPSending, grant: Grant, hardwareID: String, code: String?, timeout: Duration) async throws -> Token {
        var body: [String: JSONValue] = ["client_id": "ring_official_android", "scope": "client"]
        switch grant {
        case .refresh(let token):
            body["grant_type"] = "refresh_token"
            body["refresh_token"] = .string(token)
        case .password(let email, let password):
            body["grant_type"] = "password"
            body["username"] = .string(email)
            body["password"] = .string(password)
        }
        let request = HTTPRequest(
            method: "POST", url: oauthURL,
            headers: [("Content-Type", "application/json"), ("Accept", "application/json"), ("2fa-support", "true"), ("2fa-code", code ?? ""),
                      ("hardware_id", hardwareID), ("User-Agent", userAgent)],
            body: JSONValue.object(body).encoded(), timeout: timeout)
        let response = try await http.send(request)
        let json = (try? JSONValue(data: response.body)) ?? .null
        if response.isSuccess, let access = json["access_token"]?.stringValue, let refresh = json["refresh_token"]?.stringValue {
            return Token(accessToken: access, refreshToken: refresh, expiresIn: json["expires_in"]?.saturatingIntValue ?? 3600)
        }
        if json["error_description"]?.stringValue == "too many requests from dependency service" { throw RingError.rateLimited }
        if response.status == 412 {
            let state = json["tsv_state"]?.stringValue
            let prompt: String = switch state {
            case "totp": "Enter the code from your authenticator app"
            case let state?: "Enter the code sent to \(json["phone"]?.stringValue ?? "you") via \(state)"
            case nil: "Enter the code sent to your phone or email"
            }
            throw RingError.needsCode(prompt)
        }
        if response.status == 400, json["error"]?.stringValue?.hasPrefix("Verification Code") == true { throw RingError.wrongCode }
        if case .refresh = grant, [400, 401, 403].contains(response.status) { throw RingError.notAuthorized }
        throw RingError.tokenFailed(json["error"]?.stringValue ?? "HTTP \(response.status)")
    }

    /// The access token, refreshed (and the refresh token rotated and stored) 60 s before it expires.
    func currentAccessToken() async throws -> String {
        if let accessToken, accessToken.expires > .now { return accessToken.token }
        if let tokenTask { return try await tokenTask.value }
        let task = Task { try await self.refreshAccessToken() }
        tokenTask = task
        defer { tokenTask = nil }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        var attempt = 0
        while true {
            do {
                let token = try await Self.requestToken(
                    http: http, grant: .refresh(account.refreshToken), hardwareID: account.hardwareId, code: nil, timeout: timing.requestTimeout)
                let previous = account
                account.refreshToken = token.refreshToken
                onAccountChange(previous, account)
                accessToken = (token.accessToken, .now + .seconds(max(token.expiresIn - 60, 30)))
                return token.accessToken
            } catch let error as RingError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No answer at all: try again, as long as the plugin runs.
                attempt += 1
                if attempt > 1 { logger.warning("Ring's sign-in did not answer: \(error)") }
                try await Task.sleep(for: Backoff(initial: timing.transportRetry, maximum: .seconds(60)).delay(attempt: attempt - 1))
            }
        }
    }

    // MARK: Requests

    /// An authenticated request with the retry rules of 2.1. `allowNoResponse` (snapshots) is not retried when there is
    /// no answer.
    func send(_ method: String, _ url: String, json body: JSONValue? = nil, accept: String = "application/json", allowNoResponse: Bool = false) async throws -> RingResponse {
        guard let target = URL(string: url) else { throw RingError.unexpected("invalid URL") }
        let path = target.path
        var transportFailures = 0, unauthorized = 0, known = 0, sessions = 0
        while true {
            let token = try await currentAccessToken()
            var headers: [(name: String, value: String)] = [
                ("Accept", accept), ("authorization", "Bearer \(token)"), ("hardware_id", account.hardwareId), ("User-Agent", Self.userAgent),
            ]
            if body != nil { headers.append(("Content-Type", "application/json")) }
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(method: method, url: target, headers: headers, body: body?.encoded(), timeout: timing.requestTimeout))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if allowNoResponse { throw error }
                transportFailures += 1
                if transportFailures > 1 { logger.warning("Ring did not answer \(method) \(path), retrying: \(error)") }
                try await Task.sleep(for: Backoff(initial: timing.transportRetry, maximum: .seconds(60)).delay(attempt: transportFailures - 1))
                continue
            }
            if response.isSuccess {
                return RingResponse(
                    status: response.status, body: response.body, responseTimestamp: response.header("date").flatMap(Self.httpDate),
                    timeMillis: response.header("x-time-millis").flatMap(Double.init))
            }
            let json = (try? JSONValue(data: response.body)) ?? .null
            switch response.status {
            case 401 where unauthorized < 2:
                unauthorized += 1
                accessToken = nil
                continue
            case 504:
                try await Task.sleep(for: timing.gatewayRetry)
                continue
            case 404:
                let codes = (json["errors"]?.arrayValue ?? []).compactMap(\.saturatingIntValue)
                let names = codes.compactMap { Self.knownErrors[$0] }
                if !names.isEmpty {
                    known += 1
                    logger.info("Ring answered \(names.joined(separator: ", ")) to \(path); retrying")
                    try await Task.sleep(for: Backoff(initial: timing.knownErrorRetry, maximum: .seconds(300)).delay(attempt: known - 1))
                    continue
                }
                if url.hasPrefix(Self.clientsAPI) {
                    if sessions < 2, json["error"]?.stringValue?.contains(account.hardwareId) == true {
                        sessions += 1
                        try await createSession()
                        continue
                    }
                    throw RingError.notFound(path: path)
                }
            default:
                break
            }
            logger.warning("Ring answered HTTP \(response.status) to \(method) \(path)")
            if let excerpt = logExcerpt(String(decoding: response.body, as: UTF8.self)) { logger.debug("Ring's answer: \(excerpt)") }
            throw RingError.http(status: response.status, path: path)
        }
    }

    static let knownErrors = [7050: "NO_ASSET", 7019: "ASSET_OFFLINE", 7061: "ASSET_CELL_BACKUP", 7062: "UPDATING", 7063: "MAINTENANCE"]

    func json(_ url: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        try await send(method, url, json: body).json
    }

    static func httpDate(_ text: String) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: Session

    /// Makes a session (2.5), or waits for the one being made.
    func createSession() async throws {
        if let sessionTask { return try await sessionTask.value }
        let task = Task { try await self.postSession() }
        sessionTask = task
        defer { sessionTask = nil }
        try await task.value
    }

    private func postSession() async throws {
        let body: JSONValue = [
            "device": ["hardware_id": .string(account.hardwareId), "metadata": ["api_version": 11, "device_model": .string(displayName)], "os": "android"],
        ]
        var unauthorized = 0
        while true {
            let token = try await currentAccessToken()
            let response = try await http.send(HTTPRequest(
                method: "POST", url: URL(string: Self.clientsAPI + "session")!,
                headers: [("Content-Type", "application/json"), ("Accept", "application/json"), ("authorization", "Bearer \(token)"),
                          ("hardware_id", account.hardwareId), ("User-Agent", Self.userAgent)],
                body: body.encoded(), timeout: timing.requestTimeout))
            if response.isSuccess { break }
            if response.status == 401, unauthorized < 2 {
                unauthorized += 1
                accessToken = nil
                continue
            }
            if response.status == 429 {
                let wait = response.header("retry-after").flatMap(Int.init).map { Duration.seconds($0 + 1) } ?? timing.sessionRateLimit
                logger.warning("Ring is rate limiting its sessions; waiting \(wait.components.seconds) s")
                try await Task.sleep(for: wait)
                continue
            }
            throw RingError.http(status: response.status, path: "/clients_api/session")
        }
        logger.debug("Created a Ring session")
        if renewal == nil {
            let interval = timing.sessionRenewal
            renewal = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    do { try await self?.createSession() } catch { await self?.logSessionFailure(error) }
                }
            }
        }
        if let onSessionCreated { Task { await onSessionCreated() } }
    }

    private func logSessionFailure(_ error: any Error) { logger.warning("Could not renew the Ring session: \(error)") }

    // MARK: Endpoints (3.1)

    func locations() async throws -> [JSONValue] {
        guard let list = try await json(Self.devicesAPI + "locations")["user_locations"]?.arrayValue else {
            throw RingError.unexpected("the Ring account has no locations")
        }
        return list
    }

    func ringDevices() async throws -> JSONValue { try await json(Self.clientsAPI + "ring_devices") }

    func subscribe(_ id: String, motions: Bool) async throws {
        _ = try await send("POST", Self.clientsAPI + "doorbots/\(id)/\(motions ? "motions_subscribe" : "subscribe")")
    }

    func put(_ path: String, body: JSONValue? = nil) async throws { _ = try await send("PUT", Self.clientsAPI + path, json: body) }

    func registerPushToken(_ token: String) async throws {
        let body: JSONValue = [
            "device": [
                "metadata": ["api_version": 11, "device_model": .string(displayName), "pn_dict_version": "2.0.0", "pn_service": "fcm"],
                "os": "android", "push_notification_token": .string(token),
            ],
        ]
        _ = try await send("PATCH", Self.clientsAPI + "device", json: body)
    }

    /// The camera's next snapshot: by a notification's uuid, or forced after the last one's camera time.
    func snapshot(cameraID: String, uuid: String?, afterMilliseconds: Double) async throws -> RingResponse {
        let query = uuid.map { "uuid=\(URLEncoding.rfc3986($0))" } ?? "after-ms=\(Int64(afterMilliseconds))&extras=force"
        return try await send("GET", "https://app-snaps.ring.com/snapshots/next/\(cameraID)?\(query)", accept: "image/jpeg", allowNoResponse: true)
    }

    func hubTicket(locationID: String) async throws -> JSONValue {
        try await json(Self.appAPI + "clap/tickets?locationID=\(URLEncoding.rfc3986(locationID))&enableExtendedEmergencyCellUsage=true&requestedTransport=ws")
    }

    func locationMode(_ locationID: String) async throws -> JSONValue { try await json(Self.appAPI + "mode/location/\(locationID)") }

    func setLocationMode(_ locationID: String, _ mode: String) async throws -> JSONValue {
        try await json(Self.appAPI + "mode/location/\(locationID)", method: "POST", body: ["mode": .string(mode)])
    }

    func dispatchPanic(locationID: String, assetUUID: String, signal: String) async throws {
        let now = Double(Int64(Date().timeIntervalSince1970 * 1000))
        let body: JSONValue = [
            "alarmSessionUuid": .string(UUID().uuidString.lowercased()), "currentTsMs": .number(now), "eventOccurredTime": .number(now), "signalType": .string(signal),
        ]
        _ = try await send("POST", Self.appAPI + "rs/monitoring/accounts/\(locationID)/assets/\(assetUUID)/userAlarm", json: body)
    }

    func setLightGroup(locationID: String, groupID: String, on: Bool, duration: Int) async throws {
        let body: JSONValue = ["lights_on": ["duration_seconds": .number(Double(duration)), "enabled": .bool(on)]]
        _ = try await send("POST", "https://api.ring.com/groups/v1/locations/\(locationID)/groups/\(groupID)/devices", json: body)
    }

    func playChime(_ id: String, kind: String) async throws {
        _ = try await send("POST", Self.clientsAPI + "chimes/\(id)/play_sound", json: ["kind": .string(kind)])
    }

    func snoozeChime(_ id: String, minutes: Int?) async throws {
        _ = try await send("POST", Self.clientsAPI + "chimes/\(id)/do_not_disturb", json: minutes.map { ["time": .number(Double($0))] })
    }

    func setChimeNightlight(_ id: String, on: Bool) async throws {
        _ = try await send("PATCH", Self.devicesAPI + "devices/\(id)/settings", json: ["night_light_settings": ["light_sensor_enabled": .bool(on)]])
    }

    func unlockIntercom(_ id: String) async throws -> JSONValue {
        let body: JSONValue = [
            "command_name": "device_rpc",
            "request": ["jsonrpc": "2.0", "method": "unlock_door", "params": ["door_id": 0, "user_id": 0]],
        ]
        return try await send("PUT", Self.commandsAPI + "devices/\(id)/device_rpc", json: body).json
    }
}
