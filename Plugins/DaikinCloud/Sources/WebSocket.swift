import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// Real-time updates from the Onecta cloud (Mobile App login only): characteristic changes pushed as
/// they happen, so polling can slow down.
///
/// The connection is kept alive with a ping every 30 s (no pong within 10 s drops it) and comes back after
/// a drop with an exponential backoff (1 s doubling to 5 min, ±25 % jitter so many clients do not reconnect
/// together). The backoff resets only once a connection has stayed up a minute, so a server that accepts
/// and drops at once cannot cause a tight loop; after 50 failures in a row it gives up. The heartbeat and the
/// reconnection are this actor's, as in the Homebridge plugin, so the shared `WebSocket` runs without its own.
actor DaikinWebSocket {
    static let url = URL(string: ProcessInfo.processInfo.environment["DAIKIN_WEBSOCKET_URL"] ?? "wss://wsapi.onecta.daikineurope.com")!

    /// Opens a connection: `WebSocket.connect` with the system's trusted roots, or a fake server in tests.
    typealias Connect = @Sendable (URL, WebSocket.Options) async throws -> any WebSocketConnection

    static let connect: Connect = { url, options in try await WebSocket.connect(to: url, options: options) }

    struct Timing: Sendable {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(300), jitter: .proportional(0.25))
        var maxAttempts = 50
        var stableConnection: Duration = .seconds(60)
        var pingInterval: Duration = .seconds(30)
        var pongTimeout: Duration = .seconds(10)
        var connectTimeout: Duration = .seconds(30)
    }

    enum State: String, Sendable { case disconnected, connecting, connected, reconnecting }

    enum Event: Sendable, Equatable {
        case connected
        case disconnected(code: Int?, reason: String?, reconnecting: Bool)
        case deviceUpdate(WebSocketDeviceUpdate)
        case groupUpdate(groupID: String?, siteID: String?, characteristicName: String)
        case error(String)
    }

    private let oauth: any OAuthProvider
    private let open: Connect
    private let timing: Timing
    private let sleep: @Sendable (Duration) async throws -> Void
    private let random: @Sendable () -> Double
    private let onEvent: @Sendable (Event) -> Void

    private(set) var state = State.disconnected
    /// Attempts since the last connection that stayed up, for the circuit breaker.
    private(set) var connectionAttempts = 0
    /// Reconnections scheduled since then: the backoff grows with them.
    private(set) var reconnections = 0
    private var shouldReconnect = true
    private var connection: (any WebSocketConnection)?
    /// Each connection's number: tasks of an old one find out and stop.
    private var generation = 0
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?

    init(
        oauth: any OAuthProvider, connect: @escaping Connect = DaikinWebSocket.connect, timing: Timing = Timing(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.oauth = oauth
        open = connect
        self.timing = timing
        self.sleep = sleep
        self.random = random
        self.onEvent = onEvent
    }

    var isConnected: Bool { state == .connected && connection != nil }

    func connect() async {
        guard state != .connected, state != .connecting else { return }
        shouldReconnect = true
        await establish()
    }

    /// Closes and stays closed.
    func disconnect() async {
        shouldReconnect = false
        await cleanup()
        state = .disconnected
        onEvent(.disconnected(code: nil, reason: nil, reconnecting: false))
    }

    // MARK: Connecting

    private func establish() async {
        state = .connecting
        connectionAttempts += 1
        generation += 1
        let current = generation
        let socket: any WebSocketConnection
        do {
            // A fresh token for every connection: the last one may have expired while it was down.
            let token = try await oauth.accessToken()
            let headers = [("Authorization", "Bearer \(token)"), ("User-Agent", DaikinHTTP.userAgent)]
            socket = try await open(Self.url, WebSocket.Options(headers: headers, tls: .system, timeout: timing.connectTimeout))
        } catch {
            guard current == generation, shouldReconnect else { return }
            onEvent(.error(message(of: error)))
            state = .reconnecting
            scheduleReconnect()
            return
        }
        guard current == generation, shouldReconnect else {
            await socket.close()
            return
        }
        connection = socket
        opened(socket, generation: current)
    }

    private func opened(_ socket: any WebSocketConnection, generation current: Int) {
        state = .connected
        stableTask?.cancel()
        let stable = timing.stableConnection
        let sleep = sleep
        stableTask = Task { [weak self] in
            guard (try? await sleep(stable)) != nil, !Task.isCancelled else { return }
            await self?.markStable(current)
        }
        startHeartbeat(socket, generation: current)
        readerTask = Task { [weak self] in
            // A close frame ends the stream (its code, 1005 without one); a drop throws (1006).
            let code: Int, reason: String
            do {
                for try await message in socket.messages {
                    guard let self else { return }
                    switch message {
                    case .text(let text): await self.received(Data(text.utf8), generation: current)
                    case .binary(let data): await self.received(data, generation: current)
                    }
                }
                code = Int(socket.closeCode ?? 1005)
                reason = socket.closeReason ?? ""
            } catch {
                code = 1006
                reason = "\(error)"
            }
            await self?.closed(code: code, reason: reason, generation: current)
        }
        onEvent(.connected)
    }

    private func markStable(_ current: Int) {
        guard current == generation, state == .connected else { return }
        connectionAttempts = 0
        reconnections = 0
    }

    /// Characteristic changes; anything that is not JSON of the expected shape is ignored.
    private func received(_ data: Data, generation current: Int) {
        guard current == generation, let message = try? JSONValue(data: data), case .object = message, case .object = message["data"],
            let name = message["data"]?["name"]?.stringValue
        else { return }
        switch message["event"]?.stringValue {
        case "gateway:managementpoint:characteristic":
            guard let deviceID = message["gatewayDeviceId"]?.stringValue, let embeddedID = message["embeddedId"]?.stringValue else { return }
            onEvent(.deviceUpdate(WebSocketDeviceUpdate(
                deviceID: deviceID, embeddedID: embeddedID, managementPointID: message["managementPointId"]?.stringValue,
                characteristicName: name, data: message["data"] ?? .null)))
        case "group:characteristic":
            onEvent(.groupUpdate(groupID: message["groupId"]?.stringValue, siteID: message["siteId"]?.stringValue, characteristicName: name))
        default:
            break
        }
    }

    /// `closeCode` is what this side sends the server, when it is the one closing.
    private func closed(code: Int, reason: String, generation current: Int, closeCode: UInt16 = 1000) async {
        guard current == generation else { return }
        await cleanup(closeCode: closeCode)
        if shouldReconnect {
            state = .reconnecting
            onEvent(.disconnected(code: code, reason: reason, reconnecting: true))
            scheduleReconnect()
        } else {
            state = .disconnected
            onEvent(.disconnected(code: code, reason: reason, reconnecting: false))
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        // A circuit breaker: too many failures in a row.
        if connectionAttempts >= timing.maxAttempts {
            state = .disconnected
            onEvent(.error("WebSocket gave up after \(timing.maxAttempts) consecutive reconnection attempts"))
            onEvent(.disconnected(code: nil, reason: nil, reconnecting: false))
            return
        }
        let delay = timing.backoff.delay(attempt: reconnections, random: random())
        reconnections += 1
        let sleep = sleep
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard (try? await sleep(.milliseconds(Int((delay / .milliseconds(1)).rounded())))) != nil, !Task.isCancelled else { return }
            await self?.reconnectNow()
        }
    }

    private func reconnectNow() async {
        reconnectTask = nil
        guard shouldReconnect else { return }
        await establish()
    }

    // MARK: Heartbeat

    private func startHeartbeat(_ socket: any WebSocketConnection, generation current: Int) {
        heartbeatTask?.cancel()
        let interval = timing.pingInterval, timeout = timing.pongTimeout, sleep = sleep
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await sleep(interval)) != nil, !Task.isCancelled, let self, await self.isCurrent(current) else { return }
                do {
                    try await socket.ping(timeout: timeout)
                } catch WebSocketError.timeout {
                    // No pong: the connection is dead. Dropping it (1001 to a peer that may still listen) reconnects.
                    guard !Task.isCancelled else { return }
                    await self.closed(code: 1006, reason: "", generation: current, closeCode: 1001)
                    return
                } catch {
                    // The connection closed meanwhile: the reader reports it.
                    return
                }
            }
        }
    }

    private func isCurrent(_ current: Int) -> Bool { current == generation && state == .connected }

    private func cleanup(closeCode: UInt16 = 1000) async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stableTask?.cancel()
        stableTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        if let connection {
            self.connection = nil
            await connection.close(code: closeCode, reason: "")
        }
        readerTask?.cancel()
        readerTask = nil
    }
}
