import Foundation
import NIOCore
import Testing

@testable import HomeswiftNetwork

@Suite("WebSocket", .timeLimit(.minutes(1)))
struct WebSocketTests {
    @Test func connectsSendsHeadersAndEchoesTextAndBinary() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        var options = WebSocket.Options()
        options.headers = [("Cookie", "TOKEN=abc"), ("X-Api-Key", "k")]
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/ws/updates?lastUpdateId=7")!, options: options)
        var iterator = socket.messages.makeAsyncIterator()
        #expect(try await iterator.next() == .text("hello"))

        try await socket.send(text: "echo me")
        #expect(try await iterator.next() == .text("echo me"))
        try await socket.send(binary: Data([0, 1, 2, 255]))
        #expect(try await iterator.next() == .binary(Data([0, 1, 2, 255])))

        let request = try #require(server.webSocket.requests.first)
        #expect(request.uri == "/ws/updates?lastUpdateId=7")
        #expect(request.headers.first(name: "Cookie") == "TOKEN=abc")
        #expect(request.headers.first(name: "X-Api-Key") == "k")
        #expect(request.headers.first(name: "Host") == "127.0.0.1:\(server.port)")
        await socket.close()
    }

    @Test func requestsThePathAsItIsEncoded() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        // Decoded, `%20` would put a space in the request line and `%2F` would become a separator.
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/a%20b/c%2Fd?x=%2F")!)
        #expect(server.webSocket.requests.first?.uri == "/a%20b/c%2Fd?x=%2F")
        await socket.close()
    }

    @Test func reassemblesFragmentsAndAnswersPings() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/")!)
        var iterator = socket.messages.makeAsyncIterator()
        _ = try await iterator.next()
        try await socket.send(text: "fragment")
        #expect(try await iterator.next() == .text("fragmented"))
        try await socket.ping(timeout: .seconds(2))
        await socket.close()
    }

    @Test func endsTheStreamOnTheServersCloseFrame() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/")!)
        try await socket.send(text: "close")
        var received: [WebSocketMessage] = []
        for try await message in socket.messages { received.append(message) }
        #expect(received == [.text("hello")])
        #expect(socket.closeCode == 4000)
        #expect(socket.closeReason == "bye")
        await #expect(throws: WebSocketError.notConnected) { try await socket.send(text: "late") }
    }

    @Test func throwsWhenTheConnectionDrops() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/")!)
        try await socket.send(text: "drop")
        await #expect(throws: WebSocketError.connectionLost) {
            for try await _ in socket.messages {}
        }
    }

    /// A reset (a peer gone with frames in flight) ends the stream as a drop does, not with the I/O error: which of the
    /// two a client sees depends on timing.
    @Test func aResetConnectionIsADropToo() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/")!)
        try await socket.send(text: "reset")
        await #expect(throws: WebSocketError.connectionLost) {
            for try await _ in socket.messages {}
        }
    }

    @Test func heartbeatDetectsASilentServer() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(
            to: URL(string: "ws://127.0.0.1:\(server.port)/")!, options: WebSocket.Options(heartbeat: .milliseconds(200))
        )
        // On a loaded runner a pong can come late enough that the heartbeat closes the socket before "mute" goes out:
        // that is a heartbeat timeout too, which the stream reports.
        try? await socket.send(text: "mute")
        await #expect(throws: WebSocketError.heartbeatTimeout) {
            for try await _ in socket.messages {}
        }
    }

    @Test func limitsTheMessageSize() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(
            to: URL(string: "ws://127.0.0.1:\(server.port)/")!, options: WebSocket.Options(maximumMessageSize: 1024)
        )
        try await socket.send(text: "big")
        await #expect(throws: WebSocketError.messageTooLarge(limit: 1024)) {
            for try await _ in socket.messages {}
        }
    }

    @Test func reportsARefusedUpgradeAndAClosedPort() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        await #expect(throws: WebSocketError.handshakeFailed(status: 403)) {
            _ = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/refuse")!)
        }
        await #expect(throws: WebSocketError.invalidURL("http://127.0.0.1/")) {
            _ = try await WebSocket.connect(to: URL(string: "http://127.0.0.1/")!)
        }
        let closed = try await TestSocketServer(mode: .webSocket)
        let port = closed.port
        await closed.stop()
        do {
            _ = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(port)/")!)
            Issue.record("connected to a closed port")
        } catch let error as WebSocketError {
            guard case .cannotConnect(_, let failedPort, _, _) = error else { throw error }
            #expect(failedPort == port)
        }
    }

    @Test func negotiatesTheSubprotocol() async throws {
        let server = try await TestSocketServer(mode: .webSocket)
        defer { Task { await server.stop() } }
        let socket = try await WebSocket.connect(
            to: URL(string: "ws://127.0.0.1:\(server.port)/")!, options: WebSocket.Options(subprotocols: ["mqtt", "mqttv3.1"])
        )
        #expect(socket.subprotocol == "mqtt")
        await socket.close()

        server.webSocket.forcedSubprotocol = "other"
        await #expect(throws: WebSocketError.unexpectedSubprotocol("other")) {
            _ = try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(server.port)/")!, options: WebSocket.Options(subprotocols: ["mqtt"]))
        }
    }

    @Test func wssTrustsAPinnedOrAnyCertificateButNotTheSystemRoots() async throws {
        let server = try await TestSocketServer(mode: .webSocket, tls: true)
        defer { Task { await server.stop() } }
        let url = URL(string: "wss://127.0.0.1:\(server.port)/")!

        let any = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: TLSOptions(trust: .any)))
        #expect(any.certificateFingerprint == TestCertificate.fingerprint)
        var iterator = any.messages.makeAsyncIterator()
        #expect(try await iterator.next() == .text("hello"))
        await any.close()

        let pinned = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: TLSOptions(trust: .pinned(TestCertificate.fingerprint))))
        await pinned.close()

        let roots = try await WebSocket.connect(
            to: URL(string: "wss://localhost:\(server.port)/")!, options: WebSocket.Options(tls: TLSOptions(trust: .roots(pem: TestCertificate.certificatePEM)))
        )
        await roots.close()

        await #expect(throws: HTTPClientError.certificateMismatch(expected: String(repeating: "ab", count: 32), observed: TestCertificate.fingerprint)) {
            _ = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: TLSOptions(trust: .pinned(String(repeating: "AB", count: 32)))))
        }
        await #expect(throws: (any Error).self) {
            _ = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: .system, timeout: .seconds(5)))
        }
    }

    @Test func wssPresentsAClientCertificate() async throws {
        let server = try await TestSocketServer(mode: .webSocket, tls: true, requireClientCertificate: true)
        defer { Task { await server.stop() } }
        let url = URL(string: "wss://127.0.0.1:\(server.port)/")!
        var tls = TLSOptions(trust: .any)
        await #expect(throws: (any Error).self) {
            let socket = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: tls, timeout: .seconds(5)))
            for try await _ in socket.messages {}
        }
        tls.clientIdentity = .pem(certificate: TestClientCertificate.certificatePEM, privateKey: TestClientCertificate.keyPEM)
        let socket = try await WebSocket.connect(to: url, options: WebSocket.Options(tls: tls))
        var iterator = socket.messages.makeAsyncIterator()
        #expect(try await iterator.next() == .text("hello"))
        await socket.close()
    }
}
