import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The robot's AWS IoT thing shadow over MQTT, the way the MyDolphin Plus app talks to it:
///
/// - MQTT 3.1.1 over a WebSocket whose URL is presigned with SigV4 (`wss://<endpoint>/mqtt`, service
///   `iotdevicegateway`, the `mqtt` subprotocol), clean session;
/// - subscribes to `$aws/things/<thing>/shadow/{update,get}/{accepted,rejected}` and `Maytronics/<thing>/main`;
/// - reads the shadow by publishing to `…/shadow/get`, commands the robot by publishing a desired state to
///   `…/shadow/update`.
///
/// The thing name is the serial number's first 8 characters. Each request carries a `clientToken` that AWS
/// IoT echoes, so a response is matched to its request and the phone app's traffic on the same robot is
/// ignored. The MyDolphin AWS account is shared by every user and throttles shadow requests (429
/// TOO_MANY_REQUESTS): requests are spaced out, retried with backoff, and throttling is reported only once
/// retries are exhausted, at most every ten minutes.
///
/// Every connection attempt presigns the URL again with the credentials of the moment. After a drop the
/// client reconnects every 5 seconds and renews its subscriptions; after `maximumReconnectAttempts` attempts
/// in a row it gives up, and the next shadow request opens a new connection.
actor ShadowClient {
    typealias MQTTFactory = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    enum Response: Sendable, Equatable {
        case accepted(JSONValue)
        case rejected(JSONValue)
    }

    private struct Pending {
        var continuation: CheckedContinuation<Response, any Error>
        /// A `get` only asks for the current document, so an untagged push answers it just as well; an
        /// update must see its own response.
        var acceptsUntagged: Bool
        var timeout: Task<Void, Never>
    }

    static let rateLimitCode = 429
    static let previewLength = 200
    static let iotService = "iotdevicegateway"
    /// How long the presigned URL is valid (`X-Amz-Expires`): a day.
    static let signatureLifetime = 86_400
    static let maximumReconnectAttempts = 5

    let thingName: String
    /// The connection's settings. The client id is `<thing name>_App_Token`: the IAM policy of the MyDolphin
    /// account only lets this client id in, and AWS IoT drops the older of two connections with the same id.
    let configuration: MQTTConfiguration
    /// The broker's URL, unsigned, for the log.
    private let url: URL
    private let makeConnection: MQTTFactory
    private let timing: DolphinTiming
    private let logger: Logger

    private var connection: (any MQTTConnection)?
    private var generation = 0
    private var eventTasks: [Task<Void, Never>] = []
    private(set) var isConnected = false
    private var connectTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var connectWaiters: [CheckedContinuation<Void, any Error>] = []
    private(set) var lastShadowReceivedAt: ContinuousClock.Instant?
    private var onShadow: (@Sendable (JSONValue) async -> Void)?
    private let credentials: @Sendable () -> IoTCredentials?

    private var pending: [String: Pending] = [:]
    /// The pending tokens in the order they were sent.
    private var pendingOrder: [String] = []
    private var requestCounter = 0
    private var lastRequestAt: ContinuousClock.Instant?
    private var pendingGet: Task<JSONValue, any Error>?
    private var throttledRequests = 0
    private var lastThrottleLog: ContinuousClock.Instant?

    init(
        serialNumber: String, endpoint: String, region: String, mqtt: @escaping MQTTFactory = { MQTTClient($0) }, timing: DolphinTiming = .standard,
        logger: Logger, credentials: @escaping @Sendable () -> IoTCredentials?
    ) {
        thingName = String(serialNumber.prefix(Maytronics.thingNameLength))
        url = URL(string: "wss://\(endpoint)/mqtt")!
        let presign: @Sendable () async throws -> URL = {
            guard let credentials = credentials() else { throw DolphinError.mqttConnectionFailed("AWS credentials not available") }
            return AWSSignatureV4.presignIoTURL(
                endpoint: endpoint, region: region,
                credentials: AWSCredentials(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey, sessionToken: credentials.sessionToken),
                expires: Self.signatureLifetime, service: Self.iotService)
        }
        configuration = MQTTConfiguration(
            transport: .webSocket(url: presign), clientID: "\(thingName)_App_Token", keepAlive: .seconds(30), cleanSession: true,
            connectTimeout: timing.mqttConnectTimeout, reconnect: .init(delay: .seconds(5), maximumDelay: .seconds(5)))
        makeConnection = mqtt
        self.credentials = credentials
        self.timing = timing
        self.logger = logger
    }

    /// Called with every shadow document that arrives, pushed by the robot or answering a request.
    func setShadowHandler(_ handler: @escaping @Sendable (JSONValue) async -> Void) { onShadow = handler }

    var topics: [String] {
        [
            "$aws/things/\(thingName)/shadow/update/accepted",
            "$aws/things/\(thingName)/shadow/update/rejected",
            "$aws/things/\(thingName)/shadow/get/accepted",
            "$aws/things/\(thingName)/shadow/get/rejected",
            "Maytronics/\(thingName)/main",
        ]
    }

    // MARK: Connection

    /// Connects to AWS IoT and subscribes. Concurrent callers share one attempt, and the attempt always
    /// settles: it is bounded by `mqttConnectTimeout`.
    func connect() async throws {
        if isConnected {
            logger.debug("MQTT client already connected")
            return
        }
        // Without credentials there is nothing to sign: say so at once rather than when the transport gets to it,
        // which a slow machine may not reach before the connect timeout.
        guard credentials() != nil else { throw DolphinError.mqttConnectionFailed("AWS credentials not available") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connectWaiters.append(continuation)
            if connectTask == nil { startConnecting() }
        }
    }

    private func startConnecting() {
        generation += 1
        let attempt = generation
        let configuration = configuration, makeConnection = makeConnection
        logger.debug("Connecting to AWS IoT MQTT: \(url.absoluteString) (client ID \(configuration.clientID))")
        connectTask = Task {
            do {
                let connection = try await makeConnection(configuration)
                // The streams are taken before connecting, so nothing the broker sends is missed.
                let messages = connection.messages, states = connection.states
                do {
                    try await connection.connect()
                } catch {
                    await connection.disconnect()
                    throw error
                }
                await self.didConnect(connection, messages: messages, states: states, attempt: attempt)
            } catch {
                self.connectFailed(error, attempt: attempt)
            }
        }
        let timeout = timing.mqttConnectTimeout
        connectTimeout = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await self.connectTimedOut(attempt: attempt)
        }
    }

    private func didConnect(
        _ connection: any MQTTConnection, messages: AsyncStream<MQTTMessage>, states: AsyncStream<MQTTConnectionState>, attempt: Int
    ) async {
        guard attempt == generation, connectTask != nil else {
            // Timed out or disconnected meanwhile.
            await connection.disconnect()
            return
        }
        connectTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        self.connection = connection
        isConnected = true
        eventTasks = [
            Task {
                for await message in messages {
                    await self.handle(message, generation: attempt)
                }
            },
            Task { await self.watch(states, generation: attempt) },
        ]
        await subscribeToTopics()
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func connectFailed(_ error: any Error, attempt: Int) {
        guard attempt == generation, connectTask != nil else { return }
        logger.error("MQTT error: \(error)")
        connectTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        failConnectWaiters(DolphinError.mqttConnectionFailed("\(error)"))
    }

    private func connectTimedOut(attempt: Int) async {
        guard attempt == generation, connectTask != nil else { return }
        failConnectWaiters(DolphinError.mqttConnectionFailed("Timed out connecting to AWS IoT"))
        await disconnect()
    }

    private func failConnectWaiters(_ error: DolphinError) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// The client renews these itself after a reconnect.
    private func subscribeToTopics() async {
        guard let connection else { return }
        for topic in topics {
            do {
                try await connection.subscribe(topic, qos: .atLeastOnce)
            } catch {
                logger.warning("Failed to subscribe to \(topic): \(error)")
            }
        }
    }

    private func handle(_ message: MQTTMessage, generation: Int) async {
        guard generation == self.generation else { return }
        await handleMessage(topic: message.topic, payload: message.payload)
    }

    /// Follows the connection: a drop, the reconnection, and giving up after `maximumReconnectAttempts`
    /// attempts in a row.
    private func watch(_ states: AsyncStream<MQTTConnectionState>, generation: Int) async {
        var lost = false
        var attempts = 0
        for await state in states {
            guard generation == self.generation else { return }
            switch state {
            case .connected:
                if lost {
                    isConnected = true
                    logger.debug("MQTT reconnected")
                }
                lost = false
                attempts = 0
            case .connectionLost:
                if !lost {
                    isConnected = false
                    logger.debug("MQTT connection lost, reconnecting")
                }
                lost = true
            case .connecting:
                guard lost else { continue }
                attempts += 1
                if attempts > Self.maximumReconnectAttempts {
                    logger.error("Max reconnection attempts reached: gave up after \(Self.maximumReconnectAttempts) reconnection attempts")
                    await disconnect()
                    return
                }
            case .disconnected:
                break
            }
        }
    }

    /// Closes the connection. A connection attempt in progress fails, and so do the requests waiting for an
    /// answer instead of waiting for their timeouts.
    func disconnect() async {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        failConnectWaiters(DolphinError.notConnected("MQTT disconnected before the connection completed"))
        for task in eventTasks { task.cancel() }
        eventTasks = []
        let connection = connection
        self.connection = nil
        isConnected = false
        for token in pendingOrder {
            guard let request = pending.removeValue(forKey: token) else { continue }
            request.timeout.cancel()
            request.continuation.resume(throwing: DolphinError.notConnected("MQTT disconnected while waiting for a shadow response"))
        }
        pendingOrder.removeAll()
        await connection?.disconnect()
    }

    // MARK: Messages

    func handleMessage(topic: String, payload: Data) async {
        guard let message = try? JSONValue(data: payload) else {
            logger.debug("Failed to parse MQTT message on \(topic)")
            return
        }
        logger.debug("MQTT message on \(topic): \(String(message.text().prefix(Self.previewLength)))")
        // AWS IoT echoes the clientToken we sent, which tells our responses from anyone else's.
        let token = message["clientToken"]?.stringValue

        if topic.contains("/shadow/get/accepted") || topic.contains("/shadow/update/accepted") {
            // An echo of a desired-only update carries no robot state: polling must not take it as fresh.
            if message["state"]?["reported"].isTruthy == true {
                lastShadowReceivedAt = .now
            }
            await onShadow?(message)
            settle(token: token, .accepted(message))
        } else if topic.contains("/shadow/get/rejected") || topic.contains("/shadow/update/rejected") {
            logRejection(message)
            settle(token: token, .rejected(message))
        } else if topic.contains("Maytronics/"), topic.contains("/main") {
            logger.debug("Dynamic channel message received")
        }
    }

    /// Hands a response to the request that asked for it.
    ///
    /// A matching token settles that request; a foreign one (the phone app on the same robot) settles nothing.
    /// `update/accepted` is also broadcast without a token when the robot reports its own state: that answers
    /// a pending `get`, but is never taken as acceptance of an update, and an untagged rejection is nobody's.
    private func settle(token: String?, _ response: Response) {
        let key = token ?? untaggedRecipient(response)
        guard let key, let request = pending.removeValue(forKey: key) else { return }
        pendingOrder.removeAll { $0 == key }
        request.timeout.cancel()
        request.continuation.resume(returning: response)
    }

    private func untaggedRecipient(_ response: Response) -> String? {
        guard case .accepted = response else { return nil }
        return pendingOrder.first { pending[$0]?.acceptsUntagged == true }
    }

    static func isRateLimited(_ rejection: JSONValue) -> Bool {
        rejection["code"]?.doubleValue == Double(rateLimitCode) || rejection["message"]?.stringValue == "TOO_MANY_REQUESTS"
    }

    /// Throttling is expected on the shared account and retried, so it is only counted here and reported by
    /// `reportThrottling` once the retries are exhausted.
    private func logRejection(_ rejection: JSONValue) {
        if Self.isRateLimited(rejection) {
            throttledRequests += 1
            logger.debug("Shadow operation throttled by AWS IoT (429 TOO_MANY_REQUESTS), will retry")
            return
        }
        logger.warning("Shadow operation rejected: \(rejection.text())")
    }

    private func reportThrottling(_ operation: String, attempts: Int) {
        let now = ContinuousClock.now
        if let lastThrottleLog, now - lastThrottleLog < timing.throttleLogInterval {
            logger.debug("\(operation) gave up after \(attempts) throttled attempts")
            return
        }
        logger.warning(
            "\(operation) throttled by AWS IoT after \(attempts) attempts (\(throttledRequests) throttled request(s) so far). This is a temporary MyDolphin cloud limit; state will refresh on the next poll."
        )
        lastThrottleLog = now
        throttledRequests = 0
    }

    // MARK: Requests

    private func ensureConnected() throws {
        guard isConnected, connection != nil else { throw DolphinError.notConnected("MQTT client not connected") }
    }

    private func nextClientToken() -> String {
        requestCounter = requestCounter == Int.max ? 1 : requestCounter + 1
        return "\(thingName)-\(requestCounter)"
    }

    /// Spaces shadow publishes out, so a burst (set mode, start, refresh) does not trip the throttle. Slots
    /// are reserved in call order.
    private func awaitRequestSlot() async {
        let now = ContinuousClock.now
        let slot = lastRequestAt.map { max(now, $0 + timing.minimumRequestInterval) } ?? now
        lastRequestAt = slot
        if slot > now { try? await Task.sleep(until: slot) }
    }

    /// Publishes one request and waits for its response, or fails after `shadowTimeout`.
    private func waitForResponse(acceptsUntagged: Bool, publish: @escaping @Sendable (String) async throws -> Void) async throws -> Response {
        let token = nextClientToken()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, any Error>) in
            register(token: token, continuation: continuation, acceptsUntagged: acceptsUntagged, publish: publish)
        }
    }

    private func register(
        token: String, continuation: CheckedContinuation<Response, any Error>, acceptsUntagged: Bool, publish: @escaping @Sendable (String) async throws -> Void
    ) {
        let timeout = timing.shadowTimeout
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            self.fail(token: token, DolphinError.shadowTimeout)
        }
        pending[token] = Pending(continuation: continuation, acceptsUntagged: acceptsUntagged, timeout: timer)
        pendingOrder.append(token)
        Task {
            do {
                try await publish(token)
            } catch {
                self.fail(token: token, DolphinError.notConnected("Could not publish the shadow request: \(error)"))
            }
        }
    }

    private func fail(token: String, _ error: DolphinError) {
        guard let request = pending.removeValue(forKey: token) else { return }
        pendingOrder.removeAll { $0 == token }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    /// Publishes a request, retrying with backoff while AWS IoT answers 429.
    private func request(
        _ operation: String, policy: RetryPolicy, acceptsUntagged: Bool, publish: @escaping @Sendable (String) async throws -> Void
    ) async throws -> Response {
        var lastError: JSONValue = ["code": .number(Double(Self.rateLimitCode)), "message": "TOO_MANY_REQUESTS"]
        for attempt in 1...max(1, policy.attempts) {
            await awaitRequestSlot()
            try ensureConnected()
            let response = try await waitForResponse(acceptsUntagged: acceptsUntagged, publish: publish)
            guard case .rejected(let rejection) = response, Self.isRateLimited(rejection) else { return response }
            lastError = rejection
            if attempt < policy.attempts {
                let backoff = timing.backoff(attempt: attempt, policy: policy)
                logger.debug("\(operation) throttled, retrying in \(backoff) (attempt \(attempt)/\(policy.attempts))")
                try? await Task.sleep(for: backoff)
            }
        }
        reportThrottling(operation, attempts: policy.attempts)
        return .rejected(lastError)
    }

    private func publish(_ topic: String, _ message: JSONValue) async throws {
        guard let connection else { throw DolphinError.notConnected("MQTT client not connected") }
        try await connection.publish(topic, payload: message.encoded(), qos: .atLeastOnce)
    }

    /// The current shadow. Concurrent callers share one request.
    func getShadow() async throws -> JSONValue {
        try ensureConnected()
        if let pendingGet {
            logger.debug("Reusing in-flight shadow request")
            return try await pendingGet.value
        }
        let topic = "$aws/things/\(thingName)/shadow/get"
        let task = Task { () throws -> JSONValue in
            let response = try await self.request("Shadow request", policy: self.timing.pollRetry, acceptsUntagged: true) { token in
                try await self.publish(topic, ["clientToken": .string(token)])
                self.logger.debug("Requested shadow on \(topic)")
            }
            switch response {
            case .accepted(let shadow):
                return shadow
            case .rejected(let rejection):
                let message = "Shadow request rejected: \(rejection.text())"
                throw Self.isRateLimited(rejection) ? DolphinError.shadowRateLimited(message) : DolphinError.shadowRejected(message)
            }
        }
        pendingGet = task
        defer { pendingGet = nil }
        return try await task.value
    }

    /// Sends a desired state. Retries are short because HomeKit waits on the result.
    func updateShadow(_ desired: JSONValue) async throws -> Bool {
        try ensureConnected()
        let topic = "$aws/things/\(thingName)/shadow/update"
        let response = try await request("Shadow update", policy: timing.commandRetry, acceptsUntagged: false) { token in
            let message: JSONValue = ["state": ["desired": desired], "clientToken": .string(token)]
            try await self.publish(topic, message)
            self.logger.debug("Published shadow update on \(topic): \(String(message.text().prefix(Self.previewLength)))")
        }
        if case .rejected(let rejection) = response, !Self.isRateLimited(rejection) {
            logger.error("Shadow update rejected: \(rejection.text())")
        }
        if case .accepted = response { return true }
        return false
    }
}
