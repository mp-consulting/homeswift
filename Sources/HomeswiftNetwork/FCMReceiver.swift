import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The credentials of an FCM web-push registration, in the shape docs/clean-room/FCMReceiver.md (3.2) gives: the
/// web-push keys, the Android check-in and GCM registration, the Firebase installation and the FCM token, and the
/// configuration they were made for. The consumer keeps them (they hold a private key: a secret) and gives them back.
public struct FCMCredentials: Codable, Sendable, Equatable {
    public struct Keys: Codable, Sendable, Equatable {
        public var privateKey: String
        public var publicKey: String
        public var authSecret: String
    }

    public struct GCM: Codable, Sendable, Equatable {
        public var androidId: String
        public var securityToken: String
        public var appId: String
        public var token: String
    }

    public struct Installation: Codable, Sendable, Equatable {
        public var fid: String
        public var refreshToken: String
        public var token: String
        /// Milliseconds since 1970 when `token` was obtained.
        public var createdAt: Double
        /// Its lifetime in milliseconds.
        public var expiresIn: Double
    }

    public struct FCM: Codable, Sendable, Equatable {
        public var token: String
        public var installation: Installation
    }

    public struct Fingerprint: Codable, Sendable, Equatable {
        public var bundleId: String
        public var projectId: String
        public var vapidKey: String
    }

    public var keys: Keys
    public var gcm: GCM
    public var fcm: FCM
    public var config: Fingerprint

    /// The token the vendor's cloud sends pushes to.
    public var token: String { fcm.token }

    /// The receiver's keys for decryption; nil when they do not parse.
    var webPushKeys: WebPushDecryption.Keys? {
        guard let raw = WebPushDecryption.base64URLDecode(keys.privateKey), let secret = WebPushDecryption.base64URLDecode(keys.authSecret),
              let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: Self.leftPadded(raw, to: 32)) else { return nil }
        return WebPushDecryption.Keys(privateKey: privateKey, authSecret: secret)
    }

    static func leftPadded(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        bytes.count >= count ? bytes : [UInt8](repeating: 0, count: count - bytes.count) + bytes
    }
}

/// A decrypted push: its persistent id and the JSON the sender sent (FCM's message: `data`, `from`, `priority`…).
public struct FCMMessage: Sendable, Equatable {
    public var persistentID: String
    public var payload: Data
    /// The message's `data`: the sender's string values by key, read once.
    public var data: [String: String]

    /// nil when the payload is not a JSON object.
    public init?(persistentID: String, payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        self.persistentID = persistentID
        self.payload = payload
        data = (object["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }
}

/// A byte pipe to the MCS server: TLS in the receiver, in memory in tests.
public protocol FCMConnection: Sendable {
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

extension MQTTSocketTransport: FCMConnection {}

/// An FCM receiver registered as a Chrome browser's web-push subscriber, as `@eneris/push-receiver` (the library
/// Ring's and other vendors' Homebridge plugins use) behaves: the registration (Android check-in, GCM register, a
/// Firebase installation, an FCM registration), then a persistent MCS connection over TLS to `mtalk.google.com:5228`
/// whose data messages it decrypts (`aesgcm`), deduplicates and delivers; heartbeats keep it alive, and it reconnects
/// with a linear delay when it drops. Written from docs/clean-room/FCMReceiver.md.
///
/// ```swift
/// let receiver = FCMReceiver(configuration: .init(apiKey: key, projectID: "my-project", appID: appID), credentials: stored)
/// Task { for await event in receiver.events { … } }   // .credentialsChanged: store them; .message: handle it
/// await receiver.start()
/// ```
public actor FCMReceiver {
    public struct Configuration: Sendable {
        public var apiKey: String
        public var projectID: String
        public var appID: String
        /// Kept for the record: the web-push registration does not send it.
        public var messagingSenderID: String?
        public var bundleID = "receiver.push.com"
        /// Empty: the registration uses FCM's default sender key.
        public var vapidKey = ""
        public var chromeVersion = "94.0.4606.51"
        public var chromePlatform = 2
        public var chromeChannel = 1
        public var timeZone = "Europe/Prague"
        /// Zero turns heartbeats off.
        public var heartbeatInterval: Duration = .seconds(300)

        public init(apiKey: String, projectID: String, appID: String, messagingSenderID: String? = nil) {
            self.apiKey = apiKey
            self.projectID = projectID
            self.appID = appID
            self.messagingSenderID = messagingSenderID
        }

        var fingerprint: FCMCredentials.Fingerprint {
            FCMCredentials.Fingerprint(bundleId: bundleID, projectId: projectID, vapidKey: vapidKey)
        }
    }

    public enum Event: Sendable {
        /// New credentials (a registration, a refreshed installation token): the consumer stores them.
        case credentialsChanged(FCMCredentials)
        /// The login was answered: pushes arrive from now on.
        case ready
        case message(FCMMessage)
        /// The connection closed or failed; the receiver reconnects by itself.
        case disconnected(String)
    }

    /// The waits of the protocol; tests shorten them.
    public struct Timing: Sendable {
        /// Between attempts of a request whose server answered an error: attempt × this, at most 3 × this.
        public var httpRetry: Duration = .seconds(5)
        /// After a request that got no answer at all.
        public var networkRetry: Duration = .seconds(10)
        public var gcmRetry: Duration = .seconds(1)
        /// The reconnection delay grows by this each attempt, up to 15 times it.
        public var reconnect: Duration = .seconds(1)
        public var requestTimeout: Duration = .seconds(20)
        public var connectTimeout: Duration = .seconds(20)

        public init() {}
    }

    public static let defaultHost = "mtalk.google.com"
    public static let defaultPort = 5228
    /// FCM's public web-push server key, the GCM register's `sender` when there is no VAPID key.
    public static let defaultSenderKey = "BDOU99-h67HcA6JeFXHbSNMu7e2yNNu3RzoMj8TM4W88jITfq7ZmPvIM1Iv-4_l2LxQcYwhqby2xGpWwzjfAnG4"
    /// The `x-firebase-client` header: base64 of `{"heartbeats":[],"version":2}`.
    static let firebaseClient = "eyJoZWFydGJlYXRzIjpbXSwidmVyc2lvbiI6Mn0="
    static let sdkVersion = "w:0.6.6"
    /// The persistent ids remembered to drop a message delivered twice.
    static let deduplicationLimit = 1000

    public let configuration: Configuration
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let http: any HTTPSending
    private let connect: @Sendable () async throws -> any FCMConnection
    private let timing: Timing
    private let logger: Logger
    private var credentials: FCMCredentials?
    /// Ids of messages delivered and not yet acknowledged by a login: sent at the next one.
    private var unacknowledged: [String]
    /// Ids of messages delivered, the oldest first, for deduplication.
    private var recent: [String]
    private var recentSet: Set<String>
    private var streamID: Int32 = 0
    private var reportedStreamID: Int32 = -1
    private var runner: Task<Void, Never>?

    public init(
        configuration: Configuration, credentials: FCMCredentials? = nil, persistentIDs: [String] = [], http: any HTTPSending = HTTPClient(),
        timing: Timing = Timing(), logger: Logger = Logger(label: "homeswift.fcm"),
        connect: (@Sendable () async throws -> any FCMConnection)? = nil
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.unacknowledged = persistentIDs
        self.recent = persistentIDs
        self.recentSet = Set(persistentIDs)
        self.http = http
        self.timing = timing
        self.logger = logger
        let connectTimeout = timing.connectTimeout
        self.connect = connect ?? {
            try await MQTTSocketTransport.connect(
                host: FCMReceiver.defaultHost, port: FCMReceiver.defaultPort, tls: .system, timeout: connectTimeout,
                group: MultiThreadedEventLoopGroup.singleton)
        }
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(100))
    }

    /// The token to give the vendor's cloud, once registered.
    public var token: String? { credentials?.fcm.token }

    /// Registers when needed, then connects and stays connected until `stop()`.
    public func start() {
        guard runner == nil else { return }
        runner = Task { await self.run() }
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        continuation.finish()
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            var connection: (any FCMConnection)?
            do {
                try await prepareCredentials()
                let opened = try await connect()
                connection = opened
                attempt = 0
                try await session(opened)
                continuation.yield(.disconnected("the server closed the connection"))
            } catch is CancellationError {
                await connection?.close()
                return
            } catch {
                if Task.isCancelled { await connection?.close(); return }
                logger.warning("Push connection failed: \(error)")
                continuation.yield(.disconnected("\(error)"))
            }
            await connection?.close()
            attempt += 1
            do { try await Task.sleep(for: timing.reconnect * min(attempt, 15)) } catch { return }
        }
    }

    // MARK: Registration

    /// Registers from scratch when there are no credentials for this configuration; otherwise checks in again and
    /// refreshes the installation token when it expires (best effort).
    func prepareCredentials() async throws {
        if let credentials, credentials.config == configuration.fingerprint, credentials.webPushKeys != nil {
            if let androidID = UInt64(credentials.gcm.androidId), let securityToken = UInt64(credentials.gcm.securityToken) {
                _ = try? await checkin(androidID: androidID, securityToken: securityToken)
            }
            if Self.isExpired(credentials.fcm.installation, now: Date()) {
                do {
                    var renewed = credentials
                    renewed.fcm.installation = try await refreshInstallation(credentials.fcm.installation)
                    self.credentials = renewed
                    continuation.yield(.credentialsChanged(renewed))
                } catch {
                    logger.debug("Could not refresh the Firebase installation token: \(error)")
                }
            }
            return
        }
        let registered = try await register()
        credentials = registered
        unacknowledged = []
        continuation.yield(.credentialsChanged(registered))
    }

    static func isExpired(_ installation: FCMCredentials.Installation, now: Date) -> Bool {
        guard installation.createdAt > 0, installation.expiresIn > 0 else { return true }
        return installation.createdAt + installation.expiresIn - 3_600_000 <= now.timeIntervalSince1970 * 1000
    }

    /// A full registration: new keys, a new Android id, new tokens.
    func register() async throws -> FCMCredentials {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let secret = Self.randomBytes(16)
        let checkin = try await checkin(androidID: nil, securityToken: nil)
        let appID = "wp:\(configuration.bundleID)#\(UUID().uuidString.lowercased())"
        let gcmToken = try await gcmRegister(androidID: checkin.androidID, securityToken: checkin.securityToken, appID: appID)
        let installation = try await createInstallation()
        let keys = FCMCredentials.Keys(
            privateKey: WebPushDecryption.base64URLEncode(privateKey.rawRepresentation),
            publicKey: WebPushDecryption.base64URLEncode(privateKey.publicKey.x963Representation),
            authSecret: WebPushDecryption.base64URLEncode(secret))
        let token = try await fcmRegister(keys: keys, gcmToken: gcmToken, installationToken: installation.token)
        return FCMCredentials(
            keys: keys,
            gcm: .init(androidId: String(checkin.androidID), securityToken: String(checkin.securityToken), appId: appID, token: gcmToken),
            fcm: .init(token: token, installation: installation), config: configuration.fingerprint)
    }

    func checkin(androidID: UInt64?, securityToken: UInt64?) async throws -> (androidID: UInt64, securityToken: UInt64) {
        let body = FCMProtocol.checkinRequest(
            androidID: androidID, securityToken: securityToken, chromeVersion: configuration.chromeVersion,
            platform: configuration.chromePlatform, channel: configuration.chromeChannel, style: .chrome(timeZone: configuration.timeZone))
        let response = try await send(HTTPRequest(
            method: "POST", url: URL(string: "https://android.clients.google.com/checkin")!,
            headers: [("Content-Type", "application/x-protobuf")], body: Data(body), timeout: timing.requestTimeout))
        guard let parsed = FCMProtocol.checkinResponse(Array(response.body)) else { throw FCMError.registration("the check-in answered no Android id") }
        return parsed
    }

    /// The GCM token; a body with `Error` is retried after a second, five times.
    func gcmRegister(androidID: UInt64, securityToken: UInt64, appID: String) async throws -> String {
        let body = Self.gcmRegisterBody(appID: appID, androidID: String(androidID), sender: configuration.vapidKey.isEmpty ? Self.defaultSenderKey : configuration.vapidKey)
        let request = HTTPRequest(
            method: "POST", url: URL(string: "https://android.clients.google.com/c2dm/register3")!,
            headers: [("Authorization", "AidLogin \(androidID):\(securityToken)"), ("Content-Type", "application/x-www-form-urlencoded")],
            body: Data(body.utf8), timeout: timing.requestTimeout)
        var lastError = "no answer"
        for attempt in 0...5 {
            if attempt > 0 { try await Task.sleep(for: timing.gcmRetry) }
            let response = try await send(request)
            let text = String(decoding: response.body, as: UTF8.self)
            if text.contains("Error") {
                lastError = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "token" { return String(parts[1]) }
            lastError = "an unexpected answer"
        }
        throw FCMError.registration("GCM register has failed: \(lastError)")
    }

    static func gcmRegisterBody(appID: String, androidID: String, sender: String) -> String {
        URLEncoding.form([("app", "org.chromium.linux"), ("X-subtype", appID), ("device", androidID), ("sender", sender)])
    }

    /// A new Firebase installation for a random FID.
    func createInstallation() async throws -> FCMCredentials.Installation {
        let body: [String: Any] = ["appId": configuration.appID, "authVersion": "FIS_v2", "fid": Self.generateFID(), "sdkVersion": Self.sdkVersion]
        let response = try await send(HTTPRequest(
            method: "POST", url: URL(string: "https://firebaseinstallations.googleapis.com/v1/projects/\(configuration.projectID)/installations")!,
            headers: firebaseHeaders(), body: try JSONSerialization.data(withJSONObject: body), timeout: timing.requestTimeout))
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let fid = object["fid"] as? String, let refreshToken = object["refreshToken"] as? String,
              let auth = object["authToken"] as? [String: Any], let token = auth["token"] as? String else {
            throw FCMError.registration("the Firebase installation answered no token")
        }
        return .init(fid: fid, refreshToken: refreshToken, token: token, createdAt: Date().timeIntervalSince1970 * 1000,
                     expiresIn: Self.seconds(auth["expiresIn"]) * 1000)
    }

    func refreshInstallation(_ installation: FCMCredentials.Installation) async throws -> FCMCredentials.Installation {
        let fid = installation.fid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? installation.fid
        let body: [String: Any] = ["installation": ["sdkVersion": Self.sdkVersion, "appId": configuration.appID]]
        let response = try await send(HTTPRequest(
            method: "POST",
            url: URL(string: "https://firebaseinstallations.googleapis.com/v1/projects/\(configuration.projectID)/installations/\(fid)/authTokens:generate")!,
            headers: [("Authorization", "FIS_v2 \(installation.refreshToken)")] + firebaseHeaders(),
            body: try JSONSerialization.data(withJSONObject: body), timeout: timing.requestTimeout))
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let token = object["token"] as? String,
              Self.seconds(object["expiresIn"]) > 0 else {
            throw FCMError.registration("the installation token refresh answered no token")
        }
        var renewed = installation
        renewed.token = token
        renewed.createdAt = Date().timeIntervalSince1970 * 1000
        renewed.expiresIn = Self.seconds(object["expiresIn"]) * 1000
        return renewed
    }

    /// The FCM token for these web-push keys.
    func fcmRegister(keys: FCMCredentials.Keys, gcmToken: String, installationToken: String) async throws -> String {
        var web: [String: Any] = ["auth": keys.authSecret, "endpoint": "https://fcm.googleapis.com/fcm/send/\(gcmToken)", "p256dh": keys.publicKey]
        if !configuration.vapidKey.isEmpty { web["applicationPubKey"] = configuration.vapidKey }
        let response = try await send(HTTPRequest(
            method: "POST", url: URL(string: "https://fcmregistrations.googleapis.com/v1/projects/\(configuration.projectID)/registrations")!,
            headers: [("x-goog-api-key", configuration.apiKey), ("x-goog-firebase-installations-auth", installationToken), ("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: ["web": web]), timeout: timing.requestTimeout))
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        if let error = object?["error"] as? [String: Any] { throw FCMError.registration("FCM registration failed: \(error["message"] as? String ?? "an error")") }
        guard let token = object?["token"] as? String else { throw FCMError.registration("FCM registration answered no token") }
        return token
    }

    private func firebaseHeaders() -> [(name: String, value: String)] {
        [("x-goog-api-key", configuration.apiKey), ("x-firebase-client", Self.firebaseClient), ("Content-Type", "application/json")]
    }

    /// `"604800s"` (or a number) as seconds.
    static func seconds(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let text = value as? String { return Double(text.hasSuffix("s") ? String(text.dropLast()) : text) ?? 0 }
        return 0
    }

    /// Bytes from the system's CSPRNG.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// A Firebase installation id: 17 random bytes, the first's high nibble `0111`, base64url, 22 characters.
    static func generateFID() -> String {
        var bytes = randomBytes(17)
        bytes[0] = 0x70 | (bytes[0] & 0x0F)
        return String(WebPushDecryption.base64URLEncode(bytes).prefix(22))
    }

    /// A request with the receiver's retries: no answer waits 10 s and tries again (until cancelled); an error status
    /// is tried again after 0, 5 and 10 s, then fails.
    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.debug("No answer from \(request.url.host ?? "Google"): \(error)")
                try await Task.sleep(for: timing.networkRetry)
                continue
            }
            if response.isSuccess { return response }
            guard attempt < 3 else { throw FCMError.registration("\(request.url.host ?? "Google") answered HTTP \(response.status)") }
            try await Task.sleep(for: timing.httpRetry * min(attempt, 3))
            attempt += 1
        }
    }

    // MARK: The MCS connection

    /// One connection: the login, then messages until it closes (returns) or fails (throws).
    private func session(_ connection: any FCMConnection) async throws {
        guard let credentials, let keys = credentials.webPushKeys else { throw FCMError.registration("no credentials") }
        reportedStreamID = -1
        let interval = configuration.heartbeatInterval
        let milliseconds = Int(interval.components.seconds * 1000)
        try await connection.send(FCMProtocol.loginFrame(
            androidID: credentials.gcm.androidId, securityToken: credentials.gcm.securityToken, chromeVersion: configuration.chromeVersion,
            persistentIDs: unacknowledged, heartbeatIntervalMilliseconds: milliseconds))
        let activity = NIOLockedValueBox(ContinuousClock.now)
        let dead = NIOLockedValueBox(false)
        let heartbeat: Task<Void, Never>? = interval > .zero ? Task { [weak self] in
            // A ping after an interval of silence; the connection is dead when nothing arrived for an interval after
            // it (a ping sent does not count: a half-open connection takes it without an error).
            var lastPing: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval / 4)
                let now = ContinuousClock.now
                let received = activity.withLockedValue { $0 }
                if let lastPing, received < lastPing {
                    if now - lastPing >= interval {
                        dead.withLockedValue { $0 = true }
                        await connection.close()
                        return
                    }
                } else if now - received >= interval, let ping = await self?.pingFrame() {
                    try? await connection.send(ping)
                    lastPing = now
                }
            }
        } : nil
        defer { heartbeat?.cancel() }
        var parser = MCSFrameParser()
        for try await bytes in connection.incoming {
            activity.withLockedValue { $0 = ContinuousClock.now }
            for (tag, body) in try parser.feed(bytes) {
                if try await handle(tag, body, keys: keys, connection: connection) == false { return }
            }
        }
        if dead.withLockedValue({ $0 }) { throw FCMError.heartbeatTimeout }
    }

    private func pingFrame() -> [UInt8] {
        FCMProtocol.heartbeat(.heartbeatPing, lastStreamIDReceived: newStreamID())
    }

    /// The stream id to report, when it changed since the last report.
    private func newStreamID() -> Int32? {
        guard streamID != reportedStreamID else { return nil }
        reportedStreamID = streamID
        return streamID
    }

    /// Handles one message; false for the server's Close.
    private func handle(_ tag: FCMProtocol.Tag, _ body: [UInt8], keys: WebPushDecryption.Keys, connection: any FCMConnection) async throws -> Bool {
        defer { if tag != .streamErrorStanza { streamID &+= 1 } }
        switch tag {
        case .heartbeatPing:
            let status = ProtobufMessage(body).map { Int64(bitPattern: $0.uint64(3)) }
            try await connection.send(FCMProtocol.heartbeat(.heartbeatAck, lastStreamIDReceived: newStreamID(), status: status))
        case .heartbeatAck, .loginRequest, .iqStanza:
            break
        case .loginResponse:
            unacknowledged = []
            continuation.yield(.ready)
        case .close:
            return false
        case .streamErrorStanza:
            logger.debug("Push stream error: \(ProtobufMessage(body)?.string(1) ?? "")")
        case .dataMessageStanza:
            guard let message = FCMProtocol.DataMessage(body) else { return true }
            let id = message.persistentID ?? ""
            if !id.isEmpty, recentSet.contains(id) { return true }
            guard let raw = message.rawData else {
                logger.debug("Dropped a push without an encrypted payload")
                return true
            }
            do {
                let plaintext = try WebPushDecryption.decrypt(raw, appData: message.appData, keys: keys)
                guard let decoded = FCMMessage(persistentID: id, payload: Data(plaintext)) else {
                    logger.debug("Dropped a push that is not JSON")
                    return true
                }
                remember(id)
                continuation.yield(.message(decoded))
            } catch {
                logger.debug("Dropped a push that does not decrypt: \(error)")
            }
        }
        return true
    }

    private func remember(_ id: String) {
        guard !id.isEmpty else { return }
        // Trimmed by half once twice the limit, not by one on every message.
        unacknowledged.append(id)
        if unacknowledged.count > 2 * Self.deduplicationLimit { unacknowledged.removeFirst(Self.deduplicationLimit) }
        recent.append(id)
        recentSet.insert(id)
        if recent.count > 2 * Self.deduplicationLimit {
            for old in recent.prefix(Self.deduplicationLimit) { recentSet.remove(old) }
            recent.removeFirst(Self.deduplicationLimit)
        }
    }
}

public enum FCMError: Error, CustomStringConvertible, Equatable {
    case registration(String)
    case heartbeatTimeout

    public var description: String {
        switch self {
        case .registration(let text): text
        case .heartbeatTimeout: "the push server stopped answering heartbeats"
        }
    }
}
