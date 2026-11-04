import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging

/// A refused request: Tuya's `code` and `msg`, with what the code usually means.
struct TuyaAPIError: Error, CustomStringConvertible, Sendable {
    let code: Int
    let message: String

    var description: String {
        let explanation = Self.explanation(code).map { " (\($0))" } ?? ""
        return "Tuya refused the request: \(code) \(message)\(explanation)"
    }

    static func explanation(_ code: Int) -> String? {
        switch code {
        case 1004, 1114: "check the endpoint, Access ID and Access Secret"
        case 1106: "check the country code, username, password and app, and that the app account is linked to the cloud project"
        case 2401: "the username or password is wrong"
        case 2406: "the app account is in another data centre, or not linked to the cloud project"
        case 1010: "the token is no longer valid: the same account may be used by another bridge at the same time, which Tuya does not allow"
        case 28841002: "the cloud project's API subscription has expired: renew it on the Tuya IoT Platform"
        case 28841101, 28841105:
            "an API is not subscribed: authorize Authorization Token Management, Device Status Notification, IoT Core and, for a Custom project, Industry Project Client Service"
        default: nil
        }
    }
}

/// The tokens of a signed-in project.
struct TuyaToken: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var uid: String
    var expiresAt: Date
}

/// Tuya's OpenAPI over HTTPS (developer.tuya.com, "API request"): signed requests, the tokens of both kinds of
/// project, refreshed lazily, and the endpoints the plugin uses.
actor TuyaOpenAPI {
    let accessID: String
    private let accessKey: String
    private(set) var host: String
    private let transport: any HTTPSending
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String
    private let logger: Logger
    private let debug: Bool
    private let retryBackoff: Backoff
    private(set) var token: TuyaToken?
    private var refreshing: Task<Void, Never>?

    static let customUser = "homebridge"
    static let retries = 10

    init(
        accessID: String, accessKey: String, host: String, transport: any HTTPSending, logger: Logger, debug: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }, nonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        retryBackoff: Backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(60), jitter: .additive(.milliseconds(100)))
    ) {
        self.accessID = accessID
        self.accessKey = accessKey
        self.host = host
        self.transport = transport
        self.logger = logger
        self.debug = debug
        self.now = now
        self.nonce = nonce
        self.retryBackoff = retryBackoff
    }

    // MARK: Requests

    /// A signed request's `result`. Throws `TuyaAPIError` when Tuya answers `success: false`.
    func request(_ method: String, _ path: String, query: [(String, String?)] = [], body: Data? = nil) async throws -> JSONValue {
        let isTokenPath = path.hasPrefix("/v1.0/token")
        if !isTokenPath, let token, token.expiresAt.timeIntervalSince(now()) < 60 {
            // Requests at the same moment share one refresh.
            let refreshing = self.refreshing ?? Task { await refresh(token) }
            self.refreshing = refreshing
            await refreshing.value
            self.refreshing = nil
        }
        let accessToken = isTokenPath ? "" : token?.accessToken ?? ""
        let pairs = query.compactMap { pair in pair.1.map { (pair.0, $0) } }
        let t = String(Int64((now().timeIntervalSince1970 * 1000).rounded(.down)))
        let nonce = nonce()
        let stringToSign = TuyaSignature.stringToSign(method: method, path: path, query: pairs, body: body, accessID: accessID)
        let sign = TuyaSignature.sign(accessID: accessID, accessKey: accessKey, accessToken: accessToken, t: t, nonce: nonce, stringToSign: stringToSign)
        var text = "https://\(host)\(path)"
        if !pairs.isEmpty { text += "?" + URLEncoding.form(pairs) }
        guard let url = URL(string: text) else { throw HTTPClientError.invalidURL(Self.masked(path)) }
        var request = HomeswiftNetwork.HTTPRequest(method: method, url: url, headers: [
            ("t", t), ("client_id", accessID), ("nonce", nonce), ("Signature-Headers", "client_id"), ("sign", sign), ("sign_method", "HMAC-SHA256"),
            ("access_token", accessToken), ("lang", "en"), ("dev_lang", "swift"), ("dev_channel", "homeswift"), ("devVersion", "1.0"),
        ], body: body, timeout: .seconds(15))
        if body != nil { request.setHeader("Content-Type", "application/json") }
        if debug { logger.debug("Tuya API request", metadata: ["method": "\(method)", "path": "\(Self.masked(path))", "query": "\(pairs.map(\.0))"]) }
        let response = try await send(request, path: path)
        guard response.status == 200 else {
            logger.warning("Tuya answered HTTP \(response.status) to \(method) \(Self.masked(path))")
            throw TuyaAPIError(code: response.status, message: "HTTP \(response.status)")
        }
        let json = try JSONValue(data: response.body)
        if debug { logger.debug("Tuya API response", metadata: ["path": "\(Self.masked(path))", "success": "\(json["success"]?.boolValue ?? false)"]) }
        guard json["success"]?.boolValue == true else {
            throw TuyaAPIError(code: json["code"]?.intValue ?? 0, message: json["msg"]?.stringValue ?? "unknown error")
        }
        return json["result"] ?? .null
    }

    /// A network failure is tried again, up to ten times, the delay doubling from 100 ms.
    private func send(_ request: HomeswiftNetwork.HTTPRequest, path: String) async throws -> HomeswiftNetwork.HTTPResponse {
        var attempt = 0
        while true {
            do {
                return try await transport.send(request)
            } catch let error as HTTPClientError where attempt < Self.retries && error.isRetryable {
                logger.debug("Tuya API request failed, trying again: \(error)", metadata: ["path": "\(Self.masked(path))"])
                try await Task.sleep(for: retryBackoff.delay(attempt: attempt))
                attempt += 1
            }
        }
    }

    /// A path for the log: a refresh token in it masked.
    static func masked(_ path: String) -> String {
        path.hasPrefix("/v1.0/token/") ? "/v1.0/token/***" : path
    }

    private func store(_ result: JSONValue, expiresKey: String = "expire_time") throws -> TuyaToken {
        guard let accessToken = result["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw TuyaAPIError(code: 0, message: "no access token in the answer")
        }
        let seconds = result[expiresKey]?.doubleValue ?? 7200
        let token = TuyaToken(
            accessToken: accessToken, refreshToken: result["refresh_token"]?.stringValue ?? "", uid: TuyaDevice.text(result["uid"]),
            expiresAt: now().addingTimeInterval(seconds))
        self.token = token
        return token
    }

    private func refresh(_ current: TuyaToken) async {
        guard !current.refreshToken.isEmpty else { return }
        do {
            let result = try await request("GET", "/v1.0/token/\(current.refreshToken)")
            var token = try store(result)
            if token.uid.isEmpty { token.uid = current.uid; self.token = token }
        } catch {
            logger.error("Could not refresh the Tuya token: \(error)")
        }
    }

    // MARK: Signing in

    /// A Smart Home project: the app account's login (its password as MD5). `platform_url` becomes the endpoint.
    @discardableResult
    func loginSmartHome(countryCode: Int, username: String, password: String, appSchema: String) async throws -> TuyaToken {
        token = nil
        let (hashed, wasHashed) = TuyaSignature.loginPassword(password)
        if wasHashed { logger.info("Logging in with an MD5 password") }
        logger.info("Logging in to Tuya Cloud", metadata: ["endpoint": "\(host)"])
        let body = OrderedJSON.object([
            ("country_code", .number(Double(countryCode))), ("username", .string(username)), ("password", .string(hashed)), ("schema", .string(appSchema)),
        ])
        let result = try await request("POST", "/v1.0/iot-01/associated-users/actions/authorized-login", body: body)
        let token = try store(result)
        if let platform = result["platform_url"]?.stringValue, let host = TuyaSettings.host(of: platform) { self.host = host }
        return token
    }

    /// A Custom project: its own token, the `homebridge` user (created if needed) given every top-level asset, then that
    /// user's token. Answers the assets' ids.
    func loginCustom() async throws -> [String] {
        token = nil
        logger.info("Getting a token")
        _ = try store(try await request("GET", "/v1.0/token", query: [("grant_type", "1")]))
        let password = TuyaSignature.sha256Hex(Self.customUser)
        logger.info("Searching for the default user \(Self.customUser)")
        let lookup = try await request("GET", "/v1.2/iot-02/users/\(Self.customUser)")
        var userID = TuyaDevice.text(lookup["user_id"])
        if (lookup["user_name"]?.stringValue ?? "").isEmpty {
            logger.info("Creating the default user \(Self.customUser)")
            let created = try await request("POST", "/v1.0/iot-02/users", body: OrderedJSON.object([
                ("username", .string(Self.customUser)), ("password", .string(password)), ("country_code", .number(1)),
            ]))
            userID = TuyaDevice.text(created["user_id"])
        } else {
            logger.info("Found the default user \(Self.customUser)")
        }
        logger.info("Fetching the asset list")
        let assets = try await request("GET", "/v1.0/iot-02/assets/-1/sub-assets", query: [("page_no", "0"), ("page_size", "100")])
        let list = assets["list"]?.arrayValue ?? []
        let ids = list.map { TuyaDevice.text($0["asset_id"]) }.filter { !$0.isEmpty }
        for asset in list { logger.info("Asset", metadata: ["id": "\(TuyaDevice.text(asset["asset_id"]))", "name": "\(asset["asset_name"]?.stringValue ?? "")"]) }
        guard !ids.isEmpty else {
            logger.warning("The Custom project has no assets: add the devices to an asset on the Tuya IoT Platform")
            return []
        }
        logger.info("Authorizing the assets")
        _ = try await request("POST", "/v1.0/iot-03/users/\(userID)/actions/batch-assets-authorized", body: OrderedJSON.object([
            ("asset_ids", .string(ids.joined(separator: ","))), ("authorized_children", .bool(true)),
        ]))
        logger.info("Logging in as \(Self.customUser)")
        let login = try await request("POST", "/v1.0/iot-03/users/login", body: OrderedJSON.object([
            ("username", .string(Self.customUser)), ("password", .string(password)),
        ]))
        _ = try store(login, expiresKey: "expire")
        return ids
    }

    // MARK: Endpoints

    func homes() async throws -> [JSONValue] {
        try await request("GET", "/v1.0/users/\(token?.uid ?? "")/homes").arrayValue ?? []
    }

    func homeDevices(_ homeID: String) async throws -> [JSONValue] {
        try await request("GET", "/v1.0/homes/\(homeID)/devices").arrayValue ?? []
    }

    func scenes(_ homeID: String) async throws -> [JSONValue] {
        try await request("GET", "/v1.1/homes/\(homeID)/scenes").arrayValue ?? []
    }

    func triggerScene(homeID: String, sceneID: String) async throws {
        _ = try await request("POST", "/v1.0/homes/\(homeID)/scenes/\(sceneID)/trigger")
    }

    /// An asset's device ids, page after page.
    func assetDeviceIDs(_ assetID: String) async throws -> [String] {
        var ids: [String] = []
        var lastRowKey: String?
        for _ in 0..<1000 {
            let result = try await request("GET", "/v1.0/iot-02/assets/\(assetID)/devices", query: [("page_size", "50"), ("last_row_key", lastRowKey)])
            ids += (result["list"]?.arrayValue ?? []).map { TuyaDevice.text($0["device_id"]) }.filter { !$0.isEmpty }
            guard result["has_next"]?.boolValue == true, let next = result["last_row_key"]?.stringValue, !next.isEmpty else { break }
            lastRowKey = next
        }
        return ids
    }

    /// Device records by id, twenty a request as Tuya documents.
    func devices(ids: [String]) async throws -> [JSONValue] {
        var records: [JSONValue] = []
        for start in stride(from: 0, to: ids.count, by: 20) {
            let chunk = ids[start..<min(start + 20, ids.count)]
            records += try await request("GET", "/v1.0/devices", query: [("device_ids", chunk.joined(separator: ","))])["devices"]?.arrayValue ?? []
        }
        return records
    }

    func device(_ id: String) async throws -> JSONValue {
        try await request("GET", "/v1.0/devices/\(id)")
    }

    func specification(_ id: String) async throws -> JSONValue {
        try await request("GET", "/v1.0/devices/\(id)/specifications")
    }

    func sendCommands(_ id: String, _ commands: [TuyaCommand]) async throws {
        _ = try await request("POST", "/v1.0/devices/\(id)/commands", body: OrderedJSON.commands(commands))
    }

    func mqttConfig(linkID: String, version: String) async throws -> JSONValue {
        try await request("POST", "/v1.0/iot-03/open-hub/access-config", body: OrderedJSON.object([
            ("uid", .string(token?.uid ?? "")), ("link_id", .string(linkID)), ("link_type", .string("mqtt")), ("topics", .string("device")),
            ("msg_encrypted_version", .string(version)),
        ]))
    }

    func streamURL(_ id: String) async throws -> String {
        guard let url = try await request("POST", "/v1.0/devices/\(id)/stream/actions/allocate", body: OrderedJSON.object([("type", .string("rtsp"))]))["url"]?
            .stringValue, !url.isEmpty else { throw TuyaAPIError(code: 0, message: "no stream URL in the answer") }
        return url
    }

    func operateLock(_ id: String, open: Bool) async throws {
        let ticket = TuyaDevice.text(try await request("POST", "/v1.0/smart-lock/devices/\(id)/password-ticket")["ticket_id"])
        guard !ticket.isEmpty else { throw TuyaAPIError(code: 0, message: "no ticket in the answer") }
        _ = try await request("POST", "/v1.0/smart-lock/devices/\(id)/password-free/door-operate", body: OrderedJSON.object([
            ("device_id", .string(id)), ("ticket_id", .string(ticket)), ("open", .bool(open)),
        ]))
    }

    // MARK: IR

    func remotes(hub: String) async throws -> [JSONValue] {
        try await request("GET", "/v2.0/infrareds/\(hub)/remotes").arrayValue ?? []
    }

    func remoteKeys(hub: String, remote: String) async throws -> JSONValue {
        try await request("GET", "/v2.0/infrareds/\(hub)/remotes/\(remote)/keys")
    }

    func airConditionerStatus(hub: String, remote: String) async throws -> JSONValue {
        try await request("GET", "/v2.0/infrareds/\(hub)/remotes/\(remote)/ac/status")
    }

    func learnedCodes(hub: String, remote: String) async throws -> [JSONValue] {
        try await request("GET", "/v2.0/infrareds/\(hub)/remotes/\(remote)/learning-codes").arrayValue ?? []
    }

    func pressKey(hub: String, remote: String, categoryID: Int, remoteIndex: Int, key: String, keyID: Int) async throws {
        _ = try await request("POST", "/v2.0/infrareds/\(hub)/remotes/\(remote)/raw/command", body: OrderedJSON.object([
            ("category_id", .number(Double(categoryID))), ("remote_index", .number(Double(remoteIndex))), ("key", .string(key)),
            ("key_id", .number(Double(keyID))),
        ]))
    }

    func pressLearnedKey(hub: String, remote: String, code: String) async throws {
        _ = try await request("POST", "/v2.0/infrareds/\(hub)/remotes/\(remote)/learning-codes", body: OrderedJSON.object([("code", .string(code))]))
    }

    func airConditionerCommand(hub: String, remote: String, power: Int, mode: Int, temp: Int, wind: Int) async throws {
        let body = power == 1
            ? OrderedJSON.object([("power", .number(1)), ("mode", .number(Double(mode))), ("temp", .number(Double(temp))), ("wind", .number(Double(wind)))])
            : OrderedJSON.object([("power", .number(0))])
        _ = try await request("POST", "/v2.0/infrareds/\(hub)/air-conditioners/\(remote)/scenes/command", body: body)
    }
}

extension HTTPClientError {
    /// A failure worth another try: the network, not the request.
    var isRetryable: Bool {
        switch self {
        case .cannotConnect, .timeout, .connectionClosed: true
        default: false
        }
    }
}
