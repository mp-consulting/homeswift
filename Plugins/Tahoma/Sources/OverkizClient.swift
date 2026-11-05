import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// An error from Overkiz, flattened as the Homebridge plugin's client does (3.6): `Error <status> <error>(<errorCode>)`.
struct OverkizError: Error, CustomStringConvertible, Equatable {
    var status: Int?
    var errorCode: String?
    var message: String
    /// Not the server's answer: the client's own pause after refusals (`SignInLockout`).
    var isPause = false

    init(status: Int? = nil, errorCode: String? = nil, message: String, isPause: Bool = false) {
        self.status = status
        self.errorCode = errorCode
        self.message = message
        self.isPause = isPause
    }

    /// As the log shows it: a gateway's PIN in the server's message (`… on gateway: #1234-5678-9012`) masked.
    var description: String {
        let message = OverkizClient.redacted(message)
        guard let status else { return message }
        return "Error \(status) \(message)" + (errorCode.map { "(\($0))" } ?? "")
    }

    /// The account refused what it was given (4.5): a password, a token, a user that does not exist.
    var isBadCredentials: Bool {
        let text = message.lowercased()
        return text.contains("bad credentials") || text.contains("no such user") || text.contains("invalid credentials")
            || text.contains("invalid_grant") || text.contains("invalid.grant") || errorCode == "invalid_grant" || (status == 401 && errorCode == nil && text.contains("not authenticated"))
    }

    /// The credentials themselves were refused: bad credentials, or a 401 from a gateway, whose only credential is
    /// its token.
    func refusesCredentials(local: Bool) -> Bool { isBadCredentials || (local && status == 401) }

    /// A limit the server sets for a while (4.5): too many executions, a full queue, concurrent requests.
    var isBusy: Bool {
        let text = message.lowercased()
        return errorCode == "EXEC_QUEUE_FULL" || text.contains("too many executions") || text.contains("too many concurrent requests")
    }

    /// From a response that is not a success: the JSON body's `error` and `errorCode`, or the start of its text.
    init(response: HomeswiftNetwork.HTTPResponse) {
        let body = (try? JSONValue(data: response.body)) ?? .null
        let error = body["error"]?.stringValue ?? body["error_description"]?.stringValue ?? body["message"]?.stringValue
        let code = body["errorCode"]?.stringValue ?? (body["error"]?.stringValue == "invalid_grant" ? "invalid_grant" : nil)
        var message = error ?? ""
        if message.isEmpty {
            let text = String(decoding: response.body.prefix(512), as: UTF8.self)
            message = text.contains("is down for maintenance") ? "the service is down for maintenance" : (logExcerpt(text, limit: 120) ?? "")
        }
        self.init(status: response.status, errorCode: code, message: message.isEmpty ? "HTTP \(response.status)" : message)
    }
}

/// Somfy's OAuth sign-in (docs/clean-room/Tahoma.md 11): one token endpoint for every region, and the TaHoma app's
/// client, public by design (it is in the mobile apps).
enum SomfyOAuth {
    static let tokenURL = "https://accounts.somfy.com/oauth/oauth/v2/token/jwt"
    static let clientID = "0d8e920c-1478-11e7-a377-02dd59bd3041_1ewvaqmclfogo4kcsoo0c8k4kso884owg08sg8c40sk4go4ksg"
    static let clientSecret = "12k73w1n540g8o4cokg0cw84cog840k84cwggscwg884004kgk"
    /// A token is refreshed when it has this long left.
    static let refreshMargin: Duration = .seconds(5)
}

/// Where the client keeps Somfy's refresh token between runs (the plugin's `context.secretFile`); nil keeps it in
/// memory only (Setup).
struct RefreshTokenStore: Sendable {
    var load: @Sendable () -> String?
    var save: @Sendable (String?) -> Void
}

/// The pause after the server refused a sign-in (3.1): 60 s, then four times longer each time, at most 4 h. Shared by the
/// clients a plugin makes one after another, so a retry does not start the pause over. `grace` refusals start no pause
/// (Setup's, where a person corrects a typo at once).
final class SignInLockout: Sendable {
    static let backoff = Backoff(initial: .seconds(60), factor: 4, maximum: .seconds(4 * 3600))
    private let grace: Int

    init(grace: Int = 0) { self.grace = grace }

    private struct State {
        var until: ContinuousClock.Instant?
        var refusals = 0
    }

    private let state = NIOLockedValueBox(State())

    /// How long sign-in stays paused from `now`, or nil.
    func remaining(at now: ContinuousClock.Instant) -> Duration? {
        state.withLockedValue { state in
            guard let until = state.until else { return nil }
            if until > now { return until - now }
            state.until = nil
            return nil
        }
    }

    /// A refusal at `now`: answers the pause it starts, nil while within the grace.
    func refused(at now: ContinuousClock.Instant) -> Duration? {
        state.withLockedValue { state in
            state.refusals += 1
            guard state.refusals > grace else { return nil }
            let pause = Self.backoff.delay(attempt: state.refusals - grace - 1)
            state.until = now + pause
            return pause
        }
    }

    func accepted() { state.withLockedValue { $0 = State() } }
}

/// How the client reaches the setup: a cloud with its sign-in, or a gateway's local API with a token.
enum OverkizEndpoint: Sendable, Equatable {
    case cloud(OverkizService, user: String, password: String)
    /// A gateway's local API at `host` (an address or `gateway-<PIN>.local`), `pin` when known.
    case local(host: String, pin: String?, token: String)

    var isLocal: Bool { if case .local = self { true } else { false } }
}

/// Talks to Overkiz (sections 3 and 4): signs in lazily before the first request, signs in again once on a 401, and keeps
/// itself from signing in again for a while after the server refused it (the `SignInLockout` of 3.1, which avoids
/// Overkiz's ban for repeated bad logins).
actor OverkizClient {
    /// What answers HTTP: one client for the clouds, one for the gateway (its certificate checked against the Overkiz
    /// Root CA); tests give a fake.
    struct Transport: Sendable {
        var http: any HTTPSending
        var timeout: Duration = .seconds(15)
    }

    static let cozytouchBasic = "Q3RfMUpWeVRtSUxYOEllZkE3YVVOQmpGblpVYToyRWNORHpfZHkzNDJVSnFvMlo3cFNKTnZVdjBh"

    let endpoint: OverkizEndpoint
    private let transport: Transport
    private let proxy: URL?
    private let logger: Logger
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cookie: String?
    private var signedIn = false
    /// Somfy OAuth: the Bearer, its refresh token and when it expires (nil: until the server refuses it).
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: ContinuousClock.Instant?
    /// After a 401, the next sign-in is a new password grant rather than a refresh (11.4).
    private var passwordGrantNext = false
    private let tokenStore: RefreshTokenStore?
    /// Changes when the session does (a refreshed token): an event listener belongs to the session it was made in.
    private(set) var sessionGeneration = 0
    private let lockout: SignInLockout
    /// The sign-in or token refresh under way: requests that arrive meanwhile wait for it rather than sending their
    /// own (a refused password counted three times, a rotated refresh token spent twice).
    private var signingIn: Task<Void, Error>?
    private var refreshing: Task<Void, Error>?
    /// Called with the error when the account refuses the credentials, and with nil once it accepts them.
    private let onAccount: @Sendable (OverkizError?) -> Void

    init(
        endpoint: OverkizEndpoint, transport: Transport, proxy: String? = nil, logger: Logger, tokenStore: RefreshTokenStore? = nil,
        lockout: SignInLockout = SignInLockout(), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, onAccount: @escaping @Sendable (OverkizError?) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.proxy = proxy.flatMap(URL.init(string:))
        self.logger = logger
        self.now = now
        self.onAccount = onAccount
        self.tokenStore = tokenStore
        self.lockout = lockout
    }

    /// Whether this client signs in with Somfy's OAuth: Somfy Europe (11.1). Oceania and North America keep the session
    /// login, as do the other brands.
    var usesOAuth: Bool {
        if case .cloud(.somfyEurope, _, _) = endpoint { return true }
        return false
    }

    /// The API's base URL: the cloud's, or the gateway's on port 8443 (with the extra `/1`).
    var baseURL: String {
        switch endpoint {
        case .cloud(let service, _, _): "https://\(service.host ?? "ha101-1.overkiz.com")/enduser-mobile-web/enduserAPI"
        case .local(let host, _, _): "https://\(host):8443/enduser-mobile-web/1/enduserAPI"
        }
    }

    // MARK: Requests

    /// A JSON request to a path of the API, signed in first. A 401 signs out, and unless `reconnect` is off, the request
    /// goes once more after signing in again.
    @discardableResult
    func request(_ method: String, _ path: String, json: JSONValue? = nil, reconnect: Bool = true) async throws -> JSONValue {
        try await signIn()
        try await refreshIfDue()
        do {
            return try await send(method, path, json: json)
        } catch let error as OverkizError where error.status == 401 {
            if signedIn { logger.debug("Session expired: \(error)") }
            signedIn = false
            cookie = nil
            accessToken = nil
            passwordGrantNext = true
            guard reconnect else { throw error }
            try await signIn()
            return try await send(method, path, json: json)
        }
    }

    private func send(_ method: String, _ path: String, json: JSONValue?) async throws -> JSONValue {
        var headers: [(name: String, value: String)] = [("Accept", "application/json")]
        switch endpoint {
        case .local(_, _, let token): headers.append(("Authorization", "Bearer \(token)"))
        case .cloud:
            // Never both: Overkiz refuses a request with a session cookie and a Bearer (11.3).
            if usesOAuth {
                if let accessToken { headers.append(("Authorization", "Bearer \(accessToken)")) }
            } else if let cookie {
                headers.append(("Cookie", cookie))
            }
        }
        var body: Data?
        if let json {
            body = json.encoded()
            headers.append(("Content-Type", "application/json"))
        }
        let response = try await http(method, baseURL + path, headers: headers, body: body)
        guard response.isSuccess else { throw OverkizError(response: response) }
        if response.body.isEmpty { return .null }
        return (try? JSONValue(data: response.body)) ?? .string(String(decoding: response.body, as: UTF8.self))
    }

    /// Sends one request, through the proxy when there is one; a transport failure becomes an `OverkizError`.
    private func http(_ method: String, _ url: String, headers: [(name: String, value: String)], body: Data?) async throws -> HomeswiftNetwork.HTTPResponse {
        guard var target = URL(string: url) else { throw OverkizError(message: "cannot request \(url)") }
        var headers = headers
        if let proxy, let original = target.host, let path = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedPath {
            let query = target.query.map { "?\($0)" } ?? ""
            target = URL(string: proxy.absoluteString.trimmingTrailingSlash + path + query) ?? target
            headers.append(("X-Forward-Host", original))
        }
        logger.debug("\(method) \(Self.redacted(url))")
        do {
            return try await transport.http.send(HomeswiftNetwork.HTTPRequest(method: method, url: target, headers: headers, body: body, timeout: transport.timeout))
        } catch let error as OverkizError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OverkizError(message: "\(error)")
        }
    }

    /// A URL as the log shows it: the gateway's PIN masked.
    static func redacted(_ url: String) -> String {
        url.replacingOccurrences(of: #"\d{4}-\d{4}-\d{4}"#, with: "****-****-****", options: .regularExpression)
    }

    // MARK: Signing in

    /// Signs in unless signed in already (3.1–3.4), once for every request waiting. Throws at once while locked out.
    func signIn() async throws {
        guard !signedIn else { return }
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.performSignIn() }
        signingIn = task
        defer { signingIn = nil }
        try await task.value
    }

    private func performSignIn() async throws {
        if let remaining = lockout.remaining(at: now()) {
            throw OverkizError(message: "Sign-in is paused for \(Self.describe(remaining)) after the server refused it: check the credentials, or wait to be unbanned", isPause: true)
        }
        do {
            switch endpoint {
            case .local:
                // The token is the sign-in: the API's version checks it (3.4).
                let version = try await send("GET", "/apiVersion", json: nil)
                logger.debug("Local API version \(version["protocolVersion"]?.stringValue ?? "unknown")")
            case .cloud(let service, let user, let password):
                if usesOAuth {
                    try await oauthSignIn(user: user, password: password)
                } else if service == .cozytouch {
                    let jwt = try await cozytouchJWT(user: user, password: password)
                    try await sessionLogin(form: [("jwt", jwt)])
                } else {
                    try await sessionLogin(form: [("userId", user), ("userPassword", password)])
                }
            }
            signedIn = true
            // A new session: the event listener of the previous one is gone (11.4).
            sessionGeneration += 1
            lockout.accepted()
            onAccount(nil)
        } catch let error as OverkizError {
            if let status = error.status, (400..<500).contains(status) {
                if let pause = lockout.refused(at: now()) {
                    logger.warning("The server refused to sign in (\(error)): trying again in \(Self.describe(pause)) at the earliest")
                } else {
                    logger.warning("The server refused to sign in (\(error))")
                }
                if error.refusesCredentials(local: endpoint.isLocal) { onAccount(error) }
            }
            throw error
        }
    }

    // MARK: Somfy OAuth (11)

    /// A refresh with the kept refresh token, else (or when it is refused, or after a 401) the password grant.
    private func oauthSignIn(user: String, password: String) async throws {
        cookie = nil
        if !passwordGrantNext, let kept = refreshToken ?? tokenStore?.load() {
            do {
                try await grant(Self.refreshGrant(kept))
                return
            } catch let error as OverkizError where error.isBadCredentials {
                logger.debug("Somfy refused the kept refresh token: signing in with the password")
                forgetRefreshToken()
            }
        }
        passwordGrantNext = false
        try await grant([
            ("grant_type", "password"), ("client_id", SomfyOAuth.clientID), ("client_secret", SomfyOAuth.clientSecret),
            ("username", user), ("password", password),
        ])
    }

    /// Refreshes a token that expires within 5 s, before a request (11.4), once for every request waiting; a refused
    /// refresh signs in with the password.
    private func refreshIfDue() async throws {
        guard usesOAuth, signedIn, let expiresAt, refreshToken != nil, now() >= expiresAt - SomfyOAuth.refreshMargin else { return }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refreshToken else { return }
        do {
            try await grant(Self.refreshGrant(refreshToken))
            sessionGeneration += 1
        } catch let error as OverkizError where error.isBadCredentials {
            forgetRefreshToken()
            signedIn = false
            passwordGrantNext = true
            try await signIn()
        }
    }

    private static func refreshGrant(_ token: String) -> [(String, String)] {
        [("grant_type", "refresh_token"), ("client_id", SomfyOAuth.clientID), ("client_secret", SomfyOAuth.clientSecret), ("refresh_token", token)]
    }

    private func forgetRefreshToken() {
        refreshToken = nil
        tokenStore?.save(nil)
    }

    /// A form `POST` outside the API (a sign-in), answered as it is.
    private func postForm(_ url: String, _ form: [(String, String)], headers: [(name: String, value: String)] = [("Accept", "application/json")]) async throws -> HomeswiftNetwork.HTTPResponse {
        try await http("POST", url, headers: [("Content-Type", "application/x-www-form-urlencoded")] + headers, body: Data(URLEncoding.form(form).utf8))
    }

    /// One request to Somfy's token endpoint; keeps the access token, its expiry, and a new refresh token.
    private func grant(_ form: [(String, String)]) async throws {
        let response = try await postForm(SomfyOAuth.tokenURL, form)
        let body = (try? JSONValue(data: response.body)) ?? .null
        // A refused password or refresh token, whatever the status (Somfy may answer it with 200).
        if body["message"]?.stringValue == "error.invalid.grant" || body["error"]?.stringValue == "invalid_grant" {
            throw OverkizError(status: 400, errorCode: "invalid_grant", message: "error.invalid.grant")
        }
        guard response.isSuccess else {
            if response.status >= 500 { throw OverkizError(message: "Somfy's sign-in is unavailable (HTTP \(response.status))") }
            throw OverkizError(response: response)
        }
        guard let access = body["access_token"]?.stringValue, !access.isEmpty else {
            throw OverkizError(message: "Somfy's sign-in gave no access token")
        }
        accessToken = access
        expiresAt = body["expires_in"]?.number.map { now() + .seconds(min(max(0, $0), 1e9)) }
        if let refresh = body["refresh_token"]?.stringValue, !refresh.isEmpty, refresh != refreshToken {
            refreshToken = refresh
            tokenStore?.save(refresh)
        }
    }

    /// `POST /login` with a form (3.1), keeping the `JSESSIONID` cookie.
    private func sessionLogin(form: [(String, String)]) async throws {
        cookie = nil
        let response = try await postForm(baseURL + "/login", form)
        guard response.isSuccess else { throw OverkizError(response: response) }
        if let body = try? JSONValue(data: response.body), body["success"]?.boolValue == false {
            throw OverkizError(status: 401, errorCode: "AUTHENTICATION_ERROR", message: "Bad credentials")
        }
        cookie = Self.sessionCookie(response.headers)
    }

    /// The `JSESSIONID=<value>` part of the `Set-Cookie` header that sets it.
    static func sessionCookie(_ headers: [(name: String, value: String)]) -> String? {
        for header in headers where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            for part in header.value.split(separator: ",") {
                let pair = part.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if pair.hasPrefix("JSESSIONID=") { return pair }
            }
        }
        return nil
    }

    /// Atlantic's token and JWT (3.2), for Cozytouch's `/login`.
    private func cozytouchJWT(user: String, password: String) async throws -> String {
        let token = try await postForm(
            "https://apis.groupe-atlantic.com/token", [("grant_type", "password"), ("username", "GA-PRIVATEPERSON/\(user)"), ("password", password)],
            headers: [("Authorization", "Basic \(Self.cozytouchBasic)")])
        guard token.isSuccess else { throw OverkizError(response: token) }
        guard let access = (try? JSONValue(data: token.body))?["access_token"]?.stringValue, !access.isEmpty else {
            throw OverkizError(status: 401, errorCode: "invalid_grant", message: "Invalid credentials")
        }
        let jwt = try await http(
            "GET", "https://apis.groupe-atlantic.com/magellan/accounts/jwt", headers: [("Authorization", "Bearer \(access)")], body: nil)
        guard jwt.isSuccess else { throw OverkizError(response: jwt) }
        let text = String(decoding: jwt.body, as: UTF8.self).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\""]))
        guard !text.isEmpty else { throw OverkizError(status: jwt.status, message: "Cozytouch gave no JWT") }
        return text
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds > 3600 { return "\(Int((Double(seconds) / 3600).rounded())) h" }
        if seconds > 60 { return "\(Int((Double(seconds) / 60).rounded())) min" }
        return "\(seconds) s"
    }

    // MARK: Endpoints (4.1)

    func devices() async throws -> [OverkizDevice] { OverkizDevice.list(try await request("GET", "/setup/devices")) }

    func scenarios() async throws -> [OverkizScenario] { OverkizScenario.list(try await request("GET", "/actionGroups")) }

    /// The setup's country, which picks the execution labels' language; nil on the local API.
    func countryCode() async throws -> String? {
        guard !endpoint.isLocal else { return nil }
        return try await request("GET", "/setup/location")["countryCode"]?.stringValue?.lowercased()
    }

    func gateways() async throws -> [String] {
        let list = try await request("GET", "/setup/gateways").arrayValue ?? []
        return list.compactMap { $0["gatewayId"]?.stringValue }.filter(TahomaPlugin.isPIN)
    }

    func registerListener() async throws -> String {
        guard let id = try await request("POST", "/events/register")["id"]?.stringValue, !id.isEmpty else {
            throw OverkizError(message: "the server gave no event listener")
        }
        return id
    }

    /// The events since the last fetch; a 401 is not retried (6.2): the listener is registered again after signing in.
    func fetchEvents(listener: String) async throws -> [OverkizEvent] {
        OverkizEvent.list(try await request("POST", "/events/\(Self.component(listener))/fetch", reconnect: false))
    }

    /// Posts an execution (4.4): `apply/highPriority` when asked, never on the local API, which refuses modes.
    func apply(label: String, actions: [JSONValue], highPriority: Bool) async throws -> String {
        let path = highPriority && !endpoint.isLocal ? "/exec/apply/highPriority" : "/exec/apply"
        return try await postExecution(path, ["label": .string(label), "actions": .array(actions), "metadata": nil])
    }

    func runScenario(oid: String) async throws -> String {
        try await postExecution("/exec/\(Self.component(oid))", ["label": "", "actions": [], "metadata": nil])
    }

    private func postExecution(_ path: String, _ body: JSONValue) async throws -> String {
        guard let id = try await request("POST", path, json: body)["execId"]?.stringValue else {
            throw OverkizError(message: "the server gave no execution id")
        }
        return id
    }

    func cancel(execID: String) async throws {
        try await request("DELETE", "/exec/current/setup/\(Self.component(execID))")
    }

    func refreshAllStates() async throws {
        try await request("POST", "/setup/devices/states/refresh", json: [])
    }

    func refreshStates(deviceURL: String) async throws {
        try await request("POST", "/setup/devices/\(Self.component(deviceURL))/states/refresh")
    }

    /// Mints a Developer Mode token for a gateway and activates it (3.5, 11.7); answers the token and, when the
    /// gateway's list shows it, its uuid, by which `revokeLocalToken` takes it back. Developer Mode is switched on
    /// first when the gateway says it is off; a gateway that does not answer that check is tried anyway.
    func mintLocalToken(pin: String, label: String) async throws -> (token: String, uuid: String?) {
        let before = Set(await localTokens(pin: pin).compactMap { $0["uuid"]?.stringValue })
        let mode = "/setup/gateways/\(Self.component(pin))/developerMode"
        if let active = (try? await request("GET", mode))?["active"]?.boolValue, !active {
            try await request("POST", mode)
            logger.info("Turned on the gateway's Developer Mode")
        }
        guard let token = try await request("GET", "/config/\(Self.component(pin))/local/tokens/generate")["token"]?.stringValue, !token.isEmpty else {
            throw OverkizError(message: "the server gave no token")
        }
        try await request(
            "POST", "/config/\(Self.component(pin))/local/tokens",
            json: ["label": .string(label), "token": .string(token), "scope": "devmode"])
        let added = await localTokens(pin: pin).filter { $0["label"]?.stringValue == label }.compactMap { $0["uuid"]?.stringValue }
            .filter { !$0.isEmpty && !before.contains($0) }
        return (token, added.count == 1 ? added[0] : nil)
    }

    /// The gateway's Developer Mode tokens, empty when the server does not list them.
    private func localTokens(pin: String) async -> [JSONValue] {
        (try? await request("GET", "/config/\(Self.component(pin))/local/tokens/devmode"))?.arrayValue ?? []
    }

    /// Revokes a token the plugin minted, as far as the server lets it (a failure only leaves the token there).
    func revokeLocalToken(pin: String, uuid: String) async {
        do {
            try await request("DELETE", "/config/\(Self.component(pin))/local/tokens/\(Self.component(uuid))")
            logger.debug("Revoked the gateway's previous Developer Mode token")
        } catch {
            logger.debug("Could not revoke the gateway's previous Developer Mode token: \(error)")
        }
    }

    /// A path component, everything but unreserved characters percent-encoded (`io%3A%2F%2F1234…`).
    static func component(_ text: String) -> String { URLEncoding.uriComponent(text) }
}

extension String {
    fileprivate var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
