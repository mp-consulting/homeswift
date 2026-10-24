import Foundation
import Homeswift
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct HostControlTests {
    let environment = TestEnvironment()
    let json = """
        {
          "bridge": { "name": "Main", "port": 0 },
          "platforms": [
            { "platform": "Recording", "name": "On Main", "lamps": ["main-lamp"] },
            { "platform": "Recording", "name": "On Child", "lamps": ["child-lamp"],
              "_bridge": { "username": "0E:AA:BB:CC:DD:EE", "name": "Child", "port": 0 } }
          ]
        }
        """

    @Test func stopsStartsAndRestartsAChildBridge() async throws {
        let host = try environment.host(json)
        try await host.start()
        var status = try #require(host.childBridges.first)
        #expect(status.id == "0E:AA:BB:CC:DD:EE")
        #expect(status.name == "Child")
        #expect(status.instances == ["On Child"])
        #expect(status.status == "ok")
        #expect(status.running && status.port != nil && status.startedAt != nil)
        #expect(status.accessories == 1)
        #expect(host.childBridge(id: "0eaabbccddee") != nil)
        #expect(host.childBridge(id: "child") != nil)
        #expect(host.childBridge(id: "Main") == nil)

        try await host.stopChildBridge(id: "0E:AA:BB:CC:DD:EE")
        status = try #require(host.childBridges.first)
        #expect(status.status == "stopped")
        #expect(status.stoppedManually)
        #expect(status.port == nil)
        let firstChild = try #require(environment.createdPlugins.first { $0.context.name == "On Child" })
        #expect(await firstChild.stopped)
        // The main bridge runs on.
        #expect(host.mainBridge.server.port != nil)

        let before = environment.createdPlugins.count
        try await host.startChildBridge(id: "Child")
        status = try #require(host.childBridges.first)
        #expect(status.status == "ok" && !status.stoppedManually && status.port != nil)
        #expect(environment.createdPlugins.count == before + 1)
        #expect(host.childBridges.first?.accessories == 1)

        try await host.restartChildBridge(id: "Child")
        status = try #require(host.childBridges.first)
        #expect(status.restarts == 1)
        #expect(status.running)
        #expect(environment.createdPlugins.count == before + 2)
        #expect(host.bridges[1].server.accessories.map(\.id) == ["bridge", "Recording:child-lamp"])

        await #expect(throws: HostControlError.unknownChildBridge("nope")) { try await host.stopChildBridge(id: "nope") }
        await host.stop()
    }

    @Test func aStoppedChildBridgeStaysDownAcrossAReload() async throws {
        let host = try environment.host(json)
        try await host.start()
        try await host.stopChildBridge(id: "Child")
        let count = environment.createdPlugins.count
        let next = try HomeswiftConfiguration.decode(Data(json.replacingOccurrences(of: "\"child-lamp\"]", with: "\"child-lamp\", \"lamp-2\"]").utf8))
        let report = await host.apply(next)
        #expect(report.reloaded == ["On Child"])
        #expect(environment.createdPlugins.count == count)
        #expect(host.childBridges.first?.status == "stopped")
        await host.stop()
    }

    @Test func reportsAPluginThatDidNotStart() async throws {
        let host = try environment.host("""
            {
              "bridge": { "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Broken", "refuse": true, "_bridge": { "username": "0E:AA:BB:CC:DD:EF", "port": 0 } }]
            }
            """)
        try await host.start()
        let status = try #require(host.childBridges.first)
        #expect(status.status == "degraded")
        #expect(status.failures["Broken"] != nil)
        await host.stop()
    }

    @Test func listsRemovesAndResetsCachedAccessories() async throws {
        let lamps = """
            {
              "bridge": { "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "Lamps", "lamps": ["a", "b"] }]
            }
            """
        let first = try environment.host(lamps)
        try await first.start()
        await first.stop()

        // b is gone from the block: it comes back from the cache, and its plugin does not add it.
        let second = try environment.host(lamps.replacingOccurrences(of: "[\"a\", \"b\"]", with: "[\"a\"]"))
        try await second.start()
        var cached = second.cachedAccessories()
        #expect(cached.map(\.id) == ["Recording:a", "Recording:b"])
        #expect(cached.map(\.restoredOnly) == [false, true])
        #expect(cached.allSatisfy { $0.cacheFile == "accessories/Recording-Lamps.json" && $0.instance == "Lamps" && $0.platform == "Recording" })

        try await second.removeCachedAccessory(id: "Recording:b")
        cached = second.cachedAccessories()
        #expect(cached.map(\.id) == ["Recording:a"])
        #expect(second.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:a"])
        await #expect(throws: HostControlError.unknownCachedAccessory("Recording:b")) { try await second.removeCachedAccessory(id: "Recording:b") }

        // A file no block uses: listed as orphaned, emptied by the reset.
        let orphan = environment.directory.appendingPathComponent("accessories/Recording-Old.json")
        try FileManager.default.copyItem(at: environment.directory.appendingPathComponent("accessories/Recording-Lamps.json"), to: orphan)
        #expect(second.cachedAccessories().filter { $0.instance == nil }.map(\.id) == ["Recording:a"])

        let aid = second.mainBridge.server.accessories.last?.aid
        let plugins = environment.createdPlugins.count
        #expect(await second.resetCachedAccessories() == 2)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // The plugin started again and added its lamp, with the same aid.
        #expect(environment.createdPlugins.count == plugins + 1)
        #expect(second.mainBridge.server.accessories.map(\.id) == ["bridge", "Recording:a"])
        #expect(second.mainBridge.server.accessories.last?.aid == aid)
        #expect(second.cachedAccessories().map(\.id) == ["Recording:a"])
        #expect(second.cachedAccessories().map(\.restoredOnly) == [false])
        await second.stop()
    }

    @Test func resetsPairings() async throws {
        let storage = MemoryStorage()
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in storage }
        let config = try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "port": 0 }, "platforms": [] }"#.utf8))
        _ = try PluginHost(configuration: config, registry: PluginRegistry(), storageDirectory: environment.directory, options: options)
        // A controller paired with it, as the state file would say.
        let saved = try #require(try storage.load())
        var state = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        state["pairings"] = [["identifier": "controller-1", "publicKey": Data(repeating: 1, count: 32).base64EncodedString(), "isAdmin": true]]
        try storage.save(JSONSerialization.data(withJSONObject: state))

        let host = try PluginHost(configuration: config, registry: PluginRegistry(), storageDirectory: environment.directory, options: options)
        #expect(host.mainBridge.server.isPaired)
        #expect(host.bridge(id: host.mainBridge.server.deviceID) === host.mainBridge)
        try host.resetPairings(bridgeID: host.mainBridge.server.deviceID)
        #expect(!host.mainBridge.server.isPaired)
        #expect(throws: HostControlError.unknownBridge("nope")) { try host.resetPairings(bridgeID: "nope") }
    }

    /// A name two servers share finds neither: a pairing reset never lands on the wrong one. Device IDs always find.
    @Test func findsBridgesByDeviceIDOrAUniqueName() async throws {
        let host = try environment.host("""
            {
              "bridge": { "name": "Main", "port": 0 },
              "platforms": [{ "platform": "Recording", "name": "TV", "externals": ["Twin"],
                              "_bridge": { "username": "0E:AA:BB:CC:DD:E0", "name": "Twin", "port": 0 } }]
            }
            """)
        try await host.start()
        let child = try #require(host.bridges.first { $0.isChild })
        let television = try #require(host.bridges.first { $0.isExternal })
        #expect(television.name == "Twin")
        #expect(host.bridge(id: "twin") == nil)
        #expect(throws: HostControlError.unknownBridge("Twin")) { try host.resetPairings(bridgeID: "Twin") }
        #expect(host.bridge(id: "0eaabbccdde0") === child)
        #expect(host.bridge(id: television.server.deviceID) === television)
        #expect(host.childBridge(id: "Twin") === child)
        #expect(host.bridge(id: "main") === host.mainBridge)
        await host.stop()
    }

    @Test func findsAnAccessorysEveHistory() {
        let history = EveHistory(.weather, accessoryName: "Sensor", averaging: false)
        let sensor = Service(.temperatureSensor, name: "Sensor", isPrimary: true)
        let accessory = Accessory(id: "sensor", name: "Sensor", category: .sensor, services: [sensor, history.service])
        #expect(EveHistory.histories(of: accessory).first === history)
        #expect(EveHistory.histories(of: Accessory(id: "other", name: "Other", category: .sensor, services: [sensor])).isEmpty)
        history.add(EveHistory.Entry(unixTime: 1_800_000_000, temp: 20.5, humidity: 40))
        history.add(EveHistory.Entry(unixTime: 1_800_000_600, temp: 21, humidity: 41))
        #expect(history.entries().map(\.temp) == [20.5, 21])
        #expect(history.entries(since: Date(timeIntervalSince1970: 1_800_000_300)).map(\.temp) == [21])
    }
}
