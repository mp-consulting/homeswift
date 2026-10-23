import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Errors of the Govee cloud.
enum GoveeAPIError: Error, CustomStringConvertible, Equatable {
    /// Govee wants a one-time code it has just emailed (its "new device" challenge, status 454).
    case twoFactorRequired(String)
    /// A code was given and Govee refused it. No new code was requested.
    case twoFactorInvalid(String)
    /// The account token was refused (HTTP 401 or 403, or no device list).
    case unauthorized(Int)
    case httpStatus(Int, String?)
    case message(String)
    /// The network failed; worth retrying.
    case unreachable(String)

    var description: String {
        switch self {
        case .twoFactorRequired(let message), .twoFactorInvalid(let message), .message(let message): message
        case .unauthorized(let status): "Request failed with status code \(status)"
        case .httpStatus(let status, let message): message.map { "\($0) (HTTP \(status))" } ?? "Request failed with status code \(status)"
        case .unreachable(let reason): reason
        }
    }

    /// Whether the account token was rejected, rather than the network failing.
    var isAuthFailure: Bool {
        switch self {
        case .unauthorized: true
        case .message(let message): message == Lang.noDevices
        default: false
        }
    }
}

/// The Govee app's account API on `app2.govee.com` (`utils/govee-api.ts`, `connection/http.ts`): login with
/// the new-device challenge, the AWS IoT certificate, the device list, leak alerts. The requests carry the
/// app's headers and a client id derived from the account, stable across launches, so Govee's email
/// verification is needed once.
struct GoveeAPI: Sendable {
    static let appVersion = "7.4.10"
    static let userAgent = "GoveeHome/\(appVersion) (com.ihoment.GoVeeSensor; build:8; iOS 26.5.0) Alamofire/5.11.0"
    static let loginURL = "https://app2.govee.com/account/rest/account/v2/login"
    static let verificationURL = "https://app2.govee.com/account/rest/account/v1/verification"
    static let logoutURL = "https://app2.govee.com/account/rest/account/v1/logout"
    static let devicesURL = "https://app2.govee.com/device/rest/devices/v1/list"
    static let iotKeyURL = "https://app2.govee.com/app/v1/account/iot/key"
    static let leakWarningURL = "https://app2.govee.com/leak/rest/device/v1/warnMessage"
    static let settingsCodeRequired = "Govee needs to verify this login. A verification code has been emailed to your Govee account address. "
        + "Enter that code in the \"Verification Code\" field and test the connection again."
    static let settingsCodeInvalid = "The Govee verification code was not accepted. Please double-check the code from your email, "
        + "or clear the code field and test again to have a new one sent."
    /// The status Govee answers a login from a client it has not seen with.
    static let statusNewDevice = 454
    /// The `type` the app sends when it asks for a login verification code.
    static let verificationTypeLogin = 8
    static let maximumBodyPreview = 400

    let transport: any HTTPSending
    /// `hb` and 30 hex digits: for the account API and the AWS IoT client id.
    let clientId: String

    init(transport: any HTTPSending, clientId: String) {
        self.transport = transport
        self.clientId = clientId
    }

    /// The client id the Homebridge plugin's platform used: HAP-NodeJS's `uuid.generate(username)` without its
    /// dashes and last two digits. Keeping it means a login Govee verified there needs no new code here.
    static func clientId(username: String) -> String {
        let uuid = hapUUID(username).replacingOccurrences(of: "-", with: "")
        return "hb" + uuid.dropLast(2)
    }

    /// HAP-NodeJS's `uuid.generate`: SHA-1 of the input laid out as a version 4 UUID.
    static func hapUUID(_ data: String) -> String {
        let sha = Secrets.hex(Insecure.SHA1.hash(data: Data(data.utf8)))
        let digits = Array(sha)
        var index = 0
        var result = ""
        for character in "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" {
            switch character {
            case "x":
                result.append(digits[index])
                index += 1
            case "y":
                let value = (Int(String(digits[index]), radix: 16)! & 0x3) | 0x8
                result.append(String(value, radix: 16))
                index += 1
            default:
                result.append(character)
            }
        }
        return result
    }

    // MARK: Requests

    func headers(token: String?) -> [(String, String)] {
        var headers: [(String, String)] = []
        if let token { headers.append(("Authorization", "Bearer \(token)")) }
        headers += [
            ("appVersion", Self.appVersion), ("clientId", clientId), ("clientType", "1"), ("iotVersion", "0"),
            ("timestamp", String(Int(Date().timeIntervalSince1970 * 1000))), ("User-Agent", Self.userAgent),
        ]
        return headers
    }

    /// A request to the account API: JSON in and out. Throws for statuses other than 2xx, with the server's
    /// `message` when it gives one.
    func request(
        _ method: String, _ url: String, token: String?, query: [(String, String)] = [], body: JSONValue? = nil, timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        let (status, answer) = try await send(method, url, token: token, query: query, body: body, timeout: timeout)
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw GoveeAPIError.unauthorized(status) }
            throw GoveeAPIError.httpStatus(status, answer?["message"]?.stringValue ?? answer?["msg"]?.stringValue)
        }
        return answer ?? .null
    }

    /// The status and parsed body of a request, whatever the status.
    func send(
        _ method: String, _ url: String, token: String?, query: [(String, String)] = [], body: JSONValue? = nil, timeout: Duration = .seconds(30)
    ) async throws -> (Int, JSONValue?) {
        guard var components = URLComponents(string: url) else { throw GoveeAPIError.message("bad URL \(url)") }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let full = components.url else { throw GoveeAPIError.message("bad URL \(url)") }
        var request = HTTPRequest(method: method, url: full, body: body.map { $0.encoded() }, timeout: timeout)
        for (name, value) in headers(token: token) { request.setHeader(name, value) }
        if body != nil { request.setHeader("Content-Type", "application/json") }
        request.setHeader("Accept", "application/json")
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPClientError {
            throw GoveeAPIError.unreachable(error.description)
        }
        return (response.status, try? JSONValue(data: response.body))
    }

    // MARK: Account

    /// What a login yields.
    struct Login: Sendable, Equatable {
        var accountId: String
        var token: String
        var topic: String
    }

    /// Who reads the challenge messages: the log, or the settings page (which has a Test Connection button).
    enum Audience: Sendable { case log, settingsPage }

    /// Logs in. A new-device challenge requests the email code and throws `twoFactorRequired`; a refused
    /// code throws `twoFactorInvalid`.
    func login(username: String, password: String, code: String?, audience: Audience = .log) async throws -> Login {
        var body: [String: JSONValue] = ["email": .string(username), "password": .string(password), "client": .string(clientId)]
        if let code, !code.isEmpty { body["code"] = .string(code) }
        let (status, answer) = try await send("POST", Self.loginURL, token: nil, body: .object(body))
        if answer?["status"]?.intValue == Self.statusNewDevice {
            if let code, !code.isEmpty {
                throw GoveeAPIError.twoFactorInvalid(audience == .log ? Lang.twoFACodeInvalid : Self.settingsCodeInvalid)
            }
            try await requestVerificationCode(username: username)
            throw GoveeAPIError.twoFactorRequired(audience == .log ? Lang.twoFARequired : Self.settingsCodeRequired)
        }
        guard let client = answer?["client"], let token = client["token"]?.stringValue, !token.isEmpty else {
            throw Self.loginFailure(status: status, body: answer)
        }
        let accountId = client["accountId"].map { $0.stringValue ?? $0.doubleValue.map(DeviceUpdate.format) ?? "" } ?? ""
        return Login(accountId: accountId, token: token, topic: client["topic"]?.stringValue ?? "")
    }

    /// Asks Govee to email the one-time login code.
    func requestVerificationCode(username: String) async throws {
        _ = try await send("POST", Self.verificationURL, token: nil, body: ["type": .number(Double(Self.verificationTypeLogin)), "email": .string(username)])
    }

    func logout(token: String) async throws {
        _ = try await request("POST", Self.logoutURL, token: token, timeout: .seconds(10))
    }

    /// The AWS IoT certificate of the account (PKCS#12, base64), its password, and the endpoint.
    struct IoTKey: Sendable, Equatable {
        var endpoint: String
        var p12: String
        var p12Password: String
    }

    func iotKey(token: String) async throws -> IoTKey {
        let answer = try await request("GET", Self.iotKeyURL, token: token)
        guard let data = answer["data"], let endpoint = data["endpoint"]?.stringValue else { throw GoveeAPIError.message("no IoT credentials in Govee's answer") }
        return IoTKey(endpoint: endpoint, p12: data["p12"]?.stringValue ?? "", p12Password: data["p12Pass"]?.stringValue ?? "")
    }

    /// The account's devices, as Govee lists them.
    func devices(token: String) async throws -> [JSONValue] {
        let answer = try await request("POST", Self.devicesURL, token: token)
        guard let devices = answer["devices"]?.arrayValue else { throw GoveeAPIError.message(Lang.noDevices) }
        return devices
    }

    /// The alert messages of a leak sensor.
    func leakWarnings(token: String, deviceId: String, sku: String) async throws -> [JSONValue] {
        let body: JSONValue = ["device": .string(deviceId.replacingOccurrences(of: ":", with: "")), "limit": 50, "sku": .string(sku)]
        let answer = try await request("POST", Self.leakWarningURL, token: token, body: body, timeout: .seconds(10))
        guard let data = answer["data"]?.arrayValue else { throw GoveeAPIError.message(Lang.noDevices) }
        return data
    }

    /// A login answer without a token: the server's message when it gave one, otherwise the status and the
    /// body (shortened), which tell whether the account needs attention in the app.
    static func loginFailure(status: Int?, body: JSONValue?) -> GoveeAPIError {
        let message = body?["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? body?["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let message {
            return .message("Govee login failed: \(message)\(status.map { " (HTTP \($0))" } ?? "")")
        }
        var preview = body.map { $0.text() } ?? "(empty body)"
        if preview.count > maximumBodyPreview { preview = String(preview.prefix(maximumBodyPreview)) + "…" }
        return .message(
            "Govee login failed - the server returned \(status.map { "HTTP \($0)" } ?? "a response") without an account token. "
                + "This usually means the account needs attention in the Govee Home app (e.g. an email-verification code or "
                + "accepting updated terms), or the account is served by a region this plugin does not yet support. "
                + "If you only control devices over Bluetooth or LAN, this cloud login is not required and your devices will still work. "
                + "Server response: \(preview)")
    }
}
