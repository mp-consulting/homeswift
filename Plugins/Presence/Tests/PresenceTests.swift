import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftPresence

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

let phone = "A8:BB:CC:00:00:01"
let watch = "A8:BB:CC:00:00:02"
let laptop = "3E:BB:CC:00:00:03"

/// The network as the test sets it: which MACs are on it, the devices Setup lists, and how many checks were made.
final class FakeSource: PresenceSource {
    let present = NIOLockedValueBox<Set<String>>([])
    let checks = NIOLockedValueBox(0)
    let listed = NIOLockedValueBox<[NetworkDevice]>([])

    func seen(_ macs: Set<String>) async -> Set<String> {
        checks.withLockedValue { $0 += 1 }
        return present.withLockedValue { $0 }.intersection(macs)
    }

    func devices() async -> [NetworkDevice] { listed.withLockedValue { $0 } }

    var checkCount: Int { checks.withLockedValue { $0 } }
}

/// A clock the test moves.
final class FakeClock: Sendable {
    private let time = NIOLockedValueBox(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLockedValue { $0 } }
    func advance(minutes: Double) { time.withLockedValue { $0 += minutes * 60 } }
}

/// A host with one Presence block on the fake network and clock.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Presence-tests-\(UUID().uuidString)")
    let source = FakeSource()
    let clock = FakeClock()
    private let plugins = NIOLockedValueBox<[PresencePlugin]>([])

    var plugin: PresencePlugin? { plugins.withLockedValue { $0.last } }

    var registry: PluginRegistry {
        var registry = PluginRegistry()
        registry.register(platform: PresencePlugin.platform, name: PresencePlugin.name, addsDevicesByAddress: true, newDeviceLabel: PresencePlugin.newDeviceLabel) { json, context in
            let configuration = try JSONDecoder().decode(PresencePlugin.Configuration.self, from: json)
            let clock = self.clock
            let plugin = PresencePlugin(configuration: configuration, context: context, dependencies: .init(source: self.source, timeScale: 0.0005, now: { clock.now }))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        return registry
    }

    func start(settings: [String: Any] = [:]) async throws -> PluginHost {
        let block = try HomeswiftConfiguration.Platform(platform: PresencePlugin.platform, name: PresencePlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// Waits for `count` more checks of the network than now.
    func checks(_ count: Int) async -> Bool {
        let target = source.checkCount + count
        return await eventually { self.source.checkCount >= target }
    }
}

/// Polls `condition` until it holds or `timeout` passes: generous, for a machine under load.
func eventually(timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// The events the board tells, in order.
final class BoardEvents: Sendable {
    let events = NIOLockedValueBox<[PresenceEvent]>([])
    var all: [PresenceEvent] { events.withLockedValue { $0 } }
}

var twoPersons: [String: Any] { ["_accessories": [
    "person-00000001": ["name": "Alex", "devices": [phone.lowercased(), watch], "user": "alex"],
    "person-00000002": ["name": "Sam", "devices": [laptop]],
]] }

@Suite(.timeLimit(.minutes(2)))
struct PresenceTests {
    let environment = TestEnvironment()
    let alex = PresencePlugin.accessoryID("person-00000001")
    let sam = PresencePlugin.accessoryID("person-00000002")
    let anyone = PresencePlugin.accessoryID("anyone")

    func occupancy(_ host: PluginHost, _ id: String) -> Int? {
        host.mainBridge.server.accessories.first { $0.id == id }?.service(.occupancySensor)?[.occupancyDetected]?.value.intValue
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(PresencePlugin.Configuration.self, from: Data(#"{"platform":"Presence"}"#.utf8))
        #expect(configuration.graceMinutes == nil)
        #expect(PresencePlugin.grace(configuration) == 600)
        #expect(PresencePlugin.grace(.init(graceMinutes: 0.1)) == 60)
    }

    @Test func eachPersonIsAnOccupancySensorBesideAnyoneHome() async throws {
        let host = try await environment.start(settings: twoPersons)
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == anyone } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == alex })
        #expect(accessory.information.characteristic(.name).value == .string("Alex"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("person-00000001"))
        #expect(accessory.service(.occupancySensor)?.isPrimary == true)
        #expect(host.mainBridge.server.accessories.contains { $0.id == sam })
        await host.stop()
    }

    @Test func anExcludedPersonIsLeftOut() async throws {
        let host = try await environment.start(settings: ["_accessories": ["person-00000001": ["name": "Alex", "devices": [phone], "excluded": true], "anyone": ["excluded": true]]])
        #expect(await environment.checks(2))
        #expect(!host.mainBridge.server.accessories.contains { $0.id == alex || $0.id == anyone })
        #expect(host.presence.persons.isEmpty)
        await host.stop()
    }

    @Test func aPersonArrivesWhenOneOfTheirDevicesIsOnTheNetwork() async throws {
        let host = try await environment.start(settings: twoPersons)
        let events = BoardEvents()
        let observation = host.presence.observe { event in events.events.withLockedValue { $0.append(event) } }
        defer { observation.cancel() }
        #expect(await environment.checks(2))
        #expect(occupancy(host, alex) == 0)
        #expect(occupancy(host, anyone) == 0)
        #expect(host.presence.anyoneHome == false)

        environment.source.present.withLockedValue { $0 = [watch] }
        #expect(await eventually { occupancy(host, alex) == 1 })
        #expect(await eventually { occupancy(host, anyone) == 1 })
        #expect(occupancy(host, sam) == 0)
        let person = try #require(host.presence.persons.first { $0.id == alex })
        #expect(person.isHome && person.user == "alex" && person.since == environment.clock.now)
        #expect(host.presence.persons(of: "alex").map(\.id) == [alex])
        #expect(await eventually { events.all.count == 2 })
        #expect(events.all.last == .anyoneHome(true))
        if case .arrived(let arrived) = events.all.first { #expect(arrived.id == alex) } else { Issue.record("no arrival: \(events.all)") }
        await host.stop()
    }

    @Test func aPersonLeavesOnlyOnceTheGracePeriodIsOver() async throws {
        let host = try await environment.start(settings: twoPersons.merging(["graceMinutes": 10]) { $1 })
        environment.source.present.withLockedValue { $0 = [phone] }
        #expect(await eventually { occupancy(host, alex) == 1 })
        let seen = environment.clock.now

        // Gone for nine minutes: still home, however many checks run.
        environment.source.present.withLockedValue { $0 = [] }
        environment.clock.advance(minutes: 9)
        #expect(await environment.checks(5))
        #expect(occupancy(host, alex) == 1)

        // Ten: away, since the last time the phone was seen.
        environment.clock.advance(minutes: 1)
        #expect(await eventually { occupancy(host, alex) == 0 })
        #expect(await eventually { occupancy(host, anyone) == 0 })
        #expect(host.presence.persons.first { $0.id == alex }?.since == seen)
        await host.stop()
    }

    @Test func aRestartWithinTheGracePeriodKeepsAPersonHome() async throws {
        let first = try await environment.start(settings: twoPersons)
        environment.source.present.withLockedValue { $0 = [laptop] }
        #expect(await eventually { occupancy(first, sam) == 1 })
        await first.stop()

        environment.source.present.withLockedValue { $0 = [] }
        environment.clock.advance(minutes: 5)
        let second = try await environment.start(settings: twoPersons)
        #expect(await environment.checks(3))
        #expect(occupancy(second, sam) == 1)
        environment.clock.advance(minutes: 6)
        #expect(await eventually { occupancy(second, sam) == 0 })
        await second.stop()
    }

    @Test func addingAPersonAsksTheirNameThenTheirDevices() async throws {
        let host = try await environment.start()
        host.webUsers = { [WebUser(username: "alex", name: "Alex Martin")] }
        environment.source.listed.withLockedValue {
            $0 = [NetworkDevice(mac: phone, address: "192.168.1.20", name: "Alex’s iPhone"), NetworkDevice(mac: "06:11:22:33:44:55", address: "192.168.1.21")]
        }
        let plugin = try #require(environment.plugin)

        guard case .ask(let first, let firstState) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no first prompt"); return }
        #expect(first.fields.map(\.key) == ["name", "user"])
        #expect(first.fields[1].options.map(\.value) == ["alex"])
        #expect(firstState.isNull)

        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["name": "Alex", "user": "nobody"])) }
        guard case .ask(let second, let kept) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["name": "Alex", "user": "alex"])) else {
            Issue.record("no second prompt"); return
        }
        let devices = try #require(second.fields.first)
        #expect(devices.kind == .choices)
        #expect(devices.options.map(\.label) == ["Alex’s iPhone", "192.168.1.21"])
        #expect(devices.options[1].badge == "Private address")
        #expect(devices.options[0].badge == nil)
        #expect(second.warning?.contains("Fixed") == true)
        #expect(kept["name"] == "Alex")

        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["devices": "\(phone)\n06-11-22-33-44-55"], state: kept)) else {
            Issue.record("not done"); return
        }
        #expect(outcome.deviceID?.hasPrefix("person-") == true)
        #expect(outcome.settings["name"] == "Alex")
        #expect(outcome.settings["user"] == "alex")
        #expect(outcome.settings["devices"] == [.string(phone), "06:11:22:33:44:55"])
        await host.stop()
    }

    @Test func discoveryListsAnyoneHomeThenThePersons() async throws {
        let host = try await environment.start(settings: twoPersons)
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID) == ["anyone", "person-00000001", "person-00000002"])
        #expect(found.allSatisfy { $0.isSetUp })
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(PresencePlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Presence PresencePlugin")
        let schema = try JSONValue(string: try #require(PresencePlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Presence")
    }
}

@Suite struct PresenceBoardTests {
    @Test func aChangeAcrossAReloadIsStillTold() {
        let board = PresenceBoard()
        let events = BoardEvents()
        let observation = board.observe { event in events.events.withLockedValue { $0.append(event) } }
        defer { observation.cancel() }
        board.publish([PersonPresence(id: "Presence:person-1", name: "Alex", isHome: true)])
        #expect(events.all.isEmpty)
        board.clear()
        #expect(board.anyoneHome == nil && board.persons.isEmpty)
        board.publish([PersonPresence(id: "Presence:person-1", name: "Alex", isHome: false)])
        #expect(events.all.count == 2)
        if case .left(let person) = events.all.first { #expect(person.name == "Alex") } else { Issue.record("no departure: \(events.all)") }
        #expect(events.all.last == .anyoneHome(false))
    }
}

@Suite struct PresenceTrackerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let alex = Person(id: "person-1", name: "Alex", devices: [phone], user: nil)

    @Test func aPersonNeverSeenIsAwayFromTheFirstCheck() {
        var tracker = PresenceTracker(grace: 600)
        let (changed, _) = tracker.update([alex], seen: [], at: start)
        #expect(changed == ["person-1"])
        #expect(tracker.state(of: "person-1") == PersonState(isHome: false, since: start))
    }

    @Test func homeUntilTheGracePeriodPassesSinceTheLastSighting() {
        var tracker = PresenceTracker(grace: 600)
        _ = tracker.update([alex], seen: [phone], at: start)
        _ = tracker.update([alex], seen: [phone], at: start + 60)
        #expect(tracker.update([alex], seen: [], at: start + 659).changed.isEmpty)
        #expect(tracker.update([alex], seen: [], at: start + 660).changed == ["person-1"])
        #expect(tracker.state(of: "person-1") == PersonState(isHome: false, since: start + 60, lastSeen: start + 60))
    }

    @Test func aPersonTakenOffIsForgotten() {
        var tracker = PresenceTracker(grace: 600)
        _ = tracker.update([alex], seen: [phone], at: start)
        #expect(tracker.update([], seen: [], at: start).dirty)
        #expect(tracker.states.isEmpty)
    }
}

/// The ARP table and probes as the test sets them.
final class FakeNetwork: LocalNetwork {
    let table = NIOLockedValueBox<[(ip: String, mac: String)]>([])
    /// The table once the networks are resolved; nil leaves it as it is.
    let resolved = NIOLockedValueBox<[(ip: String, mac: String)]?>(nil)
    /// The table after the probes: another device took the address.
    let afterProbe = NIOLockedValueBox<[(ip: String, mac: String)]?>(nil)
    let reachable = NIOLockedValueBox<Set<String>>([])
    let resolves = NIOLockedValueBox(0)

    func arpEntries() async -> [(ip: String, mac: String)] { table.withLockedValue { $0 } }

    func resolve(lookingFor macs: Set<String>) async {
        resolves.withLockedValue { $0 += 1 }
        if let resolved = resolved.withLockedValue({ $0 }) { table.withLockedValue { $0 = resolved } }
    }

    func isReachable(_ ip: String) async -> Bool {
        if let after = afterProbe.withLockedValue({ $0 }) { table.withLockedValue { $0 = after } }
        return reachable.withLockedValue { $0 }.contains(ip)
    }

    func names(of ips: [String]) async -> [String: String] { ["192.168.1.20": "Alex’s iPhone"].filter { ips.contains($0.key) } }
}

@Suite struct NetworkPresenceSourceTests {
    @Test func aDeviceCountsWhenItsAddressAnswers() async {
        let network = FakeNetwork()
        network.table.withLockedValue { $0 = [("192.168.1.20", phone), ("192.168.1.21", watch)] }
        network.reachable.withLockedValue { $0 = ["192.168.1.20"] }
        let source = NetworkPresenceSource(network: network)
        #expect(await source.seen([phone, watch]) == [phone])
        #expect(network.resolves.withLockedValue { $0 } == 0)
    }

    @Test func aDeviceMissingFromTheTableIsLookedFor() async {
        let network = FakeNetwork()
        network.resolved.withLockedValue { $0 = [("192.168.1.20", phone)] }
        network.reachable.withLockedValue { $0 = ["192.168.1.20"] }
        #expect(await NetworkPresenceSource(network: network).seen([phone]) == [phone])
        #expect(network.resolves.withLockedValue { $0 } == 1)
    }

    @Test func anAddressGivenToAnotherDeviceDoesNotCount() async {
        let network = FakeNetwork()
        network.table.withLockedValue { $0 = [("192.168.1.20", phone)] }
        network.afterProbe.withLockedValue { $0 = [("192.168.1.20", laptop)] }
        network.reachable.withLockedValue { $0 = ["192.168.1.20"] }
        #expect(await NetworkPresenceSource(network: network).seen([phone]).isEmpty)
    }

    @Test func theNetworksAreSweptAtMostSoOften() async {
        let network = FakeNetwork()
        let source = NetworkPresenceSource(network: network, sweepEvery: .seconds(3600))
        #expect(await source.seen([phone]).isEmpty)
        #expect(await source.seen([phone]).isEmpty)
        #expect(network.resolves.withLockedValue { $0 } == 1)
    }

    @Test func devicesAreListedNamedFirst() async {
        let network = FakeNetwork()
        network.table.withLockedValue { $0 = [("192.168.1.9", laptop), ("192.168.1.20", phone)] }
        let devices = await NetworkPresenceSource(network: network).devices()
        #expect(devices.map(\.mac) == [phone, laptop])
        #expect(devices[1].isPrivate)
        #expect(!devices[0].isPrivate)
    }

    @Test func namesReadAsPeopleWriteThem() {
        #expect(NetworkNames.instance(of: "Alex’s iPhone._companion-link._tcp.local") == "Alex’s iPhone")
        #expect(NetworkNames.instance(of: "printer._ipp._tcp.local") == nil)
        #expect(NetworkNames.hostLabel("Galaxy-S24.lan", ip: "192.168.1.30") == "Galaxy-S24")
        #expect(NetworkNames.hostLabel("192-168-1-30.isp.example", ip: "192.168.1.30") == nil)
    }
}
