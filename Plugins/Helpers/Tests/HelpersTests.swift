import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftHelpers

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Another plugin's accessories, the Helpers' sources: two temperature sensors, a power meter and a door.
struct FakeSources: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Fake"
    let context: PluginContext

    init(configuration: Configuration, context: PluginContext) {
        self.context = context
    }

    static func sensor(_ id: String, _ name: String, _ type: ServiceType, _ characteristic: CharacteristicType, _ value: HAPValue, extra: [Characteristic] = []) -> Accessory {
        let service = Service(type, name: name, extra: extra, isPrimary: true)
        service.characteristic(adding: characteristic).value = value
        return Accessory(id: "Fake:\(id)", name: name, manufacturer: "Test", model: "Test", serialNumber: id, category: .sensor, services: [service])
    }

    static func accessories() -> [Accessory] {
        [
            sensor("kitchen", "Kitchen", .temperatureSensor, .currentTemperature, .double(20)),
            sensor("bedroom", "Bedroom", .temperatureSensor, .currentTemperature, .double(18)),
            sensor("door", "Front door", .contactSensor, .contactSensorState, .int(0)),
            sensor("plug", "Plug", .outlet, .on, .bool(true), extra: [Characteristic(EveCharacteristic.currentConsumption, value: .int(40))]),
        ]
    }

    func start() async throws {
        for accessory in Self.accessories() { try context.add(accessory) }
    }
}

/// A host running the fake sources and a Helpers block with these Helpers' Accessory Settings.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Helpers-tests-\(UUID().uuidString)")
    private let plugins = NIOLockedValueBox<[HelpersPlugin]>([])
    /// A Stays' minute, short.
    let minute: Duration = .milliseconds(40)

    var plugin: HelpersPlugin? { plugins.withLockedValue { $0.last } }

    /// The reference of a source characteristic, as Setup writes it: its accessory's id and its iid on the bridge. The
    /// iids are the same on every host for the same accessories, so a first host with the sources alone tells them.
    static func ref(_ deviceID: String, _ type: CharacteristicType) async throws -> String {
        let host = try await start(helpers: nil)
        let iid = host.mainBridge.server.accessory(id: "Fake:\(deviceID)")?.services.flatMap(\.characteristics).first { $0.type.uuid == type.uuid }?.iid
        await host.stop()
        return "Fake:\(deviceID)#\(try #require(iid))"
    }

    private static func start(helpers: [String: [String: Any]]?, environment: TestEnvironment? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: FakeSources.platform, name: "Fake") { _, context in FakeSources(configuration: .init(), context: context) }
        var blocks = [try HomeswiftConfiguration.Platform(platform: FakeSources.platform, name: "Fake", settings: [:])]
        if let helpers, let environment {
            registry.register(platform: HelpersPlugin.platform, name: HelpersPlugin.name, addsDevicesByAddress: true) { _, context in
                let plugin = HelpersPlugin(context: context, dependencies: .init(minute: environment.minute, newID: { "new-helper" }))
                environment.plugins.withLockedValue { $0.append(plugin) }
                return plugin
            }
            blocks.append(try HomeswiftConfiguration.Platform(platform: HelpersPlugin.platform, name: HelpersPlugin.name, settings: ["_accessories": helpers]))
        }
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: blocks)
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let directory = environment?.directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Helpers-tests-\(UUID().uuidString)")
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    func start(helpers: [String: [String: Any]]) async throws -> PluginHost {
        try await Self.start(helpers: helpers, environment: self)
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

extension PluginHost {
    func characteristic(_ accessoryID: String, _ type: CharacteristicType) -> Characteristic? {
        mainBridge.server.accessory(id: accessoryID)?.services.lazy.compactMap { $0[type] }.first
    }

    func showsNoResponse(_ accessoryID: String) -> Bool {
        mainBridge.server.accessory(id: accessoryID)?.showsNoResponse ?? false
    }
}

@Suite(.timeLimit(.minutes(2)))
struct HelpersTests {
    let environment = TestEnvironment()

    // MARK: Rules

    @Test func thresholdTurnsOnAboveAndOffBelowTheOffValue() {
        let rule = { (was: Bool, value: Double) in HelperRule.threshold(was: was, value: value, above: true, on: 25, off: 23) }
        #expect(rule(false, 24) == false)
        #expect(rule(false, 25.5) == true)
        // Between the two it keeps its state: the hysteresis.
        #expect(rule(true, 24) == true)
        #expect(rule(true, 22.9) == false)
        let below = { (was: Bool, value: Double) in HelperRule.threshold(was: was, value: value, above: false, on: 10, off: 12) }
        #expect(below(false, 9) == true)
        #expect(below(true, 11) == true)
        #expect(below(true, 12.5) == false)
    }

    @Test func rulesReadTheirSettingsAndRefuseWhatCannotWork() throws {
        let threshold = try HelperRule(settings: ["rule": "threshold", "source": "Fake:a#9", "on": 25, "off": 23])
        #expect(threshold == .threshold(source: SourceRef(accessoryID: "Fake:a", iid: 9), above: true, on: 25, off: 23))
        // An off value past the on value would never turn it off.
        #expect(throws: RuleError.self) { try HelperRule(settings: ["rule": "threshold", "source": "Fake:a#9", "on": 25, "off": 30]) }
        #expect(throws: RuleError.self) { try HelperRule(settings: ["rule": "combine", "measure": "temperature", "sources": []]) }
        #expect(throws: RuleError.self) { try HelperRule(settings: ["rule": "teleport"]) }
        // An accessory id with a # in it still reads: the iid is after the last one.
        #expect(SourceRef("Fake:a#b#12") == SourceRef(accessoryID: "Fake:a#b", iid: 12))
        #expect(SourceRef("Fake:a") == nil)
        #expect(Function.average.apply([18, 20, 25]) == 21)
        #expect(Function.min.apply([18, 20]) == 18)
    }

    // MARK: On a bridge

    @Test func aThresholdFollowsItsSourceWithHysteresis() async throws {
        let kitchen = try await TestEnvironment.ref("kitchen", .currentTemperature)
        let host = try await environment.start(helpers: ["hot": ["name": "Kitchen hot", "rule": "threshold", "source": kitchen, "on": 25, "off": 23]])
        let id = "Helpers:hot"
        let source = try #require(host.characteristic("Fake:kitchen", .currentTemperature))
        #expect(await eventually { host.characteristic(id, .occupancyDetected)?.value == .int(0) && !host.showsNoResponse(id) })
        let accessory = try #require(host.mainBridge.server.accessory(id: id))
        #expect(accessory.name == "Kitchen hot")
        #expect(accessory.service(.occupancySensor)?.isPrimary == true)

        source.value = .double(26)
        #expect(await eventually { host.characteristic(id, .occupancyDetected)?.value == .int(1) })
        source.value = .double(24)
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.characteristic(id, .occupancyDetected)?.value == .int(1), "between the off and on values it stays on")
        source.value = .double(22)
        #expect(await eventually { host.characteristic(id, .occupancyDetected)?.value == .int(0) })
        await host.stop()
    }

    @Test func aCombineShowsTheAverageOfItsSensors() async throws {
        let kitchen = try await TestEnvironment.ref("kitchen", .currentTemperature)
        let bedroom = try await TestEnvironment.ref("bedroom", .currentTemperature)
        let plug = try await TestEnvironment.ref("plug", EveCharacteristic.currentConsumption)
        let host = try await environment.start(helpers: [
            "avg": ["name": "Average temperature", "rule": "combine", "measure": "temperature", "function": "average", "sources": [kitchen, bedroom]],
            "max": ["name": "Warmest", "rule": "combine", "measure": "temperature", "function": "max", "sources": [kitchen, bedroom]],
            "watts": ["name": "Power", "rule": "combine", "measure": "power", "function": "max", "sources": [plug]],
        ])
        #expect(await eventually { host.characteristic("Helpers:avg", .currentTemperature)?.value == .double(19) })
        #expect(await eventually { host.characteristic("Helpers:max", .currentTemperature)?.value == .double(20) })
        #expect(await eventually { host.characteristic("Helpers:watts", EveCharacteristic.currentConsumption)?.value == .int(40) })
        #expect(host.characteristic("Helpers:watts", .currentAmbientLightLevel)?.value == .double(40))
        host.characteristic("Fake:bedroom", .currentTemperature)?.value = .double(22)
        #expect(await eventually { host.characteristic("Helpers:avg", .currentTemperature)?.value == .double(21) })
        #expect(await eventually { host.characteristic("Helpers:max", .currentTemperature)?.value == .double(22) })
        await host.stop()
    }

    @Test func aStaysTurnsOnOnceItsSourceHasStayedLongEnough() async throws {
        let door = try await TestEnvironment.ref("door", .contactSensorState)
        // Open (1) for longer than 3 minutes, a minute being 40 ms here.
        let host = try await environment.start(helpers: ["open": ["name": "Door left open", "rule": "stays", "source": door, "state": "1", "minutes": 3]])
        let id = "Helpers:open"
        let source = try #require(host.characteristic("Fake:door", .contactSensorState))
        #expect(await eventually { !host.showsNoResponse(id) })
        let opened = ContinuousClock.now
        source.value = .int(1)
        #expect(await eventually { host.characteristic(id, .occupancyDetected)?.value == .int(1) })
        #expect(ContinuousClock.now - opened >= environment.minute * 3, "not before its duration")
        source.value = .int(0)
        #expect(await eventually { host.characteristic(id, .occupancyDetected)?.value == .int(0) })
        await host.stop()
    }

    @Test func aMissingOrUnreachableSourceMakesTheHelperNoResponse() async throws {
        let kitchen = try await TestEnvironment.ref("kitchen", .currentTemperature)
        let host = try await environment.start(helpers: [
            "hot": ["name": "Kitchen hot", "rule": "threshold", "source": kitchen, "on": 25],
            "ghost": ["name": "Ghost", "rule": "threshold", "source": "Fake:gone#9", "on": 25],
        ])
        #expect(await eventually { !host.showsNoResponse("Helpers:hot") })
        #expect(host.showsNoResponse("Helpers:ghost"))
        let source = try #require(host.mainBridge.server.accessory(id: "Fake:kitchen"))
        source.isUnreachable = true
        #expect(await eventually { host.showsNoResponse("Helpers:hot") })
        source.isUnreachable = false
        #expect(await eventually { !host.showsNoResponse("Helpers:hot") })
        await host.stop()
    }

    @Test func aHelperWhoseSettingsStopWorkingStaysNoResponse() async throws {
        let kitchen = try await TestEnvironment.ref("kitchen", .currentTemperature)
        let first = try await environment.start(helpers: ["hot": ["name": "Kitchen hot", "rule": "threshold", "source": kitchen, "on": 25]])
        #expect(await eventually { !first.showsNoResponse("Helpers:hot") })
        await first.stop()
        // Its off value edited past its on value: HomeKit keeps the accessory, and with it its room and automations.
        let second = try await environment.start(helpers: ["hot": ["name": "Kitchen hot", "rule": "threshold", "source": kitchen, "on": 25, "off": 30]])
        #expect(await eventually { second.mainBridge.server.accessory(id: "Fake:kitchen") != nil })
        #expect(second.mainBridge.server.accessory(id: "Helpers:hot") != nil)
        #expect(second.showsNoResponse("Helpers:hot"))
        await second.stop()
    }

    // MARK: Setup and settings

    @Test func setupAsksTheRuleThenItsSourcesAndEndsWithItsSettings() async throws {
        let host = try await environment.start(helpers: [:])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { host.mainBridge.server.accessory(id: "Fake:door") != nil })

        guard case .ask(let first, let state) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(first.fields.map(\.key) == ["rule"])
        guard case .ask(let measures, let state2) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["rule": "combine"], state: state)) else {
            Issue.record("no measure prompt"); return
        }
        // Only measures some accessory has.
        #expect(measures.fields.first?.options.map(\.value) == ["temperature", "power"])
        guard case .ask(let sensors, let state3) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["measure": "temperature"], state: state2)) else {
            Issue.record("no sensors prompt"); return
        }
        let options = try #require(sensors.fields.first { $0.key == "sources" }).options
        #expect(options.map(\.label) == ["Bedroom", "Kitchen"])
        #expect(options.map(\.detail) == ["Current Temperature", "Current Temperature"])
        // A name is needed, and only sensors listed are taken.
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["sources": options[0].value, "function": "max", "name": " "], state: state3))
        }
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["sources": "Fake:door#3", "function": "max", "name": "Warmest"], state: state3))
        }
        let picked = options.map(\.value).joined(separator: "\n")
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["sources": picked, "function": "max", "name": "Warmest"], state: state3)) else {
            Issue.record("not done"); return
        }
        #expect(outcome.deviceID == "new-helper")
        #expect(outcome.settings["rule"] == "combine")
        #expect(outcome.settings["name"] == "Warmest")
        #expect(outcome.settings["sources"]?.arrayValue?.count == 2)
        #expect(try HelperRule(settings: outcome.settings).kind == .combine)
        await host.stop()
    }

    @Test func aThresholdSetupRefusesAnOffValuePastTheOnValue() async throws {
        let host = try await environment.start(helpers: [:])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { host.mainBridge.server.accessory(id: "Fake:kitchen") != nil })
        guard case .ask(let prompt, let state) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["rule": "threshold"], state: .null)) else {
            Issue.record("no prompt"); return
        }
        let source = try #require(prompt.fields.first { $0.key == "source" }?.options.first { $0.label.hasPrefix("Kitchen") })
        // The door's contact state is a state, not a reading.
        #expect(prompt.fields.first { $0.key == "source" }?.options.contains { $0.label.hasPrefix("Front door") } == false)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["source": source.value, "direction": "above", "on": "25", "off": "27", "name": "Hot"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["source": source.value, "direction": "above", "on": "25,5", "off": "", "name": "Hot"], state: state)) else {
            Issue.record("not done"); return
        }
        #expect(outcome.settings["on"] == 25.5)
        #expect(outcome.settings["off"] == 25.5)
        await host.stop()
    }

    @Test func theSettingsOfferTheSourcesAndTheKindIsTheRule() async throws {
        let door = try await TestEnvironment.ref("door", .contactSensorState)
        let host = try await environment.start(helpers: ["open": ["name": "Door left open", "rule": "stays", "source": door, "state": "1", "minutes": 10]])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { host.mainBridge.server.accessory(id: "Helpers:open") != nil })
        #expect(await plugin.deviceKind(of: "open") == "stays")
        let sources = try #require(await plugin.accessorySettingChoices("source", deviceID: "open"))
        #expect(sources.contains { $0.label == "Front door" && $0.detail == "Contact Sensor State" })
        // A Helper never reads itself.
        #expect(!sources.contains { $0.value.hasPrefix("Helpers:open#") })
        #expect(await plugin.accessorySettingChoices("state", deviceID: "open")?.map(\.label) == ["Open", "Closed"])
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID) == ["open"])
        #expect(found.first?.kind == "stays")
        await host.stop()
    }

    // MARK: Files

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(HelpersPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Helpers HelpersPlugin")
        let schema = try JSONValue(string: try #require(HelpersPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Helpers")
    }
}
