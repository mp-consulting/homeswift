import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// What a call to Google answered when it did not work: the HTTP status and Google's message only, never the request
/// (its Authorization header) or a token.
enum NestError: Error, CustomStringConvertible, Equatable, Sendable {
    /// HTTP status and Google's message, at most 300 characters.
    case http(status: Int, message: String)
    /// 429 or RESOURCE_EXHAUSTED: a quota of Google's.
    case rateLimited(String)
    /// The refresh token was refused (`invalid_grant`) or the client (`invalid_client`): Setup has to run again.
    case unauthorized(String)
    case invalidResponse(String)
    /// The account is not set up: the keys missing.
    case notConfigured([String])

    var description: String {
        switch self {
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .rateLimited(let message): "rate limited: \(message)"
        case .unauthorized(let message): "Google refused the authorization (\(message)): run Setup again"
        case .invalidResponse(let message): message
        case .notConfigured(let keys): "missing \(keys.joined(separator: ", "))"
        }
    }

    var isRateLimit: Bool { if case .rateLimited = self { true } else { false } }

    /// Google's error of a response: `{"error": {"code", "message", "status"}}` for its APIs, `{"error": "invalid_grant",
    /// "error_description"}` for OAuth. A limit is a 429, or "rate limit" or RESOURCE_EXHAUSTED in the message.
    static func from(_ response: HTTPResponse) -> NestError {
        let body = try? JSONValue(data: response.body)
        var message = body?["error"]?["message"]?.stringValue ?? body?["error_description"]?.stringValue ?? body?["error"]?.stringValue
            ?? String(decoding: response.body.prefix(300), as: UTF8.self)
        if message.count > 300 { message = String(message.prefix(300)) }
        let status = body?["error"]?["status"]?.stringValue ?? ""
        let lowered = (message + " " + status).lowercased()
        if response.status == 429 || lowered.contains("rate limit") || lowered.contains("resource_exhausted") { return .rateLimited(message) }
        if let oauth = body?["error"]?.stringValue, oauth == "invalid_grant" || oauth == "invalid_client" { return .unauthorized(oauth) }
        return .http(status: response.status, message: message)
    }
}

/// The OAuth client of the user's Google Cloud project, and the Device Access project it is linked to.
struct NestAccount: Sendable, Equatable {
    var clientID: String
    var clientSecret: String
    var projectID: String
    var refreshToken: String
    /// `projects/<gcp-project>/subscriptions/<id>`.
    var subscriptionID: String
}

/// Google's OAuth endpoints (section 2): the Partner Connections Manager's consent page, the code exchange and the
/// refresh-token grant.
enum GoogleOAuth {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let redirectURI = "https://www.google.com"
    /// `sdm.service` and `pubsub`: the plugin reads the subscription with the user's own credentials.
    static let scopes = "https://www.googleapis.com/auth/sdm.service+https://www.googleapis.com/auth/pubsub"

    /// The Partner Connections Manager page where the person picks the homes and devices to share (section 2.2).
    static func authorizationURL(projectID: String, clientID: String) -> String {
        "https://nestservices.google.com/partnerconnections/\(URLEncoding.uriComponent(projectID))/auth?redirect_uri=\(redirectURI)"
            + "&access_type=offline&prompt=consent&client_id=\(URLEncoding.uriComponent(clientID))&response_type=code&scope=\(scopes)"
    }

    /// The `code` of the address Google redirected to (`https://www.google.com?code=…&scope=…`), or the code pasted alone.
    static func code(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains("code=") else { return trimmed.contains("://") ? nil : trimmed }
        let query = trimmed.split(separator: "?", maxSplits: 1).last.map(String.init) ?? trimmed
        return URLEncoding.fields(query.split(separator: "#").first.map(String.init) ?? query)["code"].nonEmptyText
    }

    struct Tokens: Sendable, Equatable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?
    }

    static func exchange(code: String, clientID: String, clientSecret: String, transport: any HTTPSending) async throws -> Tokens {
        try await post([
            ("client_id", clientID), ("client_secret", clientSecret), ("code", code), ("grant_type", "authorization_code"), ("redirect_uri", redirectURI),
        ], transport: transport)
    }

    static func refresh(_ refreshToken: String, clientID: String, clientSecret: String, transport: any HTTPSending) async throws -> Tokens {
        try await post([("grant_type", "refresh_token"), ("client_id", clientID), ("client_secret", clientSecret), ("refresh_token", refreshToken)],
                       transport: transport)
    }

    private static func post(_ fields: [(String, String)], transport: any HTTPSending) async throws -> Tokens {
        var request = HTTPRequest(method: "POST", url: tokenURL, body: Data(URLEncoding.form(fields).utf8), timeout: .seconds(20))
        request.setHeader("Content-Type", "application/x-www-form-urlencoded")
        let response = try await transport.send(request)
        guard response.isSuccess else { throw NestError.from(response) }
        guard let body = try? JSONValue(data: response.body), let token = body["access_token"]?.stringValue else {
            throw NestError.invalidResponse("Google's token endpoint answered without an access token")
        }
        return Tokens(accessToken: token, expiresIn: body["expires_in"]?.intValue ?? 3600, refreshToken: body["refresh_token"]?.stringValue.nonEmptyText)
    }
}

/// The access token the SDM and Pub/Sub calls share, refreshed about five minutes before it expires, or when a call finds
/// it refused. Callers waiting at the same time share one refresh.
actor AccessTokens {
    private let account: NestAccount
    private let transport: any HTTPSending
    private let now: @Sendable () -> Date
    /// Google sent a new refresh token: it replaces the stored one.
    private let rotated: @Sendable (String) -> Void
    private var refreshToken: String
    private var current: (token: String, expires: Date)?
    private var refreshing: Task<String, any Error>?

    init(account: NestAccount, transport: any HTTPSending, now: @escaping @Sendable () -> Date = { Date() }, rotated: @escaping @Sendable (String) -> Void) {
        self.account = account
        self.transport = transport
        self.now = now
        self.rotated = rotated
        refreshToken = account.refreshToken
    }

    func token() async throws -> String {
        if let current, current.expires.timeIntervalSince(now()) > 300 { return current.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { [account, transport, refreshToken] in
            defer { self.refreshing = nil }
            let tokens = try await GoogleOAuth.refresh(refreshToken, clientID: account.clientID, clientSecret: account.clientSecret, transport: transport)
            self.store(tokens)
            return tokens.accessToken
        }
        refreshing = task
        return try await task.value
    }

    private func store(_ tokens: GoogleOAuth.Tokens) {
        current = (tokens.accessToken, now().addingTimeInterval(TimeInterval(tokens.expiresIn)))
        if let next = tokens.refreshToken, next != refreshToken {
            refreshToken = next
            rotated(next)
        }
    }

    /// A call was refused with this token: the next asks Google again.
    func invalidate() { current = nil }
}

/// A Bearer call to one of Google's JSON APIs: a 401 refreshes the token once, an error becomes a `NestError`.
struct GoogleCaller: Sendable {
    let transport: any HTTPSending
    let tokens: AccessTokens

    func call(_ method: String, _ url: URL, body: JSONValue? = nil, timeout: Duration = .seconds(20)) async throws -> JSONValue {
        for attempt in 0..<2 {
            var request = HTTPRequest(method: method, url: url, body: body?.encoded(), timeout: timeout)
            request.setHeader("Authorization", "Bearer \(try await tokens.token())")
            if body != nil { request.setHeader("Content-Type", "application/json") }
            let response = try await transport.send(request)
            if response.status == 401, attempt == 0 {
                await tokens.invalidate()
                continue
            }
            guard response.isSuccess else { throw NestError.from(response) }
            if response.body.isEmpty { return .object([:]) }
            guard let json = try? JSONValue(data: response.body) else { throw NestError.invalidResponse("Google answered with invalid JSON") }
            return json
        }
        throw NestError.http(status: 401, message: "Unauthorized")
    }

    /// The bytes at `url` with this Authorization header (an event image's `Basic <token>`, a clip preview's Bearer).
    func download(_ url: URL, authorization: String?) async throws -> Data {
        var request = HTTPRequest(url: url, timeout: .seconds(20))
        if let authorization {
            request.setHeader("Authorization", authorization)
        } else {
            request.setHeader("Authorization", "Bearer \(try await tokens.token())")
        }
        let response = try await transport.send(request)
        guard response.isSuccess else { throw NestError.from(response) }
        return response.body
    }
}

/// The Smart Device Management API (section 3).
struct SDMClient: Sendable {
    static let base = "https://smartdevicemanagement.googleapis.com/v1/"
    let caller: GoogleCaller
    let projectID: String

    /// The devices the person shared, first page only, as the Homebridge plugin reads it.
    func listDevices() async throws -> [SDMDevice] {
        let json = try await caller.call("GET", URL(string: Self.base + "enterprises/\(projectID)/devices")!)
        return (json["devices"]?.arrayValue ?? []).compactMap(SDMDevice.init(json:))
    }

    func device(_ name: String) async throws -> SDMDevice {
        let json = try await caller.call("GET", URL(string: Self.base + name)!)
        guard let device = SDMDevice(json: json) else { throw NestError.invalidResponse("Google answered without the device") }
        return device
    }

    /// `executeCommand`: its `results`.
    func execute(_ device: String, _ command: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let body: JSONValue = ["command": .string("sdm.devices.commands.\(command)"), "params": .object(params)]
        let json = try await caller.call("POST", URL(string: Self.base + device + ":executeCommand")!, body: body)
        return json["results"] ?? .object([:])
    }
}

/// One Pub/Sub message as pull gives it.
struct PubSubMessage: Sendable, Equatable {
    var ackID: String
    var data: Data
}

/// A Cloud Pub/Sub pull subscription over REST (section 4.1): pull, then acknowledge.
struct PubSubClient: Sendable {
    let caller: GoogleCaller
    let subscription: String

    /// Waits for messages (Google holds a pull with nothing to give for a while, then answers `{}`).
    func pull(maxMessages: Int = 50) async throws -> [PubSubMessage] {
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(subscription):pull")!
        let json = try await caller.call("POST", url, body: ["maxMessages": .number(Double(maxMessages))], timeout: .seconds(90))
        return (json["receivedMessages"]?.arrayValue ?? []).compactMap { item in
            guard let ackID = item["ackId"]?.stringValue else { return nil }
            let data = item["message"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
            return PubSubMessage(ackID: ackID, data: data)
        }
    }

    func acknowledge(_ ackIDs: [String]) async throws {
        guard !ackIDs.isEmpty else { return }
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(subscription):acknowledge")!
        _ = try await caller.call("POST", url, body: ["ackIds": .array(ackIDs.map { .string($0) })])
    }
}
