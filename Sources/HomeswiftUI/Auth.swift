import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The UI's users, in `ui-users.json` next to config.json: a salted PBKDF2-HMAC-SHA256 hash per user.
public final class UserStore: Sendable {
    public struct User: Codable, Sendable, Equatable {
        public var username: String
        var salt: Data
        var hash: Data
        var iterations: Int
        var created: Date
    }

    public static let defaultIterations = 210_000

    public let url: URL
    let iterations: Int
    private let state: NIOLockedValueBox<[User]>

    /// Loads the file, or starts empty. `iterations` is for new users (tests lower it).
    public init(url: URL, iterations: Int = UserStore.defaultIterations) {
        self.url = url
        self.iterations = iterations
        let users = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([User].self, from: $0) } ?? []
        state = NIOLockedValueBox(users)
    }

    public var isEmpty: Bool { state.withLockedValue { $0.isEmpty } }
    public var usernames: [String] { state.withLockedValue { $0.map(\.username) } }

    public func contains(_ username: String) -> Bool { user(named: username) != nil }

    /// Usernames are matched without regard to case or surrounding spaces.
    private func user(named username: String) -> User? {
        let name = username.trimmingCharacters(in: .whitespaces).lowercased()
        return state.withLockedValue { $0.first { $0.username.lowercased() == name } }
    }

    /// Adds a user. The username must be new; the password at least eight characters.
    public func create(username: String, password: String) throws {
        try add(username: username, password: password, onlyWhenEmpty: false)
    }

    /// Adds the first user, refusing when one exists: the check and the write happen under one lock, so two
    /// first visits cannot both create an account.
    public func createFirst(username: String, password: String) throws {
        try add(username: username, password: password, onlyWhenEmpty: true)
    }

    private func add(username: String, password: String, onlyWhenEmpty: Bool) throws {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(name.count), !name.contains(where: { $0.isWhitespace || $0 == ":" }) else { throw AuthError.invalidUsername }
        guard password.count >= 8, password.utf8.count <= 1024 else { throw AuthError.weakPassword }
        let salt = Secrets.randomBytes(16)
        let user = User(username: name, salt: salt, hash: Self.pbkdf2(password: password, salt: salt, iterations: iterations), iterations: iterations, created: Date())
        try state.withLockedValue { users in
            guard !onlyWhenEmpty || users.isEmpty else { throw AuthError.setupDone }
            guard !users.contains(where: { $0.username.lowercased() == name.lowercased() }) else { throw AuthError.userExists }
            users.append(user)
            try save(users)
        }
    }

    /// Whether the password is the user's. Every call does the full hash, so timing says nothing about users.
    public func verify(username: String, password: String) -> Bool {
        let user = user(named: username)
        let salt = user?.salt ?? Data(count: 16)
        let expected = user?.hash ?? Data(count: 32)
        let computed = Self.pbkdf2(password: password, salt: salt, iterations: user?.iterations ?? iterations)
        return Secrets.constantTimeEqual(computed, expected) && user != nil
    }

    private func save(_ users: [User]) throws {
        try OwnerOnlyFile.write(JSONEncoder().encode(users), to: url)
    }

    /// PBKDF2 with HMAC-SHA256 (RFC 8018), 32 bytes.
    static func pbkdf2(password: String, salt: Data, iterations: Int, length: Int = 32) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        var output = Data()
        var block: UInt32 = 1
        while output.count < length {
            var message = salt
            message.append(contentsOf: withUnsafeBytes(of: block.bigEndian) { Array($0) })
            var u = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
            var t = u
            for _ in 1..<max(1, iterations) {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for index in t.indices { t[index] ^= u[index] }
            }
            output.append(t)
            block += 1
        }
        return output.prefix(length)
    }
}

public enum AuthError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidUsername
    case weakPassword
    case userExists
    case setupDone
    case wrongSetupCode
    case badCredentials

    public var description: String {
        switch self {
        case .invalidUsername: "the username must be 1 to 64 characters without spaces or colons"
        case .weakPassword: "the password must be at least 8 characters"
        case .userExists: "that user already exists"
        case .setupDone: "the first user already exists; sign in"
        case .wrongSetupCode: "wrong set-up code: it is in the bridge's output, next to the web UI address"
        case .badCredentials: "wrong username or password"
        }
    }
}

/// Logged-in sessions: a random token in a cookie, gone after `lifetime` without a request, and gone when
/// `isKnownUser` no longer knows its user (the user file was reset). With a `url` they are kept in a file
/// (owner-only) and survive a restart of the bridge; the file is written when a session starts or ends, so
/// a session's expiry in the file is from its start, and a loaded expiry never exceeds the lifetime.
/// Sessions are keyed by the SHA-256 of the token, so neither the file nor memory holds a usable cookie.
public final class SessionStore: Sendable {
    struct Session: Codable {
        var username: String
        var expires: Date
    }

    public let lifetime: TimeInterval
    let url: URL?
    private let isKnownUser: @Sendable (String) -> Bool
    private let sessions: NIOLockedValueBox<[String: Session]>

    public init(lifetime: TimeInterval, url: URL? = nil, isKnownUser: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.lifetime = lifetime
        self.url = url
        self.isKnownUser = isKnownUser
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Session].self, from: $0) } ?? [:]
        let latest = Date().addingTimeInterval(lifetime)
        sessions = NIOLockedValueBox(saved.compactMapValues { session in
            let capped = Session(username: session.username, expires: min(session.expires, latest))
            return capped.expires > Date() && isKnownUser(session.username) ? capped : nil
        })
    }

    public func create(username: String) -> String {
        let token = Secrets.randomToken()
        update { sessions in
            sessions = sessions.filter { $0.value.expires > Date() }
            sessions[Self.key(for: token)] = Session(username: username, expires: Date().addingTimeInterval(lifetime))
        }
        return token
    }

    /// The user of a live session, refreshing its expiry. A session whose user is gone ends here.
    public func username(for token: String) -> String? {
        let key = Self.key(for: token)
        let found: Session? = sessions.withLockedValue { sessions in
            guard let session = sessions[key], session.expires > Date() else {
                sessions.removeValue(forKey: key)
                return nil
            }
            sessions[key]?.expires = Date().addingTimeInterval(lifetime)
            return session
        }
        guard let found else { return nil }
        guard isKnownUser(found.username) else {
            revoke(token)
            return nil
        }
        return found.username
    }

    public func revoke(_ token: String) {
        let key = Self.key(for: token)
        update { $0.removeValue(forKey: key) }
    }

    public var count: Int { sessions.withLockedValue { $0.count } }

    /// Changes the sessions under the lock and writes the file after it, so requests never wait on the disk.
    private func update(_ change: (inout [String: Session]) -> Void) {
        let snapshot = sessions.withLockedValue { sessions -> [String: Session] in
            change(&sessions)
            return sessions
        }
        guard let url else { return }
        try? OwnerOnlyFile.write(JSONEncoder().encode(snapshot), to: url)
    }

    static func key(for token: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(token.utf8)) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
