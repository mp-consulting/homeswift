import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing
import _CryptoExtras

@testable import Homeswift
@testable import HomeswiftLGThinQ

@Suite struct JavaScriptSemanticsTests {
    @Test func numbersAndStrings() {
        #expect(JS.parseInt("12abc") == 12)
        #expect(JS.parseInt("  -7") == -7)
        #expect(JS.parseInt("abc").isNaN)
        #expect(JS.parseInt(JSONValue.number(25.9)) == 25)
        #expect(JS.parseInt(nil, fallback: 3) == 3)
        #expect(JS.parseFloat("25.5°") == 25.5)
        #expect(JS.parseFloat(".5") == 0.5)
        #expect(JS.parseFloat("x").isNaN)
        #expect(JS.number(.string("")) == 0)
        #expect(JS.number(.string(" 42 ")) == 42)
        #expect(JS.number(.string("4x")).isNaN)
        #expect(JS.number(nil).isNaN)
        #expect(JS.number(.null) == 0)
        #expect(JS.string(.number(350)) == "350")
        #expect(JS.string(.number(25.5)) == "25.5")
        #expect(JS.string(nil) == "undefined")
        #expect(JS.truthy(.string("")) == false && JS.truthy(.number(0)) == false && JS.truthy(.string("0")))
        #expect(JS.keys(["b": 1, "10": 1, "2": 1, "a": 1]) == ["2", "10", "a", "b"])
        #expect(JS.shiftLeft(1, 8) == 256)
        #expect(JS.shiftLeft(.nan, 8) == 0)
        #expect(JS.shiftLeft(16_777_216, 8) == 0)
        // Whole numbers past Int64 print in full up to 1e21, as JavaScript does, without trapping.
        #expect(JS.format(1e19) == "10000000000000000000" && JS.format(-9.3e18) == "-9300000000000000000")
        #expect(JS.format(9.223372036854775807e18) == "9223372036854775808" && JS.format(-0.0) == "0")
        #expect(JS.format(1e21) == "1e+21")
        #expect(JS.int(.string("99999999999999999999999")) == Int.max && JS.int(.string(String(repeating: "9", count: 400)), fallback: 7) == 7)
        #expect(JS.int(.string("-99999999999999999999999")) == Int.min && JS.int(.string("x"), fallback: 3) == 3)
    }

    @Test func fitsValuesToCharacteristics() {
        let counter = CharacteristicType(name: "Counter", uuid: HAPUUID("00000000-0000-1000-8000-0026BB765291"), format: .uint64, permissions: [.pairedRead])
        #expect(Service.fit(.double(1e300), to: counter) == .int(Int.max))
        #expect(Service.fit(.double(-5), to: counter) == .int(0) && Service.fit(.double(.nan), to: counter) == nil)
        #expect(Service.fit(.double(2.6), to: .remainingDuration) == .int(3))
    }

    @Test func decodesBase64AsNodeDoes() {
        #expect(ThinQAPI.decodeBase64("AQID") == Data([1, 2, 3]))
        // Line breaks and spaces are skipped, padding is optional, decoding stops at the first "=".
        #expect(ThinQAPI.decodeBase64("AQ\r\nID") == Data([1, 2, 3]) && ThinQAPI.decodeBase64(" A Q I D ") == Data([1, 2, 3]))
        #expect(ThinQAPI.decodeBase64("AQI") == Data([1, 2]) && ThinQAPI.decodeBase64("AQ==AQID") == Data([1]))
        // The URL-safe alphabet too.
        #expect(ThinQAPI.decodeBase64("-_8") == Data([0xFB, 0xFF]) && ThinQAPI.decodeBase64("+/8=") == Data([0xFB, 0xFF]))
        #expect(ThinQAPI.decodeBase64("") == Data() && ThinQAPI.decodeBase64("***") == Data())
    }

    @Test func normalizesHomeKitValues() {
        #expect(Normalize.boolean(.int(1)) && !Normalize.boolean(.int(2)) && Normalize.boolean(.string("on")))
        #expect(Normalize.number(.string("21.5")) == 21.5)
        #expect(Normalize.number(.string("x")) == nil)
    }

    @Test func encodesLikeQs() {
        #expect(URLEncoding.query([("a b", "lgaccount.lgsmartthinq:/"), ("empty", ""), ("star", "*!'()")]) == "a%20b=lgaccount.lgsmartthinq%3A%2F&empty=&star=%2A%21%27%28%29")
        #expect(URLEncoding.uriComponent("a+b/c=*") == "a%2Bb%2Fc%3D*")
        #expect(parseQuery("code=the%20Code&state=signin") == ["code": "the Code", "state": "signin"])
    }

    @Test func formatsDatesLikeLuxon() {
        #expect(RFC2822.string(Date(timeIntervalSince1970: 1_700_000_000)) == "Tue, 14 Nov 2023 22:13:20 +0000")
        #expect(RFC2822.string(Date(timeIntervalSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 +0000")
    }

    @Test func signsAndHashesLikeNode() {
        // crypto.createHmac('sha1', Buffer.from('key')).update('The quick brown fox jumps over the lazy dog').digest('base64')
        #expect(Auth.signature("The quick brown fox jumps over the lazy dog", secret: "key") == "3nybhbi3iqa8ino29wqQcBydtNk=")
        #expect(Auth.sha512Hex("abc").hasPrefix("ddaf35a193617aba"))
        #expect(Auth.randomString(32).count == 32)
        #expect(Auth.jsonText(["user_id": "a@b.c", "uuid": "u"], keys: ["uuid", "user_id"]) == #"{"uuid":"u","user_id":"a@b.c"}"#)
    }

    @Test func encryptsTheUserIDForLG() throws {
        let encrypted = try #require(Data(base64Encoded: try Auth.encryptUserID("someone@example.com")))
        #expect(encrypted.count == 256)
        // PKCS#1 v1.5 is randomized: two encryptions differ.
        #expect(try Auth.encryptUserID("someone@example.com") != Auth.encryptUserID("someone@example.com"))
    }

    @Test func sessionExpiry() {
        #expect(Session.expiry(fromNow: .string("3600")) > Session.now() + 3000)
        #expect(Session.expiry(fromNow: .string("x")) == 0)
        let session = Session(accessToken: "a", refreshToken: "r", expiresAt: Session.expiry(fromNow: 3600))
        #expect(session.hasValidToken)
        #expect(!Session(accessToken: "a", refreshToken: "r", expiresAt: 0).hasValidToken)
    }
}

/// A transport that answers from a list, recording requests.
final class ScriptedTransport: HTTPSending, @unchecked Sendable {
    let responses: NIOLockedValueBox<[Result<HTTPResponse, ThinQNetworkError>]>
    let sent = NIOLockedValueBox<[HTTPRequest]>([])

    init(_ responses: [Result<HTTPResponse, ThinQNetworkError>]) {
        self.responses = NIOLockedValueBox(responses)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.withLockedValue { $0.append(request) }
        let next = responses.withLockedValue { $0.isEmpty ? .success(FakeLG.json([:])) : $0.removeFirst() }
        return try next.get()
    }
}

@Suite struct RequestClientTests {
    @ThinQActor
    func client(_ transport: ScriptedTransport) -> RequestClient {
        let client = RequestClient(transport: transport, logger: testLogger)
        client.sleep = { _ in }
        return client
    }

    @Test @ThinQActor func mapsLGResultCodes() async throws {
        let transport = ScriptedTransport([
            .success(FakeLG.json(["lgedmRoot": ["returnCd": "0106", "returnMsg": "offline"]])),
            .success(FakeLG.json(["lgedmRoot": ["returnCd": "0102"]])),
            .success(FakeLG.json(["lgedmRoot": ["returnCd": "9000", "returnMsg": "bad"]])),
            .success(FakeLG.json(["resultCode": "9999"], status: 400)),
            .success(FakeLG.json(["resultCode": "0102"], status: 400)),
            .success(FakeLG.json([:], status: 401)),
            .success(FakeLG.json(["resultCode": "0110"], status: 400)),
            .success(FakeLG.json(["resultCode": "9012"], status: 429)),
        ])
        let client = client(transport)
        await #expect(throws: ThinQError.notConnected("offline")) { try await client.get("https://x.test/a") }
        await #expect(throws: ThinQError.tokenExpired("")) { try await client.get("https://x.test/a") }
        await #expect(throws: ThinQError.monitor("9000 - bad")) { try await client.get("https://x.test/a") }
        await #expect(throws: ThinQError.notConnected("")) { try await client.get("https://x.test/a") }
        await #expect(throws: ThinQError.tokenExpired("")) { try await client.get("https://x.test/a") }
        await #expect(throws: ThinQError.tokenExpired("HTTP 401")) { try await client.get("https://x.test/a") }
        do {
            _ = try await client.get("https://x.test/a")
            Issue.record("expected an error")
        } catch let error as ThinQError {
            guard case .manualProcessNeeded = error else { Issue.record("\(error)"); return }
        }
        do {
            _ = try await client.get("https://x.test/a")
            Issue.record("expected an error")
        } catch let error as ThinQError {
            guard case .http(429, _) = error else { Issue.record("\(error)"); return }
        }
    }

    @Test @ThinQActor func retriesConnectionErrorsAndServerErrorsTwice() async throws {
        let transport = ScriptedTransport([
            .failure(ThinQNetworkError("refused", isConnectionError: true)), .success(FakeLG.json([:], status: 503)), .success(FakeLG.json(["ok": true])),
        ])
        let answer = try await client(transport).get("https://x.test/a")
        #expect(answer.data["ok"] == true)
        #expect(transport.sent.withLockedValue { $0.count } == 3)

        let failing = ScriptedTransport([.success(FakeLG.json([:], status: 500)), .success(FakeLG.json([:], status: 500)), .success(FakeLG.json([:], status: 500))])
        await #expect(throws: ThinQError.self) { try await client(failing).get("https://x.test/a") }
        #expect(failing.sent.withLockedValue { $0.count } == 3)

        // DNS failures are not retried.
        let unknown = ScriptedTransport([.failure(ThinQNetworkError("no such host", isConnectionError: false))])
        await #expect(throws: ThinQError.notConnected("no such host")) { try await client(unknown).get("https://x.test/a") }
        #expect(unknown.sent.withLockedValue { $0.count } == 1)
    }

    @Test @ThinQActor func oneRequestAtATime() async throws {
        final class Slow: HTTPSending, @unchecked Sendable {
            let inFlight = NIOLockedValueBox((current: 0, maximum: 0))
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                inFlight.withLockedValue { $0.current += 1; $0.maximum = max($0.maximum, $0.current) }
                try await Task.sleep(for: .milliseconds(20))
                inFlight.withLockedValue { $0.current -= 1 }
                return FakeLG.json([:])
            }
        }
        let slow = Slow()
        let client = RequestClient(transport: slow, logger: testLogger)
        async let a = client.get("https://x.test/1")
        async let b = client.get("https://x.test/2")
        async let c = client.get("https://x.test/3")
        _ = try await (a, b, c)
        #expect(slow.inFlight.withLockedValue { $0.maximum } == 1)
    }
}

@Suite struct AuthTests {
    static let skGateway = Gateway(empTermsURI: "https://sk.emp.lgsmartplatform.com", empSpxURI: "https://sk.m.lgaccount.com/spx",
        thinq2URI: "https://eic-service.lgthinq.com:46030/v1", thinq1URI: "https://eic.lgthinq.com:46030/api", countryCode: "SK", languageCode: "en-SK")

    @ThinQActor
    func auth(_ transport: any HTTPSending, gateway: Gateway = skGateway) -> Auth {
        let client = RequestClient(transport: transport, logger: testLogger)
        client.sleep = { _ in }
        return Auth(gateway: gateway, client: client, logger: testLogger)
    }

    @Test @ThinQActor func derivesTheOAuthBackendFromTheCountry() {
        #expect(auth(ScriptedTransport([])).lgeapiURL == "https://sk.lgeapi.com/")
        let headers = Dictionary(auth(ScriptedTransport([])).defaultEmpHeaders.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        #expect(headers["X-Device-Country"] == "SK" && headers["X-Device-Language"] == "en-SK")
        #expect(headers["User-Agent"] == ThinQConstants.empUserAgent)
    }

    /// The lgemembers.com flow, request by request.
    @Test @ThinQActor func walksTheAccountSignIn() async throws {
        let transport = ScriptedTransport([
            .success(HTTPResponse(status: 200, headers: [("set-cookie", "JSESSIONID=abc")], body: Data("<html/>".utf8))),
            .success(FakeLG.json(["account": ["loginSessionID": "session123", "userID": "testUser", "userIDType": "LGE"]])),
            .success(FakeLG.json(["code": "SUCCESS"], cookies: ["JSESSIONID=def"])),
            .success(FakeLG.json("SUCCESS")),
            .success(FakeLG.json(["redirect_uri": "lgaccount.lgsmartthinq:/?code=theCode&state=signin"])),
            .success(FakeLG.json(["access_token": "accessToken", "refresh_token": "refreshToken", "expires_in": 3600])),
        ])
        let session = try await auth(transport).loginNew(username: "testUser", encryptedPassword: "hashedPassword")
        #expect(session.accessToken == "accessToken" && session.refreshToken == "refreshToken" && session.hasValidToken)
        let sent = transport.sent.withLockedValue { $0 }
        #expect(sent[0].url.absoluteString.hasPrefix("https://sk.lgemembers.com/lgacc/service/v1/signin?callback_url=lgaccount.lgsmartthinq%3A%2F&client_id=LGAO221A02"))
        #expect(sent[1].url.absoluteString.hasSuffix("/lgacc/front/v1/signin/signInAct"))
        #expect(sent[1].bodyText.contains("userPw=hashedPassword"))
        // The encrypted user id is encoded twice, as the Homebridge plugin sends it.
        #expect(sent[1].bodyText.contains("userId=") && sent[1].bodyText.contains("%25"))
        #expect(!sent.contains { $0.url.absoluteString.contains("signInPre") })
        #expect(sent[1].header("Cookie") == "JSESSIONID=abc" && sent[2].header("Cookie") == "JSESSIONID=abc")
        #expect(sent[3].header("Cookie") == "JSESSIONID=def" && sent[4].header("Cookie") == "JSESSIONID=def")
        #expect(sent[4].bodyText.contains("userName=testUser"))
        #expect(sent[5].url.absoluteString == "https://sk.lgeapi.com/oauth/1.0/oauth2/token")
        #expect(sent[5].bodyText == "code=theCode&grant_type=authorization_code&redirect_uri=lgaccount.lgsmartthinq%3A%2F")
        let date = try #require(sent[5].header("x-lge-oauth-date"))
        #expect(sent[5].header("x-lge-oauth-signature") == Auth.signature("/oauth/1.0/oauth2/token?\(sent[5].bodyText)\n\(date)", secret: ThinQConstants.oauthSecretKey))
        #expect(!sent.contains { $0.url.absoluteString.contains("searchKey") })
    }

    @Test @ThinQActor func reportsARejectedAccount() async throws {
        let rejected = ScriptedTransport([.success(FakeLG.json("<html/>")), .success(FakeLG.json(["error": ["code": "MS.001.02", "message": "Wrong password"]]))])
        await #expect(throws: ThinQError.authentication("Wrong password")) { try await auth(rejected).loginNew(username: "u", encryptedPassword: "p") }
        let elsewhere = ScriptedTransport([.success(FakeLG.json("<html/>")), .success(FakeLG.json(["error": ["code": "MS.001.03", "message": "KR"]]))])
        await #expect(throws: ThinQError.authentication("Your account was already used to registered in KR.")) {
            try await auth(elsewhere).loginNew(username: "u", encryptedPassword: "p")
        }
    }

    /// A wrong password does not fall back to the legacy flow; a failure of the new flow does.
    @Test @ThinQActor func fallsBackToTheLegacyFlowOnlyForOtherFailures() async throws {
        let rejected = ScriptedTransport([.success(FakeLG.json("<html/>")), .success(FakeLG.json(["error": ["message": "Wrong password"]]))])
        await #expect(throws: ThinQError.authentication("Wrong password")) { try await auth(rejected).login(username: "u", password: "p") }
        #expect(rejected.sent.withLockedValue { $0.count } == 2)

        let fallback = ScriptedTransport([
            .success(FakeLG.json([:], status: 404)),
            // preLogin, account session, searchKey, authorize, token
            .success(FakeLG.json(["signature": "sig", "tStamp": "ts", "encrypted_pw": "enc"])),
            .success(FakeLG.json(["account": ["userIDType": "EMP", "country": "US", "userID": "testUser", "loginSessionID": "session123"]])),
            .success(FakeLG.json(["returnData": "secret"])),
            .success(FakeLG.json(["status": 1, "redirect_uri": "https://example.com/oauth?code=mockCode&oauth2_backend_url=https%3A%2F%2Fbackend.test%2F"])),
            .success(FakeLG.json(["access_token": "accessToken", "refresh_token": "refreshToken", "expires_in": 3600])),
        ])
        let session = try await auth(fallback, gateway: Gateway(empTermsURI: "https://example.com/emp", empSpxURI: "https://example.com/spx",
            thinq2URI: "https://example.com/thinq2", thinq1URI: "https://example.com/thinq1", countryCode: "US", languageCode: "en-US")).login(username: "testUser", password: "pw")
        #expect(session.refreshToken == "refreshToken")
        let sent = fallback.sent.withLockedValue { $0 }
        #expect(sent[1].url.absoluteString == "https://example.com/spx/preLogin")
        #expect(sent[1].bodyText.hasPrefix("user_auth2=\(Auth.sha512Hex("pw"))"))
        #expect(sent[2].url.absoluteString == "https://example.com/emp/emp/v2.0/account/session/testUser")
        #expect(sent[2].header("X-Signature") == "sig" && sent[2].header("X-Timestamp") == "ts")
        #expect(sent[2].bodyText == "user_auth2=enc&password_hash_prameter_flag=Y&svc_list=SVC202%2CSVC710")
        // LG answers 403 to the secret lookup without the app's User-Agent.
        #expect(sent[3].url.absoluteString.contains("searchKey") && sent[3].header("User-Agent") == ThinQConstants.empUserAgent)
        let date = try #require(sent[4].header("lgemp-x-date"))
        let search = try #require(sent[4].url.query)
        #expect(sent[4].header("lgemp-x-signature") == Auth.signature("/emp/oauth2/authorize/empsession?\(search)\n\(date)", secret: "secret"))
        #expect(sent[5].url.absoluteString == "https://backend.test/oauth/1.0/oauth2/token")
    }

    @Test @ThinQActor func legacyFlowReportsAnAccountError() async throws {
        let transport = ScriptedTransport([
            .success(FakeLG.json(["signature": "s", "tStamp": "t", "encrypted_pw": "e"])),
            .success(FakeLG.json(["error": ["code": "MS.001.03", "message": "Account already registered."]], status: 400)),
        ])
        await #expect(throws: ThinQError.authentication("Your account was already used to registered in Account already registered..")) {
            try await auth(transport).loginStep2(username: "u", encryptedPassword: "p")
        }
    }

    @Test @ThinQActor func refreshesWithTheGatewayBackend() async throws {
        let transport = ScriptedTransport([
            .success(FakeLG.json(["lgedmRoot": ["returnCd": "0000", "oauthUri": "https://us.lgeapi.test"]])),
            .success(FakeLG.json(["access_token": "new", "expires_in": 3600])),
        ])
        let auth = auth(transport)
        let session = try await auth.refreshNewToken(Session(accessToken: "", refreshToken: "refresh me", expiresAt: 0))
        #expect(session.accessToken == "new" && session.refreshToken == "refresh me" && session.hasValidToken)
        let sent = transport.sent.withLockedValue { $0 }
        #expect(sent[1].url.absoluteString == "https://us.lgeapi.test/oauth/1.0/oauth2/token")
        #expect(sent[1].bodyText == "grant_type=refresh_token&refresh_token=refresh%20me")
    }

    @Test @ThinQActor func acceptsNewTerms() async throws {
        let transport = ScriptedTransport([
            .success(HTTPResponse(status: 200, body: Data(#"var x = { signature : "SIG", tStamp : "TS" };"#.utf8))),
            .success(FakeLG.json(["account": ["terms": [["termsID": "1"]]]])),
            .success(FakeLG.json(["info": ["terms": [["termsID": "1", "termsType": "A", "defaultLang": "en"], ["termsID": "2", "termsType": "B", "defaultLang": "en"]]]])),
            .success(FakeLG.json([:])),
        ])
        try await auth(transport).handleNewTerm(accessToken: "token")
        let sent = transport.sent.withLockedValue { $0 }
        #expect(sent.count == 4)
        #expect(sent[3].bodyText == "terms=B%3A2%3Aen")
        #expect(sent[3].header("X-Signature") == "SIG" && sent[3].header("X-Login-Session") == "token")
    }
}

@Suite struct APITests {
    @ThinQActor
    func api(_ lg: FakeLG) async throws -> ThinQAPI {
        let client = RequestClient(transport: lg, logger: testLogger)
        client.sleep = { _ in }
        let api = ThinQAPI(country: "US", language: "en-US", client: client, logger: testLogger)
        try api.setRefreshToken("refresh-1")
        try await api.ready()
        return api
    }

    @Test @ThinQActor func signsInWithTheRefreshToken() async throws {
        let lg = FakeLG()
        let api = try await api(lg)
        #expect(api.session.accessToken == "access-1")
        #expect(api.userNumber == "US2012345678" && api.jsessionID == "jsession-1")
        #expect(api.clientID?.count == 64)
        let headers = Dictionary(api.defaultHeaders.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        #expect(headers["x-emp-token"] == "access-1" && headers["x-user-no"] == "US2012345678" && headers["x-client-id"] == api.clientID)
        #expect(headers["x-api-key"] == ThinQConstants.apiKey && headers["x-message-id"]?.count == 22)
        let monitor = Dictionary(api.monitorHeaders.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        #expect(monitor["x-thinq-token"] == "access-1" && monitor["x-thinq-jsessionId"] == "jsession-1")
    }

    @Test @ThinQActor func refreshesOnceWhenTheTokenExpired() async throws {
        let lg = FakeLG()
        let api = try await api(lg)
        let expired = NIOLockedValueBox(true)
        lg.override("/service/homes") { _ in
            let first = expired.withLockedValue { value in
                defer { value = false }
                return value
            }
            if first { return FakeLG.json(["resultCode": "0102"], status: 400) }
            return FakeLG.json(["result": ["item": [["homeId": "home-1"]]]])
        }
        lg.state.withLockedValue { $0.accessToken = "access-2" }
        let before = lg.state.withLockedValue { $0.refreshCount }
        let homes = await api.listHomes()
        #expect(homes.count == 1)
        #expect(lg.state.withLockedValue { $0.refreshCount } == before + 1)
        #expect(api.session.accessToken == "access-2")
    }

    @Test @ThinQActor func pausesWhenRateLimited() async throws {
        let lg = FakeLG()
        let api = try await api(lg)
        lg.override("/service/homes") { _ in FakeLG.json(["resultCode": "9012"], status: 429) }
        #expect(await api.listHomes().isEmpty)
        #expect(api.isRateLimited)
        let count = lg.requests.count
        _ = await api.getRequest("service/homes")
        #expect(lg.requests.count == count, "no request while cooling down")
    }

    @Test @ThinQActor func resolvesURIs() {
        #expect(ThinQAPI.resolve("service/homes", against: "https://x.test/v1/") == "https://x.test/v1/service/homes")
        #expect(ThinQAPI.resolve("https://common.lgthinq.com/route", against: "https://x.test/v1/") == "https://common.lgthinq.com/route")
    }

    @Test @ThinQActor func readsThinQ1Monitoring() async throws {
        let lg = FakeLG()
        let api = try await api(lg)
        lg.state.withLockedValue { $0.monitorData["dev"] = Data([1, 2, 3]) }
        #expect(try await api.monitorResult(deviceID: "dev", workID: "w") == Data([1, 2, 3]))
        #expect(try await api.monitorResult(deviceID: "other", workID: "w") == nil)
        lg.override("rti/rtiResult") { _ in FakeLG.json(["lgedmRoot": ["returnCd": "0000", "workList": ["returnCode": "0100"]]]) }
        await #expect(throws: ThinQError.self) { try await api.monitorResult(deviceID: "dev", workID: "w") }
        let started = try await api.sendMonitorCommand(deviceID: "dev", cmdOpt: "Start", workID: "w1")
        #expect(started["workId"] == "work-1")
    }
}
