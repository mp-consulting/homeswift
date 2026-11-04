import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging

/// An error from Overkiz, flattened as the Homebridge plugin's client does (3.6): `Error <status> <error>(<errorCode>)`.
struct OverkizError: Error, CustomStringConvertible, Equatable {
    var status: Int?
    var errorCode: String?
    var message: String

    init(status: Int? = nil, errorCode: String? = nil, message: String) {
        self.status = status
        self.errorCode = errorCode
        self.message = message
    }

    var description: String {
        guard let status else { return message }
        return "Error \(status) \(message)" + (errorCode.map { "(\($0))" } ?? "")
    }

    /// The account refused what it was given (4.5): a password, a token, a user that does not exist.
    var isBadCredentials: Bool {
        let text = message.lowercased()
        return text.contains("bad credentials") || text.contains("no such user") || text.contains("invalid credentials")
            || text.contains("invalid_grant") || (status == 401 && errorCode == nil && text.contains("not authenticated"))
    }

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

/// How the client reaches the setup: a cloud with its sign-in, or a gateway's local API with a token.
enum OverkizEndpoint: Sendable, Equatable {
    case cloud(OverkizService, user: String, password: String)
    /// A gateway's local API at `host` (an address or `gateway-<PIN>.local`), `pin` when known.
    case local(host: String, pin: String?, token: String)

    var isLocal: Bool { if case .local = self { true } else { false } }
}

/// Talks to Overkiz (sections 3 and 4): signs in lazily before the first request, signs in again once on a 401, and keeps
/// itself from signing in again for a while after the server refused it (the lockout of 3.1, which avoids Overkiz's ban
/// for repeated bad logins: 60 s, then four times longer each time, at most `maximumLockout`).
actor OverkizClient {
    /// What answers HTTP: one client for the clouds, one for the gateway (its certificate checked against the Overkiz
    /// Root CA); tests give a fake.
    struct Transport: Sendable {
        var http: any HTTPSending
        var timeout: Duration = .seconds(15)
    }

    static let maximumLockout: Duration = .seconds(4 * 3600)
    static let cozytouchBasic = "Q3RfMUpWeVRtSUxYOEllZkE3YVVOQmpGblpVYToyRWNORHpfZHkzNDJVSnFvMlo3cFNKTnZVdjBh"

    let endpoint: OverkizEndpoint
    private let transport: Transport
    private let proxy: URL?
    private let logger: Logger
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cookie: String?
    private var signedIn = false
    private var lockedUntil: ContinuousClock.Instant?
    private var lockout: Duration = .seconds(60)
    /// Called with the error when the account refuses the credentials, and with nil once it accepts them.
    private let onAccount: @Sendable (OverkizError?) -> Void

    init(
        endpoint: OverkizEndpoint, transport: Transport, proxy: String? = nil, logger: Logger,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, onAccount: @escaping @Sendable (OverkizError?) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.proxy = proxy.flatMap(URL.init(string:))
        self.logger = logger
        self.now = now
        self.onAccount = onAccount
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
        do {
            return try await send(method, path, json: json)
        } catch let error as OverkizError where error.status == 401 {
            if signedIn { logger.debug("Session expired: \(error)") }
            signedIn = false
            cookie = nil
            guard reconnect else { throw error }
            try await signIn()
            return try await send(method, path, json: json)
        }
    }

    private func send(_ method: String, _ path: String, json: JSONValue?) async throws -> JSONValue {
        var headers: [(name: String, value: String)] = [("Accept", "application/json")]
        switch endpoint {
        case .local(_, _, let token): headers.append(("Authorization", "Bearer \(token)"))
        case .cloud: if let cookie { headers.append(("Cookie", cookie)) }
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
        } catch {
            throw OverkizError(message: "\(error)")
        }
    }

    /// A URL as the log shows it: the gateway's PIN masked.
    static func redacted(_ url: String) -> String {
        url.replacingOccurrences(of: #"\d{4}-\d{4}-\d{4}"#, with: "****-****-****", options: .regularExpression)
    }

    // MARK: Signing in

    /// Signs in unless signed in already (3.1–3.4). Throws at once while locked out.
    func signIn() async throws {
        guard !signedIn else { return }
        if let lockedUntil {
            let remaining = lockedUntil - now()
            if remaining > .zero {
                throw OverkizError(message: "Sign-in is paused for \(Self.describe(remaining)) after the server refused it: check the credentials, or wait to be unbanned")
            }
            self.lockedUntil = nil
        }
        do {
            switch endpoint {
            case .local:
                // The token is the sign-in: the API's version checks it (3.4).
                let version = try await send("GET", "/apiVersion", json: nil)
                logger.debug("Local API version \(version["protocolVersion"]?.stringValue ?? "unknown")")
            case .cloud(let service, let user, let password):
                if service == .cozytouch {
                    let jwt = try await cozytouchJWT(user: user, password: password)
                    try await sessionLogin(form: [("jwt", jwt)])
                } else {
                    try await sessionLogin(form: [("userId", user), ("userPassword", password)])
                }
            }
            signedIn = true
            lockout = .seconds(60)
            onAccount(nil)
        } catch let error as OverkizError {
            if let status = error.status, (400..<500).contains(status) {
                lockedUntil = now() + lockout
                logger.warning("The server refused to sign in (\(error)): trying again in \(Self.describe(lockout)) at the earliest")
                lockout = min(lockout * 4, Self.maximumLockout)
                if error.isBadCredentials || (endpoint.isLocal && status == 401) { onAccount(error) }
            }
            throw error
        }
    }

    /// `POST /login` with a form (3.1), keeping the `JSESSIONID` cookie.
    private func sessionLogin(form: [(String, String)]) async throws {
        cookie = nil
        let response = try await http(
            "POST", baseURL + "/login", headers: [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json")],
            body: Data(URLEncoding.form(form).utf8))
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
        let token = try await http(
            "POST", "https://apis.groupe-atlantic.com/token",
            headers: [("Authorization", "Basic \(Self.cozytouchBasic)"), ("Content-Type", "application/x-www-form-urlencoded")],
            body: Data(URLEncoding.form([("grant_type", "password"), ("username", "GA-PRIVATEPERSON/\(user)"), ("password", password)]).utf8))
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
        let body: JSONValue = ["label": .string(label), "actions": .array(actions), "metadata": nil]
        guard let id = try await request("POST", path, json: body)["execId"]?.stringValue else {
            throw OverkizError(message: "the server gave no execution id")
        }
        return id
    }

    func runScenario(oid: String) async throws -> String {
        let body: JSONValue = ["label": "", "actions": [], "metadata": nil]
        guard let id = try await request("POST", "/exec/\(Self.component(oid))", json: body)["execId"]?.stringValue else {
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

    /// Mints a Developer Mode token for a gateway and activates it (3.5); answers the token.
    func mintLocalToken(pin: String, label: String) async throws -> String {
        guard let token = try await request("GET", "/config/\(Self.component(pin))/local/tokens/generate")["token"]?.stringValue, !token.isEmpty else {
            throw OverkizError(message: "the server gave no token")
        }
        try await request(
            "POST", "/config/\(Self.component(pin))/local/tokens",
            json: ["label": .string(label), "token": .string(token), "scope": "devmode", "gatewayId": .string(pin)])
        return token
    }

    /// A path component, everything but unreserved characters percent-encoded (`io%3A%2F%2F1234…`).
    static func component(_ text: String) -> String { URLEncoding.uriComponent(text) }
}

extension String {
    fileprivate var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
