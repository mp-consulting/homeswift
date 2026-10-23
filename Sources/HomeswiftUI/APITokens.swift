import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// API tokens for scripts, after Glass UI's (`core/auth/api-token.service.ts`): `Authorization: Bearer hst_…` on
/// `/api/*`. A `read` token is a user that is not an administrator, limited to reading (GET); an `admin` token is
/// an administrator. The token is shown once, when it is made; `ui-api-tokens.json` next to config.json (owner-only)
/// keeps its SHA-256, so neither the file nor memory holds a usable token. Tokens name no account: they cannot
/// change a password, two-factor authentication, users or tokens.
public final class APITokenStore: Sendable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case read, admin
    }

    public struct Token: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var scope: Scope
        /// The SHA-256 of the token, in hex.
        var hash: String
        public var created: Date
        /// Nil: it never expires.
        public var expires: Date?
        public var lastUsed: Date?
        /// Who made it.
        public var createdBy: String?
    }

    /// Every token starts with it, so a bearer value is told apart at a glance (and by secret scanners).
    public static let prefix = "hst_"
    /// Ten years, as Glass UI's longest.
    public static let maximumDays = 3650
    /// `lastUsed` is written at most once a minute per token, so a busy script does not rewrite the file.
    static let lastUsedInterval: TimeInterval = 60

    public let url: URL
    private let state: NIOLockedValueBox<[Token]>

    public init(url: URL) {
        self.url = url
        state = NIOLockedValueBox((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Token].self, from: $0) } ?? [])
    }

    /// Every token, newest first.
    public var tokens: [Token] { state.withLockedValue { $0 }.sorted { $0.created > $1.created } }

    /// Makes a token: its record, and the token itself, which only this answer carries.
    public func create(name: String, scope: Scope, expiresInDays days: Int? = nil, createdBy: String? = nil, now: Date = Date()) throws -> (token: Token, value: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count), !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw AuthError.invalidTokenName }
        if let days, !(1...Self.maximumDays).contains(days) { throw AuthError.invalidExpiry }
        let value = Self.prefix + Self.base64URL(Secrets.randomBytes(32))
        let token = Token(
            id: UUID().uuidString.lowercased(), name: name, scope: scope, hash: SessionStore.key(for: value), created: now,
            expires: days.map { now.addingTimeInterval(TimeInterval($0) * 86_400) }, lastUsed: nil, createdBy: createdBy)
        try state.withLockedValue { tokens in
            tokens.append(token)
            try save(tokens)
        }
        return (token, value)
    }

    /// Revokes (removes) a token; the next request with it gets a 401.
    @discardableResult
    public func revoke(id: String) throws -> Token {
        try state.withLockedValue { tokens in
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { throw AuthError.noSuchToken }
            let removed = tokens.remove(at: index)
            try save(tokens)
            return removed
        }
    }

    /// The token a bearer value is, unless it is unknown, revoked or expired; notes its use.
    public func validate(_ presented: String, now: Date = Date()) -> Token? {
        guard presented.hasPrefix(Self.prefix), presented.utf8.count <= 128 else { return nil }
        let hash = SessionStore.key(for: presented)
        return state.withLockedValue { tokens -> Token? in
            guard let index = tokens.firstIndex(where: { $0.hash == hash }) else { return nil }
            if let expires = tokens[index].expires, expires <= now { return nil }
            if tokens[index].lastUsed.map({ now.timeIntervalSince($0) >= Self.lastUsedInterval }) ?? true {
                tokens[index].lastUsed = now
                try? save(tokens)
            }
            return tokens[index]
        }
    }

    private func save(_ tokens: [Token]) throws {
        try OwnerOnlyFile.write(JSONEncoder().encode(tokens), to: url)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
