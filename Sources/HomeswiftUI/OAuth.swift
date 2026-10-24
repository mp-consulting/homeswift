import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import NIOConcurrencyHelpers

/// OAuth 2.1 for MCP clients that sign in with a web UI account (claude.ai and the Claude apps, other remote MCP
/// clients): dynamic client registration (RFC 7591), the authorization code grant with PKCE (S256 only), refresh
/// tokens rotated at each use, and revocation (RFC 7009). The tokens reach the MCP server through the UI's `/mcp`
/// and nothing else: the `/api` routes do not take them.
///
/// `ui-oauth.json` next to config.json (owner-only) keeps the clients and the grants with the SHA-256 of every
/// token and client secret, so neither the file nor memory holds a usable one. Authorization codes stay in memory
/// for five minutes.
public final class OAuthStore: Sendable {
    /// A registered client: what it calls itself and where it may be sent back to.
    public struct Client: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var redirectURIs: [String]
        /// `none` (a public client, PKCE alone proves it), `client_secret_post` or `client_secret_basic`.
        public var authMethod: String
        /// The SHA-256 of its secret, in hex, for the two secret methods.
        var secretHash: String?
        public var created: Date
    }

    /// What one sign-in gave one client: whom it acts as, up to which scope, and its current tokens.
    public struct Grant: Codable, Sendable, Equatable {
        public var id: String
        public var clientID: String
        public var username: String
        /// The most it may do; the user's role, read again at each request, may allow less.
        public var scope: Scope
        public var created: Date
        public var lastUsed: Date?
        /// The live access and refresh tokens: one of each, or two when a refresh was asked twice at once (see below).
        var accessHashes: [String]
        var accessExpires: Date
        var refreshHashes: [String]
        /// Pushed back at each refresh: a grant unused this long ends.
        var refreshExpires: Date
        /// The refresh token the last refresh replaced, still taken until `previousUntil`: a client that lost the
        /// answer tries again with it, or sent two refreshes at once; the tokens both answers carry then stay good
        /// until the next refresh. Later, it is a stolen copy, and ends the grant.
        var previousRefreshHash: String?
        var previousUntil: Date?
        /// The code it came from: a second exchange of that code ends it (RFC 6749 §4.1.2).
        var codeHash: String?
    }

    /// A token response's contents.
    public struct Tokens: Sendable {
        public var access: String
        public var refresh: String
        public var expiresIn: Int
        public var grant: Grant
    }

    public enum Validation: Sendable, Equatable {
        case valid(Grant)
        /// One of this store's access tokens, past its hour: the client refreshes.
        case expired
        case unknown
    }

    struct Code: Sendable {
        var clientID: String
        var username: String
        var scope: Scope
        var redirectURI: String
        /// The authorization request named it; without, the token request may leave it out too (RFC 6749 §4.1.3).
        var redirectURIGiven: Bool
        var challenge: String
        var expires: Date
    }

    struct State: Codable, Equatable {
        var clients: [Client] = []
        var grants: [Grant] = []
    }

    public static let accessPrefix = "hsa_"
    public static let refreshPrefix = "hsr_"
    public static let accessLifetime: TimeInterval = 3600
    /// A connector unused for this long signs in again.
    public static let refreshLifetime: TimeInterval = 90 * 86_400
    static let codeLifetime: TimeInterval = 300
    static let refreshGrace: TimeInterval = 60
    /// Registration is open to anyone (claude.ai registers itself): clients that got no grant within a day are
    /// dropped, and at most this many are kept, a new one replacing the oldest without a grant, so a flood of
    /// registrations cannot keep a real client from signing in.
    static let maximumClients = 100
    static let unusedClientLifetime: TimeInterval = 86_400

    public let url: URL
    /// The clients and grants, and how many changes they have had: the file is written from a snapshot taken under
    /// this lock, after it, so a check of a token (on the event loop, for the body limit) never waits on the disk.
    private let state: NIOLockedValueBox<(current: State, generation: UInt64)>
    private let writer = SnapshotWriter()
    private let codes = NIOLockedValueBox<[String: Code]>([:])

    public init(url: URL) {
        self.url = url
        state = NIOLockedValueBox(((try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(State.self, from: $0) } ?? State(), 0))
    }

    public var clients: [Client] { read { $0.clients } }

    public func client(id: String) -> Client? { read { $0.clients.first { $0.id == id } } }

    public func grant(id: String) -> Grant? { read { $0.grants.first { $0.id == id } } }

    /// A user's grants, newest first.
    public func grants(of username: String) -> [Grant] {
        let key = UserStore.key(username)
        return read { $0.grants.filter { UserStore.key($0.username) == key } }.sorted { $0.created > $1.created }
    }

    // MARK: Registration

    /// Registers a client from its RFC 7591 metadata; the secret, for the secret methods, is only in this answer.
    public func register(_ metadata: JSONValue, now: Date = Date()) throws(OAuthError) -> (client: Client, secret: String?) {
        guard metadata.objectValue != nil else { throw .invalidClientMetadata("the registration is a JSON object") }
        guard let list = metadata["redirect_uris"]?.arrayValue, !list.isEmpty, list.count <= 10 else {
            throw .invalidRedirectURI("redirect_uris lists one to ten addresses")
        }
        var redirects: [String] = []
        for entry in list {
            guard let uri = entry.stringValue, Self.acceptableRedirect(uri) else {
                throw .invalidRedirectURI("a redirect URI is https, http on this machine (localhost, 127.0.0.1, [::1]) or an app's own scheme, without a fragment")
            }
            redirects.append(uri)
        }
        let method = metadata["token_endpoint_auth_method"]?.stringValue ?? "client_secret_basic"
        guard ["none", "client_secret_post", "client_secret_basic"].contains(method) else {
            throw .invalidClientMetadata("token_endpoint_auth_method is none, client_secret_post or client_secret_basic")
        }
        if let grants = metadata["grant_types"]?.arrayValue,
           !grants.allSatisfy({ ["authorization_code", "refresh_token"].contains($0.stringValue ?? "") }) {
            throw .invalidClientMetadata("grant_types are authorization_code and refresh_token")
        }
        if let types = metadata["response_types"]?.arrayValue, types.contains(where: { $0.stringValue != "code" }) {
            throw .invalidClientMetadata("response_types is code")
        }
        let name = (metadata["client_name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ? "" : String(name.prefix(80))
        let secret = method == "none" ? nil : Secrets.randomToken()
        let client = Client(
            id: UUID().uuidString.lowercased(), name: shown.isEmpty ? "An MCP client" : shown, redirectURIs: redirects, authMethod: method,
            secretHash: secret.map(SessionStore.key(for:)), created: now)
        let added = change { state in
            Self.prune(&state, now: now)
            if state.clients.count >= Self.maximumClients {
                let granted = Set(state.grants.map(\.clientID))
                guard let oldest = state.clients.indices.filter({ !granted.contains(state.clients[$0].id) }).min(by: { state.clients[$0].created < state.clients[$1].created }) else { return false }
                state.clients.remove(at: oldest)
            }
            state.clients.append(client)
            return true
        }
        guard added else { throw .invalidClientMetadata("too many apps are connected; disconnect one first") }
        return (client, secret)
    }

    /// https anywhere; http only to this machine, where a desktop client listens (RFC 8252 §7.3); a native app's own
    /// scheme (`cursor://…`). Never a fragment, nor a scheme a browser runs.
    static func acceptableRedirect(_ uri: String) -> Bool {
        guard uri.count <= 2000, let components = URLComponents(string: uri), let scheme = components.scheme?.lowercased(), components.fragment == nil else { return false }
        switch scheme {
        case "https": return components.host?.isEmpty == false
        case "http": return components.host.map { HostName.isLoopback(HostName.of($0)) } == true
        case "javascript", "data", "file", "vbscript", "blob", "about", "ws", "wss": return false
        default: return true
        }
    }

    /// Clients registered over a day ago that have no grant, and grants unused past their refresh lifetime.
    private static func prune(_ state: inout State, now: Date) {
        state.grants.removeAll { $0.refreshExpires <= now }
        let granted = Set(state.grants.map(\.clientID))
        state.clients.removeAll { !granted.contains($0.id) && now.timeIntervalSince($0.created) > unusedClientLifetime }
    }

    /// Whether a client presents what its method asks for: its secret (in constant time), or nothing for a public one.
    public func authenticate(clientID: String, secret: String?) -> Client? {
        guard let client = client(id: clientID) else { return nil }
        guard let hash = client.secretHash else { return client }
        guard let secret, Secrets.constantTimeEqual(Array(hash.utf8), Array(SessionStore.key(for: secret).utf8)) else { return nil }
        return client
    }

    // MARK: Authorization

    /// The code a signed-in user's approval sends back to the client.
    public func issueCode(clientID: String, username: String, scope: Scope, redirectURI: String, redirectURIGiven: Bool = true, challenge: String, now: Date = Date()) -> String {
        let code = Secrets.randomToken()
        codes.withLockedValue { codes in
            codes = codes.filter { $0.value.expires > now }
            codes[SessionStore.key(for: code)] = Code(
                clientID: clientID, username: username, scope: scope, redirectURI: redirectURI, redirectURIGiven: redirectURIGiven, challenge: challenge,
                expires: now.addingTimeInterval(Self.codeLifetime))
        }
        return code
    }

    /// Trades a code for tokens: once, within five minutes, by the client it was issued to, with the same redirect URI
    /// and the PKCE verifier of its challenge. A second try ends what the first one got.
    public func exchange(code: String, client: Client, redirectURI: String?, verifier: String?, now: Date = Date()) throws(OAuthError) -> Tokens {
        let hash = SessionStore.key(for: code)
        guard let issued = codes.withLockedValue({ $0.removeValue(forKey: hash) }) else {
            change { $0.grants.removeAll { $0.codeHash == hash } }
            throw .invalidGrant("the code is unknown, used or expired")
        }
        guard issued.expires > now else { throw .invalidGrant("the code expired") }
        guard issued.clientID == client.id else { throw .invalidGrant("the code was issued to another client") }
        guard redirectURI == issued.redirectURI || (redirectURI == nil && !issued.redirectURIGiven) else {
            throw .invalidGrant("redirect_uri differs from the authorization request's")
        }
        guard let verifier, Self.verifierIsValid(verifier), Secrets.constantTimeEqual(Array(Self.challenge(for: verifier).utf8), Array(issued.challenge.utf8)) else {
            throw .invalidGrant("code_verifier does not match the code challenge")
        }
        let access = Self.accessPrefix + Secrets.randomToken()
        let refresh = Self.refreshPrefix + Secrets.randomToken()
        let grant = Grant(
            id: UUID().uuidString.lowercased(), clientID: client.id, username: issued.username, scope: issued.scope, created: now, lastUsed: now,
            accessHashes: [SessionStore.key(for: access)], accessExpires: now.addingTimeInterval(Self.accessLifetime),
            refreshHashes: [SessionStore.key(for: refresh)], refreshExpires: now.addingTimeInterval(Self.refreshLifetime), codeHash: hash)
        change { state in
            Self.prune(&state, now: now)
            state.grants.append(grant)
        }
        return Tokens(access: access, refresh: refresh, expiresIn: Int(Self.accessLifetime), grant: grant)
    }

    /// New tokens for a refresh token, which is replaced. `scope`, when asked, may only narrow the grant.
    public func refresh(_ token: String, client: Client, scope: Scope? = nil, now: Date = Date()) throws(OAuthError) -> Tokens {
        let hash = SessionStore.key(for: token)
        let access = Self.accessPrefix + Secrets.randomToken()
        let refresh = Self.refreshPrefix + Secrets.randomToken()
        let grant = try change { state -> Result<Grant, OAuthError> in
            guard let index = state.grants.firstIndex(where: { $0.refreshHashes.contains(hash) || $0.previousRefreshHash == hash }) else {
                return .failure(.invalidGrant("the refresh token is unknown or revoked"))
            }
            var grant = state.grants[index]
            guard grant.clientID == client.id else { return .failure(.invalidGrant("the refresh token was issued to another client")) }
            let current = grant.refreshHashes.contains(hash)
            if !current, (grant.previousUntil ?? .distantPast) <= now {
                // A refresh token used again after its replacement was: someone else holds a copy.
                state.grants.remove(at: index)
                return .failure(.invalidGrant("the refresh token was already used; sign in again"))
            }
            guard grant.refreshExpires > now else { return .failure(.invalidGrant("the refresh token expired; sign in again")) }
            if let scope {
                guard scope <= grant.scope else { return .failure(.invalidScope("a refresh may not widen the grant")) }
                grant.scope = scope
            }
            // A rotation replaces the live tokens and opens the window for the refresh token just used. Within that
            // window, the same token again adds a second pair beside the first: whichever answer the client kept works.
            if current {
                grant.previousRefreshHash = hash
                grant.previousUntil = now.addingTimeInterval(Self.refreshGrace)
                grant.refreshHashes = [SessionStore.key(for: refresh)]
                grant.accessHashes = [SessionStore.key(for: access)]
            } else {
                grant.refreshHashes = Array((grant.refreshHashes + [SessionStore.key(for: refresh)]).suffix(2))
                grant.accessHashes = Array((grant.accessHashes + [SessionStore.key(for: access)]).suffix(2))
            }
            grant.refreshExpires = now.addingTimeInterval(Self.refreshLifetime)
            grant.accessExpires = now.addingTimeInterval(Self.accessLifetime)
            grant.lastUsed = now
            state.grants[index] = grant
            return .success(grant)
        }.get()
        return Tokens(access: access, refresh: refresh, expiresIn: Int(Self.accessLifetime), grant: grant)
    }

    /// RFC 7009: an access or refresh token ends its grant, when it is this client's; anything else is ignored.
    public func revoke(_ token: String, client: Client) {
        let hash = SessionStore.key(for: token)
        change { $0.grants.removeAll { $0.clientID == client.id && ($0.accessHashes.contains(hash) || $0.refreshHashes.contains(hash) || $0.previousRefreshHash == hash) } }
    }

    /// Ends one of a user's grants (the Account page's Disconnect).
    @discardableResult
    public func revoke(grant id: String, of username: String) -> Bool {
        change { state in
            guard let index = state.grants.firstIndex(where: { $0.id == id && UserStore.key($0.username) == UserStore.key(username) }) else { return false }
            state.grants.remove(at: index)
            return true
        }
    }

    /// Ends every grant of a user: removed, or with a new password or two-factor setting, as their other sessions end.
    public func revokeAll(of username: String) {
        let key = UserStore.key(username)
        change { $0.grants.removeAll { UserStore.key($0.username) == key } }
    }

    /// The grant an access token belongs to; notes its use unless `noteUse` is false.
    public func validate(_ presented: String, now: Date = Date(), noteUse: Bool = true) -> Validation {
        guard presented.hasPrefix(Self.accessPrefix), presented.utf8.count <= 128 else { return .unknown }
        let hash = SessionStore.key(for: presented)
        return change { state -> Validation in
            guard let index = state.grants.firstIndex(where: { $0.accessHashes.contains(hash) }) else { return .unknown }
            guard state.grants[index].accessExpires > now else { return .expired }
            if noteUse, state.grants[index].lastUsed.map({ now.timeIntervalSince($0) >= APITokenStore.lastUsedInterval }) ?? true {
                state.grants[index].lastUsed = now
            }
            return .valid(state.grants[index])
        }
    }

    // MARK: PKCE

    /// RFC 7636 §4.1: 43 to 128 unreserved characters.
    static func verifierIsValid(_ verifier: String) -> Bool {
        (43...128).contains(verifier.utf8.count) && verifier.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
        }
    }

    /// The S256 challenge of a verifier: base64url of its SHA-256, without padding.
    static func challenge(for verifier: String) -> String {
        Secrets.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A challenge as S256 makes them: 43 base64url characters.
    static func challengeIsValid(_ challenge: String) -> Bool {
        challenge.utf8.count == 43 && challenge.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }

    // MARK: Scopes

    /// The highest of the scopes a `scope` parameter names (`read control`), nil when it names none of them.
    public static func scope(from parameter: String?) -> Scope? {
        (parameter ?? "").split(separator: " ").compactMap { Scope(rawValue: String($0)) }.max()
    }

    /// A scope as the token response states it: each level it includes.
    public static func parameter(for scope: Scope) -> String {
        Scope.allCases.filter { $0 <= scope }.map(\.rawValue).joined(separator: " ")
    }

    // MARK: File

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func read<T>(_ body: (State) -> T) -> T {
        state.withLockedValue { body($0.current) }
    }

    /// Changes the state under the lock; when something changed, writes the file after it, from a snapshot taken
    /// under it (SessionStore's way: an older snapshot never replaces a newer one).
    @discardableResult
    private func change<T>(_ body: (inout State) -> T) -> T {
        let (result, snapshot) = state.withLockedValue { box -> (T, (State, UInt64)?) in
            let before = box.current
            let result = body(&box.current)
            guard box.current != before else { return (result, nil) }
            box.generation += 1
            return (result, (box.current, box.generation))
        }
        if let (saved, generation) = snapshot {
            writer.write(generation) { try? OwnerOnlyFile.write(Self.encoder.encode(saved), to: url) }
        }
        return result
    }
}

/// An OAuth error response (RFC 6749 §5.2, RFC 7591 §3.2.2): its code, what went wrong, and the HTTP status.
public enum OAuthError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest(String)
    case invalidClient(String)
    case invalidGrant(String)
    case invalidScope(String)
    case unsupportedGrantType(String)
    case invalidRedirectURI(String)
    case invalidClientMetadata(String)

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidClient: "invalid_client"
        case .invalidGrant: "invalid_grant"
        case .invalidScope: "invalid_scope"
        case .unsupportedGrantType: "unsupported_grant_type"
        case .invalidRedirectURI: "invalid_redirect_uri"
        case .invalidClientMetadata: "invalid_client_metadata"
        }
    }

    public var description: String {
        switch self {
        case .invalidRequest(let text), .invalidClient(let text), .invalidGrant(let text), .invalidScope(let text), .unsupportedGrantType(let text),
             .invalidRedirectURI(let text), .invalidClientMetadata(let text): text
        }
    }

    public var status: Int { if case .invalidClient = self { 401 } else { 400 } }

    public var json: JSONValue { ["error": .string(code), "error_description": .string(description)] }
}
