import Crypto
import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging

/// The account's credentials, shared by every device of a block.
struct TapoCredentials: Codable, Sendable, Equatable {
    var username: String
    var password: String
}

/// One device's session: KLAP, or securePassthrough when the device has no KLAP endpoint (docs/clean-room/Tapo.md, 4).
///
/// Requests go one at a time (the session's sequence number and the device's session both want it), so a handshake
/// happens once however many requests wait for it. A session ends when its cookie's `TIMEOUT` passes, the device
/// answers 403 or 401, or the inner answer is a session timeout (9999) or refuses the credentials (-1501): then one new
/// handshake and one retry. A device falls back to securePassthrough only when KLAP's handshake1 answers 404, and never
/// once it has completed a KLAP handshake (`spokeKLAP`, kept across launches): an impostor at its address cannot have it
/// send the account's password the older protocol carries.
actor TapoConnection {
    enum Session {
        case klap(KLAP.Session, cookie: String?)
        case passthrough(SecurePassthrough.Cipher, cookie: String?, token: String)
    }

    /// The session ended on the device: a new handshake, then the request again. `code` is the inner error, if any.
    private struct SessionExpired: Error { var code: Int? }
    /// KLAP's handshake1 answered 404: the device may speak securePassthrough.
    private struct NoKLAP: Error {}

    let host: String
    private let http: any HTTPSending
    private let credentials: @Sendable () -> TapoCredentials?
    /// securePassthrough's login and requests; KLAP and both handshakes take `handshakeTimeout`.
    private let requestTimeout: Duration
    private let handshakeTimeout: Duration
    private let logger: Logger
    private let now: @Sendable () -> ContinuousClock.Instant
    /// Whether this device completed a KLAP handshake before, and what to call when it does.
    private let spokeKLAP: @Sendable () -> Bool
    private let rememberKLAP: @Sendable () -> Void

    private var session: Session?
    /// When the session's cookie expires, from its `TIMEOUT`.
    private var expiry: ContinuousClock.Instant?
    /// Learned once: the device answered handshake1 with an HTTP error, and securePassthrough's login worked.
    private var usesPassthrough = false
    /// Made the first time securePassthrough is needed: 1024-bit RSA takes a moment.
    private var keyPair: SecurePassthrough.KeyPair?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        host: String, http: any HTTPSending, requestTimeout: Duration, handshakeTimeout: Duration = .seconds(5), logger: Logger,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, spokeKLAP: @escaping @Sendable () -> Bool = { false },
        rememberKLAP: @escaping @Sendable () -> Void = {}, credentials: @escaping @Sendable () -> TapoCredentials?
    ) {
        self.spokeKLAP = spokeKLAP
        self.rememberKLAP = rememberKLAP
        self.host = host
        self.http = http
        self.requestTimeout = requestTimeout
        self.handshakeTimeout = handshakeTimeout
        self.logger = logger
        self.now = now
        self.credentials = credentials
    }

    /// Sends a method and answers its `result`; throws the device's error for a non-zero `error_code`.
    func call(_ method: String, params: [String: JSONValue]? = nil, terminalUUID: String? = nil) async throws -> JSONValue {
        await acquire()
        defer { release() }
        let body = TapoMessage.request(method, params: params, terminalUUID: terminalUUID)
        do {
            return try await exchange(body)
        } catch is SessionExpired {
            logger.info("The session with \(host) expired, signing in again")
            session = nil
        }
        do {
            return try await exchange(body)
        } catch let expired as SessionExpired {
            session = nil
            throw expired.code == TapoMessage.invalidCredentials ? TapoError.invalidCredentials : TapoError.sessionRefused
        }
    }

    // MARK: Serialising

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Exchanges

    private func exchange(_ body: Data) async throws -> JSONValue {
        if let expiry, now() >= expiry { session = nil }
        if session == nil { try await handshake() }
        do {
            switch session {
            case .klap(var keys, let cookie):
                let (sequence, encrypted) = try keys.encrypt(body)
                session = .klap(keys, cookie: cookie)
                let response = try await post("/app/request?seq=\(sequence)", body: encrypted, cookie: cookie, timeout: handshakeTimeout)
                if let fresh = Self.cookie(of: response) { session = .klap(keys, cookie: fresh.cookie) }
                guard response.status != 403, response.status != 401 else { throw SessionExpired() }
                guard response.status == 200 else { throw TapoError.http(response.status) }
                let plaintext: Data
                do {
                    plaintext = try keys.decrypt(response.body, sequence: sequence)
                } catch {
                    // A body that does not decrypt was made with other keys: the device started a new session.
                    throw SessionExpired()
                }
                return try Self.result(of: TapoMessage.parse(plaintext))
            case .passthrough(let cipher, let cookie, let token):
                let inner = try await passthrough(body, cipher: cipher, cookie: cookie, path: "/app?token=\(token)", timeout: requestTimeout)
                return try Self.result(of: inner)
            case nil:
                throw TapoError.invalidResponse("no session")
            }
        } catch let error as HTTPClientError {
            // The request may or may not have reached the device: start the next one from a new handshake.
            session = nil
            throw error
        }
    }

    private static func result(of response: JSONValue) throws -> JSONValue {
        let code = TapoMessage.errorCode(of: response)
        if code == TapoMessage.sessionTimeout || code == TapoMessage.invalidCredentials { throw SessionExpired(code: code) }
        return try TapoMessage.result(of: response)
    }

    private func handshake() async throws {
        guard let credentials = credentials() else { throw TapoError.noCredentials }
        if !usesPassthrough {
            do {
                try await klapHandshake(credentials)
                rememberKLAP()
                return
            } catch is NoKLAP {
                guard !spokeKLAP() else {
                    logger.warning("\(host) answered KLAP's handshake with HTTP 404, but it spoke KLAP before: not falling back to securePassthrough")
                    throw TapoError.http(404)
                }
                logger.info("\(host) has no KLAP endpoint (HTTP 404), trying securePassthrough")
                do {
                    try await passthroughHandshake(credentials)
                    usesPassthrough = true
                } catch TapoError.device(TapoMessage.wantsKLAP) {
                    throw TapoError.http(404)
                }
                return
            }
        }
        try await passthroughHandshake(credentials)
    }

    private func klapHandshake(_ credentials: TapoCredentials) async throws {
        session = nil
        expiry = nil
        let authHash = KLAP.authHash(username: credentials.username, password: credentials.password)
        var localSeed = Data(count: 16)
        for index in localSeed.indices { localSeed[index] = UInt8.random(in: .min ... .max) }
        // Without the old cookie: a new session.
        let first = try await post("/app/handshake1", body: localSeed, cookie: nil, timeout: handshakeTimeout)
        guard first.status != 404 else { throw NoKLAP() }
        guard first.status == 200 else { throw TapoError.http(first.status) }
        guard first.body.count == 48 else { throw TapoError.invalidResponse("handshake1 answered \(first.body.count) bytes") }
        let remoteSeed = Data(first.body.prefix(16))
        guard KLAP.serverHash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash) == first.body.suffix(32) else {
            throw TapoError.invalidCredentials
        }
        let cookie = Self.cookie(of: first)
        let second = try await post(
            "/app/handshake2", body: KLAP.clientHash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash), cookie: cookie?.cookie,
            timeout: handshakeTimeout)
        guard second.status == 200 else {
            throw second.status == 403 || second.status == 401 ? TapoError.invalidCredentials : TapoError.http(second.status)
        }
        session = .klap(KLAP.Session(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash), cookie: cookie?.cookie)
        // A minute early, so a request never goes out with a cookie about to expire.
        expiry = cookie?.timeout.map { now() + .seconds(max(0, $0 - 60)) }
        logger.debug("KLAP session with \(host) started")
    }

    private func passthroughHandshake(_ credentials: TapoCredentials) async throws {
        session = nil
        expiry = nil
        let keys = try keyPair ?? SecurePassthrough.KeyPair()
        keyPair = keys
        let request = TapoMessage.request("handshake", params: ["key": .string(keys.publicKeyPEM)])
        let response = try await post("/app", body: request, cookie: nil, timeout: handshakeTimeout, json: true)
        guard response.status == 200 else { throw TapoError.http(response.status) }
        let handshake = try TapoMessage.result(of: TapoMessage.parse(response.body))
        guard let key = handshake["key"]?.stringValue else { throw TapoError.invalidResponse("the handshake has no key") }
        let cipher = try keys.cipher(fromHandshakeKey: key)
        let cookie = Self.cookie(of: response)?.cookie
        let login = TapoMessage.request("login_device", params: SecurePassthrough.loginParameters(username: credentials.username, password: credentials.password).mapValues(JSONValue.string))
        let answer: JSONValue
        do {
            answer = try TapoMessage.result(of: await passthrough(login, cipher: cipher, cookie: cookie, path: "/app", timeout: requestTimeout))
        } catch TapoError.device(-1501) {
            throw TapoError.invalidCredentials
        }
        guard let token = answer["token"]?.stringValue, !token.isEmpty else { throw TapoError.invalidResponse("the login has no token") }
        session = .passthrough(cipher, cookie: cookie, token: token)
        logger.debug("securePassthrough session with \(host) started")
    }

    /// A request in a `securePassthrough` envelope; answers the inner response.
    private func passthrough(_ inner: Data, cipher: SecurePassthrough.Cipher, cookie: String?, path: String, timeout: Duration) async throws -> JSONValue {
        let envelope = JSONValue.object(["method": "securePassthrough", "params": ["request": .string(try cipher.encrypt(inner))]]).encoded()
        let response = try await post(path, body: envelope, cookie: cookie, timeout: timeout, json: true)
        guard response.status == 200 else { throw TapoError.http(response.status) }
        let outer = try TapoMessage.parse(response.body)
        if TapoMessage.errorCode(of: outer) == TapoMessage.sessionTimeout { throw SessionExpired(code: TapoMessage.sessionTimeout) }
        let result = try TapoMessage.result(of: outer)
        guard let encrypted = result["response"]?.stringValue else { throw TapoError.invalidResponse("no securePassthrough response") }
        return try TapoMessage.parse(cipher.decrypt(encrypted))
    }

    private func post(_ path: String, body: Data, cookie: String?, timeout: Duration, json: Bool = false) async throws -> HomeswiftNetwork.HTTPResponse {
        guard let url = URL(string: "http://\(Self.authority(host))\(path)") else { throw HTTPClientError.invalidURL(host) }
        var request = HTTPRequest(method: "POST", url: url, body: body, timeout: timeout)
        request.setHeader("Accept", json ? "application/json" : "*/*")
        request.setHeader("Content-Type", json ? "application/json" : "application/octet-stream")
        if let cookie { request.setHeader("Cookie", cookie) }
        return try await http.send(request)
    }

    /// The host as it goes in a URL: an IPv6 address in brackets.
    static func authority(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// The session cookie of a response's first `Set-Cookie` (up to its first `;`) and its `TIMEOUT` in seconds.
    static func cookie(of response: HomeswiftNetwork.HTTPResponse) -> (cookie: String, timeout: Int?)? {
        guard let header = response.header("Set-Cookie") else { return nil }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cookie = parts.first, !cookie.isEmpty else { return nil }
        let timeout = parts.dropFirst().first { $0.uppercased().hasPrefix("TIMEOUT=") }.flatMap { Int($0.dropFirst("TIMEOUT=".count)) }
        return (cookie, timeout)
    }
}
