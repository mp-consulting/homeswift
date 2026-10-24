import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The part of the UniFi Access API the plugin needs (`unifi-access` 1.5.3 as the Homebridge plugin ported it):
/// login with the CSRF token and session cookie of UniFi OS, the bootstrap (controller, floors, doors, devices,
/// Enterprise hubs as one device per door), unlocking, and the realtime events WebSocket with its heartbeat
/// watchdog and backed-off reconnection.
///
/// Requests back off after ten errors in a row for five minutes, so a controller that is restarting is not
/// hammered. Controllers have self-signed certificates: unless `verifyTLS` is on, the first certificate seen is
/// pinned and a different one refused, before any credentials are sent on later connections.
actor AccessAPI {
    enum Event: Sendable {
        case bootstrap
        case message(AccessEventPacket)
    }

    /// The delays of the API; tests shorten them.
    struct Timing: Sendable {
        var requestTimeout: Duration = .milliseconds(3500)
        var heartbeatTimeout: Duration = .seconds(10)
        var reconnectMinimum: Duration = .seconds(1)
        var reconnectMaximum: Duration = .seconds(60)
        var throttle: Duration = .seconds(300)
        var retryMinimum: Duration = .milliseconds(100)
        var retryMaximum: Duration = .milliseconds(1500)
    }

    static let errorLimit = 10
    static let maximumEventSize = 4 * 1024 * 1024
    static let retryStatuses: Set<Int> = [429, 500, 502, 503, 504]
    static let serverErrors: Set<Int> = [400, 404, 429, 500, 502, 503]
    static let retryErrnos: Set<Int32> = [ECONNREFUSED, ECONNRESET, EHOSTUNREACH, EPIPE, ETIMEDOUT]
    static let heartbeat = "\"Hello\"\n"

    /// An HTTP client for a TLS mode: the system's roots, any certificate (first use), or the pinned one.
    typealias HTTPFactory = @Sendable (HTTPClient.TLS) -> any HTTPSending
    /// Opens the events WebSocket.
    typealias EventsConnector = @Sendable (URL, WebSocket.Options) async throws -> any WebSocketConnection

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let logger: Logger
    private let http: HTTPFactory
    /// nil for the settings page's one-off connections, which need no events.
    private let eventsConnector: EventsConnector?
    private let verifyTLS: Bool
    let trust: HTTPClient.TrustOnFirstUse
    /// Logged after a refused certificate: how to trust a new one.
    private let mismatchHint: String?
    private let timing: Timing

    private(set) var controller: AccessControllerInfo?
    private(set) var bootstrap: [String: JSONValue]?
    private(set) var devices: [AccessDevice]?
    private(set) var doors: [AccessDoor]?
    private(set) var isThrottled = false

    private var address = ""
    private var username = ""
    private var password = ""
    private var headers: [String: String] = [:]
    private var apiErrorCount = 0
    private var apiLastSuccess = ContinuousClock.now
    private var isClosed = false
    private var socket: (any WebSocketConnection)?
    private var socketGeneration = 0
    private var reader: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var client: (tls: HTTPClient.TLS, client: any HTTPSending)?

    init(
        logger: Logger, http: @escaping HTTPFactory, events: EventsConnector?, verifyTLS: Bool, trust: HTTPClient.TrustOnFirstUse, mismatchHint: String? = nil,
        timing: Timing = Timing()
    ) {
        self.logger = logger
        self.http = http
        eventsConnector = events
        self.verifyTLS = verifyTLS
        self.trust = trust
        self.mismatchHint = mismatchHint
        self.timing = timing
        (self.events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1000))
    }

    // MARK: Names and endpoints

    /// The controller's alias or name once bootstrapped, its address before.
    var name: String {
        if let alias = bootstrap?["alias"]?.stringValue, !alias.isEmpty { return alias }
        if let name = bootstrap?["name"]?.stringValue, !name.isEmpty { return name }
        return address
    }

    /// `Name [Model]`, with the address and MAC when `deviceInfo`.
    nonisolated static func deviceName(_ device: AccessDevice, name: String? = nil, deviceInfo: Bool = false) -> String {
        let name = name ?? ((device.alias?.isEmpty == false) ? device.alias : device.name)
        let host = device.ip.map { $0.isEmpty ? "" : "address: \($0) " } ?? ""
        let type = (device.displayModel?.isEmpty == false ? device.displayModel : nil) ?? device.deviceType
        return "\(name ?? type) [\(type)]" + (deviceInfo ? " (\(host)mac: \(AccessSettings.normalizeMac(device.mac)))" : "")
    }

    /// `Controller Device [Model]`.
    func fullName(_ device: AccessDevice) -> String {
        let deviceName = Self.deviceName(device)
        return name + (deviceName.isEmpty ? "" : " \(deviceName)")
    }

    func endpoint(_ name: String) -> String {
        let prefix: String
        let suffix: String
        switch name {
        case "bootstrap": (prefix, suffix) = ("/proxy/access/api/v2/", "devices/topology4")
        case "controller": (prefix, suffix) = ("/proxy/access/api/v2/", "access/info")
        case "device": (prefix, suffix) = ("/proxy/access/api/v2/", "device")
        case "location": (prefix, suffix) = ("/proxy/access/api/v2/", "location")
        case "login": (prefix, suffix) = ("/api/", "auth/login")
        case "self": (prefix, suffix) = ("/api/", "users/self")
        case "settings": (prefix, suffix) = ("/proxy/access/api/v2/", "settings")
        case "websocket": (prefix, suffix) = ("/proxy/access/api/v2/", "ws")
        default: return ""
        }
        return "https://\(address)\(prefix)\(suffix)"
    }

    // MARK: Login

    /// Logs in, dropping any session first.
    func login(address: String, username: String, password: String) async -> Bool {
        self.address = address
        self.username = username
        self.password = password
        isClosed = false
        logout()
        return await loginController()
    }

    private func loginController() async -> Bool {
        if headers["cookie"] != nil, headers["x-csrf-token"] != nil { return true }
        // UniFi OS protects its API against cross-site requests: the token is in the headers of its home page.
        // It also pins the certificate on first use, before any credentials go out: the pin is recorded from a
        // response, so without one the password would go to a certificate no request has seen. Then this
        // request's failure is the one to log, as the login's would have been.
        let unpinned = isUnpinned
        if headers["x-csrf-token"] == nil || unpinned, let response = await retrieve("https://\(address)", logErrors: unpinned),
            let token = response.header("X-CSRF-Token") {
            headers["x-csrf-token"] = token
        }
        guard !isUnpinned else {
            logger.debug("\(name): No TLS certificate pinned for \(address) yet: not sending the login credentials.")
            return false
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["password": password, "rememberMe": true, "token": "", "username": username], options: [.sortedKeys])) ?? Data()
        guard let response = await retrieve(endpoint("login"), method: "POST", body: body) else {
            logout()
            return false
        }
        let token = response.header("X-Updated-CSRF-Token") ?? response.header("X-CSRF-Token")
        if let token, let cookie = response.header("Set-Cookie") {
            // The token part of the cookie, without its attributes.
            headers["cookie"] = String(cookie.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            headers["x-csrf-token"] = token
            return true
        }
        logout()
        return false
    }

    /// Trust on first use, with no certificate pinned yet.
    private var isUnpinned: Bool { !verifyTLS && trust.fingerprint == nil }

    /// Forgets the session, keeping the CSRF token.
    func logout() {
        reset()
        let token = headers["x-csrf-token"]
        headers = ["content-type": "application/json", "user-agent": "unifi-access"]
        if let token { headers["x-csrf-token"] = token }
    }

    /// Drops the bootstrap and the events connection.
    func reset() {
        bootstrap = nil
        doors = nil
        devices = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let socket {
            self.socket = nil
            socketGeneration += 1
            Task { await socket.close() }
        }
    }

    /// Closes for good: no reconnection until the next login.
    func close() {
        isClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        logout()
    }

    // MARK: Bootstrap

    /// Reads the controller and its devices, and connects to the events API. Retries once.
    func getBootstrap() async -> Bool {
        await bootstrapController(retry: true)
    }

    private func bootstrapController(retry: Bool) async -> Bool {
        // Closed (the plugin stopped) during a reconnection: no new session, no new events connection.
        guard !isClosed else { return false }
        guard await loginController() else { return retry ? await bootstrapController(retry: false) : false }

        func fetch(_ name: String) async -> JSONValue? {
            guard let response = await retrieve(endpoint(name)) else {
                logRetry("Unable to retrieve the UniFi Access \(name) configuration.", isRetry: retry)
                return nil
            }
            guard let json = try? JSONValue(data: response.body) else {
                logError("Unable to parse response from UniFi Access. Will retry again later.")
                return nil
            }
            return json
        }

        controller = await fetch("controller")?["data"]?.objectValue.map(AccessControllerInfo.init(json:))
        if controller == nil, retry { return await bootstrapController(retry: false) }

        bootstrap = await fetch("bootstrap")?["data"]?[0]?.objectValue
        if bootstrap == nil, retry { return await bootstrapController(retry: false) }

        let floorList = bootstrap?["floors"]?.arrayValue
        let doorList = (floorList ?? []).flatMap { $0["doors"]?.arrayValue ?? [] }.compactMap { AccessDoor($0) }
        doors = doorList.isEmpty ? nil : doorList

        var deviceList = (doors ?? []).flatMap(\.deviceGroups).compactMap { AccessDevice($0) }
        // Some controllers list device groups at the top level too, or instead.
        let topLevel = (bootstrap?["device_groups"]?.arrayValue ?? []).flatMap { $0.arrayValue ?? [$0] }.filter { !$0.isNull }
        deviceList += topLevel.compactMap { AccessDevice($0) }

        // Enterprise hubs: each extension (a door) becomes a device of its own that looks like a UA Hub, named
        // after its door and unlocking its door's location.
        for device in topLevel.compactMap({ AccessDevice($0) }) where device.deviceType == "UAH-Ent" {
            var base = device.json
            let extensions = base.removeValue(forKey: "extensions")?.arrayValue ?? []
            let alias = base.removeValue(forKey: "alias")
            let displayModel = base.removeValue(forKey: "display_model")?.stringValue ?? "undefined"
            let locationId = base.removeValue(forKey: "location_id")
            for case .object(var extensionJSON) in extensions {
                let targetName = extensionJSON.removeValue(forKey: "target_name")
                let targetValue = extensionJSON.removeValue(forKey: "target_value")
                var door = base.merging(extensionJSON) { $1 }
                door["alias"] = targetName?.nonNull ?? .string("Unknown")
                let sourceId = extensionJSON["source_id"]?.stringValue
                door["display_model"] = .string(displayModel + (sourceId.map { " " + Self.startCase($0) } ?? ""))
                door["location_id"] = targetValue?.nonNull ?? locationId ?? .null
                door["name"] = alias ?? .null
                deviceList.append(AccessDevice(door))
            }
        }
        devices = deviceList.isEmpty ? nil : deviceList

        guard bootstrap != nil, await launchEvents() else { return retry ? await bootstrapController(retry: false) : false }
        reconnectAttempts = 0
        continuation.yield(.bootstrap)
        return true
    }

    /// The first letter of every word in capitals: `port1` as `Port1`.
    static func startCase(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if character.isWhitespace {
                atWordStart = true
                result.append(character)
            } else {
                result += atWordStart ? character.uppercased() : String(character)
                atWordStart = false
            }
        }
        return result
    }

    // MARK: Events

    private func launchEvents() async -> Bool {
        guard await loginController() else { return false }
        guard let eventsConnector else { return true }
        if socket != nil { return true }
        guard let url = URL(string: "wss://\(address)/proxy/access/api/v2/ws/notification") else { return false }
        let opened: any WebSocketConnection
        do {
            // The session cookie, the API's certificate policy, and no message larger than an event can be.
            let options = WebSocket.Options(
                headers: [("Cookie", headers["cookie"] ?? "")], tls: TLSOptions(verifyTLS ? .system : trust.tls), timeout: .seconds(10),
                maximumMessageSize: Self.maximumEventSize)
            opened = try await eventsConnector(url, options)
        } catch {
            logError("Error connecting to the realtime update events API: \(error)")
            return false
        }
        if isClosed || socket != nil {
            // Closed while connecting (the plugin stopped), or another bootstrap connected meanwhile.
            await opened.close()
            return !isClosed
        }
        socket = opened
        socketGeneration += 1
        let generation = socketGeneration
        reader?.cancel()
        reader = Task { [weak self] in
            do {
                for try await message in opened.messages {
                    switch message {
                    case .text(let text): await self?.received(text)
                    case .binary(let data): await self?.received(String(decoding: data, as: UTF8.self))
                    }
                }
            } catch {
                await self?.logError("Events API error: \(error)")
            }
            await self?.socketClosed(generation: generation)
        }
        armHeartbeat()
        return true
    }

    private func received(_ message: String) {
        if message.isEmpty { return }
        // The controller says hello every five seconds.
        if message == Self.heartbeat || message.trimmingCharacters(in: .whitespacesAndNewlines) == "\"Hello\"" {
            armHeartbeat()
            return
        }
        guard let json = try? JSONValue(string: message), let packet = AccessEventPacket(json) else {
            logError("Error processing message from the events API: \(message.prefix(200))")
            return
        }
        continuation.yield(.message(packet))
    }

    /// The connection ended: when it was the current one, reconnect rather than wait for the next refresh.
    private func socketClosed(generation: Int) {
        guard generation == socketGeneration, socket != nil else { return }
        socket = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        scheduleReconnect()
    }

    private func armHeartbeat() {
        heartbeatTask?.cancel()
        let timeout = timing.heartbeatTimeout
        heartbeatTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.heartbeatMissed()
        }
    }

    private func heartbeatMissed() {
        logError("Failed to detect heartbeat from the events API. Resetting the connection.")
        reset()
        scheduleReconnect()
    }

    /// Bootstraps again after an exponential, jittered delay, which reconnects the events API.
    private func scheduleReconnect() {
        guard !isClosed, reconnectTask == nil else { return }
        let delay = Backoff(initial: timing.reconnectMinimum, maximum: timing.reconnectMaximum, jitter: .proportional(0.2)).delay(attempt: reconnectAttempts)
        reconnectAttempts += 1
        logger.debug("\(name): Reconnecting to the events API in \(delay).")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    /// The reconnection stays `reconnectTask` while it bootstraps, so `close()` cancels it there too.
    private func reconnect() async {
        guard !isClosed, !Task.isCancelled else { return }
        let connected = await getBootstrap()
        reconnectTask = nil
        // Failed, or the new connection dropped while this one finished (its own reconnection was skipped).
        if !isClosed, !connected || socket == nil { scheduleReconnect() }
    }

    // MARK: Unlocking

    /// Unlocks a hub's door. Without a duration, the controller's momentary unlock of its door's location; with
    /// one, a lock rule: 0 (or less) locks, infinity keeps it unlocked, otherwise that many minutes.
    func unlock(_ device: AccessDevice, minutes duration: Double? = nil) async -> Bool {
        guard device.has(capability: "is_hub") else { return false }
        var action = "unlock"
        let url: String
        let payload: [String: Any]
        if var duration {
            url = endpoint("device") + "/\(device.uniqueId)/lock_rule?get_result=true"
            if duration < 0 { duration = 0 }
            if duration == 0 {
                action = "lock"
                payload = ["type": "reset"]
            } else if duration.isInfinite {
                payload = ["type": "keep_unlock"]
            } else {
                payload = ["interval": Int(duration.rounded(.towardZero)), "type": "custom"]
            }
        } else {
            // A gate's door location from its port setting, else the device's own location.
            let location = device.extensions?.first { $0.extensionName == "port_setting" }?.targetValue ?? device.locationId ?? ""
            url = endpoint("location") + "/\(location)/unlock"
            payload = [:]
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        let model = device.displayModel ?? device.deviceType
        guard let response = await retrieve(url, method: "PUT", body: body) else {
            logError("\(fullName(device)): Unable to \(action) the \(model): undefined.")
            return false
        }
        guard let status = try? JSONValue(data: response.body) else {
            logError("\(fullName(device)): Unable to \(action) the \(model): invalid response received.")
            return false
        }
        if status["codeS"]?.stringValue == "SUCCESS" { return true }
        logError("\(fullName(device)): Error \(action)ing the \(model): \n\(status.text(pretty: true))")
        return false
    }

    // MARK: Requests

    /// Sends a request to the controller with the session's headers: retries transient failures of GETs, logs
    /// failures in plain words, backs off after repeated errors. nil when the request did not succeed.
    func retrieve(_ url: String, method: String = "GET", body: Data? = nil, logErrors: Bool = true) async -> HTTPResponse? {
        func fail(_ message: String) { if logErrors { logError(message) } }

        if apiErrorCount >= Self.errorLimit {
            if !isThrottled {
                apiLastSuccess = .now
                isThrottled = true
                logError("Throttling API calls due to errors with the \(apiErrorCount) previous attempts. Pausing communication with the Access controller for \(Self.minutes(timing.throttle)) minutes.")
                apiErrorCount += 1
                reset()
                return nil
            }
            if apiLastSuccess + timing.throttle > .now { return nil }
            logError("Resuming connectivity to the UniFi Access API after pausing for \(Self.minutes(timing.throttle)) minutes.")
            apiErrorCount = 0
            isThrottled = false
            guard await loginController() else { return nil }
        }

        guard let target = URL(string: url) else {
            apiErrorCount += 1
            fail("Error: invalid address | \(url).")
            return nil
        }
        var request = HTTPRequest(method: method, url: target, body: body, timeout: timing.requestTimeout)
        for (name, value) in headers { request.setHeader(name, value) }
        if body != nil, request.header("content-type") == nil { request.setHeader("content-type", "application/json") }

        let response: HTTPResponse
        do {
            response = try await send(request, retrying: ["GET", "HEAD"].contains(method.uppercased()))
        } catch {
            // Cancelled (the plugin stops): not the controller's fault.
            if error is CancellationError || Task.isCancelled { return nil }
            apiErrorCount += 1
            describe(error, url: url, log: fail)
            return nil
        }
        apiErrorCount += 1
        if response.status == 401 {
            logout()
            fail("Invalid login credentials given. Please check your login and password.")
            return nil
        }
        if response.status == 403 {
            fail("Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.")
            return nil
        }
        guard response.isSuccess else {
            if Self.serverErrors.contains(response.status) {
                fail("Unable to connect to the Access controller. This is usually temporary and will occur during device reboots.")
            } else {
                fail("\(response.status) - \(HTTPReason.phrase(response.status))")
            }
            return nil
        }
        apiLastSuccess = .now
        apiErrorCount = 0
        isThrottled = false
        return response
    }

    /// One request, retried with backoff on transient statuses and network errors when idempotent, within one
    /// overall deadline.
    private func send(_ request: HTTPRequest, retrying: Bool) async throws -> HTTPResponse {
        let deadline = ContinuousClock.now + request.timeout
        var attempt = 0
        while true {
            var current = request
            current.timeout = max(.milliseconds(10), deadline - .now)
            let tls: HTTPClient.TLS = verifyTLS ? .system : trust.tls
            do {
                let response = try await client(for: tls).send(current)
                if !verifyTLS, case .any = tls, trust.observe(response.certificateFingerprint), let pinned = colonFingerprint(trust.fingerprint) {
                    logger.info("\(name): Trusting and pinning the TLS certificate presented by \(request.url.host ?? address) (SHA-256 fingerprint: \(pinned)).")
                }
                if retrying, Self.retryStatuses.contains(response.status), attempt < 5, ContinuousClock.now < deadline {
                    try await backoff(&attempt, deadline: deadline)
                    continue
                }
                return response
            } catch let error as HTTPClientError {
                if case .certificateMismatch(_, let observed) = error {
                    if trust.reportMismatch(observed: observed), let expected = colonFingerprint(trust.fingerprint), let actual = colonFingerprint(observed) {
                        let host = request.url.host ?? address
                        logger.error(
                            "\(name): API error: The TLS certificate presented by \(host) does not match the pinned certificate. Refusing to connect - no credentials have been sent. Expected SHA-256 fingerprint: \(expected). Received: \(actual). This can happen when the controller certificate is regenerated, or it may indicate that someone is intercepting your connection."
                        )
                        if let mismatchHint { logger.error("\(mismatchHint)") }
                    }
                    throw error
                }
                guard retrying, attempt < 5, ContinuousClock.now < deadline, Self.isTransient(error) else { throw error }
                try await backoff(&attempt, deadline: deadline)
            }
        }
    }

    private func backoff(_ attempt: inout Int, deadline: ContinuousClock.Instant) async throws {
        let delay = Backoff(initial: timing.retryMinimum, maximum: timing.retryMaximum).delay(attempt: attempt)
        attempt += 1
        try await Task.sleep(for: min(delay, max(.zero, deadline - .now)))
    }

    private static func isTransient(_ error: HTTPClientError) -> Bool {
        switch error {
        case .cannotConnect(_, _, let code, _): code.map { retryErrnos.contains($0) } ?? false
        case .connectionClosed: true
        default: false
        }
    }

    private func client(for tls: HTTPClient.TLS) -> any HTTPSending {
        if let client, client.tls == tls { return client.client }
        let made = http(tls)
        client = (tls, made)
        return made
    }

    /// The plain-words version of a failed request.
    private func describe(_ error: any Error, url: String, log: (String) -> Void) {
        switch error as? HTTPClientError {
        case .timeout:
            log("Access controller is taking too long to respond to a request. This error can usually be safely ignored.")
            logger.debug("\(name): Original request was: \(url)")
        case .cannotConnect(_, _, let code, let reason):
            if code == ETIMEDOUT || reason.lowercased().contains("timeout") || reason.lowercased().contains("timed out") {
                log("Access controller is taking too long to respond to a request. This error can usually be safely ignored.")
                logger.debug("\(name): Original request was: \(url)")
            } else if code == ECONNREFUSED || code == EHOSTDOWN {
                log("Connection refused.")
            } else if code == ECONNRESET {
                log("Network connection to Access controller has been reset.")
            } else if reason.lowercased().contains("dns") || reason.lowercased().contains("resolve") || reason.lowercased().contains("nodename") {
                log(address.isEmpty ? "No hostname or IP address provided." : "Hostname or IP address not found: \(address). Please ensure the address you configured for this UniFi Access controller is correct.")
            } else {
                log("Error: \(code.map { String(cString: strerror($0)) } ?? "connection") | \(reason).")
            }
        case .connectionClosed:
            log("Network connection to Access controller has been reset.")
        case .certificateMismatch(let expected, let observed):
            log(
                "Error: ERR_ACCESS_TLS_PIN_MISMATCH | Refusing TLS connection to \(address): certificate fingerprint \(colonFingerprint(observed) ?? observed) does not match the pinned fingerprint \(colonFingerprint(expected) ?? expected)."
            )
        case .some(let other):
            log("Error: \(other).")
        case nil:
            log("Unknown error: \(error)")
        }
    }

    private func logRetry(_ message: String, isRetry: Bool) {
        // Over the limit, the throttling message says it all.
        guard apiErrorCount < Self.errorLimit else { return }
        if isRetry {
            logger.debug("\(name): \(message) Retrying.")
        } else {
            logError(message)
        }
    }

    private func logError(_ message: String) {
        logger.error("\(name): API error: \(message)")
    }

    private static func minutes(_ duration: Duration) -> String {
        FeatureOptions.javaScriptString(Double(duration.components.seconds) / 60)
    }
}

/// HTTP reason phrases for the log (`STATUS_CODES` in Node).
enum HTTPReason {
    static func phrase(_ status: Int) -> String {
        switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 418: "I'm a Teapot"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Unknown"
        }
    }
}
