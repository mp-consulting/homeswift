import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The readings plugins record with `Metrics.record`: a minute keeps each series' count, sum, lowest and highest,
/// the history merges them, and they survive a restart in the day's file.
@Suite(.timeLimit(.minutes(1)))
struct MetricsValueTests {
    /// A whole minute: 2027-01-15 08:00 UTC.
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aMinuteKeepsTheCountSumLowestAndHighest() {
        let clock = NIOLockedValueBox(start.addingTimeInterval(10))
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        metrics.record(120, series: "plugin:Test:solar")
        metrics.record(340, series: "plugin:Test:solar")
        metrics.record(80, series: "plugin:Test:solar")
        let history = metrics.valueHistory(from: start, to: start.addingTimeInterval(60), series: "plugin:Test:solar")
        let values = history.points.first?.values
        #expect(values == Metrics.Values(count: 3, sum: 540, low: 80, high: 340))
        #expect(values?.average == 180)
    }

    @Test func seriesAreKeptApart() {
        let metrics = Metrics(directory: nil, now: { [start] in start.addingTimeInterval(10) })
        metrics.record(1, series: "plugin:Test:solar")
        metrics.record(2, series: "plugin:Test:home")
        let solar = metrics.valueHistory(from: start, to: start.addingTimeInterval(60), series: "plugin:Test:solar")
        #expect(solar.points.map(\.values.sum) == [1])
        #expect(metrics.valueHistory(from: start, to: start.addingTimeInterval(60), series: "plugin:Test:grid").points.isEmpty)
    }

    @Test func nonFiniteReadingsAreLeftOut() {
        let metrics = Metrics(directory: nil, now: { [start] in start.addingTimeInterval(10) })
        metrics.record(.nan, series: "plugin:Test:solar")
        metrics.record(.infinity, series: "plugin:Test:solar")
        #expect(metrics.valueHistory(from: start, to: start.addingTimeInterval(60), series: "plugin:Test:solar").points.isEmpty)
    }

    @Test func minutesMergeIntoOnePoint() {
        let clock = NIOLockedValueBox(start.addingTimeInterval(10))
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        metrics.record(100, series: "plugin:Test:home")
        clock.withLockedValue { $0 = start.addingTimeInterval(70) }
        metrics.record(300, series: "plugin:Test:home")
        let history = metrics.valueHistory(from: start, to: start.addingTimeInterval(3600), series: "plugin:Test:home", points: 1)
        #expect(history.points.count == 1)
        #expect(history.points.first?.values == Metrics.Values(count: 2, sum: 400, low: 100, high: 300))
    }

    @Test func readingsSurviveARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = start.addingTimeInterval(10)
        let metrics = Metrics(directory: directory, now: { now })
        metrics.record(250, series: "plugin:Test:solar")
        metrics.record(90, series: "plugin:Test:solar")
        // Closing the minute writes it to the day's file.
        metrics.stop()

        let later = start.addingTimeInterval(3600)
        let reread = Metrics(directory: directory, now: { later })
        let history = reread.valueHistory(from: start, to: start.addingTimeInterval(60), series: "plugin:Test:solar")
        #expect(history.points.first?.values == Metrics.Values(count: 2, sum: 340, low: 90, high: 250))
    }
}
