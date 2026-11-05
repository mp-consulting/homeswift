import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftAPsystemsECU

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// An ECU in memory: answers each command with its frame, counts the requests.
actor FakeECU: ECUExchanging {
    var frames: [ECUCommand: [UInt8]] = [
        .system: Vectors.bytes(Vectors.v1), .realTime: Vectors.bytes(Vectors.v4), .signal: Vectors.bytes(Vectors.v11),
    ]
    var reachable = true
    private(set) var requests: [String] = []
    private(set) var hosts: [String] = []
    /// How long each answer takes, and the most requests it had at once.
    var delay: Duration = .zero
    private var inFlight = 0
    private(set) var mostAtOnce = 0

    func exchange(_ request: [UInt8], host: String, port: Int) async throws -> [UInt8] {
        let command = String(decoding: request[9..<13], as: UTF8.self)
        requests.append(command)
        hosts.append(host)
        inFlight += 1
        mostAtOnce = max(mostAtOnce, inFlight)
        defer { inFlight -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard reachable else { throw HTTPClientError.cannotConnect(host: host, port: port, code: 61, reason: "connection refused") }
        guard let frame = ECUCommand(rawValue: command).flatMap({ frames[$0] }) else { throw ECUTransportError.timeout }
        return frame
    }

    func set(_ command: ECUCommand, _ frame: [UInt8]?) { frames[command] = frame }
    func set(reachable: Bool) { self.reachable = reachable }
    func set(delay: Duration) { self.delay = delay }
    func count(_ command: ECUCommand) -> Int { requests.filter { $0 == command.rawValue }.count }
}

/// An ECU-C's meter page in memory.
actor FakeMeter: ECUMeterReading {
    var answer: ECUMeter? = ECUMeter(production: [3000, 2500, 2672], grid: [-1000, 200, 300])
    private(set) var requests = 0

    func meter(host: String) async throws -> ECUMeter {
        requests += 1
        guard let answer else { throw ECUTransportError.timeout }
        return answer
    }

    func set(_ answer: ECUMeter?) { self.answer = answer }
}

/// A host with one platform block whose plugin talks to the fakes, every delay scaled down.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-APsystemsECU-tests-\(UUID().uuidString)")
    let ecu = FakeECU()
    let meter = FakeMeter()
    private let plugins = NIOLockedValueBox<[APsystemsECUPlugin]>([])
    /// Every reading recorded, in order.
    let readings = NIOLockedValueBox<[(series: String, value: Double, tag: EnergyTag?)]>([])
    private let observation = NIOLockedValueBox<Observation?>(nil)

    var plugin: APsystemsECUPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = ["ecus": [["host": "192.0.2.10"]]], timeScale: Double = 0.0001) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: APsystemsECUPlugin.platform, name: APsystemsECUPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(APsystemsECUPlugin.Configuration.self, from: json)
            let plugin = APsystemsECUPlugin(
                configuration: configuration, context: context, dependencies: .init(exchange: self.ecu, meter: self.meter, timeScale: timeScale))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: APsystemsECUPlugin.platform, name: APsystemsECUPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        let readings = self.readings
        observation.withLockedValue { $0 = host.observeReadings { series, value, tag in readings.withLockedValue { $0.append((series, value, tag)) } } }
        try await host.start()
        return host
    }

    func values(_ series: String) -> [Double] {
        readings.withLockedValue { $0.filter { $0.series == "plugin:APsystemsECU:\(series)" }.map(\.value) }
    }

    func tag(_ series: String) -> EnergyTag? {
        readings.withLockedValue { $0.last { $0.series == "plugin:APsystemsECU:\(series)" }?.tag }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? { mainBridge.server.accessories.first { $0.id == id } }
}

@Suite(.timeLimit(.minutes(1)))
struct APsystemsECUTests {
    let environment = TestEnvironment()
    let ecuID = APsystemsECUPlugin.accessoryID(deviceID: "215000999901")
    let inverterID = APsystemsECUPlugin.accessoryID(deviceID: "703000999002")

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(APsystemsECUPlugin.Configuration.self, from: Data(#"{"platform":"APsystemsECU"}"#.utf8))
        #expect(configuration.ecus == nil)
        #expect(configuration.pollInterval == nil)
        let full = try JSONDecoder().decode(APsystemsECUPlugin.Configuration.self, from: Data(
            #"{"platform":"APsystemsECU","ecus":[{"host":"10.0.0.5","port":8899,"name":"Roof"}],"pollInterval":120,"connectRetries":3,"inverters":false,"meter":false}"#.utf8))
        #expect(full.ecus == [.init(host: "10.0.0.5", port: 8899, name: "Roof")])
        #expect(full.inverters == false && full.meter == false && full.connectRetries == 3)
    }

    @Test func notConfiguredCostsNothing() async throws {
        let host = try await environment.start(settings: [:])
        _ = try #require(environment.plugin)
        #expect(await environment.ecu.requests.isEmpty)
        #expect(host.mainBridge.server.accessories.allSatisfy { !$0.id.hasPrefix("APsystemsECU:") })
        await host.stop()
    }

    @Test func theECUAndItsInvertersBecomeAccessories() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(ecuID) != nil && host.accessory(inverterID) != nil })
        let ecu = try #require(host.accessory(ecuID))
        #expect(ecu.information.characteristic(.name).value == .string("ECU-C 215000999901"))
        #expect(ecu.information.characteristic(.manufacturer).value == .string("APsystems"))
        #expect(ecu.information.characteristic(.model).value == .string("ECU-C"))
        #expect(ecu.information.characteristic(.serialNumber).value == .string("215000999901"))
        #expect(ecu.information.characteristic(.firmwareRevision).value == .string("1.2.24"))
        let solar = try #require(ecu.service(.lightSensor))
        #expect(solar.isPrimary)
        #expect(solar[.currentAmbientLightLevel]?.value == .double(8172))
        #expect(solar[.statusActive]?.value == .bool(true))
        #expect(solar[.statusFault]?.value == .int(0))
        #expect(solar[EveCharacteristic.currentConsumption]?.value == .int(8172))
        #expect(solar[EveCharacteristic.totalConsumption]?.value == .double(18132.9))

        let inverter = try #require(host.accessory(inverterID))
        #expect(inverter.information.characteristic(.model).value == .string("DS3 series"))
        #expect(inverter.information.characteristic(.name).value == .string("Inverter 703000999002"))
        #expect(inverter.service(.lightSensor)?[.currentAmbientLightLevel]?.value == .double(174))
        #expect(inverter.service(.lightSensor)?[.statusActive]?.value == .bool(true))
        #expect(inverter.service(.temperatureSensor)?[.currentTemperature]?.value == .double(33))
        // The registered-only inverter has no accessory until it reports.
        #expect(host.accessory(APsystemsECUPlugin.accessoryID(deviceID: "703000999001")) == nil)
        await host.stop()
    }

    @Test func theProductionAndTheMeterReachTheEnergySection() async throws {
        let host = try await environment.start()
        #expect(await eventually { !environment.values("215000999901:home").isEmpty })
        #expect(environment.values("215000999901:solar").first == 8172)
        #expect(environment.tag("215000999901:solar") == EnergyTag(role: .solar, device: "ECU-C 215000999901"))
        #expect(environment.values("215000999901:grid").first == -500)
        #expect(environment.tag("215000999901:grid")?.role == .grid)
        #expect(environment.values("215000999901:home").first == 7672)
        #expect(environment.tag("215000999901:home")?.role == .home)
        #expect(environment.values("703000999002:power").first == 174)
        #expect(environment.values("703000999002:power1").first == 88)
        #expect(environment.values("703000999002:temperature").first == 33)
        #expect(environment.values("703000999002:signal").first == 81)
        await host.stop()
    }

    @Test func aFailingMeterNeverFailsThePoll() async throws {
        await environment.meter.set(nil)
        let host = try await environment.start()
        #expect(await eventually { await environment.meter.requests >= 2 })
        #expect(host.accessory(ecuID)?.service(.lightSensor)?[.statusActive]?.value == .bool(true))
        #expect(environment.values("215000999901:grid").isEmpty)
        #expect(environment.values("215000999901:home").isEmpty)
        #expect(!environment.values("215000999901:solar").isEmpty)
        await host.stop()
    }

    @Test func theMeterIsAskedOnlyOfAnECUCAndOnlyWhenOn() async throws {
        await environment.ecu.set(.system, Vectors.bytes(Vectors.v3))
        let host = try await environment.start()
        #expect(await eventually { await environment.ecu.count(.system) >= 3 })
        #expect(await environment.meter.requests == 0)
        await host.stop()

        let other = TestEnvironment()
        let second = try await other.start(settings: ["ecus": [["host": "192.0.2.10"]], "meter": false])
        #expect(await eventually { await other.ecu.count(.system) >= 3 })
        #expect(await other.meter.requests == 0)
        await second.stop()
    }

    @Test func threeRequestsPerPollEachOnItsOwnConnection() async throws {
        let host = try await environment.start()
        #expect(await eventually { await environment.ecu.count(.system) >= 4 })
        await host.stop()
        let requests = await environment.ecu.requests
        // System, real-time, signal, in that order, and nothing else.
        let polls = requests.count / 3
        #expect(Array(requests.prefix(polls * 3)) == Array(repeating: ["0001", "0002", "0030"], count: polls).flatMap { $0 })
        #expect(await environment.meter.requests <= polls + 1)
    }

    @Test func aPollIsSpacedByTheInterval() async throws {
        // 60 s (the floor) at a scale of 1/1000: 60 ms between polls, so 300 ms hold at most 6 polls.
        let host = try await environment.start(settings: ["ecus": [["host": "192.0.2.10"]], "pollInterval": 1], timeScale: 0.001)
        #expect(await eventually { await environment.ecu.count(.system) >= 2 })
        let start = ContinuousClock.now
        let before = await environment.ecu.count(.system)
        try await Task.sleep(for: .milliseconds(300))
        let elapsed = ContinuousClock.now - start
        let polls = await environment.ecu.count(.system) - before
        await host.stop()
        #expect(polls <= Int(elapsed / .milliseconds(60)) + 1)
    }

    @Test func anUnreachableECUKeepsItsValuesNotActive() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(inverterID) != nil })
        await environment.ecu.set(reachable: false)
        let solar = try #require(host.accessory(ecuID)?.service(.lightSensor))
        #expect(await eventually { solar[.statusActive]?.value == .bool(false) })
        #expect(await eventually { solar[.statusFault]?.value == .int(1) })
        // The last values stay; the inverter's too, not active.
        #expect(solar[.currentAmbientLightLevel]?.value == .double(8172))
        let inverter = try #require(host.accessory(inverterID))
        #expect(inverter.service(.lightSensor)?[.statusActive]?.value == .bool(false))
        #expect(inverter.service(.temperatureSensor)?[.currentTemperature]?.value == .double(33))
        // Nothing recorded while it is down.
        let recorded = environment.values("215000999901:solar").count
        let failed = await environment.ecu.requests.count
        #expect(await eventually { await environment.ecu.requests.count >= failed + 3 })
        #expect(environment.values("215000999901:solar").count == recorded)
        // Back.
        await environment.ecu.set(reachable: true)
        #expect(await eventually { solar[.statusActive]?.value == .bool(true) && solar[.statusFault]?.value == .int(0) })
        #expect(await eventually { inverter.service(.lightSensor)?[.statusActive]?.value == .bool(true) })
        await host.stop()
    }

    @Test func aRestartWithTheECUDownShowsTheCachedAccessoriesNotActive() async throws {
        let first = try await environment.start()
        #expect(await eventually { first.accessory(inverterID)?.service(.lightSensor)?[.statusActive]?.value == .bool(true) })
        await first.stop()
        await environment.ecu.set(reachable: false)
        let host = try await environment.start()
        let solar = try #require(host.accessory(ecuID)?.service(.lightSensor))
        #expect(await eventually { solar[.statusActive]?.value == .bool(false) })
        #expect(await eventually { host.accessory(inverterID)?.service(.lightSensor)?[.statusActive]?.value == .bool(false) })
        await host.stop()
    }

    @Test func aProbeNeverTalksToTheECUDuringAPoll() async throws {
        await environment.ecu.set(delay: .milliseconds(20))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await plugin.probe(host: "192.0.2.10", port: 8899) } }
            try await group.waitForAll()
        }
        #expect(await eventually { await environment.ecu.count(.realTime) >= 2 })
        #expect(await environment.ecu.mostAtOnce == 1)
        await host.stop()
    }

    @Test func aDayChangesOnTheBridgesDateWithoutRealTimeData() throws {
        let previous = try ECUProtocol.parseSystem(Vectors.bytes(Vectors.v1))
        var morning = previous
        morning.todayEnergy = previous.todayEnergy / 2
        let yesterday = APsystemsECUPlugin.localDay(Date(timeIntervalSinceNow: -86_400))
        let today = APsystemsECUPlugin.localDay(Date())
        #expect(today.count == 8 && today != yesterday)
        #expect(APsystemsECUPlugin.filtered(morning, previous: previous, previousDate: yesterday, newDate: today).todayEnergy == morning.todayEnergy)
        #expect(APsystemsECUPlugin.filtered(morning, previous: previous, previousDate: today, newDate: today).todayEnergy == previous.todayEnergy)
    }

    @Test func backsOffAfterThreeFailures() async throws {
        let (host, context) = try await bareContext()
        defer { Task { await host.stop() } }
        let plugin = APsystemsECUPlugin(configuration: .init(ecus: [.init(host: "h")]), context: context, dependencies: .init(exchange: FakeECU(), timeScale: 1))
        var ecu = ECURuntime(host: "h", port: 8899, configuredName: nil)
        #expect(await plugin.nextDelay(ecu) == .seconds(300))
        ecu.failures = 3
        #expect(await plugin.nextDelay(ecu) == .seconds(600))
        ecu.failures = 0
        ecu.system = try ECUProtocol.parseSystem(Vectors.bytes(Vectors.v2))
        #expect(await plugin.nextDelay(ecu) == .seconds(900))
    }

    @Test func atNightTheInvertersKeepTheirTemperature() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(inverterID) != nil })
        // V9's DS3s are other inverters; the night frame for this one: offline, every field 0.
        var night = Vectors.bytes(Vectors.v4)
        night.replaceSubrange((26 + 9 + 6)..<(26 + 9 + 7), with: [0])
        for offset in (26 + 9 + 9)..<(26 + 9 + 21) { night[offset] = 0 }
        await environment.ecu.set(.realTime, night)
        await environment.ecu.set(.system, Vectors.bytes(Vectors.v2))
        let inverter = try #require(host.accessory(inverterID))
        #expect(await eventually { inverter.service(.temperatureSensor)?[.statusActive]?.value == .bool(false) })
        #expect(inverter.service(.temperatureSensor)?[.currentTemperature]?.value == .double(33))
        #expect(await eventually { inverter.service(.lightSensor)?[.currentAmbientLightLevel]?.value == .double(0.0001) })
        // Solar 0 is recorded at night, the −100 °C never.
        #expect(await eventually { environment.values("215000999901:solar").contains(0) })
        #expect(!environment.values("703000999002:temperature").contains(-100))
        await host.stop()
    }

    @Test func noRecordsKeepTheInvertersNotActive() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(inverterID) != nil })
        await environment.ecu.set(.realTime, Vectors.bytes(Vectors.v10))
        let inverter = try #require(host.accessory(inverterID))
        #expect(await eventually { inverter.service(.lightSensor)?[.statusActive]?.value == .bool(false) })
        #expect(inverter.service(.lightSensor)?[.currentAmbientLightLevel]?.value == .double(174))
        #expect(host.accessory(ecuID)?.service(.lightSensor)?[.statusActive]?.value == .bool(true))
        await host.stop()
    }

    @Test func invertersOffMakesNoInverterAccessory() async throws {
        let host = try await environment.start(settings: ["ecus": [["host": "192.0.2.10"]], "inverters": false])
        #expect(await eventually { await environment.ecu.count(.system) >= 2 })
        #expect(host.accessory(ecuID) != nil)
        #expect(host.accessory(inverterID) == nil)
        await host.stop()
    }

    @Test func anExcludedECUIsNotPolledAgain() async throws {
        let host = try await environment.start(settings: ["ecus": [["host": "192.0.2.10"]], "_accessories": ["215000999901": ["excluded": true]]])
        #expect(await eventually { await environment.ecu.count(.system) == 1 })
        // Several of its intervals (30 ms here) later, still the one system query that told its id.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await environment.ecu.count(.system) == 1)
        #expect(await environment.ecu.count(.realTime) == 0)
        #expect(host.accessory(ecuID) == nil)
        await host.stop()
    }

    // MARK: The filters (5.2)

    @Test func theFiltersKeepThePreviousValues() throws {
        let previous = try ECUProtocol.parseSystem(Vectors.bytes(Vectors.v1))
        var glitch = previous
        glitch.inverters = 0
        glitch.lifetimeEnergy = 0
        glitch.todayEnergy = 0
        let kept = APsystemsECUPlugin.filtered(glitch, previous: previous, previousDate: "20260503", newDate: "20260503")
        #expect(kept.inverters == 7 && kept.lifetimeEnergy == 18132.9 && kept.todayEnergy == 30.12)
        // A lifetime that drops is ignored; a today that drops on the same day with inverters online too.
        var lower = previous
        lower.lifetimeEnergy = 18000
        lower.todayEnergy = 12
        let monotonic = APsystemsECUPlugin.filtered(lower, previous: previous, previousDate: "20260503", newDate: "20260503")
        #expect(monotonic.lifetimeEnergy == 18132.9 && monotonic.todayEnergy == 30.12)
        // The midnight reset: a new date, or no inverter online.
        #expect(APsystemsECUPlugin.filtered(lower, previous: previous, previousDate: "20260503", newDate: "20260504").todayEnergy == 12)
        var night = lower
        night.invertersOnline = 0
        night.todayEnergy = 0
        #expect(APsystemsECUPlugin.filtered(night, previous: previous, previousDate: nil, newDate: nil).todayEnergy == 0)
        // Higher values pass.
        var higher = previous
        higher.lifetimeEnergy = 18133.5
        higher.todayEnergy = 31.1
        let passed = APsystemsECUPlugin.filtered(higher, previous: previous, previousDate: "20260503", newDate: "20260503")
        #expect(passed.lifetimeEnergy == 18133.5 && passed.todayEnergy == 31.1)
    }

    @Test func aGlitchNeverReachesHomeKit() async throws {
        let host = try await environment.start()
        let ecu = try #require(await eventually { host.accessory(ecuID) != nil } ? host.accessory(ecuID) : nil)
        var glitch = Vectors.bytes(Vectors.v1)
        // Lifetime 0 and today 0, with 7 online.
        for offset in 27..<31 { glitch[offset] = 0 }
        for offset in 35..<39 { glitch[offset] = 0 }
        await environment.ecu.set(.system, glitch)
        let before = await environment.ecu.count(.system)
        #expect(await eventually { await environment.ecu.count(.system) >= before + 2 })
        #expect(ecu.service(.lightSensor)?[EveCharacteristic.totalConsumption]?.value == .double(18132.9))
        await host.stop()
    }

    // MARK: Setup

    @Test func discoverListsTheECUByItsIdAndItsInverters() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(inverterID) != nil })
        let found = try await host.discover(platform: APsystemsECUPlugin.platform, name: APsystemsECUPlugin.name)
        let ecu = try #require(found.devices.first { $0.deviceID == "215000999901" })
        #expect(ecu.model == "ECU-C" && ecu.address == "192.0.2.10" && ecu.isSetUp && ecu.authorization == .none && ecu.kind == "ecu")
        #expect(found.devices.contains { $0.deviceID == "703000999002" && $0.kind == "inverter" })
        #expect(!found.devices.contains { $0.deviceID == "703000999001" })
        #expect(found.accountState == .none)
        await host.stop()
    }

    @Test func discoverConfirmsAnAddressWithTheSystemQuery() async throws {
        let (host, context) = try await bareContext()
        defer { Task { await host.stop() } }
        let plugin = APsystemsECUPlugin(
            configuration: .init(ecus: [.init(host: "192.0.2.10"), .init(host: "192.0.2.11", port: 9000, name: "Garage")]), context: context,
            dependencies: .init(exchange: environment.ecu))
        let devices = try await plugin.discover()
        #expect(devices.first?.deviceID == "215000999901")
        #expect(devices.first?.isReachable == true)
        await environment.ecu.set(reachable: false)
        let unreachable = try await APsystemsECUPlugin(
            configuration: .init(ecus: [.init(host: "192.0.2.11", port: 9000, name: "Garage")]), context: context,
            dependencies: .init(exchange: environment.ecu)).discover()
        #expect(unreachable.first?.deviceID == "address:192.0.2.11:9000")
        #expect(unreachable.first?.name == "Garage")
        #expect(unreachable.first?.isReachable == false)
    }

    @Test func theProbeRouteAnswersTheECUsId() async throws {
        let (host, context) = try await bareContext()
        defer { Task { await host.stop() } }
        let plugin = APsystemsECUPlugin(configuration: .init(), context: context, dependencies: .init(exchange: environment.ecu))
        let answer = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "probe", query: ["host": "192.0.2.10"], user: "test"))
        #expect(answer.status == 200)
        #expect(answer.json["ecuID"] == "215000999901")
        #expect(answer.json["model"] == "ECU-C")
        let missing = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "probe", user: "test"))
        #expect(missing.status == 400)
        await environment.ecu.set(.system, Vectors.bytes(Vectors.v4))
        let wrong = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "probe", query: ["host": "192.0.2.10"], user: "test"))
        #expect(wrong.status == 502)
    }

    @Test func addByAddressAsksTheECUAndKeysItByItsID() async throws {
        #expect(APsystemsECUPlugin.addsDevicesByAddress)
        let (host, context) = try await bareContext()
        defer { Task { await host.stop() } }
        let plugin = APsystemsECUPlugin(configuration: .init(), context: context, dependencies: .init(exchange: environment.ecu))
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["host", "port"] && prompt.fields[1].optional)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": " 192.0.2.10 "])) else {
            Issue.record("not done"); return
        }
        #expect(outcome.deviceID == "215000999901" && outcome.credentials == nil)
        #expect(outcome.settings == ["host": "192.0.2.10", "port": .null])
        guard case .done(let other) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.10", "port": "9000"])) else {
            Issue.record("not done"); return
        }
        #expect(other.settings["port"] == 9000)
        #expect(await environment.ecu.hosts.allSatisfy { $0 == "192.0.2.10" })
        await #expect(throws: SetupError("The port must be between 1 and 65535")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.10", "port": "0"]))
        }
        await environment.ecu.set(reachable: false)
        await #expect(throws: SetupError("No ECU answered at 192.0.2.60:8899")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.60"]))
        }
        guard case .done = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("the account asks nothing"); return }
    }

    /// An ECU whose Accessory Settings give its host is read there and listed by its id; the same ECU in `ecus` at
    /// another address is left aside once it answers.
    @Test func anECUAddedByAddressIsReadAtItsHost() async throws {
        let host = try await environment.start(settings: [
            "ecus": [["host": "192.0.2.99"]],
            "_accessories": ["215000999901": ["host": "192.0.2.20", "port": 9000]],
        ])
        #expect(await eventually { host.accessory(ecuID) != nil })
        #expect(await eventually { await environment.plugin?.order == ["192.0.2.20:9000"] })
        let found = try await host.discover(platform: APsystemsECUPlugin.platform, name: APsystemsECUPlugin.name)
        #expect(found.devices.first { $0.deviceID == "215000999901" }.map { $0.isSetUp && $0.address == "192.0.2.20:9000" } == true)
        await host.stop()
    }

    @Test func theStatusRouteShowsTheLastReading() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(inverterID) != nil })
        let plugin = try #require(environment.plugin)
        let answer = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "status", user: "test"))
        let ecu = try #require(answer.json["ecus"]?.arrayValue?.first)
        #expect(ecu["ecuID"] == "215000999901")
        #expect(ecu["power"]?.doubleValue == 8172)
        #expect(ecu["home"]?.doubleValue == 7672)
        let inverters = try #require(ecu["inverterList"]?.arrayValue)
        #expect(inverters.count == 2)
        #expect(inverters.contains { $0["uid"] == "703000999002" && $0["signal"]?.doubleValue == 81 && $0["temperature"]?.doubleValue == 33 })
        await host.stop()
    }

    @Test func canonicalSettingsMovesAnECUsNameOnceItsIdIsKnown() throws {
        let block = try JSONValue(string: #"{"platform":"APsystemsECU","ecus":[{"host":"192.0.2.10","name":"Roof"},{"host":"192.0.2.11","name":"Shed"}]}"#)
        let canonical = APsystemsECUPlugin.canonical(block, ecuIDs: ["192.0.2.10:8899": "215000999901"])
        #expect(canonical["_accessories"]?["215000999901"]?["name"] == "Roof")
        #expect(canonical["ecus"]?.arrayValue?.first?["name"] == nil)
        #expect(canonical["ecus"]?.arrayValue?.last?["name"] == "Shed")
        #expect(APsystemsECUPlugin.canonical(canonical, ecuIDs: ["192.0.2.10:8899": "215000999901"]) == canonical)
        #expect(APsystemsECUPlugin.canonical(block, ecuIDs: [:]) == block)
    }

    // MARK: The TCP client

    @Test func theClientReadsAFrameSplitAcrossReads() async throws {
        let stream = ChunkedStream(chunks: [Array(Vectors.bytes(Vectors.v4).prefix(40)), Array(Vectors.bytes(Vectors.v4).dropFirst(40))])
        let client = ECUClient(connect: { _, _, _ in stream })
        let frame = try await client.exchange(ECUProtocol.request(.realTime, ecuID: "215000999901"), host: "h", port: 8899)
        #expect(frame == Vectors.bytes(Vectors.v4))
        #expect(stream.sent == [ECUProtocol.request(.realTime, ecuID: "215000999901")])
        #expect(stream.closed)
    }

    @Test func theClientTimesOutAndRetriesTheConnect() async throws {
        let silent = ChunkedStream(chunks: [], finish: false)
        let slow = ECUClient(readTimeout: .milliseconds(50), connect: { _, _, _ in silent })
        await #expect(throws: ECUTransportError.timeout) { try await slow.exchange(ECUProtocol.systemRequest, host: "h", port: 8899) }
        #expect(silent.closed)

        let attempts = NIOLockedValueBox(0)
        let refused = ECUClient(retries: 3, retryDelay: .milliseconds(1), connect: { host, port, _ in
            attempts.withLockedValue { $0 += 1 }
            throw HTTPClientError.cannotConnect(host: host, port: port, code: 61, reason: "refused")
        })
        await #expect(throws: HTTPClientError.self) { try await refused.exchange(ECUProtocol.systemRequest, host: "h", port: 8899) }
        #expect(attempts.withLockedValue { $0 } == 3)

        let empty = ECUClient(connect: { _, _, _ in ChunkedStream(chunks: []) })
        await #expect(throws: ECUTransportError.closed(received: 0)) { try await empty.exchange(ECUProtocol.systemRequest, host: "h", port: 8899) }
    }

    @Test func theMeterClientAsksTheECUCsPage() async throws {
        let http = FakeHTTP(body: #"{"power1":[{"powerA":100,"powerB":0,"powerC":0}],"power2":[{"powerA":50,"powerB":0,"powerC":0}]}"#)
        let meter = try await ECUMeterClient(http: http).meter(host: "192.0.2.10")
        #expect(meter.homePower == 150)
        let request = try #require(http.requests.first)
        #expect(request.url.absoluteString == "http://192.0.2.10/index.php/meter/old_meter_power_graph")
        #expect(request.header("X-Requested-With") == "XMLHttpRequest")
        #expect(request.method == "GET")
        await #expect(throws: (any Error).self) { try await ECUMeterClient(http: FakeHTTP(body: "", status: 404)).meter(host: "h") }
    }

    // MARK: Helpers

    /// The schema is current.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(APsystemsECUPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/APsystemsECU APsystemsECUPlugin")
        let schema = try JSONValue(string: try #require(APsystemsECUPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "APsystemsECU")
    }

    @Test func webFilesAreCurrent() throws {
        let directory = Self.root.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names) == Set(APsystemsECUPlugin.webFiles.keys))
        for name in names {
            let file = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(APsystemsECUPlugin.webFiles[name]?.body == file,
                    "run: swift Scripts/embed-assets.swift web Plugins/APsystemsECU/Web Plugins/APsystemsECU/Sources/WebFiles.swift APsystemsECUPlugin (\(name))")
        }
    }

    /// A context for a plugin made outside the host's own: that of a block with no ECU, on a host of its own.
    func bareContext() async throws -> (PluginHost, PluginContext) {
        let host = try await TestEnvironment().start(settings: [:])
        return (host, try #require(host.context(platform: APsystemsECUPlugin.platform, name: APsystemsECUPlugin.name)))
    }
}

/// An HTTP server in memory: one answer, the requests kept.
final class FakeHTTP: HTTPSending, Sendable {
    let body: String
    let status: Int
    private let sent = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    var requests: [HomeswiftNetwork.HTTPRequest] { sent.withLockedValue { $0 } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        sent.withLockedValue { $0.append(request) }
        return HomeswiftNetwork.HTTPResponse(status: status, body: Data(body.utf8))
    }
}

/// A connection that delivers `chunks`, then ends (unless `finish` is false), recording what is sent.
final class ChunkedStream: ByteStream, @unchecked Sendable {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let state = NIOLockedValueBox<(sent: [[UInt8]], closed: Bool)>(([], false))

    init(chunks: [[UInt8]], finish: Bool = true) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        for chunk in chunks { continuation.yield(chunk) }
        if finish { continuation.finish() }
        incoming = stream
        // Kept so an unfinished stream stays open.
        self.continuation = continuation
    }

    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    var sent: [[UInt8]] { state.withLockedValue { $0.sent } }
    var closed: Bool { state.withLockedValue { $0.closed } }

    func send(_ bytes: [UInt8]) async throws { state.withLockedValue { $0.sent.append(bytes) } }
    func close() async {
        state.withLockedValue { $0.closed = true }
        continuation.finish()
    }
}
