import Crypto
import Foundation
import HomeswiftNetwork
import Homeswift
import HomeswiftPlugin
import Logging

/// The encrypt_type 3 login and its `securePassthrough` (docs/clean-room/TapoPTZ.md, 3.2): the values both sides
/// derive from the cloud password's hash and the two nonces, as pure functions the spec's vectors check (10.1).
enum TapoControlCrypto {
    /// Uppercase hex of SHA-256 of the UTF-8 text.
    static func sha(_ text: String) -> String { Streamd.hex(SHA256.hash(data: Data(text.utf8))).uppercased() }

    /// What the camera proves it knows the password with: `SHA(cnonce + P + nonce) + nonce + cnonce`.
    static func deviceConfirm(cnonce: String, hash: String, nonce: String) -> String { sha(cnonce + hash + nonce) + nonce + cnonce }

    /// What the client proves it with: `SHA(P + cnonce + nonce) + cnonce + nonce`.
    static func digestPassword(cnonce: String, hash: String, nonce: String) -> String { sha(hash + cnonce + nonce) + cnonce + nonce }

    /// The session's AES-128-CBC key (`lsk`) and IV (`ivb`) (step 5), the same cipher as the plugs' securePassthrough.
    static func cipher(cnonce: String, hash: String, nonce: String) -> SecurePassthrough.Cipher {
        let k = sha(cnonce + hash + nonce)
        func derive(_ label: String) -> Data { Data(SHA256.hash(data: Data((label + cnonce + nonce + k).utf8)).prefix(16)) }
        return SecurePassthrough.Cipher(key: derive("lsk"), iv: derive("ivb"))
    }

    /// `Tapo_tag`: `SHA(SHA(P + cnonce) + body + seq)`.
    static func tag(hash: String, cnonce: String, body: String, seq: Int) -> String { sha(sha(hash + cnonce) + body + String(seq)) }
}

enum TapoControlError: Error, CustomStringConvertible, Equatable {
    /// The camera offers only the newer SPAKE2+ login (TapoPTZ.md 3.4), which the plugin does not speak yet.
    case newerLogin
    case wrongPassword
    case lockedOut(seconds: Int)
    /// A shared account's session: control needs the camera's owner (3.2 step 4).
    case notOwner
    case asleep
    /// The camera's certificate is not the one pinned: trusted again only after the camera proves it knows the password.
    case certificateChanged
    /// The session ended (a session code, a reply that does not decrypt): log in again and send once more (3.5).
    case sessionExpired
    case code(Int)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .newerLogin: "the camera's firmware offers only the newer SPAKE2+ login, which this plugin does not support yet"
        case .wrongPassword: "the camera refused the Tapo account's password"
        case .lockedOut(let seconds): "the camera locked its sign-in after too many attempts (\(seconds) s left)"
        case .notOwner: "the camera takes control requests only from its owner's account"
        case .asleep: "the camera did not answer: it is asleep"
        case .certificateChanged: "the camera's certificate changed"
        case .sessionExpired: "the camera ended the session"
        case .code(-64304): "the camera reached the end of its pan or tilt range"
        case .code(-64303): "the camera's motor is busy"
        case .code(-64324): "the camera is in privacy mode"
        case .code(-64302), .code(-64321): "the camera has no such preset"
        case .code(-40109): "too many requests: the camera takes one a second"
        case .code(let code): "the camera answered error \(code)"
        case .invalidResponse(let what): "unexpected answer from the camera (\(what))"
        }
    }

    /// Codes that end a session: log in again and send once more (3.5). `-40210` is also METHOD_DO_NOT_EXIST (7): it is
    /// sent once more after a new login too (`TapoControl.call`), and means unsupported when it comes back.
    static let sessionCodes: Set<Int> = [-40401, -40421, -1, -1001, 9999, -40413, 1002, 1112]
    /// Codes that mean the camera does not have the feature (7).
    static let unsupportedCodes: Set<Int> = [-40105, -40210, -40106, -40101]
}

/// A Tapo camera's control API (docs/clean-room/TapoPTZ.md): HTTPS on port 443 with a self-signed certificate (pinned
/// on first use), signed in as `admin` with the cloud password through the encrypt_type 3 login, each call a
/// `multipleRequest` sent through `securePassthrough`. One session while the camera is awake; a session error logs in
/// again once. The plugin uses it only while a live view keeps the camera awake: a request never wakes it on its own.
actor TapoControl {
    struct Session {
        var stok: String
        var seq: Int
        var cipher: SecurePassthrough.Cipher
        var hash: String
        var cnonce: String
    }

    private let host: String
    private let http: @Sendable () -> any HTTPSending
    private let observe: @Sendable (String?) -> Void
    private let resetTrust: @Sendable () -> Void
    private let password: @Sendable () -> String?
    private let logger: Logger
    private let timeout: Duration
    private var session: Session?
    /// Until when no login is tried, after a refusal or a lockout (3.3).
    private var blockedUntil: ContinuousClock.Instant?
    /// What discover offered, asked once: a camera's logins do not change between sessions.
    private var offersType3: Bool?
    private var lastMotor: ContinuousClock.Instant?
    /// The certificate the last response came with: pinned once a login proved the camera knows the password.
    private var lastFingerprint: String?
    private let motorSpacing: Duration
    /// One exchange at a time: a call waits for the one before (its login, its motor spacing) rather than racing it.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(host: String, http: @escaping @Sendable () -> any HTTPSending, observe: @escaping @Sendable (String?) -> Void = { _ in },
         resetTrust: @escaping @Sendable () -> Void = {}, password: @escaping @Sendable () -> String?, timeout: Duration = .seconds(10), motorSpacing: Duration = .seconds(1), logger: Logger) {
        self.host = host
        self.http = http
        self.observe = observe
        self.resetTrust = resetTrust
        self.password = password
        self.timeout = timeout
        self.motorSpacing = motorSpacing
        self.logger = logger
    }

    // MARK: Pan and tilt (5)

    /// The presets (5.3); throws `.code` with an unsupported code for a camera without a motor.
    func presets() async throws -> [CameraControls.Preset] {
        await acquire()
        defer { release() }
        let result = try await call("getPresetConfig", ["preset": ["name": ["preset"]]])
        let list = ((result["preset"] as? [String: Any])?["preset"] as? [String: Any]) ?? [:]
        let ids = Self.strings(list["id"]), names = Self.strings(list["name"])
        return zip(ids, names).map { CameraControls.Preset(id: $0, name: $1) }
    }

    /// A relative move (5.2): `x` pan, positive right; `y` tilt, positive up; in the camera's units (degrees, as the
    /// sources present them). The end of the range is reported as `.code(-64304)`.
    func move(x: Int, y: Int) async throws {
        try await motor("relativeMove", ["motor": ["move": ["x_coord": String(x), "y_coord": String(y)]]])
    }

    func goToPreset(_ id: String) async throws {
        try await motor("motorMoveToPreset", ["preset": ["goto_preset": ["id": id]]])
    }

    /// A motor request, at most one a second (7, `-40109`); a busy motor is stopped and asked once more (5.2).
    func motor(_ method: String, _ params: [String: Any]) async throws {
        await acquire()
        defer { release() }
        if let lastMotor {
            let next = lastMotor + motorSpacing
            if next > .now { try await Task.sleep(until: next) }
        }
        defer { lastMotor = .now }
        do {
            _ = try await call(method, params)
        } catch TapoControlError.code(-64303) {
            _ = try? await call("cruiseStop", ["motor": ["cruise_stop": [String: Any]()]])
            _ = try await call(method, params)
        }
    }

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    /// Hands the turn to the next waiting call, if any.
    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    // MARK: Calls (4)

    /// One call in a `multipleRequest`: its entry's `result`, or `.code` for its error. A session error logs in again
    /// and sends it once more (3.5).
    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        do {
            return try await send(method, params)
        } catch TapoControlError.sessionExpired, TapoControlError.code(-40210) {
            session = nil
            return try await send(method, params)
        } catch TapoControlError.certificateChanged {
            // A new certificate (a firmware update makes one): trusted again, and pinned, only once the new login's
            // device_confirm proves the camera knows the password (3.2 step 3); nothing secret goes before that.
            logger.warning("The Tapo camera at \(host) presents a new certificate: trusting it once the camera proves it knows the password")
            resetTrust()
            session = nil
            offersType3 = nil
            return try await send(method, params)
        }
    }

    private func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        var current: Session
        if let session { current = session } else { current = try await login() }
        let plaintext = try Self.json(["method": "multipleRequest", "params": ["requests": [["method": method, "params": params]]]])
        let body = String(decoding: try Self.json(["method": "securePassthrough", "params": ["request": try current.cipher.encrypt(plaintext)]]), as: UTF8.self)
        let seq = current.seq
        current.seq += 1
        session = current
        let tag = TapoControlCrypto.tag(hash: current.hash, cnonce: current.cnonce, body: body, seq: seq)
        let reply = try await post("/stok=\(current.stok)/ds", body: Data(body.utf8), headers: [("Seq", String(seq)), ("Tapo_tag", tag)])
        try Self.check(reply["error_code"])
        guard let response = (reply["result"] as? [String: Any])?["response"] as? String else { throw TapoControlError.invalidResponse("no response") }
        // A reply that does not decrypt: the session is no longer valid (3.2 step 6).
        guard let decrypted = try? current.cipher.decrypt(response) else { throw TapoControlError.sessionExpired }
        guard let object = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else { throw TapoControlError.invalidResponse("not JSON") }
        try Self.check(object["error_code"])
        let responses = ((object["result"] as? [String: Any])?["responses"] as? [[String: Any]]) ?? []
        // Matched by method: replies may come in another order (4).
        guard let entry = responses.first(where: { $0["method"] as? String == method }) ?? responses.first else {
            throw TapoControlError.invalidResponse("no answer for \(method)")
        }
        try Self.check(entry["error_code"])
        return entry["result"] as? [String: Any] ?? [:]
    }

    // MARK: Login (3)

    /// Discover, then the encrypt_type 3 login: the camera's confirmation checked against the SHA-256 hash, then the MD5
    /// one, before the client's digest is sent. Every login request counts towards the camera's lockout (3.3): a
    /// refusal or a lockout stops further attempts for a minute, or for as long as the camera says.
    private func login() async throws -> Session {
        if let blockedUntil, blockedUntil > .now { throw TapoControlError.lockedOut(seconds: Int((blockedUntil - .now).components.seconds)) }
        guard let password = password(), !password.isEmpty else { throw TapoControlError.wrongPassword }
        if offersType3 == nil {
            let discover = try await post("/", body: try Self.json(["method": "login", "params": ["sub_method": "discover"]]))
            let discovered = (discover["result"] as? [String: Any]) ?? [:]
            let type3 = TapoCloud.int(discover["error_code"]) == -40413
                && Self.strings(((discovered["data"] as? [String: Any])?["encrypt_type"])).contains("3")
            let pake = Self.strings(((discovered["tpap"] as? [String: Any])?["pake"]))
            logger.info("The Tapo camera at \(host) offers \(type3 ? "the encrypt_type 3 login" : "no encrypt_type 3 login")\(pake.isEmpty ? "" : ", SPAKE2+ \(pake.joined(separator: ","))")")
            if !type3, pake.contains("2") { throw TapoControlError.newerLogin }
            offersType3 = type3
        }

        let cnonce = Secrets.hex(Secrets.randomBytes(8)).uppercased()
        let first = try await post("/", body: try Self.json(["method": "login", "params": ["cnonce": cnonce, "encrypt_type": "3", "username": "admin"]]))
        try checkLockout(first)
        if TapoCloud.int(first["error_code"]) == -40211 {
            offersType3 = nil
            throw TapoControlError.newerLogin
        }
        let data = ((first["result"] as? [String: Any])?["data"] as? [String: Any]) ?? [:]
        guard let nonce = data["nonce"] as? String, let confirm = data["device_confirm"] as? String else {
            throw TapoControlError.invalidResponse("a login without a nonce (error \(TapoCloud.int(first["error_code"]) ?? 0))")
        }
        let hashes = [Streamd.passwordHash(password, sha256: true), Streamd.passwordHash(password, sha256: false)]
        guard let hash = hashes.first(where: { TapoControlCrypto.deviceConfirm(cnonce: cnonce, hash: $0, nonce: nonce) == confirm }) else {
            blockedUntil = .now + .seconds(60)
            throw TapoControlError.wrongPassword
        }
        let digest = TapoControlCrypto.digestPassword(cnonce: cnonce, hash: hash, nonce: nonce)
        let second = try await post("/", body: try Self.json([
            "method": "login", "params": ["cnonce": cnonce, "encrypt_type": "3", "digest_passwd": digest, "username": "admin"],
        ]))
        try checkLockout(second)
        if let code = TapoCloud.int(second["error_code"]), code != 0 {
            if code == -40209 || code == -40411 { blockedUntil = .now + .seconds(60); throw TapoControlError.wrongPassword }
            throw TapoControlError.code(code)
        }
        let result = (second["result"] as? [String: Any]) ?? [:]
        guard let stok = result["stok"] as? String, let start = TapoCloud.int(result["start_seq"]) else { throw TapoControlError.invalidResponse("a login without a session") }
        if let group = result["user_group"] as? String, group != "root" { throw TapoControlError.notOwner }
        observe(lastFingerprint)
        logger.debug("Signed in to the Tapo camera's control API at \(host)")
        return Session(stok: stok, seq: start, cipher: TapoControlCrypto.cipher(cnonce: cnonce, hash: hash, nonce: nonce), hash: hash, cnonce: cnonce)
    }

    /// A lockout in a login reply (3.3): `sec_left` under `result.data`, or DEVICE_BLOCKED.
    private func checkLockout(_ reply: [String: Any]) throws {
        let data = ((reply["result"] as? [String: Any])?["data"] as? [String: Any]) ?? [:]
        if let left = TapoCloud.int(data["sec_left"]), left > 0 {
            blockedUntil = .now + .seconds(left)
            throw TapoControlError.lockedOut(seconds: left)
        }
    }

    /// A POST to the camera; a timeout or a refused connection is `.asleep`, never a credential error (6.1).
    private func post(_ path: String, body: Data, headers: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(host):443\(path)") else { throw TapoControlError.invalidResponse("an address that is not one") }
        var all: [(name: String, value: String)] = [
            ("Referer", "https://\(host):443"), ("Accept", "application/json"), ("User-Agent", "Tapo CameraClient Android"),
            ("requestByApp", "true"), ("Content-Type", "application/json; charset=UTF-8"),
        ]
        all += headers.map { (name: $0.0, value: $0.1) }
        let response: HTTPResponse
        do {
            response = try await http().send(HTTPRequest(method: "POST", url: url, headers: all, body: body, timeout: timeout))
        } catch HTTPClientError.certificateMismatch {
            throw TapoControlError.certificateChanged
        } catch {
            // The error's kind, never its text: a URL in it would carry the session's stok.
            logger.debug("The Tapo camera at \(host) did not answer its control API (\(Self.kind(of: error)))")
            throw TapoControlError.asleep
        }
        lastFingerprint = response.certificateFingerprint
        // Before a session, the certificate is pinned only by the login that proves the camera (`login`).
        if session != nil { observe(response.certificateFingerprint) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw TapoControlError.invalidResponse("HTTP \(response.status)")
        }
        return object
    }

    /// What went wrong, without the request's URL.
    static func kind(of error: any Error) -> String {
        switch error as? HTTPClientError {
        case .cannotConnect(_, _, let code, _): "cannot connect\(code.map { ", errno \($0)" } ?? "")"
        case .timeout: "timed out"
        case .connectionClosed: "connection closed"
        case .invalidURL: "invalid URL"
        case .certificateMismatch: "certificate mismatch"
        case .responseTooLarge: "response too large"
        case nil: String(describing: type(of: error))
        }
    }

    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// An `error_code`: a session code is `.sessionExpired`, another non-zero one `.code`.
    static func check(_ value: Any?) throws {
        guard let code = TapoCloud.int(value), code != 0 else { return }
        throw TapoControlError.sessionCodes.contains(code) ? TapoControlError.sessionExpired : TapoControlError.code(code)
    }

    /// A list of strings, or of numbers, or one string.
    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue } }
        if let text = value as? String { return [text] }
        if let number = value as? NSNumber { return [number.stringValue] }
        return []
    }
}
