import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// SmartThings' OAuth 2.0 authorization code flow on the person's own API Access App (docs/clean-room/SmartThings.md,
/// sections 3.3 to 3.6): the authorize page, then the token endpoint with the client in a Basic header.
struct SmartThingsOAuth: Sendable {
    /// The scopes asked for; `sse` too when the person says their app has it.
    static let scopes = ["r:devices:*", "x:devices:*", "r:locations:*", "r:scenes:*", "x:scenes:*"]

    var base: URL
    var clientID: String
    var clientSecret: String
    var http: any HTTPSending

    static func scope(withSSE: Bool) -> String { (scopes + (withSSE ? ["sse"] : [])).joined(separator: " ") }

    static func redirectURI(address: String, port: Int) -> String {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return "https://\(host):\(port)/oauth/callback"
    }

    /// 32 random bytes in hex.
    static func makeState() -> String { Secrets.hex(Secrets.randomBytes(32)) }

    func authorizeURL(redirectURI: String, state: String, withSSE: Bool) -> String {
        base.appendingPathComponent("oauth/authorize").absoluteString + "?" + URLEncoding.query([
            ("client_id", clientID), ("response_type", "code"), ("redirect_uri", redirectURI), ("scope", Self.scope(withSSE: withSSE)), ("state", state),
        ])
    }

    func exchange(code: String, redirectURI: String) async throws -> TokenResponse {
        try await token([("grant_type", "authorization_code"), ("code", code), ("client_id", clientID), ("redirect_uri", redirectURI)])
    }

    func refresh(_ refreshToken: String) async throws -> TokenResponse {
        try await token([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)])
    }

    private func token(_ fields: [(String, String)]) async throws -> TokenResponse {
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        let request = HTTPRequest(
            method: "POST", url: base.appendingPathComponent("oauth/token"),
            headers: [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json"), ("Authorization", "Basic \(basic)"),
                      ("User-Agent", SmartThingsAPI.userAgent)],
            body: Data(URLEncoding.form(fields).utf8), timeout: .seconds(15))
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw TokenFailure.transient("SmartThings' token endpoint did not answer: \(error)")
        }
        let json = try? JSONValue(data: response.body)
        if !response.isSuccess {
            let code = json?["error"]?.stringValue
            let description = json?["error_description"]?.stringValue
            // 408, 429 and 5xx are worth another try later; any other 4xx means the sign-in is dead (section 3.6).
            if response.status == 408 || response.status == 429 || response.status >= 500 {
                throw TokenFailure.transient("SmartThings' token endpoint answered HTTP \(response.status)")
            }
            throw TokenFailure.refused(code: code ?? "HTTP \(response.status)", description: description, status: response.status)
        }
        guard let json, let tokens = TokenResponse(json) else { throw TokenFailure.transient("SmartThings' token endpoint answered without tokens") }
        return tokens
    }
}

/// What the token endpoint answers (section 3.5).
struct TokenResponse: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double
    var scope: String?
    var installedAppID: String?

    init?(_ json: JSONValue) {
        guard let access = json["access_token"]?.stringValue, !access.isEmpty else { return nil }
        accessToken = access
        refreshToken = json["refresh_token"]?.stringValue
        expiresIn = json["expires_in"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil } ?? 86400
        scope = json["scope"]?.stringValue
        installedAppID = json["installed_app_id"]?.stringValue
    }
}

/// A failed token request: refused (the chain is dead, sign in again) or transient (try again later).
enum TokenFailure: Error, CustomStringConvertible, Equatable {
    case refused(code: String, description: String?, status: Int)
    case transient(String)

    var description: String {
        switch self {
        case .refused(let code, let description, let status): "SmartThings refused the sign-in: \(code)\(description.map { " (\($0))" } ?? "") (HTTP \(status))"
        case .transient(let message): message
        }
    }
}

/// The token file, in aziz66's shape (`smartthings_tokens.json`, section 3.7), sealed in the vault. `scope` and
/// `personal_access_token` are Homeswift's.
struct StoredTokens: Codable, Sendable, Equatable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double?
    /// Epoch milliseconds.
    var expires_at: Double?
    // Not read by Homeswift: kept so the file keeps aziz66's shape (section 3.7).
    var refresh_token_expires_at: Double?
    var installed_app_id: String?
    var location_id: String?
    var seeded_from_config_refresh_token_sha256: String?
    var scope: String?
    /// ik's `AccessToken`: a Personal Access Token, used until it fails, never refreshed (section 3.10).
    var personal_access_token: Bool?

    static let refreshTokenLifetime: TimeInterval = 30 * 24 * 3600

    init(_ response: TokenResponse, now: Date, locationID: String?, previous: StoredTokens? = nil) {
        access_token = response.accessToken
        refresh_token = response.refreshToken ?? previous?.refresh_token
        expires_in = response.expiresIn
        expires_at = (now.timeIntervalSince1970 + response.expiresIn) * 1000
        refresh_token_expires_at = (now.timeIntervalSince1970 + Self.refreshTokenLifetime) * 1000
        installed_app_id = response.installedAppID ?? previous?.installed_app_id
        location_id = locationID ?? previous?.location_id
        scope = response.scope ?? previous?.scope
        seeded_from_config_refresh_token_sha256 = previous?.seeded_from_config_refresh_token_sha256
    }

    init(accessToken: String, refreshToken: String?, expiresIn: Double, now: Date, personal: Bool = false) {
        access_token = accessToken
        refresh_token = refreshToken
        expires_in = expiresIn
        expires_at = (now.timeIntervalSince1970 + expiresIn) * 1000
        refresh_token_expires_at = refreshToken == nil ? nil : (now.timeIntervalSince1970 + Self.refreshTokenLifetime) * 1000
        personal_access_token = personal ? true : nil
    }

    var expiresAt: Date? { expires_at.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var isPersonal: Bool { personal_access_token == true }
    var grantsSSE: Bool { !isPersonal && (scope?.split(separator: " ").contains("sse") ?? false) }

    /// When 75 % of the access token's life has gone (section 3.6).
    var refreshDue: Date? {
        guard let expiresAt else { return nil }
        let lifetime = expires_in ?? 86400
        return expiresAt.addingTimeInterval(-lifetime * 0.25)
    }

    static func sha256(_ text: String) -> String { Secrets.hex(SHA256.hash(data: Data(text.utf8))) }
}

/// The plugin's tokens: one refresh at a time, every new pair saved to the vault before it is used (section 3.6).
actor TokenStore {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case notSignedIn
        case refused(String)
        case transient(String)

        var description: String {
            switch self {
            case .notSignedIn: "Not signed in to SmartThings: sign in on Add accessories"
            case .refused(let reason): reason
            case .transient(let reason): reason
            }
        }
    }

    typealias Refresh = @Sendable (_ refreshToken: String) async throws -> TokenResponse

    private let file: SecretFile<StoredTokens>
    private let refreshRequest: Refresh?
    private let now: @Sendable () -> Date
    private let logger: Logger
    private let onRefused: @Sendable (String) -> Void
    private(set) var tokens: StoredTokens?
    /// A pair the vault did not take: written again before each use, and no refresh until it is (section 3.6).
    private var unsaved = false
    private var refreshing: Task<StoredTokens, any Error>?
    private(set) var refusal: String?
    /// The margin before expiry at which a token counts as expired.
    static let expiryMargin: TimeInterval = 300

    init(file: SecretFile<StoredTokens>, refresh: Refresh?, now: @escaping @Sendable () -> Date, logger: Logger, onRefused: @escaping @Sendable (String) -> Void) {
        self.file = file
        refreshRequest = refresh
        self.now = now
        self.logger = logger
        self.onRefused = onRefused
        tokens = file.load()
    }

    var isSignedIn: Bool { tokens != nil && refusal == nil }
    var grantsSSE: Bool { tokens?.grantsSSE ?? false }
    var isPersonal: Bool { tokens?.isPersonal ?? false }
    var refreshDue: Date? { tokens.flatMap { $0.isPersonal ? nil : $0.refreshDue } }

    /// Takes a starting pair (an import, a sign-in), saved before anything uses it.
    func seed(_ new: StoredTokens) throws {
        try file.save(new)
        tokens = new
        unsaved = false
        refusal = nil
    }

    /// The vault's tokens again, after Setup signed in on another instance.
    func reload() {
        guard let stored = file.load() else { return }
        tokens = stored
        unsaved = false
        refusal = nil
    }

    /// A valid access token: the saved one while it has 5 minutes left, else a refreshed one.
    func accessToken() async throws -> String {
        if let refusal { throw Failure.refused(refusal) }
        guard let current = tokens else { throw Failure.notSignedIn }
        retrySaveIfNeeded()
        if current.isPersonal { return current.access_token }
        if let expiresAt = current.expiresAt, expiresAt.timeIntervalSince(now()) > Self.expiryMargin { return current.access_token }
        return try await refresh(replacing: current.access_token).access_token
    }

    /// A refresh, shared by every caller waiting on one. `replacing` is the access token a call was refused with: when it
    /// has been replaced already, the new one is answered without a request.
    @discardableResult
    func refresh(replacing failedToken: String? = nil) async throws -> StoredTokens {
        if let refusal { throw Failure.refused(refusal) }
        guard let current = tokens else { throw Failure.notSignedIn }
        if let failedToken, current.access_token != failedToken { return current }
        if let refreshing { return try await refreshing.value }
        if current.isPersonal {
            refused("SmartThings refused the personal access token (AccessToken): sign in with your own SmartThings app on Add accessories")
            throw Failure.refused(refusal ?? "")
        }
        retrySaveIfNeeded()
        // An unsaved pair is never refreshed: the vault would be left with a dead refresh token.
        guard !unsaved else { throw Failure.transient("The SmartThings tokens could not be saved to the vault; not refreshing until they are") }
        guard let refreshToken = current.refresh_token, let refreshRequest else {
            refused("SmartThings has no refresh token for this sign-in: sign in again on Add accessories")
            throw Failure.refused(refusal ?? "")
        }
        let task = Task { () -> StoredTokens in
            let response = try await refreshRequest(refreshToken)
            return StoredTokens(response, now: self.now(), locationID: nil, previous: current)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            // Saved before the new access token is used and before the new refresh token could ever be sent.
            tokens = fresh
            do {
                try file.save(fresh)
                unsaved = false
            } catch {
                unsaved = true
                logger.error("Could not save the new SmartThings tokens to the vault: \(error). Not refreshing again until they are saved.")
            }
            return fresh
        } catch let failure as TokenFailure {
            switch failure {
            case .refused(let code, let description, let status):
                // The endpoint's error and description, never a token (section 3.6).
                logger.error("SmartThings refused the token refresh: \(code)\(description.map { " (\($0))" } ?? "") (HTTP \(status))")
                refused("SmartThings refused the saved sign-in; sign in again")
                throw Failure.refused(refusal ?? "")
            case .transient(let message):
                throw Failure.transient(message)
            }
        }
    }

    private func refused(_ reason: String) {
        guard refusal == nil else { return }
        refusal = reason
        onRefused(reason)
    }

    private func retrySaveIfNeeded() {
        guard unsaved, let tokens else { return }
        if (try? file.save(tokens)) != nil {
            unsaved = false
            logger.info("The SmartThings tokens are saved to the vault")
        }
    }
}
