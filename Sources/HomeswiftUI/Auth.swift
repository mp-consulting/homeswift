import Crypto
import Foundation
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
        var salt = Data(count: 16)
        for index in salt.indices { salt[index] = UInt8.random(in: 0...255) }
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
        let users = state.withLockedValue { $0 }
        let user = users.first { $0.username.lowercased() == username.trimmingCharacters(in: .whitespaces).lowercased() }
        let salt = user?.salt ?? Data(count: 16)
        let expected = user?.hash ?? Data(count: 32)
        let computed = Self.pbkdf2(password: password, salt: salt, iterations: user?.iterations ?? iterations)
        return constantTimeEqual(computed, expected) && user != nil
    }

    private func save(_ users: [User]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(users).write(to: url, options: .atomic)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
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

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    var difference = a.count == b.count ? 0 : 1
    for index in 0..<max(a.count, b.count) {
        let left = index < a.count ? a[a.startIndex + index] : 0
        let right = index < b.count ? b[b.startIndex + index] : 0
        difference |= Int(left ^ right)
    }
    return difference == 0
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

/// Logged-in sessions, in memory: a random token in a cookie, gone after `lifetime` without a request.
public final class SessionStore: Sendable {
    struct Session {
        var username: String
        var expires: Date
    }

    public let lifetime: TimeInterval
    private let sessions = NIOLockedValueBox<[String: Session]>([:])

    public init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    public func create(username: String) -> String {
        var bytes = Data(count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        sessions.withLockedValue { sessions in
            sessions = sessions.filter { $0.value.expires > Date() }
            sessions[token] = Session(username: username, expires: Date().addingTimeInterval(lifetime))
        }
        return token
    }

    /// The user of a live session, refreshing its expiry.
    public func username(for token: String) -> String? {
        sessions.withLockedValue { sessions in
            guard let session = sessions[token], session.expires > Date() else {
                sessions.removeValue(forKey: token)
                return nil
            }
            sessions[token]?.expires = Date().addingTimeInterval(lifetime)
            return session.username
        }
    }

    public func revoke(_ token: String) {
        _ = sessions.withLockedValue { $0.removeValue(forKey: token) }
    }

    public var count: Int { sessions.withLockedValue { $0.count } }
}

/// Slows down repeated failed logins from one address.
final class LoginThrottle: Sendable {
    private let failures = NIOLockedValueBox<[String: (count: Int, last: Date)]>([:])

    /// The delay to impose before answering this attempt.
    func delay(for remote: String) -> Duration {
        let count = failures.withLockedValue { failures -> Int in
            guard let entry = failures[remote], Date().timeIntervalSince(entry.last) < 900 else { return 0 }
            return entry.count
        }
        return count >= 5 ? .seconds(min(count - 4, 10)) : .zero
    }

    func failed(_ remote: String) {
        failures.withLockedValue { failures in
            let previous = failures[remote].map { Date().timeIntervalSince($0.last) < 900 ? $0.count : 0 } ?? 0
            failures[remote] = (previous + 1, Date())
        }
    }

    func succeeded(_ remote: String) {
        failures.withLockedValue { $0[remote] = nil }
    }
}
