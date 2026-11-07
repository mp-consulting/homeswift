import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

@Suite(.timeLimit(.minutes(1)))
struct SceneAndMatterTests {
    /// Scenes are Discovered Devices, included by default, momentary switches that run them (section 11).
    @Test func scenesAreListedAndRun() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let sceneID = "scene:\(Fixture.scene)"
        #expect(await eventually { host.accessory(sceneID) != nil })
        let plugin = try #require(environment.plugin)
        let discovered = try #require(try await plugin.discover().first { $0.deviceID == sceneID })
        #expect(discovered.name == "Good Night" && discovered.kind == "scene" && discovered.isSetUp && !discovered.excludedBySettings)
        #expect(await plugin.scenes().map(\.name) == ["Good Night"])

        let on = try #require(host.accessory(sceneID)?.service(subtype: "main/scene")?[.on])
        try await write(on, .bool(true))
        #expect(environment.cloud.sent("POST", "/v1/scenes/\(Fixture.scene)/execute").count == 1)
        // Back to Off a second later (a millisecond here).
        #expect(await eventually { on.value == .bool(false) })
        try await plugin.recallScene(id: Fixture.scene)
        #expect(environment.cloud.sent("POST", "/v1/scenes/\(Fixture.scene)/execute").count == 2)
    }

    @Test func anExcludedSceneIsNoAccessory() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(accessories: ["scene:\(Fixture.scene)": ["excluded": true]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory(Fixture.lamp) != nil })
        #expect(host.accessory("scene:\(Fixture.scene)") == nil)
        #expect(await environment.plugin?.scenes().isEmpty == true)
    }

    /// 15.5: Homeswift's bridge and its copies are skipped; other Matter devices are not.
    static let matterDevices = Fixture.json("""
        { "items": [
          { "deviceId": "aaaa0000-0000-4000-8000-0000000000b0", "label": "Homeswift Bridge", "name": "Homeswift Bridge",
            "manufacturerName": "Homeswift", "type": "MATTER",
            "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000ABC",
                        "uniqueId": "8f14e45fceea167a5a36dedd4bea2543", "hubId": "3e4f0d2c-0000-4000-8000-0000000000d7" },
            "childDevices": [ { "id": "aaaa0000-0000-4000-8000-0000000000b1" } ],
            "components": [ { "id": "main", "capabilities": [ { "id": "healthCheck", "version": 1 } ] } ] },
          { "deviceId": "aaaa0000-0000-4000-8000-0000000000b1", "label": "Desk Light", "manufacturerName": "Elgato",
            "type": "MATTER", "parentDeviceId": "aaaa0000-0000-4000-8000-0000000000b0",
            "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000ABC", "uniqueId": "ElgatoKeyLights:3C6A9D0011AA" },
            "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1 }, { "id": "switchLevel", "version": 1 } ] } ] },
          { "deviceId": "bbbb0000-0000-4000-8000-0000000000c1", "label": "Eve Energy", "manufacturerName": "Eve Systems",
            "type": "MATTER", "matter": { "vendorId": 4874, "productId": 80, "networkId": "0000000000000DEF" },
            "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1, "status": { "switch": { "value": "on" } } },
                                                             { "id": "powerMeter", "version": 1, "status": { "power": { "value": 12.5, "unit": "W" } } } ] } ] },
          { "deviceId": "cccc0000-0000-4000-8000-0000000000c2", "label": "Matterbridge Plug", "manufacturerName": "Matterbridge",
            "type": "MATTER", "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000F00" },
            "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1 } ] } ] }
        ], "_links": {} }
        """)

    @Test func copiesOfHomeswiftsOwnAccessoriesAreFound() throws {
        let devices = (Self.matterDevices["items"]?.arrayValue ?? []).compactMap(SmartThingsDevice.init)
        let found = MatterCopies.find(in: devices, homeswiftIDs: ["ElgatoKeyLights:3C6A9D0011AA"])
        #expect(found["aaaa0000-0000-4000-8000-0000000000b0"]?.isBridge == true)
        #expect(found["aaaa0000-0000-4000-8000-0000000000b1"]?.rules == ["a", "b", "c"])
        #expect(found["bbbb0000-0000-4000-8000-0000000000c1"] == nil)
        #expect(found["cccc0000-0000-4000-8000-0000000000c2"] == nil)
        // A long Accessory Id is the first 32 hex digits of its SHA-256.
        let long = "HomeBridgeSmartThings:0a1b2c3d-0000-4000-8000-0000000000d1"
        let unique = MatterCopies.uniqueID(of: long)
        #expect(unique.count == 32 && unique.allSatisfy(\.isHexDigit))
        let own = try #require(SmartThingsDevice(["deviceId": "x", "type": "MATTER", "manufacturerName": "Acme",
                                                  "matter": ["vendorId": 65521, "productId": 32768, "uniqueId": .string(unique.uppercased())], "components": []]))
        #expect(MatterCopies.find(in: [own], homeswiftIDs: [long])["x"]?.rules == ["c"])
    }


    /// A copy shown before its bridge was listed (the host's accessories were not all up) leaves the bridge once it is found.
    @Test func aCopyFoundLaterLeavesTheBridge() async throws {
        let environment = TestEnvironment()
        let items = Self.matterDevices["items"]?.arrayValue ?? []
        let child = try #require(items.first { $0["deviceId"] == "aaaa0000-0000-4000-8000-0000000000b1" })
        environment.cloud.reset("GET", "/v1/devices")
        environment.cloud.answer("GET", "/v1/devices", ["items": [child], "_links": [:]])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("aaaa0000-0000-4000-8000-0000000000b1") != nil })
        environment.cloud.reset("GET", "/v1/devices")
        environment.cloud.answer("GET", "/v1/devices", Self.matterDevices)
        let plugin = try #require(environment.plugin)
        await plugin.reconcile()
        #expect(await eventually { host.accessory("aaaa0000-0000-4000-8000-0000000000b1") == nil })
        #expect(await plugin.bindings["aaaa0000-0000-4000-8000-0000000000b1"] == nil)
    }
    @Test func copiesAreSkippedAndOtherMatterDevicesShown() async throws {
        let environment = TestEnvironment()
        environment.cloud.reset("GET", "/v1/devices")
        environment.cloud.answer("GET", "/v1/devices", Self.matterDevices)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("bbbb0000-0000-4000-8000-0000000000c1") != nil })
        #expect(host.accessory("aaaa0000-0000-4000-8000-0000000000b0") == nil && host.accessory("aaaa0000-0000-4000-8000-0000000000b1") == nil)
        #expect(host.accessory("cccc0000-0000-4000-8000-0000000000c2")?.service(.switch) != nil)
        let plugin = try #require(environment.plugin)
        let ids = try await plugin.discover().map(\.deviceID)
        #expect(!ids.contains("aaaa0000-0000-4000-8000-0000000000b0") && ids.contains("bbbb0000-0000-4000-8000-0000000000c1"))
        let diagnostics = await plugin.diagnostics()
        #expect(diagnostics["skippedCopies"]?.arrayValue?.count == 2)
        // The Eve plug's power is on its switch's Meter.
        #expect(host.accessory("bbbb0000-0000-4000-8000-0000000000c1")?.service(.switch)?[.on]?.value == .bool(true))
    }
}
