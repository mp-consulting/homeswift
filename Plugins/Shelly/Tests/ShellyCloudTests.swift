import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import Testing

@testable import HomeswiftShelly

/// Shelly Cloud's history of a relay (unofficial): what is asked (the key in the body, never the address), how an answer
/// is read (hours in the cloud's time zone, a missing hour left out), and what a refusal or another shape gives.
@Suite(.timeLimit(.minutes(1)))
struct ShellyCloudTests {
    let paris = TimeZone(identifier: "Europe/Paris")!

    @Test func asksADayAndReadsItsHours() async throws {
        let http = FakeHTTP()
        http.answer("/statistics/relay/consumption", #"{"isok":true,"data":{"timezone":"Europe/Paris","history":[{"datetime":"2026-11-04 13:00:00","consumption":12.5,"reversed":0},{"datetime":"2026-11-04 14:00:00","consumption":0,"missing":true},{"datetime":"2026-11-04 15:00:00","consumption":3}]}}"#)
        let cloud = ShellyCloud(credentials: ShellyCloudCredentials(server: "shelly-238-eu.shelly.cloud", authKey: "SECRET+KEY"), http: http, logger: Logger(label: "test"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)))
        let answer = await cloud.consumption(id: "e4b3233864a8", channel: 0, day: day, timeZone: paris)
        guard case .hours(let hours) = answer else { Issue.record("no hours: \(answer)"); return }
        #expect(hours.map(\.consumption) == [12.5, 3])
        #expect(hours.first?.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 13)))
        #expect(hours.first?.returned == 0 && hours.last?.returned == nil)

        let request = try #require(http.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://shelly-238-eu.shelly.cloud/statistics/relay/consumption")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("id=e4b3233864a8") && body.contains("channel=0") && body.contains("date_range=custom"))
        #expect(body.contains("date_from=2026-11-04+00%3A00%3A00") && body.contains("date_to=2026-11-04+23%3A59%3A59"))
        #expect(body.contains("auth_key=SECRET%2BKEY"))
    }

    @Test func aRefusalOrAnotherShapeIsNoHistory() async {
        let logger = Logger(label: "test")
        #expect(ShellyCloud.answer(["isok": false, "errors": ["unauthorized": "Unauthorized"]], timeZone: paris, logger: logger) == .refused)
        #expect(ShellyCloud.answer(["isok": false, "errors": ["wrong_id": "No device"]], timeZone: paris, logger: logger) == .nothing)
        #expect(ShellyCloud.answer(["isok": true, "data": ["other": 1]], timeZone: paris, logger: logger) == .nothing)
        let http = FakeHTTP()
        http.answer("/statistics/relay/consumption", status: 401, "{}")
        let cloud = ShellyCloud(credentials: ShellyCloudCredentials(server: "https://example.shelly.cloud/", authKey: "k"), http: http, logger: logger)
        #expect(await cloud.consumption(id: "x", channel: 0, day: Date(), timeZone: paris) == .refused)
        #expect(ShellyCloud(credentials: ShellyCloudCredentials(server: " ", authKey: "k"), http: http, logger: logger).base == nil)
    }
}
