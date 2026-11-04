import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// The SwitchBot OpenAPI v1.1 (https://github.com/OpenWonderLabs/SwitchBotAPI): every request signed with the account's
/// token and secret, every answer `{"statusCode", "message", "body"}`.
enum OpenAPI {
    static let defaultBase = URL(string: "https://api.switch-bot.com")!

    /// The `sign` header: base64 of HMAC-SHA256 keyed by the secret over token ∥ t ∥ nonce, as the documentation's
    /// examples send it (not upper-cased).
    static func sign(token: String, secret: String, time: String, nonce: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data((token + time + nonce).utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(code).base64EncodedString()
    }

    /// The headers of a request made at `time` (milliseconds since 1970) with `nonce`.
    static func headers(token: String, secret: String, time: String, nonce: String) -> [(name: String, value: String)] {
        [
            ("Authorization", token), ("t", time), ("nonce", nonce),
            ("sign", sign(token: token, secret: secret, time: time, nonce: nonce)), ("Content-Type", "application/json"),
        ]
    }

    /// An answer of the API: its code (100 is success), message and body, and the HTTP status it came with.
    struct Response: Sendable, Equatable {
        var httpStatus: Int
        var statusCode: Int
        var message: String
        var body: JSONValue

        /// Code 100, or HTTP 200 without a code.
        var succeeded: Bool { statusCode == 100 || (statusCode == 0 && httpStatus == 200) }

        /// What went wrong, in the words of the API's table of codes.
        var failure: String {
            switch (httpStatus, statusCode) {
            case (401, _): "unauthorized: the token or secret is wrong, or the account used its 10,000 requests of the day"
            case (_, 151): "the device type does not support this command (151)"
            case (_, 152): "the device was not found (152)"
            case (_, 160): "the command is not supported (160)"
            case (_, 161): "the device is offline (161)"
            case (_, 171): "the hub is offline (171)"
            case (_, 190): "the device reported an internal error (190): \(message)"
            case (let http, 0): "HTTP \(http)"
            default: "code \(statusCode): \(message)"
            }
        }
    }

    /// A request that threw on every attempt (no answer, or one that is not JSON).
    struct Unreachable: Error, CustomStringConvertible {
        var reason: String
        var description: String { "SwitchBot's cloud did not answer: \(reason)" }
    }

    /// The account's keys are missing.
    struct NoCredentials: Error, CustomStringConvertible {
        var description: String { "no OpenAPI token and secret: run Setup with the token and secret from the SwitchBot app" }
    }
}

/// What the plugin sends to a device.
struct Command: Sendable, Equatable, CustomStringConvertible {
    var command: String
    var parameter: String = "default"
    var commandType: String = "command"

    var json: JSONValue { ["command": .string(command), "parameter": .string(parameter), "commandType": .string(commandType)] }
    var description: String { parameter == "default" ? command : "\(command) \(parameter)" }
}

/// The OpenAPI client of one account. Each request is counted in `budget`; one that throws is tried again up to
/// `attempts` times, `retryDelay` apart (an answer with a code other than 100 is not).
final class OpenAPIClient: Sendable {
    struct Settings: Sendable {
        var base = OpenAPI.defaultBase
        var attempts = 2
        var retryDelay: Duration = .seconds(3)
        var timeout: Duration = .seconds(10)
    }

    let token: String
    let secret: String
    let settings: Settings
    let http: any HTTPSending
    let budget: RequestBudget
    let now: @Sendable () -> Date

    init(token: String, secret: String, settings: Settings, http: any HTTPSending, budget: RequestBudget, now: @escaping @Sendable () -> Date = Date.init) {
        self.token = token
        self.secret = secret
        self.settings = settings
        self.http = http
        self.budget = budget
        self.now = now
    }

    /// The device list: physical devices and IR remotes.
    func deviceList(attempts: Int? = nil, retryDelay: Duration? = nil) async throws -> DeviceList {
        let response = try await send("GET", "/v1.1/devices", attempts: attempts, retryDelay: retryDelay)
        guard response.succeeded else { throw ListFailed(response: response) }
        return DeviceList(response.body)
    }

    struct ListFailed: Error, CustomStringConvertible {
        var response: OpenAPI.Response
        var description: String { "SwitchBot refused the device list: \(response.failure)" }
    }

    func status(_ deviceID: String) async throws -> OpenAPI.Response {
        try await send("GET", "/v1.1/devices/\(Self.escape(deviceID))/status")
    }

    func send(_ command: Command, to deviceID: String) async throws -> OpenAPI.Response {
        try await send("POST", "/v1.1/devices/\(Self.escape(deviceID))/commands", body: command.json)
    }

    func webhook(_ action: String, _ body: JSONValue, attempts: Int? = nil, retryDelay: Duration? = nil) async throws -> OpenAPI.Response {
        try await send("POST", "/v1.1/webhook/\(action)", body: body, attempts: attempts, retryDelay: retryDelay)
    }

    static func escape(_ id: String) -> String { URLEncoding.rfc3986(id) }

    func send(_ method: String, _ path: String, body: JSONValue? = nil, attempts: Int? = nil, retryDelay: Duration? = nil) async throws -> OpenAPI.Response {
        guard !token.isEmpty, !secret.isEmpty else { throw OpenAPI.NoCredentials() }
        guard let url = URL(string: path, relativeTo: settings.base)?.absoluteURL else { throw OpenAPI.Unreachable(reason: "invalid hostname") }
        let attempts = max(1, attempts ?? settings.attempts)
        var lastError: any Error = OpenAPI.Unreachable(reason: "no attempt")
        for attempt in 1...attempts {
            try Task.checkCancellation()
            let time = String(Int64((now().timeIntervalSince1970 * 1000).rounded(.down)))
            let nonce = UUID().uuidString.lowercased()
            let request = HTTPRequest(
                method: method, url: url, headers: OpenAPI.headers(token: token, secret: secret, time: time, nonce: nonce),
                body: body?.encoded(), timeout: settings.timeout)
            await budget.record()
            do {
                let answer = try await http.send(request)
                return try Self.parse(answer)
            } catch let error as CancellationError {
                throw error
            } catch {
                lastError = error
                if attempt < attempts { try await Task.sleep(for: retryDelay ?? settings.retryDelay) }
            }
        }
        throw OpenAPI.Unreachable(reason: "\(lastError)")
    }

    /// An answer's envelope. A 401 carries `{"message":"Unauthorized"}` only; any other body that is not JSON throws.
    static func parse(_ answer: HTTPResponse) throws -> OpenAPI.Response {
        let json = answer.body.isEmpty ? JSONValue.object([:]) : try JSONValue(data: answer.body)
        return OpenAPI.Response(
            httpStatus: answer.status, statusCode: json["statusCode"]?.intValue ?? 0, message: json["message"]?.stringValue ?? "",
            body: json["body"] ?? .null)
    }
}

/// The body of `GET /v1.1/devices`.
struct DeviceList: Sendable, Equatable {
    var devices: [[String: JSONValue]]
    var remotes: [[String: JSONValue]]

    init(devices: [[String: JSONValue]] = [], remotes: [[String: JSONValue]] = []) {
        self.devices = devices
        self.remotes = remotes
    }

    init(_ body: JSONValue) {
        devices = body["deviceList"]?.arrayValue?.compactMap(\.objectValue) ?? []
        remotes = body["infraredRemoteList"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }
}
