import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// A room renamed in Homeswift, renamed on the plugins' hubs too when `syncRoomNames` is on (docs/ui.md, "Rooms on
/// the hubs"). The devices plugin's hub has the rooms Séjour, Kitchen and Bedroom, and refuses the name Attic.
@Suite struct HubRoomTests {
    func hubRooms(_ environment: MCPTestEnvironment) -> [String: String] { environment.hubRooms.withLockedValue { $0 } }

    /// Off by default: the room is renamed in Homeswift only.
    @Test func renamesOnlyInHomeswiftByDefault() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try environment.catalog.updateLayout(["rooms": ["Sejour"]])
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
        _ = try environment.catalog.updateLayout(["rooms": ["sejour", "Kitchen"]])

        let on = try await client.tool("set_accessory_layout", ["syncRoomNames": true])["structuredContent"]
        #expect(on?["syncRoomNames"] == true)
        #expect(environment.catalog.home.layout.value.syncRoomNames == true)

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
        _ = try environment.catalog.updateLayout(["rooms": ["Kitchen"], "syncRoomNames": true])

        let answer = try await environment.catalog.updateLayout(["renameRoom": ["from": "Kitchen", "to": "Attic"]], by: "test")
        #expect(answer["rooms"]?[0]?["name"] == "Attic")
        #expect(answer["hubRooms"]?[0]?["renamed"] == false)
        #expect(answer["hubRooms"]?[0]?["error"] == "that name is taken")
        #expect(hubRooms(environment)["r2"] == "Kitchen")

        // Off again: kept as no value in the layout's file.
        _ = try environment.catalog.updateLayout(["syncRoomNames": false])
        #expect(environment.catalog.home.layout.value.syncRoomNames == nil)
        #expect(throws: CatalogError.self) { try environment.catalog.updateLayout(["syncRoomNames": "yes"]) }
    }

    /// The other way: a room renamed on a hub (in the Home app, through Wingman) renames the layout's room of the old
    /// name when `syncRoomNames` is on, and nothing goes back to the hub, which has the name already.
    @Test func followsARoomRenamedOnAHub() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try environment.catalog.updateLayout(["rooms": ["kitchen", "Bedroom"]])
        let instance = try #require(await environment.host.pluginRooms().first?.instance)
        environment.hubRooms.withLockedValue { $0["r2"] = "Cuisine" }

        // Off: Homeswift keeps its name.
        await environment.catalog.followHubRoomRename(on: instance, from: "Kitchen", to: "Cuisine")
        #expect(environment.catalog.home.layout.value.rooms == ["kitchen", "Bedroom"])

        _ = try environment.catalog.updateLayout(["syncRoomNames": true])
        await environment.catalog.followHubRoomRename(on: instance, from: "Kitchen", to: "Cuisine")
        #expect(environment.catalog.home.layout.value.rooms == ["Cuisine", "Bedroom"])
        #expect(hubRooms(environment) == ["r1": "Séjour", "r2": "Cuisine", "r3": "Bedroom"])

        // A room Homeswift does not have, or a name another room has, changes nothing.
        await environment.catalog.followHubRoomRename(on: instance, from: "Garage", to: "Atelier")
        await environment.catalog.followHubRoomRename(on: instance, from: "Cuisine", to: "bedroom")
        #expect(environment.catalog.home.layout.value.rooms == ["Cuisine", "Bedroom"])
    }
}
