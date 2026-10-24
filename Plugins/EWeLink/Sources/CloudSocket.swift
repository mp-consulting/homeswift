import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The WebSocket refused the session: 406 means the token was invalidated (the account logged in elsewhere).
struct SocketAuthenticationError: Error, CustomStringConvertible, Equatable {
    let code: Int
    var description: String { code == 406 ? "AUTH_TOKEN_INVALIDATED" : "Authentication failed: \(code)" }
}

/// The eWeLink WebSocket: authenticates with `userOnline`, routes `update` messages to the platform, sends
/// commands and queries with a sequence number and waits for their answer, keeps the connection alive with
/// pings and reconnects with exponential backoff (5 s doubling to 5 min, ±20 %), logging in again when the
/// session was invalidated. The backoff starts over only after a connection stayed up for a minute: when
/// another client signs in to the same account, each fresh login drops the other's session, and resetting
/// on every successful login made the two take turns every half minute forever. The eWeLink servers have
/// public certificates, so the system's trust is what is needed; the pings are eWeLink's own (`ping` as text,
/// answered with `pong`), not WebSocket pings.
actor CloudSocket {
    /// Opens a WebSocket: `WebSocket.connect` in the plugin, a scripted server in tests.
    typealias Connect = @Sendable (URL, WebSocket.Options) async throws -> any WebSocketConnection

    /// The real WebSocket.
    static let connectWebSocket: Connect = { url, options in try await WebSocket.connect(to: url, options: options) }

    /// Requests already sent when the socket closed: the device may have run them, so they are not resent.
    static let inFlightLostMessage = "WebSocket closed before response"

    struct Dependencies: Sendable {
        var connect: Connect
        var clock: EWeLinkClock
        var random: @Sendable () -> Double
    }

    private let api: CloudAPI
    private let dependencies: Dependencies
    private let logger: Logger
    /// Updates for the platform: device id and parameters.
    private let onUpdate: @Sendable (String, DeviceParams) async -> Void
    /// The API key of a device in the platform's cache, nil when it is not there.
    private let deviceAPIKey: @Sendable (String) async -> String?
    private let displayName: @Sendable (String) async -> String

    private var connection: (any WebSocketConnection)?
    /// Which socket the reader and the heartbeat belong to; an old socket's end is ignored.
    private var generation = 0
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTimer: Task<Void, Never>?
    private var heartbeatInterval = Double(Timing.socketHeartbeat)
    private(set) var reconnecting = false
    private(set) var connected = false
    private(set) var reconnectAttempts = 0
    /// When the current socket authenticated, in plugin milliseconds.
    private var connectedAt: Double?
    /// Set by `disconnect()`: nothing reconnects until `connect()`.
    private(set) var stopped = false
    private var lastMessageAt = 0.0
    private var lastSequence = 0.0
    private var authentication: CheckedContinuation<Void, any Error>?
    private var authenticationID = 0
    private var pending: [String: Pending] = [:]

    private struct Pending {
        var continuation: CheckedContinuation<Bool, any Error>
        var timeout: Task<Void, Never>
    }

    init(
        api: CloudAPI, dependencies: Dependencies, logger: Logger,
        onUpdate: @escaping @Sendable (String, DeviceParams) async -> Void,
        deviceAPIKey: @escaping @Sendable (String) async -> String?,
        displayName: @escaping @Sendable (String) async -> String
    ) {
        self.api = api
        self.dependencies = dependencies
        self.logger = logger
        self.onUpdate = onUpdate
        self.deviceAPIKey = deviceAPIKey
        self.displayName = displayName
    }

    var isConnected: Bool { connected }

    /// Connects in the background: a failure schedules retries until connected or `disconnect()`. Nothing
    /// happens when `disconnect()` came first (the platform stopped before this task ran).
    func start() async {
        guard !stopped else { return }
        do {
            try await openSocket()
        } catch {
            if stopped { return }
            let invalidated = (error as? SocketAuthenticationError)?.code == 406 || "\(error)".contains("AUTH_TOKEN_INVALIDATED")
            logger.warning("WebSocket connection failed: \(error) - retrying in the background")
            scheduleReconnect(forceLogin: invalidated)
        }
    }

    /// Connects now (re-enables reconnects after `disconnect()`).
    func connect() async throws {
        stopped = false
        try await openSocket()
    }

    private func openSocket() async throws {
        let host = await api.socketURL(now: dependencies.clock.nowMilliseconds / 1000)
        if stopped { throw EWeLinkError("WebSocket disconnected") }
        logger.debug("Connecting to WebSocket: \(host)")
        await closeSocket()
        connected = false
        guard let url = URL(string: host) else { throw EWeLinkError("Invalid WebSocket URL \(host)") }
        let socket = try await dependencies.connect(url, WebSocket.Options(timeout: .seconds(30)))
        if stopped {
            await socket.close()
            throw EWeLinkError("WebSocket disconnected")
        }
        generation += 1
        let current = generation
        connection = socket
        logger.debug("WebSocket connection opened")
        reader = Task { [weak self] in
            do {
                for try await message in socket.messages {
                    await self?.received(message.text ?? String(decoding: message.data, as: UTF8.self), generation: current)
                }
                await self?.socketClosed(generation: current, error: nil)
            } catch {
                await self?.socketClosed(generation: current, error: error)
            }
        }
        do {
            try await authenticate(on: socket)
        } catch {
            // Tear the half-open socket down; the caller decides whether to retry.
            if generation == current { await closeSocket() }
            throw error
        }
        // The socket closed, or `disconnect()` ran, while the answer was on its way: nothing would ever notice
        // a socket marked connected that is gone, so the caller retries instead.
        guard generation == current, connection != nil, !stopped else {
            if generation == current { await closeSocket() }
            throw EWeLinkError("WebSocket closed during authentication")
        }
        connected = true
        connectedAt = dependencies.clock.nowMilliseconds
        startHeartbeat()
    }

    /// Stops listening to the current socket and closes it.
    private func closeSocket() async {
        guard let socket = connection else { return }
        connection = nil
        generation += 1
        reader?.cancel()
        reader = nil
        await socket.close()
    }

    private func rejectPending(_ message: String) {
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: EWeLinkError(message))
        }
    }

    /// Unique, increasing sequence numbers in the millisecond-timestamp format.
    func nextSequence() -> String {
        lastSequence = max(dependencies.clock.nowMilliseconds.rounded(.down), lastSequence + 1)
        return lastSequence.jsDescription
    }

    private var isReady: Bool { connected && connection != nil }

    private func authenticate(on socket: any WebSocketConnection) async throws {
        let message: JSONValue = [
            "action": "userOnline", "at": .string(await api.accessToken), "apikey": .string(await api.apiKey),
            "appid": .string(EWeLinkCloud.appID), "nonce": .string(CloudAPI.nonce()),
            "ts": .number((dependencies.clock.nowMilliseconds / 1000).rounded(.down)), "userAgent": "app",
            "sequence": .string(nextSequence()), "version": 8,
        ]
        let clock = dependencies.clock
        authenticationID += 1
        let id = authenticationID
        let timeout = Task {
            do { try await clock.sleep(milliseconds: Double(Timing.socketAuthentication)) } catch { return }
            self.failAuthentication(EWeLinkError("Authentication timeout"), id: id)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // An earlier authentication still waiting would otherwise never end.
            failAuthentication(EWeLinkError("WebSocket authentication superseded"))
            authentication = continuation
            Task {
                do {
                    try await socket.send(text: message.text())
                } catch {
                    self.failAuthentication(error, id: id)
                }
            }
        }
    }

    private func failAuthentication(_ error: any Error, id: Int? = nil) {
        guard let continuation = authentication, id == nil || id == authenticationID else { return }
        authentication = nil
        continuation.resume(throwing: error)
    }

    private func received(_ text: String, generation current: Int) async {
        guard current == generation else { return }
        lastMessageAt = dependencies.clock.nowMilliseconds
        if authentication != nil, let message = try? JSONValue(string: text) {
            if message["error"]?.intValue == 0, let config = message["config"], config.objectValue != nil {
                if let interval = config["hbInterval"]?.jsNumber, interval > 0 { heartbeatInterval = interval * 1000 }
                logger.info("WebSocket authenticated successfully")
                let continuation = authentication
                authentication = nil
                continuation?.resume()
            } else if let code = message["error"]?.intValue, code != 0 {
                if code == 406 {
                    logger.warning("WebSocket authentication failed: Token invalidated (concurrent session detected)")
                }
                failAuthentication(SocketAuthenticationError(code: code))
            }
        }
        await handleMessage(text)
    }

    /// Routes a message: pongs, device updates, Zigbee reports, and the answers to commands and queries.
    func handleMessage(_ text: String) async {
        if text == "pong" {
            logger.debug("Heartbeat pong received")
            return
        }
        guard let message = try? JSONValue(string: text), message.objectValue != nil else {
            logger.debug("Failed to parse WebSocket message: \(text)")
            return
        }
        let action = message["action"]?.stringValue
        if action == "pong" {
            logger.debug("Heartbeat pong received")
            return
        }
        logger.debug("WebSocket message received: \(Self.redacted(message).text())")
        let deviceID = message["deviceid"]?.stringValue
        let params = message["params"]?.objectValue
        if action == "update", let deviceID, let params {
            logger.debug("Device update received: \(deviceID)")
            await onUpdate(deviceID, params)
            return
        }
        if action == "reportSubDevice" || action == "subDevice" {
            // Informational: the sub-devices' state comes in `update` messages.
            logger.debug("Zigbee sub-device report received (\(action ?? ""))")
            return
        }
        guard let sequence = message["sequence"]?.jsString else { return }
        let code = message["error"]?.intValue
        if let request = pending.removeValue(forKey: sequence) {
            request.timeout.cancel()
            if code == 0 {
                logger.debug("Command response received: success (error: 0)")
                if let deviceID, let params {
                    logger.debug("Updating device \(deviceID) with query response params")
                    await onUpdate(deviceID, params)
                }
                request.continuation.resume(returning: true)
            } else {
                let codeText = code.map(String.init) ?? message["error"]?.jsString ?? "undefined"
                logger.error("Command response received: failed (error: \(codeText))")
                request.continuation.resume(throwing: EWeLinkError("Command failed: \(codeText)", code: code))
            }
        } else {
            logger.debug("Received response for unknown sequence: \(sequence)")
            // Answers sometimes come back under another sequence: their parameters still count.
            if code == 0, let deviceID, let params {
                logger.debug("Updating device \(deviceID) from unmatched sequence response")
                await onUpdate(deviceID, params)
            }
        }
    }

    /// The access token never reaches the log.
    private static func redacted(_ message: JSONValue) -> JSONValue {
        guard var object = message.objectValue else { return message }
        for key in ["at", "apikey", "selfApikey"] where object[key] != nil { object[key] = "[REDACTED]" }
        return .object(object)
    }

    // MARK: Commands

    /// Sends a command. False when the socket is not open (nothing was sent); throws on a timeout, an error
    /// from the server, or when the socket closed before the answer.
    func sendCommand(_ deviceID: String, params: DeviceParams) async throws -> Bool {
        guard isReady, let socket = connection else {
            logger.warning("Cannot send command to \(deviceID): WebSocket not ready")
            return false
        }
        let parent = DeviceLimits.parentDeviceID(deviceID)
        guard let deviceKey = await deviceAPIKey(parent) else {
            logger.warning("Cannot send command to \(deviceID): Device not in cache")
            return false
        }
        let sequence = nextSequence()
        let message: JSONValue = [
            "action": "update", "deviceid": .string(parent), "apikey": .string(deviceKey), "selfApikey": .string(await api.apiKey),
            "params": .object(params), "sequence": .string(sequence), "userAgent": "app",
        ]
        logger.debug("Sending WebSocket command to \(deviceID): \(JSONValue.object(params).text())")
        return try await request(sequence: sequence, message: message, on: socket, timeoutMessage: "Command timeout") {
            self.logger.warning("Command timeout for \(deviceID)")
        }
    }

    /// Asks the device for its state; the answer reaches the platform as an update.
    func queryDeviceState(_ deviceID: String) async throws -> Bool {
        let name = await displayName(deviceID)
        guard isReady, let socket = connection else {
            logger.warning("Cannot query device \(name): WebSocket not connected")
            return false
        }
        let key = await api.apiKey
        guard !key.isEmpty else {
            logger.warning("Cannot query device \(name): No API key available")
            return false
        }
        let sequence = nextSequence()
        let message: JSONValue = [
            "action": "query", "apikey": .string(key), "deviceid": .string(deviceID), "params": [], "sequence": .string(sequence),
            "ts": 0, "userAgent": "app",
        ]
        logger.debug("Querying device state for \(name)")
        return try await request(sequence: sequence, message: message, on: socket, timeoutMessage: "Query timeout") {
            self.logger.warning("Query timeout for \(name)")
        }
    }

    private func request(
        sequence: String, message: JSONValue, on socket: any WebSocketConnection, timeoutMessage: String,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> Bool {
        let clock = dependencies.clock
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            let timeout = Task {
                try? await clock.sleep(milliseconds: Double(Timing.socketCommand))
                guard !Task.isCancelled else { return }
                self.expire(sequence, message: timeoutMessage, onTimeout: onTimeout)
            }
            pending[sequence] = Pending(continuation: continuation, timeout: timeout)
            let text = message.text()
            Task {
                do {
                    try await socket.send(text: text)
                } catch {
                    self.failSend(sequence, error: error)
                }
            }
        }
    }

    private func expire(_ sequence: String, message: String, onTimeout: @Sendable () -> Void) {
        guard let request = pending.removeValue(forKey: sequence) else { return }
        onTimeout()
        request.continuation.resume(throwing: EWeLinkError(message))
    }

    private func failSend(_ sequence: String, error: any Error) {
        guard let request = pending.removeValue(forKey: sequence) else { return }
        request.timeout.cancel()
        logger.error("Failed to send WebSocket message: \(error)")
        request.continuation.resume(throwing: error)
    }

    // MARK: Liveness

    private func startHeartbeat() {
        stopHeartbeat()
        lastMessageAt = dependencies.clock.nowMilliseconds
        let clock = dependencies.clock, current = generation
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.heartbeatInterval else { return }
                do { try await clock.sleep(milliseconds: interval) } catch { return }
                await self?.beat(generation: current)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// Nothing heard for two intervals: the connection is dead even if TCP has not noticed.
    private func beat(generation current: Int) async {
        guard current == generation, connected, let socket = connection else { return }
        let silence = dependencies.clock.nowMilliseconds - lastMessageAt
        if silence > heartbeatInterval * 2 {
            logger.warning("WebSocket silent for \(Int((silence / 1000).rounded()))s, reconnecting...")
            await socket.close()
            return
        }
        do {
            try await socket.send(text: "ping")
            logger.debug("Heartbeat ping sent")
        } catch {
            logger.debug("Heartbeat ping failed: \(error)")
        }
    }

    private func socketClosed(generation current: Int, error: (any Error)?) {
        guard current == generation else { return }
        logger.debug("WebSocket closed\(error.map { ": \($0)" } ?? "")")
        let wasConnected = connected
        connected = false
        connection = nil
        stopHeartbeat()
        failAuthentication(EWeLinkError("WebSocket closed during authentication"))
        rejectPending(Self.inFlightLostMessage)
        // A socket that closes while connecting is the opener's to retry.
        guard wasConnected, !stopped else { return }
        let uptime = connectedAt.map { dependencies.clock.nowMilliseconds - $0 } ?? 0
        connectedAt = nil
        if uptime >= Double(Timing.socketStableConnection) {
            reconnectAttempts = 0
        } else if reconnectAttempts > 0 {
            logger.warning("WebSocket dropped \((uptime / 1000).rounded().clampedInt)s after connecting, again: backing off (is the account signed in elsewhere, in the eWeLink app or another bridge?)")
        }
        scheduleReconnect(forceLogin: false)
    }

    /// The delay before reconnection attempt `attempt` (1-based): 5 s doubling, at most 5 min, ±20 %.
    static func reconnectDelay(attempt: Int, random: Double) -> Double {
        reconnectBackoff.milliseconds(attempt: attempt - 1, random: random)
    }

    private static let reconnectBackoff = Backoff(
        initial: .milliseconds(Timing.socketReconnect), maximum: .milliseconds(Timing.socketReconnectMaximum),
        jitter: .proportional(Timing.socketReconnectJitter))

    private func scheduleReconnect(forceLogin: Bool) {
        guard !reconnecting, !stopped else { return }
        reconnecting = true
        reconnectAttempts += 1
        if reconnectAttempts == Timing.socketMaxReconnectAttempts + 1 {
            logger.error("WebSocket still disconnected after \(Timing.socketMaxReconnectAttempts) attempts. Will keep retrying every ~\(Timing.socketReconnectMaximum / 1000)s - please check your credentials and network.")
        }
        let delay = Self.reconnectDelay(attempt: reconnectAttempts, random: dependencies.random())
        logger.info("Scheduling WebSocket reconnection attempt \(reconnectAttempts) in \(Int(jsRound(delay / 1000)))s...")
        let clock = dependencies.clock
        reconnectTimer = Task { [weak self] in
            do { try await clock.sleep(milliseconds: delay) } catch { return }
            await self?.reconnect(forceLogin: forceLogin)
        }
    }

    private func reconnect(forceLogin: Bool) async {
        reconnectTimer = nil
        if stopped {
            reconnecting = false
            return
        }
        logger.info("Attempting to reconnect to WebSocket...")
        do {
            if forceLogin {
                logger.info("Performing fresh login due to token invalidation...")
                try await api.login()
            } else {
                logger.debug("Reloading tokens from storage before reconnect...")
                await api.reloadTokensFromStorage()
            }
            if stopped {
                reconnecting = false
                return
            }
            try await openSocket()
            reconnecting = false
        } catch {
            if stopped {
                reconnecting = false
                return
            }
            let invalidated = (error as? SocketAuthenticationError)?.code == 406 || "\(error)".contains("AUTH_TOKEN_INVALIDATED")
            if invalidated {
                logger.error("Reconnection failed: Token invalidated. This usually means you logged in elsewhere. Will retry with fresh login...")
            } else {
                logger.error("Reconnection failed: \(error)")
            }
            reconnecting = false
            scheduleReconnect(forceLogin: invalidated)
        }
    }

    /// Closes the socket and stops reconnecting; pending requests fail.
    func disconnect() async {
        stopped = true
        connectedAt = nil
        reconnecting = false
        stopHeartbeat()
        reconnectTimer?.cancel()
        reconnectTimer = nil
        await closeSocket()
        connected = false
        failAuthentication(EWeLinkError("WebSocket disconnected"))
        rejectPending("WebSocket disconnected")
    }
}
