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
        var refuse: Bool?
        var brightness: Int?
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
    }

    func stop() async { stopped = true }

    func addLamp(id: String) throws {
        let lightbulb = Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)
        lightbulb.characteristic(.brightness).value = .int(configuration.brightness ?? 0)
        try context.add(Accessory(id: "Recording:\(id)", name: id, category: .lightbulb, services: [lightbulb]))
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
        #expect(PluginHost.isDeviceID(try #require(configuration.bridge.username)))
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
        #expect(PluginHost.isDeviceID("0E:1A:2B:3C:4D:5E"))
        #expect(!PluginHost.isDeviceID("0E:1A:2B:3C:4D"))
        #expect(!PluginHost.isDeviceID("0E:1A:2B:3C:4D:ZZ"))
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
        try first.context.remove(id: "Recording:shared")
        #expect(host.mainBridge.server.accessories.count == 1)
        try await second.addLamp(id: "shared")
        #expect(host.mainBridge.server.accessories.count == 2)
        #expect(second.context.accessories.count == 1)
        #expect(first.context.accessories.isEmpty)
        await host.stop()
    }
}
