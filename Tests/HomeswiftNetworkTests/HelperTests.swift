import Foundation
import HomeswiftNetworkTestSupport
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import Testing

@testable import HomeswiftNetwork

struct BackoffTests {
    @Test func growsToTheMaximum() {
        let backoff = Backoff(initial: .seconds(1), maximum: .seconds(5))
        #expect((0..<5).map { backoff.delay(attempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)])
        #expect(backoff.delay(attempt: 10_000) == .seconds(5))
        #expect(backoff.delay(attempt: -1) == .seconds(1))
    }

    @Test func jitter() {
        let proportional = Backoff(initial: .seconds(10), maximum: .seconds(60), jitter: .proportional(0.2))
        #expect(proportional.delay(attempt: 0, random: 0) == .seconds(8))
        #expect(proportional.delay(attempt: 0, random: 0.5) == .seconds(10))
        let additive = Backoff(initial: .seconds(10), factor: 3, maximum: .seconds(60), jitter: .additive(.seconds(2)))
        #expect(additive.delay(attempt: 1, random: 0.5) == .seconds(31))
        #expect(additive.delay(attempt: 2, random: 0) == .seconds(60))
    }

    @Test func outlandishSettingsDoNotTrap() {
        let huge = Backoff(initial: .seconds(1), maximum: .seconds(Int64.max), jitter: .proportional(1e300))
        #expect(huge.delay(attempt: 3, random: 1) == .seconds(Int64.max))
        #expect(Backoff(initial: .seconds(1), maximum: .seconds(5), jitter: .proportional(.nan)).delay(attempt: 0) == .zero)
        #expect(Backoff(initial: .seconds(1), factor: -2, maximum: .seconds(5)).delay(attempt: 1) == .zero)
    }
}

struct UDPSocketTests {
    @Test func sendsAndReceivesOnLoopback() async throws {
        let receiver = try await UDPSocket.bind(host: "127.0.0.1", reuseAddress: true)
        let sender = try await UDPSocket.bind(host: "127.0.0.1")
        let port = try #require(receiver.localPort)
        try await sender.send(Data("hello".utf8), to: "127.0.0.1", port: port)
        var iterator = receiver.datagrams.makeAsyncIterator()
        let datagram = try #require(await iterator.next())
        #expect(datagram.data == Data("hello".utf8))
        #expect(datagram.address == "127.0.0.1")
        await sender.close()
        await receiver.close()
        #expect(await iterator.next() == nil)
    }

    @Test func listsTheLoopbackNetwork() {
        let loopback = localIPv4Networks().first(where: \.isLoopback)
        #expect(loopback?.contains(IPv4Network.parse("127.0.0.1")!) == true)
        #expect(IPv4Network(address: 0xC0A8_010A, netmask: 0xFFFF_FF00).broadcast == 0xC0A8_01FF)
    }
}

struct TrustOnFirstUseTests {
    @Test func pinsTheFirstCertificateAndReportsAMismatchOnce() {
        let first = String(repeating: "ab", count: 32), second = String(repeating: "cd", count: 32)
        let saved = NIOLockedValueBox<[String]>([])
        let trust = HTTPClient.TrustOnFirstUse { fingerprint in saved.withLockedValue { $0.append(fingerprint) } }
        #expect(trust.tls == .any)
        #expect(!trust.observe("not a fingerprint"))
        #expect(trust.observe(first.uppercased()))
        #expect(!trust.observe(second))
        #expect(trust.tls == .pinned(first))
        #expect(saved.withLockedValue { $0 } == [first])
        #expect(trust.reportMismatch(observed: second))
        #expect(!trust.reportMismatch(observed: second))

        let restored = HTTPClient.TrustOnFirstUse(pinned: "AB:" + String(repeating: "AB:", count: 30) + "AB")
        #expect(restored.fingerprint == first)
        restored.reset()
        #expect(restored.tls == .any)
    }
}

struct TLSHelperTests {
    @Test func amazonRootParses() throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(TLSOptions.Trust.amazonRootCA1PEM.utf8))
        #expect(certificates.count == 1)
        #expect(TLSOptions(trust: .amazonRootCA1) == TLSOptions(trust: .roots(pem: TLSOptions.Trust.amazonRootCA1PEM)))
    }

    @Test func contextIsReusedUntilTheOptionsChange() throws {
        var options = TLSOptions(trust: .any)
        let context = try options.makeContext()
        #expect(try options.makeContext() === context)
        options.alpn = ["mqtt"]
        #expect(try options.makeContext() !== context)
    }
}

struct MQTTFirstConnectionTests {
    @Test func retriesTheFirstConnectionUntilDisconnected() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        let port = server.port
        await server.stop()
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tcp(host: "127.0.0.1", port: port), clientID: "c", connectTimeout: .seconds(1),
                reconnect: .init(delay: .milliseconds(20), maximumDelay: .milliseconds(40), firstConnection: true)))
        let states = Recorder(client.states)
        let connecting = Task { try await client.connect() }
        try await eventually { states.all.filter { if case .connectionLost = $0 { true } else { false } }.count >= 2 }
        await client.disconnect()
        await #expect(throws: (any Error).self) { try await connecting.value }
        #expect(states.all.last == .disconnected)
    }
}

struct FakeTests {
    @Test func fakeMQTTRecordsAndDelivers() async throws {
        let mqtt = FakeMQTTConnection()
        await #expect(throws: MQTTError.notConnected) { try await mqtt.publish("a", string: "x") }
        mqtt.failConnects(with: [MQTTError.timeout])
        await #expect(throws: MQTTError.timeout) { try await mqtt.connect() }
        try await mqtt.connect()
        try await mqtt.subscribe("status/#", qos: .atLeastOnce)
        try await mqtt.publish("command", string: "on")
        #expect(mqtt.published(on: "command") == ["on"])
        #expect(mqtt.subscriptions == ["status/#": .atLeastOnce])
        #expect(mqtt.connectCount == 2)

        var messages = mqtt.messages.makeAsyncIterator()
        mqtt.receive("status/1", string: "{}")
        #expect(await messages.next()?.topic == "status/1")
        var states = mqtt.states.makeAsyncIterator()
        #expect(await states.next() == .connected(sessionPresent: false))
        mqtt.setState(.connectionLost("gone"))
        #expect(await states.next() == .connectionLost("gone"))
        #expect(!mqtt.isConnected)
    }

    @Test func fakeWebSocketRecordsAndCloses() async throws {
        let socket = FakeWebSocket()
        socket.onSend { message in if message.text == "ping" { socket.receive(text: "pong") } }
        try await socket.send(text: "ping")
        var messages = socket.messages.makeAsyncIterator()
        #expect(try await messages.next() == .text("pong"))
        socket.finish(code: 4000, reason: "bye")
        #expect(try await messages.next() == nil)
        let connection: any WebSocketConnection = socket
        #expect(connection.closeCode == 4000 && connection.closeReason == "bye")
        await #expect(throws: WebSocketError.notConnected) { try await socket.send(text: "late") }
        #expect(socket.sentText == ["ping"])
    }
}

struct HTTPHeaderTests {
    @Test func requestHeadersReplaceDefaultsAndKeepRepeats() {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "device")
        headers.add(name: "Connection", value: "close")
        headers.applying([("host", "proxy"), ("Cookie", "a=1"), ("Cookie", "b=2")])
        #expect(headers["Host"] == ["proxy"])
        #expect(headers["Connection"] == ["close"])
        #expect(headers["Cookie"] == ["a=1", "b=2"])
    }

    @Test func bracketsIPv6HostsAndLeavesDefaultPortsOut() {
        #expect(hostHeader(host: "fe80::1", port: 8080, defaultPort: 80) == "[fe80::1]:8080")
        #expect(hostHeader(host: "fe80::1", port: 443, defaultPort: 443) == "[fe80::1]")
        #expect(hostHeader(host: "192.168.1.2", port: 1926, defaultPort: 443) == "192.168.1.2:1926")
        #expect(hostHeader(host: "tv.local", port: 80, defaultPort: 80) == "tv.local")
    }

    @Test func errorsDoNotCarryAURLsPassword() throws {
        let error = #expect(throws: MQTTError.self) {
            try MQTTConfiguration(url: URL(string: "mqtts2://user:s3cret@broker:8883")!, clientID: "x")
        }
        #expect(error.map { "\($0)" }?.contains("s3cret") == false)
        #expect(error.map { "\($0)" }?.contains("user:***@broker") == true)
        #expect(redactingPassword(URL(string: "http://host/path?x=1")!) == "http://host/path?x=1")
    }
}

struct LogExcerptTests {
    @Test func makesABodyOneLogLine() {
        #expect(logExcerpt("\n\n<!DOCTYPE html>\n<html><head><title>\n  Not   Found\n</title></head></html>") == "an HTML page, Not Found")
        #expect(logExcerpt("<HTML><body>Request\n  blocked</body></HTML>") == "an HTML page, Request blocked")
        #expect(logExcerpt("<html><body></body></html>") == "an HTML page")
        #expect(logExcerpt("<html><style>body { margin: 0 }</style><script>var a = 1</script><p>Bad gateway</p></html>") == "an HTML page, Bad gateway")
        #expect(logExcerpt("  busy\n\n  later ") == "busy later")
        #expect(logExcerpt(" \n ") == nil)
        #expect(logExcerpt(String(repeating: "ab ", count: 500), limit: 10) == "ab ab ab a")
    }
}
