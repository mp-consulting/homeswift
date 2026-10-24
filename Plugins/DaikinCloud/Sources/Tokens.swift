import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// The tokens of an OAuth login, as the token endpoint answers and as the token file keeps them. The file
/// has the Homebridge plugin's shape, so a token file copied from a Homebridge storage path works.
struct TokenSet: Codable, Sendable, Equatable {
    var access_token: String
    var refresh_token: String?
    var token_type: String
    var expires_in: Double?
    /// Seconds since 1970.
    var expires_at: Double?
    var scope: String?

    /// Seconds before expiry at which a token counts as expired, so a request never leaves with a token that
    /// lapses on the way.
    static let expiryBuffer: Double = 10

    var expiresAt: Date? { expires_at.map { Date(timeIntervalSince1970: $0) } }

    /// The set with `expires_at` derived from `expires_in` when the server only sent the lifetime.
    func withExpiresAt(now: Date = Date()) -> TokenSet {
        guard let expires_in, expires_in != 0, expires_at == nil else { return self }
        var copy = self
        copy.expires_at = floor(now.timeIntervalSince1970) + expires_in
        return copy
    }

    /// Expired or about to; a token without `expires_at` counts as expired.
    func isExpiring(now: Date = Date()) -> Bool {
        (expires_at ?? 0) < floor(now.timeIntervalSince1970) + Self.expiryBuffer
    }

    struct InvalidFields: Error { var fields: [String] }

    /// Checks a token endpoint's JSON field by field, as the Homebridge plugin's schema does: the names of
    /// missing or malformed fields on failure, never their values.
    static func validate(_ json: JSONValue) -> Result<TokenSet, InvalidFields> {
        guard case .object(let object) = json else { return .failure(InvalidFields(fields: ["(body)"])) }
        var problems: [String] = []
        func string(_ key: String, required: Bool) -> String? {
            switch object[key] {
            case .string(let value): return value
            case nil: if required { problems.append(key) }
            default: problems.append(key)
            }
            return nil
        }
        func number(_ key: String) -> Double? {
            switch object[key] {
            case .number(let value): return value
            case nil: break
            default: problems.append(key)
            }
            return nil
        }
        let access = string("access_token", required: true)
        let refresh = string("refresh_token", required: false)
        let type = string("token_type", required: true)
        let expiresIn = number("expires_in")
        let expiresAt = number("expires_at")
        let scope = string("scope", required: false)
        guard problems.isEmpty, let access, let type else { return .failure(InvalidFields(fields: problems)) }
        return .success(TokenSet(access_token: access, refresh_token: refresh, token_type: type, expires_in: expiresIn, expires_at: expiresAt, scope: scope))
    }
}

/// An error a user can act on, with the Homebridge plugin's wording. The OAuth error code stays in the
/// message (`invalid_grant`), which callers match on.
struct DaikinError: Error, CustomStringConvertible, Equatable, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// The message of any error, as the Homebridge plugin's `toMessage` gives it.
func message(of error: any Error) -> String {
    switch error {
    case let error as DaikinError: error.message
    case let error as DaikinNetworkError: error.message.isEmpty ? error.code : "\(error.message) (\(error.code))"
    case let error as CustomStringConvertible: error.description
    default: "\(error)"
    }
}

enum TokenResponse {
    /// The JSON of a response, or an error naming the host and status when a proxy or firewall answered
    /// with a page or nothing.
    static func json(_ response: HTTPResponse, url: URL, context: String) throws -> JSONValue {
        do {
            return try JSONValue(data: response.body)
        } catch {
            let snippet = String(response.text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
            throw DaikinError("\(context): \(url.host ?? "") returned a non-JSON response (HTTP \(response.status))"
                + (snippet.isEmpty ? " with an empty body" : ": \(snippet)"))
        }
    }

    /// A token endpoint's answer as a token set: OAuth error bodies, other statuses and malformed sets become
    /// errors with a readable message that never carries a token.
    static func parse(_ response: HTTPResponse, url: URL, context: String) throws -> TokenSet {
        let body = try json(response, url: url, context: context)
        if case .object(let object) = body, case .string(let error) = object["error"] {
            var description: String?
            switch object["error_description"] {
            case .string(let value): description = value
            case nil: break
            default: description = nil
            }
            if object["error_description"] == nil || description != nil {
                throw DaikinError("\(context): \(error)\(description.map { $0.isEmpty ? "" : " - \($0)" } ?? "") (HTTP \(response.status))")
            }
        }
        guard response.isSuccess else { throw DaikinError("\(context): \(url.host ?? "") returned HTTP \(response.status)") }
        switch TokenSet.validate(body) {
        case .success(let tokens): return tokens
        case .failure(let invalid):
            var seen = Set<String>()
            let unique = invalid.fields.filter { seen.insert($0).inserted }
            throw DaikinError("\(context): \(url.host ?? "") returned an invalid token response (missing or malformed: \(unique.joined(separator: ", ")))")
        }
    }
}

/// The token file: owner-only, replaced atomically, ignored when it does not hold a valid token set.
enum TokenFile {
    static func load(_ url: URL) -> TokenSet? {
        guard let data = try? Data(contentsOf: url), let json = try? JSONValue(data: data) else { return nil }
        return try? TokenSet.validate(json).get()
    }

    static func save(_ tokens: TokenSet, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try OwnerOnlyFile.write(encoder.encode(tokens), to: url)
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the API client and the WebSocket need from a login: a valid access token, and a refresh when the
/// cloud says the token no longer works.
protocol OAuthProvider: Sendable {
    func accessToken() async throws -> String
    @discardableResult func refreshToken() async throws -> TokenSet
}

/// The token lifecycle both logins share: the token file, expiry with a margin, one refresh in flight at a
/// time, and the previous refresh token kept when the server does not rotate it.
actor TokenClient: OAuthProvider {
    typealias Refresh = @Sendable (_ refreshToken: String) async throws -> TokenSet

    let file: URL
    private(set) var tokens: TokenSet?
    private var refreshing: Task<TokenSet, any Error>?
    /// Bumped when the tokens are cleared or reloaded: a refresh that started before keeps its answer to
    /// itself instead of writing a revoked or replaced login back to the file.
    private var generation = 0
    private let requestRefresh: Refresh
    private let onError: @Sendable (String) -> Void

    init(file: URL, onError: @escaping @Sendable (String) -> Void = { _ in }, refresh: @escaping Refresh) {
        self.file = file
        self.onError = onError
        requestRefresh = refresh
        tokens = TokenFile.load(file)
    }

    func isAuthenticated() -> Bool { !(tokens?.access_token.isEmpty ?? true) }

    /// A valid access token, refreshed first when it is about to expire.
    func accessToken() async throws -> String {
        guard let current = tokens else { throw DaikinError("Not authenticated. Please authenticate first.") }
        guard current.isExpiring() else { return current.access_token }
        guard current.refresh_token != nil else { throw DaikinError("Token expired and no refresh token available. Please re-authenticate.") }
        return try await refreshToken().access_token
    }

    /// Refreshes the access token. Concurrent callers share one request; a failed one is not kept, so the
    /// next call tries again.
    @discardableResult
    func refreshToken() async throws -> TokenSet {
        guard let refreshToken = tokens?.refresh_token else { throw DaikinError("No refresh token available") }
        if let refreshing { return try await refreshing.value }
        let request = requestRefresh
        let started = generation
        let task = Task { () -> TokenSet in
            var fresh = try await request(refreshToken)
            // A provider that does not rotate refresh tokens leaves the previous one valid (RFC 6749 §6).
            if fresh.refresh_token == nil { fresh.refresh_token = refreshToken }
            return try self.storeRefreshed(fresh, generation: started)
        }
        refreshing = task
        defer { if generation == started { refreshing = nil } }
        return try await task.value
    }

    private func storeRefreshed(_ tokens: TokenSet, generation started: Int) throws -> TokenSet {
        guard generation == started else { throw DaikinError("Not authenticated. Please authenticate first.") }
        return store(tokens)
    }

    /// Keeps a new token set in memory and on disk, with `expires_at` filled in.
    @discardableResult
    func store(_ tokens: TokenSet) -> TokenSet {
        let stored = tokens.withExpiresAt()
        self.tokens = stored
        do {
            try TokenFile.save(stored, to: file)
        } catch {
            onError("Failed to save token file: \(error)")
        }
        return stored
    }

    /// Forgets the tokens and deletes the file.
    func clear() {
        generation += 1
        refreshing = nil
        TokenFile.delete(file)
        tokens = nil
    }

    /// Reads the file again, after the settings page logged in.
    func reload() {
        generation += 1
        refreshing = nil
        tokens = TokenFile.load(file)
    }
}
