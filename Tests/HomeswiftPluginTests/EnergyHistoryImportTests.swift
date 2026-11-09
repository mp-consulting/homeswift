import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The runtime's energy history import (`EnergyHistoryImport`): what it keeps, where each pass starts, a new version or
/// device read again from the start with the old hours dropped, failures said and resumed from the checkpoint.
@Suite struct EnergyHistoryImportTests {
    /// What the import did, as the runtime's sinks saw it.
    final class Recorder: Sendable {
        let readings = NIOLockedValueBox<[MeterReading]>([])
        let progress = NIOLockedValueBox<[EnergyImportProgress]>([])
        let forgotten = NIOLockedValueBox<[MeterID]>([])

        var imported: [(MeterID, Int)] {
            readings.withLockedValue { $0 }.compactMap { reading in
                guard case let .history(id, hours, _) = reading else { return nil }
                return (id, hours.count)
            }
        }
        var last: EnergyImportProgress? { progress.withLockedValue { $0.last } }

        func meter(_ key: String) -> PluginMeter {
            PluginMeter(id: MeterID(accessory: "Test:unit", meter: key), kind: .electricity,
                        description: MeterDescription(device: "Unit", suggestedRole: nil, shared: nil, series: "plugin:Test:unit:\(key)"),
                        readings: { [readings] reading in readings.withLockedValue { $0.append(reading) } })
        }
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("energy-history-\(UUID().uuidString)")
    let recorder = Recorder()

    func history(version: Int = 1, migrate: @escaping @Sendable () -> EnergyHistoryState? = { nil }) -> EnergyHistoryImport {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = recorder
        return EnergyHistoryImport(
            name: "cloud", version: version, overlap: 2 * 86_400, interval: .seconds(3600), retry: .seconds(60),
            file: JSONFile(url: directory.appendingPathComponent("energy-history-cloud.json")), logger: Logger(label: "test"),
            progress: { progress in recorder.progress.withLockedValue { $0.append(progress) } },
            forget: { ids in recorder.forgotten.withLockedValue { $0 += ids } },
            migrate: migrate)
    }

    static let day = 86_400.0
    static let now = Date(timeIntervalSince1970: 1_793_799_000)
    static func hours(from start: Date, count: Int) -> [MeterHourImport] {
        (0..<count).map { MeterHourImport(start: start.addingTimeInterval(Double($0) * 3600), consumption: 100) }
    }

    @Test func aFirstPassReadsFromTheStartThenTheLastDaysAgain() async {
        let history = history()
        let sinces = NIOLockedValueBox<[Date?]>([])
        let meter = recorder.meter("consumption")
        let first = Self.now.addingTimeInterval(-10 * Self.day)
        let passed1 = await history.pass(now: Self.now) { pass in
            sinces.withLockedValue { $0.append(pass.since) }
            #expect(pass.isFirst)
            pass.add(meter, Self.hours(from: first, count: 48))
        }
        #expect(passed1)
        #expect(history.state.through == Self.now)
        #expect(history.state.from == first)
        #expect(history.state.meters == [meter.id])
        #expect(recorder.last?.state == .done)
        let later = Self.now.addingTimeInterval(6 * 3600)
        let passed2 = await history.pass(now: later) { pass in
            sinces.withLockedValue { $0.append(pass.since) }
            #expect(!pass.isFirst)
        }
        #expect(passed2)
        #expect(sinces.withLockedValue { $0 } == [nil, Self.now.addingTimeInterval(-2 * Self.day)])
        #expect(history.state.through == later)
        #expect(recorder.imported.map(\.1) == [48])
    }

    @Test func aFailedFirstPassGoesOnFromItsCheckpoint() async {
        let history = history()
        let meter = recorder.meter("consumption")
        let checkpoint = Self.now.addingTimeInterval(-5 * Self.day)
        let passed3 = await history.pass(now: Self.now) { pass in
            pass.add(meter, Self.hours(from: checkpoint.addingTimeInterval(-Self.day), count: 24))
            pass.checkpoint(checkpoint)
            throw EnergyHistoryFailure("the cloud is down")
        }
        #expect(!passed3)
        #expect(recorder.last?.state == .failed)
        #expect(recorder.last?.message == "the cloud is down")
        #expect(history.state.through == nil)
        let since = NIOLockedValueBox<Date?>(nil)
        let passed4 = await history.pass(now: Self.now) { pass in
            since.withLockedValue { $0 = pass.since }
            #expect(pass.isFirst)
        }
        #expect(passed4)
        #expect(since.withLockedValue { $0 } == checkpoint)
        #expect(history.state.resume == nil)
    }

    @Test func aNewVersionDropsTheOldHoursAndReadsFromTheStart() async {
        let meter = recorder.meter("consumption")
        let passed5 = await history(version: 1).pass(now: Self.now) { pass in pass.add(meter, Self.hours(from: Self.now.addingTimeInterval(-Self.day), count: 2)) }
        #expect(passed5)
        let next = history(version: 2)
        let since = NIOLockedValueBox<Date?>(Self.now)
        let passed6 = await next.pass(now: Self.now) { pass in since.withLockedValue { $0 = pass.since } }
        #expect(passed6)
        #expect(recorder.forgotten.withLockedValue { $0 } == [meter.id])
        #expect(since.withLockedValue { $0 } == nil)
        #expect(next.state.version == 2)
    }

    @Test func anotherDeviceDropsTheOldOnesHoursAndStartsAgainAtOnce() async {
        let history = history()
        let first = recorder.meter("first")
        let passed7 = await history.pass(now: Self.now) { pass in
            try pass.identify("A")
            pass.add(first, Self.hours(from: Self.now.addingTimeInterval(-Self.day), count: 2))
        }
        #expect(passed7)
        let passes = NIOLockedValueBox(0)
        let passed8 = await history.pass(now: Self.now) { pass in
            passes.withLockedValue { $0 += 1 }
            try pass.identify("B")
            #expect(pass.since == nil, "from the start, on B")
        }
        #expect(passed8)
        #expect(passes.withLockedValue { $0 } == 2)
        #expect(recorder.forgotten.withLockedValue { $0 } == [first.id])
        #expect(history.state.identity == "B")
    }

    @Test func aPluginsFormerFileIsTakenOnceSoNothingIsReadAgain() async {
        let through = Self.now.addingTimeInterval(-Self.day)
        let history = history { EnergyHistoryState(version: 1, from: through.addingTimeInterval(-30 * Self.day), through: through) }
        let since = NIOLockedValueBox<Date?>(nil)
        let passed9 = await history.pass(now: Self.now) { pass in since.withLockedValue { $0 = pass.since } }
        #expect(passed9)
        #expect(since.withLockedValue { $0 } == through.addingTimeInterval(-2 * Self.day))
    }

    @Test func aMigratedStateIsSavedAtOnceSoTheFormerFileIsAskedForOnce() async {
        let asked = NIOLockedValueBox(0)
        let through = Self.now.addingTimeInterval(-Self.day)
        let first = history {
            asked.withLockedValue { $0 += 1 }
            return EnergyHistoryState(version: 1, through: through)
        }
        #expect(first.state.through == through)
        #expect(history(version: 1).state.through == through, "read from the runtime's file, not the former one")
        #expect(asked.withLockedValue { $0 } == 1)
    }

    @Test func notesAreKeptWithTheState() async {
        let history = history()
        let passed10 = await history.pass(now: Self.now) { pass in pass.note("twoWay", true) }
        #expect(passed10)
        #expect(history.state.notes["twoWay"] == true)
    }
}
