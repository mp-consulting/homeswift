import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import _CryptoExtras

/// The account's regional endpoints, from `route.lgthinq.com`.
struct Gateway: Sendable, Equatable {
    var empTermsURI: String
    var empSpxURI: String
    var thinq2URI: String
    var thinq1URI: String
    var countryCode: String
    var languageCode: String

    init(empTermsURI: String, empSpxURI: String, thinq2URI: String, thinq1URI: String, countryCode: String, languageCode: String) {
        self.empTermsURI = empTermsURI
        self.empSpxURI = empSpxURI
        self.thinq2URI = thinq2URI
        self.thinq1URI = thinq1URI
        self.countryCode = countryCode
        self.languageCode = languageCode
    }

    init(_ result: JSONValue) {
        empTermsURI = JS.string(result["empTermsUri"])
        empSpxURI = JS.string(result["empSpxUri"])
        thinq2URI = JS.string(result["thinq2Uri"])
        thinq1URI = JS.string(result["thinq1Uri"])
        countryCode = JS.string(result["countryCode"])
        languageCode = JS.string(result["languageCode"])
    }

    var empBaseURL: String { empTermsURI + "/" }
    var loginBaseURL: String { empSpxURI + "/" }
    var thinq2URL: String { thinq2URI + "/" }
    var thinq1URL: String { thinq1URI + "/" }
}

/// An OAuth session: the access token, the refresh token that outlives it, and when the access token expires
/// (seconds since 1970).
struct Session: Sendable, Equatable {
    var accessToken: String
    let refreshToken: String
    var expiresAt: Double

    static let expiryMargin: Double = 60

    var hasToken: Bool { !accessToken.isEmpty }
    var isTokenExpired: Bool { expiresAt < Self.now() }
    var hasValidToken: Bool { hasToken && !isTokenExpired }

    mutating func newToken(_ accessToken: String, expiresAt: Double) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// An OAuth `expires_in` (seconds from now, number or string) as an absolute expiry, a minute early so the
    /// token is refreshed before LG rejects it. 0 (expired) when it is not a number.
    static func expiry(fromNow expiresIn: JSONValue?) -> Double {
        let seconds = JS.number(expiresIn)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return now() + max(0, seconds - expiryMargin)
    }

    static func now() -> Double { (Date().timeIntervalSince1970).rounded() }
}

/// Signing in to LG: the lgemembers.com account flow (and the legacy EMP flow it replaced, as a fallback), the
/// token exchange and refresh, the user number, the ThinQ v1 session and new terms.
@ThinQActor
final class Auth {
    let gateway: Gateway
    let client: RequestClient
    var logger: Logger
    /// The country's OAuth backend; the token endpoint can move it.
    var lgeapiURL: String

    init(gateway: Gateway, client: RequestClient, logger: Logger) {
        self.gateway = gateway
        self.client = client
        self.logger = logger
        lgeapiURL = "https://\(gateway.countryCode.lowercased()).lgeapi.com/"
    }

    /// Signs in with an LG account. The password travels as its SHA-512 digest.
    func login(username: String, password: String) async throws -> Session {
        let digest = Self.sha512Hex(password)
        do {
            return try await loginNew(username: username, encryptedPassword: digest)
        } catch ThinQError.authentication(let message) {
            throw ThinQError.authentication(message)
        } catch {
            // Only the message: a request error could carry the password digest.
            logger.debug("lgemembers.com sign-in failed, falling back to the legacy EMP flow: \(error)")
            return try await loginStep2(username: username, encryptedPassword: digest)
        }
    }

    /// The lgemembers.com sign-in: the page for a cookie, `signInAct` with the encrypted user id and the
    /// password digest, `signInComplete`, `token`, `oauth` for a code, then the token exchange signed with the
    /// static OAuth secret.
    func loginNew(username: String, encryptedPassword: String) async throws -> Session {
        let country = gateway.countryCode
        let language = gateway.languageCode
        let localLanguage = String(language.split(separator: "-").first ?? "")
        let host = "https://\(country.lowercased()).\(ThinQConstants.accountBaseHost)"
        let headers: [(name: String, value: String)] = [
            ("Accept", "*/*"),
            ("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8"),
            ("X-Requested-With", "XMLHttpRequest"),
            ("Accept-Language", "\(language),\(country.lowercased());q=0.9"),
            ("Origin", host),
            ("User-Agent", ThinQConstants.empUserAgent),
        ]

        // 1. The sign-in page, for a session cookie.
        let signIn = URLEncoding.query([
            ("callback_url", ThinQConstants.accountRedirectURI), ("client_id", ThinQConstants.clientID), ("close_type", "0"),
            ("country", country), ("language", language), ("pre_login", ""), ("redirect_url", ThinQConstants.accountRedirectURI),
            ("state", "signin"), ("svc_code", ThinQConstants.svcCode), ("svc_integrated", "Y"), ("ui_mode", "light"), ("webview_yn", "Y"),
        ])
        let page = try await client.get("\(host)/lgacc/service/v1/signin?\(signIn)", headers: [
            ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
            ("Accept-Language", "\(language),\(country.lowercased());q=0.9"),
            ("User-Agent", ThinQConstants.empUserAgent),
        ])
        let cookie = page.cookies.first ?? ""

        // 2. Authenticate: the user id RSA-encrypted, the password as its digest (LG's page no longer re-hashes it).
        let encryptedUserID = try Self.encryptUserID(username)
        let account = try await client.post("\(host)/lgacc/front/v1/signin/signInAct", form: URLEncoding.query([
            ("clientId", ThinQConstants.clientID), ("doneYn", ""), ("ipadYn", "N"), ("itgTermsUseFlag", "Y"), ("itgUserType", "A"),
            ("local_country", country), ("local_lang", localLanguage), ("skipYn", "N"), ("svcCode", ThinQConstants.svcCode),
            ("svc_code", ThinQConstants.svcCode), ("userId", URLEncoding.uriComponent(encryptedUserID)), ("userPw", encryptedPassword),
        ]), headers: headers + [("Cookie", cookie)]).data
        guard let accountInfo = account["account"], !accountInfo.isNull else {
            let error = account["error"]
            if error?["code"]?.stringValue == "MS.001.03" {
                throw ThinQError.authentication("Your account was already used to registered in \(JS.string(error?["message"])).")
            }
            let message = error?["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? account["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            throw ThinQError.authentication(message ?? "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.")
        }

        // 3. Complete the sign-in, which upgrades the session cookie.
        let loginSessionID = JS.string(accountInfo["loginSessionID"])
        let loginUUID = UUID().uuidString.lowercased()
        let additionalInfo = JSONValue.object([
            "uuid": .string(loginUUID), "user_id": accountInfo["userID"] ?? .null, "user_id_type": accountInfo["userIDType"] ?? .null, "svc_integrated": "Y",
        ])
        let complete = try await client.post("\(host)/lgacc/front/v1/signin/signInComplete", form: URLEncoding.query([
            ("loginSessionID", loginSessionID), ("additionalInfo", URLEncoding.uriComponent(Self.jsonText(additionalInfo, keys: ["uuid", "user_id", "user_id_type", "svc_integrated"]))),
            ("autoYn", "N"), ("deviceId", Self.randomString(32)), ("ipadYn", "N"), ("local_country", country), ("local_lang", localLanguage),
            ("serviceYn", "Y"), ("svcCode", ThinQConstants.svcCode), ("svc_code", ThinQConstants.svcCode), ("uuid", loginUUID),
        ]), headers: headers + [("Cookie", cookie)])
        guard complete.data["code"]?.stringValue == "SUCCESS" else {
            throw ThinQError.token(complete.data["message"]?.stringValue ?? complete.data.text())
        }
        let sessionCookie = complete.cookies.first ?? cookie

        // 4. Mark the session as issued.
        _ = try await client.post("\(host)/lgacc/front/v1/signin/token", form: URLEncoding.query([("loginSessionID", loginSessionID), ("uuid", loginUUID)]),
            headers: headers + [("Cookie", sessionCookie)])

        // 5. Exchange the session for an authorization code.
        let oauth = try await client.post("\(host)/lgacc/front/v1/signin/oauth", form: URLEncoding.query([
            ("loginSessionID", loginSessionID), ("accountType", "LGE"), ("clientId", ThinQConstants.clientID), ("countryCode", country),
            ("local_country", country), ("local_lang", localLanguage), ("redirectUri", ThinQConstants.accountRedirectURI), ("state", "signin"),
            ("svc_code", ThinQConstants.svcCode), ("userName", username),
        ]), headers: headers + [("Cookie", sessionCookie)]).data
        guard let redirect = oauth["redirect_uri"]?.stringValue, !redirect.isEmpty else {
            throw ThinQError.token(oauth["message"]?.stringValue ?? oauth.text())
        }
        let decoded = redirect.removingPercentEncoding ?? redirect
        let query = decoded.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        guard let code = parseQuery(query)["code"], !code.isEmpty else { throw ThinQError.token("LG returned no authorization code.") }

        // 6. Trade the code for tokens.
        return try await requestToken(code: code)
    }

    /// The legacy EMP flow: `preLogin`, the account session, the dynamic secret from `searchKey`, then the
    /// `empsession` authorization. `extra` carries `third_party` for accounts of Google, Apple and others.
    func loginStep2(username: String, encryptedPassword: String, extra: [(String, String)] = []) async throws -> Session {
        var headers = defaultEmpHeaders
        let preLogin = try await client.post(gateway.loginBaseURL + "preLogin", form: URLEncoding.query([
            ("user_auth2", encryptedPassword),
            ("log_param", "login request / user_id : \(username) / third_party : null / svc_list : SVC202,SVC710 / 3rd_service : "),
        ]), headers: headers).data
        headers.append(("X-Signature", JS.string(preLogin["signature"])))
        headers.append(("X-Timestamp", JS.string(preLogin["tStamp"])))

        let data = [("user_auth2", JS.string(preLogin["encrypted_pw"])), ("password_hash_prameter_flag", "Y"), ("svc_list", "SVC202,SVC710")] + extra
        let account: JSONValue
        do {
            account = try await client.post(gateway.empBaseURL + "emp/v2.0/account/session/" + URLEncoding.uriComponent(username),
                form: URLEncoding.query(data), headers: headers).data["account"] ?? .null
        } catch ThinQError.http(let status, let body) {
            guard let error = body["error"], !error.isNull else { throw ThinQError.http(status: status, body: body) }
            if error["code"]?.stringValue == "MS.001.03" {
                throw ThinQError.authentication("Your account was already used to registered in \(JS.string(error["message"])).")
            }
            throw ThinQError.authentication(error["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "LG rejected the sign-in.")
        }
        guard !account.isNull else { throw ThinQError.authentication("LG returned no account for this sign-in.") }

        // The secret for the EMP signature.
        let secretKey = JS.string(try await client.get(gateway.loginBaseURL + "searchKey?key_name=OAUTH_SECRETKEY&sever_type=OP",
            headers: [("User-Agent", ThinQConstants.empUserAgent)]).data["returnData"])

        let timestamp = RFC2822.string()
        let search = URLEncoding.query([
            ("account_type", JS.string(account["userIDType"])), ("client_id", ThinQConstants.clientID), ("country_code", JS.string(account["country"])),
            ("redirect_uri", "lgaccount.lgsmartthinq:/"), ("response_type", "code"), ("state", "12345"), ("username", JS.string(account["userID"])),
        ])
        let path = "/emp/oauth2/authorize/empsession"
        let signature = Self.signature("\(path)?\(search)\n\(timestamp)", secret: secretKey)
        let empHeaders: [(name: String, value: String)] = [
            ("lgemp-x-app-key", ThinQConstants.oauthClientKey), ("lgemp-x-date", timestamp), ("lgemp-x-session-key", JS.string(account["loginSessionID"])),
            ("lgemp-x-signature", signature), ("Accept", "application/json"), ("X-Device-Type", "M01"), ("X-Device-Platform", "ADR"),
            ("Content-Type", "application/x-www-form-urlencoded"), ("Access-Control-Allow-Origin", "*"), ("Accept-Encoding", "gzip, deflate, br"),
            ("Accept-Language", "en-US,en;q=0.9"),
            ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36 Edg/93.0.961.44"),
        ]
        let authorize: JSONValue
        do {
            authorize = try await client.get("https://emp-oauth.lgecloud.com\(path)?\(search)", headers: empHeaders).data
        } catch ThinQError.http(let status, let body) {
            guard let message = body["error"]?["message"]?.stringValue else { throw ThinQError.http(status: status, body: body) }
            throw ThinQError.authentication(message)
        }
        guard JS.number(authorize["status"]) == 1 else { throw ThinQError.token(authorize["message"]?.stringValue ?? authorize.text()) }
        guard let redirect = authorize["redirect_uri"]?.stringValue, let components = URLComponents(string: redirect) else {
            throw ThinQError.token("LG returned no redirect.")
        }
        let items = components.queryItems ?? []
        let backend = items.first { $0.name == "oauth2_backend_url" }?.value
        return try await requestToken(code: items.first { $0.name == "code" }?.value ?? "", backendURL: backend?.isEmpty == false ? backend : nil)
    }

    /// Exchanges an authorization code for a session at the country's OAuth backend.
    func requestToken(code: String, backendURL: String? = nil) async throws -> Session {
        let form = URLEncoding.query([("code", code), ("grant_type", "authorization_code"), ("redirect_uri", ThinQConstants.accountRedirectURI)])
        let timestamp = RFC2822.string()
        let token = try await client.post((backendURL ?? lgeapiURL) + "oauth/1.0/oauth2/token", form: form, headers: oauthHeaders(
            signing: "/oauth/1.0/oauth2/token?\(form)", timestamp: timestamp)).data
        if let backend = token["oauth2_backend_url"]?.stringValue, !backend.isEmpty { lgeapiURL = backend }
        return Session(accessToken: JS.string(token["access_token"]), refreshToken: JS.string(token["refresh_token"]), expiresAt: Session.expiry(fromNow: token["expires_in"]))
    }

    /// A new access token for the session's refresh token, at the OAuth backend the gateway list names.
    func refreshNewToken(_ session: Session) async throws -> Session {
        do {
            let gateways = try await client.post("https://kic.lgthinq.com:46030/api/common/gatewayUriList", json: [
                "lgedmRoot": ["countryCode": .string(gateway.countryCode), "langCode": .string(gateway.languageCode)],
            ], headers: [("Accept", "application/json"), ("x-thinq-application-key", "wideq"), ("x-thinq-security-key", "nuts_securitykey")]).data
            if let oauth = gateways["lgedmRoot"]?["oauthUri"]?.stringValue, !oauth.isEmpty { lgeapiURL = oauth + "/" }
        } catch {
            // The country's default backend then.
        }
        let form = URLEncoding.query([("grant_type", "refresh_token"), ("refresh_token", session.refreshToken)])
        let timestamp = RFC2822.string()
        let token = try await client.post(lgeapiURL + "oauth/1.0/oauth2/token", form: form, headers: oauthHeaders(
            signing: "/oauth/1.0/oauth2/token?\(form)", timestamp: timestamp)).data
        var session = session
        session.newToken(JS.string(token["access_token"]), expiresAt: Session.expiry(fromNow: token["expires_in"]))
        return session
    }

    /// The account's user number, which ThinQ v2 requests carry.
    func userNumber(accessToken: String) async throws -> String {
        let timestamp = RFC2822.string()
        let profile = try await client.get(lgeapiURL + "users/profile", headers: [
            ("Accept", "application/json"), ("Authorization", "Bearer \(accessToken)"), ("X-Lge-Svccode", "SVC202"),
            ("X-Application-Key", ThinQConstants.applicationKey), ("lgemp-x-app-key", ThinQConstants.clientID), ("X-Device-Type", "M01"),
            ("X-Device-Platform", "ADR"), ("x-lge-oauth-date", timestamp),
            ("x-lge-oauth-signature", Self.signature("/users/profile\n\(timestamp)", secret: ThinQConstants.oauthSecretKey)),
        ]).data
        if JS.number(profile["status"]) == 2 { throw ThinQError.authentication(JS.string(profile["message"])) }
        guard let number = profile["account"]?["userNo"], !number.isNull else { throw ThinQError.authentication("LG returned no user number.") }
        return JS.string(number)
    }

    /// The ThinQ v1 session id. Failure is normal for accounts without v1 devices: logged, and nil.
    func jsessionID(accessToken: String) async -> String? {
        do {
            let answer = try await client.post(gateway.thinq1URL + "member/login", json: [
                "lgedmRoot": ["countryCode": .string(gateway.countryCode), "langCode": .string(gateway.languageCode), "loginType": "EMP", "token": .string(accessToken)],
            ], headers: [("x-thinq-application-key", "wideq"), ("x-thinq-security-key", "nuts_securitykey"), ("Accept", "application/json"), ("x-thinq-token", accessToken)]).data
            return answer["lgedmRoot"]?["jsessionId"]?.stringValue
        } catch {
            let message = "\(error)"
            logger.debug("\(message.hasPrefix(ThinQError.manualProcessNeededCode) ? "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift." : message)")
            logger.info("Failed to login to old thinq v1 gateway. See debug logs for more details. Continuing anyways.")
            return nil
        }
    }

    /// Accepts the terms LG added since the account last agreed, as its app does.
    func handleNewTerm(accessToken: String) async throws {
        let showTerms = "common/showTerms?" + URLEncoding.query([
            ("callback_url", "lgaccount.lgsmartthinq:/updateTerms"), ("country", gateway.countryCode), ("language", gateway.languageCode),
            ("division", "ha:T20"), ("terms_display_type", "3"), ("svc_list", "SVC202"),
        ])
        let html = JS.string(try await client.get(gateway.loginBaseURL + showTerms, headers: [("X-Login-Session", accessToken)]).data)
        guard let signature = Self.firstMatch(#"signature[\s]+:[\s]+"([^"]+)""#, in: html), let timestamp = Self.firstMatch(#"tStamp[\s]+:[\s]+"([^"]+)""#, in: html) else {
            throw ThinQError.token("Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.")
        }
        let headers = defaultEmpHeaders + [("X-Login-Session", accessToken), ("X-Signature", signature), ("X-Timestamp", timestamp)]
        let accountTerms = try await client.get(gateway.empBaseURL + "emp/v2.0/account/user/terms?opt_term_cond=001&term_data=SVC202&itg_terms_use_flag=Y&dummy_terms_use_flag=Y",
            headers: headers).data["account"]?["terms"]?.arrayValue?.compactMap { $0["termsID"].map { JS.string($0) } } ?? []
        let infoTerms = try await client.get(gateway.empBaseURL + "emp/v2.0/info/terms?opt_term_cond=001&only_service_terms_flag=&itg_terms_use_flag=Y&term_data=SVC202",
            headers: headers).data["info"]?["terms"]?.arrayValue ?? []
        let needed = infoTerms.filter { !accountTerms.contains(JS.string($0["termsID"])) }
            .map { [JS.string($0["termsType"]), JS.string($0["termsID"]), JS.string($0["defaultLang"])].joined(separator: ":") }
            .joined(separator: ",")
        if !needed.isEmpty {
            _ = try await client.post(gateway.empBaseURL + "emp/v2.0/account/user/terms", form: URLEncoding.query([("terms", needed)]), headers: headers)
        }
    }

    /// The URL of LG's own sign-in page, for accounts that sign in with Google, Apple, Facebook or Amazon.
    func loginURL() -> String {
        gateway.loginBaseURL + "login/signIn?" + URLEncoding.query([
            ("country", gateway.countryCode), ("language", gateway.languageCode), ("client_id", ThinQConstants.clientID),
            ("svc_list", ThinQConstants.svcCode), ("svc_integrated", "Y"), ("redirect_uri", "lgaccount.lgsmartthinq:/"),
            ("show_thirdparty_login", "LGE,MYLG,GGL,AMZ,FBK,APPL"), ("division", "ha:T20"), ("callback_url", "lgaccount.lgsmartthinq:/"),
            ("oauth2State", "12345"), ("show_select_country", "N"),
        ])
    }

    var defaultEmpHeaders: [(name: String, value: String)] {
        [
            ("Accept", "application/json"), ("X-Application-Key", ThinQConstants.applicationKey), ("X-Client-App-Key", ThinQConstants.clientID),
            ("X-Lge-Svccode", "SVC709"), ("X-Device-Type", "M01"), ("X-Device-Platform", "ADR"), ("X-Device-Language-Type", "IETF"),
            ("X-Device-Publish-Flag", "Y"), ("X-Device-Country", gateway.countryCode), ("X-Device-Language", gateway.languageCode),
            ("Content-Type", "application/x-www-form-urlencoded;charset=UTF-8"), ("Access-Control-Allow-Origin", "*"),
            ("Accept-Encoding", "gzip, deflate, br"), ("Accept-Language", "en-US,en;q=0.9"), ("User-Agent", ThinQConstants.empUserAgent),
        ]
    }

    private func oauthHeaders(signing path: String, timestamp: String) -> [(name: String, value: String)] {
        [
            ("x-lge-app-os", "ADR"), ("x-lge-appkey", ThinQConstants.clientID),
            ("x-lge-oauth-signature", Self.signature("\(path)\n\(timestamp)", secret: ThinQConstants.oauthSecretKey)),
            ("x-lge-oauth-date", timestamp), ("Accept", "application/json"), ("Content-Type", "application/x-www-form-urlencoded"),
        ]
    }

    // MARK: Crypto

    /// HMAC-SHA1 of the message under the secret's UTF-8 bytes, base64.
    nonisolated static func signature(_ message: String, secret: String) -> String {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))).base64EncodedString()
    }

    nonisolated static func sha512Hex(_ text: String) -> String {
        Secrets.hex(SHA512.hash(data: Data(text.utf8)))
    }

    /// The user id encrypted with LG's account key, RSA PKCS#1 v1.5, base64, as the sign-in form does.
    nonisolated static func encryptUserID(_ username: String) throws -> String {
        let key = try _RSA.Encryption.PublicKey(pemRepresentation: ThinQConstants.accountPublicKey)
        return try key.encrypt(Data(username.utf8), padding: ._WEAK_AND_INSECURE_PKCS_V1_5).base64EncodedString()
    }

    nonisolated static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    /// `JSON.stringify` of an object with its keys in the given order.
    nonisolated static func jsonText(_ object: JSONValue, keys: [String]) -> String {
        "{" + keys.compactMap { key in object[key].map { "\(JSONValue.string(key).text()):\($0.text())" } }.joined(separator: ",") + "}"
    }

    nonisolated static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
