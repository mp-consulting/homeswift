import Foundation
import Homeswift
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

struct TaskBagTests {
    @Test func cancelsEverythingAndStartsNothingOnceStopped() async {
        let bag = TaskBag()
        let ran = NIOLockedValueBox(0)
        bag.add { ran.withLockedValue { $0 += 1 } }
        bag.add { try? await Task.sleep(for: .seconds(60)) }
        let outside = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        bag.add(outside)
        #expect(!bag.isStopped)
        bag.cancelAll()
        await bag.idle()
        #expect(outside.isCancelled)
        #expect(ran.withLockedValue { $0 } == 1)
        #expect(bag.isStopped)
        #expect(bag.add { ran.withLockedValue { $0 += 1 } } == nil)
        let late = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        bag.add(late)
        #expect(late.isCancelled)
    }
}

struct LatestCallGuardTests {
    @Test func letsTheLastCallThrough() async {
        let latest = LatestCallGuard(delay: .milliseconds(20))
        // A call made while an earlier one waits supersedes it; other keys are separate.
        let earlier = latest.claim("brightness")
        #expect(await latest("brightness"))
        #expect(!earlier())
        #expect(await latest("hue"))
        let waiting = Task { await latest("hue") }
        waiting.cancel()
        #expect(await waiting.value == false)
    }
}

struct PersistedDictionaryTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-persisted-\(UUID().uuidString)/values.json")

    @Test func writesChangesOnlyAndTogether() async throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersistedDictionary<Int>(url: url, autosave: .milliseconds(20))
        store["a"] = 1
        store["b"] = 2
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(PersistedDictionary<Int>(url: url).values == ["a": 1, "b": 2])
        #if !os(Windows)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #endif

        // An unchanged value writes nothing.
        try FileManager.default.removeItem(at: url)
        #expect(!store.update("a") { $0 = 1 })
        try store.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.removeValue(forKey: "a") == 1)
        try store.flush()
        #expect(PersistedDictionary<Int>(url: url).values == ["b": 2])
    }

    /// A store let go of before its autosave still writes its change.
    @Test func savesAChangeOfAStoreLetGo() async throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = PersistedDictionary<Int>(url: url, autosave: .milliseconds(20))
            store["a"] = 1
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(PersistedDictionary<Int>(url: url).values == ["a": 1])
    }

    @Test func jsonFileRoundTrips() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONFile<[String]>(url: url)
        #expect(file.load() == nil)
        try file.save(["x", "y"])
        #expect(file.load() == ["x", "y"])
        file.remove()
        #expect(file.load() == nil)
    }
}

struct PluginContextHelperTests {
    let environment = TestEnvironment()

    @Test func removesAccessoriesNotKept() async throws {
        let host = try environment.host("""
            {
              "bridge": { "name": "Test Bridge", "username": "0e:11:22:33:44:56", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["one", "two", "three"] }]
            }
            """)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        let removed = await plugin.context.removeAccessories(keeping: ["Recording:two"])
        #expect(Set(removed) == ["Recording:one", "Recording:three"])
        #expect(plugin.context.accessories.map(\.id) == ["Recording:two"])
        await host.stop()
    }

    /// A file name made from a device's id stays in the plugin's directory.
    @Test func keepsFilesInTheStorageDirectory() throws {
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Lamps" }] }"#)
        let context = try #require(host.instances.first?.context)
        let directory = context.storageDirectory.standardizedFileURL.path
        for name in ["../../config.json", "..", "a/../../b.json", #"..\x"#, "devices.json"] {
            let url = context.jsonFile(name, as: [String].self).url.standardizedFileURL
            #expect(url.deletingLastPathComponent().path == directory, "\(name)")
        }
        #expect(context.jsonFile("devices.json", as: [String].self).url.lastPathComponent == "devices.json")
    }

    /// A change still waiting for its autosave is written when the plugin stops, before a restart can lose it.
    @Test func savesPersistedDictionariesWhenThePluginStops() async throws {
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Lamps" }] }"#)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        let store = plugin.context.persistedDictionary("state.json", of: Int.self, autosave: .seconds(60))
        store["level"] = 3
        await host.stop()
        #expect(PersistedDictionary<Int>(url: store.url).values == ["level": 3])
    }

    @Test func revertsAValueLater() async throws {
        let on = Characteristic(.on, value: .bool(true))
        let task = on.revert(to: .bool(false), after: .milliseconds(10))
        await task.value
        #expect(on.value == .bool(false))
        let cancelled = on.revert(to: .bool(true), after: .seconds(60))
        cancelled.cancel()
        await cancelled.value
        #expect(on.value == .bool(false))
    }
}

struct ConfidentialValueTests {
    @Test func theAccessoryCacheKeepsNoConfidentialValue() {
        let characteristic = Characteristic(.setupEndpoints, value: "c3J0cC1tYXN0ZXIta2V5")
        #expect(CachedCharacteristic(characteristic).value == .null)
        #expect(CachedCharacteristic(Characteristic(.brightness, value: 40)).value == .int(40))
    }
}

struct JSONNumberTests {
    @Test func saturatingIntValues() {
        #expect(JSONValue.number(1e300).saturatingIntValue == .max)
        #expect(JSONValue.number(-1e300).saturatingIntValue == .min)
        #expect(JSONValue.number(41.9).saturatingIntValue == 41)
        #expect(JSONValue.number(1e300).intValue == nil)
        #expect(JSONValue.string("12").saturatingIntValue == nil)
        #expect(JSONValue.number(250).saturatingIntValue(in: 0...100) == 100)
        #expect(JSONValue.null.saturatingIntValue(in: 0...100) == nil)
    }
}

struct AssistantBackgroundTests {
    private struct Lamp: HomeswiftPlugin {
        struct Configuration: Decodable, Sendable {}
        static let platform = "Lamp"
        static let assistantBackground: String? = "ECONNREFUSED means the lamp's API is off."
        init(configuration: Configuration, context: PluginContext) async throws {}
        func start() async throws {}
    }

    @Test func registryKeepsThePluginsBackgroundForTheAssistant() {
        var registry = PluginRegistry()
        registry.register(Lamp.self)
        let entry = registry.entry(for: "Lamp")
        #expect(entry?.assistantBackground == "ECONNREFUSED means the lamp's API is off.")
        let context = PluginContext.assistantContext(name: "Desk", platform: "Lamp", background: entry?.assistantBackground)
        #expect(context.hasPrefix("The requests come from the Homeswift plugin \"Desk\" (platform Lamp)."))
        #expect(context.hasSuffix("ECONNREFUSED means the lamp's API is off."))
        #expect(PluginContext.assistantContext(name: "Desk", platform: "Lamp", background: "  ") == "The requests come from the Homeswift plugin \"Desk\" (platform Lamp).")
    }
}
