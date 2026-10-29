import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftEcoFlow

/// The EcoFlow cloud's answers as the probe of the app's API found them, keyed by path; a chart's by its code.
final class FakeCloud: HTTPSending, Sendable {
    let requests = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])
    /// Whether the system's battery and grid charts answer; refused ("query fail") otherwise.
    let twoWay: Bool

    init(twoWay: Bool = true) { self.twoWay = twoWay }

    static func hourly(_ day: String, _ values: [Double]) -> String {
        values.enumerated().map { #"{"indexName":"chart_data","indexValue":\#($0.element),"time":"\#(day) \#(String(format: "%02d", $0.offset)):00:00","unit":"wh"}"# }.joined(separator: ",")
    }

    /// A two-way chart's points, as the battery and grid charts send them: the value as text, `extra` the direction.
    static func twoWayHourly(_ day: String, count: Int, _ first: Int, _ second: Int) -> String {
        (0..<count).flatMap { hour in
            [("1", first), ("2", second)].map { extra, value in
                #"{"unit":"wh","indexName":"chart_data","extra":"\#(extra)","time":"\#(day) \#(String(format: "%02d", hour)):00:00","indexValue":"\#(value)"}"#
            }
        }.joined(separator: ",")
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        requests.withLockedValue { $0.append(request) }
        let path = request.url.path
        let body: String
        switch path {
        case "/auth/login": body = #"{"code":"0","message":"Success","data":{"token":"T0KEN","user":{"userId":"1"}}}"#
        case "/app/space/getSpaceInfoBySn":
            body = #"{"code":"0","data":{"spaceId":"S1","rootSpaceId":"S1","properties":[{"key":"address","value":"1 Demo Street"},{"key":"timezone","value":"Europe/Lisbon"}]}}"#
        case "/app/user/device/list": body = #"{"code":"0","data":[{"sn":"R655-RIVER"},{"sn":"BK11-STREAM"}]}"#
        case "/app/space/system/list": body = #"{"code":"0","data":{"systemList":[{"systemNo":"N1","createTime":"2026-09-30 10:00:00"}]}}"#
        case "/app/commonQuery/query":
            let json = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
            let params = json["params"] as? [String: Any] ?? [:]
            let begin = params["beginTime"] as? String ?? ""
            let code = json["code"] as? String
            if code == EcoFlowHistory.batteryCode || code == EcoFlowHistory.gridCode {
                guard twoWay, (json["sn"] as? String)?.hasPrefix("BK11") == true, params["sn"] as? String == json["sn"] as? String else {
                    body = #"{"code":"1","message":"query fail"}"#
                    break
                }
                let (first, second) = code == EcoFlowHistory.batteryCode ? (150, 40) : (700, 5)
                let points = begin.hasPrefix("2026-09") ? Self.twoWayHourly("2026-09-30", count: 24, first, second)
                    : Self.twoWayHourly("2026-10-01", count: 24, first, second) + "," + Self.twoWayHourly("2026-10-02", count: 13, first, second)
                body = #"{"code":"0","data":[\#(points)]}"#
                break
            }
            let solar = code == EcoFlowHistory.solarCode
            // September: one day; October: the 1st and the 2nd, the 2nd under way.
            let points = begin.hasPrefix("2026-09") ? Self.hourly("2026-09-30", Array(repeating: solar ? 100 : 400, count: 24))
                : Self.hourly("2026-10-01", Array(repeating: solar ? 200 : 500, count: 24)) + "," + Self.hourly("2026-10-02", Array(repeating: solar ? 300 : 600, count: 13))
            body = #"{"code":"0","data":[\#(points)]}"#
        default: return HomeswiftNetwork.HTTPResponse(status: 404)
        }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

/// The fake cloud, refusing the first chart with the cloud's "Server error".
final class FlakyCloud: HTTPSending, Sendable {
    let cloud = FakeCloud()
    /// The charts asked for, the refused one included.
    let charts = NIOLockedValueBox(0)

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let first = request.url.path == "/app/commonQuery/query" && charts.withLockedValue { count in
            defer { count += 1 }
            return count == 0
        }
        if first { return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(#"{"code":"500","message":"Server error"}"#.utf8)) }
        return try await cloud.send(request)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowHistoryTests {
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    func local(_ text: String) -> Date { EcoFlowHistory.formatter(lisbon).date(from: text)! }

    @Test func theHistoryIsEachWholeHourSinceTheSystemWasSetUp() async throws {
        let cloud = FakeCloud()
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud)
        // 2 October, 12:30 in Lisbon: the 12:00 hour is under way.
        let hours = try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00"))
        #expect(hours.count == 24 + 24 + 12)
        #expect(hours.first?.start == local("2026-09-30 00:00:00"))
        #expect(hours.first?.flows == EnergyFlows(solar: 100, home: 400, gridImport: 700, gridExport: 5, batteryCharge: 150, batteryDischarge: 40))
        #expect(hours.last?.start == local("2026-10-02 11:00:00"))
        #expect(hours.last?.flows == EnergyFlows(solar: 300, home: 600, gridImport: 700, gridExport: 5, batteryCharge: 150, batteryDischarge: 40))

        let requests = cloud.requests.withLockedValue { $0 }
        // One sign-in without the app's headers, then the space, the system and per month the solar, home, battery and
        // grid charts.
        #expect(requests.map(\.url.path) == ["/auth/login", "/app/space/getSpaceInfoBySn", "/app/space/system/list"] + Array(repeating: "/app/commonQuery/query", count: 8))
        #expect(requests[0].headers.contains { $0.name == "lang" } == false)
        #expect(requests[1].headers.contains { $0.name == "lang" && $0.value == "en_US" })
        #expect(requests[1].headers.contains { $0.name == "Authorization" && $0.value == "Bearer T0KEN" })
        let first = try #require(try JSONSerialization.jsonObject(with: requests[3].body ?? Data()) as? [String: Any])
        #expect(first["code"] as? String == EcoFlowHistory.solarCode)
        #expect((first["params"] as? [String: String]) == ["spaceId": "S1", "rootSpaceId": "S1", "beginTime": "2026-09-01 00:00:00", "endTime": "2026-09-30 23:59:59"])
    }

    /// A system whose cloud refuses the battery and grid charts keeps its solar and home history, and is not asked for
    /// them again month after month.
    @Test func aSystemWithoutBatteryChartsKeepsSolarAndHome() async throws {
        let cloud = FakeCloud(twoWay: false)
        var history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud)
        history.retryDelays = []
        let hours = try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00"))
        #expect(hours.count == 24 + 24 + 12)
        #expect(hours.first?.flows == EnergyFlows(solar: 100, home: 400))
        let queries = cloud.requests.withLockedValue { $0 }.filter { $0.url.path == "/app/commonQuery/query" }
        #expect(queries.count == 4 + 1, "solar and home for two months, and the battery chart once")
    }

    /// Without a serial number, the account's first STREAM in the app's device list is the history's.
    @Test func theStreamComesFromTheDeviceListWhenNoneIsKnown() async throws {
        let cloud = FakeCloud()
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud)
        let hours = try await history.hours(serial: nil, since: nil, now: local("2026-10-02 12:30:00"))
        #expect(hours.count == 24 + 24 + 12)
        let space = try #require(cloud.requests.withLockedValue { $0 }.first { $0.url.path == "/app/space/getSpaceInfoBySn" })
        #expect(space.url.query == "sn=BK11-STREAM")
    }

    /// A chart the cloud refuses once ("Server error") is asked for again: the import goes on.
    @Test func aRefusedChartIsAskedAgain() async throws {
        let cloud = FlakyCloud()
        var history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud)
        history.retryDelays = [.zero]
        let hours = try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00"))
        #expect(hours.count == 24 + 24 + 12)
        #expect(cloud.charts.withLockedValue { $0 } == 8 + 1, "four charts a month, and the refused one again")
    }

    @Test func aTopUpStartsTheDayOfItsSince() async throws {
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud())
        let hours = try await history.hours(serial: "BK11", since: local("2026-10-01 18:00:00"), now: local("2026-10-02 12:30:00"))
        #expect(hours.first?.start == local("2026-10-01 00:00:00"))
        #expect(hours.count == 24 + 12)
    }

    @Test func pointsReadWattHoursAndSkipTheRest() {
        let format = EcoFlowHistory.formatter(lisbon)
        let points = EcoFlowHistory.points([
            ["indexName": "chart_data", "indexValue": 731.5, "time": "2026-10-26 08:00:00", "unit": "wh"],
            ["indexName": "chart_data", "indexValue": 1.2, "time": "2026-10-26 09:00:00", "unit": "kWh"],
            ["indexName": "master_data", "indexValue": 11630, "unit": "wh"],
            ["indexName": "chart_data", "time": "2026-10-26 10:00:00"],
        ], format: format)
        #expect(points.map(\.1) == [731.5, 1200])
        #expect(points.first?.0 == local("2026-10-26 08:00:00"))
    }

    @Test func thePluginHandsTheHistoryToTheArchiveAndRemembersWhere() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let received = NIOLockedValueBox<[(String, Int)]>([])
        let observation = host.observeEnergyImports { source, hours in received.withLockedValue { $0.append((source, hours.count)) } }
        defer { observation.cancel() }
        let cloud = FakeCloud()
        let plugin = try #require(environment.plugin)
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK11", now: local("2026-10-02 12:30:00"))
        // A month at a time, as it arrives.
        #expect(received.withLockedValue { $0.map(\.1) } == [24, 36])
        #expect(received.withLockedValue { $0.first?.0 }?.hasPrefix("EcoFlow") == true)
        let done = try #require(host.energyImportProgress.first)
        #expect(done.state == .done)
        #expect(done.name == "EcoFlow")
        #expect(done.from == local("2026-09-30 00:00:00"))
        #expect(done.through == local("2026-10-02 12:30:00"))

        // The next import starts two days before the last one ended: from 30 September, so September is asked again.
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK11", now: local("2026-10-02 13:30:00"))
        #expect(received.withLockedValue { $0.map(\.1) } == [24, 36, 24, 37])
        // The history's start is kept across top-ups.
        #expect(host.energyImportProgress.first?.from == local("2026-09-30 00:00:00"))
    }

    @Test func theProgressGoesMonthByMonthAndAFailureSaysWhy() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let steps = NIOLockedValueBox<[String]>([])
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud())
        try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00")) { batch, done, total in
            steps.withLockedValue { $0.append("\(done)/\(total):\(batch.count)") }
        }
        #expect(steps.withLockedValue { $0 } == ["0/2:0", "1/2:24", "2/2:36"])

        final class Refusing: HTTPSending, Sendable {
            func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
                HomeswiftNetwork.HTTPResponse(status: 200, body: Data(#"{"code":"1001","message":"wrong password"}"#.utf8))
            }
        }
        let plugin = try #require(environment.plugin)
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "nope", transport: Refusing()), serial: "BK11")
        let failed = try #require(host.energyImportProgress.first)
        #expect(failed.state == .failed)
        #expect(failed.message?.contains("wrong password") == true)
    }

    /// An account without a STREAM has no history: the import reports nothing, fails nothing, and waits the usual
    /// interval rather than trying again in minutes.
    @Test func anAccountWithoutAStreamHasNothingToImport() async throws {
        final class NoStream: HTTPSending, Sendable {
            func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
                let body = request.url.path == "/auth/login" ? #"{"code":"0","data":{"token":"T","user":{"userId":"1"}}}"#
                    : #"{"code":"0","data":[{"sn":"R655-RIVER"}]}"#
                return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(body.utf8))
            }
        }
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let imported = await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: NoStream()), serial: nil)
        #expect(imported, "nothing failed")
        #expect(host.energyImportProgress.isEmpty, "no import to show")
    }

    @Test func aRefusedSignInSaysSo() async {
        final class Refusing: HTTPSending, Sendable {
            func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
                HomeswiftNetwork.HTTPResponse(status: 200, body: Data(#"{"code":"1001","message":"wrong password"}"#.utf8))
            }
        }
        let history = EcoFlowHistory(email: "me@example.test", password: "nope", transport: Refusing())
        await #expect(throws: EcoFlowHistory.Failure.self) { try await history.hours(serial: "BK11", since: nil) }
    }
}
