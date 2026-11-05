import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import Testing

@testable import HomeswiftShelly

/// Shelly Cloud's history of a relay (unofficial): the sign-in (email and password, a token naming the account's server),
/// the day asked with the token, how an answer is read (hours in the cloud's time zone, a missing hour left out), and what
/// a refusal or another shape gives.
@Suite(.timeLimit(.minutes(1)))
struct ShellyCloudTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    let credentials = ShellyCloudCredentials(email: "Me@Example.com", password: "s3cret")

    /// A JWT whose claims name the server and an expiry an hour on (no signature: the client does not check one).
    func token(server: String = "https://shelly-238-eu.shelly.cloud", expires: Date = Date().addingTimeInterval(3600)) -> String {
        let claims = #"{"user_api_url":"\#(server)","exp":\#(Int(expires.timeIntervalSince1970))}"#
        let encoded = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
    }

    @Test func signsInThenAsksADayWithTheToken() async throws {
        let http = FakeHTTP()
        http.answer("/v2/users/auth/login", #"{"accessToken":"\#(token())","refreshToken":"r"}"#)
        http.answer("/v2/statistics/power-consumption", #"{"timezone":"Europe/Paris","history":[{"datetime":"2026-11-04 13:00:00","consumption":12.5,"reversed":0},{"datetime":"2026-11-04 14:00:00","consumption":0,"missing":true},{"datetime":"2026-11-04 15:00:00","consumption":3}]}"#)
        let cloud = ShellyCloud(credentials: credentials, http: http, logger: Logger(label: "test"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)))
        let answer = await cloud.consumption(id: "e4b3233864a8", channel: 0, day: day, timeZone: paris)
        guard case .hours(let hours) = answer else { Issue.record("no hours: \(answer)"); return }
        #expect(hours.map(\.consumption) == [12.5, 3])
        #expect(hours.first?.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 13)))

        let login = try #require(http.requests.first)
        #expect(login.method == "POST" && login.url.absoluteString == "https://api2.shelly.cloud/v2/users/auth/login")
        let body = try JSONValue(data: login.body ?? Data())
        // The password's SHA-1 in hex, never the password.
        #expect(body["email"] == "me@example.com" && body["password"] == .string(TextDigest.sha1("s3cret")))
        #expect(TextDigest.sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(!(login.body.map { String(decoding: $0, as: UTF8.self) } ?? "").contains("s3cret"))
        let ask = try #require(http.requests.last)
        #expect(ask.method == "GET" && ask.url.host == "shelly-238-eu.shelly.cloud" && ask.url.path == "/v2/statistics/power-consumption")
        #expect(ask.headers.contains { $0.name == "Authorization" && $0.value == "Bearer \(token())" })
        let query = ask.url.query ?? ""
        #expect(query.contains("id=e4b3233864a8") && query.contains("channel=0") && query.contains("date_range=custom"))
        #expect(query.contains("date_from=2026-11-04+00%3A00%3A00") && query.contains("date_to=2026-11-04+23%3A59%3A59"))
        #expect(!query.contains("s3cret") && !query.contains("auth"))

        // The next day keeps the token: one sign-in.
        _ = await cloud.consumption(id: "e4b3233864a8", channel: 0, day: day.addingTimeInterval(86_400), timeZone: paris)
        #expect(http.requests.filter { $0.url.path == "/v2/users/auth/login" }.count == 1)
    }

    @Test func aRefusedSignInOrAnotherShapeIsSaid() async {
        let logger = Logger(label: "test")
        let http = FakeHTTP()
        http.answer("/v2/users/auth/login", status: 401, #"{"errors":{"wrong_credentials":"Wrong credentials"}}"#)
        let cloud = ShellyCloud(credentials: credentials, http: http, logger: logger)
        #expect(await cloud.signIn() == .refused)
        #expect(await cloud.consumption(id: "x", channel: 0, day: Date(), timeZone: paris) == .refused)
        #expect(ShellyCloud.answer(["isok": false, "errors": ["unauthorized": "Unauthorized"]], timeZone: paris, logger: logger) == .refused)
        #expect(ShellyCloud.answer(["isok": true, "data": ["other": 1]], timeZone: paris, logger: logger) == .nothing)
        #expect(ShellyCloud.answer(["isok": true, "data": ["history": [["datetime": "2026-11-04 01:00:00", "consumption": 2]]]], timeZone: paris, logger: logger) != .nothing)
        #expect(ShellyCloud.claims(of: "not.a.jwt") == nil)
    }
}
