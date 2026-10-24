import Crypto
#if canImport(CommonCrypto)
import CommonCrypto
#endif
import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The UI's users, in `ui-users.json` next to config.json (owner-only): a salted PBKDF2-HMAC-SHA256 hash per
/// user, whether they are an administrator, and their two-factor secret. As Glass UI's: an administrator does
/// everything; any other user sees the bridge and controls accessories, nothing more. There is always an
/// administrator: the last one can be neither removed nor demoted, an account added while there is none becomes
/// one (`homeswift users add`, which the Synology installer runs for the first account), and a file that has users
/// but no administrator gets its first user promoted when it loads (installs made before that rule). A file from
/// before roles loads with its users as administrators (there was one account, the administrator).
public final class UserStore: Sendable {
    public struct User: Codable, Sendable, Equatable {
        public var username: String
        /// The name shown in the UI; the username unless one was given.
        public var name: String
        public var admin: Bool
        var salt: Data
        var hash: Data
        var iterations: Int
        public var created: Date
        /// The TOTP secret: waiting for its first code while `otpActive` is false, asked at every login once true.
        var otpSecret: Data?
        public var otpActive: Bool

        init(username: String, name: String, admin: Bool, salt: Data, hash: Data, iterations: Int, created: Date) {
            self.username = username
            self.name = name
            self.admin = admin
            self.salt = salt
            self.hash = hash
            self.iterations = iterations
            self.created = created
            otpActive = false
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            username = try container.decode(String.self, forKey: .username)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? username
            admin = try container.decodeIfPresent(Bool.self, forKey: .admin) ?? true
            salt = try container.decode(Data.self, forKey: .salt)
            hash = try container.decode(Data.self, forKey: .hash)
            iterations = try container.decode(Int.self, forKey: .iterations)
            created = try container.decode(Date.self, forKey: .created)
            otpSecret = try container.decodeIfPresent(Data.self, forKey: .otpSecret)
            otpActive = try container.decodeIfPresent(Bool.self, forKey: .otpActive) ?? false
        }
    }

    public static let defaultIterations = 210_000

    public let url: URL
    let iterations: Int
    private let state: NIOLockedValueBox<[User]>
    /// The latest TOTP step each user signed in with, by lower-cased username: a code works once (RFC 6238 §5.2).
    private let usedSteps = NIOLockedValueBox<[String: UInt64]>([:])

    /// Loads the file, or starts empty. `iterations` is for new users (tests lower it).
    public init(url: URL, iterations: Int = UserStore.defaultIterations) {
        self.url = url
        self.iterations = iterations
        var users = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([User].self, from: $0) } ?? []
        let promote = !users.isEmpty && !users.contains(where: \.admin)
        if promote { users[0].admin = true }
        state = NIOLockedValueBox(users)
        if promote { try? save(users) }
    }

    public var isEmpty: Bool { state.withLockedValue { $0.isEmpty } }
    public var usernames: [String] { state.withLockedValue { $0.map(\.username) } }
    /// Every user, in the order they were added.
    public var users: [User] { state.withLockedValue { $0 } }

    public func contains(_ username: String) -> Bool { user(named: username) != nil }

    /// Usernames are matched without regard to case or surrounding spaces.
    public func user(named username: String) -> User? {
        let name = Self.key(username)
        return state.withLockedValue { $0.first { $0.username.lowercased() == name } }
    }

    public func isAdmin(_ username: String) -> Bool { user(named: username)?.admin == true }

    static func key(_ username: String) -> String { username.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Adds a user. The username must be new; the password must pass `PasswordPolicy`.
    @discardableResult
    public func create(username: String, password: String, name: String? = nil, admin: Bool = false) throws -> User {
        try add(username: username, password: password, name: name, admin: admin, onlyWhenEmpty: false)
    }

    /// Adds the first user, an administrator, refusing when one exists: the check and the write happen under one
    /// lock, so two first visits cannot both create an account.
    @discardableResult
    public func createFirst(username: String, password: String) throws -> User {
        try add(username: username, password: password, name: nil, admin: true, onlyWhenEmpty: true)
    }

    private func add(username: String, password: String, name: String?, admin: Bool, onlyWhenEmpty: Bool) throws -> User {
        let username = username.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(username.count), !username.contains(where: { $0.isWhitespace || $0 == ":" }) else { throw AuthError.invalidUsername }
        let shown = try Self.displayName(name, username: username)
        try PasswordPolicy.check(password, username: username)
        let salt = Secrets.randomBytes(16)
        var user = User(username: username, name: shown, admin: admin, salt: salt, hash: Self.pbkdf2(password: password, salt: salt, iterations: iterations), iterations: iterations, created: Date())
        try state.withLockedValue { users in
            guard !onlyWhenEmpty || users.isEmpty else { throw AuthError.setupDone }
            guard !users.contains(where: { $0.username.lowercased() == username.lowercased() }) else { throw AuthError.userExists }
            // There is always an administrator: the first account, however it is added, is one.
            if !users.contains(where: \.admin) { user.admin = true }
            users.append(user)
            try save(users)
        }
        return user
    }

    /// A display name: trimmed, 1 to 64 characters without control characters; the username when empty.
    static func displayName(_ name: String?, username: String) throws -> String {
        let shown = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if shown.isEmpty { return username }
        guard shown.count <= 64, !shown.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw AuthError.invalidName }
        return shown
    }

    /// Whether the password is the user's. Every call does the full hash, so timing says nothing about users.
    public func verify(username: String, password: String) -> Bool {
        authenticate(username: username, password: password) != nil
    }

    /// The user, when the password is theirs (a full hash either way, as `verify`).
    public func authenticate(username: String, password: String) -> User? {
        // No password is that long; hashing megabytes 210,000 times would only slow the bridge down. The hash of
        // an empty one keeps the timing of a refusal.
        guard password.utf8.count <= PasswordPolicy.maximumBytes else {
            _ = Self.pbkdf2(password: "", salt: Data(count: 16), iterations: iterations)
            return nil
        }
        let user = user(named: username)
        let salt = user?.salt ?? Data(count: 16)
        let expected = user?.hash ?? Data(count: 32)
        let computed = Self.pbkdf2(password: password, salt: salt, iterations: user?.iterations ?? iterations)
        return Secrets.constantTimeEqual(computed, expected) ? user : nil
    }

    /// Replaces a user's password once the current one checks out (a full hash either way, as `verify`).
    public func changePassword(username: String, current: String, new password: String) throws {
        guard verify(username: username, password: current) else { throw AuthError.wrongPassword }
        try setPassword(username: username, password)
    }

    private func setPassword(username: String, _ password: String) throws {
        try PasswordPolicy.check(password, username: username)
        let salt = Secrets.randomBytes(16)
        let hash = Self.pbkdf2(password: password, salt: salt, iterations: iterations)
        try change(username) { user in
            user.salt = salt
            user.hash = hash
            user.iterations = iterations
        }
    }

    /// An administrator's change to a user: the name shown, the role, a new password (no current one needed).
    /// The last administrator keeps the role.
    @discardableResult
    public func update(username: String, name: String? = nil, admin: Bool? = nil, password: String? = nil) throws -> User {
        guard let existing = user(named: username) else { throw AuthError.noSuchUser }
        let shown = try name.map { try Self.displayName($0, username: existing.username) }
        // Everything is checked before anything changes: a refused role leaves the password as it was.
        if let password { try PasswordPolicy.check(password, username: existing.username) }
        var updated = try modify(existing.username) { user, users in
            if let admin, admin != user.admin, !admin, users.filter(\.admin).count < 2 { throw AuthError.lastAdmin }
            if let shown { user.name = shown }
            if let admin { user.admin = admin }
        }
        if let password {
            try setPassword(username: existing.username, password)
            updated = user(named: existing.username) ?? updated
        }
        return updated
    }

    /// Removes a user; never the last administrator.
    public func delete(username: String) throws {
        let name = Self.key(username)
        try state.withLockedValue { users in
            guard let index = users.firstIndex(where: { $0.username.lowercased() == name }) else { throw AuthError.noSuchUser }
            if users[index].admin, users.filter(\.admin).count < 2 { throw AuthError.lastAdmin }
            users.remove(at: index)
            try save(users)
        }
        _ = usedSteps.withLockedValue { $0.removeValue(forKey: name) }
    }

    // MARK: Two-factor authentication

    /// Starts setting up TOTP: a new secret, kept until a code from it turns it on (`activateTwoFactor`). Refused
    /// while it is on: turning it off first takes the password.
    public func beginTwoFactor(username: String) throws -> Data {
        let secret = TOTP.newSecret()
        try change(username) { user in
            guard !user.otpActive else { throw AuthError.twoFactorActive }
            user.otpSecret = secret
        }
        return secret
    }

    /// Turns TOTP on once a code from the new secret checks out: the app has it.
    public func activateTwoFactor(username: String, code: String, at date: Date = Date()) throws {
        try change(username) { user in
            guard !user.otpActive else { throw AuthError.twoFactorActive }
            guard let secret = user.otpSecret else { throw AuthError.twoFactorNotSetUp }
            guard let step = TOTP.matchingStep(code, secret: secret, at: date) else { throw AuthError.wrongCode }
            user.otpActive = true
            usedSteps.withLockedValue { $0[user.username.lowercased()] = step }
        }
    }

    /// Turns TOTP off, with the password (a full hash either way).
    public func disableTwoFactor(username: String, password: String) throws {
        guard verify(username: username, password: password) else { throw AuthError.wrongPassword }
        try change(username) { user in
            user.otpActive = false
            user.otpSecret = nil
        }
    }

    /// Whether the code is the user's for now, and not one already used: each step's code signs in once.
    public func checkTwoFactor(username: String, code: String, at date: Date = Date()) -> Bool {
        guard let user = user(named: username), user.otpActive, let secret = user.otpSecret,
              let step = TOTP.matchingStep(code, secret: secret, at: date) else { return false }
        let key = user.username.lowercased()
        return usedSteps.withLockedValue { used in
            if let last = used[key], step <= last { return false }
            used[key] = step
            return true
        }
    }

    /// Changes one user under the lock and saves.
    @discardableResult
    private func change(_ username: String, _ apply: (inout User) throws -> Void) throws -> User {
        try modify(username) { user, _ in try apply(&user) }
    }

    /// The same, the closure seeing every user (for the last administrator's check).
    @discardableResult
    private func modify(_ username: String, _ apply: (inout User, [User]) throws -> Void) throws -> User {
        let name = Self.key(username)
        return try state.withLockedValue { users in
            guard let index = users.firstIndex(where: { $0.username.lowercased() == name }) else { throw AuthError.noSuchUser }
            var user = users[index]
            try apply(&user, users)
            users[index] = user
            try save(users)
            return user
        }
    }

    /// Sets a user's password without the current one: `homeswift users password`, for whoever can run the
    /// bridge's binary and so could edit this file anyway.
    public func resetPassword(username: String, to password: String) throws {
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
    case invalidName
    case noSuchUser
    /// The last administrator cannot be removed nor lose the role.
    case lastAdmin
    case twoFactorActive
    case twoFactorNotSetUp
    case wrongCode
    case invalidTokenName
    case invalidExpiry
    case noSuchToken

    public var description: String {
        switch self {
        case .invalidUsername: "the username must be 1 to 64 characters without spaces or colons"
        case .weakPassword(let problems): "the password is too weak: \(problems)"
        case .userExists: "that user already exists"
        case .setupDone: "the first user already exists; sign in"
        case .wrongSetupCode: "wrong set-up code: it is in the bridge's output, next to the web UI address"
        case .badCredentials: "wrong username or password"
        case .wrongPassword: "the current password is not right"
        case .invalidName: "the name must be 1 to 64 characters"
        case .noSuchUser: "there is no such user"
        case .lastAdmin: "this is the last administrator: make another user an administrator first"
        case .twoFactorActive: "two-factor authentication is already on; turn it off first"
        case .twoFactorNotSetUp: "set up two-factor authentication first"
        case .wrongCode: "that code is not right: type the 6 digits your authenticator app shows now"
        case .invalidTokenName: "the token needs a name of 1 to 64 characters"
        case .invalidExpiry: "a token expires after 1 to \(APITokenStore.maximumDays) days, or never"
        case .noSuchToken: "there is no such token"
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
    /// The sessions, and how many changes they have had: the file is written from a snapshot taken under this lock.
    private let sessions: NIOLockedValueBox<(all: [String: Session], generation: UInt64)>
    private let writer = SnapshotWriter()

    public init(lifetime: TimeInterval, url: URL? = nil, isKnownUser: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.lifetime = lifetime
        self.url = url
        self.isKnownUser = isKnownUser
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Session].self, from: $0) } ?? [:]
        let latest = Date().addingTimeInterval(lifetime)
        sessions = NIOLockedValueBox((saved.compactMapValues { session in
            let capped = Session(username: session.username, expires: min(session.expires, latest))
            return capped.expires > Date() && isKnownUser(session.username) ? capped : nil
        }, 0))
    }

    public func create(username: String) -> String {
        let token = Secrets.randomToken()
        update { sessions in
            sessions = sessions.filter { $0.value.expires > Date() }
            sessions[Self.key(for: token)] = Session(username: username, expires: Date().addingTimeInterval(lifetime))
        }
        return token
    }

    /// The user of a live session, refreshing its expiry unless `refresh` is false (a check that is not the user's
    /// own request, such as an open event stream's). A session whose user is gone ends here.
    public func username(for token: String, refresh: Bool = true) -> String? {
        let key = Self.key(for: token)
        let found: Session? = sessions.withLockedValue { sessions in
            guard let session = sessions.all[key], session.expires > Date() else {
                sessions.all.removeValue(forKey: key)
                return nil
            }
            if refresh { sessions.all[key]?.expires = Date().addingTimeInterval(lifetime) }
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

    public var count: Int { sessions.withLockedValue { $0.all.count } }

    /// Ends every session of a user but the one with `keeping`: after a password change, a browser signed in with
    /// the old password is signed out.
    public func revokeAll(of username: String, keeping token: String?) {
        let kept = token.map(Self.key(for:))
        let name = username.lowercased()
        update { sessions in sessions = sessions.filter { $0.key == kept || $0.value.username.lowercased() != name } }
    }

    /// Changes the sessions under the lock and writes the file after it, so requests never wait on the disk. Two
    /// changes at once write in order: an older snapshot never replaces a newer one, which would bring a revoked
    /// session back at the next start.
    private func update(_ change: (inout [String: Session]) -> Void) {
        let (snapshot, generation) = sessions.withLockedValue { sessions -> ([String: Session], UInt64) in
            change(&sessions.all)
            sessions.generation += 1
            return (sessions.all, sessions.generation)
        }
        guard let url else { return }
        writer.write(generation) { try? OwnerOnlyFile.write(JSONEncoder().encode(snapshot), to: url) }
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

/// Writes a file from snapshots taken under another lock, newest first: a snapshot older than the one written last
/// is dropped, so two changes saved at once never leave the earlier one on disk.
final class SnapshotWriter: Sendable {
    private let written = NIOLockedValueBox<UInt64>(0)

    /// Runs `save` for the snapshot of change number `generation`, unless a later one was written already.
    func write(_ generation: UInt64, _ save: () throws -> Void) rethrows {
        try written.withLockedValue { last in
            guard generation > last else { return }
            try save()
            last = generation
        }
    }
}
