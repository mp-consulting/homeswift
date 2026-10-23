import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftNetwork

/// Collects what a client's streams deliver.
final class Recorder<Element: Sendable>: Sendable {
    let values = NIOLockedValueBox<[Element]>([])
    let task: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let values = values
        task = Task { for await value in stream { values.withLockedValue { $0.append(value) } } }
    }

    var all: [Element] { values.withLockedValue { $0 } }
    deinit { task.cancel() }
}

@Suite("MQTT packets")
struct MQTTPacketTests {
    @Test func connectMatchesTheSpecificationsLayout() {
        let connect = MQTTConnect(clientID: "abc", username: "u", password: "p", keepAlive: 60, cleanSession: true, will: nil)
        // Fixed header, "MQTT", level 4, flags (user, password, clean), keep-alive 60, then the strings.
        #expect(MQTTPacket.connect(connect).encode() == [
            0x10, 21, 0, 4, 77, 81, 84, 84, 4, 0xC2, 0, 60, 0, 3, 97, 98, 99, 0, 1, 117, 0, 1, 112,
        ])
    }

    @Test func everyPacketRoundTrips() throws {
        let packets: [MQTTPacket] = [
            .connect(MQTTConnect(version: .v3_1, clientID: "id", username: nil, password: "secret", keepAlive: 30, cleanSession: false,
                                 will: MQTTMessage(topic: "status", string: "offline", qos: .atLeastOnce, retain: true))),
            .connack(sessionPresent: true, returnCode: 0),
            .publish(MQTTMessage(topic: "a/b", payload: Data(repeating: 1, count: 300), qos: .atLeastOnce, retain: true), packetID: 9, duplicate: true),
            .publish(MQTTMessage(topic: "a", string: "x"), packetID: nil, duplicate: false),
            .puback(1), .pubrec(2), .pubrel(3), .pubcomp(4),
            .subscribe(packetID: 5, [MQTTSubscription(topic: "a/#", qos: .atLeastOnce), MQTTSubscription(topic: "b/+", qos: .atMostOnce)]),
            .suback(packetID: 5, returnCodes: [1, 0x80]),
            .unsubscribe(packetID: 6, ["a/#"]), .unsuback(6), .pingreq, .pingresp, .disconnect,
        ]
        var parser = MQTTPacketParser()
        // One byte at a time, as a slow stream delivers them.
        for byte in packets.flatMap({ $0.encode() }) { parser.append([byte]) }
        var decoded: [MQTTPacket] = []
        while let packet = try parser.next() { decoded.append(packet) }
        #expect(decoded == packets)
    }

    @Test func refusesOversizedPackets() {
        var parser = MQTTPacketParser(limit: 10)
        parser.append(MQTTPacket.publish(MQTTMessage(topic: "t", payload: Data(count: 20)), packetID: nil, duplicate: false).encode())
        #expect(throws: MQTTError.packetTooLarge(limit: 10)) { try parser.next() }
    }

    @Test func topicFilters() {
        #expect(MQTTTopic.matches(filter: "a/+/c", topic: "a/b/c"))
        #expect(MQTTTopic.matches(filter: "a/#", topic: "a/b/c"))
        #expect(MQTTTopic.matches(filter: "a/#", topic: "a"))
        #expect(MQTTTopic.matches(filter: "#", topic: "anything/at/all"))
        #expect(!MQTTTopic.matches(filter: "a/+", topic: "a/b/c"))
        #expect(!MQTTTopic.matches(filter: "#", topic: "$aws/things/x"))
        #expect(MQTTTopic.matches(filter: "$aws/things/+/shadow/#", topic: "$aws/things/x/shadow/get/accepted"))
    }

    @Test func configurationFromABrokerURL() throws {
        let plain = try MQTTConfiguration(url: URL(string: "mqtt://user%40home:p%3Ass@broker.local")!, clientID: "c")
        guard case .tcp("broker.local", 1883) = plain.transport else { Issue.record("\(plain.transport)"); return }
        #expect(plain.username == "user@home")
        #expect(plain.password == "p:ss")
        let secure = try MQTTConfiguration(url: URL(string: "mqtts://broker.local:8884")!, clientID: "c", tls: TLSOptions(trust: .any))
        guard case .tls("broker.local", 8884, let options) = secure.transport else { Issue.record("\(secure.transport)"); return }
        #expect(options.trust == .any)
        #expect(secure.username == nil)
        #expect(throws: MQTTError.invalidURL("http://broker.local")) { try MQTTConfiguration(url: URL(string: "http://broker.local")!, clientID: "c") }
    }

    @Test func credentialsInABrokerURLAreDecodedOnce() throws {
        // `%25` is a percent sign: the password is `p%41`, not `pA`.
        let configuration = try MQTTConfiguration(url: URL(string: "mqtt://u%2540x:p%2541@broker.local")!, clientID: "c")
        #expect(configuration.username == "u%40x")
        #expect(configuration.password == "p%41")
        let socket = try MQTTConfiguration(url: URL(string: "ws://u:p%2541@broker.local:9001")!, clientID: "c")
        #expect(socket.password == "p%41")
    }
}

@Suite("MQTT client", .timeLimit(.minutes(1)))
struct MQTTClientTests {
    @Test func connectsWithCredentialsSubscribesAndPublishesBothWays() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        server.broker.state.withLockedValue { $0.credentials = ("serial", "local-password") }
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "homeswift-test", username: "serial", password: "local-password",
                keepAlive: .seconds(30), will: MQTTMessage(topic: "homeswift/status", string: "offline", retain: true)
            )
        )
        let messages = Recorder(client.messages)
        let states = Recorder(client.states)
        try await client.connect()
        #expect(await client.isConnected)
        let connect = try #require(server.broker.connects.first)
        #expect(connect.clientID == "homeswift-test")
        #expect(connect.keepAlive == 30)
        #expect(connect.cleanSession)
        #expect(connect.will == MQTTMessage(topic: "homeswift/status", string: "offline", retain: true))

        try await client.subscribe("475/SERIAL/status/#", qos: .atLeastOnce)
        #expect(server.broker.subscribes == [[MQTTSubscription(topic: "475/SERIAL/status/#", qos: .atLeastOnce)]])

        // QoS 0 and QoS 1 from the broker; the client acknowledges QoS 1.
        server.broker.publish(MQTTMessage(topic: "475/SERIAL/status/current", string: #"{"msg":"CURRENT-STATE"}"#))
        server.broker.publish(MQTTMessage(topic: "475/SERIAL/status/faults", string: "f", qos: .atLeastOnce))
        server.broker.publish(MQTTMessage(topic: "elsewhere", string: "not for us"))
        try await eventually { messages.all.count == 2 && server.broker.pubacks.count == 1 }
        #expect(messages.all.map(\.topic) == ["475/SERIAL/status/current", "475/SERIAL/status/faults"])
        #expect(messages.all.first?.string == #"{"msg":"CURRENT-STATE"}"#)

        // QoS 1 publish waits for PUBACK; QoS 0 goes out as is; retain is kept.
        try await client.publish("475/SERIAL/command", string: #"{"msg":"REQUEST-CURRENT-STATE"}"#, qos: .atLeastOnce)
        try await client.publish("homeswift/status", string: "online", retain: true)
        try await eventually { server.broker.published.count == 2 }
        #expect(server.broker.published[0] == MQTTMessage(topic: "475/SERIAL/command", string: #"{"msg":"REQUEST-CURRENT-STATE"}"#, qos: .atLeastOnce))
        #expect(server.broker.published[1].retain)

        try await client.unsubscribe("475/SERIAL/status/#")
        server.broker.publish(MQTTMessage(topic: "475/SERIAL/status/current", string: "after"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(messages.all.count == 2)

        await client.disconnect()
        try await eventually { server.broker.sessionCount == 0 }
        try await eventually { states.all.last == .disconnected }
        #expect(states.all.first == .disconnected)
        #expect(states.all.contains(.connected(sessionPresent: false)))
        await #expect(throws: MQTTError.notConnected) { try await client.publish("t", string: "x") }
    }

    @Test func badCredentialsAreRefused() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        server.broker.state.withLockedValue { $0.credentials = ("serial", "right") }
        let client = MQTTClient(
            MQTTConfiguration(transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c", username: "serial", password: "wrong")
        )
        await #expect(throws: MQTTError.connectionRefused(code: 4)) { try await client.connect() }
        #expect(await !client.isConnected)
    }

    @Test func refusedSubscriptionsThrow() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        let client = MQTTClient(MQTTConfiguration(transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c"))
        try await client.connect()
        await #expect(throws: MQTTError.subscriptionRefused(topic: "forbidden/x")) { try await client.subscribe("forbidden/x") }
        await client.disconnect()
    }

    @Test func reconnectsAndRenewsSubscriptions() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c",
                reconnect: MQTTConfiguration.Reconnect(delay: .milliseconds(50), maximumDelay: .milliseconds(200))
            )
        )
        let messages = Recorder(client.messages)
        let states = Recorder(client.states)
        // Subscribed before connecting: sent with the connection.
        try await client.subscribe("a/#", qos: .atLeastOnce)
        try await client.connect()
        try await eventually { server.broker.subscribes.count == 1 }

        server.broker.dropAll()
        try await eventually { server.broker.connects.count == 2 && server.broker.subscribes.count == 2 }
        #expect(server.broker.subscribes[1] == [MQTTSubscription(topic: "a/#", qos: .atLeastOnce)])
        try await eventually { states.all.last == .connected(sessionPresent: false) }
        #expect(states.all.contains { if case .connectionLost = $0 { true } else { false } })

        server.broker.publish(MQTTMessage(topic: "a/b", string: "after reconnect"))
        try await eventually { messages.all.map(\.string) == ["after reconnect"] }
        await client.disconnect()
    }

    @Test func keepAliveDetectsASilentBrokerAndReconnects() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c", keepAlive: .seconds(1),
                reconnect: MQTTConfiguration.Reconnect(delay: .milliseconds(50))
            )
        )
        let states = Recorder(client.states)
        try await client.connect()
        try await eventually { server.broker.pingreqs >= 1 }
        server.broker.state.withLockedValue { $0.mutePings = true }
        try await eventually(.seconds(10)) { states.all.contains(.connectionLost(MQTTError.keepAliveTimeout.description)) }
        server.broker.state.withLockedValue { $0.mutePings = false }
        try await eventually(.seconds(10)) { server.broker.connects.count == 2 }
        await client.disconnect()
    }

    @Test func noReconnectionWhenDisabled() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        let client = MQTTClient(MQTTConfiguration(transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c", reconnect: nil))
        let states = Recorder(client.states)
        try await client.connect()
        server.broker.dropAll()
        try await eventually { states.all.last == .disconnected }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.broker.connects.count == 1)
    }

    @Test func aConnectionLostRightAfterCONNACKIsNotReportedConnected() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        // The bad packet behind the CONNACK tears the connection down before `connect()` resumes.
        server.broker.state.withLockedValue { $0.connackThenGarbage = true }
        let client = MQTTClient(MQTTConfiguration(transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c"))
        let states = Recorder(client.states)
        await #expect(throws: (any Error).self) { try await client.connect() }
        #expect(await !client.isConnected)
        try await eventually { states.all.last == .disconnected }
        #expect(!states.all.contains { if case .connected = $0 { true } else { false } })
    }

    @Test func overlappingConnectionAttemptsShareOneCONNACK() async throws {
        let server = try await TestSocketServer(mode: .mqtt)
        defer { Task { await server.stop() } }
        server.broker.state.withLockedValue { $0.connackDelay = .milliseconds(300) }
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tcp(host: "127.0.0.1", port: server.port), clientID: "c",
                reconnect: MQTTConfiguration.Reconnect(delay: .milliseconds(50), maximumDelay: .milliseconds(50))
            )
        )
        let finished = NIOLockedValueBox(0)
        let connect: @Sendable () -> Void = {
            Task {
                do {
                    try await client.connect()
                    finished.withLockedValue { $0 += 1 }
                } catch {
                    Issue.record(error)
                }
            }
        }
        // A second connect() while the first waits for its CONNACK: both return, on one connection.
        connect()
        try await eventually { server.broker.connects.count == 1 }
        connect()
        try await eventually { finished.withLockedValue { $0 } == 2 }
        #expect(await client.isConnected)
        #expect(server.broker.connects.count == 1)

        // connect() while a reconnection waits for its CONNACK joins it.
        server.broker.dropAll()
        try await eventually { server.broker.connects.count == 2 }
        connect()
        try await eventually { finished.withLockedValue { $0 } == 3 }
        #expect(await client.isConnected)
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.broker.connects.count == 2)
        #expect(server.broker.sessionCount == 1)
        await client.disconnect()
    }

    @Test func disconnectDuringAReconnectionEndsDisconnected() async throws {
        let server = try await TestSocketServer(mode: .mqttOverWebSocket)
        defer { Task { await server.stop() } }
        let attempts = NIOLockedValueBox(0)
        let port = server.port
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .webSocket(
                    url: {
                        let attempt = attempts.withLockedValue { value in
                            value += 1
                            return value
                        }
                        // The reconnection is slow to get its URL: disconnect() comes in the meantime.
                        if attempt > 1 { try? await Task.sleep(for: .milliseconds(300)) }
                        return URL(string: "ws://127.0.0.1:\(port)/mqtt")!
                    },
                    options: WebSocket.Options()
                ),
                clientID: "c", reconnect: MQTTConfiguration.Reconnect(delay: .milliseconds(20))
            )
        )
        let states = Recorder(client.states)
        try await client.connect()
        server.broker.dropAll()
        try await eventually { attempts.withLockedValue { $0 } == 2 }
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(600))
        #expect(states.all.last == .disconnected)
        #expect(server.broker.connects.count == 1)
        #expect(await !client.isConnected)
    }

    @Test func tlsWithAClientCertificateInPEMAndPKCS12() async throws {
        let server = try await TestSocketServer(mode: .mqtt, tls: true, requireClientCertificate: true, alpn: ["x-amzn-mqtt-ca"])
        defer { Task { await server.stop() } }
        let identities: [TLSOptions.ClientIdentity] = [
            .pem(certificate: TestClientCertificate.certificatePEM, privateKey: TestClientCertificate.keyPEM),
            .pkcs12(TestClientCertificate.pkcs12, passphrase: "secret"),
        ]
        for identity in identities {
            let tls = TLSOptions(trust: .roots(pem: TestCertificate.certificatePEM), clientIdentity: identity, alpn: ["x-amzn-mqtt-ca"], serverName: "localhost")
            let client = MQTTClient(MQTTConfiguration(transport: .tls(host: "127.0.0.1", port: server.port, options: tls), clientID: "AP/1/abc"))
            try await client.connect()
            try await client.publish("t", string: "x", qos: .atLeastOnce)
            await client.disconnect()
        }
        // Without the client certificate the handshake fails.
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .tls(host: "127.0.0.1", port: server.port, options: TLSOptions(trust: .any)), clientID: "c", connectTimeout: .seconds(5)
            )
        )
        await #expect(throws: (any Error).self) { try await client.connect() }
    }

    @Test func mqttsWithASelfSignedBroker() async throws {
        let server = try await TestSocketServer(mode: .mqtt, tls: true)
        defer { Task { await server.stop() } }
        let configuration = try MQTTConfiguration(url: URL(string: "mqtts://u:p@127.0.0.1:\(server.port)")!, clientID: "c", tls: TLSOptions(trust: .any))
        let client = MQTTClient(configuration)
        try await client.connect()
        #expect(server.broker.connects.first?.username == "u")
        await client.disconnect()
    }

    @Test func overAWebSocketWithAFreshURLEachAttempt() async throws {
        let server = try await TestSocketServer(mode: .mqttOverWebSocket, tls: true)
        defer { Task { await server.stop() } }
        let attempts = NIOLockedValueBox(0)
        let port = server.port
        let client = MQTTClient(
            MQTTConfiguration(
                transport: .webSocket(
                    url: {
                        let attempt = attempts.withLockedValue { value in
                            value += 1
                            return value
                        }
                        return URL(string: "wss://127.0.0.1:\(port)/mqtt?X-Amz-Signature=\(attempt)")!
                    },
                    options: WebSocket.Options(tls: TLSOptions(trust: .any))
                ),
                clientID: "SERIAL_App_Token", reconnect: MQTTConfiguration.Reconnect(delay: .milliseconds(50))
            )
        )
        let messages = Recorder(client.messages)
        try await client.connect()
        try await client.subscribe("$aws/things/SERIAL/shadow/get/accepted", qos: .atLeastOnce)
        try await client.publish("$aws/things/SERIAL/shadow/get/accepted", string: "{}", qos: .atLeastOnce)
        try await eventually { messages.all.map(\.string) == ["{}"] }
        #expect(server.webSocket.requests.first?.headers.first(name: "Sec-WebSocket-Protocol") == "mqtt")

        server.broker.dropAll()
        try await eventually { server.broker.subscribes.count == 2 }
        #expect(server.webSocket.requests.map(\.uri) == ["/mqtt?X-Amz-Signature=1", "/mqtt?X-Amz-Signature=2"])
        await client.disconnect()
    }
}
