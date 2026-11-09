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
    /// An hour from the run's start, the same for every token made: a test that compares the token it answered with the one
    /// sent would see two different ones when a second ticked between them.
    static let anHourAhead = Date().addingTimeInterval(3600)

    func token(server: String = "https://shelly-238-eu.shelly.cloud", expires: Date = Self.anHourAhead) -> String {
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

    /// An energy meter's answer, a list per phase, is added up by hour.
    @Test func anEnergyMetersPhasesAddUp() {
        let json: JSONValue = ["history": [
            [["datetime": "2026-11-04 13:00:00", "consumption": 100, "reversed": 1], ["datetime": "2026-11-04 14:00:00", "consumption": 10]],
            [["datetime": "2026-11-04 13:00:00", "consumption": 200, "reversed": 2]],
            [["datetime": "2026-11-04 13:00:00", "consumption": 300]],
        ], "timezone": "Europe/Paris"]
        guard case .hours(let hours) = ShellyCloud.answer(json, timeZone: paris, logger: Logger(label: "test")) else { Issue.record("no hours"); return }
        #expect(hours.map(\.consumption) == [600, 10])
        #expect(hours.first?.returned == 3)
    }

    /// A week asked at once is taken when it comes by hour, and refused (to be asked a day at a time) when by day.
    @Test func aWeekIsTakenOnlyByTheHour() async throws {
        let http = FakeHTTP()
        http.answer("/v2/users/auth/login", #"{"accessToken":"\#(token())"}"#)
        http.answer("/v2/statistics/power-consumption", #"{"interval":"day","history":[{"datetime":"2026-11-01 00:00:00","consumption":120}]}"#)
        let cloud = ShellyCloud(credentials: credentials, http: http, logger: Logger(label: "test"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30)))
        #expect(await cloud.consumption(id: "x", channel: 0, day: first, days: 7, timeZone: paris) == .notHourly)
        let query = http.requests.last?.url.query ?? ""
        #expect(query.contains("date_from=2026-10-30+00%3A00%3A00") && query.contains("date_to=2026-11-05+23%3A59%3A59"))

        http.answer("/v2/statistics/power-consumption", #"{"interval":"hour","history":[{"datetime":"2026-10-30 01:00:00","consumption":1},{"datetime":"2026-11-05 23:00:00","consumption":2}]}"#)
        guard case .hours(let hours) = await cloud.consumption(id: "x", channel: 0, day: first, days: 7, timeZone: paris) else { Issue.record("no hours"); return }
        #expect(hours.count == 2)
    }
    /// The names the Shelly app keeps in the cloud: asked with the token, read by device and channel, "unnamed" left out.
    @Test func theDevicesNamesComeFromTheAppsList() async throws {
        let http = FakeHTTP()
        http.answer("/v2/users/auth/login", #"{"accessToken":"\#(token())"}"#)
        http.answer("/interface/device/get_all_lists", #"{"isok":true,"data":{"devices":{"e4b3233864a8":{"id":"e4b3233864a8","name":"Smart Plug","channel":0,"type":"PlugSG3EF","category":"relay"},"ece334eb13f8_1":{"id":"ece334eb13f8_1","name":"Garage","channel":1},"aabbccddeeff":{"id":"AABBCCDDEEFF","name":"unnamed"}},"rooms":{}}}"#)
        let cloud = ShellyCloud(credentials: credentials, http: http, logger: Logger(label: "test"))
        #expect(await cloud.deviceNames() == ["e4b3233864a8": "Smart Plug", "ece334eb13f8_1": "Garage"])
        let ask = try #require(http.requests.last)
        #expect(ask.method == "POST" && ask.url.host == "shelly-238-eu.shelly.cloud" && ask.url.path == "/interface/device/get_all_lists")
        #expect(ask.headers.contains { $0.name == "Authorization" && $0.value == "Bearer \(token())" })
        #expect(ShellyCloud.names(["isok": false]) == [:])
    }
    /// A few hours of a device that was offline, over three days and without the step named, are hours, not days.
    @Test func aFewHoursAreHoursStill() async throws {
        let http = FakeHTTP()
        http.answer("/v2/users/auth/login", #"{"accessToken":"\#(token())"}"#)
        http.answer("/v2/statistics/power-consumption", #"{"timezone":"Europe/Paris","history":[{"datetime":"2026-11-04 13:00:00","consumption":5},{"datetime":"2026-11-04 14:00:00","consumption":6}]}"#)
        let cloud = ShellyCloud(credentials: credentials, http: http, logger: Logger(label: "test"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        guard case .hours(let hours) = await cloud.consumption(id: "x", channel: 0, day: first, days: 3, timeZone: paris) else { Issue.record("not hours"); return }
        #expect(hours.count == 2)
        // One a day at midnight is by day.
        http.answer("/v2/statistics/power-consumption", #"{"timezone":"Europe/Paris","history":[{"datetime":"2026-11-02 00:00:00","consumption":500},{"datetime":"2026-11-03 00:00:00","consumption":600}]}"#)
        #expect(await cloud.consumption(id: "x", channel: 0, day: first, days: 3, timeZone: paris) == .notHourly)
    }
}
