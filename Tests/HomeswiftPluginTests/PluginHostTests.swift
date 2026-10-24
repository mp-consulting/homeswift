import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// The host's log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

enum TestError: Error { case refused }

/// A plugin that records what the runtime does with it and adds the lamps its block lists.
actor RecordingPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {
        var name: String?
        var lamps: [String]?
        /// Televisions to publish on servers of their own.
        var externals: [String]?
        var refuse: Bool?
        var brightness: Int?
        /// `start()` adds its lamps, then throws.
        var failStart: Bool?
    }

    static let platform = "Recording"
    static let name = "Recording Plugin"

    let configuration: Configuration
    let context: PluginContext
    private(set) var started = false
    private(set) var stopped = false

    init(configuration: Configuration, context: PluginContext) throws {
        if configuration.refuse == true { throw TestError.refused }
        self.configuration = configuration
        self.context = context
    }

    func start() async throws {
        started = true
        for lamp in configuration.lamps ?? [] {
            try addLamp(id: lamp)
        }
        for tv in configuration.externals ?? [] {
            try await publishTelevision(id: tv, inputs: ["HDMI 1"])
        }
        if configuration.failStart == true { throw TestError.refused }
    }

    func stop() async { stopped = true }

    func addLamp(id: String) throws {
        let lightbulb = Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)
        lightbulb.characteristic(.brightness).value = .int(configuration.brightness ?? 0)
        try context.add(Accessory(id: "Recording:\(id)", name: id, category: .lightbulb, services: [lightbulb]))
    }

    /// A television with its inputs as linked services, published outside the bridge.
    func publishTelevision(id: String, inputs: [String]) async throws {
        let sources = inputs.enumerated().map { index, name in
            Service(.inputSource, name: name, subtype: "input-\(index + 1)", optional: [.identifier], extra: [Characteristic(.identifier, value: .int(index + 1))])
        }
        let television = Service(.television, name: id, linked: sources, isPrimary: true)
        try await context.publishExternal(Accessory(id: "Recording:\(id)", name: id, category: .television, services: [television] + sources))
    }
}

/// Collects the plugins the host creates, and keeps HAP state per bridge across hosts like files would.
final class TestEnvironment: @unchecked Sendable {
    let directory: URL
    private let plugins = NIOLockedValueBox<[RecordingPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-tests-\(UUID().uuidString)")
    }

    var registry: PluginRegistry {
        var registry = PluginRegistry()
        registry.register(platform: RecordingPlugin.platform, name: RecordingPlugin.name) { json, context in
            let plugin = try RecordingPlugin(configuration: try JSONDecoder().decode(RecordingPlugin.Configuration.self, from: json), context: context)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        return registry
    }

    var createdPlugins: [RecordingPlugin] { plugins.withLockedValue { $0 } }

    var options: PluginHost.Options {
        PluginHost.Options(advertise: false, logger: testLogger) { name in
            self.storages.withLockedValue { storages in
                if let storage = storages[name] { return storage }
                let storage = MemoryStorage()
                storages[name] = storage
                return storage
            }
        }
    }

    func host(_ json: String) throws -> PluginHost {
        try PluginHost(configuration: try HomeswiftConfiguration.decode(Data(json.utf8)), registry: registry, storageDirectory: directory, options: options)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    @Test func decodesHomebridgeShapedConfig() throws {
        let configuration = try HomeswiftConfiguration.decode(Data("""
            {
              "bridge": { "name": "Test Bridge", "username": "0e:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "accessories": [{ "accessory": "Dummy", "name": "Dummy" }],
              "platforms": [
                { "platform": "Recording", "name": "Lamps", "lamps": ["a", "b"] },
                { "platform": "Recording", "_bridge": { "username": "0E:AA:BB:CC:DD:EE", "name": "Child" } },
                { "platform": "Unknown" }
              ],
              "disabledPlugins": ["Other"]
            }
            """.utf8))
        #expect(configuration.bridge == .init(name: "Test Bridge", username: "0e:11:22:33:44:55", port: 0, pin: "031-45-154"))
        #expect(configuration.accessoryBlockCount == 1)
        #expect(configuration.disabledPlugins == ["Other"])
        #expect(configuration.platforms.map(\.name) == ["Lamps", "Recording", "Unknown"])
        #expect(configuration.platforms[1].childBridge == .init(name: "Child", username: "0E:AA:BB:CC:DD:EE"))
        let settings = try JSONDecoder().decode(RecordingPlugin.Configuration.self, from: configuration.platforms[0].json)
        #expect(settings.lamps == ["a", "b"])
    }

    @Test func rejectsMalformedBlocks() {
        #expect(throws: ConfigurationError.notAnObject) { try HomeswiftConfiguration.decode(Data("[]".utf8)) }
        #expect(throws: ConfigurationError.invalidValue(key: "platforms[0].platform", expected: "a platform name")) {
            try HomeswiftConfiguration.decode(Data(#"{"platforms": [{"name": "x"}]}"#.utf8))
        }
    }

    @Test func defaultConfigIsValid() throws {
        let configuration = try HomeswiftConfiguration.decode(HomeswiftConfiguration.makeDefault())
        #expect(configuration.bridge.name == "Homeswift")
        #expect(HomeswiftConfiguration.isDeviceID(try #require(configuration.bridge.username)))
        #expect(SetupCode(try #require(configuration.bridge.pin)) != nil)
        #expect(configuration.platforms.isEmpty)
    }

    @Test func registersPluginTypes() async throws {
        var registry = PluginRegistry([RecordingPlugin.self])
        #expect(registry.entries.map(\.platform) == ["Recording"])
        #expect(registry.entry(for: "Recording")?.name == "Recording Plugin")
        registry.register(RecordingPlugin.self)
        #expect(registry.entries.count == 1)

        // The entry decodes the block into the plugin's Configuration and creates it.
        let environment = TestEnvironment()
        let host = try PluginHost(
            configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [
                try .init(platform: "Recording", name: "Typed", settings: ["lamps": ["typed-lamp"]]),
            ]),
            registry: registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:typed-lamp"])
        await host.stop()
    }

    @Test func helpers() {
        #expect(PluginHost.slug("Elgato Key Lights") == "Elgato-Key-Lights")
        #expect(PluginHost.slug("a/b  c.d_e") == "a-b-c.d_e")
        #expect(PluginHost.slug("  ") == "platform")
        #expect(HomeswiftConfiguration.isDeviceID("0E:1A:2B:3C:4D:5E"))
        #expect(!HomeswiftConfiguration.isDeviceID("0E:1A:2B:3C:4D"))
        #expect(!HomeswiftConfiguration.isDeviceID("0E:1A:2B:3C:4D:ZZ"))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PluginHostTests {
    let environment = TestEnvironment()

    @Test func runsPluginsOnTheBridge() async throws {
        let host = try environment.host("""
            {
              "bridge": { "name": "Test Bridge", "username": "0e:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"] }]
            }
            """)
        try await host.start()
        let server = host.mainBridge.server
        #expect(server.deviceID == "0E:11:22:33:44:55")
        #expect(server.setupCode.rawValue == "031-45-154")
        #expect(server.port != nil)
        #expect(host.mainBridge.name == "Test Bridge")
        #expect(host.platforms.map(\.name) == ["Lamps"])
        #expect(server.accessories.map(\.id) == ["bridge", "Recording:lamp-1"])
        #expect(server.primary.information[.serialNumber]?.value == .string("0E:11:22:33:44:55"))
        #expect(server.primary.information[.firmwareRevision]?.value == .string(PluginHost.version))

        let plugin = try #require(environment.createdPlugins.first)
        #expect(await plugin.started)
        #expect(plugin.context.name == "Lamps")
        #expect(plugin.context.accessories.map(\.id) == ["Recording:lamp-1"])
        await host.stop()
        #expect(await plugin.stopped)
    }

    @Test func skipsUnknownDisabledAndFailingPlugins() async throws {
        let host = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [
                { "platform": "Unknown", "name": "Nobody" },
                { "platform": "Recording", "name": "Refusing", "refuse": true },
                { "platform": "Recording", "name": "Mistyped", "lamps": "not-an-array" },
                { "platform": "Recording", "name": "Disabled", "lamps": ["x"] }
              ],
              "disabledPlugins": ["Recording"]
            }
            """)
        try await host.start()
        #expect(host.platforms.isEmpty)
        #expect(host.mainBridge.server.accessories.count == 1)
        #expect(environment.createdPlugins.isEmpty)
        await host.stop()

        let failing = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [
                { "platform": "Recording", "name": "Refusing", "refuse": true },
                { "platform": "Recording", "name": "Mistyped", "lamps": "not-an-array" },
                { "platform": "Recording", "name": "Working", "lamps": ["x"] }
              ]
            }
            """)
        try await failing.start()
        #expect(failing.platforms.map(\.name) == ["Refusing", "Mistyped", "Working"])
        #expect(failing.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:x"])
        #expect(environment.createdPlugins.count == 1)
        await failing.stop()
    }

    @Test func rejectsInvalidPinAndUsername() {
        #expect(throws: ConfigurationError.invalidSetupCode("111-11-111")) {
            try environment.host(#"{"bridge": {"pin": "111-11-111"}}"#)
        }
        #expect(throws: ConfigurationError.invalidUsername("nope")) {
            try environment.host(#"{"bridge": {"username": "nope"}}"#)
        }
    }

    @Test func restoresTheCacheAndKeepsAIDs() async throws {
        let first = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"], "brightness": 42 }]
            }
            """)
        try await first.start()
        let original = try #require(first.mainBridge.server.accessories.last)
        #expect(original.aid == 2)
        await first.stop()
        let cacheURL = environment.directory.appendingPathComponent("accessories/Recording-Lamps.json")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Before the plugin starts, the lamp is back with its last value and the same aid.
        let second = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"] }]
            }
            """)
        let restored = try #require(second.mainBridge.server.accessories.last)
        #expect(restored.id == "Recording:lamp-1")
        #expect(restored.aid == 2)
        #expect(restored.name == "lamp-1")
        #expect(restored.category == .lightbulb)
        let restoredLightbulb = try #require(restored.service(.lightbulb))
        #expect(restoredLightbulb.isPrimary)
        #expect(restoredLightbulb[.brightness]?.value == .int(42))
        #expect(restoredLightbulb[.name]?.value == .string("lamp-1"))
        #expect(restoredLightbulb.iid == original.service(.lightbulb)?.iid)
        #expect(restoredLightbulb[.brightness]?.iid == original.service(.lightbulb)?[.brightness]?.iid)

        // The plugin's own accessory replaces it, keeping the aid and iids.
        try await second.start()
        let replaced = try #require(second.mainBridge.server.accessories.last)
        #expect(replaced !== restored)
        #expect(replaced.aid == 2)
        #expect(replaced.service(.lightbulb)?[.brightness]?.value == .int(0))
        #expect(replaced.service(.lightbulb)?[.brightness]?.iid == restoredLightbulb[.brightness]?.iid)
        #expect(second.mainBridge.server.accessories.count == 2)
        await second.stop()
    }

    @Test func purgesTheControllerStatesOfAccessoriesThatAreGone() async throws {
        let json = """
            {
              "bridge": { "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"] }]
            }
            """
        let first = try environment.host(json)
        try await first.start()
        await first.stop()
        let url = environment.directory.appendingPathComponent("controllers/Recording-Lamps.json")
        let storage = ControllerStorage(url: url)
        try storage.save(Data("kept".utf8), accessoryID: "Recording:lamp-1", controllerID: "characteristic-transition-1")
        try storage.save(Data("gone".utf8), accessoryID: "Recording:removed", controllerID: "characteristic-transition-1")

        // Restoring the cache drops the state of the accessory the instance no longer has.
        let second = try environment.host(json)
        #expect(second.mainBridge.server.accessories.contains { $0.id == "Recording:lamp-1" })
        let reloaded = ControllerStorage(url: url)
        #expect(reloaded.state(accessoryID: "Recording:lamp-1", controllerID: "characteristic-transition-1") == Data("kept".utf8))
        #expect(reloaded.state(accessoryID: "Recording:removed", controllerID: "characteristic-transition-1") == nil)
    }

    @Test func appliesANewConfigurationWithoutARestart() async throws {
        func configuration(_ platforms: String, port: Int = 0) throws -> HomeswiftConfiguration {
            try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "port": \#(port) }, "platforms": [\#(platforms)] }"#.utf8))
        }
        let host = try PluginHost(
            configuration: try configuration(#"{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"], "brightness": 10 }"#),
            registry: environment.registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let server = host.mainBridge.server
        let lamp = try #require(server.accessories.last)

        // Unchanged: nothing happens.
        #expect(await host.apply(host.configuration) == PluginHost.ReloadReport())

        // A changed block: a fresh plugin on the same accessory, aid and iids kept.
        let report = await host.apply(try configuration(#"{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"], "brightness": 70 }"#))
        #expect(report == PluginHost.ReloadReport(reloaded: ["Lamps"]))
        #expect(environment.createdPlugins.count == 2)
        #expect(await environment.createdPlugins[0].stopped)
        #expect(await environment.createdPlugins[1].started)
        let reloaded = try #require(server.accessories.last)
        #expect(reloaded.aid == lamp.aid)
        #expect(reloaded.service(.lightbulb)?[.brightness]?.value == .int(70))
        #expect(reloaded.service(.lightbulb)?[.brightness]?.iid == lamp.service(.lightbulb)?[.brightness]?.iid)

        // A new block starts, with its television on a server of its own; a removed one leaves the bridge.
        // The host's change feed (the web UI's live events, MCP) covers the new server too.
        let changed = NIOLockedValueBox<[String]>([])
        let observation = host.observeChanges { accessory, characteristic, _ in changed.withLockedValue { $0.append("\(accessory.id) \(characteristic.type.name)") } }
        let added = await host.apply(try configuration(#"""
            { "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"], "brightness": 70 },
            { "platform": "Recording", "name": "TVs", "externals": ["tv-1"] }
            """#))
        #expect(added == PluginHost.ReloadReport(started: ["TVs"]))
        let television = try #require(host.bridges.first { $0.isExternal }?.server.primary.service(.television))
        television.characteristic(.active).value = .int(1)
        #expect(changed.withLockedValue { $0 }.contains("Recording:tv-1 Active"))
        observation.cancel()
        television.characteristic(.active).value = .int(0)
        #expect(changed.withLockedValue { $0 }.count == 1)
        #expect(host.platforms.map(\.name) == ["Lamps", "TVs"])
        let tv = try #require(host.bridges.first { $0.isExternal })
        #expect(tv.server.port != nil)
        let removed = await host.apply(try configuration(#"{ "platform": "Recording", "name": "TVs", "externals": ["tv-1"] }"#))
        #expect(removed == PluginHost.ReloadReport(stopped: ["Lamps"]))
        #expect(server.accessories.map(\.id) == ["bridge"])
        #expect(host.platforms.map(\.name) == ["TVs"])

        // The bridge block needs a restart; the plugin blocks still apply.
        let bridge = await host.apply(try configuration("", port: 51826))
        #expect(bridge.needsRestart == ["the bridge block changed"])
        #expect(bridge.stopped == ["TVs"])
        #expect(!host.bridges.contains { $0.isExternal })
        await host.stop()
    }

    /// Blocks with the same platform and name pair up with their instances in order: a change to the second
    /// reloads the second, not the first.
    @Test func reloadsTheDuplicateBlockThatChanged() async throws {
        func configuration(_ second: String) throws -> HomeswiftConfiguration {
            try HomeswiftConfiguration.decode(Data(#"""
                { "bridge": { "port": 0 }, "platforms": [
                  { "platform": "Recording", "name": "Lights", "lamps": ["a"] },
                  { "platform": "Recording", "name": "Lights", "lamps": [\#(second)] }
                ] }
                """#.utf8))
        }
        let host = try PluginHost(configuration: try configuration(#""b""#), registry: environment.registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        #expect(host.platforms.map(\.accessoryIDs) == [["Recording:a"], ["Recording:b"]])
        let report = await host.apply(try configuration(#""b", "c""#))
        #expect(report == PluginHost.ReloadReport(reloaded: ["Lights"]))
        #expect(host.platforms.map(\.accessoryIDs) == [["Recording:a"], ["Recording:b", "Recording:c"]])
        #expect(environment.createdPlugins.count == 3)
        #expect(await !environment.createdPlugins[0].stopped)
        #expect(await environment.createdPlugins[1].stopped)
        await host.stop()
    }

    /// A plugin whose `start()` throws is stopped, so what it began does not run on unseen.
    @Test func stopsAPluginWhoseStartThrew() async throws {
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Half", "lamps": ["a"], "failStart": true }] }"#)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        #expect(await plugin.started)
        #expect(await plugin.stopped)
        #expect(host.instances.first?.plugin.withLockedValue { $0 } == nil)
        #expect(host.instances.first?.failure.withLockedValue { $0 } != nil)
        await host.stop()
    }

    /// A paused block keeps its accessories in HomeKit, answering No Response, and runs no plugin; resuming
    /// starts a fresh one on the same accessories.
    @Test func pausesAPluginAndResumesIt() async throws {
        func configuration(paused: Bool) throws -> HomeswiftConfiguration {
            try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1"], "_paused": \#(paused) }] }"#.utf8))
        }
        #expect(throws: ConfigurationError.self) {
            try HomeswiftConfiguration.decode(Data(#"{ "platforms": [{ "platform": "Recording", "_paused": "yes" }] }"#.utf8))
        }
        let host = try PluginHost(configuration: try configuration(paused: false), registry: environment.registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let lamp = try #require(host.mainBridge.server.accessories.last)
        let brightness = try #require(lamp.service(.lightbulb)?[.brightness])
        let writes = NIOLockedValueBox(0)
        brightness.onWrite { _ in writes.withLockedValue { $0 += 1 } }

        let paused = await host.apply(try configuration(paused: true))
        #expect(paused == PluginHost.ReloadReport(reloaded: ["Lamps"]))
        #expect(environment.createdPlugins.count == 1)
        #expect(await environment.createdPlugins[0].stopped)
        #expect(host.platforms.map(\.paused) == [true])
        #expect(host.mainBridge.server.accessories.last === lamp)
        #expect(lamp.isUnavailable)
        await #expect(throws: HAPStatusError.self) { try await brightness.write(.int(50)) }
        #expect(writes.withLockedValue { $0 } == 0)

        let resumed = await host.apply(try configuration(paused: false))
        #expect(resumed == PluginHost.ReloadReport(reloaded: ["Lamps"]))
        #expect(await environment.createdPlugins[1].started)
        #expect(!lamp.isUnavailable)
        #expect(host.platforms.map(\.paused) == [false])
        await host.stop()
    }

    @Test func runsChildBridges() async throws {
        let host = try environment.host("""
            {
              "bridge": { "name": "Main", "port": 0 },
              "platforms": [
                { "platform": "Recording", "name": "On Main", "lamps": ["main-lamp"] },
                { "platform": "Recording", "name": "On Child", "lamps": ["child-lamp"],
                  "_bridge": { "username": "0E:AA:BB:CC:DD:EE", "name": "Child", "pin": "031-45-154", "port": 0 } }
              ]
            }
            """)
        try await host.start()
        #expect(host.bridges.map(\.name) == ["Main", "Child"])
        #expect(host.bridges.map(\.isChild) == [false, true])
        let child = host.bridges[1]
        #expect(child.server.deviceID == "0E:AA:BB:CC:DD:EE")
        #expect(child.server.setupCode.rawValue == "031-45-154")
        #expect(child.server.port != host.mainBridge.server.port)
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:main-lamp"])
        #expect(child.server.accessories.map(\.id) == ["bridge", "Recording:child-lamp"])
        #expect(host.platforms.map(\.bridge.name) == ["Main", "Child"])
        await host.stop()
    }

    @Test func offersTheAssistantFromTheAiKitBlock() async throws {
        let host = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [
                { "platform": "HomeswiftAiKit", "provider": "openai-compatible", "model": "llama3.1", "baseUrl": "http://127.0.0.1:9/v1" },
                { "platform": "Recording", "name": "Lamps" }
              ]
            }
            """)
        #expect(host.platforms.map(\.platform) == ["Recording"])
        #expect(host.aiConfiguration?.provider == .openaiCompatible)
        #expect(host.assistant?.providerName == "openai-compatible")
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        let assistant = try #require(plugin.context.assistant)
        #expect(assistant.model == "llama3.1")
        await host.stop()

        // A block that cannot be set up leaves the bridge running without an Assistant.
        let broken = try environment.host("""
            { "bridge": { "port": 0 }, "platforms": [{ "platform": "HomeswiftAiKit", "provider": "anthropic" }, { "platform": "Recording", "name": "Lamps" }] }
            """)
        #expect(broken.aiConfiguration != nil)
        // (Unless the shell running the tests has ANTHROPIC_API_KEY, which the block then picks up.)
        let keyInEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
        #expect(broken.assistant == nil || keyInEnvironment)
        try await broken.start()
        #expect(environment.createdPlugins.last?.context.assistant == nil || keyInEnvironment)
        await broken.stop()
    }

    @Test func refusesDuplicateIDsAcrossPlugins() async throws {
        let host = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [
                { "platform": "Recording", "name": "First", "lamps": ["shared"] },
                { "platform": "Recording", "name": "Second" }
              ]
            }
            """)
        try await host.start()
        let second = try #require(environment.createdPlugins.first { $0.context.name == "Second" })
        await #expect(throws: PluginError.accessoryIDInUse(id: "Recording:shared", by: "First")) {
            try await second.addLamp(id: "shared")
        }
        #expect(host.mainBridge.server.accessories.count == 2)

        // Removing frees the id.
        let first = try #require(environment.createdPlugins.first { $0.context.name == "First" })
        try await first.context.remove(id: "Recording:shared")
        #expect(host.mainBridge.server.accessories.count == 1)
        try await second.addLamp(id: "shared")
        #expect(host.mainBridge.server.accessories.count == 2)
        #expect(second.context.accessories.count == 1)
        #expect(first.context.accessories.isEmpty)
        await host.stop()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ExternalAccessoryTests {
    let environment = TestEnvironment()
    let json = """
        {
          "bridge": { "name": "Main", "pin": "031-45-154", "port": 0 },
          "platforms": [{ "platform": "Recording", "name": "TVs", "lamps": ["lamp"], "externals": ["Living Room TV"] }]
        }
        """

    @Test func publishesTelevisionsOnTheirOwnServers() async throws {
        let host = try environment.host(json)
        try await host.start()
        // Published while the host runs: the server is up at once.
        #expect(host.bridges.map(\.name) == ["Main", "Living Room TV"])
        let external = host.bridges[1]
        #expect(external.isExternal && !external.isChild)
        #expect(external.owner == "TVs")
        #expect(external.server.port != nil)
        #expect(external.server.port != host.mainBridge.server.port)
        #expect(external.server.setupCode == host.mainBridge.server.setupCode)
        #expect(external.server.primary.id == "Recording:Living Room TV")
        #expect(external.server.primary.aid == 1)
        #expect(external.server.primary.category == .television)
        #expect(external.server.accessories.count == 1)
        #expect(host.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:lamp"])
        let plugin = try #require(environment.createdPlugins.first)
        #expect(plugin.context.accessories.map(\.id) == ["Recording:lamp", "Recording:Living Room TV"])
        #expect(plugin.context.isExternal(id: "Recording:Living Room TV"))
        #expect(host.platforms[0].accessoryIDs.contains("Recording:Living Room TV"))
        let deviceID = external.server.deviceID
        let inputIID = external.server.primary.service(.inputSource, subtype: "input-1")?.iid

        // Publishing again replaces the accessory on the same server.
        try await plugin.publishTelevision(id: "Living Room TV", inputs: ["HDMI 1", "Netflix"])
        #expect(host.bridges.count == 2)
        #expect(host.bridges[1].server === external.server)
        #expect(external.server.primary.service(.inputSource, subtype: "input-1")?.iid == inputIID)
        #expect(external.server.primary.services.filter { $0.type.uuid == ServiceType.inputSource.uuid }.count == 2)
        await host.stop()

        // At the next launch the television is back on its own server, with its identity, before the plugin starts.
        let second = try environment.host(json)
        #expect(second.bridges.map(\.name) == ["Main", "Living Room TV"])
        #expect(second.bridges[1].isExternal)
        #expect(second.bridges[1].server.deviceID == deviceID)
        let restored = second.bridges[1].server.primary
        #expect(restored.service(.television)?.linked.count == 2)
        #expect(restored.service(.inputSource, subtype: "input-1")?.iid == inputIID)
        try await second.start()
        #expect(second.bridges.count == 2)
        #expect(second.bridges[1].server.port != nil)
        #expect(second.bridges[1].server.primary !== restored)   // the plugin's own accessory replaced the cached one
        #expect(second.bridges[1].server.primary.service(.inputSource, subtype: "input-1")?.iid == inputIID)

        // Removing stops the server.
        let plugin2 = try #require(environment.createdPlugins.last)
        try await plugin2.context.remove(id: "Recording:Living Room TV")
        #expect(second.bridges.map(\.name) == ["Main"])
        #expect(plugin2.context.accessories.map(\.id) == ["Recording:lamp"])
        await second.stop()
    }
}
