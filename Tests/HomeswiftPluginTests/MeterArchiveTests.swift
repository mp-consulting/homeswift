import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// Each Meter's energy by the hour: counters' gains spread over the time between readings, resets, a restart's gap as
/// an estimate an import stands over, power held between readings, days in a time zone, and the files.
@Suite(.timeLimit(.minutes(1)))
struct MeterArchiveTests {
    /// 2027-01-15 08:00 UTC, a whole hour.
    let hour = Date(timeIntervalSince1970: 1_800_000_000)
    let plug = MeterID(accessory: "Shelly:aabbcc", meter: "switch:0")

    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meters-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aCounterGainIsSpreadOverTheHoursBetweenReadings() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(1000, meter: plug, at: hour.addingTimeInterval(1800))
        // 300 Wh over an hour, half in each of two hours.
        archive.recordCounter(1300, meter: plug, at: hour.addingTimeInterval(5400))
        let hours = archive.hours(of: plug, from: hour, to: hour.addingTimeInterval(7200))
        #expect(hours.map(\.start) == [hour, hour.addingTimeInterval(3600)])
        #expect(near(hours[0].consumption, 150) && near(hours[1].consumption, 150))
        #expect(hours.allSatisfy { $0.recorded })
        #expect(hours.allSatisfy { $0.returned == nil })
    }

    @Test func aCounterThatGoesBackIsAReset() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(5000, meter: plug, at: hour.addingTimeInterval(60))
        archive.recordCounter(40, meter: plug, at: hour.addingTimeInterval(120))
        archive.recordCounter(100, meter: plug, at: hour.addingTimeInterval(180))
        #expect(near(archive.hours(of: plug, from: hour, to: hour).first?.consumption, 100))
    }

    @Test func returnedIsCountedApart() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(10, direction: .returned, meter: plug, at: hour.addingTimeInterval(60))
        archive.recordCounter(70, direction: .returned, meter: plug, at: hour.addingTimeInterval(120))
        let first = archive.hours(of: plug, from: hour, to: hour).first
        #expect(near(first?.returned, 60))
        #expect(first?.consumption == nil)
    }

    @Test func aGapLongerThanAMonthIsLost() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(0, meter: plug, at: hour)
        archive.recordCounter(9000, meter: plug, at: hour.addingTimeInterval(MeterArchive.longestGap + 3600))
        #expect(archive.hours(of: plug, from: hour, to: hour.addingTimeInterval(MeterArchive.longestGap + 7200)).isEmpty)
    }

    @Test func powerIsHeldBetweenReadingsAndAdvancedToNow() {
        let clock = NIOLockedValueBox(hour)
        let archive = MeterArchive(directory: nil, now: { clock.withLockedValue { $0 } })
        archive.recordPower(600, meter: plug, at: hour)
        // Ten minutes of 600 W, then twenty of 300 W returned (a grid meter exporting).
        archive.recordPower(-300, meter: plug, at: hour.addingTimeInterval(600))
        archive.advance(to: hour.addingTimeInterval(1800))
        let first = archive.hours(of: plug, from: hour, to: hour).first
        #expect(near(first?.consumption, 100))
        #expect(near(first?.returned, 100))
    }

    @Test func aCounterWinsOverPowerForItsDirection() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(0, meter: plug, at: hour)
        archive.recordPower(1000, meter: plug, at: hour)
        archive.advance(to: hour.addingTimeInterval(1800))
        archive.recordCounter(200, meter: plug, at: hour.addingTimeInterval(1800))
        #expect(near(archive.hours(of: plug, from: hour, to: hour).first?.consumption, 200))
    }

    @Test func aRestartKeepsTheCounterAndEstimatesTheGap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = MeterArchive(directory: directory, now: { hour })
        before.recordCounter(1000, meter: plug, at: hour.addingTimeInterval(60))
        before.flush()

        // Back two hours later: the first hour and the start of the second are an estimate, the rest measured.
        let restart = hour.addingTimeInterval(5400)
        let after = MeterArchive(directory: directory, now: { restart })
        #expect(after.meters == [plug])
        after.recordCounter(1000 + 7140 / 60 * 2, meter: plug, at: hour.addingTimeInterval(7200))
        let hours = after.hours(of: plug, from: hour, to: hour.addingTimeInterval(3600))
        #expect(hours.count == 2)
        #expect(hours[0].recorded == false && hours[1].recorded == false)
        #expect(near((hours[0].consumption ?? 0) + (hours[1].consumption ?? 0), 238))

        // An import stands over the estimated hours; a measured hour keeps its own figure.
        after.importHours([MeterHourImport(start: hour, consumption: 50), MeterHourImport(start: hour.addingTimeInterval(3600), consumption: 70)], meter: plug)
        let merged = after.hours(of: plug, from: hour, to: hour.addingTimeInterval(3600))
        #expect(near(merged[0].consumption, 50) && near(merged[1].consumption, 70))
    }

    @Test func aMeasuredHourKeepsItsFigureOverAnImport() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(0, meter: plug, at: hour)
        archive.recordCounter(80, meter: plug, at: hour.addingTimeInterval(600))
        archive.importHours([MeterHourImport(start: hour, consumption: 999, returned: 5)], meter: plug)
        let first = archive.hours(of: plug, from: hour, to: hour).first
        #expect(near(first?.consumption, 80))
        // What the bridge did not measure comes from the import.
        #expect(near(first?.returned, 5))
        #expect(first?.recorded == true)
    }

    @Test func daysAreCountedInTheTimeZone() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let archive = MeterArchive(directory: nil, now: { hour })
        // 2027-01-15 22:30 and 23:30 UTC: the 15th's last hour and the 16th's first in Paris.
        let evening = hour.addingTimeInterval(14 * 3600 + 1800)
        archive.importHours([MeterHourImport(start: evening, consumption: 10), MeterHourImport(start: evening.addingTimeInterval(3600), consumption: 20)], meter: plug)
        let days = archive.periods(of: plug, .day, from: evening, to: evening.addingTimeInterval(3600), timeZone: paris)
        #expect(days.count == 2)
        #expect(near(days[0].consumption, 10) && near(days[1].consumption, 20))
        #expect(days.allSatisfy { $0.recordedHours == 0 && $0.hours == 1 })
    }

    @Test func yearsAreFilesOfTheirOwnAndForgetRemovesThem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 2026-12-31 23:00 UTC to 2027-01-01 01:00.
        let newYear = Date(timeIntervalSince1970: 1_798_761_600)
        let archive = MeterArchive(directory: directory, now: { newYear })
        archive.recordCounter(0, meter: plug, at: newYear.addingTimeInterval(-3600))
        archive.recordCounter(120, meter: plug, at: newYear.addingTimeInterval(3600))
        archive.flush()
        let folder = MeterArchive.folder(of: plug, in: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["2026.json", "2027.json", "meter.json"])

        let reloaded = MeterArchive(directory: directory, now: { newYear })
        let hours = reloaded.hours(of: plug, from: newYear.addingTimeInterval(-3600), to: newYear)
        #expect(hours.count == 2 && near(hours[0].consumption, 60) && near(hours[1].consumption, 60))

        reloaded.forget(accessory: plug.accessory)
        #expect(reloaded.meters.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A plugin's 0 while the device was away, then its real reading: no gain more than `largestPower` could make.
    @Test func anImplausibleGainIsNotCounted() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(1_000_000, meter: plug, at: hour)
        archive.recordCounter(0, meter: plug, at: hour.addingTimeInterval(60))
        archive.recordCounter(1_000_050, meter: plug, at: hour.addingTimeInterval(70))
        archive.recordCounter(1_000_080, meter: plug, at: hour.addingTimeInterval(130))
        #expect(near(archive.hours(of: plug, from: hour, to: hour).first?.consumption, 30))
    }

    /// A cached counter read at start counts only when it went up, and never as a reset.
    @Test func aSeedOnlyMovesACounterForward() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordCounter(500, meter: plug, at: hour)
        archive.seedCounter(200, meter: plug)
        archive.seedCounter(500, meter: plug)
        #expect(archive.hours(of: plug, from: hour, to: hour).isEmpty)
        archive.recordCounter(560, meter: plug, at: hour.addingTimeInterval(600))
        #expect(near(archive.hours(of: plug, from: hour, to: hour).first?.consumption, 60))
    }

    /// A device that stops reporting is counted for `longestHold` after its last reading, then no more.
    @Test func heldPowerStopsAfterTheLongestHold() {
        let archive = MeterArchive(directory: nil, now: { hour })
        archive.recordPower(100, meter: plug, at: hour)
        archive.advance(to: hour.addingTimeInterval(MeterArchive.longestHold + 86_400))
        let total = archive.hours(of: plug, from: hour, to: hour.addingTimeInterval(2 * 86_400)).reduce(0) { $0 + ($1.consumption ?? 0) }
        #expect(near(total, 100 * MeterArchive.longestHold / 3600))
    }

    /// Forgetting one Meter writes what is due for the others: nothing they recorded is lost.
    @Test func forgetKeepsTheOthersPendingSave() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = MeterID(accessory: "Shelly:ddeeff", meter: "switch:0")
        let archive = MeterArchive(directory: directory, now: { hour })
        archive.recordCounter(0, meter: plug, at: hour)
        archive.recordCounter(0, meter: other, at: hour)
        archive.recordCounter(40, meter: other, at: hour.addingTimeInterval(600))
        archive.forget(accessory: plug.accessory)
        archive.flush()
        let reloaded = MeterArchive(directory: directory, now: { hour })
        #expect(reloaded.meters == [other])
        #expect(near(reloaded.hours(of: other, from: hour, to: hour).first?.consumption, 40))
        #expect(!reloaded.hasHistory(accessory: plug.accessory) && reloaded.hasHistory(accessory: other.accessory))
    }

    @Test func aMetersKindIsKeptInItsFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let water = MeterID(accessory: "Meters:house", meter: "water")
        let before = MeterArchive(directory: directory, now: { hour })
        #expect(before.kind(of: water) == .electricity)
        before.setKind(.water, meter: water)
        before.importHours([MeterHourImport(start: hour, cubicMetres: 0.18)], meter: water)
        before.recordCounter(1000, meter: plug, at: hour)
        before.flush()

        let after = MeterArchive(directory: directory, now: { hour })
        #expect(after.kind(of: water) == .water)
        #expect(after.kind(of: plug) == .electricity)
        #expect(near(after.hours(of: water, from: hour, to: hour).first?.consumption, 180))
        #expect(MeterKind.gas.unit == "m³" && MeterKind.electricity.unit == "kWh")
    }

    /// A declared Meter shows nowhere before its first reading, takes its kind then, and goes back to electricity when
    /// its plugin says so.
    @Test func aDeclaredKindWaitsForTheFirstReadingAndCanGoBack() {
        let archive = MeterArchive(directory: nil, now: { hour })
        let gas = MeterID(accessory: "Meters:boiler", meter: "gas")
        archive.setKind(.gas, meter: gas)
        #expect(archive.meters.isEmpty)
        #expect(archive.kind(of: gas) == .gas)
        archive.recordCounter(1_000, meter: gas, at: hour)
        #expect(archive.meters == [gas])
        #expect(archive.kind(of: gas) == .gas)
        archive.setKind(.electricity, meter: gas)
        #expect(archive.kind(of: gas) == .electricity)
    }
}
