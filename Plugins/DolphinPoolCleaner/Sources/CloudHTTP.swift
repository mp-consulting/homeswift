import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// An error Cognito answered with: its type (`NotAuthorizedException`) and its message.
struct CognitoError: Error, Equatable, Sendable, CustomStringConvertible {
    var type: String
    var message: String

    var description: String { message.isEmpty ? type : message }
}

/// AWS Cognito's user pool API, as JSON over HTTPS (`X-Amz-Target` names the operation). InitiateAuth and
/// RespondToAuthChallenge are unauthenticated calls: no AWS signature, the app client id is enough.
struct CognitoClient: Sendable {
    var transport: any HTTPSending
    var timeout = Maytronics.requestTimeout

    static let url = URL(string: "https://cognito-idp.\(Maytronics.cognitoRegion).amazonaws.com/")!

    /// `InitiateAuth` with one of the app client's flows: `USER_PASSWORD_AUTH`, `REFRESH_TOKEN_AUTH` or
    /// `CUSTOM_AUTH` (which mails a code).
    func initiateAuth(flow: String, parameters: [String: String]) async throws -> JSONValue {
        try await call("InitiateAuth", [
            "AuthFlow": .string(flow), "ClientId": .string(Maytronics.cognitoClientID), "AuthParameters": .object(parameters.mapValues { .string($0) }),
        ])
    }

    /// `RespondToAuthChallenge`: the answer to a challenge InitiateAuth returned, with its session.
    func respondToAuthChallenge(name: String, session: String, responses: [String: String]) async throws -> JSONValue {
        try await call("RespondToAuthChallenge", [
            "ChallengeName": .string(name), "ClientId": .string(Maytronics.cognitoClientID), "Session": .string(session),
            "ChallengeResponses": .object(responses.mapValues { .string($0) }),
        ])
    }

    /// Calls `AWSCognitoIdentityProviderService.<target>`. Throws `CognitoError` when Cognito names the error
    /// (`__type`, as the AWS SDK reads it), `DolphinError.requestFailed` for an outage.
    func call(_ target: String, _ payload: JSONValue) async throws -> JSONValue {
        var request = HTTPRequest(method: "POST", url: Self.url, body: payload.encoded(), timeout: timeout)
        request.setHeader("Content-Type", "application/x-amz-json-1.1")
        request.setHeader("X-Amz-Target", "AWSCognitoIdentityProviderService.\(target)")
        let response = try await HTTPRedirects.send(request, through: transport)
        if response.status >= 500 {
            throw DolphinError.requestFailed("Cognito service error: HTTP \(response.status)")
        }
        let body = try? JSONValue(data: response.body)
        if let type = body?["__type"]?.stringValue ?? (response.isSuccess ? nil : response.header("x-amzn-ErrorType")) {
            let message = body?["message"]?.stringValue ?? body?["Message"]?.stringValue ?? ""
            throw CognitoError(type: Self.errorName(type), message: message)
        }
        guard response.isSuccess else { throw DolphinError.requestFailed("Cognito \(target) failed: HTTP \(response.status)") }
        guard let body else { throw DolphinError.invalidResponse("Cognito \(target) returned invalid JSON") }
        return body
    }

    /// `com.amazonaws.cognito#NotAuthorizedException` and `NotAuthorizedException:http://…` are both
    /// `NotAuthorizedException`.
    static func errorName(_ type: String) -> String {
        var name = Substring(type)
        if let hash = name.lastIndex(of: "#") { name = name[name.index(after: hash)...] }
        if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
        return String(name)
    }
}

/// The MyDolphin REST backend: form-encoded requests, a JSON envelope (`Status`, `Alert`, `Data`) back.
struct MyDolphinClient: Sendable {
    /// What every endpoint answers. `Status` is `"1"` on success.
    struct Envelope: Sendable, Equatable {
        var status: String?
        var alert: String?
        var data: JSONValue?

        var isSuccess: Bool { status == "1" }

        init(status: String?, alert: String? = nil, data: JSONValue? = nil) {
            self.status = status
            self.alert = alert
            self.data = data
        }

        init(json: JSONValue) {
            switch json["Status"] {
            case .string(let value)?: status = value
            case .number(let value)?: status = value == value.rounded() ? String(Int(saturating: value) ?? 0) : String(value)
            default: status = nil
            }
            alert = json["Alert"]?.stringValue
            data = json["Data"].flatMap { $0.isNull ? nil : $0 }
        }
    }

    var transport: any HTTPSending
    var timeout = Maytronics.requestTimeout

    func get(_ path: String, parameters: [(String, String?)] = [], bearer: String?) async throws -> Envelope {
        try await request("GET", path, parameters: parameters, body: nil, bearer: bearer)
    }

    /// POSTs a form; `nil` sends an empty body.
    func post(_ path: String, form: [(String, String)]?, bearer: String?) async throws -> Envelope {
        let body = URLEncoding.form(form ?? [])
        return try await request("POST", path, parameters: [], body: Data(body.utf8), bearer: bearer)
    }

    private func request(_ method: String, _ path: String, parameters: [(String, String?)], body: Data?, bearer: String?) async throws -> Envelope {
        let query = URLEncoding.form(parameters.compactMap { name, value in value.map { (name, $0) } })
        guard let url = URL(string: path + (query.isEmpty ? "" : "?\(query)"), relativeTo: Maytronics.baseURL)?.absoluteURL else {
            throw DolphinError.requestFailed("\(method) \(path): bad URL")
        }
        var request = HTTPRequest(method: method, url: url, body: body, timeout: timeout)
        request.setHeader("Content-Type", "application/x-www-form-urlencoded")
        request.setHeader("AppKey", Maytronics.appKey)
        request.setHeader("Accept", "*/*")
        request.setHeader("User-Agent", Maytronics.userAgent)
        if let bearer { request.setHeader("Authorization", "Bearer \(bearer)") }

        let response: HTTPResponse
        do {
            response = try await HTTPRedirects.send(request, through: transport)
        } catch {
            throw DolphinError.requestFailed("\(method) \(path) failed: \(error)")
        }
        guard response.isSuccess else {
            throw MyDolphinHTTPError(method: method, path: path, status: response.status, body: response.body)
        }
        guard let json = try? JSONValue(data: response.body) else {
            throw DolphinError.invalidResponse("\(method) \(path) returned invalid JSON")
        }
        return Envelope(json: json)
    }
}

/// The backend answered with an HTTP error.
struct MyDolphinHTTPError: Error, Sendable, CustomStringConvertible {
    var method: String
    var path: String
    var status: Int
    var body: Data

    var description: String { "\(method) \(path) failed: HTTP \(status)" }
}

/// Redirects followed the way the Homebridge plugin's `fetch` follows them (`redirect: "follow"`): MyDolphin
/// answers `POST /mobapi/user/authenticate-user/` with a 307 at times, and `HTTPClient` returns redirects as
/// they are.
enum HTTPRedirects {
    /// `fetch` gives up after 20.
    static let limit = 20
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    /// The headers that describe a body, dropped with it.
    static let bodyHeaders = ["Content-Type", "Content-Length", "Content-Encoding", "Content-Language", "Content-Location"]

    /// Sends `request` through `transport`, following redirects: 307 and 308 keep the method and the body;
    /// 301 and 302 turn a POST into a GET without a body, 303 anything but a GET or HEAD; `Authorization`
    /// does not follow a redirect to another origin. A redirect without a usable `Location` is the answer.
    static func send(_ request: HTTPRequest, through transport: any HTTPSending) async throws -> HTTPResponse {
        var request = request
        var response = try await transport.send(request)
        var redirects = 0
        while statuses.contains(response.status), let next = redirected(request, by: response) {
            redirects += 1
            guard redirects <= limit else { throw DolphinError.requestFailed("\(request.method) \(request.url.path): too many redirects") }
            request = next
            response = try await transport.send(request)
        }
        return response
    }

    /// The request a redirect asks for, nil when its `Location` is missing or not an HTTP(S) URL, or would take
    /// an HTTPS request to plain HTTP: a 307 keeps the body, which carries the password or refresh token.
    static func redirected(_ request: HTTPRequest, by response: HTTPResponse) -> HTTPRequest? {
        guard let location = response.header("Location"), let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
            let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http", target.host != nil,
            scheme == "https" || request.url.scheme?.lowercased() != "https"
        else { return nil }
        var next = request
        next.url = target
        let method = request.method.uppercased()
        if (response.status == 303 && method != "GET" && method != "HEAD") || ((response.status == 301 || response.status == 302) && method == "POST") {
            next.method = "GET"
            next.body = nil
            next.headers.removeAll { header in bodyHeaders.contains { $0.caseInsensitiveCompare(header.name) == .orderedSame } }
        }
        if origin(of: target) != origin(of: request.url) {
            next.headers.removeAll { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }
        }
        return next
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}
