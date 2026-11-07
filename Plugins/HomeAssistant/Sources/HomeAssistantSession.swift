import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// What went wrong talking to Home Assistant.
enum HomeAssistantError: Error, CustomStringConvertible, Equatable {
    /// `auth_invalid`: the token was refused (Needs Authorization; never retried in a loop, HA bans IPs).
    case authInvalid(String)
    /// A command's `result` with `success: false`.
    case failed(code: String, message: String)
    /// No answer in time.
    case timeout(String)
    /// The connection closed or dropped.
    case closed(String)
    /// A message that is not what the protocol says.
    case protocolError(String)
    /// The URL is not one Home Assistant can be reached at.
    case invalidURL(String)

    var description: String {
        switch self {
        case .authInvalid(let message): "Home Assistant refused the access token: \(message)"
        case .failed(let code, let message): "Home Assistant answered \(code): \(message)"
        case .timeout(let what): "Home Assistant did not answer \(what) in time"
        case .closed(let reason): "the connection to Home Assistant closed: \(reason)"
        case .protocolError(let reason): "unexpected message from Home Assistant: \(reason)"
        case .invalidURL(let url): "not a Home Assistant address: \(url)"
        }
    }

    /// Whether the command is not available to this token or server (an older version, a non-admin user).
    var isUnavailableCommand: Bool {
        if case .failed(let code, _) = self { return code == "unauthorized" || code == "unknown_command" || code == "not_allowed" }
        return false
    }
}

/// One authenticated WebSocket session with Home Assistant (docs/clean-room/HomeAssistant.md, section 2): commands with
/// strictly increasing ids answered by `result` (or `pong`), subscriptions whose events carry the subscribing id, and
/// frames that may hold one message or an array of them (coalesced messages, 2.7). One reader task reads the socket
/// continuously and never waits on HomeKit: events are handed to the subscriber's closure, which queues them.
actor HomeAssistantSession {
    typealias EventHandler = @Sendable (JSONValue) -> Void

    let socket: any WebSocketConnection
    /// The server's version, from `auth_ok`.
    private(set) var version: String?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var subscriptions: [Int: EventHandler] = [:]
    /// The auth phase's messages (they carry no id), in order, and the one waiting for the next.
    private var authMessages: [JSONValue] = []
    private var authWaiter: CheckedContinuation<JSONValue, any Error>?
    private(set) var closedReason: String?
    private var onClose: (@Sendable (String) -> Void)?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    /// Messages go out in the order their ids were given: HA refuses an id lower than one it has seen (`id_reuse`).
    private let outgoing: AsyncStream<String>.Continuation
    private let outgoingStream: AsyncStream<String>

    init(socket: any WebSocketConnection) {
        self.socket = socket
        (outgoingStream, outgoing) = AsyncStream.makeStream(of: String.self)
    }

    /// Starts reading; `onClose` is called once when the connection ends.
    func start(onClose: @escaping @Sendable (String) -> Void) {
        self.onClose = onClose
        let socket = self.socket
        reader = Task { [weak self] in
            var reason = "closed by Home Assistant"
            do {
                for try await message in socket.messages {
                    guard let text = message.text else { continue }
                    await self?.receive(text)
                }
                if let code = socket.closeCode { reason = "closed by Home Assistant (\(code))" }
            } catch {
                reason = "\(error)"
            }
            await self?.ended(reason)
        }
        let stream = outgoingStream
        writer = Task { [weak self] in
            for await text in stream {
                do {
                    try await socket.send(text: text)
                } catch {
                    await self?.ended("\(error)")
                    return
                }
            }
        }
    }

    /// The auth phase (2.2): `auth_required`, then `auth` with the token, then `auth_ok` or `auth_invalid`.
    func authenticate(token: String, timeout: Duration) async throws {
        let first = try await nextAuthMessage(timeout: timeout)
        if first["type"]?.stringValue == "auth_ok" { return }
        guard first["type"]?.stringValue == "auth_required" else {
            throw HomeAssistantError.protocolError("expected auth_required, got \(first["type"]?.stringValue ?? "?")")
        }
        try await send(["type": "auth", "access_token": .string(token)])
        let answer = try await nextAuthMessage(timeout: timeout)
        switch answer["type"]?.stringValue {
        case "auth_ok":
            version = answer["ha_version"]?.stringValue
        case "auth_invalid":
            throw HomeAssistantError.authInvalid(answer["message"]?.stringValue ?? "invalid access token")
        default:
            throw HomeAssistantError.protocolError("expected auth_ok, got \(answer["type"]?.stringValue ?? "?")")
        }
    }

    /// Sends a command with the next id and waits for its result (`result` on success; a `pong` for a `ping`).
    @discardableResult
    func command(_ fields: [String: JSONValue], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        try await command(fields, timeout: timeout, subscribe: nil)
    }

    /// `subscribe_events` for one event type; `handler` gets each event's `event` object.
    func subscribe(eventType: String, handler: @escaping EventHandler) async throws {
        _ = try await command(["type": "subscribe_events", "event_type": .string(eventType)], timeout: .seconds(30), subscribe: handler)
    }

    private func command(_ fields: [String: JSONValue], timeout: Duration, subscribe: EventHandler?) async throws -> JSONValue {
        if let closedReason { throw HomeAssistantError.closed(closedReason) }
        let id = nextID
        nextID += 1
        var message = fields
        message["id"] = .number(Double(id))
        if let subscribe { subscriptions[id] = subscribe }
        let type = fields["type"]?.stringValue ?? "command"
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(id, HomeAssistantError.timeout(type))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            outgoing.yield(JSONValue.object(message).text())
        }
    }

    private func send(_ fields: [String: JSONValue]) async throws {
        if let closedReason { throw HomeAssistantError.closed(closedReason) }
        outgoing.yield(JSONValue.object(fields).text())
    }

    func close() async {
        reader?.cancel()
        outgoing.finish()
        await socket.close(code: 1000, reason: "")
        ended("closed by the bridge")
    }

    // MARK: Incoming

    private func receive(_ text: String) {
        guard let json = try? JSONValue(string: text) else { return }
        // Coalesced messages: a frame may hold an array of messages (2.7).
        if let list = json.arrayValue {
            for message in list { dispatch(message) }
        } else {
            dispatch(json)
        }
    }

    private func dispatch(_ message: JSONValue) {
        let type = message["type"]?.stringValue
        switch type {
        case "auth_required", "auth_ok", "auth_invalid":
            if let waiter = authWaiter {
                authWaiter = nil
                waiter.resume(returning: message)
            } else {
                authMessages.append(message)
            }
        case "result":
            guard let id = message["id"]?.intValue else { return }
            let continuation = pending.removeValue(forKey: id)
            if message["success"]?.boolValue == true {
                continuation?.resume(returning: message["result"] ?? .null)
            } else {
                subscriptions.removeValue(forKey: id)
                let error = message["error"]
                continuation?.resume(throwing: HomeAssistantError.failed(
                    code: error?["code"]?.stringValue ?? "unknown_error", message: error?["message"]?.stringValue ?? ""))
            }
        case "pong":
            guard let id = message["id"]?.intValue else { return }
            pending.removeValue(forKey: id)?.resume(returning: .null)
        case "event":
            guard let id = message["id"]?.intValue, let handler = subscriptions[id], let event = message["event"] else { return }
            handler(event)
        default:
            break
        }
    }

    private func nextAuthMessage(timeout: Duration) async throws -> JSONValue {
        if !authMessages.isEmpty { return authMessages.removeFirst() }
        if let closedReason { throw HomeAssistantError.closed(closedReason) }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failAuth(HomeAssistantError.timeout("the authentication"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { authWaiter = $0 }
    }

    private func failAuth(_ error: any Error) {
        authWaiter?.resume(throwing: error)
        authWaiter = nil
    }

    private func fail(_ id: Int, _ error: any Error) {
        subscriptions.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func ended(_ reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason
        let error = HomeAssistantError.closed(reason)
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending = [:]
        subscriptions = [:]
        failAuth(error)
        outgoing.finish()
        onClose?(reason)
        onClose = nil
    }
}

/// The WebSocket address of a Home Assistant base URL (2.1): `http` → `ws`, `https` → `wss`, `/api/websocket` appended;
/// a bare host gets port 8123.
enum HomeAssistantURL {
    static let defaultPort = 8123

    /// The base URL as people write it, normalised: a scheme (http by default), no trailing slash, no path.
    static func base(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
            if URLComponents(string: trimmed)?.port == nil { trimmed += ":\(defaultPort)" }
        }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else { return nil }
        switch scheme {
        case "http", "ws": components.scheme = "http"
        case "https", "wss": components.scheme = "https"
        default: return nil
        }
        if components.path.hasSuffix("/api/websocket") { components.path = String(components.path.dropLast("/api/websocket".count)) }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func webSocket(_ text: String) -> URL? {
        guard let base = base(text), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path += "/api/websocket"
        return components.url
    }
}
