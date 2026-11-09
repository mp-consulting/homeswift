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
    /// The month (`2026-10`) from which they are refused, for as long as it is set.
    let refusedFrom = NIOLockedValueBox<String?>(nil)

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
                let refused = refusedFrom.withLockedValue { $0 }.map { begin >= $0 } ?? false
                guard twoWay, !refused, (json["sn"] as? String)?.hasPrefix("BK") == true, params["sn"] as? String == json["sn"] as? String else {
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

/// The fake cloud, its solar chart's points without their unit: a change in the answer's shape.
final class ReshapedCloud: HTTPSending, Sendable {
    let cloud = FakeCloud()

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let response = try await cloud.send(request)
        let json = try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        guard request.url.path == "/app/commonQuery/query", json?["code"] as? String == EcoFlowHistory.solarCode else { return response }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(String(decoding: response.body, as: UTF8.self).replacingOccurrences(of: #","unit":"wh""#, with: "").utf8))
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
        // The home's use from the balance of the flows (100 + 700 - 5 + 40 - 150), not the Space chart's 400.
        #expect(hours.first?.flows == EnergyFlows(solar: 100, home: 685, gridImport: 700, gridExport: 5, batteryCharge: 150, batteryDischarge: 40))
        #expect(hours.last?.start == local("2026-10-02 11:00:00"))
        #expect(hours.last?.flows == EnergyFlows(solar: 300, home: 885, gridImport: 700, gridExport: 5, batteryCharge: 150, batteryDischarge: 40))

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

    /// Answers of the expected shape report nothing.
    @Test func expectedAnswersReportNoChange() async throws {
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud())
        try await history.hours(serial: nil, since: nil, now: local("2026-10-02 12:30:00"))
        #expect(await history.schemas.drain().isEmpty)
    }

    /// A chart whose answer changed shape is reported once, naming the chart and what changed; the next import, with
    /// the same change, says nothing more.
    @Test func aChangedAnswerIsReportedOnce() async throws {
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: ReshapedCloud())
        try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00"))
        let changes = await history.schemas.drain()
        #expect(changes == ["The EcoFlow answer for app/commonQuery/query solar changed: missing or not as expected: [*].unit"])
        try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00"))
        #expect(await history.schemas.drain().isEmpty, "once")
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
        let changes = await history.schemas.drain()
        #expect(changes.count == 1)
        #expect(changes.first?.contains("did not answer the battery history chart") == true, "a refused chart is said, as a renamed code would be")
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

    @Test func thePluginHandsTheHistoryToTheStreamsMetersAndRemembersWhere() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let received = NIOLockedValueBox<[(MeterID, Int)]>([])
        let observation = host.observeMeterReadings { reading in
            guard case let .history(id, hours, _) = reading else { return }
            received.withLockedValue { $0.append((id, hours.count)) }
        }
        defer { observation.cancel() }
        let cloud = FakeCloud()
        let plugin = try #require(environment.plugin)
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK11", now: local("2026-10-02 12:30:00"))
        // A month at a time, as it arrives, and each Energy Role on the Meter of that role.
        let first = received.withLockedValue { $0 }
        #expect(Set(first.map { $0.0.meter }) == ["solar", "home", "grid", "battery"])
        #expect(first.allSatisfy { $0.0.accessory == "EcoFlow:BK11" })
        // September's 24 hours, then October's 36, on each of the four.
        #expect(Dictionary(grouping: first, by: { $0.0.meter }).mapValues { $0.map { $0.1 } } ==
                ["solar": [24, 36], "home": [24, 36], "grid": [24, 36], "battery": [24, 36]])
        let done = try #require(host.energyImportProgress.first)
        #expect(done.state == .done)
        #expect(done.name == "EcoFlow")
        #expect(done.from == local("2026-09-30 00:00:00"))
        #expect(done.through == local("2026-10-02 12:30:00"))

        // The next import starts two days before the last one ended: from 30 September, so September is asked again.
        received.withLockedValue { $0 = [] }
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK11", now: local("2026-10-02 13:30:00"))
        #expect(Dictionary(grouping: received.withLockedValue { $0 }, by: { $0.0.meter }).mapValues { $0.map { $0.1 } } ==
                ["solar": [24, 37], "home": [24, 37], "grid": [24, 37], "battery": [24, 37]])
        // The history's start is kept across top-ups.
        #expect(host.energyImportProgress.first?.from == local("2026-09-30 00:00:00"))
    }

    /// A bridge that imported the history as the home's flows, before the Meters carried it: the old import is dropped
    /// (the two would be added to one another) and the whole history read again, not just the last days.
    @Test func aHistoryImportedTheOldWayIsDroppedAndReadAgain() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let forgotten = NIOLockedValueBox<[String]>([])
        let observation = host.observeEnergyImports { source, _, forget in
            if forget { forgotten.withLockedValue { $0.append(source) } }
        }
        defer { observation.cancel() }
        let plugin = try #require(environment.plugin)
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        let file = context.jsonFile(EcoFlowPlugin.historyFile, as: EcoFlowPlugin.HistoryState.self)
        // A file of the old kind: imported up to the 2nd, with no `meters`.
        try file.save(EcoFlowPlugin.HistoryState(importedThrough: local("2026-10-02 12:30:00"), from: local("2026-09-30 00:00:00")))
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud()), serial: "BK11", now: local("2026-10-02 13:30:00"))
        #expect(forgotten.withLockedValue { $0 }.count == 1)
        #expect(forgotten.withLockedValue { $0 }.first?.hasPrefix("EcoFlow") == true)
        // Read from the start, not from two days before the old import ended.
        #expect((await plugin.historyStatus).version == EcoFlowPlugin.historyVersion)
        #expect(host.energyImportProgress.first?.from == local("2026-09-30 00:00:00"))

        // The next import is a top-up again: nothing more is dropped.
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud()), serial: "BK11", now: local("2026-10-02 14:30:00"))
        #expect(forgotten.withLockedValue { $0 }.count == 1)
    }

    @Test func theProgressGoesMonthByMonthAndAFailureSaysWhy() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let steps = NIOLockedValueBox<[String]>([])
        let history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud())
        try await history.hours(serial: "BK11", since: nil, now: local("2026-10-02 12:30:00")) { month in
            steps.withLockedValue { $0.append("\(month.serial) \(month.done)/\(month.total):\(month.hours.count)") }
        }
        #expect(steps.withLockedValue { $0 } == ["BK11 0/2:0", "BK11 1/2:24", "BK11 2/2:36"])

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
        let forgotten = NIOLockedValueBox(0)
        let observation = host.observeEnergyImports { _, _, forget in if forget { forgotten.withLockedValue { $0 += 1 } } }
        defer { observation.cancel() }
        let imported = await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: NoStream()), serial: nil)
        #expect(imported, "nothing failed")
        #expect(host.energyImportProgress.isEmpty, "no import to show")
        // What an older version imported (its file lost, or never written) is dropped once, not on every look.
        await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: NoStream()), serial: nil)
        #expect(forgotten.withLockedValue { $0 } == 1)
    }

    /// The STREAM the history went onto is kept and chosen again whatever reports first; when it does change (another
    /// configured), the old one's imported hours go and the whole history is read onto the new one's Meters.
    @Test func theStreamIsKeptAndAnotherOneTakesTheWholeHistory() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let readings = NIOLockedValueBox<[String]>([])
        let observation = host.observeMeterReadings { reading in
            switch reading {
            case let .history(id, hours, _): readings.withLockedValue { $0.append("\(id.accessory)#\(id.meter) \(hours.count)") }
            case let .forgetHistory(id): readings.withLockedValue { $0.append("forget \(id.accessory)#\(id.meter)") }
            default: break
            }
        }
        defer { observation.cancel() }
        let plugin = try #require(environment.plugin)
        let cloud = FakeCloud()
        #expect(await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK11", now: local("2026-10-02 12:30:00")))
        #expect((await plugin.historyStatus).serial == "BK11")
        #expect(await plugin.historySerial(remembered: "BK11") == "BK11")
        #expect(await plugin.historySerial(remembered: nil) == nil, "nothing reported nor configured: the app's list chooses")

        readings.withLockedValue { $0 = [] }
        #expect(await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud), serial: "BK12", now: local("2026-10-02 13:30:00")))
        let after = readings.withLockedValue { $0 }
        #expect(Set(after.filter { $0.hasPrefix("forget") }) == Set(["solar", "home", "grid", "battery"].map { "forget EcoFlow:BK11#\($0)" }))
        // From the start onto the new one: September's 24 hours too, not a top-up's last two days.
        #expect(after.contains("EcoFlow:BK12#home 24"))
        #expect(!after.contains { $0.hasPrefix("EcoFlow:BK11#") && !$0.hasPrefix("forget") })
        #expect((await plugin.historyStatus).serial == "BK12")
        #expect((await plugin.historyStatus).importedThrough == local("2026-10-02 13:30:00"))
    }

    /// The history goes onto the Meters of the STREAM unit whose live readings carry the system's flows, which record
    /// them live: on the author's Ultra and AC Pro, the AC Pro. A history kept on the Ultra (whose flows read 0) is
    /// dropped from its Meters and read again onto the AC Pro's, once: otherwise each hour counts on both.
    @Test func theHistoryGoesOntoTheUnitThatCarriesTheSystemsFlows() async throws {
        let environment = TestEnvironment()
        var ultra = EcoFlowDevice(id: "BK11-ULTRA", name: "STREAM Ultra", online: true, model: EcoFlowModel.model(serial: "BK11-ULTRA"))
        ultra.state = EcoFlowState(soc: 26, power: EcoFlowState.Power())
        var acPro = EcoFlowDevice(id: "BK31-ACPRO", name: "STREAM AC Pro", online: true, model: EcoFlowModel.model(serial: "BK31-ACPRO"))
        acPro.state = EcoFlowState(soc: 40, power: EcoFlowState.Power(solar: 409, home: 1296, grid: 970, battery: 83))
        await environment.api.add(ultra)
        await environment.api.add(acPro)
        let host = try await environment.start(settings: ["devices": [["id": "BK11-ULTRA"], ["id": "BK31-ACPRO"]]])
        defer { Task { await host.stop() } }
        let readings = NIOLockedValueBox<[String]>([])
        let observation = host.observeMeterReadings { reading in
            switch reading {
            case let .history(id, hours, _): readings.withLockedValue { $0.append("\(id.accessory)#\(id.meter) \(hours.count)") }
            case let .forgetHistory(id): readings.withLockedValue { $0.append("forget \(id.accessory)#\(id.meter)") }
            default: break
            }
        }
        defer { observation.cancel() }
        let plugin = try #require(environment.plugin)
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        let file = context.jsonFile(EcoFlowPlugin.historyFile, as: EcoFlowPlugin.HistoryState.self)
        // What 0.26.0 kept: the history on the Ultra's Meters, the one the configuration names first.
        try file.save(EcoFlowPlugin.HistoryState(importedThrough: local("2026-10-02 12:30:00"), from: local("2026-09-30 00:00:00"),
                                                 version: 2, serial: "BK11-ULTRA"))
        await plugin.refresh()
        let serial = await plugin.historySerial(remembered: "BK11-ULTRA")
        #expect(serial == "BK31-ACPRO", "the unit that carries the flows, whatever was remembered or named")

        #expect(await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud()),
                                           serial: serial, now: local("2026-10-02 13:30:00")))
        let after = readings.withLockedValue { $0 }
        #expect(Set(after.filter { $0.hasPrefix("forget") }) == Set(["solar", "home", "grid", "battery"].map { "forget EcoFlow:BK11-ULTRA#\($0)" }))
        #expect(!after.contains { $0.hasPrefix("EcoFlow:BK11-ULTRA#") }, "nothing imported onto the Ultra")
        // The whole history, from September, onto the AC Pro's Meters.
        #expect(after.contains("EcoFlow:BK31-ACPRO#home 24"))
        #expect((await plugin.historyStatus).serial == "BK31-ACPRO")
        #expect((await plugin.historyStatus).version == EcoFlowPlugin.historyVersion)

        // Kept while it carries them; a moment when no unit reports keeps it too.
        #expect(await plugin.historySerial(remembered: "BK31-ACPRO") == "BK31-ACPRO")
        await environment.api.update(deviceID: "BK31-ACPRO") { $0.power = EcoFlowState.Power() }
        await plugin.refresh()
        #expect(await plugin.historySerial(remembered: "BK31-ACPRO") == "BK31-ACPRO")
    }

    @Test func aBalancedHourKeepsTheChartsHomeWithoutTheGridAndBattery() {
        #expect(EcoFlowHistory.balanced(EnergyFlows(solar: 411, home: 973, gridImport: 962, gridExport: 0, batteryCharge: 76, batteryDischarge: 31))
                == EnergyFlows(solar: 411, home: 1328, gridImport: 962, gridExport: 0, batteryCharge: 76, batteryDischarge: 31))
        #expect(EcoFlowHistory.balanced(EnergyFlows(solar: 411, home: 973)) == EnergyFlows(solar: 411, home: 973))
        // Never below zero: the charts' rounding.
        #expect(EcoFlowHistory.balanced(EnergyFlows(solar: 0, gridImport: 0, batteryCharge: 3)).home == 0)
    }

    /// An Excluded STREAM has no Meters made for its history, chosen neither by the plugin nor from the app's list.
    @Test func anExcludedStreamIsNeverTheHistorys() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: ["devices": [["id": "BK11-STREAM"]], "_accessories": ["BK11-STREAM": ["excluded": true]]])
        defer { Task { await host.stop() } }
        let made = NIOLockedValueBox(0)
        let observation = host.observeMeterReadings { reading in if case .history = reading { made.withLockedValue { $0 += 1 } } }
        defer { observation.cancel() }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.historySerial(remembered: "BK11-STREAM") == nil)
        #expect(await plugin.importHistory(EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud()), serial: nil, now: local("2026-10-02 12:30:00")))
        #expect(made.withLockedValue { $0 } == 0)
        #expect(host.energyImportProgress.isEmpty)
    }

    /// The battery and grid charts refused part way through a full import: the months before are kept and the import
    /// is not done, so the next one goes on from the refused month rather than from the start or not at all.
    @Test func aRefusedChartLeavesTheImportToGoOnFromThatMonth() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let forgotten = NIOLockedValueBox(0)
        let observation = host.observeEnergyImports { _, _, forget in if forget { forgotten.withLockedValue { $0 += 1 } } }
        defer { observation.cancel() }
        let plugin = try #require(environment.plugin)
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        let file = context.jsonFile(EcoFlowPlugin.historyFile, as: EcoFlowPlugin.HistoryState.self)
        // A file of the first version, whose import is dropped before the new one.
        try file.save(EcoFlowPlugin.HistoryState(importedThrough: local("2026-10-02 12:30:00"), from: local("2026-09-30 00:00:00")))
        let cloud = FakeCloud()
        cloud.refusedFrom.withLockedValue { $0 = "2026-10" }
        var history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: cloud)
        history.retryDelays = []
        #expect(await plugin.importHistory(history, serial: "BK11", now: local("2026-10-02 13:30:00")) == false)
        let stopped = await plugin.historyStatus
        #expect(stopped.importedThrough == nil, "not done")
        #expect(stopped.resumeFrom == local("2026-10-01 00:00:00"))
        #expect(stopped.twoWay == true && stopped.refusals == 1, "September answered")
        #expect(host.energyImportProgress.first?.state == .failed)

        cloud.refusedFrom.withLockedValue { $0 = nil }
        cloud.requests.withLockedValue { $0 = [] }
        #expect(await plugin.importHistory(history, serial: "BK11", now: local("2026-10-02 14:30:00")))
        // October alone was asked again, and the old import was dropped only the once.
        let begins = cloud.requests.withLockedValue { $0 }.compactMap { request -> String? in
            guard request.url.path == "/app/commonQuery/query", let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return (json["params"] as? [String: Any])?["beginTime"] as? String
        }
        #expect(!begins.isEmpty && begins.allSatisfy { $0.hasPrefix("2026-10") })
        #expect(forgotten.withLockedValue { $0 } == 1)
        let done = await plugin.historyStatus
        #expect(done.importedThrough == local("2026-10-02 14:30:00") && done.resumeFrom == nil)
        #expect(done.twoWay == true && done.refusals == nil)
        #expect(done.from == local("2026-09-30 00:00:00"))
    }

    /// A system whose cloud never answers the battery and grid charts: a few imports try them again, then the history
    /// goes on without them and the top-ups that follow do not stop at them.
    @Test func chartsThatNeverAnswerAreGivenUpAfterAFewImports() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        var history = EcoFlowHistory(email: "me@example.test", password: "secret", transport: FakeCloud(twoWay: false))
        history.retryDelays = []
        for _ in 0..<EcoFlowPlugin.historyRefusals {
            #expect(await plugin.importHistory(history, serial: "BK11", now: local("2026-10-02 13:30:00")) == false)
        }
        #expect(await plugin.importHistory(history, serial: "BK11", now: local("2026-10-02 13:30:00")))
        #expect((await plugin.historyStatus).twoWay == false)
        #expect(await plugin.importHistory(history, serial: "BK11", now: local("2026-10-02 14:30:00")))
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
