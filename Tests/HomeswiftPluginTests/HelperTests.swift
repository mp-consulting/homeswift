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
        let deadline = ContinuousClock.now + .seconds(5)
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
