import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import HomeswiftDolphinPoolCleaner

/// The Homebridge plugin's MQTT client tests: connection, throttling, matching responses to requests.
@Suite(.timeLimit(.minutes(1)))
struct ShadowClientTests {
    let broker = FakeBroker()
    let log = LogRecorder()
    let thing = "E3086OFG"
    static let throttled: JSONValue = ["code": 429, "message": "TOO_MANY_REQUESTS"]
    static let shadow: JSONValue = ["state": ["reported": [:]], "version": 7]

    func client(credentials: CredentialsBox = .testCredentials, timing: DolphinTiming = .fast) -> ShadowClient {
        ShadowClient(
            serialNumber: "E3086OFG2M", endpoint: "mock-iot-endpoint.iot.eu-west-1.amazonaws.com", region: "eu-west-1", mqtt: broker.factory,
            timing: timing, logger: log.logger, credentials: { credentials.value })
    }

    /// `payload` with the request's token, for a broker that echoes it.
    static func tagged(_ payload: JSONValue, _ token: String?) -> JSONValue {
        guard case .object(var object) = payload, let token else { return payload }
        object["clientToken"] = .string(token)
        return .object(object)
    }

    func connected(timing: DolphinTiming = .fast) async throws -> ShadowClient {
        let client = client(timing: timing)
        try await client.connect()
        return client
    }

    // MARK: Connection

    @Test func connectsAndSubscribes() async throws {
        let client = try await connected()
        #expect(await client.isConnected)
        let connection = try #require(broker.connections.first)
        #expect(connection.subscriptions == [
            "$aws/things/\(thing)/shadow/update/accepted", "$aws/things/\(thing)/shadow/update/rejected",
            "$aws/things/\(thing)/shadow/get/accepted", "$aws/things/\(thing)/shadow/get/rejected", "Maytronics/\(thing)/main",
        ])
        #expect(connection.mqtt.subscriptions.values.allSatisfy { $0 == .atLeastOnce })
        // The client id the MyDolphin IAM policy expects, on a clean session as the app connects.
        let configuration = try #require(broker.lastConfiguration)
        #expect(configuration.clientID == "E3086OFG_App_Token")
        #expect(configuration.cleanSession)
        #expect(configuration.keepAlive == .seconds(30))
        #expect(configuration.reconnect == .init(delay: .seconds(5), maximumDelay: .seconds(5)))
        let url = try await broker.presignedURL().absoluteString
        #expect(url.hasPrefix("wss://mock-iot-endpoint.iot.eu-west-1.amazonaws.com/mqtt?"))
        #expect(url.contains("%2Feu-west-1%2Fiotdevicegateway%2Faws4_request"))
        #expect(url.contains("X-Amz-Expires=86400"))
    }

    @Test func notConnectedRequestsFail() async {
        let client = client()
        await #expect(throws: DolphinError.notConnected("MQTT client not connected")) { try await client.getShadow() }
        await #expect(throws: DolphinError.notConnected("MQTT client not connected")) { try await client.updateShadow(["test": true]) }
    }

    @Test func aBrokerThatNeverAnswersTimesOut() async {
        broker.behavior = .hang
        let client = client(timing: .timesOut)
        await #expect(throws: DolphinError.mqttConnectionFailed("Timed out connecting to AWS IoT")) { try await client.connect() }
        #expect(await !client.isConnected)
    }

    @Test func aRefusedConnectionFails() async {
        broker.behavior = .fail
        let client = client()
        await #expect(throws: DolphinError.self) { try await client.connect() }
        #expect(log.contains(.error, "MQTT error"))
    }

    @Test func disconnectingRejectsAPendingConnection() async throws {
        broker.behavior = .hang
        let client = client()
        let attempt = Task { try await client.connect() }
        #expect(await eventually { broker.connectCount == 1 })
        await client.disconnect()
        await #expect(throws: DolphinError.notConnected("MQTT disconnected before the connection completed")) { try await attempt.value }
    }

    @Test func concurrentCallersShareOneAttempt() async throws {
        let client = client()
        async let first: Void = client.connect()
        async let second: Void = client.connect()
        _ = try await (first, second)
        #expect(broker.connectCount == 1)
    }

    @Test func everyAttemptReadsTheCurrentCredentials() async throws {
        let credentials = CredentialsBox()
        credentials.set(.test)
        let client = client(credentials: credentials)
        try await client.connect()
        #expect(try await broker.presignedURL().absoluteString.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F"))
        credentials.set(IoTCredentials(accessKeyID: "AKIAREFRESHED", secretAccessKey: "s", sessionToken: "new token/+=", expiration: .distantFuture))
        // A reconnect signs with what the provider gives then.
        #expect(try await broker.presignedURL().absoluteString.contains("X-Amz-Credential=AKIAREFRESHED%2F"))
    }

    @Test func reconnectsKeepTheSubscriptions() async throws {
        let client = try await connected()
        let connection = try #require(broker.connections.first)
        connection.mqtt.setState(.connectionLost("dropped"))
        #expect(await eventually { await !client.isConnected })
        connection.mqtt.setState(.connecting)
        connection.mqtt.setState(.connected(sessionPresent: false))
        #expect(await eventually { await client.isConnected })
        // The MQTT client renews them on its own.
        #expect(connection.subscriptions.count == 5)
        #expect(log.contains(.debug, "MQTT reconnected"))
    }

    @Test func givingUpCloses() async throws {
        let client = try await connected()
        let connection = try #require(broker.connections.first)
        // Five attempts in a row are retried.
        connection.mqtt.setState(.connectionLost("dropped"))
        for _ in 0..<5 { connection.mqtt.setState(.connecting) }
        connection.mqtt.setState(.connected(sessionPresent: false))
        #expect(await eventually { await client.isConnected })
        #expect(!connection.isClosed)
        // The sixth gives up.
        connection.mqtt.setState(.connectionLost("dropped"))
        for _ in 0..<6 { connection.mqtt.setState(.connecting) }
        #expect(await eventually { connection.isClosed })
        #expect(await !client.isConnected)
        #expect(log.contains(.error, "Max reconnection attempts reached: gave up after 5 reconnection attempts"))
    }

    @Test func onlyShadowsWithReportedStateAreFresh() async {
        let client = client()
        // The echo of a desired-only update (ours or the phone app's).
        await client.handleMessage(topic: "$aws/things/\(thing)/shadow/update/accepted", payload: (["state": ["desired": ["a": 1]], "version": 3] as JSONValue).encoded())
        #expect(await client.lastShadowReceivedAt == nil)
        await client.handleMessage(topic: "$aws/things/\(thing)/shadow/update/accepted", payload: (["state": ["reported": ["a": 1]], "version": 4] as JSONValue).encoded())
        #expect(await client.lastShadowReceivedAt != nil)
    }

    // MARK: Throttling and matching

    @Test func throttledRequestIsRetried() async throws {
        let thing = thing
        broker.respond { attempt, message in
            attempt == 1
                ? ("$aws/things/\(thing)/shadow/get/rejected", Self.tagged(Self.throttled, message.clientToken))
                : ("$aws/things/\(thing)/shadow/get/accepted", Self.tagged(Self.shadow, message.clientToken))
        }
        let client = try await connected()
        let shadow = try await client.getShadow()
        #expect(shadow["version"] == 7)
        #expect(broker.published.count == 2)
        // Throttling a retry resolves is not worth a warning.
        #expect(log.warnings.isEmpty)
    }

    @Test func throttlingOnEveryAttemptWarnsOnce() async throws {
        let thing = thing
        broker.respond { _, message in ("$aws/things/\(thing)/shadow/get/rejected", Self.tagged(Self.throttled, message.clientToken)) }
        let client = try await connected()
        await #expect(throws: DolphinError.self) { try await client.getShadow() }
        #expect(broker.published.count == 3)
        #expect(log.warnings.count == 1)
        #expect(log.warnings.first?.contains("throttled by AWS IoT") == true)
        // The error says it was throttling, which the cloud keeps quiet about.
        do {
            _ = try await client.getShadow()
        } catch let error as DolphinError {
            #expect(error.isTransient)
            #expect(error.description.contains("Shadow request rejected"))
        }
        // The second report within ten minutes is a debug line.
        #expect(log.warnings.count == 1)
    }

    @Test func otherRejectionsWarn() async throws {
        let thing = thing
        broker.respond { _, message in ("$aws/things/\(thing)/shadow/get/rejected", Self.tagged(["code": 403, "message": "Forbidden"], message.clientToken)) }
        let client = try await connected()
        await #expect(throws: DolphinError.self) { try await client.getShadow() }
        #expect(log.contains(.warning, "Shadow operation rejected"))
        #expect(broker.published.count == 1)
    }

    @Test func concurrentReadsShareOneRequest() async throws {
        let client = try await connected()
        async let first = client.getShadow()
        async let second = client.getShadow()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(broker.published.count == 1)
    }

    @Test func throttledCommandsRetryLess() async throws {
        let thing = thing
        broker.respond { _, message in ("$aws/things/\(thing)/shadow/update/rejected", Self.tagged(Self.throttled, message.clientToken)) }
        let client = try await connected()
        // HomeKit waits on a command, so it gives up after 2 attempts.
        #expect(try await client.updateShadow(["systemState": ["pwsState": "on"]]) == false)
        #expect(broker.published.count == 2)
    }

    @Test func robotPushIsNoAcceptanceOfACommand() async throws {
        let thing = thing
        broker.respond { _, message in ("$aws/things/\(thing)/shadow/update/rejected", Self.tagged(["code": 400, "message": "Invalid state"], message.clientToken)) }
        let client = try await connected()
        let command = Task { try await client.updateShadow(["systemState": ["pwsState": "on"]]) }
        // The robot reports its own state meanwhile: broadcast, no client token.
        await client.handleMessage(topic: "$aws/things/\(thing)/shadow/update/accepted", payload: Self.shadow.encoded())
        #expect(try await command.value == false)
        #expect(log.contains(.error, "Shadow update rejected"))
    }

    @Test func untaggedPushAnswersAPendingGet() async throws {
        let thing = thing
        // A broker that does not echo the token.
        broker.respond { _, _ in ("$aws/things/\(thing)/shadow/get/accepted", Self.shadow) }
        let client = try await connected()
        #expect(try await client.getShadow()["version"] == 7)
    }

    @Test func untaggedRejectionIsNobodys() async throws {
        let thing = thing
        broker.respond { _, _ in ("$aws/things/\(thing)/shadow/get/rejected", ["code": 403, "message": "Forbidden"]) }
        let client = try await connected(timing: .timesOut)
        await #expect(throws: DolphinError.shadowTimeout) { try await client.getShadow() }
    }

    @Test func droppingTheConnectionFailsWaitingRequests() async throws {
        broker.respond { _, _ in nil }
        let client = try await connected()
        let request = Task { try await client.getShadow() }
        #expect(await eventually { broker.published.count == 1 })
        await client.disconnect()
        await #expect(throws: DolphinError.notConnected("MQTT disconnected while waiting for a shadow response")) { try await request.value }
    }

    @Test func aForeignTokenSettlesNothing() async throws {
        let thing = thing
        broker.respond { _, _ in nil }
        let client = try await connected()
        let request = Task { try await client.getShadow() }
        #expect(await eventually { broker.published.count == 1 })
        // A rejection meant for the phone app must not fail our pending request.
        await client.handleMessage(topic: "$aws/things/\(thing)/shadow/get/rejected", payload: Self.tagged(Self.throttled, "someone-else-1").encoded())
        let token = broker.published.first?.clientToken
        await client.handleMessage(topic: "$aws/things/\(thing)/shadow/get/accepted", payload: Self.tagged(Self.shadow, token).encoded())
        #expect(try await request.value["version"] == 7)
        #expect(broker.published.count == 1)
    }

    @Test func requestsAreSpacedOut() async throws {
        let client = try await connected()
        let started = ContinuousClock.now
        _ = try await client.updateShadow(["a": 1])
        _ = try await client.updateShadow(["a": 2])
        _ = try await client.updateShadow(["a": 3])
        #expect(ContinuousClock.now - started >= .milliseconds(10))
        #expect(broker.published.map(\.desired) == [["a": 1], ["a": 2], ["a": 3]])
        #expect(Set(broker.published.compactMap(\.clientToken)).count == 3)
    }
}

extension IoTCredentials {
    static let test = IoTCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: "mock-session-token",
        expiration: Date(timeIntervalSince1970: 4_070_908_800))
}

extension CredentialsBox {
    static var testCredentials: CredentialsBox {
        let box = CredentialsBox()
        box.set(.test)
        return box
    }
}
