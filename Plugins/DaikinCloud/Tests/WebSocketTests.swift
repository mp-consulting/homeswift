import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// A WebSocket server in memory: each connection is a `FakeWebSocket` the test drives.
final class FakeSockets: Sendable {
    /// A connection whose pings never get their pong.
    final class Silent: WebSocketConnection {
        let socket: FakeWebSocket
        init(_ socket: FakeWebSocket) { self.socket = socket }
        var messages: AsyncThrowingStream<WebSocketMessage, any Error> { socket.messages }
        func send(_ message: WebSocketMessage) async throws { try await socket.send(message) }
        func ping(timeout: Duration) async throws {
            try await socket.ping(timeout: timeout)
            throw WebSocketError.timeout
        }
        func close(code: UInt16, reason: String) async { await socket.close(code: code, reason: reason) }
        var closeCode: UInt16? { socket.closeCode }
        var closeReason: String? { socket.closeReason }
    }

    let sockets = NIOLockedValueBox<[FakeWebSocket]>([])
    let headers = NIOLockedValueBox<[[(name: String, value: String)]]>([])
    let attempts = NIOLockedValueBox(0)
    /// Connections that fail before this many attempts.
    let failures = NIOLockedValueBox(0)
    let answersPings: Bool

    init(answersPings: Bool = true, failures: Int = 0) {
        self.answersPings = answersPings
        self.failures.withLockedValue { $0 = failures }
    }

    var last: FakeWebSocket? { sockets.withLockedValue { $0.last } }
    var count: Int { sockets.withLockedValue { $0.count } }

    /// The `Authorization` header of each connection.
    var authorizations: [String?] { headers.withLockedValue { $0.map { $0.first { $0.name == "Authorization" }?.value } } }

    var connect: DaikinWebSocket.Connect { { url, options in try await self.open(url, options) } }

    func open(_ url: URL, _ options: WebSocket.Options) async throws -> any WebSocketConnection {
        attempts.withLockedValue { $0 += 1 }
        let fail = failures.withLockedValue { value -> Bool in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
        if fail { throw DaikinError("Unexpected server response: 503") }
        let socket = FakeWebSocket(url: url)
        headers.withLockedValue { $0.append(options.headers) }
        sockets.withLockedValue { $0.append(socket) }
        return answersPings ? socket : Silent(socket)
    }
}

/// The Homebridge plugin's WebSocket tests: backoff, the heartbeat, messages, disconnecting.
@Suite(.timeLimit(.minutes(1)))
struct WebSocketTests {
    let events = NIOLockedValueBox<[DaikinWebSocket.Event]>([])
    let delays = NIOLockedValueBox<[Duration]>([])

    func socket(_ transport: FakeSockets, oauth: FakeOAuth = FakeOAuth(), timing: DaikinWebSocket.Timing = .init(), scaled: Bool = true) -> DaikinWebSocket {
        let events = events, delays = delays
        return DaikinWebSocket(oauth: oauth, connect: transport.connect, timing: timing, sleep: { duration in
            delays.withLockedValue { $0.append(duration) }
            // A thousand times faster: a 30 s ping is 30 ms.
            if scaled { try await Task.sleep(for: duration / 1000) }
        }, random: { 0.5 }) { event in events.withLockedValue { $0.append(event) } }
    }

    var recorded: [DaikinWebSocket.Event] { events.withLockedValue { $0 } }

    @Test func backoffGrowsAndIsCapped() async throws {
        let transport = FakeSockets(failures: 100)
        let ws = socket(transport, scaled: false)
        await ws.connect()
        #expect(await eventually { recorded.contains(.error("WebSocket gave up after 50 consecutive reconnection attempts")) })
        #expect(transport.attempts.withLockedValue { $0 } == 50)
        let waits = delays.withLockedValue { $0 }.map { Int($0 / .milliseconds(1)) }
        #expect(Array(waits.prefix(10)) == [1000, 2000, 4000, 8000, 16000, 32000, 64000, 128_000, 256_000, 300_000])
        #expect(waits.count == 49)
        #expect(Set(waits.dropFirst(9)) == [300_000])
        #expect(recorded.last == .disconnected(code: nil, reason: nil, reconnecting: false))
        #expect(recorded.contains(.error("Unexpected server response: 503")))
    }

    @Test func backoffResetsOnlyAfterAStableMinute() async throws {
        let transport = FakeSockets()
        var timing = DaikinWebSocket.Timing()
        timing.pingInterval = .seconds(3600)
        // Stable after 500 ms here rather than 60: the two drops below come well within it on a loaded runner.
        timing.stableConnection = .seconds(500)
        let ws = socket(transport, timing: timing)
        await ws.connect()
        #expect(await ws.isConnected)
        #expect(recorded == [.connected])
        // Dropped before it is stable: the backoff keeps growing.
        transport.last?.drop()
        #expect(await eventually { transport.count == 2 })
        transport.last?.drop()
        #expect(await eventually { transport.count == 3 })
        #expect(await ws.reconnections == 2)
        // Up long enough: back to the start.
        #expect(await eventually { await ws.reconnections == 0 })
        #expect(await ws.connectionAttempts == 0)
        #expect(recorded.contains(.disconnected(code: 1006, reason: "\(WebSocketError.connectionLost)", reconnecting: true)))
        // The next drop waits the first delay again.
        delays.withLockedValue { $0.removeAll() }
        transport.last?.drop()
        #expect(await eventually { transport.count == 4 })
        #expect(delays.withLockedValue { $0 }.contains(.seconds(1)))
        #expect(!delays.withLockedValue { $0 }.contains(.seconds(4)))
        await ws.disconnect()
    }

    @Test func aCloseFrameReportsItsCode() async throws {
        let transport = FakeSockets()
        var timing = DaikinWebSocket.Timing()
        timing.pingInterval = .seconds(3600)
        let ws = socket(transport, timing: timing)
        await ws.connect()
        transport.last?.finish(code: 4001, reason: "token expired")
        #expect(await eventually { recorded.contains(.disconnected(code: 4001, reason: "token expired", reconnecting: true)) })
        #expect(await eventually { transport.count == 2 })
        await ws.disconnect()
    }

    @Test func aMissingPongDropsTheConnection() async throws {
        let transport = FakeSockets(answersPings: false)
        let ws = socket(transport)
        await ws.connect()
        let first = try #require(transport.last)
        #expect(await eventually { !first.isOpen })
        #expect(first.closeCode == 1001)
        #expect(first.pingCount == 1)
        #expect(recorded.contains(.disconnected(code: 1006, reason: "", reconnecting: true)))
        // And it comes back.
        #expect(await eventually { transport.count == 2 })
        await ws.disconnect()
    }

    @Test func pongsKeepTheConnection() async throws {
        let transport = FakeSockets(answersPings: true)
        let ws = socket(transport)
        await ws.connect()
        let first = try #require(transport.last)
        #expect(await eventually { first.pingCount >= 3 })
        #expect(first.isOpen)
        #expect(transport.count == 1)
        await ws.disconnect()
    }

    @Test func messages() async throws {
        let transport = FakeSockets()
        var timing = DaikinWebSocket.Timing()
        timing.pingInterval = .seconds(3600)
        let ws = socket(transport, timing: timing)
        await ws.connect()
        let socket = try #require(transport.last)
        #expect(transport.authorizations == ["Bearer valid-token"])
        #expect(socket.url == DaikinWebSocket.url)
        socket.receive(text: #"{"event":"gateway:managementpoint:characteristic","eventType":"update","embeddedId":"climateControl","managementPointId":"mp","gatewayDeviceId":"dev-1","type":"x","data":{"name":"onOffMode","value":"on","settable":true}}"#)
        for malformed in ["not json", "[]", #"{"event":"gateway:managementpoint:characteristic"}"#, #"{"data":{"name":1}}"#,
            #"{"event":"gateway:managementpoint:characteristic","data":{"name":"x"}}"#, #"{"event":"other","data":{"name":"x"}}"#] {
            socket.receive(text: malformed)
        }
        socket.receive(binary: Data(#"{"event":"group:characteristic","groupId":"g","siteId":"s","data":{"name":"temp","value":1}}"#.utf8))
        #expect(await eventually { recorded.count == 3 })
        #expect(recorded[1] == .deviceUpdate(WebSocketDeviceUpdate(
            deviceID: "dev-1", embeddedID: "climateControl", managementPointID: "mp", characteristicName: "onOffMode", data: ["name": "onOffMode", "value": "on", "settable": true])))
        #expect(recorded[2] == .groupUpdate(groupID: "g", siteID: "s", characteristicName: "temp"))
    }

    @Test func disconnectStaysDisconnected() async throws {
        let transport = FakeSockets()
        let ws = socket(transport)
        await ws.connect()
        let socket = try #require(transport.last)
        await ws.disconnect()
        #expect(!socket.isOpen)
        #expect(socket.closeCode == 1000)
        #expect(await ws.state == .disconnected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.count == 1)
        #expect(recorded.last == .disconnected(code: nil, reason: nil, reconnecting: false))
    }

    @Test func aFreshTokenForEveryConnection() async throws {
        let oauth = FakeOAuth()
        await oauth.set(tokens: ["first", "second"])
        let transport = FakeSockets()
        let ws = socket(transport, oauth: oauth)
        await ws.connect()
        transport.last?.drop()
        #expect(await eventually { transport.count == 2 })
        #expect(transport.authorizations == ["Bearer first", "Bearer second"])
        await ws.disconnect()
    }

    @Test func aTokenFailureSchedulesAReconnect() async throws {
        actor FailingOnce: OAuthProvider {
            var calls = 0
            func accessToken() async throws -> String {
                calls += 1
                if calls == 1 { throw DaikinError("Not authenticated. Please authenticate first.") }
                return "token"
            }
            func refreshToken() async throws -> TokenSet { throw DaikinError("no") }
        }
        let transport = FakeSockets()
        let events = events
        let ws = DaikinWebSocket(oauth: FailingOnce(), connect: transport.connect, sleep: { try await Task.sleep(for: $0 / 1000) }) { event in events.withLockedValue { $0.append(event) } }
        await ws.connect()
        #expect(recorded == [.error("Not authenticated. Please authenticate first.")])
        #expect(await eventually { transport.count == 1 })
        #expect(await eventually { recorded.contains(.connected) })
        await ws.disconnect()
    }
}
