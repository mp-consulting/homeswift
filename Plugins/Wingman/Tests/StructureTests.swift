import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftWingman

/// Apple Home's rooms, scenes and automations through a Wingman that serves them (docs/apple-home-design.md).
@Suite(.timeLimit(.minutes(1)))
struct StructureTests {
    let environment = TestEnvironment()

    /// A host whose plugin has read the structure (the automations come last).
    func start() async throws -> (PluginHost, WingmanPlugin) {
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await !plugin.automations().isEmpty })
        return (host, plugin)
    }

    func scene(_ plugin: WingmanPlugin, _ id: String) async throws -> PluginScene {
        try #require(await plugin.scenes().first { $0.id == id })
    }

    func automation(_ plugin: WingmanPlugin, _ id: String) async throws -> PluginAutomation {
        try #require(await plugin.automations().first { $0.id == id })
    }

    // MARK: The Home Link

    /// Wingman's view of the bridge's home, as the Home Link gives it: rooms, zones and placements by id, Homeswift's ids
    /// for the accessories (a mirror's, its own plug's by serial number).
    @Test func theHomeLinkGivesTheBridgesHome() async throws {
        let (host, plugin) = try await start()
        try publishPlug(host)
        #expect(await plugin.homeLinkState() == .up)
        #expect(await eventually { await plugin.homeSnapshot()?.placements["Meross:plug"] != nil })
        let home = try #require(await plugin.homeSnapshot())
        #expect(home.homeID == "home-1")
        #expect(home.rooms.map(\.name) == ["Salon", "Bureau", "Cave", "Entrée"])
        #expect(home.placements["Wingman:light-1"] == .some("room-salon"))
        #expect(home.placements["Meross:plug"] == .some("room-bureau"))
        #expect(home.zones == [.init(id: "zone-bas", name: "Rez-de-chaussée", rooms: ["room-salon", "room-entree"])])
        await host.stop()
    }

    @Test func incompleteIdentityWaitsForHomeKitAndRecovers() async throws {
        environment.wingman.missingSerial("homeswift-switch", true)
        let (host, plugin) = try await start()
        try publishPlug(host)
        let state = await plugin.homeLinkState()
        guard case .down(let reason) = state else {
            Issue.record("Incomplete identity must keep the Home Link down, got \(String(describing: state))")
            await host.stop()
            return
        }
        #expect(reason.contains("Serial Number"))
        #expect(await plugin.homeSnapshot() == nil)
        let error = await #expect(throws: HomeChangeError.self) {
            try await plugin.applyHomeChange(.createGroup(name: "Lights", members: ["Wingman:light-1", "Meross:plug"]))
        }
        #expect(error?.kind == .unreachable)
        #expect(environment.wingman.edits.isEmpty)
        environment.wingman.missingSerial("homeswift-switch", false)
        #expect(await eventually { await plugin.homeLinkState() == .up })
        #expect(await plugin.homeSnapshot()?.placements["Meross:plug"] == .some("room-bureau"))
        _ = try await plugin.applyHomeChange(.createGroup(name: "Lights", members: ["Wingman:light-1", "Meross:plug"]))
        #expect(environment.wingman.edits.last?.path == "groups/create")
        // A later incomplete refresh must not publish a group with only the still-identifiable member.
        environment.wingman.missingSerial("homeswift-switch", true)
        #expect(await eventually { await plugin.homeSnapshot() == nil })
        guard case .down = await plugin.homeLinkState() else {
            Issue.record("Losing a previously known identity must pause the Home Link")
            await host.stop()
            return
        }
        environment.wingman.missingSerial("homeswift-switch", false)
        #expect(await eventually { await plugin.homeSnapshot()?.groups.first?.members.count == 2 })
        await host.stop()
    }

    /// Changes the Home Link asks for go to Wingman by id; one Apple Home does not have is not found.
    @Test func changesGoToAppleHomeByID() async throws {
        let (host, plugin) = try await start()
        try publishPlug(host)
        #expect(await eventually { await plugin.homeSnapshot()?.placements["Meross:plug"] != nil })
        let garage = try #require(try await plugin.applyHomeChange(.createRoom(name: "Garage")))
        #expect(environment.wingman.edits.last == .init(path: "rooms/create", body: ["name": "Garage", "home": "home-1"]))
        _ = try await plugin.applyHomeChange(.moveAccessory(accessoryID: "Meross:plug", roomID: garage))
        #expect(environment.wingman.edits.last == .init(path: "accessories/room", body: ["accessory": "homeswift-switch", "roomID": .string(garage)]))
        #expect(await plugin.homeSnapshot()?.placements["Meross:plug"] == .some(garage))
        _ = try await plugin.applyHomeChange(.moveAccessory(accessoryID: "Wingman:light-1", roomID: nil))
        #expect(environment.wingman.edits.last == .init(path: "accessories/room", body: ["accessory": "light-1", "roomID": .null]))
        #expect(environment.wingman.room(of: "light-1") == "Default Room")
        _ = try await plugin.applyHomeChange(.renameRoom(id: "room-cave", name: "Cellier"))
        #expect(await plugin.homeSnapshot()?.room("room-cave")?.name == "Cellier")
        _ = try await plugin.applyHomeChange(.deleteRoom(id: garage))
        #expect(await plugin.homeSnapshot()?.room(garage) == nil)
        let zone = try #require(try await plugin.applyHomeChange(.createZone(name: "Étage")))
        _ = try await plugin.applyHomeChange(.setZoneRooms(id: zone, add: ["room-bureau"], remove: []))
        #expect(await plugin.homeSnapshot()?.zones.first { $0.id == zone }?.rooms == ["room-bureau"])
        let group = try #require(try await plugin.applyHomeChange(.createGroup(name: "Lampes", members: ["Wingman:light-1", "Meross:plug"])))
        #expect(environment.wingman.edits.last == .init(path: "groups/create", body: ["name": "Lampes", "services": ["bulb-1", "switch-1"], "home": "home-1"]))
        #expect(await plugin.homeSnapshot()?.groups == [.init(id: group, name: "Lampes", members: ["Wingman:light-1", "Meross:plug"])])
        let error = await #expect(throws: HomeChangeError.self) { try await plugin.applyHomeChange(.moveAccessory(accessoryID: "Elgato:lamp", roomID: nil)) }
        #expect(error?.kind == .notFound)
        await host.stop()
    }

    /// A change in the Home app reaches Homeswift as a new snapshot (`PluginContext.homeChanged()`).
    @Test func aChangeInTheHomeAppIsSaid() async throws {
        let (host, plugin) = try await start()
        let said = NIOLockedValueBox(0)
        host.handleHomeChanges { said.withLockedValue { $0 += 1 } }
        environment.wingman.renameRoomInAppleHome("room-cave", to: "Cellier")
        #expect(await eventually { await plugin.homeSnapshot()?.room("room-cave")?.name == "Cellier" })
        #expect(await eventually { said.withLockedValue { $0 } > 0 })
        environment.wingman.deleteRoomInAppleHome("room-cave")
        #expect(await eventually { await plugin.homeSnapshot()?.room("room-cave") == nil })
        await host.stop()
    }

    /// Up but not allowed to edit, Apple Home's changes still come; a Wingman from before the Home Link is no link.
    @Test func theLinksStateSaysWhatToTurnOn() async throws {
        let (host, plugin) = try await start()
        environment.wingman.allowStructure(false)
        #expect(await eventually { if case .readOnly = await plugin.homeLinkState() { true } else { false } })
        let error = await #expect(throws: HomeChangeError.self) { try await plugin.applyHomeChange(.renameRoom(id: "room-salon", name: "Séjour")) }
        #expect(error?.kind == .refused)
        await host.stop()

        environment.wingman.withoutHomeLink()
        let older = try await environment.start()
        let plugin2 = try #require(environment.plugin)
        #expect(await eventually { await !plugin2.automations().isEmpty })
        guard case .down(let reason) = await plugin2.homeLinkState() else { Issue.record("not down"); return }
        #expect(reason.contains("Update Homeswift Wingman"))
        #expect(await plugin2.homeSnapshot() == nil)
        await older.stop()
    }

    /// Homeswift's own plug, as the host publishes it: Apple Home knows it by its serial number.
    func publishPlug(_ host: PluginHost) throws {
        try host.mainBridge.server.add(Accessory(
            id: "Meross:plug", name: "Plug", serialNumber: "PLUG-SERIAL", category: .outlet, services: [Service(.outlet, isPrimary: true)]))
    }

    func homeAccessory(_ id: String, serialNumber: String, bridge: [String: Any]? = nil) -> [String: Any] {
        var accessory: [String: Any] = ["id": id, "name": id, "services": [[
            "type": "0000003E-0000-1000-8000-0026BB765291",
            "characteristics": [["type": "00000030-0000-1000-8000-0026BB765291", "properties": ["read"], "value": serialNumber]],
        ]]]
        if let bridge { accessory["bridge"] = bridge }
        return accessory
    }

    @Test(arguments: [false, true])
    func incompleteOwnershipDoesNotPublishPartialGroups(childBridge: Bool) throws {
        let bridge = TestEnvironment.bridgeID
        var unresolved = homeAccessory("unresolved", serialNumber: "")
        if childBridge { unresolved["manufacturer"] = "Homeswift"; unresolved["model"] = "Homeswift" }
        var accessories = [homeAccessory("main-bridge", serialNumber: bridge), unresolved]
        if childBridge {
            accessories.append(homeAccessory("child-light", serialNumber: "LIGHT", bridge: ["id": "unresolved", "name": "Child", "manufacturer": "Homeswift"]))
        }
        let json: [String: Any] = ["id": "home-1", "name": "Maison", "accessories": accessories]
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: json))
        let structure = Structure(allowed: true, homes: [home], mirrored: [], bridges: [bridge, "CHILD"], own: childBridge ? [] : ["TV"])
        #expect(structure.incompleteIdentityReason?.contains("Serial Number of unresolved") == true)
    }

    /// The reason names the accessories without a Serial Number, with their room, five at most.
    @Test func incompleteIdentitiesAreNamed() throws {
        let bridge = TestEnvironment.bridgeID
        var accessories = [homeAccessory("main-bridge", serialNumber: bridge)]
        for index in 1...7 {
            var light = homeAccessory("light-\(index)", serialNumber: "", bridge: ["id": "main-bridge", "name": "Homeswift"])
            light["name"] = "Spot \(index)"
            if index == 1 { light["room"] = "Salon" }
            accessories.append(light)
        }
        let json: [String: Any] = ["id": "home-1", "name": "Maison", "accessories": accessories]
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: json))
        let structure = Structure(allowed: true, homes: [home], mirrored: [], bridges: [bridge])
        #expect(structure.incompleteIdentityReason
            == "Waiting for Homeswift Wingman to read the Serial Number of Spot 1 (Salon), Spot 2, Spot 3, Spot 4, Spot 5 and 2 more in Apple Home")
    }

    /// One of Homeswift's own accessories is found behind its bridge (the home's accessory whose Serial Number is the
    /// bridge's device ID), never a home's own accessory with the same serial number, such as the light a hub also brings
    /// to Apple Home; one published on its own is found among those that are not bridged.
    @Test func homeswiftsOwnAccessoriesAreFoundBehindItsBridge() throws {
        let bridge = TestEnvironment.bridgeID
        let json: [String: Any] = ["id": "home-1", "name": "Maison", "accessories": [
            homeAccessory("homeswift-bridge", serialNumber: bridge),
            homeAccessory("hub-light", serialNumber: "SN", bridge: ["id": "hue-bridge", "name": "Hue Bridge"]),
            homeAccessory("homeswift-light", serialNumber: "SN", bridge: ["id": "homeswift-bridge", "name": "Homeswift"]),
            homeAccessory("other-homeswift", serialNumber: "SN", bridge: ["id": "elsewhere", "name": "Homeswift", "manufacturer": "Homeswift"]),
            homeAccessory("older-wingman", serialNumber: "OLD", bridge: ["name": "Homeswift", "manufacturer": "Homeswift"]),
            homeAccessory("homeswift-tv", serialNumber: "TV"),
            homeAccessory("hub-tv", serialNumber: "TV", bridge: ["id": "hue-bridge", "name": "Hue Bridge"]),
        ]]
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: json))
        let structure = Structure(allowed: true, homes: [home], mirrored: [], bridges: [bridge], own: ["TV"])

        #expect(structure.homeKitID(of: "Hue:light", place: .init(bridge: bridge, serialNumber: "SN")) == "homeswift-light")
        #expect(structure.homeKitID(of: "PhilipsAmbilightTV:tv", place: .init(bridge: nil, serialNumber: "TV")) == "homeswift-tv")
        // A Wingman that does not name bridges: a bridge that says it is Homeswift's.
        #expect(structure.homeKitID(of: "Old:plug", place: .init(bridge: bridge, serialNumber: "OLD")) == "older-wingman")
        #expect(structure.homeKitID(of: "Hue:gone", place: .init(bridge: bridge, serialNumber: "NONE")) == nil)
        // Another Homeswift's bridge, or a hub's, is not this one.
        #expect(structure.devices["other-homeswift"]?.homeswift == nil)
        #expect(structure.devices["hub-light"]?.homeswift == nil)
        #expect(structure.devices["hub-tv"]?.homeswift == nil)
    }

    @Test func groupingSelectsTheControlInsteadOfAnAuxiliaryService() throws {
        let json: [String: Any] = ["id": "home-1", "name": "Home", "accessories": [[
            "id": "lamp", "name": "Lamp", "services": [
                ["id": "battery", "type": ServiceType.battery.uuid.uuidString, "characteristics": []],
                ["id": "light", "type": ServiceType.lightbulb.uuid.uuidString, "characteristics": []],
            ],
        ], [
            "id": "sensor", "name": "Sensor", "services": [
                ["id": "temperature", "type": ServiceType.temperatureSensor.uuid.uuidString, "characteristics": []],
            ],
        ]]]
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: json))
        let structure = Structure(allowed: true, homes: [home], mirrored: ["lamp", "sensor"])
        #expect(structure.devices["lamp"]?.groupingService == "light")
        #expect(structure.devices["sensor"]?.groupingService == nil)
    }

    @Test func groupingRejectsMultiplePrimaryServicesAndMirrorsPreserveThem() throws {
        let on: [String: Any] = ["type": CharacteristicType.on.uuid.uuidString, "format": "bool", "properties": ["read", "write"], "value": false]
        let json: [String: Any] = ["id": "home-1", "name": "Home", "accessories": [[
            "id": "ambiguous", "name": "Ambiguous", "services": [
                ["id": "light", "type": ServiceType.lightbulb.uuid.uuidString, "primary": true, "characteristics": [on]],
                ["id": "switch", "type": ServiceType.switch.uuid.uuidString, "primary": true, "characteristics": [on]],
            ],
        ]]]
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: json))
        let structure = Structure(allowed: true, homes: [home], mirrored: ["ambiguous"])
        #expect(structure.devices["ambiguous"]?.groupingService == nil)
        let source = try #require(home.accessories.first)
        let mirror = try #require(Mirror(source) { _, _, _ in })
        #expect(mirror.accessory.services.filter(\.isPrimary).count == 2)
    }

    // MARK: Scenes

    @Test func scenesAreListedWithWhatHomeswiftMayDo() async throws {
        let (host, plugin) = try await start()
        let evening = try await scene(plugin, "scene-evening")
        #expect(evening.name == "Soirée")
        // The light (Salon) and the Homeswift plug (Bureau): no single room; only the mirrored light is named.
        #expect(evening.room == nil)
        #expect(evening.accessoryIDs == ["Wingman:light-1"])
        #expect(evening.capabilities == [.recall, .rename, .update, .delete])
        #expect(evening.colours.count == 1)
        #expect(evening.colours.first?.hasPrefix("#") == true)

        let reading = try await scene(plugin, "scene-reading")
        #expect(reading.room == "Salon")
        #expect(reading.colours.count == 1)
        // Built in: run and changed, never renamed or removed.
        #expect(try await scene(plugin, "scene-wake").capabilities == [.recall, .update])
        // A shortcut action Homeswift cannot show: its actions are never replaced.
        #expect(try await scene(plugin, "scene-shortcut").capabilities == [.recall, .rename, .delete])
        await host.stop()
    }

    @Test func aSceneIsRunRenamedAndDeleted() async throws {
        let (host, plugin) = try await start()
        try await plugin.recallScene(id: "scene-evening")
        #expect(environment.wingman.edits.last == .init(path: "scenes/run", body: ["scene": "scene-evening"]))

        try await host.updateScene(platform: "Wingman", name: "Wingman", id: "scene-evening", sceneName: "Veillée", lights: nil)
        #expect(try await scene(plugin, "scene-evening").name == "Veillée")

        try await plugin.deleteScene(id: "scene-evening")
        #expect(await plugin.scenes().contains { $0.id == "scene-evening" } == false)
        await #expect(throws: PluginSceneError.self) { try await plugin.deleteScene(id: "scene-wake") }
        await host.stop()
    }

    /// "Keep the lights as they are": the light's actions are replaced, the plug's stays.
    @Test func updatingASceneFromLightsKeepsItsOtherActions() async throws {
        let (host, plugin) = try await start()
        let light = PluginSceneLight(accessoryID: "Wingman:light-1", on: true, brightness: 70, colorTemperature: 250)
        try await plugin.updateScene(id: "scene-evening", name: nil, lights: [light])
        let edit = try #require(environment.wingman.edits.last)
        #expect(edit.path == "scenes/actions")
        let actions = try #require(edit.body["actions"]?.arrayValue)
        #expect(actions.contains { $0["accessory"] == "homeswift-switch" && $0["characteristic"] == "switch-on" && $0["value"] == true })
        #expect(actions.contains { $0["characteristic"] == "light-brightness" && $0["value"]?.doubleValue == 70 })
        #expect(actions.contains { $0["characteristic"] == "light-ct" && $0["value"]?.doubleValue == 250 })
        // The old colour went with the light's old actions.
        #expect(!actions.contains { $0["characteristic"] == "light-hue" })
        #expect(actions.count == 4)
        await #expect(throws: PluginSceneError.self) { try await plugin.updateScene(id: "scene-shortcut", name: nil, lights: [light]) }
        await host.stop()
    }

    @Test func aNewSceneGoesToTheLightsHome() async throws {
        let (host, plugin) = try await start()
        #expect(await plugin.sceneTarget(accessoryIDs: ["Wingman:light-1"]) == "Maison in Apple Home")
        #expect(await plugin.sceneTarget(accessoryIDs: ["Elgato:abc"]) == nil)
        let id = try await plugin.createScene(name: "Nuit", lights: [PluginSceneLight(accessoryID: "Wingman:light-1", on: false)])
        #expect(id == "scene-new-1")
        #expect(environment.wingman.edits.last == .init(path: "scenes/create", body: [
            "home": "home-1", "name": "Nuit", "actions": [["accessory": "light-1", "characteristic": "light-on", "value": false]],
        ]))
        #expect(try await scene(plugin, id).name == "Nuit")
        await host.stop()
    }

    @Test func aSceneRenamedInTheHomeAppArrivesAtOnce() async throws {
        let (host, plugin) = try await start()
        environment.wingman.renameSceneInAppleHome("scene-reading", to: "Livre")
        #expect(await eventually { (try? await scene(plugin, "scene-reading"))?.name == "Livre" })
        await host.stop()
    }

    // MARK: Automations

    @Test func automationsAreMappedWithTheirTriggersAndConditions() async throws {
        let (host, plugin) = try await start()
        let sunset = try await automation(plugin, "auto-sunset")
        #expect(sunset.name == "Coucher du soleil")
        #expect(sunset.enabled)
        #expect(sunset.place == "Maison")
        #expect(sunset.triggers == [.time(PluginAutomationTime(solarEvent: .sunset, offsetMinutes: -15, weekdays: [2, 3, 4, 5, 6]))])
        #expect(sunset.conditions == [.time(after: nil, before: PluginAutomationTime(hour: 23, minute: 0))])
        #expect(sunset.sceneIDs == ["scene-evening"])
        #expect(sunset.lastRun == ISO8601DateFormatter().date(from: "2026-11-01T17:12:03Z"))
        #expect(sunset.capabilities == Set(PluginAutomation.Capability.allCases))

        let warm = try await automation(plugin, "auto-warm")
        #expect(warm.triggers == [.accessory(accessoryID: "Wingman:sensor-1", characteristic: "Current Temperature", value: nil, minimum: 25, maximum: nil)])
        #expect(warm.endTriggers == [.duration(seconds: 600)])
        #expect(warm.conditions == [.presence(who: "anyone", home: true), .other("SUBQUERY(...)")])
        #expect(warm.actions == [PluginAutomationAction(accessoryID: "Wingman:light-1", characteristic: "On", value: true)])
        #expect(warm.names == ["Wingman:sensor-1": "Thermomètre", "Wingman:light-1": "Plafonnier"])
        // Not a time trigger: its time is not changed from here.
        #expect(!warm.capabilities.contains(.time))

        let arrive = try await automation(plugin, "auto-arrive")
        #expect(!arrive.enabled)
        #expect(arrive.triggers == [.presence(who: "anyone", arriving: true)])
        // An action Homeswift cannot show: its actions stay the Home app's.
        #expect(!arrive.capabilities.contains(.actions))
        await host.stop()
    }

    @Test func anAutomationIsChangedPartByPart() async throws {
        let (host, plugin) = try await start()
        let time = PluginAutomationTime(hour: 7, minute: 30, weekdays: [1, 7])
        try await host.updateAutomation(platform: "Wingman", name: "Wingman", id: "auto-sunset", change: PluginAutomationChange(
            name: "Matin", enabled: false, time: time, sceneIDs: ["scene-reading"],
            actions: [PluginAutomationAction(accessoryID: "Wingman:light-1", characteristic: "Brightness", value: 50)]))
        #expect(environment.wingman.edits.map(\.path) == ["automations/enable", "automations/rename", "automations/time", "automations/scenes", "automations/actions"])
        #expect(environment.wingman.edits[2].body["time"] == ["hour": 7, "minute": 30, "weekdays": [1, 7]])
        #expect(environment.wingman.edits[4].body["actions"] == [["accessory": "light-1", "characteristic": "light-brightness", "value": 50]])
        let changed = try await automation(plugin, "auto-sunset")
        #expect(changed.name == "Matin")
        #expect(!changed.enabled)
        #expect(changed.triggers == [.time(time)])
        #expect(changed.sceneIDs == ["scene-reading"])

        // Nothing is sent for what it cannot do, or for a scene Apple Home does not have.
        await #expect(throws: PluginAutomationError.self) {
            try await plugin.updateAutomation(id: "auto-warm", change: PluginAutomationChange(time: time))
        }
        await #expect(throws: PluginAutomationError.self) {
            try await plugin.updateAutomation(id: "auto-warm", change: PluginAutomationChange(sceneIDs: ["nope"]))
        }
        await #expect(throws: PluginAutomationError.self) {
            try await plugin.updateAutomation(id: "auto-warm", change: PluginAutomationChange(actions: [PluginAutomationAction(accessoryID: "Wingman:sensor-1", characteristic: "On", value: true)]))
        }
        #expect(environment.wingman.edits.count == 5)

        try await host.deleteAutomation(platform: "Wingman", name: "Wingman", id: "auto-sunset")
        #expect(await plugin.automations().contains { $0.id == "auto-sunset" } == false)
        await host.stop()
    }

    // MARK: Permissions and older Wingmen

    @Test func anOlderWingmanGivesNoneOfIt() async throws {
        environment.wingman.withoutStructure()
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == "Wingman:light-1" } })
        let plugin = try #require(environment.plugin)
        #expect(await plugin.homeSnapshot() == nil)
        #expect(await plugin.scenes().isEmpty)
        #expect(await plugin.automations().isEmpty)
        #expect(!environment.wingman.requests.contains("scenes"))
        await host.stop()
    }

    @Test func wingmansOwnerTurnsEditsOff() async throws {
        let (host, plugin) = try await start()
        environment.wingman.allowStructure(false)
        // The "settings" event: the scenes may only run now.
        #expect(await eventually { (try? await scene(plugin, "scene-evening"))?.capabilities == [.recall] })
        #expect(try await automation(plugin, "auto-sunset").capabilities.isEmpty)
        environment.wingman.allowStructure(true)
        #expect(await eventually { (try? await scene(plugin, "scene-evening"))?.capabilities.contains(.rename) == true })
        await host.stop()
    }

    @Test func aMacUserWhoIsNotAnAdministratorOnlyRunsScenes() async throws {
        environment.wingman.notAdministrator()
        let (host, plugin) = try await start()
        #expect(await plugin.scenes().allSatisfy { $0.capabilities == [.recall] })
        #expect(await plugin.automations().allSatisfy(\.capabilities.isEmpty))
        #expect(await plugin.sceneTarget(accessoryIDs: ["Wingman:light-1"]) == nil)
        await host.stop()
    }
}
