import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The long-term energy archive: the bridge's minutes rolled up into hours, imports beside them, the bridge's own
/// figures standing over an import's for an hour it recorded, days and months in a time zone, and the file.
@Suite(.timeLimit(.minutes(1)))
struct EnergyArchiveTests {
    /// 2027-01-15 08:00 UTC, a whole hour.
    let hour = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

    @Test func closedMinutesAddUpInTheirHour() {
        let clock = NIOLockedValueBox(hour.addingTimeInterval(5))
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        metrics.tag("plugin:Test:solar", EnergyTag(role: .solar, device: "Roof"))
        metrics.tag("plugin:Test:home", EnergyTag(role: .home, device: "House"))
        metrics.tag("plugin:Test:grid", EnergyTag(role: .grid, device: "Meter"))
        for _ in 0..<60 {
            metrics.record(1200, series: "plugin:Test:solar")
            metrics.record(600, series: "plugin:Test:home")
            metrics.record(-300, series: "plugin:Test:grid")
            clock.withLockedValue { $0 = $0.addingTimeInterval(60) }
        }
        metrics.record(0, series: "plugin:Test:untagged")
        let day = metrics.archive.periods(.day, from: hour, to: hour, timeZone: utc)
        #expect(day.count == 1)
        #expect(near(day[0].flows.solar, 1200))
        #expect(near(day[0].flows.home, 600))
        #expect(near(day[0].flows.gridImport, 0))
        #expect(near(day[0].flows.gridExport, 300))
        #expect(near(day[0].flows.homeFromSolar, 600))
        #expect(day[0].flows.batteryCharge == nil)
        #expect(day[0].recordedHours == 1)
        #expect(day[0].solarShare == 1)
    }

    @Test func anImportKnowsSolarAndHomeOnly() {
        let archive = EnergyArchive(url: nil)
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 500, home: 800)),
                             EnergyHourImport(start: hour.addingTimeInterval(3600), flows: EnergyFlows(solar: 0, home: 400))], source: "Cloud")
        let day = archive.periods(.day, from: hour, to: hour, timeZone: utc)[0]
        #expect(near(day.flows.solar, 500))
        #expect(near(day.flows.home, 1200))
        // The lesser of solar and home in each hour.
        #expect(near(day.flows.homeFromSolar, 500))
        #expect(near(day.homeNotSplit, 700))
        #expect(day.homeFromGrid == nil)
        #expect(day.flows.gridImport == nil)
        #expect(day.importedHours == 2)
        #expect(day.recordedHours == 0)
    }

    @Test func theBridgesWholeHourStandsOverAnImport() {
        let archive = EnergyArchive(url: nil)
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 999, home: 999))], source: "Cloud")
        for minute in 0..<50 { archive.addRecorded(hour.addingTimeInterval(Double(minute) * 60), watts: [.solar: 600, .home: 300, .grid: 0]) }
        let whole = archive.periods(.day, from: hour, to: hour, timeZone: utc)[0]
        #expect(near(whole.flows.solar, 500))
        #expect(near(whole.flows.home, 250))
        #expect(whole.recordedHours == 1)

        // A few minutes recorded: the import's figures, and the recorded grid it does not have.
        let next = hour.addingTimeInterval(3600)
        archive.importHours([EnergyHourImport(start: next, flows: EnergyFlows(solar: 100, home: 200))], source: "Cloud")
        for minute in 0..<5 { archive.addRecorded(next.addingTimeInterval(Double(minute) * 60), watts: [.solar: 600, .home: 300, .grid: 120]) }
        let flows = EnergyArchive.merged(EnergyArchive.Hour(recorded: EnergyFlows.minute([.grid: 120]), minutes: 5, imported: ["Cloud": EnergyFlows(solar: 100, home: 200, homeFromSolar: 100)])).flows
        #expect(flows.solar == 100)
        #expect(near(flows.gridImport, 2))
    }

    @Test func sourcesAddUpAndAnImportReplacesItsOwnHour() {
        let archive = EnergyArchive(url: nil)
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 100))], source: "A")
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 50))], source: "B")
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 120))], source: "A")
        #expect(near(archive.periods(.day, from: hour, to: hour, timeZone: utc)[0].flows.solar, 170))
        #expect(archive.earliest == hour)
    }

    @Test func daysAndMonthsFollowTheTimeZone() {
        let archive = EnergyArchive(url: nil)
        // 22:00 and 23:00 UTC are the next day in Athens (UTC+2).
        let late = Date(timeIntervalSince1970: 1_801_000_000 - 1_801_000_000.truncatingRemainder(dividingBy: 86_400) - 2 * 3600)
        archive.importHours([EnergyHourImport(start: late, flows: EnergyFlows(home: 100)),
                             EnergyHourImport(start: late.addingTimeInterval(3600), flows: EnergyFlows(home: 100))], source: "Cloud")
        let athens = TimeZone(identifier: "Europe/Athens")!
        let days = archive.periods(.day, from: late.addingTimeInterval(-86_400), to: late.addingTimeInterval(86_400), timeZone: athens)
        #expect(days.map(\.importedHours) == [0, 2, 0])
        let months = archive.periods(.month, from: late, to: late, timeZone: utc)
        #expect(months.count == 1)
        #expect(near(months[0].flows.home, 200))
    }

    @Test func theFileKeepsTheHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(EnergyArchive.fileName)
        let archive = EnergyArchive(url: url, saveDelay: .seconds(3600))
        archive.importHours([EnergyHourImport(start: hour, flows: EnergyFlows(solar: 321.123, home: 10))], source: "Cloud")
        archive.flush()
        let reread = EnergyArchive(url: url)
        #expect(near(reread.periods(.day, from: hour, to: hour, timeZone: utc)[0].flows.solar, 321.12))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aRestartCountsNoMinuteTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = NIOLockedValueBox(hour.addingTimeInterval(5))
        let metrics = Metrics(directory: directory, now: { clock.withLockedValue { $0 } })
        metrics.tag("plugin:Test:home", EnergyTag(role: .home, device: "House"))
        for _ in 0..<90 {
            metrics.record(600, series: "plugin:Test:home")
            clock.withLockedValue { $0 = $0.addingTimeInterval(60) }
        }
        metrics.stop()
        let before = metrics.archive.periods(.day, from: hour, to: hour, timeZone: utc)[0].flows.home
        let reread = Metrics(directory: directory, now: { clock.withLockedValue { $0 } })
        #expect(near(reread.archive.periods(.day, from: hour, to: hour, timeZone: utc)[0].flows.home, before ?? -1))
        #expect(near(before, 900))
    }

    @Test func importsMadeBeforeAnyoneFollowsArriveLater() {
        let feed = EnergyImportFeed()
        feed.publish("Cloud", [EnergyHourImport(start: hour, flows: EnergyFlows(solar: 1))])
        let seen = NIOLockedValueBox<[String]>([])
        let observation = feed.add { source, hours in seen.withLockedValue { $0.append("\(source):\(hours.count)") } }
        defer { observation.cancel() }
        feed.publish("Cloud", [])
        #expect(seen.withLockedValue { $0 } == ["Cloud:1", "Cloud:0"])
    }
}
