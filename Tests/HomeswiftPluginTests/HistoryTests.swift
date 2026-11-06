import Foundation
import Homeswift
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The History and the Logbook: states at each change, numbers at most every interval and by the hour, the Logbook's
/// Change Sources, writes that change nothing, the files and their retention, and the Change Source a write's task
/// carries to the server's observers.
@Suite(.timeLimit(.minutes(1)))
struct HistoryTests {
    /// 2027-01-15 08:00 UTC, a whole hour.
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Clock: Sendable {
        let date: NIOLockedValueBox<Date>
        init(_ date: Date) { self.date = NIOLockedValueBox(date) }
        var now: Date { date.withLockedValue { $0 } }
        func advance(_ seconds: TimeInterval) { date.withLockedValue { $0 = $0.addingTimeInterval(seconds) } }
    }

    func sensor() -> (Accessory, Characteristic) {
        let service = Service(.temperatureSensor, name: "Hall")
        let accessory = Accessory(id: "Test:hall", name: "Hall", category: .sensor, services: [service])
        return (accessory, service.characteristic(.currentTemperature))
    }

    func lamp() -> (Accessory, Characteristic, Characteristic) {
        let service = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        let accessory = Accessory(id: "Test:lamp", name: "Lamp", category: .lightbulb, services: [service])
        return (accessory, service.characteristic(.on), service.characteristic(.brightness))
    }

    @Test func statesAreKeptAtEachChangeAndLoggedWithTheirSource() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, now: { clock.now })
        let (accessory, on, _) = lamp()
        store.recordChange(of: on, in: accessory, value: .bool(true), source: .user("ann"))
        clock.advance(1)
        store.recordChange(of: on, in: accessory, value: .bool(false), source: .device)
        let series = try #require(store.series(accessory: accessory.id).first { $0.characteristic == "On" })
        #expect(series.kind == .state)
        let found = store.changes(of: series, from: start, to: clock.now)
        #expect(found.points.map(\.value) == [.bool(true), .bool(false)])
        let entries = store.logbook(LogbookQuery())
        #expect(entries.map(\.source) == [.device, .user("ann")])
        // The user's change was not logged as a write: only a write marks it.
        #expect(entries.map(\.write) == [false, false])
        #expect(store.logbook(LogbookQuery(sourceKind: "user")).count == 1)
    }

    @Test func numbersAreKeptAtMostEveryIntervalAndTheLastOfABurstStays() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, interval: 10, now: { clock.now })
        let (accessory, temperature) = sensor()
        // A reading a second, 0.01 °C apart: below the step, so only the first, then the settled last.
        for index in 0..<30 {
            store.recordChange(of: temperature, in: accessory, value: .double(20 + Double(index) * 0.01), source: .device)
            clock.advance(1)
        }
        store.tick()
        clock.advance(10)
        store.tick()
        let series = try #require(store.series(accessory: accessory.id).first)
        let points = store.changes(of: series, from: start, to: clock.now).points
        #expect(points.count == 2)
        #expect(points.first?.value.doubleValue == 20)
        #expect(points.last?.value.doubleValue.map { abs($0 - 20.29) < 1e-9 } == true)
        // Readings are not in the Logbook.
        #expect(store.logbook(LogbookQuery()).isEmpty)
    }

    @Test func aJumpIsKeptOnceTheIntervalHasPassed() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, interval: 10, now: { clock.now })
        let (accessory, temperature) = sensor()
        store.recordChange(of: temperature, in: accessory, value: .double(20), source: .device)
        clock.advance(2)
        store.recordChange(of: temperature, in: accessory, value: .double(25), source: .device)
        clock.advance(9)
        store.recordChange(of: temperature, in: accessory, value: .double(30), source: .device)
        let series = try #require(store.series(accessory: accessory.id).first)
        // Whole numbers read back as such.
        #expect(store.changes(of: series, from: start, to: clock.now).points.map(\.value.doubleValue) == [20, 30])
    }

    @Test func eachHourHasItsLowestMeanAndHighest() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, now: { clock.now })
        let (accessory, temperature) = sensor()
        store.recordChange(of: temperature, in: accessory, value: .double(10), source: .device)
        clock.advance(1800)
        store.recordChange(of: temperature, in: accessory, value: .double(20), source: .device)
        clock.advance(5400)
        store.tick()
        let series = try #require(store.series(accessory: accessory.id).first)
        let hours = store.hours(of: series, from: start, to: clock.now)
        #expect(hours.first == HistoryHour(start: start, min: 10, mean: 15, max: 20))
        // The next hour held 20 throughout, and the one under way so far.
        #expect(hours.dropFirst().first == HistoryHour(start: start.addingTimeInterval(3600), min: 20, mean: 20, max: 20))
        #expect(hours.count == 3)
    }

    @Test func aWriteIsLoggedOnceAndOneThatChangesNothingStill() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, now: { clock.now })
        let (accessory, on, brightness) = lamp()
        // The change a write made, then the write itself: one entry.
        store.recordChange(of: on, in: accessory, value: .bool(true), source: .mcpClient("Claude"))
        store.recordWrite(of: on, in: accessory, value: .bool(true), source: .mcpClient("Claude"))
        clock.advance(5)
        // A write of the value it has: no change, an entry all the same.
        store.recordWrite(of: on, in: accessory, value: .bool(true), source: .homeApp(pairing: "ABCDEF12-3456"))
        // A number written is a target set by someone: logged.
        store.recordWrite(of: brightness, in: accessory, value: .int(40), source: .scene("Evening"))
        let entries = store.logbook(LogbookQuery())
        #expect(entries.map(\.source) == [.scene("Evening"), .homeApp(pairing: "ABCDEF12-3456"), .mcpClient("Claude")])
        #expect(store.logbook(LogbookQuery(accessories: ["Other:1"])).isEmpty)
    }

    @Test func aWriteMarksTheChangeItMadeAndNotTheOthers() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, now: { clock.now })
        let (accessory, on, brightness) = lamp()
        // The handler of a write to On sets Brightness too: one write, and a change it caused.
        store.recordChange(of: on, in: accessory, value: .bool(true), source: .user("ann"))
        store.recordWrite(of: on, in: accessory, value: .bool(true), source: .user("ann"))
        store.recordChange(of: brightness, in: accessory, value: .int(100), source: .user("ann"))
        let entries = store.logbook(LogbookQuery())
        #expect(entries.map(\.characteristic) == ["On"])
        #expect(entries.first?.write == true)
    }

    @Test func aDeviceThatStopsAnsweringStopsItsHours() throws {
        let clock = Clock(start)
        let store = HistoryStore(directory: nil, now: { clock.now })
        let (accessory, temperature) = sensor()
        store.recordChange(of: temperature, in: accessory, value: .double(20), source: .device)
        clock.advance(1800)
        store.tick(silent: [accessory.id])
        clock.advance(4 * 3600)
        store.tick(silent: [accessory.id])
        let series = try #require(store.series(accessory: accessory.id).first)
        // The first hour, closed at its last reading; nothing after.
        #expect(store.hours(of: series, from: start, to: clock.now).map(\.start) == [start])
    }

    @Test func filesOutliveTheStoreAndOldDaysAreDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let store = HistoryStore(directory: directory, retention: HistoryRetention(days: 2), now: { clock.now })
        let (accessory, on, _) = lamp()
        store.recordChange(of: on, in: accessory, value: .bool(true), source: .automation("Night"))
        store.tick()
        let again = HistoryStore(directory: directory, retention: HistoryRetention(days: 2), now: { clock.now })
        let series = try #require(again.series(accessory: accessory.id).first { $0.characteristic == "On" })
        #expect(series.last == .bool(true))
        #expect(again.changes(of: series, from: start, to: clock.now).points.count == 1)
        #expect(again.logbook(LogbookQuery()).first?.source == .automation("Night"))

        // Three days on, the first day's files go.
        clock.advance(3 * 86_400)
        again.prune(at: clock.now)
        let days = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("changes").path)
        #expect(days.isEmpty)
        #expect(again.logbook(LogbookQuery(from: start)).isEmpty)
    }

    @Test func aWritesTaskCarriesItsSourceToTheServersObservers() async throws {
        let (accessory, on, _) = lamp()
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Bridge", category: .bridge, services: []), accessories: [accessory], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false))
        let seen = NIOLockedValueBox<[String]>([])
        server.observeChanges { _, _, value in seen.withLockedValue { $0.append("change \(value) \(ChangeSource.resolved)") } }
        server.observeWrites { _, _, value in seen.withLockedValue { $0.append("write \(value) \(ChangeSource.resolved)") } }
        on.onWrite { _ in }
        try await ChangeSource.user("ann").run { try await on.write(.bool(true)) }
        // The device's own change, outside any write.
        on.value = .bool(false)
        #expect(seen.withLockedValue { $0 } == ["change bool(true) user ann", "write bool(true) user ann", "change bool(false) the device"])
    }

    @Test func retentionStaysInItsBounds() {
        #expect(HistoryRetention(days: 0, years: 99) == HistoryRetention(days: 1, years: 20))
        var bridge = HomeswiftConfiguration.Bridge()
        bridge.historyDays = 30
        #expect(HistoryRetention(bridge).days == 30)
        #expect(HistoryRetention(bridge).years == HistoryRetention.defaultYears)
    }
}
