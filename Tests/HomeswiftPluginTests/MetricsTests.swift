import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct MetricsTests {
    typealias Minute = Metrics.Minute
    typealias Durations = Metrics.Durations

    /// A whole minute: 2027-01-15 08:00 UTC.
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mergesMinutesIntoPoints() {
        let metrics = Metrics(directory: nil, now: { [start] in start.addingTimeInterval(3600) })
        for index in 0..<10 {
            metrics.add(Minute(
                start: start.addingTimeInterval(Double(index) * 60), memory: UInt64(100 + index), cpu: Double(index),
                requests: ["all": Durations(count: 1, total: Double(index), longest: Double(index))],
                handlers: index.isMultiple(of: 2) ? ["accessory:lamp": Durations(count: 1, total: 50, longest: 50)] : [:]))
        }
        // Ten minutes in at most five points: two minutes each, the highest memory, the average CPU, the calls added up.
        let history = metrics.history(from: start, to: start.addingTimeInterval(600), points: 5)
        #expect(history.step == 120)
        #expect(history.points.map(\.start) == (0..<5).map { start.addingTimeInterval(Double($0) * 120) })
        #expect(history.points[0].memory == 101)
        #expect(history.points[0].cpu == 0.5)
        #expect(history.points[0].requests == Durations(count: 2, total: 1, longest: 1))
        #expect(history.points[0].handlers == Durations())

        // Another series has its own calls only; memory and CPU stay the process's.
        let lamp = metrics.history(from: start, to: start.addingTimeInterval(600), series: "accessory:lamp", points: 5)
        #expect(lamp.points[1].handlers == Durations(count: 1, total: 50, longest: 50))
        #expect(lamp.points[1].requests == Durations())
        #expect(lamp.points[1].memory == 103)

        // Asked from a second within a minute, points still start on whole minutes.
        #expect(metrics.history(from: start.addingTimeInterval(19), to: start.addingTimeInterval(180)).points.first?.start == start)
    }

    @Test func recordsTimingsBySeries() {
        let clock = NIOLockedValueBox(start)
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        let lamp = Accessory(id: "Recording:lamp", name: "Lamp", category: .lightbulb, services: [])
        metrics.record(HAPServer.Timing(kind: .request, accessories: [lamp], duration: .milliseconds(30)), server: "AA:BB")
        metrics.record(HAPServer.Timing(kind: .handler, accessories: [lamp], duration: .milliseconds(80)), server: "AA:BB")
        metrics.record(HAPServer.Timing(kind: .request, accessories: [], duration: .milliseconds(10)), server: "CC:DD")

        // The minute under way counts.
        func point(_ series: String) -> Metrics.Point? { metrics.history(from: start, to: start.addingTimeInterval(60), series: series).points.first }
        #expect(point("all")?.requests == Durations(count: 2, total: 40, longest: 30))
        #expect(point("bridge:AA:BB")?.requests == Durations(count: 1, total: 30, longest: 30))
        #expect(point("bridge:CC:DD")?.requests == Durations(count: 1, total: 10, longest: 10))
        #expect(point("accessory:Recording:lamp")?.handlers == Durations(count: 1, total: 80, longest: 80))
        #expect(point("accessory:Recording:lamp")?.requests == Durations(count: 1, total: 30, longest: 30))

        // A call in the next minute closes this one.
        clock.withLockedValue { $0 = start.addingTimeInterval(61) }
        metrics.record(HAPServer.Timing(kind: .request, accessories: [], duration: .milliseconds(5)), server: "AA:BB")
        #expect(metrics.history(from: start, to: start.addingTimeInterval(120)).points.map(\.requests.count) == [2, 1])
    }

    @Test func readsItsFilesBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-metrics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The last minute of 15 January and the first of the 16th, UTC: a file each.
        let late = Date(timeIntervalSince1970: 1_800_057_540), midnight = Date(timeIntervalSince1970: 1_800_057_600)
        let now = midnight.addingTimeInterval(120)
        let metrics = Metrics(directory: directory, now: { now })
        metrics.add(Minute(start: late, memory: 1000, cpu: 2.5, requests: ["all": Durations(count: 3, total: 12.25, longest: 9)]))
        metrics.add(Minute(start: midnight, handlers: ["all": Durations(count: 1, total: 4, longest: 4)]))
        metrics.stop()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["metrics-20270115.jsonl", "metrics-20270116.jsonl"])
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(names[0]).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let reread = Metrics(directory: directory, now: { now }).history(from: late, to: now, points: 100)
        #expect(reread.points == [
            Metrics.Point(start: late, memory: 1000, cpu: 2.5, requests: Durations(count: 3, total: 12.25, longest: 9), handlers: Durations()),
            Metrics.Point(start: midnight, memory: nil, cpu: nil, requests: Durations(), handlers: Durations(count: 1, total: 4, longest: 4)),
        ])
        // Minutes older than `days` are not read back.
        #expect(Metrics(directory: directory, days: 1, now: { now.addingTimeInterval(86_400) }).history(from: late, to: now).points.isEmpty)
    }

    @Test func samplesTheProcess() {
        #expect((Metrics.memoryFootprint() ?? 0) > 1_000_000)
        #expect((Metrics.cpuSeconds() ?? 0) > 0)
        let metrics = Metrics(directory: nil)
        metrics.sample()
        // CPU is the time used between two samples.
        #expect(metrics.latest.cpu == nil)
        metrics.sample()
        #expect(metrics.latest.memory != nil)
        #expect(metrics.latest.cpu != nil)
    }

    @Test func followsTheHostsServers() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"] }] }"#)
        try await host.start()
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        let lamp = try #require(host.mainBridge.server.accessories.last)
        let brightness = try #require(lamp.service(.lightbulb)?[.brightness])
        brightness.onWrite { _ in }
        try await brightness.write(.int(40))

        let history = metrics.history(from: Date().addingTimeInterval(-120), to: Date(), series: "accessory:Recording:lamp-1")
        #expect(history.points.reduce(0) { $0 + $1.handlers.count } == 1)
        metrics.stop()
        await host.stop()
    }
}
