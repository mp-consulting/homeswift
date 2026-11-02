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

    // MARK: Rooms

    @Test func roomsAreListedAndRenamedInAppleHome() async throws {
        let (host, plugin) = try await start()
        let rooms = await plugin.rooms()
        #expect(rooms.map(\.name) == ["Salon", "Bureau", "Cave", "Entrée"])
        #expect(rooms.first?.place == "Maison")
        // Through the host, as "Sync rooms with the hubs" does.
        try await host.renameRoom(platform: "Wingman", name: "Wingman", id: "room-salon", to: "Séjour")
        #expect(environment.wingman.edits.last == .init(path: "rooms/rename", body: ["room": "room-salon", "name": "Séjour"]))
        #expect(await plugin.rooms().first?.name == "Séjour")
        // The "homes" event Wingman makes moves the mirrored light to the renamed room.
        #expect(await eventually { host.mainBridge.server.accessories.first { $0.id == "Wingman:light-1" }?.suggestedRoom == "Séjour" })
        await host.stop()
    }

    /// A room renamed in the Home app is said to Homeswift once; one Homeswift renamed is not said back.
    @Test func aRoomRenamedInAppleHomeIsSaidToHomeswift() async throws {
        let (host, plugin) = try await start()
        let renames = NIOLockedValueBox<[String]>([])
        host.handleHubRoomChanges { instance, change in
            if case .renamed(let from, let to) = change { renames.withLockedValue { $0.append("\(instance.platform) \(from)→\(to)") } }
        }
        try await plugin.renameRoom(id: "room-bureau", name: "Atelier")
        environment.wingman.renameRoomInAppleHome("room-cave", to: "Cellier")
        #expect(await eventually { renames.withLockedValue { $0 } == ["Wingman Cave→Cellier"] })
        #expect(await plugin.rooms().map(\.name) == ["Salon", "Atelier", "Cellier", "Entrée"])
        await host.stop()
    }

    /// Homeswift's own plug, as the host publishes it: Apple Home knows it by its serial number.
    func publishPlug(_ host: PluginHost) throws {
        try host.mainBridge.server.add(Accessory(
            id: "Meross:plug", name: "Plug", serialNumber: "PLUG-SERIAL", category: .outlet, services: [Service(.outlet, isPrimary: true)]))
    }

    /// An accessory moved in Homeswift moves in Apple Home: a mirror by its id, one of Homeswift's own by its serial
    /// number, to a room Apple Home adds when it has none; one Apple Home does not have is not Wingman's.
    @Test func anAccessoryMovedInHomeswiftMovesInAppleHome() async throws {
        let (host, plugin) = try await start()
        try publishPlug(host)
        let changes = NIOLockedValueBox<[HubRoomChange]>([])
        host.handleHubRoomChanges { _, change in changes.withLockedValue { $0.append(change) } }

        #expect(try await plugin.moveAccessory(id: "Wingman:light-1", toRoom: "Bureau"))
        #expect(environment.wingman.edits.last == .init(path: "accessories/room", body: ["accessory": "light-1", "room": "Bureau"]))
        #expect(try await plugin.moveAccessory(id: "Meross:plug", toRoom: "Garage"))
        #expect(environment.wingman.edits.last == .init(path: "accessories/room", body: ["accessory": "homeswift-switch", "room": "Garage"]))
        #expect(try await !plugin.moveAccessory(id: "Elgato:lamp", toRoom: "Garage"))
        // Already there: nothing sent.
        #expect(try await plugin.moveAccessory(id: "Meross:plug", toRoom: "garage"))
        #expect(environment.wingman.edits.count == 2)

        // Wingman's "homes" event shows both moves; neither is said back.
        #expect(await eventually { await plugin.rooms().contains { $0.name == "Garage" } })
        #expect(await eventually { host.mainBridge.server.accessories.first { $0.id == "Wingman:light-1" }?.suggestedRoom == "Bureau" })
        #expect(changes.withLockedValue { $0 }.isEmpty)
        await host.stop()
    }

    /// An accessory moved in the Home app is said to Homeswift by Homeswift's id: a mirror's, or its own plug's.
    @Test func anAccessoryMovedInAppleHomeIsSaidToHomeswift() async throws {
        let (host, _) = try await start()
        try publishPlug(host)
        let changes = NIOLockedValueBox<[HubRoomChange]>([])
        host.handleHubRoomChanges { _, change in changes.withLockedValue { $0.append(change) } }
        environment.wingman.moveInAppleHome("homeswift-switch", to: "Cave")
        #expect(await eventually { changes.withLockedValue { $0 } == [.moved(accessoryID: "Meross:plug", room: "Cave")] })
        environment.wingman.moveInAppleHome("light-1", to: "Cave")
        #expect(await eventually { changes.withLockedValue { $0 }.last == .moved(accessoryID: "Wingman:light-1", room: "Cave") })
        await host.stop()
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
        #expect(await plugin.rooms().isEmpty)
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
        // A room rename still asks Wingman, which says why it refuses.
        let error = await #expect(throws: WingmanError.self) { try await plugin.renameRoom(id: "room-salon", name: "Séjour") }
        #expect(error?.description == "structural edits are turned off in Wingman's settings")
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
