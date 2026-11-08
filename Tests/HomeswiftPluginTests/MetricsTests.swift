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

    /// A damaged row reads as what it can say, never as a trap at every start.
    @Test func readsDamagedRowsWithoutTrapping() throws {
        let minute = try #require(Metrics.minute(Data(#"{"t":1800000000,"m":1e300,"r":{"all":[1e300,1,1],"x":[-1e300,1,1]}}"#.utf8)))
        #expect(minute.memory == .max)
        #expect(minute.requests["all"]?.count == .max)
        #expect(minute.requests["x"]?.count == .min)
        #expect(Metrics.day(Date(timeIntervalSince1970: 1_800_057_540)) == "20270115")
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

    /// An accessory's Total Consumption is a Meter the bridge records with no code of its plugin's: its counter as it
    /// stands at start, then each change, by the hour.
    @Test func recordsMetersFromTotalConsumption() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Plugs", "meters": ["plug-1"] }] }"#)
        try await host.start()
        let plug = try #require(host.mainBridge.server.accessories.last)
        let service = try #require(plug.service(.outlet))
        let total = try #require(service[EveCharacteristic.totalConsumption])
        let clock = NIOLockedValueBox(Date())
        let metrics = Metrics(directory: nil, interval: .seconds(60), now: { clock.withLockedValue { $0 } })
        metrics.start(following: host)
        let id = MeterID(accessory: "Recording:plug-1", meter: "\(service.type.uuid)/")
        #expect(metrics.meters.meters == [id])

        // A quarter of a kWh over the next half hour.
        let start = clock.withLockedValue { $0 }
        clock.withLockedValue { $0 = start.addingTimeInterval(1800) }
        total.value = .double(2.25)
        let hours = metrics.meters.hours(of: id, from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(3600))
        #expect(abs(hours.reduce(0) { $0 + ($1.consumption ?? 0) } - 250) < 1e-6)
        #expect(hours.allSatisfy { $0.recorded })
        metrics.stop()
        await host.stop()
    }

    /// A Meter a plugin declares: its counters reach the Meters, and its power the Home Energy with `EnergyRole`'s
    /// signs (solar produced is above zero there, Returned on the Meter).
    @Test func recordsTheMetersAPluginDeclares() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Roof", "solar": 800 }] }"#)
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        try await host.start()
        let id = MeterID(accessory: "Recording:roof", meter: "solar")
        #expect(metrics.meters.meters == [id])
        // Its 800 W of solar, produced: Returned on the Meter, held for an hour.
        let now = Date()
        metrics.meters.advance(to: now.addingTimeInterval(3600))
        let hours = metrics.meters.hours(of: id, from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(7200))
        #expect(abs(hours.reduce(0) { $0 + ($1.returned ?? 0) } - 800) < 1)
        #expect(metrics.energyTags["plugin:Recording:roof:solar"] == EnergyTag(role: .solar, device: "Roof"))
        let solar = metrics.valueMinutes(from: now.addingTimeInterval(-120), to: now.addingTimeInterval(60), series: ["plugin:Recording:roof:solar"])
        #expect(solar.last?.values["plugin:Recording:roof:solar"]?.average == 800)
        metrics.stop()
        await host.stop()
    }

    /// A Meter's power counts in the Home Energy under the Energy Role a person gave it, live, else its plugin's
    /// suggestion; a role other than the suggestion is a series of its own, and none counts nothing.
    @Test func homeEnergyFollowsEachMetersRole() async throws {
        let environment = TestEnvironment()
        let outlet = "\(ServiceType.outlet.uuid)/"
        let config = #"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Plugs", "meters": ["plug-1"], "solarMeter": true, "_accessories": { "plug-1": { "energyRoles": { "OUTLET": "grid" } }, "array": { "energyRoles": { "solar": "none" } } } }] }"#
            .replacingOccurrences(of: "OUTLET", with: outlet)
        let host = try environment.host(config)
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.last)
        #expect(host.energyRole(of: MeterID(accessory: "Recording:plug-1", meter: outlet)) == .some(.grid))
        #expect(host.energyRole(of: MeterID(accessory: "Recording:array", meter: "solar")) == .some(nil))
        #expect(host.energyRole(of: MeterID(accessory: "Recording:plug-9", meter: outlet)) == nil)

        // The plug, a grid meter by its settings: its power is the grid's.
        let plug = try #require(host.mainBridge.server.accessories.first { $0.id == "Recording:plug-1" })
        plug.service(.outlet)?[EveCharacteristic.currentConsumption]?.value = .int(1200)
        #expect(metrics.energyTags["meter:Recording:plug-1#\(outlet):grid"] == EnergyTag(role: .grid, device: "plug-1"))
        // The array, suggested solar but set to none: nothing in the Home Energy, yet still a Meter.
        await plugin.recordSolar(700)
        #expect(metrics.meters.meters.contains(MeterID(accessory: "Recording:array", meter: "solar")))
        #expect(!metrics.energyTags.values.contains { $0.role == .solar })
        #expect(metrics.meterDescription(of: MeterID(accessory: "Recording:array", meter: "solar"))?.suggestedRole == .solar)
        metrics.stop()
        await host.stop()
    }

    /// A Meter that only ever imported hours (a cloud's history, its device offline) still has its plugin's Energy
    /// Role, and keeps it in its files for after a restart; dropping its imported hours drops them from the Home Energy too.
    @Test func importedHoursGiveAMeterItsRoleAndCanBeForgotten() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Plugs" }] }"#)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metrics = Metrics(directory: directory, interval: .seconds(60))
        metrics.start(following: host)
        try await host.start()
        let context = try #require(host.context(platform: "Recording", name: "Plugs"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = MeterID(accessory: "Recording:system", meter: "home")
        context.meter("home", deviceID: "system", device: "System", suggestedRole: .home).importHours([MeterHourImport(start: start, consumption: 800)])
        #expect(await meterEventually { metrics.suggestedRole(of: id) == .home })
        #expect(metrics.archive.importedHours(from: start, to: start).first?.flows.home == 800)
        metrics.meters.flush()
        #expect(MeterArchive(directory: directory.appendingPathComponent("meters")).suggestedRole(of: id) == .home)

        context.forgetImportedHours(ofMeter: "home", deviceID: "system")
        #expect(await meterEventually { metrics.meters.hours(of: id, from: start, to: start).isEmpty })
        #expect(metrics.archive.importedHours(from: start, to: start).isEmpty)
        metrics.stop()
        await host.stop()
    }

    /// A gas Meter a plugin declares: read in m³ and kept in litres, its kind kept; never in the Home Energy, whatever
    /// role was suggested, and no power.
    @Test func aGasMeterIsKeptInCubicMetresApartFromTheHomeEnergy() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Plugs", "gasMeter": true }] }"#)
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.last)
        let boiler = MeterID(accessory: "Recording:boiler", meter: "gas")

        await plugin.recordGas(1_234.5)
        #expect(await meterEventually { metrics.meters.kind(of: boiler) == .gas })
        await plugin.recordGasWatts(900)
        // A litre a tenth of a second later: a gain the archive finds plausible (it bounds a gain by the time it took).
        try await Task.sleep(for: .milliseconds(100))
        await plugin.recordGas(1_234.501)
        #expect(await meterEventually {
            metrics.meters.hours(of: boiler, from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(86_400)).compactMap(\.consumption).reduce(0, +) > 0.999
        })
        #expect(abs(metrics.meters.hours(of: boiler, from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(86_400)).compactMap(\.consumption).reduce(0, +) - 1) < 0.001)
        #expect(metrics.meterDescription(of: boiler) == nil)
        #expect(metrics.energyTags.isEmpty)
        metrics.stop()
        await host.stop()
    }
}

/// A ceiling, not a wait: a loaded machine can take seconds to pass a reading on.
private func meterEventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
