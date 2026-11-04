import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// The device ids Gigya remembers this bridge by (3.3): with them a password sign-in skips the e-mailed code while the
/// device is remembered. Secrets: never logged.
struct GigyaDeviceIDs: Codable, Sendable, Equatable {
    var gmid: String
    var ucid: String

    var cookie: String { "gmid=\(gmid); ucid=\(ucid)" }
}

/// One address the 2FA code can go to.
struct GigyaEmail: Sendable, Equatable {
    var id: String
    /// `e***@example.com`.
    var obfuscated: String
}

/// SAP's Gigya, Renault's sign-in (docs/clean-room/Renault.md, 3.2 and 3.3). Bodies are never logged: they hold the
/// password and the tokens.
struct GigyaClient: Sendable {
    let http: any HTTPSending
    let servers: RenaultServers
    let timeout: Duration

    /// `accounts.login`: the login token, or `needsTwoFactor` with its registration token.
    func login(email: String, password: String, deviceIDs: GigyaDeviceIDs?) async throws -> String {
        let json = try await post("accounts.login", ["ApiKey": servers.gigyaKey, "loginID": email, "password": password], cookie: deviceIDs?.cookie)
        guard let token = json["sessionInfo"]?["cookieValue"]?.stringValue, !token.isEmpty else { throw RenaultError.missing("login token") }
        return token
    }

    /// `accounts.getAccountInfo`: the person id.
    func personID(loginToken: String) async throws -> String {
        let json = try await post("accounts.getAccountInfo", ["ApiKey": servers.gigyaKey, "login_token": loginToken])
        guard let person = json["data"]?["personId"]?.stringValue, !person.isEmpty else { throw RenaultError.missing("person id") }
        return person
    }

    /// `accounts.getJWT`: a JWT for Kamereon, about 15 minutes. A dead login token is `loginTokenExpired`.
    func jwt(loginToken: String) async throws -> String {
        do {
            let json = try await post("accounts.getJWT", [
                "ApiKey": servers.gigyaKey, "login_token": loginToken, "fields": "data.personId,data.gigyaDataCenter", "expiration": "900",
            ])
            guard let token = json["id_token"]?.stringValue, !token.isEmpty else { throw RenaultError.missing("JWT") }
            return token
        } catch RenaultError.gigya(let code, _) where code == 403005 || code == 403013 {
            throw RenaultError.loginTokenExpired
        }
    }

    // MARK: Two-factor (3.3)

    /// `accounts.webSdkBootstrap`: the device ids, from this response's own `Set-Cookie` headers.
    func bootstrapDeviceIDs() async throws -> GigyaDeviceIDs {
        let response = try await http.send(request("GET", "accounts.webSdkBootstrap", query: [("APIKey", servers.gigyaKey)], cookie: nil))
        var cookies: [String: String] = [:]
        for header in response.headers where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            guard let pair = header.value.split(separator: ";").first else { continue }
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            cookies[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let gmid = cookies["gmid"], !gmid.isEmpty, let ucid = cookies["ucid"], !ucid.isEmpty else { throw RenaultError.missing("device ids") }
        return GigyaDeviceIDs(gmid: gmid, ucid: ucid)
    }

    func initTFA(regToken: String, deviceIDs: GigyaDeviceIDs) async throws -> String {
        let json = try await get("accounts.tfa.initTFA", [
            ("APIKey", servers.gigyaKey), ("regToken", regToken), ("provider", "gigyaEmail"), ("mode", "verify"),
            ("gmid", deviceIDs.gmid), ("ucid", deviceIDs.ucid),
        ], deviceIDs: deviceIDs)
        guard let assertion = json["gigyaAssertion"]?.stringValue, !assertion.isEmpty else { throw RenaultError.missing("assertion") }
        return assertion
    }

    func emails(assertion: String, deviceIDs: GigyaDeviceIDs) async throws -> [GigyaEmail] {
        let json = try await get("accounts.tfa.email.getEmails", [("APIKey", servers.gigyaKey), ("gigyaAssertion", assertion)], deviceIDs: deviceIDs)
        return (json["emails"]?.arrayValue ?? []).prefix(20).compactMap { entry in
            guard let id = entry["id"]?.stringValue, !id.isEmpty else { return nil }
            return GigyaEmail(id: id, obfuscated: entry["obfuscated"]?.stringValue ?? "your e-mail")
        }
    }

    /// Sends the code; answers the token the verification needs.
    func sendCode(assertion: String, emailID: String, deviceIDs: GigyaDeviceIDs) async throws -> String {
        var query = [("APIKey", servers.gigyaKey), ("gigyaAssertion", assertion), ("emailID", emailID)]
        if let language = servers.language { query.append(("lang", language)) }
        let json = try await get("accounts.tfa.email.sendVerificationCode", query, deviceIDs: deviceIDs)
        guard let token = json["phvToken"]?.stringValue, !token.isEmpty else { throw RenaultError.missing("verification token") }
        return token
    }

    /// Checks the code; a wrong one is `wrongCode` and the challenge stays as it was.
    func verify(code: String, assertion: String, phvToken: String, deviceIDs: GigyaDeviceIDs) async throws -> String {
        do {
            let json = try await get("accounts.tfa.email.completeVerification", [
                ("APIKey", servers.gigyaKey), ("gigyaAssertion", assertion), ("phvToken", phvToken), ("code", code),
            ], deviceIDs: deviceIDs)
            guard let assertion = json["providerAssertion"]?.stringValue, !assertion.isEmpty else { throw RenaultError.missing("provider assertion") }
            return assertion
        } catch RenaultError.gigya(let code, _) where code == 400006 {
            throw RenaultError.wrongCode
        }
    }

    /// Ends the challenge; `remember` (the default) keeps the device remembered for about 30 days.
    func finalize(assertion: String, providerAssertion: String, regToken: String, remember: Bool = true, deviceIDs: GigyaDeviceIDs) async throws {
        _ = try await get("accounts.tfa.finalizeTFA", [
            ("APIKey", servers.gigyaKey), ("gigyaAssertion", assertion), ("providerAssertion", providerAssertion), ("regToken", regToken),
            ("tempDevice", remember ? "false" : "true"),
        ], deviceIDs: deviceIDs)
    }

    // MARK: Requests

    private func request(_ method: String, _ name: String, query: [(String, String)] = [], form: [(String, String)]? = nil, cookie: String?) -> HTTPRequest {
        var address = "\(servers.gigyaRoot)/\(name)"
        if !query.isEmpty { address += "?" + URLEncoding.query(query) }
        var request = HTTPRequest(method: method, url: URL(string: address) ?? URL(string: servers.gigyaRoot)!, timeout: timeout)
        if let form {
            request.setHeader("Content-Type", "application/x-www-form-urlencoded")
            request.body = Data(URLEncoding.form(form).utf8)
        }
        if let cookie { request.setHeader("Cookie", cookie) }
        return request
    }

    private func post(_ name: String, _ fields: KeyValuePairs<String, String>, cookie: String? = nil) async throws -> JSONValue {
        try Self.check(try await http.send(request("POST", name, form: fields.map { ($0.key, $0.value) }, cookie: cookie)))
    }

    private func get(_ name: String, _ query: [(String, String)], deviceIDs: GigyaDeviceIDs) async throws -> JSONValue {
        try Self.check(try await http.send(request("GET", name, query: query, cookie: deviceIDs.cookie)))
    }

    /// The body first, `errorCode` before the HTTP status (Gigya answers its errors with 4xx and a JSON body).
    static func check(_ response: HTTPResponse) throws -> JSONValue {
        guard let json = try? JSONValue(data: response.body), json.objectValue != nil else {
            throw RenaultError.gigya(code: -1, details: "HTTP \(response.status), not JSON")
        }
        let code = json["errorCode"]?.intValue ?? 0
        switch code {
        case 0:
            guard response.isSuccess else { throw RenaultError.http(status: response.status) }
            return json
        case 403042:
            throw RenaultError.invalidCredentials
        case 403101:
            guard let token = json["regToken"]?.stringValue, !token.isEmpty else { throw RenaultError.missing("registration token") }
            throw RenaultError.needsTwoFactor(regToken: token)
        default:
            let details = json["errorDetails"]?.stringValue ?? json["errorMessage"]?.stringValue ?? ""
            throw RenaultError.gigya(code: code, details: String(details.prefix(120)))
        }
    }
}

/// A JWT's expiry (3.4): its payload's `exp`, read without checking the signature.
enum JWT {
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let payload = try? JSONValue(data: data), let exp = payload["exp"]?.doubleValue?.finite else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Expired 60 s before `exp`, for clock skew; a token without one lives the 15 minutes asked for, from `issued`.
    static func isExpired(_ token: String, issued: Date, now: Date) -> Bool {
        let expiry = expiry(of: token) ?? issued.addingTimeInterval(900)
        return now >= expiry.addingTimeInterval(-60)
    }
}
