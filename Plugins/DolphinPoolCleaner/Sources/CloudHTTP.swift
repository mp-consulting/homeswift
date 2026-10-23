import Foundation
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
        let response = try await transport.send(request)
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
            case .number(let value)?: status = value == value.rounded() ? String(Int(value)) : String(value)
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
            response = try await transport.send(request)
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
