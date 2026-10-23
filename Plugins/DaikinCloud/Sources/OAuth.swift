import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The Developer Portal login: OAuth 2.0 authorization code with the app's Client ID and Secret, its
/// redirect caught by the callback server (`CallbackServer`) or pasted on the settings page.
enum DeveloperPortalOAuth {
    static let authorizationEndpoint = URL(string: "https://idp.onecta.daikineurope.com/v1/oidc/authorize")!
    static let tokenEndpoint = URL(string: "https://idp.onecta.daikineurope.com/v1/oidc/token")!
    static let revokeEndpoint = URL(string: "https://idp.onecta.daikineurope.com/v1/oidc/revoke")!
    static let scope = "openid onecta:basic.integration"

    /// The redirect URI registered in the portal: `https://<address>:<port>`.
    static func redirectURI(address: String, port: Int) -> String { "https://\(address):\(port)" }

    static func authorizationURL(clientID: String, redirectURI: String, state: String) -> String {
        authorizationEndpoint.absoluteString + "?" + URLEncoding.form([
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI), ("scope", scope), ("state", state),
        ])
    }

    /// 32 random bytes in hex, for `state`.
    static func makeState() -> String {
        Secrets.hex(Secrets.randomBytes(32))
    }

    static func exchangeCode(_ code: String, clientID: String, clientSecret: String, redirectURI: String, http: DaikinHTTP) async throws -> TokenSet {
        try await requestToken([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI), ("client_id", clientID), ("client_secret", clientSecret),
        ], context: "Authorization code exchange failed", http: http).withExpiresAt()
    }

    static func refresh(_ refreshToken: String, clientID: String, clientSecret: String, http: DaikinHTTP) async throws -> TokenSet {
        try await requestToken([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID), ("client_secret", clientSecret),
        ], context: "Token refresh failed", http: http)
    }

    static func revoke(_ refreshToken: String, clientID: String, clientSecret: String, http: DaikinHTTP) async throws {
        let response = try await http.postForm(revokeEndpoint, [
            ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID), ("client_secret", clientSecret),
        ])
        guard response.isSuccess else { throw DaikinError("Token revocation failed: HTTP \(response.status)") }
    }

    private static func requestToken(_ fields: [(String, String)], context: String, http: DaikinHTTP) async throws -> TokenSet {
        let response = try await http.postForm(tokenEndpoint, fields)
        return try TokenResponse.parse(response, url: tokenEndpoint, context: context)
    }

    /// The token client of a configured Developer Portal app.
    static func client(file: URL, clientID: String, clientSecret: String, http: DaikinHTTP, onError: @escaping @Sendable (String) -> Void) -> TokenClient {
        TokenClient(file: file, onError: onError) { refreshToken in
            try await refresh(refreshToken, clientID: clientID, clientSecret: clientSecret, http: http)
        }
    }
}

/// The Onecta app's own login: Gigya (SAP Customer Data Cloud) with the account's email and password, then
/// OIDC with PKCE. 3000 API calls a day instead of 200, and the WebSocket.
///
/// The client's credentials are the app's; like the Homebridge plugin, the environment can override them.
struct MobileOAuth: Sendable {
    struct Settings: Sendable {
        var apiKey: String
        var clientID: String
        var clientSecret: String
        var redirectURI: String
        var gigyaBaseURL: String
        var tokenEndpoint: URL
        var scope: String

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
            Settings(
                apiKey: environment["DAIKIN_API_KEY"] ?? "3_xRB3jaQ62bVjqXU1omaEsPDVYC0Twi1zfq1zHPu_5HFT0zWkDvZJS97Yw1loJnTm",
                clientID: environment["DAIKIN_CLIENT_ID"] ?? "FjS6T5oZHvzpZENIDybFRdtK",
                clientSecret: environment["DAIKIN_CLIENT_SECRET"] ?? "_yWGLBGUnQFrN-u7uIOAZhSBsJOfcnBs0IS87wTgUvUmnLnEOs4NQmaKagqZBpQpG0XYl07KeCx8XHHKxAn24w",
                redirectURI: environment["DAIKIN_REDIRECT_URI"] ?? "daikinunified://cdc/",
                gigyaBaseURL: environment["DAIKIN_GIGYA_BASE_URL"] ?? "https://cdc.daikin.eu",
                tokenEndpoint: environment["DAIKIN_IDP_TOKEN_ENDPOINT"].flatMap(URL.init(string:)) ?? DeveloperPortalOAuth.tokenEndpoint,
                scope: environment["DAIKIN_SCOPE"] ?? "openid onecta:onecta.application offline_access")
        }
    }

    static let maxAttempts = 3
    static let retryBaseDelay: Duration = .seconds(1)
    static let retryMaxDelay: Duration = .seconds(10)

    var email: String
    var password: String
    var http: DaikinHTTP
    var settings = Settings.fromEnvironment()
    /// Progress worth telling the user (a pending registration completed, a retry).
    var log: @Sendable (String) -> Void = { _ in }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Logs in from scratch and answers the token set (not stored: the caller keeps it).
    func authenticate() async throws -> TokenSet {
        let verifier = Secrets.base64URL(Secrets.randomBytes(32))
        let challenge = Secrets.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let context = try await oidcContext(challenge: challenge)
        let cookies = try await bootstrapGigya(context: context)
        let loginToken = try await login(cookies: cookies)
        let code = try await authorize(context: context, loginToken: loginToken, cookies: cookies)
        return try await exchange(code: code, verifier: verifier)
    }

    func refresh(_ refreshToken: String) async throws -> TokenSet {
        try await idpToken([("grant_type", "refresh_token"), ("refresh_token", refreshToken)], context: "Token refresh failed")
    }

    // MARK: The steps

    private var oidcBase: String { "\(settings.gigyaBaseURL)/oidc/op/v1.0/\(settings.apiKey)" }

    /// Step 1: the OIDC authorize request redirects to the login page with a `context`.
    private func oidcContext(challenge: String) async throws -> String {
        let state = Secrets.hex(Secrets.randomBytes(16))
        let query = URLEncoding.form([
            ("client_id", settings.clientID), ("redirect_uri", settings.redirectURI), ("response_type", "code"), ("scope", settings.scope),
            ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
        ])
        let response = try await request("GET", "\(oidcBase)/authorize?\(query)")
        if response.status == 302, let location = response.header("Location"), let context = URLQuery.match("context", in: location) {
            return context.removingPercentEncoding ?? context
        }
        throw DaikinError("Failed to get OIDC context")
    }

    /// Step 2: the Gigya SDK bootstrap hands out the cookies the login needs.
    private func bootstrapGigya(context: String) async throws -> String {
        let proxyURL = "https://id.daikin.eu/cdc/onecta/oidc/proxy.html?context=\(URLEncoding.uriComponent(context))&client_id=\(settings.clientID)"
            + "&mode=login&scope=\(URLEncoding.uriComponent(settings.scope))&gig_skipConsent=true"
        let query = URLEncoding.form([("apiKey", settings.apiKey), ("pageURL", proxyURL), ("sdk", "js_latest"), ("sdkBuild", "18305"), ("format", "json")])
        let response = try await request("GET", "\(settings.gigyaBaseURL)/accounts.webSdkBootstrap?\(query)", headers: [
            ("Accept", "*/*"), ("Origin", "https://id.daikin.eu"), ("Referer", "https://id.daikin.eu/"),
        ])
        var cookies: [String] = []
        for header in response.values(of: "Set-Cookie") {
            let pair = header.prefix { $0 != ";" }
            if let equals = pair.firstIndex(of: "="), equals != pair.startIndex, pair.index(after: equals) != pair.endIndex { cookies.append(String(pair)) }
        }
        cookies.append("gig_bootstrap_\(settings.apiKey)=cdc_ver4")
        return cookies.joined(separator: "; ")
    }

    private var sdkFields: [(String, String)] {
        [
            ("targetEnv", "jssdk"), ("include", "profile,data,emails,subscriptions,preferences,"), ("APIKey", settings.apiKey), ("source", "showScreenSet"),
            ("sdk", "js_latest"), ("authMode", "cookie"),
            ("pageURL", "https://id.daikin.eu/cdc/onecta/oidc/registration-login.html?gig_client_id=\(settings.clientID)"),
            ("sdkBuild", "18305"), ("format", "json"),
        ]
    }

    private func postHeaders(cookies: String) -> [(name: String, value: String)] {
        [("Content-Type", "application/x-www-form-urlencoded"), ("Origin", "https://id.daikin.eu"), ("Referer", "https://id.daikin.eu/"), ("Cookie", cookies)]
    }

    /// The browser fingerprint Gigya's risk engine expects with a login.
    private func riskContext() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date())
        let time = "\(parts.hour ?? 0):\(String(format: "%02d", parts.minute ?? 0)):\(String(format: "%02d", parts.second ?? 0))"
        return #"{"b0":14063,"b1":[0,2,2,0],"b2":4,"b3":[],"b4":2,"b5":1,"b6":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)","b7":[],"b8":""#
            + time + #"","b9":0,"b10":{"state":"denied"},"b11":false,"b12":null,"b13":[5,"402|874|24",false,true]}"#
    }

    /// Step 3: the email and password, for a login token. An account with a pending registration (206001)
    /// is completed on the way, as the Onecta app does.
    private func login(cookies: String) async throws -> String {
        let fields = sdkFields + [
            ("loginID", email), ("password", password), ("sessionExpiration", "31536000"), ("includeUserInfo", "true"), ("loginMode", "standard"),
            ("lang", "en"), ("riskContext", riskContext()),
        ]
        let url = "\(settings.gigyaBaseURL)/accounts.login"
        let response = try await request("POST", url, headers: postHeaders(cookies: cookies), body: URLEncoding.form(fields))
        let result = try gigyaResult(response, url: url, context: "Login failed")
        if result.errorCode == 206001 {
            log("Account has pending registration (206001). Attempting to complete registration automatically...")
            if let token = result.loginToken { return token }
            if let regToken = result.regToken {
                return try await completeRegistration(regToken: regToken, result: result, cookies: cookies)
            }
        }
        return try result.requireLoginToken(context: "Login failed")
    }

    private func completeRegistration(regToken: String, result: GigyaResult, cookies: String) async throws -> String {
        let custom = result.json["data"]?["profile"]
        let country = custom?["countryResidence"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "US"
        let language = custom?["communicationLanguage"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        var firstName = result.json["profile"]?["firstName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        var lastName = result.json["profile"]?["lastName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if firstName == nil || lastName == nil {
            let user = email.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = user.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map(String.init)
            let capitalized = { (part: String) in part.prefix(1).uppercased() + part.dropFirst() }
            firstName = firstName ?? (parts.first.map(capitalized) ?? "User")
            lastName = lastName ?? (parts.count > 1 ? capitalized(parts[parts.count - 1]) : "Account")
            log("Using derived name for registration: \(firstName!) \(lastName!). You can update your name in the Daikin Onecta app.")
        }
        log("Completing pending registration with countryResidence=\(country), communicationLanguage=\(language)")
        log("Note: Privacy notice consent (privacy.PrivacyNotice.onecta) will be accepted automatically.")
        let profile = JSONValue.object(["firstName": .string(firstName ?? "User"), "lastName": .string(lastName ?? "Account")]).text()
        let data = JSONValue.object(["profile": .object(["countryResidence": .string(country), "communicationLanguage": .string(language)])]).text()
        let preferences = #"{"privacy.PrivacyNotice.onecta":{"isConsentGranted":true}}"#
        let fields = sdkFields + [
            ("regToken", regToken), ("email", email), ("password", password), ("profile", profile), ("data", data), ("preferences", preferences),
            ("finalizeRegistration", "true"),
        ]
        let url = "\(settings.gigyaBaseURL)/accounts.register"
        let response = try await request("POST", url, headers: postHeaders(cookies: cookies), body: URLEncoding.form(fields))
        let token = try gigyaResult(response, url: url, context: "Registration completion failed").requireLoginToken(context: "Registration completion failed")
        log("Pending registration completed successfully.")
        return token
    }

    /// Step 4: the login token, for an authorization code (in the redirect to the app's scheme).
    private func authorize(context: String, loginToken: String, cookies: String) async throws -> String {
        let query = URLEncoding.form([("context", context), ("login_token", loginToken)])
        let response = try await request("GET", "\(oidcBase)/authorize/continue?\(query)", headers: [
            ("Cookie", "\(cookies); glt_\(settings.apiKey)=\(loginToken)"), ("Referer", "https://id.daikin.eu/"),
        ])
        if response.status == 302, let location = response.header("Location") {
            if let code = URLQuery.match("code", in: location) { return code }
            if let error = URLQuery.match("error", in: location) {
                let description = URLQuery.match("error_description", in: location) ?? error
                throw DaikinError("Authorization error: \(description.removingPercentEncoding ?? description)")
            }
        }
        throw DaikinError("Failed to get authorization code")
    }

    /// Step 5: the code and the PKCE verifier, for tokens.
    private func exchange(code: String, verifier: String) async throws -> TokenSet {
        try await idpToken([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", settings.redirectURI), ("code_verifier", verifier),
        ], context: "Token exchange failed")
    }

    /// A grant at the token endpoint, the client authenticating with HTTP Basic.
    private func idpToken(_ fields: [(String, String)], context: String) async throws -> TokenSet {
        let basic = Data("\(settings.clientID):\(settings.clientSecret)".utf8).base64EncodedString()
        let response = try await request("POST", settings.tokenEndpoint.absoluteString, headers: [
            ("Content-Type", "application/x-www-form-urlencoded"), ("Authorization", "Basic \(basic)"),
        ], body: URLEncoding.form(fields))
        return try TokenResponse.parse(response, url: settings.tokenEndpoint, context: context)
    }

    // MARK: Gigya answers

    struct GigyaResult {
        var json: JSONValue
        var errorCode: Int
        var regToken: String? { json["regToken"]?.stringValue }
        var loginToken: String? { json["sessionInfo"]?["login_token"]?.stringValue }

        func requireLoginToken(context: String) throws -> String {
            if errorCode != 0 {
                let detail = json["errorMessage"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? json["errorDetails"]?.stringValue ?? "undefined"
                throw DaikinError("\(context) (\(errorCode)): \(detail)")
            }
            guard let loginToken else { throw DaikinError("No login_token in \(context) response") }
            return loginToken
        }
    }

    /// Gigya answers 200 for most failures and reports them in `errorCode`; anything else is a readable error.
    private func gigyaResult(_ response: HTTPResponse, url: String, context: String) throws -> GigyaResult {
        let target = URL(string: url) ?? settings.tokenEndpoint
        let json = try TokenResponse.json(response, url: target, context: context)
        guard let code = json["errorCode"]?.doubleValue, json.objectValue != nil else {
            throw DaikinError("\(context): \(target.host ?? "") returned an unexpected response (HTTP \(response.status))")
        }
        return GigyaResult(json: json, errorCode: Self.errorCode(code))
    }

    /// Gigya's code as an integer that never traps; anything but an exact 0 stays a failure (`errorCode !== 0`).
    static func errorCode(_ code: Double) -> Int {
        if code == 0 { return 0 }
        guard let integer = Int(saturating: code), integer != 0 else { return -1 }
        return integer
    }

    // MARK: Requests, with retries for transient network failures

    private func request(_ method: String, _ url: String, headers: [(name: String, value: String)] = [], body: String? = nil) async throws -> HTTPResponse {
        guard let target = URL(string: url) else { throw DaikinError("Invalid URL \(url)") }
        let host = target.host ?? url
        var attempt = 1
        while true {
            do {
                return try await http.send(method, target, headers: headers, body: body.map { Data($0.utf8) })
            } catch let error as DaikinNetworkError {
                guard attempt < Self.maxAttempts, error.isRetryable else { throw Self.describe(error, host: host) }
                let delay = min(Self.retryBaseDelay * (1 << (attempt - 1)), Self.retryMaxDelay)
                log("Request to \(host) failed (\(error.code)); retrying in \(Int(delay / .milliseconds(1)))ms (attempt \(attempt + 1)/\(Self.maxAttempts))")
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    /// A socket error a user can act on: which host could not be reached, and where to look.
    static func describe(_ error: DaikinNetworkError, host: String) -> DaikinError {
        let reason = "\(error.message) (\(error.code))"
        guard error.isRetryable else { return DaikinError("Request to \(host) failed: \(reason)") }
        return DaikinError(
            "Request to \(host) failed after \(maxAttempts) attempts: \(reason). The Homeswift host could not get a response from https://\(host). "
                + "Verify it is reachable from this host (curl -v), and check for firewall/DNS filtering, broken IPv6 connectivity or a low-MTU link "
                + "— the Daikin endpoints themselves are usually fine.")
    }

    /// The token client of a Mobile App login.
    static func client(file: URL, http: DaikinHTTP, log: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (String) -> Void) -> TokenClient {
        let refresher = MobileOAuth(email: "", password: "", http: http, log: log)
        return TokenClient(file: file, onError: onError) { refreshToken in try await refresher.refresh(refreshToken) }
    }
}
