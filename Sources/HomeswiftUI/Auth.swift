import Crypto
#if canImport(CommonCrypto)
import CommonCrypto
#endif
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

    /// Adds a user. The username must be new; the password must pass `PasswordPolicy`.
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
        try PasswordPolicy.check(password, username: name)
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
        // No password is that long; hashing megabytes 210,000 times would only slow the bridge down. The hash of
        // an empty one keeps the timing of a refusal.
        guard password.utf8.count <= PasswordPolicy.maximumBytes else {
            _ = Self.pbkdf2(password: "", salt: Data(count: 16), iterations: iterations)
            return false
        }
        let user = user(named: username)
        let salt = user?.salt ?? Data(count: 16)
        let expected = user?.hash ?? Data(count: 32)
        let computed = Self.pbkdf2(password: password, salt: salt, iterations: user?.iterations ?? iterations)
        return Secrets.constantTimeEqual(computed, expected) && user != nil
    }

    /// Replaces a user's password once the current one checks out (a full hash either way, as `verify`).
    public func changePassword(username: String, current: String, new password: String) throws {
        guard verify(username: username, password: current) else { throw AuthError.wrongPassword }
        try PasswordPolicy.check(password, username: username)
        let salt = Secrets.randomBytes(16)
        let hash = Self.pbkdf2(password: password, salt: salt, iterations: iterations)
        let name = username.trimmingCharacters(in: .whitespaces).lowercased()
        try state.withLockedValue { users in
            guard let index = users.firstIndex(where: { $0.username.lowercased() == name }) else { throw AuthError.badCredentials }
            users[index].salt = salt
            users[index].hash = hash
            users[index].iterations = iterations
            try save(users)
        }
    }

    private func save(_ users: [User]) throws {
        try OwnerOnlyFile.write(JSONEncoder().encode(users), to: url)
    }

    /// PBKDF2 with HMAC-SHA256 (RFC 8018), 32 bytes. CommonCrypto's on Apple platforms; elsewhere a loop that
    /// keys the HMAC once and reuses its buffers (a fresh HMAC and `Data` per round took seconds in debug builds).
    static func pbkdf2(password: String, salt: Data, iterations: Int, length: Int = 32) -> Data {
        #if canImport(CommonCrypto)
        var derived = [UInt8](repeating: 0, count: length)
        let secret = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            secret.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, secret.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(max(1, iterations)), &derived, length)
            }
        }
        if status == kCCSuccess { return Data(derived) }
        #endif
        return portablePBKDF2(password: password, salt: salt, iterations: iterations, length: length)
    }

    static func portablePBKDF2(password: String, salt: Data, iterations: Int, length: Int = 32) -> Data {
        let keyed = HMAC<SHA256>(key: SymmetricKey(data: Data(password.utf8)))
        var output = Data()
        var block: UInt32 = 1
        var u = [UInt8](repeating: 0, count: 32)
        var t = [UInt8](repeating: 0, count: 32)
        while output.count < length {
            var first = keyed
            first.update(data: salt)
            first.update(data: withUnsafeBytes(of: block.bigEndian) { Array($0) })
            first.finalize().withUnsafeBytes { bytes in for index in 0..<32 { u[index] = bytes[index] } }
            t = u
            for _ in 1..<max(1, iterations) {
                var round = keyed
                round.update(data: u)
                round.finalize().withUnsafeBytes { bytes in
                    for index in 0..<32 {
                        u[index] = bytes[index]
                        t[index] ^= bytes[index]
                    }
                }
            }
            output.append(contentsOf: t)
            block += 1
        }
        return output.prefix(length)
    }
}

public enum AuthError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidUsername
    /// What to change, in words.
    case weakPassword(String)
    case userExists
    case setupDone
    case wrongSetupCode
    case badCredentials
    case wrongPassword

    public var description: String {
        switch self {
        case .invalidUsername: "the username must be 1 to 64 characters without spaces or colons"
        case .weakPassword(let problems): "the password is too weak: \(problems)"
        case .userExists: "that user already exists"
        case .setupDone: "the first user already exists; sign in"
        case .wrongSetupCode: "wrong set-up code: it is in the bridge's output, next to the web UI address"
        case .badCredentials: "wrong username or password"
        case .wrongPassword: "the current password is not right"
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

    /// Ends every session of a user but the one with `keeping`: after a password change, a browser signed in with
    /// the old password is signed out.
    public func revokeAll(of username: String, keeping token: String?) {
        let kept = token.map(Self.key(for:))
        let name = username.lowercased()
        update { sessions in sessions = sessions.filter { $0.key == kept || $0.value.username.lowercased() != name } }
    }

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
