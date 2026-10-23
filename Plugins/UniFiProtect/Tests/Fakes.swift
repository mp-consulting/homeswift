import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Collects log lines, to check what the plugin says.
final class LogCapture: LogHandler, @unchecked Sendable {
    private let lines = NIOLockedValueBox<[(Logger.Level, String)]>([])
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lines.withLockedValue { $0.append((event.level, "\(event.message)")) }
    }

    var messages: [String] { lines.withLockedValue { $0.map(\.1) } }
    func messages(at level: Logger.Level) -> [String] { lines.withLockedValue { $0.filter { $0.0 == level }.map(\.1) } }
    func contains(_ text: String) -> Bool { messages.contains { $0.contains(text) } }

    var logger: Logger {
        var logger = Logger(label: "protect-test") { _ in self }
        logger.logLevel = .trace
        return logger
    }
}

/// A UniFi Protect controller in memory: the login with its CSRF dance, the bootstrap, device PATCHes, the
/// endpoints of a camera, and the TLS behaviour of a self-signed console.
final class FakeController: ProtectHTTPTransport, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var path: String
        var query: String?
        var headers: [String: String]
        var body: Data?
        var tls: HTTPClient.TLS
    }

    static let fingerprint = String(repeating: "ab", count: 32)
    static let otherFingerprint = String(repeating: "cd", count: 32)

    struct State {
        var bootstrap: JSONValue
        var requests: [Seen] = []
        var requireCSRF = false
        var password = "secret"
        var certificate = FakeController.fingerprint
        /// Responds with this status to everything (a controller in trouble).
        var failEverything: Int?
        /// Statuses for the next requests to a path, in order.
        var scripted: [String: [Int]] = [:]
        var patchStatus = 200
        var lux = 42.0
        /// Requests whose path ends so wait this long before their answer (a slow controller).
        var delays: [String: Duration] = [:]
    }

    let state: NIOLockedValueBox<State>

    init(bootstrap: JSONValue = Fixtures.bootstrap()) {
        state = NIOLockedValueBox(State(bootstrap: bootstrap))
    }

    var requests: [Seen] { state.withLockedValue { $0.requests } }
    func requests(_ path: String) -> [Seen] { requests.filter { $0.path == path } }

    func update(_ change: (inout State) -> Void) { state.withLockedValue(change) }

    func send(_ request: HomeswiftNetwork.HTTPRequest, tls: HTTPClient.TLS) async throws -> HomeswiftNetwork.HTTPResponse {
        let certificate = state.withLockedValue { $0.certificate }
        // The certificate check happens in the TLS handshake: nothing is sent to a console that fails it.
        if case .pinned(let pinned) = tls, HTTPClient.normalizeFingerprint(pinned) != certificate {
            throw HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(pinned), observed: certificate)
        }
        if tls == .system, request.url.scheme == "https" {
            throw HTTPClientError.cannotConnect(host: request.url.host ?? "", port: 443, code: nil, reason: "certificate verify failed")
        }
        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name.lowercased()] = value }
        let seen = Seen(method: request.method, path: request.url.path.isEmpty ? "/" : request.url.path, query: request.url.query, headers: headers, body: request.body, tls: tls)
        let delay = state.withLockedValue { state in state.delays.first { seen.path.hasSuffix($0.key) }?.value }
        var response = state.withLockedValue { state -> HomeswiftNetwork.HTTPResponse in
            state.requests.append(seen)
            if let status = state.failEverything { return HomeswiftNetwork.HTTPResponse(status: status) }
            if var scripted = state.scripted[seen.path], !scripted.isEmpty {
                let status = scripted.removeFirst()
                state.scripted[seen.path] = scripted
                if status != 200 { return HomeswiftNetwork.HTTPResponse(status: status) }
            }
            return route(seen, &state)
        }
        response.certificateFingerprint = certificate
        // Recorded at once, answered late.
        if let delay { try await Task.sleep(for: delay) }
        return response
    }

    private func route(_ request: Seen, _ state: inout State) -> HomeswiftNetwork.HTTPResponse {
        let json = { (value: JSONValue) in HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: value.encoded()) }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("X-CSRF-Token", "csrf-1")], body: Data("<html></html>".utf8))
        case ("POST", "/api/auth/login"):
            guard !state.requireCSRF || request.headers["x-csrf-token"] != nil else { return HomeswiftNetwork.HTTPResponse(status: 401) }
            let body = request.body.flatMap { try? JSONValue(data: $0) }
            guard body?.string("password") == state.password else { return HomeswiftNetwork.HTTPResponse(status: 401) }
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Set-Cookie", "TOKEN=session-cookie; path=/; HttpOnly"), ("X-Updated-CSRF-Token", "csrf-2")], body: Data("{}".utf8))
        case ("GET", "/camera-snapshot"):
            // A third-party camera's own snapshot URL, behind Digest authentication.
            if let authorization = request.headers["authorization"], authorization.hasPrefix("Digest "), authorization.contains("username=\"viewer\""),
               authorization.contains("uri=\"/camera-snapshot?channel=1\"") {
                return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg")], body: Data([0xFF, 0xD8, 0xCA]))
            }
            return HomeswiftNetwork.HTTPResponse(status: 401, headers: [("WWW-Authenticate", "Digest realm=\"camera\", nonce=\"n1\", qop=\"auth\"")])
        default:
            break
        }
        guard request.headers["cookie"] == "TOKEN=session-cookie" else { return HomeswiftNetwork.HTTPResponse(status: 401) }
        switch (request.method, request.path) {
        case ("GET", "/proxy/protect/api/bootstrap"):
            return json(state.bootstrap)
        case ("GET", let path) where path.hasPrefix("/proxy/protect/api/ws/"):
            return json(["url": .string("wss://controller.local:7442/\(path.dropFirst("/proxy/protect/api/ws/".count))?token=abc")])
        case ("GET", let path) where path.hasSuffix("/lux"):
            return json(["illuminance": .number(state.lux)])
        case ("GET", let path) where path.hasSuffix("/snapshot") || path.hasSuffix("/package-snapshot"):
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg")], body: Data([0xFF, 0xD8, 0xFF]))
        case ("POST", _):
            return json([:])
        case ("PATCH", let path):
            guard state.patchStatus == 200 else { return HomeswiftNetwork.HTTPResponse(status: state.patchStatus) }
            let parts = path.split(separator: "/")
            let patch = request.body.flatMap { try? JSONValue(data: $0) } ?? .object([:])
            if parts.last == "nvr" {
                let merged = (state.bootstrap.at("nvr") ?? .object([:])).merging(patch)
                state.bootstrap = state.bootstrap.setting("nvr", merged)
                return json(merged)
            }
            guard parts.count >= 2 else { return HomeswiftNetwork.HTTPResponse(status: 404) }
            let collection = String(parts[parts.count - 2]), id = String(parts[parts.count - 1])
            var devices = state.bootstrap.array(collection)
            guard let index = devices.firstIndex(where: { $0.string("id") == id }) else { return HomeswiftNetwork.HTTPResponse(status: 404) }
            devices[index] = devices[index].merging(patch)
            state.bootstrap = state.bootstrap.setting(collection, .array(devices))
            return json(devices[index])
        default:
            return HomeswiftNetwork.HTTPResponse(status: 404)
        }
    }

    /// The JSON body of a recorded request.
    static func body(_ seen: Seen) -> JSONValue? { seen.body.flatMap { try? JSONValue(data: $0) } }
}

/// Opens the shared `FakeWebSocket`s with the TLS behaviour of a self-signed console: a pinned certificate that is
/// not the console's fails the handshake, before the upgrade request and its cookie go out.
final class FakeWebSocketConnector: @unchecked Sendable {
    private let opened = NIOLockedValueBox<[(socket: FakeWebSocket, options: WebSocket.Options)]>([])
    let certificate: String
    let failures = NIOLockedValueBox(0)
    /// The console stops answering pings.
    let unansweredPings = NIOLockedValueBox(false)

    init(certificate: String = FakeController.fingerprint) {
        self.certificate = certificate
    }

    var connections: [FakeWebSocket] { opened.withLockedValue { $0.map(\.socket) } }
    var last: FakeWebSocket? { connections.last }

    /// A header of the upgrade request of `socket`.
    func header(_ name: String, of socket: FakeWebSocket) -> String? {
        opened.withLockedValue { $0.first { $0.socket === socket }?.options.headers.first { $0.name.lowercased() == name.lowercased() }?.value }
    }

    var factory: ProtectWebSocketFactory { { url, options in try self.connect(url, options) } }

    private func connect(_ url: URL, _ options: WebSocket.Options) throws -> any WebSocketConnection {
        if case .pinned(let pinned) = options.tls.trust, HTTPClient.normalizeFingerprint(pinned) != certificate {
            throw HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(pinned), observed: certificate)
        }
        if failures.withLockedValue({ value -> Bool in
            guard value > 0 else { return false }
            value -= 1
            return true
        }) {
            throw HTTPClientError.cannotConnect(host: url.host ?? "", port: 443, code: nil, reason: "refused")
        }
        let socket = FakeWebSocket(url: url)
        opened.withLockedValue { $0.append((socket, options)) }
        return unansweredPings.withLockedValue { $0 } ? UnansweredPings(socket) : socket
    }
}

/// A console that stopped answering pings: they time out, the rest is the fake's.
private final class UnansweredPings: WebSocketConnection {
    let socket: FakeWebSocket
    init(_ socket: FakeWebSocket) { self.socket = socket }

    var messages: AsyncThrowingStream<WebSocketMessage, any Error> { socket.messages }
    func send(_ message: WebSocketMessage) async throws { try await socket.send(message) }
    func close(code: UInt16, reason: String) async { await socket.close(code: code, reason: reason) }

    func ping(timeout: Duration) async throws {
        try await socket.ping(timeout: timeout)
        throw WebSocketError.heartbeatTimeout
    }
}

extension FakeWebSocket {
    /// A binary message from the console.
    func push(_ data: Data) { receive(binary: data) }
    /// The console closes the connection.
    func serverClose() { finish() }
    var isClosed: Bool { !isOpen }
    var path: String { url?.path ?? "" }
    /// What the plugin sent, as bytes.
    var sentData: [Data] { sent.map(\.data) }
}

extension FakeMQTTConnection {
    /// A message from the broker.
    func receive(_ topic: String, _ message: String) { receive(topic, string: message) }
    func published(_ topic: String) -> [String] { published(on: topic) }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
