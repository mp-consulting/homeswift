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

struct PluginPicturesTests {
    let pictures = PluginPictures(directory: FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-pictures-\(UUID().uuidString)"))
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]) + Data(repeating: 7, count: 32)
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 32)
    static let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8) + Data(repeating: 2, count: 16)

    static func url(_ data: Data, as type: String = "image/jpeg") -> String { "data:\(type);base64,\(data.base64EncodedString())" }

    /// A picture comes back as it went, typed by its bytes rather than by what the URL claims.
    @Test func keepsJPEGPNGAndWebP() throws {
        try pictures.save(key: "scene-1", dataURL: Self.url(Self.jpeg))
        #expect(pictures.dataURL(key: "scene-1") == Self.url(Self.jpeg))
        try pictures.save(key: "scene-2", dataURL: Self.url(Self.png, as: "image/jpeg"))
        #expect(pictures.dataURL(key: "scene-2") == Self.url(Self.png, as: "image/png"))
        try pictures.save(key: "scene-3", dataURL: Self.url(Self.webp, as: "image/webp"))
        #expect(pictures.dataURL(key: "scene-3")?.hasPrefix("data:image/webp;base64,") == true)
        #expect(Set(pictures.versions().keys) == ["scene-1", "scene-2", "scene-3"])
        // Another kind replaces the first, it does not sit beside it.
        try pictures.save(key: "scene-1", dataURL: Self.url(Self.png, as: "image/png"))
        #expect(pictures.dataURL(key: "scene-1") == Self.url(Self.png, as: "image/png"))
        pictures.remove(key: "scene-1")
        #expect(pictures.dataURL(key: "scene-1") == nil)
        #expect(pictures.versions()["scene-1"] == nil)
    }

    @Test func refusesWhatIsNotAPicture() {
        #expect(throws: PluginPictures.Failure.notAnImage) { try pictures.save(key: "a", dataURL: Self.url(Data("<svg onload=alert(1)>".utf8), as: "image/png")) }
        #expect(throws: PluginPictures.Failure.notAnImage) { try pictures.save(key: "a", dataURL: "https://example.com/a.jpg") }
        #expect(throws: PluginPictures.Failure.notAnImage) { try pictures.save(key: "a", dataURL: "data:image/jpeg;base64,%%%") }
        #expect(throws: PluginPictures.Failure.tooLarge(limit: PluginPictures.maximumSize)) {
            try pictures.save(key: "a", dataURL: Self.url(Self.jpeg + Data(count: PluginPictures.maximumSize)))
        }
        // A key never leaves the directory.
        for key in ["../escape", "a/b", "", "a.b", String(repeating: "x", count: 241)] {
            #expect(throws: PluginPictures.Failure.badKey) { try pictures.save(key: key, dataURL: Self.url(Self.jpeg)) }
        }
        #expect(pictures.versions().isEmpty)
    }

    /// A plugin's scene pictures are the core's, under its scenes' id prefix; the ones it kept before move there once.
    @Test func pluginScenePicturesAreTheCores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-scene-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = PluginPictures(directory: root.appendingPathComponent("plugins/hue/scene-pictures"))
        try old.save(key: "kept-before", dataURL: Self.url(Self.jpeg))
        let hue = PluginPictures.scenePictures(root: root, platform: "PhilipsHue", name: "Hue Bridge")
        hue.adopt(old)
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        try hue.save(key: "abc", dataURL: Self.url(Self.png, as: "image/png"))
        #expect(Set(hue.versions().keys) == ["kept-before", "abc"])
        let core = PluginPictures.scenePictures(root: root)
        #expect(Set(core.versions().keys) == ["PhilipsHue:Hue Bridge:kept-before", "PhilipsHue:Hue Bridge:abc"])
        #expect(core.dataURL(key: "PhilipsHue:Hue Bridge:abc") == Self.url(Self.png, as: "image/png"))
        // Another instance sees none of them; a removal through the core shows on the plugin's view at once.
        #expect(PluginPictures.scenePictures(root: root, platform: "PhilipsHue", name: "Other").versions().isEmpty)
        core.remove(key: "PhilipsHue:Hue Bridge:abc")
        #expect(hue.versions()["abc"] == nil)
        // Any key is a safe file name once encoded.
        try core.save(key: "../escape", dataURL: Self.url(Self.jpeg))
        #expect(try FileManager.default.contentsOfDirectory(atPath: core.directory.path).allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") })
    }
}
