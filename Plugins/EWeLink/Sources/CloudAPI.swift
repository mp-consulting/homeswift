import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// An error with the message the Homebridge plugin shows.
struct EWeLinkError: Error, CustomStringConvertible, Equatable, Sendable {
    let message: String
    /// The eWeLink error code, when the cloud gave one.
    var code: Int?

    init(_ message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }

    var description: String { message }
}

/// The eWeLink cloud's HTTP API (v2): login signed with HMAC-SHA256, region redirects, token refresh,
/// homes, devices and groups, commands, and the WebSocket dispatch.
///
/// eWeLink usually reports an expired access token as HTTP 200 with `error: 401` or `402` in the body; a
/// plain HTTP 401 is handled the same way. Concurrent requests share one refresh.
actor CloudAPI {
    struct Credentials: Sendable {
        var username: String?
        var password: String?
        var countryCode: String?
    }

    /// An HTTP status that is not 2xx, with the eWeLink message when the body had one.
    struct HTTPStatusError: Error, CustomStringConvertible {
        let status: Int
        let message: String?
        let code: Int?
        var description: String { message ?? "Request failed with status code \(status)" }
    }

    /// Body-level codes meaning the access token is invalid or expired.
    static let tokenErrorCodes: Set<Int> = [401, 402]

    let credentials: Credentials
    let transport: any HTTPSending
    let storage: TokenStorage?
    let logger: Logger
    let debug: Bool
    private(set) var region: EWeLinkCloud.Region
    private(set) var httpHost: String
    private(set) var apiKey = ""
    private(set) var accessToken = ""
    private(set) var refreshToken = ""
    private var triedBase64 = false
    private var currentPassword = ""
    private var refreshTask: Task<Void, any Error>?

    init(credentials: Credentials, transport: any HTTPSending, storage: TokenStorage?, logger: Logger, debug: Bool = false) {
        self.credentials = credentials
        self.transport = transport
        self.storage = storage
        self.logger = logger
        self.debug = debug
        region = EWeLinkCloud.Region(countryCode: credentials.countryCode)
        httpHost = region.httpHost
        if storage == nil { logger.debug("No storage directory - token persistence disabled") }
    }

    // MARK: Requests

    private struct Options {
        var headers: [String: String] = [:]
        /// Login and refresh never trigger a refresh.
        var skipAuthRefresh = false
        var retried = false
        var authorization = true
    }

    /// Sends a request and returns the JSON body. Non-2xx statuses throw, except a 401 that a refresh fixes.
    private func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, options: Options = Options()) async throws -> JSONValue {
        var components = URLComponents()
        components.scheme = "https"
        components.host = httpHost
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw EWeLinkError("Invalid URL for \(path)") }
        var headers = ["Content-Type": "application/json", "X-CK-Appid": EWeLinkCloud.appID]
        if options.authorization, !accessToken.isEmpty { headers["Authorization"] = "Bearer \(accessToken)" }
        headers.merge(options.headers) { $1 }
        let sentToken = accessToken
        let response = try await transport.send(
            HTTPRequest(method: method, url: url, headers: headers.map { ($0.key, $0.value) }, body: body, timeout: .milliseconds(Timing.httpRequest)))
        let json = (try? JSONValue(data: response.body)) ?? .null
        let canRefresh = !options.retried && !options.skipAuthRefresh && !refreshToken.isEmpty
        if response.status == 401, canRefresh {
            return try await retryWithFreshToken(method, path, query: query, body: body, options: options, rejected: sentToken)
        }
        guard (200..<300).contains(response.status) else {
            throw HTTPStatusError(status: response.status, message: json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }, code: json["error"]?.intValue)
        }
        if let code = json["error"]?.intValue, Self.tokenErrorCodes.contains(code), canRefresh {
            logger.debug("Access token rejected (error \(code)), refreshing...")
            return try await retryWithFreshToken(method, path, query: query, body: body, options: options, rejected: sentToken)
        }
        return json
    }

    /// `rejected` is the token the request went with: when another request's refresh has replaced it meanwhile, the
    /// retry takes the new one rather than refreshing again with a refresh token that has just rotated.
    private func retryWithFreshToken(_ method: String, _ path: String, query: [(String, String)], body: Data?, options: Options, rejected: String) async throws -> JSONValue {
        if accessToken == rejected { try await refreshAccessToken() }
        var retry = options
        retry.retried = true
        retry.headers["Authorization"] = "Bearer \(accessToken)"
        return try await request(method, path, query: query, body: body, options: retry)
    }

    /// One refresh for every request that needs it.
    func refreshAccessToken() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performTokenRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performTokenRefresh() async throws {
        let body = JSONValue.object(["rt": .string(refreshToken)]).encoded()
        let json = try await request("POST", "/v2/user/refresh", body: body, options: Options(skipAuthRefresh: true))
        let code = json["error"]?.intValue ?? -1
        guard code == 0, let at = json["data"]?["at"]?.stringValue else { throw EWeLinkError("Failed to refresh token [\(code)]", code: code) }
        accessToken = at
        refreshToken = json["data"]?["rt"]?.stringValue ?? refreshToken
        persistTokens()
        logger.debug("Token refreshed successfully")
    }

    private func applyRegion(_ name: String) throws {
        guard let newRegion = EWeLinkCloud.Region(rawValue: name) else { throw EWeLinkError("Unknown region received: \(name)") }
        region = newRegion
        httpHost = newRegion.httpHost
    }

    private func persistTokens() {
        guard let storage else { return }
        do {
            try storage.save(accessToken: accessToken, refreshToken: refreshToken, apiKey: apiKey, region: region.rawValue)
        } catch {
            logger.error("Failed to save tokens: \(error)")
        }
    }

    static func signature(_ text: String) -> String {
        let key = SymmetricKey(data: Data(EWeLinkCloud.appSecret.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)).base64EncodedString()
    }

    /// Eight hex characters of randomness, as the API requires.
    static func nonce() -> String {
        Secrets.hex(Secrets.randomBytes(4))
    }

    /// The login body, keys in the order the signature covers: countryCode, password, then email or phoneNumber.
    static func loginBody(username: String, password: String, countryCode: String) -> String {
        let field = username.contains("@") ? "email" : "phoneNumber"
        return "{\"countryCode\":\(javaScriptStringLiteral(countryCode)),\"password\":\(javaScriptStringLiteral(password)),\"\(field)\":\(javaScriptStringLiteral(username))}"
    }

    // MARK: Login

    /// Region redirects one login follows: a server bouncing between regions would otherwise loop forever.
    static let maximumRegionRedirects = 3

    func login() async throws {
        try await login(redirects: 0)
    }

    private func login(redirects: Int) async throws {
        logger.debug("=== LOGIN START ===")
        let username = credentials.username ?? "", password = credentials.password ?? ""
        logger.debug("Username: \(username.isEmpty ? "EMPTY" : String(username.prefix(3)) + "***")")
        guard !username.isEmpty, !password.isEmpty else { throw EWeLinkError("Username and password are required") }
        if currentPassword.isEmpty {
            currentPassword = password
        } else {
            logger.debug("Using modified password (possibly base64 decoded)")
        }
        logger.debug("Login method: \(username.contains("@") ? "EMAIL" : "PHONE")")
        let countryCode = (credentials.countryCode?.isEmpty == false ? credentials.countryCode : nil) ?? "1"
        let body = Self.loginBody(username: username, password: currentPassword, countryCode: countryCode)
        let signature = Self.signature(body)
        logger.debug("Full URL: https://\(httpHost)/v2/user/login")

        let json: JSONValue
        do {
            json = try await request(
                "POST", "/v2/user/login", body: Data(body.utf8),
                options: Options(headers: ["X-CK-Nonce": Self.nonce(), "Authorization": "Sign \(signature)"], skipAuthRefresh: true, authorization: false))
        } catch let error as HTTPStatusError {
            logger.debug("=== LOGIN END (ERROR) ===")
            logger.error("Login HTTP error: \(error.status) - \(error.description)\(error.code.map { " [\($0)]" } ?? "")")
            throw EWeLinkError("Login failed: \(error.description)")
        } catch {
            logger.debug("=== LOGIN END (ERROR) ===")
            logger.error("Login HTTP error: no response - \(error)")
            throw EWeLinkError("Login failed: \(error)")
        }
        let code = json["error"]?.intValue
        logger.debug("Response error code: \(code.map(String.init) ?? "none")")

        if code == 10004, let given = json["data"]?["region"]?.stringValue {
            guard redirects < Self.maximumRegionRedirects else { throw EWeLinkError("Login failed: too many region redirects [\(given)]", code: code) }
            logger.info("Region redirect required: \(httpHost) -> \(given)")
            try applyRegion(given)
            logger.debug("Retrying login with new host: \(httpHost)")
            return try await login(redirects: redirects + 1)
        }
        if let code, [10001, 10014].contains(code), !triedBase64 {
            logger.warning("Password error (\(code)), attempting base64 decode...")
            triedBase64 = true
            let decoded = lenientBase64Decode(password).map { String(decoding: $0, as: UTF8.self) } ?? ""
            currentPassword = decoded.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("Password length changed from \(password.count) to \(currentPassword.count) chars")
            return try await login(redirects: redirects)
        }
        if let at = json["data"]?["at"]?.stringValue {
            accessToken = at
            refreshToken = json["data"]?["rt"]?.stringValue ?? ""
            apiKey = json["data"]?["user"]?["apikey"]?.stringValue ?? ""
            persistTokens()
            logger.info("✓ Successfully logged in to eWeLink")
            logger.debug("=== LOGIN END (SUCCESS) ===")
            return
        }
        logger.error("Login failed - no access token in response (error \(code.map(String.init) ?? "undefined"))")
        logger.debug("=== LOGIN END (ERROR) ===")
        if let message = json["msg"]?.stringValue, !message.isEmpty {
            throw EWeLinkError("\(message) [\(code.map(String.init) ?? "undefined")]", code: code)
        }
        throw EWeLinkError("Login failed: unexpected response [\(code.map(String.init) ?? "undefined")]", code: code)
    }

    // MARK: Homes and devices

    func homes() async throws -> [String] {
        let json: JSONValue
        do {
            json = try await request("GET", "/v2/family")
        } catch let error as HTTPStatusError {
            throw EWeLinkError("Failed to get homes: \(error.description)")
        }
        guard json["error"]?.intValue == 0, let families = json["data"]?["familyList"]?.arrayValue else {
            throw EWeLinkError(json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Failed to get family list")
        }
        let ids = families.compactMap { family -> String? in
            guard let id = family["id"]?.jsString else { return nil }
            logger.debug("Found home: \(family["name"]?.stringValue ?? "") [\(id)]")
            return id
        }
        logger.debug("Retrieved \(ids.count) homes from API")
        return ids
    }

    /// The rooms of every home (`GET /v2/family`'s `roomList`), with their home's name.
    func rooms() async throws -> [(id: String, name: String, homeID: String, home: String)] {
        let json: JSONValue
        do {
            json = try await request("GET", "/v2/family")
        } catch let error as HTTPStatusError {
            throw EWeLinkError("Failed to get homes: \(error.description)")
        }
        guard json["error"]?.intValue == 0, let families = json["data"]?["familyList"]?.arrayValue else {
            throw EWeLinkError(json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Failed to get family list")
        }
        return families.flatMap { family in
            (family["roomList"]?.arrayValue ?? []).compactMap { room in
                guard let id = room["id"]?.jsString, let name = room["name"]?.stringValue, let home = family["id"]?.jsString else { return nil }
                return (id, name, home, family["name"]?.stringValue ?? "")
            }
        }
    }

    /// `PUT /v2/family/room` with `{id, name}`: the only change eWeLink allows a room (CoolKit's v2 API, as
    /// ewelink-api-next's `home.setRoom` sends it).
    func renameRoom(_ id: String, name: String) async throws {
        let json: JSONValue
        do {
            json = try await request("PUT", "/v2/family/room", body: JSONValue.object(["id": .string(id), "name": .string(name)]).encoded())
        } catch let error as HTTPStatusError {
            throw EWeLinkError("Failed to rename the room: \(error.description)")
        }
        guard json["error"]?.intValue == 0 else {
            throw EWeLinkError(json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Failed to rename the room", code: json["error"]?.intValue)
        }
    }

    /// The devices (things with a UIID) and groups (item type 3) of every home.
    func devices() async throws -> (devices: [EWeLinkDevice], groups: [JSONValue]) {
        let homes = try await homes()
        if homes.isEmpty {
            logger.warning("No homes found in eWeLink account")
            return ([], [])
        }
        var devices: [EWeLinkDevice] = [], groups: [JSONValue] = []
        do {
            for home in homes {
                logger.debug("Fetching devices for home: \(home)")
                let json = try await request("GET", "/v2/device/thing", query: [("num", "0"), ("familyid", home)])
                guard json["error"]?.intValue == 0 else {
                    logger.warning("Failed to get devices for home \(home): \(json["msg"]?.stringValue ?? "undefined")")
                    continue
                }
                for thing in json["data"]?["thingList"]?.arrayValue ?? [] {
                    guard let item = thing["itemData"] else { continue }
                    if let uiid = item["extra"]?["uiid"], uiid.jsNumber.map({ $0 != 0 }) ?? false, let device = EWeLinkDevice(item) {
                        devices.append(device)
                    } else if thing["itemType"]?.intValue == 3 {
                        groups.append(item)
                    }
                }
            }
        } catch let error as HTTPStatusError {
            throw EWeLinkError("Failed to get devices: \(error.description)")
        }
        logger.debug("Retrieved \(devices.count) devices and \(groups.count) groups from API")
        return (devices, groups)
    }

    func device(_ deviceID: String) async -> EWeLinkDevice? {
        do {
            let thingList = JSONValue.array([["itemType": 1, "id": .string(deviceID)]]).text()
            let json = try await request("GET", "/v2/device/thing", query: [("thingList", thingList)])
            guard json["error"]?.intValue == 0 else { return nil }
            return json["data"]?["thingList"]?[0]?["itemData"].flatMap(EWeLinkDevice.init)
        } catch {
            logger.error("Failed to get device: \(deviceID) \(error)")
            return nil
        }
    }

    private func status(type: Int, id: String, params: DeviceParams) async throws -> JSONValue {
        let body = JSONValue.object(["type": .number(Double(type)), "id": .string(id), "params": .object(params)]).encoded()
        return try await request("POST", "/v2/device/thing/status", body: body)
    }

    func updateDevice(_ deviceID: String, params: DeviceParams) async -> Bool {
        do {
            return try await status(type: 1, id: deviceID, params: params)["error"]?.intValue == 0
        } catch {
            logger.error("Failed to update device: \(deviceID) \(error)")
            return false
        }
    }

    /// Groups take `type: 2`.
    func updateGroup(_ groupID: String, params: DeviceParams) async -> Bool {
        do {
            return try await status(type: 2, id: groupID, params: params)["error"]?.intValue == 0
        } catch {
            logger.error("Failed to update group: \(groupID) \(error)")
            return false
        }
    }

    /// A command over HTTP (the settings page's test button).
    func setDeviceState(_ deviceID: String, params: DeviceParams) async -> Bool {
        logger.debug("Setting device state for \(deviceID): \(JSONValue.object(params).text())")
        do {
            let json = try await status(type: 1, id: deviceID, params: params)
            if json["error"]?.intValue == 0 {
                logger.debug("Successfully updated device \(deviceID)")
                return true
            }
            logger.error("Failed to update device \(deviceID): \(json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown error")")
            return false
        } catch let error as HTTPStatusError {
            logger.error("HTTP error setting device state: \(error.status) - \(error.description)")
            return false
        } catch {
            logger.error("Error setting device state: \(error)")
            return false
        }
    }

    // MARK: The WebSocket host

    /// The WebSocket URL from the dispatch service, else the region's `pconnect3` host.
    func socketURL(now: Double = Date().timeIntervalSince1970) async -> String {
        logger.debug("Fetching WebSocket host from: https://\(httpHost)/dispatch/app")
        do {
            let body = JSONValue.object([
                "appid": .string(EWeLinkCloud.appID), "nonce": .string(Self.nonce()), "ts": .number(now.rounded(.down)), "version": 8,
            ]).encoded()
            let json = try await request("POST", "/dispatch/app", body: body)
            guard let domain = json["domain"]?.stringValue, !domain.isEmpty else { throw EWeLinkError("No WebSocket host received from dispatch endpoint") }
            let url = "wss://\(domain):8080/api/ws"
            logger.debug("WebSocket host received: \(url)")
            return url
        } catch {
            // Common (503s); the fallback hosts work.
            if let error = error as? HTTPStatusError {
                logger.debug("Dispatch service unavailable (\(error.status)), using fallback WebSocket host")
            } else {
                logger.debug("Dispatch error: \(error), using fallback")
            }
            var host = EWeLinkCloud.socketHostMapping.first { httpHost.contains($0.prefix) }?.host
            if host == nil { host = region.socketHosts[2] }
            let url = "wss://\(host ?? httpHost)/api/ws"
            logger.debug("Using fallback WebSocket host: \(url)")
            return url
        }
    }

    // MARK: Credentials

    /// The tokens saved by the last login or refresh, when they are less than a day old.
    @discardableResult
    func reloadTokensFromStorage() -> Bool {
        guard let tokens = storage?.loadValid() else {
            logger.debug("No valid tokens found in storage")
            return false
        }
        logger.debug("Reloading tokens from storage")
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        apiKey = tokens.apiKey
        if !tokens.region.isEmpty, tokens.region != region.rawValue {
            if let stored = EWeLinkCloud.Region(rawValue: tokens.region) {
                region = stored
                httpHost = stored.httpHost
            } else {
                logger.debug("Ignoring unknown region in stored tokens: \(tokens.region)")
            }
        }
        return true
    }

    func setCredentials(accessToken: String, apiKey: String? = nil, refreshToken: String? = nil, region: String? = nil) {
        self.accessToken = accessToken
        if let apiKey, !apiKey.isEmpty { self.apiKey = apiKey }
        if let refreshToken, !refreshToken.isEmpty { self.refreshToken = refreshToken }
        if let region, region != self.region.rawValue, let known = EWeLinkCloud.Region(rawValue: region) {
            self.region = known
            httpHost = known.httpHost
        }
    }
}
