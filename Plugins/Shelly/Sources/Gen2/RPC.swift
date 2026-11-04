import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import Logging

/// What a Gen 2+ device's WebSocket RPC tells its owner.
enum RPCEvent: Sendable {
    case connected
    /// The socket closed; `wasConnected` is false for a connection that never opened.
    case disconnected(reason: String, wasConnected: Bool)
    /// `NotifyStatus`, `NotifyFullStatus` or `NotifyEvent`, with its `params`.
    case notification(method: String, params: JSONValue)
}

enum RPCError: Error, CustomStringConvertible, Equatable {
    case unauthorized
    case invalidPassword
    case unsupportedAuthentication(String)
    case device(code: Int, message: String)
    case timeout
    case connectionClosed
    case notConnected(String)

    var description: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .invalidPassword: "Invalid password"
        case .unsupportedAuthentication(let what): "Unsupported authentication (\(what))"
        case .device(let code, let message): "\(message) (code \(code))"
        case .timeout: "Request timeout"
        case .connectionClosed: "Connection closed"
        case .notConnected(let reason): reason
        }
    }
}

/// The WebSocket client settings of a `ShellyNG` block (`websocket`), in seconds.
struct RPCSettings: Sendable, Equatable {
    var requestTimeout: Double = 10
    /// 0 turns pings off.
    var pingInterval: Double = 60
    /// The n-th consecutive reconnection waits the n-th value, the last one reused; a value of 0 or less stops.
    var reconnectInterval: [Double] = [5, 10, 30, 60, 300, 600]
    /// Multiplies every delay above; tests shorten them.
    var timeScale: Double = 1

    func duration(_ seconds: Double) -> Duration { .milliseconds(Int(saturating: (seconds * timeScale * 1000).rounded()) ?? 0) }

    /// The schedule from a number, an array of numbers or a comma-separated string, as the Homebridge plugin reads it.
    static func reconnectSchedule(_ value: JSONValue?) -> [Double]? {
        switch value {
        case .number(let seconds): [seconds]
        case .array(let items): items.compactMap(\.number)
        case .string(let text): text.split(separator: ",", omittingEmptySubsequences: false).map { Double(Int($0.trimmingCharacters(in: .whitespaces)) ?? 0) }
        default: nil
        }
    }

    /// The wait before attempt `attempt` (0-based), or nil when no reconnection is due.
    func reconnectDelay(attempt: Int) -> Double? {
        guard !reconnectInterval.isEmpty else { return nil }
        let seconds = reconnectInterval[min(attempt, reconnectInterval.count - 1)]
        return seconds > 0 ? seconds : nil
    }
}

/// Digest authentication of Shelly's RPC frames (SHA-256, the fixed user `admin`), as aioshelly does it: a fresh
/// response per request with the nonce count growing, a stale nonce replaced and retried once.
struct RPCDigest: Sendable, Equatable {
    var realm: String
    /// As the device sent it: a JSON number, written back unchanged.
    var nonce: JSONValue
    var nc: Int

    static let user = "admin"
    /// `H("dummy_method:dummy_uri")`, the constant the devices expect.
    static let ha2 = sha256("dummy_method:dummy_uri")

    /// A challenge from a 401's `message` (a JSON string). Throws for another scheme or algorithm.
    init?(challenge message: String) throws(RPCError) {
        guard let challenge = try? JSONValue(string: message), let realm = challenge["realm"]?.stringValue, let nonce = challenge["nonce"], !nonce.isNull else {
            return nil
        }
        let type = challenge["auth_type"]?.stringValue ?? "digest"
        guard type == "digest" else { throw .unsupportedAuthentication(type) }
        let algorithm = challenge["algorithm"]?.stringValue ?? "SHA-256"
        guard algorithm == "SHA-256" else { throw .unsupportedAuthentication(algorithm) }
        self.realm = realm
        self.nonce = nonce
        nc = challenge["nc"]?.intValue ?? 1
    }

    init(realm: String, nonce: JSONValue, nc: Int) {
        self.realm = realm
        self.nonce = nonce
        self.nc = nc
    }

    static func isStale(_ message: String) -> Bool { (try? JSONValue(string: message))?["stale"]?.boolValue == true }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `response` for this nonce count and client nonce.
    func response(password: String, cnonce: String) -> String {
        let ha1 = Self.sha256("\(Self.user):\(realm):\(password)")
        return Self.sha256("\(ha1):\(nonce.decimalText ?? ""):\(nc):\(cnonce):auth:\(Self.ha2)")
    }

    /// The frame's `auth` object; `cnonce` goes as given (a number or a string).
    func auth(password: String, cnonce: JSONValue) -> JSONValue {
        [
            "realm": .string(realm), "username": .string(Self.user), "nonce": nonce, "cnonce": cnonce, "nc": .number(Double(nc)),
            "response": .string(response(password: password, cnonce: cnonce.decimalText ?? "")), "algorithm": "SHA-256",
        ]
    }
}

/// One Gen 2+ device's RPC over its WebSocket at `ws://<host>/rpc`: requests matched to their responses by id, the
/// device's notifications as events, a protocol ping, and reconnection on the `reconnectInterval` schedule.
actor ShellyRPC {
    typealias Connector = @Sendable (URL) async throws -> any WebSocketConnection

    private(set) var host: String
    let clientID: String
    private let password: String?
    private let settings: RPCSettings
    private let connector: Connector
    private let logger: Logger

    let events: AsyncStream<RPCEvent>
    private let continuation: AsyncStream<RPCEvent>.Continuation

    private var socket: (any WebSocketConnection)?
    private var connecting: Task<any WebSocketConnection, any Error>?
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var reconnecting: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var digest: RPCDigest?
    private var stopped = false
    /// The socket we closed after a missed pong: its close reconnects whatever its code.
    private var killed = false
    /// Whether this outage was logged already.
    private var outageLogged = false

    init(host: String, clientID: String, password: String?, settings: RPCSettings, connector: @escaping Connector, logger: Logger) {
        self.host = host
        self.clientID = clientID
        self.password = password?.isEmpty == true ? nil : password
        self.settings = settings
        self.connector = connector
        self.logger = logger
        (events, continuation) = AsyncStream.makeStream(of: RPCEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    var url: URL { URL(string: "ws://\(Self.bracketed(host))/rpc")! }

    static func bracketed(_ host: String) -> String { host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host }

    var isConnected: Bool { socket != nil }

    /// Opens the socket in the background; requests wait for it.
    func start() {
        guard !stopped, socket == nil, connecting == nil else { return }
        reconnecting?.cancel()
        reconnecting = nil
        Task { _ = try? await self.open() }
    }

    /// Moves to another address (a DHCP change mDNS announced): the socket reconnects there.
    func move(to host: String) async {
        guard host != self.host else { return }
        self.host = host
        if let socket {
            killed = true
            await socket.close(code: 1001, reason: "moved")
        } else {
            reconnecting?.cancel()
            reconnecting = nil
            start()
        }
    }

    /// Closes for good: pending requests fail with "Connection closed".
    func stop() async {
        stopped = true
        reconnecting?.cancel()
        pinger?.cancel()
        connecting?.cancel()
        let socket = socket
        self.socket = nil
        failPending(RPCError.connectionClosed)
        await socket?.close(code: 1000, reason: "")
        reader?.cancel()
        continuation.finish()
    }

    // MARK: Requests

    /// Calls `method`, answering a digest challenge with the password, and returns its `result`.
    func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        var challenged = false
        while true {
            let auth = nextAuth()
            let reply = try await send(method, params, auth: auth)
            if let error = reply["error"], !error.isNull {
                let code = error["code"]?.intValue ?? 0
                let message = error["message"]?.stringValue ?? ""
                guard code == 401 else { throw RPCError.device(code: code, message: message) }
                guard let password, !password.isEmpty else { throw RPCError.unauthorized }
                if auth != nil, !RPCDigest.isStale(message) {
                    digest = nil
                    throw RPCError.invalidPassword
                }
                guard !challenged, let challenge = try RPCDigest(challenge: message) else { throw RPCError.invalidPassword }
                challenged = true
                digest = challenge
                continue
            }
            return reply["result"] ?? .null
        }
    }

    private func nextAuth() -> JSONValue? {
        guard let password, var digest else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let auth = digest.auth(password: password, cnonce: .string(Data(bytes).base64EncodedString()))
        digest.nc += 1
        self.digest = digest
        return auth
    }

    /// One frame out, its reply back (the whole frame), or a timeout.
    private func send(_ method: String, _ params: JSONValue?, auth: JSONValue?) async throws -> JSONValue {
        let socket = try await connected()
        let id = nextID
        nextID += 1
        var frame: [String: JSONValue] = ["src": .string(clientID), "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { frame["params"] = params }
        if let auth { frame["auth"] = auth }
        logger.debug("WebSocket: \(method)")
        let timeout = Task { [settings] in
            try? await Task.sleep(for: settings.duration(settings.requestTimeout))
            self.expire(id)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(text: JSONValue.object(frame).text()) } catch { self.fail(id, error) }
            }
        }
    }

    private func expire(_ id: Int) { pending.removeValue(forKey: id)?.resume(throwing: RPCError.timeout) }
    private func fail(_ id: Int, _ error: any Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }

    private func failPending(_ error: any Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: The connection

    private func connected() async throws -> any WebSocketConnection {
        if let socket { return socket }
        guard !stopped else { throw RPCError.connectionClosed }
        return try await open()
    }

    @discardableResult
    private func open() async throws -> any WebSocketConnection {
        if let connecting { return try await connecting.value }
        reconnecting?.cancel()
        reconnecting = nil
        let url = url, connector = connector
        let task = Task { try await connector(url) }
        connecting = task
        do {
            let socket = try await task.value
            connecting = nil
            guard !stopped else {
                await socket.close(code: 1000, reason: "")
                throw RPCError.connectionClosed
            }
            opened(socket)
            return socket
        } catch {
            connecting = nil
            if !stopped { ended(reason: "\(error)", code: nil, wasConnected: false) }
            throw RPCError.notConnected("\(error)")
        }
    }

    private func opened(_ socket: any WebSocketConnection) {
        self.socket = socket
        killed = false
        reconnectAttempt = 0
        outageLogged = false
        logger.info("Device connected")
        continuation.yield(.connected)
        reader = Task { [weak self] in
            var reason = ""
            do {
                for try await message in socket.messages {
                    guard let self, let text = message.text else { continue }
                    await self.handle(text)
                }
            } catch {
                reason = "\(error)"
            }
            await self?.closed(socket, error: reason)
        }
        schedulePing(socket)
    }

    private func schedulePing(_ socket: any WebSocketConnection) {
        pinger?.cancel()
        guard settings.pingInterval > 0 else { return }
        let settings = settings
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: settings.duration(settings.pingInterval))
                guard !Task.isCancelled else { return }
                do {
                    try await socket.ping(timeout: settings.duration(settings.requestTimeout))
                } catch {
                    await self?.kill(socket)
                    return
                }
            }
        }
    }

    /// No pong in time: the socket is dropped as an abnormal close, which reconnects.
    private func kill(_ socket: any WebSocketConnection) async {
        guard self.socket === socket else { return }
        killed = true
        await socket.close(code: 4000, reason: "ping timeout")
    }

    private func closed(_ closing: any WebSocketConnection, error: String) {
        guard socket === closing else { return }
        socket = nil
        pinger?.cancel()
        failPending(RPCError.connectionClosed)
        let code = closing.closeCode
        let reason = closing.closeReason?.nonEmpty ?? (error.isEmpty ? code.map { "\($0)" } ?? "connection lost" : error)
        guard !stopped else { return }
        if code == 1000, !killed {
            continuation.yield(.disconnected(reason: reason, wasConnected: true))
            logger.warning("Device disconnected (reason: \(reason))")
            return
        }
        ended(reason: reason, code: code, wasConnected: true)
    }

    private func ended(reason: String, code: UInt16?, wasConnected: Bool) {
        continuation.yield(.disconnected(reason: reason, wasConnected: wasConnected))
        let level: Logger.Level = outageLogged ? .debug : .warning
        if wasConnected {
            logger.log(level: level, "Device disconnected (reason: \(reason))")
        } else {
            logger.log(level: level, "Connection failed (code: \(code.map { "\($0)" } ?? reason))")
        }
        guard let delay = settings.reconnectDelay(attempt: reconnectAttempt) else { return }
        logger.log(level: outageLogged ? .debug : .info, "Reconnecting in \(Self.describe(seconds: delay))")
        outageLogged = true
        reconnectAttempt += 1
        let settings = settings
        reconnecting?.cancel()
        reconnecting = Task { [weak self] in
            try? await Task.sleep(for: settings.duration(delay))
            guard !Task.isCancelled else { return }
            _ = try? await self?.open()
        }
    }

    static func describe(seconds: Double) -> String {
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if seconds < 60 { return unit(Int(saturating: seconds) ?? 0, "second") }
        if seconds < 3600 { return unit(Int(saturating: seconds / 60) ?? 0, "minute") }
        return unit(Int(saturating: seconds / 3600) ?? 0, "hour")
    }

    // MARK: Frames in

    private func handle(_ text: String) {
        guard let frame = try? JSONValue(string: text) else { return }
        if let id = frame["id"]?.intValue, id != 0 {
            pending.removeValue(forKey: id)?.resume(returning: frame)
            return
        }
        guard let method = frame["method"]?.stringValue else { return }
        continuation.yield(.notification(method: method, params: frame["params"] ?? .null))
    }
}
