import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// The Homebridge plugin's token-client, token-storage, Developer Portal and Mobile App login tests.
@Suite(.timeLimit(.minutes(1)))
struct OAuthTests {
    let directory = temporaryDirectory()
    let tokenURL = DeveloperPortalOAuth.tokenEndpoint

    // MARK: Token sets

    @Test func expiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = TokenSet(access_token: "a", token_type: "Bearer", expires_in: 3600)
        #expect(tokens.withExpiresAt(now: now).expires_at == 1_003_600)
        #expect(tokens.expires_at == nil)
        var fixed = tokens
        fixed.expires_at = 42
        #expect(fixed.withExpiresAt(now: now).expires_at == 42)
        var expiring = tokens
        expiring.expires_at = 1_000_000 + TokenSet.expiryBuffer - 1
        #expect(expiring.isExpiring(now: now))
        expiring.expires_at = 1_000_000 + TokenSet.expiryBuffer + 1
        #expect(!expiring.isExpiring(now: now))
        #expect(TokenSet(access_token: "a", token_type: "Bearer").isExpiring(now: now))
    }

    @Test func tokenResponses() throws {
        let html = HTTPResponse.text("<html><body>Request blocked</body></html>", status: 403)
        #expect(throws: DaikinError("Token refresh failed: idp.onecta.daikineurope.com returned a non-JSON response (HTTP 403): <html><body>Request blocked</body></html>")) {
            try TokenResponse.parse(html, url: tokenURL, context: "Token refresh failed")
        }
        #expect(throws: DaikinError("Token refresh failed: idp.onecta.daikineurope.com returned a non-JSON response (HTTP 502) with an empty body")) {
            try TokenResponse.parse(.text("", status: 502), url: tokenURL, context: "Token refresh failed")
        }
        let valid = try TokenResponse.parse(.json(["access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": 3600]), url: tokenURL, context: "x")
        #expect(valid == TokenSet(access_token: "a", refresh_token: "r", token_type: "Bearer", expires_in: 3600))
        #expect(throws: DaikinError("x: invalid_grant - Refresh token expired (HTTP 400)")) {
            try TokenResponse.parse(.json(["error": "invalid_grant", "error_description": "Refresh token expired"], status: 400), url: tokenURL, context: "x")
        }
        #expect(throws: DaikinError("x: idp.onecta.daikineurope.com returned HTTP 500")) {
            try TokenResponse.parse(.json(["message": "boom"], status: 500), url: tokenURL, context: "x")
        }
        do {
            _ = try TokenResponse.parse(.json(["access_token": 42, "token_type": "Bearer", "secret": "hidden"]), url: tokenURL, context: "x")
            Issue.record("no error")
        } catch let error as DaikinError {
            #expect(error.message == "x: idp.onecta.daikineurope.com returned an invalid token response (missing or malformed: access_token)")
            #expect(!error.message.contains("42"))
        }
    }

    @Test func tokenFileIsOwnerOnlyAndValidated() throws {
        let url = directory.appendingPathComponent(".daikin-mobile-tokenset")
        #expect(TokenFile.load(url) == nil)
        let tokens = TokenSet(access_token: "a", refresh_token: "r", token_type: "Bearer", expires_in: 3600, expires_at: 1_700_000_000)
        try TokenFile.save(tokens, to: url)
        #expect(TokenFile.load(url) == tokens)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".daikin-mobile-tokenset"])
        try Data("not json".utf8).write(to: url)
        #expect(TokenFile.load(url) == nil)
        try Data(#"{"refresh_token":"r"}"#.utf8).write(to: url)
        #expect(TokenFile.load(url) == nil)
        // A token file written by the Homebridge plugin.
        try Data(#"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":3600,"expires_at":1767000000,"scope":"openid"}"#.utf8).write(to: url)
        #expect(TokenFile.load(url)?.expires_at == 1_767_000_000)
        TokenFile.delete(url)
        TokenFile.delete(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func tokenClientRefreshes() async throws {
        let url = directory.appendingPathComponent("tokens")
        try TokenFile.save(TokenSet(access_token: "old", refresh_token: "refresh", token_type: "Bearer", expires_at: 1), to: url)
        let calls = NIOLockedValueBox(0)
        let release = Signal()
        let client = TokenClient(file: url) { refresh in
            #expect(refresh == "refresh")
            calls.withLockedValue { $0 += 1 }
            await release.wait()
            // No refresh_token: the server does not rotate it.
            return TokenSet(access_token: "fresh", token_type: "Bearer", expires_in: 3600)
        }
        #expect(await client.isAuthenticated())
        async let first = client.accessToken()
        async let second = client.accessToken()
        #expect(await eventually { calls.withLockedValue { $0 } == 1 })
        release.fire()
        #expect(try await [first, second] == ["fresh", "fresh"])
        #expect(calls.withLockedValue { $0 } == 1)
        #expect(TokenFile.load(url)?.refresh_token == "refresh")
        #expect(TokenFile.load(url)?.expires_at != nil)
        // A token outside the margin is used as it is.
        #expect(try await client.accessToken() == "fresh")
        #expect(calls.withLockedValue { $0 } == 1)
        await client.clear()
        #expect(!(await client.isAuthenticated()))
        await #expect(throws: DaikinError("Not authenticated. Please authenticate first.")) { try await client.accessToken() }
    }

    @Test func aFailedRefreshIsTriedAgain() async throws {
        let url = directory.appendingPathComponent("tokens")
        try TokenFile.save(TokenSet(access_token: "old", refresh_token: "refresh", token_type: "Bearer", expires_at: 1), to: url)
        let attempts = NIOLockedValueBox(0)
        let client = TokenClient(file: url) { _ in
            let attempt = attempts.withLockedValue { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 { throw DaikinError("Token refresh failed: invalid_grant") }
            return TokenSet(access_token: "fresh", refresh_token: "new", token_type: "Bearer", expires_in: 3600)
        }
        await #expect(throws: DaikinError("Token refresh failed: invalid_grant")) { try await client.accessToken() }
        #expect(try await client.accessToken() == "fresh")
        #expect(TokenFile.load(url)?.refresh_token == "new")
    }

    /// Revoking from the page while a poll refreshes: the refresh's answer must not write the login back.
    @Test func aRefreshInFlightDoesNotRestoreClearedTokens() async throws {
        let url = directory.appendingPathComponent("tokens")
        try TokenFile.save(TokenSet(access_token: "old", refresh_token: "refresh", token_type: "Bearer", expires_at: 1), to: url)
        let started = Signal()
        let release = Signal()
        let client = TokenClient(file: url) { _ in
            started.fire()
            await release.wait()
            return TokenSet(access_token: "fresh", refresh_token: "new", token_type: "Bearer", expires_in: 3600)
        }
        let refresh = Task { try await client.accessToken() }
        await started.wait()
        await client.clear()
        release.fire()
        await #expect(throws: DaikinError("Not authenticated. Please authenticate first.")) { try await refresh.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!(await client.isAuthenticated()))
    }

    @Test func expiredWithoutARefreshToken() async throws {
        let url = directory.appendingPathComponent("tokens")
        try TokenFile.save(TokenSet(access_token: "old", token_type: "Bearer", expires_at: 1), to: url)
        let client = TokenClient(file: url) { _ in Issue.record("refreshed"); throw DaikinError("no") }
        await #expect(throws: DaikinError("Token expired and no refresh token available. Please re-authenticate.")) { try await client.accessToken() }
    }

    // MARK: Developer Portal

    @Test func developerPortalFlow() async throws {
        let url = DeveloperPortalOAuth.authorizationURL(clientID: "client id", redirectURI: "https://192.168.1.10:8582", state: "abc")
        #expect(url == "https://idp.onecta.daikineurope.com/v1/oidc/authorize?response_type=code&client_id=client+id&redirect_uri=https%3A%2F%2F192.168.1.10%3A8582&scope=openid+onecta%3Abasic.integration&state=abc")
        #expect(DeveloperPortalOAuth.makeState().count == 64)

        let http = FakeHTTP { request, _ in
            if request.url.path.hasSuffix("/revoke") { return .text("", status: 500) }
            switch request.form["grant_type"] {
            case "authorization_code": return .json(["access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": 3600])
            case "refresh_token": return .json(["error": "invalid_grant"], status: 400)
            default: return .text("<html>", status: 500)
            }
        }
        let tokens = try await DeveloperPortalOAuth.exchangeCode("the-code", clientID: "id", clientSecret: "secret", redirectURI: "https://h:1", http: DaikinHTTP(transport: http))
        #expect(tokens.expires_at != nil)
        #expect(http.all[0].form == ["grant_type": "authorization_code", "code": "the-code", "redirect_uri": "https://h:1", "client_id": "id", "client_secret": "secret"])
        #expect(http.all[0].header("Content-Type") == "application/x-www-form-urlencoded")
        await #expect(throws: DaikinError("Token refresh failed: invalid_grant (HTTP 400)")) {
            try await DeveloperPortalOAuth.refresh("r", clientID: "id", clientSecret: "secret", http: DaikinHTTP(transport: http))
        }
        await #expect(throws: DaikinError("Token revocation failed: HTTP 500")) {
            try await DeveloperPortalOAuth.revoke("r", clientID: "id", clientSecret: "secret", http: DaikinHTTP(transport: http))
        }
        #expect(http.all.last?.form["token_type_hint"] == "refresh_token")
    }

    // MARK: Mobile App

    /// The Gigya and OIDC endpoints, with what `login` answers.
    final class Gigya: @unchecked Sendable {
        let login: JSONValue
        let register: JSONValue
        let failures = NIOLockedValueBox(0)
        let http: FakeHTTP

        init(login: JSONValue, register: JSONValue = ["errorCode": 0, "sessionInfo": ["login_token": "login-token-xyz"]], failures: Int = 0, code: String = "ETIMEDOUT") {
            self.login = login
            self.register = register
            self.failures.withLockedValue { $0 = failures }
            let remaining = self.failures
            http = FakeHTTP { request, _ in
                if remaining.withLockedValue({ value -> Bool in
                    guard value > 0 else { return false }
                    value -= 1
                    return true
                }) {
                    throw DaikinNetworkError(code: code, message: "connect \(code)")
                }
                let url = request.url.absoluteString
                if url.contains("/authorize/continue") { return HTTPResponse(status: 302, headers: [("location", "daikinunified://login?code=auth-code-456")]) }
                if url.contains("/authorize?") { return HTTPResponse(status: 302, headers: [("location", "https://id.daikin.eu/cdc/onecta/oidc/proxy.html?context=test%2Dcontext-123&mode=login")]) }
                if url.contains("accounts.webSdkBootstrap") { return .json([:], headers: [("set-cookie", "gig_canary=abc123; Path=/"), ("set-cookie", "gig_canary_ver=1; Path=/")]) }
                if url.contains("accounts.login") { return .json(login) }
                if url.contains("accounts.register") { return .json(register) }
                if url.contains("/oidc/token") { return .json(["access_token": "access-token-final", "refresh_token": "refresh-token-final", "token_type": "Bearer", "expires_in": 3600]) }
                return .text("Unexpected", status: 500)
            }
        }
    }

    func mobile(_ gigya: Gigya, log: LogRecorder) -> MobileOAuth {
        var oauth = MobileOAuth(email: "john.doe@example.com", password: "test-password", http: DaikinHTTP(transport: gigya.http), log: { log.logger.info("\($0)") })
        oauth.sleep = { _ in }
        return oauth
    }

    @Test func mobileLogin() async throws {
        let gigya = Gigya(login: ["errorCode": 0, "sessionInfo": ["login_token": "lt"]])
        let log = LogRecorder()
        let tokens = try await mobile(gigya, log: log).authenticate()
        #expect(tokens.access_token == "access-token-final")
        let requests = gigya.http.all
        #expect(requests.count == 5)
        #expect(requests.allSatisfy { $0.header("User-Agent") == "okhttp/4.12.0" })
        let authorize = try #require(requests.first)
        #expect(URLQuery.parameter("code_challenge_method", in: authorize.url.absoluteString) == "S256")
        #expect(URLQuery.parameter("scope", in: authorize.url.absoluteString) == "openid onecta:onecta.application offline_access")
        // The context from the redirect, decoded, and the cookies of the bootstrap.
        #expect(URLQuery.parameter("pageURL", in: requests[1].url.absoluteString)?.contains("context=test-context-123") == true)
        let login = requests[2]
        #expect(login.form["loginID"] == "john.doe@example.com")
        #expect(login.form["password"] == "test-password")
        #expect(login.header("Cookie") == "gig_canary=abc123; gig_canary_ver=1; gig_bootstrap_3_xRB3jaQ62bVjqXU1omaEsPDVYC0Twi1zfq1zHPu_5HFT0zWkDvZJS97Yw1loJnTm=cdc_ver4")
        #expect(try JSONValue(string: login.form["riskContext"] ?? "")["b0"] == 14063)
        #expect(requests[3].header("Cookie")?.hasSuffix("glt_3_xRB3jaQ62bVjqXU1omaEsPDVYC0Twi1zfq1zHPu_5HFT0zWkDvZJS97Yw1loJnTm=lt") == true)
        let exchange = requests[4]
        #expect(exchange.header("Authorization") == "Basic " + Data("FjS6T5oZHvzpZENIDybFRdtK:_yWGLBGUnQFrN-u7uIOAZhSBsJOfcnBs0IS87wTgUvUmnLnEOs4NQmaKagqZBpQpG0XYl07KeCx8XHHKxAn24w".utf8).base64EncodedString())
        #expect(exchange.form["code"] == "auth-code-456")
        #expect(exchange.form["redirect_uri"] == "daikinunified://cdc/")
        // The verifier matches the challenge.
        let verifier = try #require(exchange.form["code_verifier"])
        #expect(Secrets.base64URL(Data(SHA256Digest(verifier))) == URLQuery.parameter("code_challenge", in: authorize.url.absoluteString))
    }

    @Test func completesAPendingRegistration() async throws {
        let gigya = Gigya(login: [
            "errorCode": 206001, "errorMessage": "Account Pending Registration", "regToken": "reg-token-abc",
            "data": ["profile": ["countryResidence": "FR", "communicationLanguage": "fr"]], "profile": ["firstName": "Jean", "lastName": "Dupont"],
        ])
        let log = LogRecorder()
        #expect(try await mobile(gigya, log: log).authenticate().access_token == "access-token-final")
        #expect(log.contains("Account has pending registration (206001)"))
        #expect(log.contains("Pending registration completed successfully"))
        #expect(!log.contains("Using derived name"))
        let register = try #require(gigya.http.all.first { $0.url.absoluteString.contains("accounts.register") })
        #expect(register.form["regToken"] == "reg-token-abc")
        #expect(try JSONValue(string: register.form["profile"] ?? "") == ["firstName": "Jean", "lastName": "Dupont"])
        #expect(try JSONValue(string: register.form["data"] ?? "") == ["profile": ["countryResidence": "FR", "communicationLanguage": "fr"]])
        #expect(register.form["finalizeRegistration"] == "true")
    }

    @Test func derivesANameFromTheEmail() async throws {
        let gigya = Gigya(login: ["errorCode": 206001, "regToken": "reg", "data": ["profile": [:]]])
        let log = LogRecorder()
        _ = try await mobile(gigya, log: log).authenticate()
        #expect(log.contains("Using derived name for registration: John Doe."))
        #expect(log.contains("countryResidence=US, communicationLanguage=en"))
    }

    @Test func usesTheLoginTokenOfAPendingRegistration() async throws {
        let gigya = Gigya(login: ["errorCode": 206001, "errorMessage": "Account Pending Registration", "sessionInfo": ["login_token": "already-has-token"], "regToken": "unused"])
        let log = LogRecorder()
        #expect(try await mobile(gigya, log: log).authenticate().access_token == "access-token-final")
        #expect(!log.contains("Completing pending registration"))
        #expect(gigya.http.count == 5)
    }

    @Test func loginErrors() async throws {
        let failing = Gigya(login: ["errorCode": 206001, "regToken": "reg", "data": ["profile": [:]]], register: ["errorCode": 400006, "errorMessage": "Unallowed value"])
        await #expect(throws: DaikinError("Registration completion failed (400006): Unallowed value")) { try await mobile(failing, log: LogRecorder()).authenticate() }
        let wrong = Gigya(login: ["errorCode": 403042, "errorMessage": "Invalid LoginID"])
        await #expect(throws: DaikinError("Login failed (403042): Invalid LoginID")) { try await mobile(wrong, log: LogRecorder()).authenticate() }
        let odd = Gigya(login: ["unexpected": true])
        await #expect(throws: DaikinError("Login failed: cdc.daikin.eu returned an unexpected response (HTTP 200)")) { try await mobile(odd, log: LogRecorder()).authenticate() }
    }

    /// Gigya's code from JSON never traps, and only an exact 0 is a success.
    @Test func gigyaErrorCodes() {
        #expect(MobileOAuth.errorCode(0) == 0)
        #expect(MobileOAuth.errorCode(403042) == 403042)
        #expect(MobileOAuth.errorCode(1e300) == Int.max)
        #expect(MobileOAuth.errorCode(-1e300) == Int.min)
        #expect(MobileOAuth.errorCode(0.5) != 0)
        #expect(MobileOAuth.errorCode(.infinity) == Int.max)
    }

    @Test func aHugeErrorCodeIsAnError() async throws {
        let odd = Gigya(login: ["errorCode": 1e300, "errorMessage": "Odd"])
        await #expect(throws: DaikinError("Login failed (\(Int.max)): Odd")) { try await mobile(odd, log: LogRecorder()).authenticate() }
    }

    @Test func retriesTransientNetworkFailures() async throws {
        let down = Gigya(login: [:], failures: 99)
        let log = LogRecorder()
        do {
            _ = try await mobile(down, log: log).authenticate()
            Issue.record("no error")
        } catch let error as DaikinError {
            #expect(error.message.contains("cdc.daikin.eu failed after 3 attempts"))
        }
        #expect(down.http.count == 3)
        #expect(log.contains("retrying in 1000ms (attempt 2/3)"))
        #expect(log.contains("retrying in 2000ms (attempt 3/3)"))

        let flaky = Gigya(login: ["errorCode": 0, "sessionInfo": ["login_token": "lt"]], failures: 1, code: "ECONNRESET")
        #expect(try await mobile(flaky, log: LogRecorder()).authenticate().access_token == "access-token-final")
        #expect(flaky.http.count == 6)

        let refused = Gigya(login: [:], failures: 99, code: "EPROTO")
        await #expect(throws: DaikinError("Request to cdc.daikin.eu failed: connect EPROTO (EPROTO)")) { try await mobile(refused, log: LogRecorder()).authenticate() }
        #expect(refused.http.count == 1)
    }

    @Test func mobileRefresh() async throws {
        let http = FakeHTTP { request, index in
            #expect(request.form == ["grant_type": "refresh_token", "refresh_token": "rt"])
            #expect(request.header("Authorization")?.hasPrefix("Basic ") == true)
            return index == 1 ? .text("<html>WAF</html>", status: 403) : .json(["access_token": "a", "token_type": "Bearer", "expires_in": 3600])
        }
        let oauth = MobileOAuth(email: "", password: "", http: DaikinHTTP(transport: http))
        await #expect(throws: DaikinError("Token refresh failed: idp.onecta.daikineurope.com returned a non-JSON response (HTTP 403): <html>WAF</html>")) { try await oauth.refresh("rt") }
        #expect(try await oauth.refresh("rt").access_token == "a")
    }
}

/// SHA-256 of a string.
private func SHA256Digest(_ string: String) -> [UInt8] { Array(SHA256.hash(data: Data(string.utf8))) }
