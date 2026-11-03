import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// A room renamed in Homeswift, renamed on the plugins' hubs too when Room Sync is on (docs/ui.md, "Rooms on the hubs"):
/// a Bridge Setting, `bridge.roomSync`, which applies without a restart. The devices plugin's hub has the rooms Séjour, Kitchen and Bedroom, and refuses the name Attic.
@Suite struct HubRoomTests {
    func hubRooms(_ environment: MCPTestEnvironment) -> [String: String] { environment.hubRooms.withLockedValue { $0 } }
    func bridge(_ environment: MCPTestEnvironment) throws -> JSONValue { try JSONValue(data: Data(contentsOf: environment.configURL))["bridge"] ?? [:] }
    func lampRoom(_ environment: MCPTestEnvironment) throws -> JSONValue? {
        try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]?["_accessories"]?["lamp"]?["room"]
    }
    func move(_ environment: MCPTestEnvironment, to room: String) async throws -> JSONValue {
        try await environment.catalog.updateAccessorySettings([("Devices:lamp", ["room": .string(room)])], who: "test")
    }

    /// Off by default: the room is renamed in Homeswift only.
    @Test func renamesOnlyInHomeswiftByDefault() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await environment.catalog.updateLayout(["rooms": ["Sejour"]], by: "test")
        #expect(environment.catalog.layoutJSON()["syncRoomNames"] == false)

        let answer = try await environment.catalog.updateLayout(["renameRoom": ["from": "Sejour", "to": "Living room"]], by: "test")
        #expect(answer["rooms"]?[0]?["name"] == "Living room")
        #expect(answer["hubRooms"] == nil)
        #expect(hubRooms(environment)["r1"] == "Séjour")
    }

    /// With it on, set_accessory_layout's renameRoom renames the hub's room of the same name, case and accents aside,
    /// and leaves the others; the answer says what each hub did, and the change is audited.
    @Test func renamesTheHubRoomOfTheSameName() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        _ = try await environment.catalog.updateLayout(["rooms": ["sejour", "Kitchen"]], by: "test")

        let on = try await client.tool("set_accessory_layout", ["syncRoomNames": true])["structuredContent"]
        #expect(on?["syncRoomNames"] == true)
        #expect(try bridge(environment)["roomSync"] == true)
        #expect(environment.catalog.home.layout.value.syncRoomNames == nil)

        let renamed = try await client.tool("set_accessory_layout", ["renameRoom": ["from": "sejour", "to": "Living room"]])["structuredContent"]
        #expect(renamed?["hubRooms"] == [["hub": "Devices:Devices", "name": "Devices", "room": "r1", "from": "Séjour", "to": "Living room", "renamed": true]])
        #expect(hubRooms(environment) == ["r1": "Living room", "r2": "Kitchen", "r3": "Bedroom"])
        #expect(environment.auditEntries.filter { $0["tool"] == "set_accessory_layout" }.count == 2)

        // A rename the layout refuses changes no hub.
        _ = try? await environment.catalog.updateLayout(["renameRoom": ["from": "Living room", "to": "kitchen"]], by: "test")
        #expect(hubRooms(environment)["r1"] == "Living room")
    }

    /// A hub that refuses the name says so in the answer; the room is renamed in Homeswift all the same.
    @Test func reportsAHubThatRefuses() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await environment.catalog.updateLayout(["rooms": ["Kitchen"], "syncRoomNames": true], by: "test")

        let answer = try await environment.catalog.updateLayout(["renameRoom": ["from": "Kitchen", "to": "Attic"]], by: "test")
        #expect(answer["rooms"]?[0]?["name"] == "Attic")
        #expect(answer["hubRooms"]?[0]?["renamed"] == false)
        #expect(answer["hubRooms"]?[0]?["error"] == "that name is taken")
        #expect(hubRooms(environment)["r2"] == "Kitchen")

        // Off again: kept as no value in the bridge block.
        _ = try await environment.catalog.updateLayout(["syncRoomNames": false], by: "test")
        #expect(try bridge(environment)["roomSync"] == nil)
        #expect(!environment.catalog.roomSync)
        await #expect(throws: CatalogError.self) { try await environment.catalog.updateLayout(["syncRoomNames": "yes"], by: "test") }
    }

    /// The other way: a room renamed on a hub (in the Home app, through Wingman) renames the layout's room of the old
    /// name when `syncRoomNames` is on, and nothing goes back to the hub, which has the name already.
    @Test func followsARoomRenamedOnAHub() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await environment.catalog.updateLayout(["rooms": ["kitchen", "Bedroom"]], by: "test")
        let instance = try #require(await environment.host.pluginRooms().first?.instance)
        environment.hubRooms.withLockedValue { $0["r2"] = "Cuisine" }

        // Off: Homeswift keeps its name.
        await environment.catalog.followHubRoomChange(on: instance, .renamed(from: "Kitchen", to: "Cuisine"))
        #expect(environment.catalog.home.layout.value.rooms == ["kitchen", "Bedroom"])

        _ = try await environment.catalog.updateLayout(["syncRoomNames": true], by: "test")
        await environment.catalog.followHubRoomChange(on: instance, .renamed(from: "Kitchen", to: "Cuisine"))
        #expect(environment.catalog.home.layout.value.rooms == ["Cuisine", "Bedroom"])
        #expect(hubRooms(environment) == ["r1": "Séjour", "r2": "Cuisine", "r3": "Bedroom"])

        // A room Homeswift does not have, or a name another room has, changes nothing.
        await environment.catalog.followHubRoomChange(on: instance, .renamed(from: "Garage", to: "Atelier"))
        await environment.catalog.followHubRoomChange(on: instance, .renamed(from: "Cuisine", to: "bedroom"))
        #expect(environment.catalog.home.layout.value.rooms == ["Cuisine", "Bedroom"])
    }

    /// An accessory moved in Homeswift (its room setting) goes to the hub's room of that name too when Room Sync is on;
    /// the answer says what each hub did. Out of a room, or within the same one, it goes nowhere.
    @Test func movesAnAccessoryOnTheHubs() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await move(environment, to: "Office")
        #expect(environment.hubMoves.withLockedValue { $0 }.isEmpty)

        _ = try await environment.catalog.updateLayout(["syncRoomNames": true], by: "test")
        let answer = try await move(environment, to: "Kitchen")
        #expect(answer["hubMoves"] == [["hub": "Devices:Devices", "name": "Devices", "accessory": "Devices:lamp", "room": "Kitchen", "moved": true]])
        #expect(environment.hubMoves.withLockedValue { $0 } == ["Devices:lamp": "Kitchen"])

        let refused = try await move(environment, to: "Attic")
        #expect(refused["hubMoves"]?[0]?["moved"] == false)
        #expect(refused["hubMoves"]?[0]?["error"] == "that name is taken")

        let same = try await move(environment, to: "attic")
        #expect(same["hubMoves"] == nil)
        let out = try await move(environment, to: "")
        #expect(out["hubMoves"] == nil)
    }

    /// The other way: an accessory moved on a hub moves in Homeswift when Room Sync is on (its room setting), to a room
    /// added when there is none, and goes back to no hub.
    @Test func followsAnAccessoryMovedOnAHub() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await move(environment, to: "Office")
        let instance = try #require(await environment.host.pluginRooms().first?.instance)

        await environment.catalog.followHubRoomChange(on: instance, .moved(accessoryID: "Devices:lamp", room: "Kitchen"))
        #expect(try lampRoom(environment) == "Office")

        _ = try await environment.catalog.updateLayout(["syncRoomNames": true], by: "test")
        await environment.catalog.followHubRoomChange(on: instance, .moved(accessoryID: "Devices:lamp", room: "Kitchen"))
        #expect(try lampRoom(environment) == "Kitchen")
        #expect(environment.catalog.find(id: "Devices:lamp")?.room == "Kitchen")
        #expect(environment.catalog.home.layout.value.rooms.contains("Kitchen"))
        #expect(environment.hubMoves.withLockedValue { $0 }.isEmpty)

        // One Homeswift does not have changes nothing.
        await environment.catalog.followHubRoomChange(on: instance, .moved(accessoryID: "Devices:nothing", room: "Garage"))
        #expect(!environment.catalog.home.layout.value.rooms.contains("Garage"))
    }
}
