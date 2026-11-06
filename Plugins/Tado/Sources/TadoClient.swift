import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// tado's cloud (docs/clean-room/Tado.md, sections 3 and 4): the login server's OAuth device authorization and refresh
// tokens, and the REST API with its retries. Requests are counted per account, since tado allows an account without a
// subscription about 100 a day (TadoBudget.swift).

/// An answer of tado that was not a success, with its status and body.
struct TadoHTTPError: Error, CustomStringConvertible {
    var status: Int
    var body: JSONValue?
    var method: String
    var path: String

    var description: String {
        let message = body?["errors"]?[0]?["title"]?.stringValue ?? body?["error_description"]?.stringValue ?? body?["error"]?.stringValue
        return "\(method) \(path) failed with HTTP \(status)" + (message.map { ": \($0)" } ?? "")
    }
}

enum TadoError: Error, CustomStringConvertible, Equatable {
    /// The account has no refresh token that works: someone has to sign in through Setup.
    case signInRequired(String)
    case tokenFile(String)
    case noHome(String)

    var description: String {
        switch self {
        case .signInRequired(let username): "tado° account \(username) needs signing in: open Add accessories in the web UI (or the MCP tool start_setup) and sign in to tado°"
        case .tokenFile(let message): message
        case .noHome(let message): message
        }
    }
}

/// Sends requests with the retries of section 4: 408, 429, 503, 504 and network errors twice more, after Retry-After
/// (up to 30 s) or 1 then 2 s.
struct TadoHTTP: Sendable {
    let transport: any HTTPSending
    /// Waits between retries; tests shorten it.
    let sleep: @Sendable (Duration) async throws -> Void

    static let retriedStatuses: Set<Int> = [408, 429, 503, 504]

    func send(_ request: HTTPRequest, retries: Int = 2) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < retries else { throw error }
                attempt += 1
                try await sleep(Self.delay(attempt: attempt))
                continue
            }
            guard Self.retriedStatuses.contains(response.status), attempt < retries else { return response }
            let wait = Self.retryAfter(response.header("Retry-After"))
            if let wait, wait > .seconds(30) { return response }
            attempt += 1
            try await sleep(wait ?? Self.delay(attempt: attempt))
        }
    }

    static func delay(attempt: Int) -> Duration { .seconds(attempt) + .milliseconds(Int.random(in: 0...100)) }

    /// Retry-After in seconds or as an HTTP date, never below 0.
    static func retryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return .milliseconds(Int(saturating: max(seconds, 0) * 1000) ?? 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .milliseconds(Int(saturating: max(date.timeIntervalSince(now), 0) * 1000) ?? 0)
    }
}

/// The login server (section 3).
enum TadoLogin {
    static let base = URL(string: "https://login.tado.com/oauth2")!
    static let clientID = "1bb50063-6b0c-4d11-bd99-387f4a91cc46"

    /// The answer of `device_authorize`.
    struct DeviceAuthorization: Sendable, Equatable {
        var deviceCode: String
        var userCode: String?
        var url: String
        var expiresIn: Int
        var interval: Int
    }

    struct Tokens: Codable, Sendable, Equatable {
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }

    /// What a poll of the device code says.
    enum PollResult: Sendable, Equatable {
        case pending
        case slowDown
        case denied(String)
        case authorized(Tokens)
    }

    static func form(_ path: String, _ fields: [(String, String)], timeout: Duration) -> HTTPRequest {
        HTTPRequest(method: "POST", url: base.appendingPathComponent(path),
                    headers: [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json")],
                    body: Data(URLEncoding.form(fields).utf8), timeout: timeout)
    }

    static func startDeviceAuthorization(http: TadoHTTP, counter: RequestCounter?) async throws -> DeviceAuthorization {
        let response = try await http.send(form("device_authorize", [("client_id", clientID), ("scope", "offline_access")], timeout: .seconds(15)), retries: 0)
        await counter?.count(login: true)
        let body = try? JSONValue(data: response.body)
        guard response.isSuccess, let code = body?["device_code"]?.text else {
            throw TadoHTTPError(status: response.status, body: body, method: "POST", path: "/oauth2/device_authorize")
        }
        let url = body?["verification_uri_complete"]?.text ?? body?["verification_uri"]?.text ?? "https://login.tado.com/oauth2/device"
        let expires = body?["expires_in"]?.saturatingIntValue ?? 300
        let interval = body?["interval"]?.saturatingIntValue ?? 5
        return DeviceAuthorization(deviceCode: code, userCode: body?["user_code"]?.text, url: url,
                                   expiresIn: expires > 0 ? expires : 300, interval: interval > 0 ? interval : 5)
    }

    /// One poll of the token endpoint with the device code.
    static func poll(deviceCode: String, http: TadoHTTP, counter: RequestCounter?) async -> PollResult {
        let request = form("token", [("client_id", clientID), ("device_code", deviceCode), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")],
                           timeout: .seconds(15))
        guard let response = try? await http.send(request, retries: 0) else { return .pending }
        await counter?.count(login: true)
        let body = try? JSONValue(data: response.body)
        switch body?["error"]?.stringValue {
        case "slow_down": return .slowDown
        case "access_denied": return .denied("tado° refused the sign-in")
        case "expired_token": return .denied("The tado° code expired: start again")
        default: break
        }
        guard response.isSuccess, let tokens = try? JSONDecoder().decode(Tokens.self, from: response.body),
              tokens.accessToken?.isEmpty == false, tokens.refreshToken?.isEmpty == false else { return .pending }
        return .authorized(tokens)
    }

    enum RefreshResult: Sendable {
        case refreshed(Tokens)
        /// The refresh token is no longer valid (400 or 401, or an answer without tokens).
        case rejected
    }

    /// Throws for a failure that keeps the refresh token (the network, a timeout, a 5xx).
    static func refresh(_ refreshToken: String, http: TadoHTTP, counter: RequestCounter?) async throws -> RefreshResult {
        let request = form("token", [("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)], timeout: .seconds(30))
        let response = try await http.send(request, retries: 0)
        await counter?.count(login: true)
        if response.status == 400 || response.status == 401 { return .rejected }
        guard response.isSuccess else { throw TadoHTTPError(status: response.status, body: try? JSONValue(data: response.body), method: "POST", path: "/oauth2/token") }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: response.body),
              tokens.accessToken?.isEmpty == false, tokens.refreshToken?.isEmpty == false else { return .rejected }
        return .refreshed(tokens)
    }

    /// The account the access token is for: `/me`'s `email`, else its `username`, lower-cased.
    static func identity(accessToken: String, apiBase: URL, http: TadoHTTP, counter: RequestCounter?) async throws -> (identity: String?, me: JSONValue) {
        let request = HTTPRequest(url: apiBase.appendingPathComponent("api/v2/me"),
                                  headers: [("Accept", "application/json"), ("Authorization", "Bearer \(accessToken)")], timeout: .seconds(15))
        let response = try await http.send(request)
        let body = try? JSONValue(data: response.body)
        guard response.isSuccess, let me = body else { throw TadoHTTPError(status: response.status, body: body, method: "GET", path: "/api/v2/me") }
        await counter?.count(login: true)
        return ((me["email"]?.text ?? me["username"]?.text)?.lowercased(), me)
    }
}

/// One tado account's tokens, shared by every home with its username, so one refresh token chain has one refresher
/// (tado rotates refresh tokens: two refreshers of one would invalidate each other).
actor TadoAccount {
    typealias Tokens = TadoLogin.Tokens

    let username: String
    private let file: SecretFile<Tokens>?
    /// The token file another program keeps, for a username ending with `.json`.
    private let tokenFile: URL?
    private let http: TadoHTTP
    let counter: RequestCounter
    private let logger: Logger
    private let now: @Sendable () -> Date

    private var accessToken: String?
    private var obtained = Date.distantPast
    private var validUntil = Date.distantPast
    private var refreshToken: String?
    private var inFlight: Task<String, any Error>?
    /// Set once refreshing failed for good, until a new token is in the vault (Setup); logged once.
    private var signInRequired = false

    init(username: String, file: SecretFile<Tokens>?, tokenFile: URL?, http: TadoHTTP, counter: RequestCounter, logger: Logger, now: @escaping @Sendable () -> Date = Date.init) {
        self.username = username
        self.file = file
        self.tokenFile = tokenFile
        self.http = http
        self.counter = counter
        self.logger = logger
        self.now = now
    }

    /// The vault's file name for a username's tokens: the Homebridge plugin's, so a copied file moves into the vault.
    static func fileName(username: String) -> String { ".tado-token-\(TadoHash.username(username)).json" }

    /// Whether the vault has a refresh token for the account (or it needs none).
    var isAuthorized: Bool {
        if tokenFile != nil || (refreshToken != nil && !signInRequired) { return true }
        // A stored token tado refused does not count: only a new one Setup kept.
        guard let stored = file?.load()?.refreshToken, !stored.isEmpty else { return false }
        return !signInRequired || stored != refreshToken
    }

    /// A valid access token: the current one, else one refreshed (once for all callers at a time).
    func token() async throws -> String {
        if let accessToken, now() < validUntil { return accessToken }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.renew() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// After a 401 with `rejected`: the token to try again with, or nil to give up (a token not a minute old).
    func retryToken(after rejected: String) async throws -> String? {
        if let accessToken, accessToken != rejected, now() < validUntil { return accessToken }
        if now().timeIntervalSince(obtained) < 60 { return nil }
        validUntil = .distantPast
        return try await token()
    }

    private func renew() async throws -> String {
        if let tokenFile { return try readTokenFile(tokenFile) }
        // The vault's refresh token wins over the one in memory when they differ: Setup signed in again meanwhile.
        if let stored = file?.load()?.refreshToken, !stored.isEmpty, stored != refreshToken {
            refreshToken = stored
            signInRequired = false
        }
        guard let refresh = refreshToken, !signInRequired else { throw requireSignIn("no refresh token is stored for it") }
        switch try await TadoLogin.refresh(refresh, http: http, counter: counter) {
        case .rejected:
            // Out of the vault too, so every instance (Setup's included) sees the account needs signing in.
            if file?.load()?.refreshToken == refresh { file?.remove() }
            throw requireSignIn("tado° refused its refresh token")
        case .refreshed(let tokens):
            store(tokens)
            return tokens.accessToken ?? ""
        }
    }

    /// Keeps a new pair, in memory first, then in the vault.
    func store(_ tokens: Tokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        obtained = now()
        // `expires_in` (about 10 minutes), less a margin; 9 minutes when tado says nothing.
        let lifetime = tokens.expiresIn.map { Double(max($0 - 30, 30)) } ?? 540
        validUntil = obtained.addingTimeInterval(lifetime)
        signInRequired = false
        do {
            try file?.save(Tokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken))
        } catch {
            logger.error("Could not keep the tado° tokens of \(username) in the vault: \(error)")
        }
    }

    private func requireSignIn(_ reason: String) -> TadoError {
        if !signInRequired { logger.warning("tado° account \(username): \(reason); sign in again through Setup (Add accessories)") }
        signInRequired = true
        accessToken = nil
        return .signInRequired(username)
    }

    /// A token file: `access_token`, as old as the file, read again once 9 minutes old.
    private func readTokenFile(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url), let token = (try? JSONValue(data: data))?["access_token"]?.text else {
            throw TadoError.tokenFile("Could not read an access_token from \(url.path)")
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now()
        obtained = min(modified, now())
        validUntil = obtained.addingTimeInterval(540)
        if validUntil <= now() { validUntil = now().addingTimeInterval(60) }
        accessToken = token
        return token
    }
}

/// tado's REST API for one home's base address (section 5).
struct TadoAPI: Sendable {
    let base: URL
    /// Nil with `skipAuth`: no Authorization header.
    let account: TadoAccount?
    let http: TadoHTTP
    let counter: RequestCounter
    let logger: Logger
    let debug: Bool

    static let minder = URL(string: "https://minder.tado.com")!

    /// Sends one request, its JSON body if it has keys; answers the JSON body (null when empty).
    @discardableResult
    func call(_ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil, host: URL? = nil) async throws -> JSONValue {
        var components = URLComponents(url: (host ?? base).appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var request = HTTPRequest(method: method, url: components.url!, headers: [("Accept", "application/json")], timeout: .seconds(15))
        if method != "GET", let body, body.objectValue?.isEmpty == false {
            request.body = body.encoded()
            request.setHeader("Content-Type", "application/json")
        }
        if debug { logger.info("tado° request: \(method) \(path)\(query.isEmpty ? "" : "?" + query.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))") }
        var token = try await account?.token()
        var response = try await send(request, token: token)
        if response.status == 401, let used = token, let account {
            token = try await account.retryToken(after: used)
            if let token { response = try await send(request, token: token) }
        }
        let parsed = response.body.isEmpty ? JSONValue.null : ((try? JSONValue(data: response.body)) ?? .string(String(decoding: response.body, as: UTF8.self)))
        guard response.isSuccess else {
            let error = TadoHTTPError(status: response.status, body: parsed, method: method, path: path)
            logger.error("tado° API request failed: \(error)")
            throw error
        }
        await counter.count(login: false)
        return parsed
    }

    private func send(_ request: HTTPRequest, token: String?) async throws -> HTTPResponse {
        var request = request
        if let token { request.setHeader("Authorization", "Bearer \(token)") }
        return try await http.send(request)
    }

    // MARK: Endpoints

    func me() async throws -> JSONValue { try await call("GET", "api/v2/me") }
    func home(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)") }
    func zones(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/zones") }
    func zoneStates(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/zoneStates") }
    func capabilities(_ home: Int, zone: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/zones/\(zone)/capabilities") }
    @discardableResult func setOverlay(_ home: Int, zone: Int, _ overlay: JSONValue) async throws -> JSONValue {
        try await call("PUT", "api/v2/homes/\(home)/zones/\(zone)/overlay", body: overlay)
    }
    func clearOverlay(_ home: Int, zone: Int) async throws { try await call("DELETE", "api/v2/homes/\(home)/zones/\(zone)/overlay") }
    func setOverlays(_ home: Int, _ overlays: JSONValue) async throws { try await call("POST", "api/v2/homes/\(home)/overlay", body: overlays) }
    func clearOverlays(_ home: Int, rooms: [Int]) async throws {
        try await call("DELETE", "api/v2/homes/\(home)/overlay", query: [("rooms", rooms.map(String.init).joined(separator: ","))])
    }
    func state(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/state") }
    /// HOME, AWAY or AUTO (back to geofencing).
    func setPresence(_ home: Int, _ presence: String) async throws {
        try await call(presence == "AUTO" ? "DELETE" : "PUT", "api/v2/homes/\(home)/presenceLock", body: ["homePresence": .string(presence)])
    }
    func mobileDevices(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/mobileDevices") }
    func weather(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/weather") }
    func devices(_ home: Int) async throws -> JSONValue { try await call("GET", "api/v2/homes/\(home)/devices") }
    func setChildLock(serial: String, _ enabled: Bool) async throws {
        try await call("PUT", "api/v2/devices/\(serial)/childLock", body: ["childLockEnabled": .bool(enabled)])
    }
    func setOpenWindow(_ home: Int, zone: Int, _ enabled: Bool) async throws {
        try await call("PUT", "api/v2/homes/\(home)/zones/\(zone)/openWindowDetection", body: ["enabled": .bool(enabled), "timeoutInSeconds": 3600])
        if enabled {
            try await call("POST", "api/v2/homes/\(home)/zones/\(zone)/state/openWindow/activate")
        } else {
            try await call("DELETE", "api/v2/homes/\(home)/zones/\(zone)/state/openWindow")
        }
    }
    /// Seconds of heating over a period (minder.tado.com).
    func runningTime(_ home: Int, aggregate: String, from: String, to: String? = nil) async throws -> Double? {
        var query = [("aggregate", aggregate), ("summary_only", "true"), ("from", from)]
        if let to { query.append(("to", to)) }
        return try await call("GET", "v1/homes/\(home)/runningTimes", query: query, host: Self.minder)["summary"]?["totalRunningTimeInSeconds"]?.doubleValue
    }
}
