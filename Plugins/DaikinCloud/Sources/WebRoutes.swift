import Foundation
import Homeswift
import HomeswiftPlugin

/// The plugin page's requests, after the Homebridge plugin's settings UI server (`homebridge-ui/server.js`), answered by
/// the running instance. Signing in is Setup's (DaikinSetup.swift), which drives the logins below; the page leads there.
///
/// | Route | What it does |
/// |---|---|
/// | `GET auth/status` | The token of either login: authenticated, expiry, refreshable |
/// | `POST auth/revoke` | Revokes and deletes the tokens |
/// | `POST auth/test` | Lists the devices with the saved token |
/// | `GET devices/list?mode=&refresh=` | The devices, reused for five minutes (or the instance's own) |
/// | `GET rate-limit` | The quota the plugin recorded on its last call (no API call) |
extension DaikinCloudPlugin {
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        let body = request.body.objectValue ?? [:]
        switch (request.method, request.path) {
        case ("GET", "auth/status"): return PluginWebResponse(await authStatus())
        case ("POST", "auth/revoke"): return PluginWebResponse(await revoke(body))
        case ("POST", "auth/test"): return PluginWebResponse(await testConnection())
        case ("GET", "devices/list"):
            let mode = request.query["mode"].flatMap(AuthMode.init(rawValue:))
            return PluginWebResponse(await listDevices(mode: mode, refresh: request.query["refresh"] == "1" || request.query["refresh"] == "true"))
        case ("GET", "rate-limit"): return PluginWebResponse(await rateLimit())
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    // MARK: Tokens

    /// The active token: the Mobile App's first, then the Developer Portal's.
    func activeToken() -> (tokens: TokenSet?, mode: AuthMode) {
        if let mobile = TokenFile.load(tokenFile(.mobileApp)), !mobile.access_token.isEmpty { return (mobile, .mobileApp) }
        return (TokenFile.load(tokenFile(.developerPortal)), .developerPortal)
    }

    /// The token of a mode, else the active one.
    func token(for mode: AuthMode?) -> (tokens: TokenSet?, mode: AuthMode) {
        if let mode, let tokens = TokenFile.load(tokenFile(mode)), !tokens.access_token.isEmpty { return (tokens, mode) }
        return activeToken()
    }

    static func status(of tokens: TokenSet?, now: Date = Date()) -> [String: JSONValue] {
        guard let tokens, !tokens.access_token.isEmpty else { return ["authenticated": false, "message": "Not authenticated"] }
        let expired = tokens.expiresAt.map { $0 < now } ?? false
        let refreshable = tokens.refresh_token != nil
        return [
            "authenticated": true, "isExpired": .bool(expired), "canRefresh": .bool(refreshable),
            "expiresAt": tokens.expiresAt.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
            "message": .string(expired ? (refreshable ? "Token expired, will refresh automatically" : "Token expired, re-authentication required") : "Authenticated"),
        ]
    }

    func authStatus() async -> JSONValue {
        var result: [String: JSONValue]
        let (tokens, mode) = activeToken()
        result = Self.status(of: tokens)
        if tokens != nil { result["authMode"] = .string(mode.rawValue) }
        // What the running instance does, for the page's header.
        if let session {
            let running = await session.isRunning
            var state: [String: JSONValue] = ["running": .bool(running), "mode": .string(settings.authMode.rawValue)]
            if running {
                state["devices"] = .number(Double(await session.accessories.count))
                state["webSocket"] = .bool(await session.webSocketConnected)
                state["pollMinutes"] = .number((await session.currentPollInterval / .seconds(60)).rounded())
                if let fetched = await session.lastFetched { state["lastFetched"] = .string(ISO8601DateFormatter.withFractionalSeconds.string(from: fetched)) }
            }
            result["session"] = .object(state)
        }
        return .object(result)
    }

    // MARK: The Developer Portal login (Setup's)

    func startAuthorization(_ body: [String: JSONValue]) async throws -> JSONValue {
        guard let clientID = DaikinSettings.nonEmpty(body["clientId"]), let clientSecret = DaikinSettings.nonEmpty(body["clientSecret"]) else {
            throw DaikinError("Client ID and Client Secret are required")
        }
        guard let address = DaikinSettings.nonEmpty(body["callbackServerExternalAddress"]) else { throw DaikinError("Callback Server Address is required") }
        let configured = DaikinSettings.isSet(body["oidcCallbackServerBindAddr"]) ? DaikinSettings.display(body["oidcCallbackServerBindAddr"]) : configuration.raw["oidcCallbackServerBindAddr"]?.stringValue
        let bindAddress = NetworkInfo.bindAddress(configured)
        if let configured, !configured.isEmpty, bindAddress != configured.trimmingCharacters(in: .whitespaces) {
            logger.warning("[DaikinCloud] Invalid callback bind address \"\(configured)\", using \(bindAddress)")
        }
        if NetworkInfo.isLoopback(bindAddress), !NetworkInfo.isLoopback(address) {
            // The browser goes to the external address, which can never reach a loopback-only server.
            throw DaikinError("The callback server bind address is \(bindAddress) (this machine only), but the callback address is \(address), "
                + "so Daikin's redirect could never reach it. Set \"Callback Server Bind Address\" to 0.0.0.0 (or this host's LAN IP) in Settings > Network, "
                + "then start authentication again.")
        }
        let port = try Self.callbackPort(body["callbackServerPort"])
        let redirectURI = DeveloperPortalOAuth.redirectURI(address: address, port: port)
        let state = DeveloperPortalOAuth.makeState()
        pendingAuth = PendingAuth(state: state, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI, port: port, createdAt: Date())
        authAttempt += 1
        authResult = nil
        devicesCache.removeAll()
        let url = DeveloperPortalOAuth.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state)
        logger.info("[DaikinCloud] Redirect URI: \(redirectURI)")
        var running = false
        var failure: String?
        do {
            try await callbackServer.start(
                port: port, hostname: address, bindAddress: bindAddress, certificateDirectory: storage.appendingPathComponent(Self.certificateDirectoryName),
                lifetime: Self.authorizationWindow
            ) { [weak self] uri in
                guard let self else { return (503, CallbackServer.page(success: false, message: "Homeswift is stopping")) }
                return await self.callbackRequest(uri)
            }
            running = true
            logger.info("[DaikinCloud] Callback server started successfully")
        } catch {
            failure = message(of: error)
            logger.warning("[DaikinCloud] Failed to start callback server: \(failure ?? "")")
        }
        return [
            "authUrl": .string(url), "state": .string(state), "redirectUri": .string(redirectURI), "callbackServerRunning": .bool(running),
            "callbackServerError": failure.map(JSONValue.string) ?? .null,
            "message": .string(running
                ? "Callback server is running. Authentication will complete automatically."
                : "Could not start callback server. After authenticating, copy the full callback URL and paste it below."),
        ]
    }

    /// The port as `parseInt` reads the field ("8582 " works, unset is the default); one no socket can have is
    /// refused here rather than reaching the bind.
    static func callbackPort(_ value: JSONValue?) throws -> Int {
        if let port = DaikinSettings.port(value) { return port }
        let digits = DaikinSettings.display(value).trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isWholeNumber }
        // 0 is falsy in `callbackServerPort || "8582"`.
        guard !digits.isEmpty, digits.contains(where: { $0 != "0" }) else { return DaikinSettings.defaultCallbackPort }
        guard let port = Int(digits), (1...65535).contains(port) else { throw DaikinError("Callback Server Port must be between 1 and 65535") }
        return port
    }

    private var pendingExpired: Bool {
        guard let pendingAuth else { return false }
        return Date().timeIntervalSince(pendingAuth.createdAt) > Double(Self.authorizationWindow / .seconds(1))
    }

    /// The browser, redirected by Daikin. Requests without the pending state are not ours: refused without
    /// touching the result, so they cannot disturb a login in progress.
    func callbackRequest(_ uri: String) async -> (status: Int, html: String) {
        let url = "https://localhost" + (uri.hasPrefix("/") ? uri : "/" + uri)
        let code = URLQuery.parameter("code", in: url)
        let state = URLQuery.parameter("state", in: url)
        let error = URLQuery.parameter("error", in: url)
        let description = URLQuery.parameter("error_description", in: url)
        guard let pending = pendingAuth, let state, Self.isPendingState(state, of: pending) else {
            return (400, CallbackServer.page(success: false, message: "Invalid or missing state parameter"))
        }
        if pendingExpired {
            pendingAuth = nil
            authResult = ["success": false, "error": "Authorization request expired. Please try again."]
            Task { await callbackServer.stop() }
            return (400, CallbackServer.page(success: false, message: "Authorization request expired. Please start again from Homeswift."))
        }
        if let error {
            let text = description.flatMap { $0.isEmpty ? nil : $0 } ?? error
            authResult = ["success": false, "error": .string(text)]
            return (200, CallbackServer.page(success: false, message: text))
        }
        guard let code, !code.isEmpty else {
            authResult = ["success": false, "error": "Missing code parameter"]
            return (400, CallbackServer.page(success: false, message: "Missing authorization code"))
        }
        // Taken before the exchange: a second request with the same state (a browser retry, a pasted URL) is
        // refused instead of exchanging the code again and racing this one.
        pendingAuth = nil
        let attempt = authAttempt
        do {
            let tokens = try await DeveloperPortalOAuth.exchangeCode(code, clientID: pending.clientID, clientSecret: pending.clientSecret, redirectURI: pending.redirectURI, http: http)
            try TokenFile.save(tokens, to: tokenFile(.developerPortal))
            devicesCache.removeAll()
            authResult = [
                "success": true, "message": "Authentication successful!",
                "expiresAt": tokens.expiresAt.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
            ]
            Task { await callbackServer.stop() }
            logger.info("[Auth] Developer Portal authentication successful")
            await resumeIfIdle(.developerPortal)
            return (200, CallbackServer.page(success: true, message: "Authentication successful! You can close this window."))
        } catch {
            restore(pending, attempt)
            authResult = ["success": false, "error": .string(message(of: error))]
            return (200, CallbackServer.page(success: false, message: "Token exchange failed: \(message(of: error))"))
        }
    }

    /// The state the login started with, compared in constant time.
    static func isPendingState(_ state: String, of pending: PendingAuth) -> Bool {
        Secrets.constantTimeEqual(Array(state.utf8), Array(pending.state.utf8))
    }

    /// A failed exchange leaves the login pending, as the Homebridge plugin does (the URL can still be pasted),
    /// unless it was cancelled or another one started meanwhile.
    private func restore(_ pending: PendingAuth, _ attempt: Int) {
        if attempt == authAttempt, pendingAuth == nil { pendingAuth = pending }
    }

    /// The callback URL pasted in Setup, when the redirect could not reach this host.
    func completeAuthorization(_ body: [String: JSONValue]) async throws -> JSONValue {
        var code = body["code"]?.stringValue
        var state = body["state"]?.stringValue
        if let callback = DaikinSettings.nonEmpty(body["callbackUrl"]) {
            guard let url = URL(string: callback.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host != nil else { throw DaikinError("Invalid callback URL format") }
            code = URLQuery.parameter("code", in: url.absoluteString)
            state = URLQuery.parameter("state", in: url.absoluteString)
        }
        guard let code, !code.isEmpty else { throw DaikinError("Authorization code is required") }
        guard let pending = pendingAuth else { throw DaikinError("No pending authorization. Please start the auth flow again.") }
        guard let state, Self.isPendingState(state, of: pending) else { throw DaikinError("Invalid or missing state parameter. Please paste the full callback URL or start again.") }
        if pendingExpired {
            pendingAuth = nil
            throw DaikinError("Authorization request expired. Please try again.")
        }
        pendingAuth = nil
        let attempt = authAttempt
        do {
            let tokens = try await DeveloperPortalOAuth.exchangeCode(code, clientID: pending.clientID, clientSecret: pending.clientSecret, redirectURI: pending.redirectURI, http: http)
            try TokenFile.save(tokens, to: tokenFile(.developerPortal))
            devicesCache.removeAll()
            await callbackServer.stop()
            logger.info("[Auth] Developer Portal authentication successful")
            await resumeIfIdle(.developerPortal)
            return [
                "success": true, "message": "Authentication successful! Save the settings to apply.",
                "expiresAt": tokens.expiresAt.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
            ]
        } catch {
            restore(pending, attempt)
            throw DaikinError("Token exchange failed: \(message(of: error))")
        }
    }

    func pollAuthorization() async -> JSONValue {
        if let result = authResult {
            if result["success"]?.boolValue == true {
                authResult = nil
                await callbackServer.stop()
            }
            return result
        }
        if let tokens = TokenFile.load(tokenFile(.developerPortal)), !tokens.access_token.isEmpty, pendingAuth == nil {
            return [
                "success": true, "message": "Authentication successful!",
                "expiresAt": tokens.expiresAt.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
            ]
        }
        return ["pending": true]
    }

    // MARK: The Mobile App login (Setup's)

    func testMobileLogin(_ body: [String: JSONValue]) async -> JSONValue {
        guard let email = DaikinSettings.nonEmpty(body["email"]), let password = DaikinSettings.nonEmpty(body["password"]) else {
            return ["success": false, "message": "Email and password are required"]
        }
        devicesCache.removeAll()
        logger.info("[DaikinCloud] Testing mobile app authentication...")
        let logger = logger
        let mobile = MobileOAuth(email: email, password: password, http: http, log: { logger.info("\($0)") })
        let tokens: TokenSet
        do {
            tokens = try await mobile.authenticate().withExpiresAt()
            try TokenFile.save(tokens, to: tokenFile(.mobileApp))
        } catch {
            logger.error("[DaikinCloud] Mobile auth test failed: \(message(of: error))")
            return ["success": false, "message": .string(message(of: error))]
        }
        logger.info("[DaikinCloud] Mobile authentication successful")
        var count = 0
        var rateLimit: JSONValue = .null
        do {
            let (data, limit) = try await DaikinAPI.get("/v1/gateway-devices", accessToken: tokens.access_token, http: http)
            count = data?.arrayValue?.count ?? 0
            rateLimit = limit.json
        } catch {
            logger.warning("[DaikinCloud] API test failed: \(message(of: error))")
        }
        await resumeIfIdle(.mobileApp)
        return [
            "success": true, "message": "Authentication successful!", "deviceCount": .number(Double(count)), "rateLimit": rateLimit,
            "expiresAt": tokens.expiresAt.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
        ]
    }

    // MARK: Revoke, test

    func revoke(_ body: [String: JSONValue]) async -> JSONValue {
        devicesCache.removeAll()
        let developer = TokenFile.load(tokenFile(.developerPortal))
        let mobile = TokenFile.load(tokenFile(.mobileApp))
        guard developer != nil || mobile != nil else { return ["success": true, "message": "No tokens to revoke"] }
        let clientID = DaikinSettings.nonEmpty(body["clientId"]) ?? settings.clientID
        let clientSecret = DaikinSettings.nonEmpty(body["clientSecret"]) ?? settings.clientSecret
        if let refresh = developer?.refresh_token, let clientID, let clientSecret {
            do {
                try await DeveloperPortalOAuth.revoke(refresh, clientID: clientID, clientSecret: clientSecret, http: http)
            } catch {
                logger.warning("Failed to revoke token at server: \(message(of: error))")
            }
        }
        // The running instance stops using the tokens now, not at the next restart, and before the files go: a
        // refresh in flight must not write them back.
        if let session {
            await session.stop()
            await session.tokens.clear()
            self.session = nil
            logger.warning("[Auth] Authentication revoked from the settings page; authenticate again to reconnect")
        }
        TokenFile.delete(tokenFile(.developerPortal))
        TokenFile.delete(tokenFile(.mobileApp))
        return ["success": true, "message": "Authentication revoked. You will need to re-authenticate."]
    }

    func testConnection() async -> JSONValue {
        let (tokens, mode) = activeToken()
        guard let tokens, !tokens.access_token.isEmpty else {
            return ["success": false, "message": "Not authenticated. Please authenticate first."]
        }
        do {
            // The running instance's token client refreshes an expired token first; the Homebridge page sent the
            // saved one as it was, and failed once it had expired.
            let accessToken = session?.mode == mode ? try await session?.tokens.accessToken() ?? tokens.access_token : tokens.access_token
            let (data, _) = try await DaikinAPI.get("/v1/gateway-devices", accessToken: accessToken, http: http)
            let count = data?.arrayValue?.count ?? 0
            return ["success": true, "message": .string("Connection successful! Found \(count) device(s)."), "deviceCount": .number(Double(count))]
        } catch {
            return ["success": false, "message": .string("Connection failed: \(message(of: error))"), "error": .string(message(of: error))]
        }
    }

    // MARK: Devices

    func listDevices(mode requested: AuthMode?, refresh: Bool) async -> JSONValue {
        let (tokens, mode) = token(for: requested)
        guard let tokens, !tokens.access_token.isEmpty else {
            return ["success": false, "devices": [], "message": "Not authenticated. Please authenticate first."]
        }
        if refresh { devicesCache[mode] = nil }
        if let cached = devicesCache[mode], Date().timeIntervalSince(cached.fetchedAt) < Self.devicesCacheLifetime {
            var result = cached.result
            result["cached"] = true
            result["fetchedAt"] = .string(ISO8601DateFormatter.withFractionalSeconds.string(from: cached.fetchedAt))
            return .object(result)
        }
        // The instance's own list costs no call: it polls anyway.
        if !refresh, mode == settings.authMode, let session, await session.isRunning, let fetched = await session.lastFetched {
            let devices = await session.devices.map { Self.summary($0.raw) }
            return [
                "success": true, "devices": .array(devices), "message": .string("Found \(devices.count) device(s)."), "cached": true,
                "fetchedAt": .string(ISO8601DateFormatter.withFractionalSeconds.string(from: fetched)),
            ]
        }
        do {
            let (data, _) = try await DaikinAPI.get("/v1/gateway-devices", accessToken: tokens.access_token, http: http)
            let devices = (data?.arrayValue ?? []).map(Self.summary)
            let result: [String: JSONValue] = ["success": true, "devices": .array(devices), "message": .string("Found \(devices.count) device(s).")]
            let fetched = Date()
            devicesCache[mode] = (result, fetched)
            var answer = result
            answer["cached"] = false
            answer["fetchedAt"] = .string(ISO8601DateFormatter.withFractionalSeconds.string(from: fetched))
            return .object(answer)
        } catch {
            return ["success": false, "devices": [], "message": .string("Failed to fetch devices: \(message(of: error))"), "error": .string(message(of: error))]
        }
    }

    /// A device as the page lists it.
    static func summary(_ device: JSONValue) -> JSONValue {
        let points = device["managementPoints"]?.arrayValue ?? []
        let byID = { (id: String) in points.first { $0["embeddedId"]?.stringValue == id } }
        let climate = climateControlIDs.lazy.compactMap(byID).first
        let gateway = byID("gateway")
        func temperature(_ key: String) -> JSONValue {
            guard let reading = climate?["sensoryData"]?["value"]?[key], let value = reading["value"], !value.isNull else { return .null }
            let unit = reading["unit"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "°C"
            return .string("\(DaikinSettings.display(value))\(unit)")
        }
        var type = device["type"]?.stringValue ?? "Unknown Type"
        if !points.isEmpty {
            for point in points {
                if point["embeddedId"]?.stringValue == "climateControl" { type = "Climate Control"; break }
                if point["embeddedId"]?.stringValue == "domesticHotWaterTank" { type = "Hot Water Tank"; break }
            }
        }
        var features: [JSONValue] = []
        for point in points {
            let id = point["embeddedId"]?.stringValue ?? ""
            if climateControlIDs.contains(id) {
                if point["onOffMode"] != nil { features.append("Power") }
                if point["temperatureControl"] != nil { features.append("Temperature") }
                if point["operationMode"] != nil { features.append("Mode") }
                if point["fanControl"] != nil { features.append("Fan") }
                if point["sensoryData"] != nil { features.append("Sensors") }
            }
            if id == "domesticHotWaterTank" {
                if point["onOffMode"] != nil { features.append("Hot Water") }
                if point["temperatureControl"] != nil { features.append("Water Temp") }
            }
        }
        let nonEmpty = { (value: JSONValue?) -> String? in value?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        return [
            "id": device["id"] ?? .null,
            "name": .string(nonEmpty(climate?["name"]?["value"]) ?? nonEmpty(device["id"]) ?? "Unknown Device"),
            "model": .string(nonEmpty(gateway?["modelInfo"]?["value"]) ?? nonEmpty(device["deviceModel"]) ?? "Unknown Model"),
            "type": .string(type),
            "online": .bool(device["isCloudConnectionUp"]?["value"]?.boolValue ?? false),
            "features": .array(features),
            "roomTemp": temperature("roomTemperature"),
            "outdoorTemp": temperature("outdoorTemperature"),
            "operationMode": nonEmpty(climate?["operationMode"]?["value"]).map(JSONValue.string) ?? .null,
            "powerState": nonEmpty(climate?["onOffMode"]?["value"]).map(JSONValue.string) ?? .null,
        ]
    }

    // MARK: Rate limit

    /// The quota the plugin recorded after its last call: reading it costs nothing. The running session has it;
    /// before its first call, the file keeps the one from before a restart.
    func rateLimit() async -> JSONValue {
        let status: JSONValue
        if let recorded = await session?.rateLimit {
            status = recorded
        } else {
            let url = storage.appendingPathComponent(Self.rateLimitFileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ["success": false, "noData": true, "message": "No data yet — the plugin records this after its next API call."]
            }
            guard let data = try? Data(contentsOf: url), let file = try? JSONValue(data: data), case .object = file else {
                return ["success": false, "message": "Could not read rate limit status: invalid file contents"]
            }
            status = file
        }
        var updated: Date?
        if let text = status["updatedAt"]?.stringValue {
            updated = ISO8601DateFormatter.withFractionalSeconds.date(from: text) ?? ISO8601DateFormatter.internetDateTime.date(from: text)
        } else if let milliseconds = status["updatedAt"]?.doubleValue {
            updated = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        var limits: [String: JSONValue] = [:]
        for key in ["limitMinute", "remainingMinute", "limitDay", "remainingDay"] { if let value = status[key] { limits[key] = value } }
        return [
            "success": true, "rateLimit": .object(limits), "mode": status["mode"] ?? .null,
            "updatedAt": updated.map { .string(ISO8601DateFormatter.withFractionalSeconds.string(from: $0)) } ?? .null,
            "ageMs": updated.map { .number(max(0, (Date().timeIntervalSince($0) * 1000).rounded())) } ?? .null,
        ]
    }
}
