import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The Energy section: readings tagged with a role, added up across devices (a shared figure once), and each day's
/// kWh from the per-minute averages.
@Suite(.timeLimit(.minutes(1)))
struct EnergyTests {
    /// 2027-01-15 08:00 UTC, a whole minute.
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    /// A metrics store at `start` plus `offset`, and a way to move its clock.
    func store(_ directory: URL? = nil) -> (Metrics, NIOLockedValueBox<Date>) {
        let clock = NIOLockedValueBox(start.addingTimeInterval(5))
        return (Metrics(directory: directory, now: { clock.withLockedValue { $0 } }), clock)
    }

    /// `watts` for each series, in each of `minutes` minutes from the clock's minute on; the clock ends in the minute after.
    func record(_ metrics: Metrics, _ clock: NIOLockedValueBox<Date>, minutes: Int, _ watts: [String: Double]) {
        for _ in 0..<minutes {
            for (series, value) in watts { metrics.record(value, series: series) }
            clock.withLockedValue { $0 = $0.addingTimeInterval(60) }
        }
        // Closes the last minute.
        metrics.record(0, series: "plugin:Test:untagged")
    }

    @Test func aMinuteIsItsAverageForASixtiethOfAnHour() {
        var day = EnergyDay(start: start)
        for _ in 0..<60 { day.add([.solar: 1200, .home: 800, .grid: -300, .battery: 100]) }
        for _ in 0..<30 { day.add([.solar: 0, .home: 1000, .grid: 1000, .battery: -500]) }
        #expect(day.minutes == 90)
        #expect(abs(day.solar - 1.2) < 1e-9)
        #expect(abs(day.home - 1.3) < 1e-9)
        #expect(abs(day.gridImport - 0.5) < 1e-9)
        #expect(abs(day.gridExport - 0.3) < 1e-9)
        #expect(abs(day.batteryCharge - 0.1) < 1e-9)
        #expect(abs(day.batteryDischarge - 0.25) < 1e-9)
        // The first hour solar covered the home's 0.8 kWh; the half hour after, nothing.
        #expect(abs(day.homeFromSolar - 0.8) < 1e-9)
        #expect(abs((day.solarShare ?? 0) - 0.8 / 1.3) < 1e-9)
        #expect(EnergyDay(start: start).solarShare == nil)
    }

    @Test func devicesAddUpAndASharedFigureCountsOnce() {
        let tags: [String: EnergyTag] = [
            "a:solar": EnergyTag(role: .solar, device: "A"), "b:solar": EnergyTag(role: .solar, device: "B"),
            "a:home": EnergyTag(role: .home, device: "A", shared: "system"), "b:home": EnergyTag(role: .home, device: "B", shared: "system"),
            "c:home": EnergyTag(role: .home, device: "C"), "a:level": EnergyTag(role: .batteryLevel, device: "A"),
        ]
        let values: [String: Metrics.Values] = [
            "a:solar": .init(count: 2, sum: 600, low: 200, high: 400), "b:solar": .init(count: 1, sum: 100, low: 100, high: 100),
            "a:home": .init(count: 1, sum: 500, low: 500, high: 500), "b:home": .init(count: 1, sum: 520, low: 520, high: 520),
            "c:home": .init(count: 1, sum: 40, low: 40, high: 40), "a:level": .init(count: 1, sum: 80, low: 80, high: 80),
        ]
        let minutes = Metrics.energyMinutes([(start, values)], tags: tags)
        #expect(minutes.count == 1)
        // Solar: 300 + 100; home: the system's 510 once, plus C's own 40; the level is no power.
        #expect(minutes.first?.watts == [.solar: 400, .home: 550])
        #expect(Metrics.energyMinutes([(start, ["x": .init(count: 1, sum: 1, low: 1, high: 1)])], tags: tags).isEmpty)
    }

    @Test func theReportChartsTheRangeAndCountsTheDays() {
        let (metrics, clock) = store()
        metrics.tag("plugin:Test:solar", EnergyTag(role: .solar, device: "Roof"))
        metrics.tag("plugin:Test:grid", EnergyTag(role: .grid, device: "Meter"))
        metrics.tag("plugin:Test:level", EnergyTag(role: .batteryLevel, device: "Pack"))
        record(metrics, clock, minutes: 30, ["plugin:Test:solar": 2000, "plugin:Test:grid": -1000, "plugin:Test:level": 50])
        // A minute under way: charted, not yet counted in the day.
        metrics.record(4000, series: "plugin:Test:solar")

        let report = metrics.energy(from: start, to: start.addingTimeInterval(3600), points: 60, days: 3, timeZone: utc)
        #expect(report.roles == [.solar, .grid, .batteryLevel])
        #expect(report.step == 60)
        #expect(report.power.count == 31)
        #expect(report.power.first?.watts == [.solar: 2000, .grid: -1000])
        #expect(report.power.last?.watts[.solar] == 4000)
        #expect(report.levels.map(\.device) == ["Pack"])
        #expect(report.levels.first?.points.count == 30)

        #expect(report.days.map(\.start) == [start.addingTimeInterval(-8 * 3600), start.addingTimeInterval(-32 * 3600), start.addingTimeInterval(-56 * 3600)])
        let today = report.days[0]
        #expect(today.minutes == 30)
        #expect(abs(today.solar - 1) < 1e-9)
        #expect(abs(today.gridExport - 0.5) < 1e-9)
        #expect(today.gridImport == 0)
        #expect(report.days[1].minutes == 0)
    }

    @Test func daysEndAtMidnightInTheTimeZoneAsked() {
        // 23:50 to 00:10 in Paris (UTC+1 in January): ten minutes each side of midnight.
        // 2027-01-15 22:50:05 UTC as one literal: Linux's compiler times out type-checking the sum that makes it.
        let start: TimeInterval = 1_800_053_405
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: start))
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        metrics.tag("plugin:Test:home", EnergyTag(role: .home, device: "House"))
        record(metrics, clock, minutes: 20, ["plugin:Test:home": 600])
        let paris = TimeZone(identifier: "Europe/Paris")!
        let days = metrics.energy(from: clock.withLockedValue { $0 }.addingTimeInterval(-3600), to: clock.withLockedValue { $0 }, days: 2, timeZone: paris).days
        #expect(days.map(\EnergyDay.minutes) == [10, 10])
        #expect(abs(days[0].home - 0.1) < 1e-9)
        #expect(days[0].solarShare == 0)
    }

    @Test func tagsSurviveARestartWhileTheirSeriesHasHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-energy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (metrics, clock) = store(directory)
        metrics.tag("plugin:Test:solar", EnergyTag(role: .solar, device: "Roof"))
        metrics.tag("plugin:Test:gone", EnergyTag(role: .home, device: "Old"))
        // The same tag again writes nothing new; a renamed device replaces it.
        metrics.tag("plugin:Test:solar", EnergyTag(role: .solar, device: "Roof panels"))
        record(metrics, clock, minutes: 1, ["plugin:Test:solar": 500])
        metrics.stop()

        let reread = Metrics(directory: directory, now: { [start] in start.addingTimeInterval(600) })
        #expect(reread.energyTags == ["plugin:Test:solar": EnergyTag(role: .solar, device: "Roof panels")])
    }

    @Test func theHostPassesAPluginsTagToItsFollowers() async throws {
        let seen = NIOLockedValueBox<[String: EnergyTag]>([:])
        let feed = ValueFeed()
        let observation = feed.add { series, _, tag in if let tag { seen.withLockedValue { $0[series] = tag } } }
        defer { observation.cancel() }
        feed.publish("plugin:Test:solar", 100, EnergyTag(role: .solar, device: "Roof"))
        feed.publish("plugin:Test:other", 1, nil)
        #expect(seen.withLockedValue { $0 } == ["plugin:Test:solar": EnergyTag(role: .solar, device: "Roof")])
    }
}
