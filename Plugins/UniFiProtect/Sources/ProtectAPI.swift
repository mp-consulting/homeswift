import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The UniFi Protect API client (`ProtectApi` of the Homebridge plugin, itself `unifi-protect` 4.29): a
/// cookie session with a CSRF token, the bootstrap, device updates, snapshots, the WebSocket endpoints, and
/// the realtime events WebSocket whose packets come out of `packets`, in order.
///
/// Requests go through a circuit breaker that pauses all traffic for five minutes after ten consecutive
/// errors, GETs are retried with backoff on transient failures, and the controller's self-signed certificate
/// is pinned on first use unless `verifyTls` asks for the system's roots.
actor ProtectAPI {
    struct Options: Sendable {
        /// Validate the certificate against the system's roots instead of pinning it.
        var verifyTls = false
        var pin = ProtectTLSPin.Options()
        var transport: any ProtectHTTPTransport = NetworkHTTPTransport()
        var webSockets: ProtectWebSocketFactory = { try await WebSocket.connect(to: $0, options: $1) }
        /// Scales every delay of the client (backoffs, heartbeats, reconnects); tests shorten them.
        var timeScale = 1.0
        /// Connect the realtime events WebSocket with each bootstrap; the settings page only reads devices.
        var connectsEvents = true
    }

    /// Ten consecutive errors pause the client.
    static let errorLimit = 10
    /// The pause, in seconds.
    static let retryInterval = 300
    /// How long a request may take, in milliseconds, retries included.
    static let requestTimeout = 3500
    /// The events WebSocket is presumed dead after this many milliseconds without traffic.
    static let eventsHeartbeatInterval = 30_000
    /// Milliseconds before reconnecting a closed events WebSocket.
    static let eventsReconnectDelay = 5000
    /// Statuses that mean the controller is having a moment (a reboot, an update).
    static let serverErrors: Set<Int> = [400, 404, 429, 500, 502, 503, 504]
    /// Statuses a GET is transparently retried on.
    static let retryStatuses: Set<Int> = [429, 500, 502, 503, 504]
    /// The pause between a GET's retries: 100 ms doubling up to 1.5 s.
    static let retryBackoff = Backoff(initial: .milliseconds(100), maximum: .milliseconds(1500))

    enum Endpoint: String, Sendable {
        case bootstrap, camera, chime, light, login, nvr, `self`, sensor, viewer, websocket
    }

    private let log: ProtectLog
    let verifyTls: Bool
    private let transport: any ProtectHTTPTransport
    private let webSockets: ProtectWebSocketFactory
    let timeScale: Double
    let pin: ProtectTLSPin?
    private let connectsEvents: Bool

    private(set) var bootstrap: JSONValue?
    private(set) var isAdminUser = false
    private var breaker: CircuitBreaker
    private(set) var nvrAddress = ""
    private(set) var username = ""
    private var password = ""
    private var headers: [String: String] = [:]

    // The realtime events WebSocket.
    nonisolated let packets: AsyncStream<ProtectEventPacket>
    private let packetSink: AsyncStream<ProtectEventPacket>.Continuation
    private var events: (any WebSocketConnection)?
    private var eventsTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    /// The events WebSocket being opened: a second caller waits for it rather than opening another.
    private var connectingEvents: Task<Bool, Never>?
    /// Bumped by each `logout()`: work that began before one (a login, a bootstrap, an events connection, a
    /// reconnect) does not bring the session or the events back after it.
    private var sessionGeneration = 0

    init(log: ProtectLog, options: Options = Options()) {
        self.log = log
        verifyTls = options.verifyTls
        transport = options.transport
        webSockets = options.webSockets
        timeScale = options.timeScale
        connectsEvents = options.connectsEvents
        breaker = CircuitBreaker(errorLimit: Self.errorLimit, retryInterval: .seconds(Double(Self.retryInterval) * options.timeScale))
        pin = options.verifyTls ? nil : ProtectTLSPin(log: log, options: options.pin)
        (packets, packetSink) = AsyncStream.makeStream(of: ProtectEventPacket.self, bufferingPolicy: .bufferingNewest(1000))
        headers = Self.baseHeaders(csrf: nil)
    }

    deinit {
        packetSink.finish()
    }

    // MARK: Names and state

    /// `Name [Model]` once bootstrapped, the address before.
    var name: String {
        if let nvr = bootstrap?.at("nvr") {
            let market = nvr.string("marketName") ?? ""
            return (nvr.string("name") ?? market) + " [" + market + "]"
        }
        return nvrAddress
    }

    var isThrottled: Bool { breaker.isThrottled }
    var isLoggedIn: Bool { headers["cookie"] != nil && headers["x-csrf-token"] != nil }

    /// The pinned certificate's fingerprint, unless the system's roots are used.
    var tlsFingerprint: String? { pin?.fingerprint }

    /// The TLS policy of a connection to the controller: the system's roots, the pin, or first contact.
    var tlsPolicy: HTTPClient.TLS { pin?.policy ?? .system }

    /// The session cookie, for WebSockets.
    var cookie: String? { headers["cookie"] }

    /// `Device Name [Type]`, and ` (address: IP mac: MAC)` with `deviceInfo`.
    nonisolated static func deviceName(_ device: JSONValue, name: String? = nil, deviceInfo: Bool = false) -> String {
        let config = ProtectDeviceConfig(device)
        let host = config.host.flatMap { $0.isEmpty ? nil : "address: \($0) " } ?? ""
        let type = config.marketName.flatMap { $0.isEmpty ? nil : $0 } ?? config.type
        return (name ?? config.name ?? type) + " [" + type + "]" + (deviceInfo ? " (" + host + "mac: " + config.mac + ")" : "")
    }

    /// The controller's name, then the device's.
    func fullName(_ device: JSONValue) -> String {
        let deviceName = Self.deviceName(device)
        return name + (deviceName.isEmpty ? "" : " " + deviceName)
    }

    /// The URL of an API endpoint on the controller.
    func endpoint(_ endpoint: Endpoint) -> String {
        let (prefix, suffix): (String, String) = switch endpoint {
        case .bootstrap: ("/proxy/protect/api/", "bootstrap")
        case .camera: ("/proxy/protect/api/", "cameras")
        case .chime: ("/proxy/protect/api/", "chimes")
        case .light: ("/proxy/protect/api/", "lights")
        case .login: ("/api/", "auth/login")
        case .nvr: ("/proxy/protect/api/", "nvr")
        case .self: ("/api/", "users/self")
        case .sensor: ("/proxy/protect/api/", "sensors")
        case .viewer: ("/proxy/protect/api/", "viewers")
        case .websocket: ("/proxy/protect/api/", "ws")
        }
        return "https://" + nvrAddress + prefix + suffix
    }

    /// The endpoint of a device class (`camera`, `light`, ...), from its `modelKey`.
    func endpoint(modelKey: String) -> String {
        endpoint(Endpoint(rawValue: modelKey) ?? .camera)
    }

    // MARK: Session

    /// Logs in from scratch: any session is dropped first.
    func login(address: String, username: String, password: String) async -> Bool {
        nvrAddress = address
        self.username = username
        self.password = password
        dropSession()
        return await sessionLogin()
    }

    /// Logs in if there is no session: with the CSRF token we have, else fetching one from the console's
    /// home page when the login is refused without it.
    func sessionLogin() async -> Bool {
        if isLoggedIn { return true }
        let generation = sessionGeneration
        let body = JSONValue.object(["password": .string(password), "rememberMe": true, "token": "", "username": .string(username)]).encoded()
        var response = await retrieve(endpoint(.login), method: "POST", body: body)
        if !(response?.isSuccess ?? false), headers["x-csrf-token"] == nil {
            let csrfResponse = await retrieve("https://" + nvrAddress, method: "GET", logErrors: false)
            if csrfResponse?.isSuccess ?? false, let token = csrfResponse?.header("X-CSRF-Token") {
                headers["x-csrf-token"] = token
                response = await retrieve(endpoint(.login), method: "POST", body: body)
            }
        }
        // Logged out meanwhile: the session this login opens is not wanted any more.
        guard generation == sessionGeneration else { return false }
        guard let response, response.isSuccess else {
            dropSession()
            return false
        }
        let csrf = response.header("X-Updated-CSRF-Token") ?? response.header("X-CSRF-Token")
        if let csrf, let cookie = response.header("Set-Cookie") {
            headers["cookie"] = String(cookie.split(separator: ";", maxSplits: 1).first ?? Substring(cookie))
            headers["x-csrf-token"] = csrf
            return true
        }
        dropSession()
        return false
    }

    /// Closes the events WebSocket and forgets the bootstrap.
    func reset() {
        bootstrap = nil
        closeEvents()
    }

    /// Ends the session for good, keeping the CSRF token for a later `login`: work still in flight (a login,
    /// a bootstrap, an events connection or its reconnection) does not bring it back.
    func logout() {
        sessionGeneration += 1
        dropSession()
    }

    /// Drops the session (a refused request, a new login), keeping the CSRF token for the next login.
    private func dropSession() {
        reset()
        isAdminUser = false
        headers = Self.baseHeaders(csrf: headers["x-csrf-token"])
    }

    private static func baseHeaders(csrf: String?) -> [String: String] {
        var headers = ["content-type": "application/json", "user-agent": "unifi-protect"]
        if let csrf { headers["x-csrf-token"] = csrf }
        return headers
    }

    // MARK: Bootstrap

    /// Fetches the bootstrap and connects the events WebSocket, retrying once.
    func getBootstrap() async -> Bool {
        await bootstrapController(retry: true)
    }

    private func bootstrapController(retry: Bool) async -> Bool {
        guard await sessionLogin() else { return retry ? await bootstrapController(retry: false) : false }
        let generation = sessionGeneration
        let fetched = await retrieve(endpoint(.bootstrap))
        // Logged out meanwhile (the controller is stopping): no bootstrap, no events.
        guard generation == sessionGeneration else { return false }
        guard let response = fetched, response.isSuccess else {
            logRetry("Unable to retrieve the UniFi Protect controller configuration.", isRetry: retry)
            return retry ? await bootstrapController(retry: false) : false
        }
        guard let data = try? JSONValue(data: response.body), data.objectValue != nil else {
            // A console without the app answers its proxy's paths with its own web page.
            apiError(response.header("content-type")?.lowercased().hasPrefix("text/html") == true
                ? "UniFi Protect does not run on this console: it answered with its web page. Set up the console that runs UniFi Protect."
                : "Unable to parse response from UniFi Protect. Will retry again later.")
            return retry ? await bootstrapController(retry: false) : false
        }
        let isFirstRun = bootstrap == nil
        bootstrap = data
        checkAdminUserStatus(isFirstRun: isFirstRun)
        if connectsEvents, !(await connectEvents()) { return retry ? await bootstrapController(retry: false) : false }
        return true
    }

    /// Replaces the bootstrap our view keeps (the chimes after a volume change, the messages after an edit).
    func updateBootstrap(_ change: @Sendable (inout JSONValue) -> Void) {
        guard var current = bootstrap else { return }
        change(&current)
        bootstrap = current
    }

    /// Whether the user may change cameras: a `camera:…write…` permission, which the Super Admin role has.
    private func checkAdminUserStatus(isFirstRun: Bool) {
        guard let bootstrap, let authUserId = bootstrap.string("authUserId"),
            let user = bootstrap.array("users").first(where: { $0.string("id") == authUserId }), let permissions = user.at("allPermissions")?.arrayValue
        else { return }
        let wasAdmin = isAdminUser
        isAdminUser = permissions.compactMap(\.stringValue).contains { entry in
            guard entry.hasPrefix("camera:") else { return false }
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count > 1 && parts[1].split(separator: ",").contains("write")
        }
        if isFirstRun, !isAdminUser {
            log.info("\(name): User '\(username)' requires the Super Admin role in order to change certain settings like camera RTSP stream availability.")
        } else if !isFirstRun, wasAdmin != isAdminUser {
            log.info("\(name): Role change detected for user '\(username)': the Super Admin role has been \(isAdminUser ? "enabled" : "disabled").")
        }
    }

    // MARK: Devices

    /// Sends a configuration change to a device (the NVR when its `modelKey` is `nvr`) and returns the device
    /// as the controller now has it; nil when it failed (logged) or the user may not change it.
    func updateDevice(_ device: JSONValue, payload: JSONValue) async -> JSONValue? {
        guard await sessionLogin(), isAdminUser else { return nil }
        let config = ProtectDeviceConfig(device)
        log.debug("\(name): \(fullName(device)): \(payload.text())")
        let url = endpoint(modelKey: config.modelKey) + (config.modelKey == "nvr" ? "" : "/" + config.id)
        guard let response = await retrieve(url, method: "PATCH", body: payload.encoded()) else { return nil }
        guard response.isSuccess else {
            apiError("\(fullName(device)): Unable to configure the \(config.modelKey): \(response.status).")
            return nil
        }
        guard let updated = try? JSONValue(data: response.body) else {
            apiError("\(fullName(device)): Unable to parse the response from the Protect controller.")
            return nil
        }
        return updated
    }

    /// Turns RTSP on for every channel of a camera; the camera as it is when that is not needed or allowed.
    func enableRtsp(_ device: JSONValue) async -> JSONValue? {
        guard await sessionLogin(), isAdminUser else { return nil }
        let channels = device.array("channels")
        guard channels.contains(where: { !$0.bool("isRtspEnabled") }) else { return device }
        let enabled = JSONValue.array(channels.map { $0.setting("isRtspEnabled", true) })
        let config = ProtectDeviceConfig(device)
        let response = await retrieve(endpoint(modelKey: config.modelKey) + "/" + config.id, method: "PATCH",
            body: JSONValue.object(["channels": enabled]).encoded(), decodeResponse: false)
        guard let response, response.isSuccess else {
            breaker.recordFailure()
            if response?.status == 403 {
                apiError("\(fullName(device)): Insufficient privileges to enable RTSP on all channels. Please ensure this username has the Administrator role assigned in UniFi Protect.")
            } else {
                apiError("\(fullName(device)): Unable to enable RTSP on all channels: \(response.map { String($0.status) } ?? "undefined").")
            }
            return device
        }
        breaker.recordSuccess()
        guard let updated = try? JSONValue(data: response.body) else {
            apiError("\(fullName(device)): Unable to parse the response from the Protect controller.")
            return device
        }
        return updated
    }

    /// A JPEG from the controller, of the camera or its package camera, at the size asked.
    func getSnapshot(_ device: JSONValue, width: Int? = nil, height: Int? = nil, timeout: Duration? = nil, usePackageCamera: Bool = false) async -> Data? {
        guard await sessionLogin() else { return nil }
        let config = ProtectDeviceConfig(device)
        if usePackageCamera, !config.feature("hasPackageCamera") { return nil }
        var parameters: [String] = []
        if let height { parameters.append("h=\(height)") }
        if let width { parameters.append("w=\(width)") }
        let url = endpoint(modelKey: config.modelKey) + "/" + config.id + "/" + (usePackageCamera ? "package-" : "") + "snapshot?" + parameters.joined(separator: "&")
        guard let response = await retrieve(url, method: "GET", timeout: timeout ?? .milliseconds(Self.requestTimeout)), response.isSuccess else {
            apiError("\(fullName(device)): Unable to retrieve the snapshot.")
            return nil
        }
        return response.body
    }

    /// The URL of a WebSocket endpoint (`livestream`, `talkback`), on the controller's address.
    func getWsEndpoint(_ endpoint: String, parameters: [(String, String)] = []) async -> String? {
        guard await sessionLogin() else { return nil }
        let query = URLEncoding.form(parameters)
        let response = await retrieve(self.endpoint(.websocket) + "/" + endpoint + (query.isEmpty ? "" : "?" + query))
        guard let response, response.isSuccess else {
            if let response { apiError("API endpoint access error: \(response.status) - \(Self.statusText(response.status)).") }
            return nil
        }
        guard let json = try? JSONValue(data: response.body), let url = json.string("url") else {
            apiError("Received syntax error while communicating with the controller. This is typically due to a controller reboot.")
            return nil
        }
        guard var components = URLComponents(string: url) else {
            apiError("An error occurred while communicating with the controller: invalid URL.")
            return nil
        }
        components.host = Self.hostname(of: nvrAddress)
        return components.string
    }

    /// The host of an address that may carry a port (`192.168.1.1:443`).
    static func hostname(of address: String) -> String {
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") { return String(address[address.index(after: address.startIndex)..<end]) }
        if address.filter({ $0 == ":" }).count == 1, let colon = address.firstIndex(of: ":") { return String(address[..<colon]) }
        return address
    }

    /// Opens a WebSocket to the controller (`livestream`, `talkback`) with its TLS policy: a pinned or unknown
    /// certificate is checked in the handshake, before the upgrade request and any cookie go out.
    func openWebSocket(_ url: URL, headers: [(name: String, value: String)] = []) async throws -> any WebSocketConnection {
        try await webSockets(url, WebSocket.Options(headers: headers, tls: TLSOptions(tlsPolicy)))
    }

    /// A livestream session on this controller.
    nonisolated func createLivestream(log: ProtectLog) -> ProtectLivestream {
        ProtectLivestream(api: self, log: log)
    }

    // MARK: Requests

    /// A request to the controller with our session, the breaker, retries for GETs, and the errors logged as
    /// the Homebridge plugin logs them. nil when it failed. With `decodeResponse: false` the caller judges the
    /// response and the breaker is left alone.
    func retrieve(_ url: String, method: String = "GET", body: Data? = nil, logErrors: Bool = true, timeout: Duration = .milliseconds(requestTimeout),
                  decodeResponse: Bool = true) async -> HTTPResponse? {
        let logError: (String) -> Void = { message in if logErrors { self.apiError(message) } }
        switch breaker.check() {
        case .tripped:
            apiError("Throttling API calls due to errors with the \(breaker.errorCount) previous attempts. Pausing communication with the Protect controller for \(Self.retryInterval / 60) minutes.")
            reset()
            return nil
        case .open:
            return nil
        case .resumed:
            apiError("Resuming connectivity to the UniFi Protect API after pausing for \(Self.retryInterval / 60) minutes.")
            guard await sessionLogin() else { return nil }
        case .closed:
            break
        }
        guard let target = URL(string: url) else {
            logError("Unknown error: invalid URL.")
            return nil
        }
        var request = HTTPRequest(method: method, url: target, body: body, timeout: timeout)
        for (name, value) in headers { request.setHeader(name, value) }
        let retries = method == "PATCH" || method == "POST" ? 0 : 5
        let response: HTTPResponse
        do {
            response = try await send(request, retries: retries, deadline: ContinuousClock.now + timeout)
        } catch {
            breaker.recordFailure()
            logNetworkError(error, logError: logError, host: target.host ?? nvrAddress)
            return nil
        }
        if !decodeResponse { return response }
        breaker.recordFailure()
        if response.status == 401 {
            dropSession()
            logError("Invalid login credentials given. Please check your login and password.")
            return nil
        }
        if response.status == 403 {
            logError("Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.")
            return nil
        }
        guard response.isSuccess else {
            if Self.serverErrors.contains(response.status) {
                logError("Unable to connect to the Protect controller. This is temporary and may occur during device reboots.")
            } else {
                logError("\(response.status) - \(Self.statusText(response.status))")
            }
            return nil
        }
        breaker.recordSuccess()
        return response
    }

    /// One request with the retries of a GET: backoff 100 ms doubling up to 1.5 s, on transient statuses and
    /// connection errors, within the request's deadline.
    private func send(_ request: HTTPRequest, retries: Int, deadline: ContinuousClock.Instant) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            var request = request
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw HTTPClientError.timeout }
            request.timeout = remaining
            let policy = tlsPolicy
            do {
                let response = try await transport.send(request, tls: policy)
                if policy == .any { pin?.accept(host: request.url.host ?? nvrAddress, presented: response.certificateFingerprint) }
                if Self.retryStatuses.contains(response.status), attempt < retries {
                    try await backoff(attempt, deadline: deadline)
                    attempt += 1
                    continue
                }
                return response
            } catch let error as HTTPClientError {
                if case .certificateMismatch(_, let observed) = error { pin?.reportMismatch(host: request.url.host ?? nvrAddress, observed: observed) }
                guard attempt < retries, Self.isTransient(error) else { throw error }
                try await backoff(attempt, deadline: deadline)
                attempt += 1
            }
        }
    }

    private func backoff(_ attempt: Int, deadline: ContinuousClock.Instant) async throws {
        let delay = Self.retryBackoff.delay(attempt: attempt) * timeScale
        guard ContinuousClock.now + delay < deadline else { throw HTTPClientError.timeout }
        try await Task.sleep(for: delay)
    }

    private static func isTransient(_ error: HTTPClientError) -> Bool {
        guard case .cannotConnect(_, _, let code, _) = error, let code else { return false }
        return [ECONNREFUSED, ECONNRESET, EHOSTUNREACH, EPIPE, ETIMEDOUT].contains(code)
    }

    private func logNetworkError(_ error: any Error, logError: (String) -> Void, host: String) {
        guard let error = error as? HTTPClientError else {
            logError("Unknown error: \(error)")
            return
        }
        switch error {
        case .timeout:
            logError("Protect controller is taking too long to respond to a request. This error can usually be safely ignored.")
        case .certificateMismatch:
            // The pin has told the user in detail already.
            break
        case .cannotConnect(_, _, let code, let reason):
            switch code {
            case ECONNREFUSED, EHOSTDOWN: logError("Connection refused.")
            case ECONNRESET: logError("Network connection to Protect controller has been reset.")
            case ETIMEDOUT: logError("Connection timed out.")
            default:
                if reason.lowercased().contains("resolve") || reason.lowercased().contains("not known") || reason.lowercased().contains("nodename") {
                    logError(nvrAddress.isEmpty ? "No hostname or IP address provided."
                        : "Hostname or IP address not found: \(nvrAddress). Please ensure the address you configured for this UniFi Protect controller is correct.")
                } else {
                    logError("Error: \(code.map { String($0) } ?? "unknown") | \(reason).")
                }
            }
        default:
            logError("Error: \(error).")
        }
    }

    private func logRetry(_ message: String, isRetry: Bool) {
        guard !breaker.isOverLimit else { return }
        if isRetry {
            log.debug("\(name): \(message) Retrying.")
        } else {
            apiError(message)
        }
    }

    private func apiError(_ message: String) {
        log.error("\(name): API error: \(message)")
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }

    // MARK: Realtime events

    /// Connects the events WebSocket with our session, from the last update the bootstrap knows so nothing
    /// is missed. True when it is (or already was) connected.
    func connectEvents() async -> Bool {
        if events != nil { return true }
        if let connecting = connectingEvents { return await connecting.value }
        let generation = sessionGeneration
        let connecting = Task { await self.openEvents(generation) }
        connectingEvents = connecting
        let connected = await connecting.value
        if connectingEvents == connecting { connectingEvents = nil }
        return connected
    }

    private func openEvents(_ generation: Int) async -> Bool {
        guard generation == sessionGeneration, await sessionLogin(), generation == sessionGeneration else { return false }
        if events != nil { return true }
        let query = URLEncoding.form([("lastUpdateId", bootstrap?.string("lastUpdateId") ?? "")])
        guard let url = URL(string: "wss://" + nvrAddress + "/proxy/protect/ws/updates?" + query) else { return false }
        let policy = tlsPolicy
        let socket: any WebSocketConnection
        do {
            socket = try await webSockets(url, WebSocket.Options(headers: [("Cookie", cookie ?? "")], tls: TLSOptions(policy)))
        } catch {
            if case .certificateMismatch(_, let observed) = error as? HTTPClientError { pin?.reportMismatch(host: url.host ?? nvrAddress, observed: observed) }
            log.error("\(name): API error: Events API error: \(error)")
            return false
        }
        // Logged out while connecting, or another socket won: this one goes.
        guard generation == sessionGeneration, events == nil else {
            await socket.close()
            return events != nil
        }
        if policy == .any { pin?.accept(host: url.host ?? nvrAddress, presented: (socket as? WebSocket)?.certificateFingerprint) }
        events = socket
        startEvents(socket)
        return true
    }

    private func startEvents(_ socket: any WebSocketConnection) {
        let lastTraffic = LastTraffic()
        let sink = packetSink
        let log = log
        let reader = Task { [weak self] in
            do {
                for try await message in socket.messages {
                    lastTraffic.touch()
                    do {
                        sink.yield(try ProtectEventPacket.decode(message.data))
                    } catch {
                        let name = await self?.name ?? ""
                        log.error("\(name): API error: Realtime events API: error decoding update packet: \(error).")
                        log.error("\(name): API error: Unable to process message from the realtime update events API.")
                        await socket.close()
                    }
                }
            } catch {
                // A dropped connection ends like a close.
            }
            await self?.eventsClosed(socket)
        }
        let interval = Duration.milliseconds(Int(Double(Self.eventsHeartbeatInterval) * timeScale))
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if lastTraffic.takeSilence() {
                    await socket.close()
                    return
                }
                // A pong is traffic too.
                if (try? await socket.ping(timeout: .seconds(10))) != nil { lastTraffic.touch() }
            }
        }
        eventsTasks = [reader, heartbeat]
    }

    /// The events WebSocket closed: forget it and, while logged in, reconnect once after a few seconds rather
    /// than waiting for the next bootstrap refresh.
    private func eventsClosed(_ socket: any WebSocketConnection) {
        guard events === socket else { return }
        events = nil
        eventsTasks.forEach { $0.cancel() }
        eventsTasks = []
        guard isLoggedIn, reconnectTask == nil else { return }
        let delay = Duration.milliseconds(Int(Double(Self.eventsReconnectDelay) * timeScale))
        let generation = sessionGeneration
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnectEvents(generation)
        }
    }

    /// Reconnects, unless the session it was scheduled for ended: a logout must not log back in.
    private func reconnectEvents(_ generation: Int) async {
        reconnectTask = nil
        guard generation == sessionGeneration, isLoggedIn else { return }
        _ = await connectEvents()
    }

    private func closeEvents() {
        let socket = events
        events = nil
        eventsTasks.forEach { $0.cancel() }
        eventsTasks = []
        reconnectTask?.cancel()
        reconnectTask = nil
        if let socket { Task { await socket.close() } }
    }

    /// Whether the events WebSocket is open.
    var isEventsConnected: Bool { events != nil }
}

/// Whether traffic came since the last heartbeat tick.
private final class LastTraffic: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = true

    func touch() {
        lock.lock()
        seen = true
        lock.unlock()
    }

    /// True when nothing came since the last call; resets the flag.
    func takeSilence() -> Bool {
        lock.lock()
        defer { seen = false; lock.unlock() }
        return !seen
    }
}
