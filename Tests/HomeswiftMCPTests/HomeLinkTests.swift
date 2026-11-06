import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// One room definition shared with Apple Home (docs/adr/0005-apple-home-owns-rooms-zones-and-groups.md): the bridge's
/// Rooms, Zones and Groups are the Home's through the Home Link, here the devices plugin standing in for Wingman
/// (`FakeHomeLink`). The devices plugin's own hub has the rooms Séjour, Kitchen and Bedroom, and refuses the name Attic.
@Suite struct HomeLinkTests {
    func environment(bulbs: Int = 0) async throws -> MCPTestEnvironment {
        let config = """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "Devices", "name": "Devices", "colourBulbs": \(bulbs) } ]
            }
            """
        let environment = try MCPTestEnvironment(config: config)
        try await environment.start()
        return environment
    }

    func lampRoom(_ environment: MCPTestEnvironment) -> String? { environment.catalog.find(id: "Devices:lamp")?.room }
    func move(_ environment: MCPTestEnvironment, _ id: String = "Devices:lamp", to room: String) async throws -> JSONValue {
        try await environment.catalog.updateAccessorySettings([(id, ["room": .string(room)])], who: "test")
    }

    /// A bridge with nothing of its own links at once: it takes the Home's Rooms and placements.
    @Test func aBridgeWithNoRoomsLinksAtOnce() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon"), ("hk-cuisine", "Cuisine")], placements: ["Devices:lamp": "hk-cuisine", "Devices:lock": nil])
        await environment.catalog.followHome()
        #expect(environment.catalog.home.layout.value.rooms == ["Salon", "Cuisine"])
        #expect(lampRoom(environment) == "Cuisine")
        #expect(environment.catalog.find(id: "Devices:lock")?.room == nil)
        let link = await environment.catalog.homeLinkJSON()
        #expect(link["state"] == "up" && link["linked"] == true && link["home"] == "Maison")
        #expect(environment.homeLink.applied.isEmpty)
    }

    /// A bridge with Rooms of its own waits for a person to confirm; confirmed, its own Rooms are made in Apple Home,
    /// Apple Home's placements win, and one in No Room there keeps the bridge's Room.
    @Test func aBridgeWithRoomsOfItsOwnWaitsForTheFirstLinkToBeConfirmed() async throws {
        let environment = try await environment(bulbs: 1)
        defer { Task { await environment.stop() } }
        _ = try await move(environment, to: "Office")
        _ = try await move(environment, "Devices:bulb1", to: "Office")
        environment.homeLink.turnOn(rooms: [("hk-cuisine", "Cuisine")], placements: ["Devices:lamp": "hk-cuisine", "Devices:bulb1": nil])
        await environment.catalog.followHome()

        let waiting = await environment.catalog.homeLinkJSON()
        #expect(waiting["linked"] == false)
        #expect(waiting["comparison"]?["roomsOnlyHere"] == ["Office"])
        #expect(waiting["comparison"]?["roomsOnlyInHome"] == ["Cuisine"])
        #expect(waiting["comparison"]?["accessories"]?.arrayValue?.count == 2)
        #expect(lampRoom(environment) == "Office")
        #expect(environment.homeLink.applied.isEmpty)

        _ = try await environment.catalog.confirmHomeLink(by: "test")
        let office = try #require(environment.homeLink.home.rooms.first { $0.name == "Office" }?.id)
        #expect(environment.homeLink.applied.contains(.createRoom(name: "Office")))
        #expect(environment.homeLink.home.placements["Devices:bulb1"] == .some(office))
        #expect(lampRoom(environment) == "Cuisine")
        #expect(environment.catalog.find(id: "Devices:bulb1")?.room == "Office")
        #expect(Set(environment.catalog.home.layout.value.rooms) == ["Office", "Cuisine"])
        #expect(await environment.catalog.homeLinkJSON()["linked"] == true)
    }

    /// Linked, a move in Homeswift is a move in Apple Home, to a Room by its id or to the Default Room; a new Room is
    /// made there first.
    @Test func movesAndNewRoomsReachAppleHome() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon")], placements: ["Devices:lamp": nil])
        await environment.catalog.followHome()
        _ = try await move(environment, to: "Salon")
        #expect(environment.homeLink.home.placements["Devices:lamp"] == .some("hk-salon"))
        _ = try await move(environment, to: "Garage")
        let garage = try #require(environment.homeLink.home.rooms.first { $0.name == "Garage" }?.id)
        #expect(environment.homeLink.home.placements["Devices:lamp"] == .some(garage))
        _ = try await move(environment, to: "")
        #expect(environment.homeLink.home.placements["Devices:lamp"] == .some(nil))
        // Not in the Home: nothing to move there, and nothing kept.
        _ = try await move(environment, "Devices:lock", to: "Salon")
        #expect(environment.catalog.home.homeLink.value.pending.isEmpty)
    }

    /// A Room renamed or removed in the Home app is here too, by its id: a rename is never read as moves, and the other
    /// hubs' rooms of the old name follow.
    @Test func roomsRenamedAndRemovedInAppleHomeAreFollowed() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-kitchen", "Kitchen"), ("hk-bed", "Bedroom")], placements: ["Devices:lamp": "hk-kitchen"])
        await environment.catalog.followHome()
        #expect(lampRoom(environment) == "Kitchen")

        environment.homeLink.set { $0.home.rooms[0].name = "Cuisine" }
        await environment.catalog.followHome()
        #expect(environment.catalog.home.layout.value.rooms == ["Cuisine", "Bedroom"])
        #expect(lampRoom(environment) == "Cuisine")
        #expect(environment.hubRooms.withLockedValue { $0["r2"] } == "Cuisine")
        #expect(environment.homeLink.applied.isEmpty)

        environment.homeLink.set { state in
            state.home.rooms.removeAll { $0.id == "hk-kitchen" }
            state.home.placements["Devices:lamp"] = .some(nil)
        }
        await environment.catalog.followHome()
        #expect(environment.catalog.home.layout.value.rooms == ["Bedroom"])
        #expect(lampRoom(environment) == nil)
    }

    /// A Room renamed or removed in Homeswift is renamed or removed in Apple Home, by its id.
    @Test func roomsRenamedAndRemovedHereReachAppleHome() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-kitchen", "Kitchen")], placements: ["Devices:lamp": "hk-kitchen"])
        await environment.catalog.followHome()
        _ = try await environment.catalog.updateLayout(["renameRoom": ["from": "Kitchen", "to": "Cuisine"]], by: "test")
        #expect(environment.homeLink.applied.last == .renameRoom(id: "hk-kitchen", name: "Cuisine"))
        #expect(environment.homeLink.home.rooms == [.init(id: "hk-kitchen", name: "Cuisine")])
        _ = try await environment.catalog.updateLayout(["removeRooms": ["Cuisine"]], by: "test")
        #expect(environment.homeLink.applied.last == .deleteRoom(id: "hk-kitchen"))
        #expect(environment.homeLink.home.rooms.isEmpty)
    }

    /// While the link is down, changes wait as Pending Changes, in order, and reach Apple Home when it is back up.
    @Test func changesMadeWhileTheLinkIsDownWait() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon")], placements: ["Devices:lamp": "hk-salon"])
        await environment.catalog.followHome()
        environment.homeLink.set { $0.state = .down("Wingman is asleep") }
        await environment.catalog.followHome()
        _ = try await move(environment, to: "Garage")
        #expect(lampRoom(environment) == "Garage")
        #expect(environment.catalog.home.homeLink.value.pending == [.createRoom(name: "Garage"), .moveAccessory(accessory: "Devices:lamp", room: "Garage")])
        #expect(environment.homeLink.applied.isEmpty)
        let down = await environment.catalog.homeLinkJSON()
        #expect(down["state"] == "down" && down["pending"] == 2)

        environment.homeLink.set { $0.state = .up }
        await environment.catalog.followHome()
        #expect(environment.catalog.home.homeLink.value.pending.isEmpty)
        let garage = try #require(environment.homeLink.home.rooms.first { $0.name == "Garage" }?.id)
        #expect(environment.homeLink.home.placements["Devices:lamp"] == .some(garage))
        #expect(lampRoom(environment) == "Garage")
    }

    /// Up but not allowed to edit, a change here is refused at once, saying what to turn on; Apple Home's still come.
    @Test func aLinkThatMayNotEditRefuses() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon"), ("hk-bed", "Bedroom")], placements: ["Devices:lamp": "hk-salon"])
        await environment.catalog.followHome()
        environment.homeLink.set { $0.state = .readOnly("turn on Let bridges edit rooms") }
        await environment.catalog.followHome()
        let error = await #expect(throws: CatalogError.self) { try await move(environment, to: "Bedroom") }
        #expect(error?.message.contains("turn on Let bridges edit rooms") == true)
        await #expect(throws: CatalogError.self) { try await environment.catalog.updateLayout(["renameRoom": ["from": "Salon", "to": "Séjour"]], by: "test") }
        #expect(lampRoom(environment) == "Salon")

        environment.homeLink.set { $0.home.placements["Devices:lamp"] = .some("hk-bed") }
        await environment.catalog.followHome()
        #expect(lampRoom(environment) == "Bedroom")
    }

    /// A step of following Apple Home that fails (a Room renamed there to a name the bridge's own new Room has) is
    /// logged, and the rest still follows: an accessory moved there moves here.
    @Test func oneFailedStepLeavesTheRestFollowed() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-kitchen", "Kitchen"), ("hk-bed", "Bedroom")], placements: ["Devices:lamp": "hk-kitchen"])
        await environment.catalog.followHome()
        environment.homeLink.set { $0.state = .down("asleep") }
        await environment.catalog.followHome()
        _ = try await environment.catalog.updateLayout(["rooms": ["Kitchen", "Bedroom", "Cuisine"]], by: "test")
        environment.homeLink.set { state in
            state.state = .readOnly("edits are off")
            state.home.rooms[0].name = "Cuisine"
            state.home.placements["Devices:lamp"] = .some("hk-bed")
        }
        await environment.catalog.followHome()
        #expect(lampRoom(environment) == "Bedroom")
    }

    /// A change Apple Home refuses is said in the answer and kept for the pages; Apple Home's version stays.
    @Test func aRefusedChangeIsSaid() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon")], placements: ["Devices:lamp": "hk-salon"])
        await environment.catalog.followHome()
        let answer = try await move(environment, to: "Attic")
        #expect(answer["appleHomeRefused"]?[0]?["reason"] == "that name is taken")
        #expect(await environment.catalog.homeLinkJSON()["refused"]?.arrayValue?.isEmpty == false)
        await environment.catalog.followHome()
        #expect(lampRoom(environment) == "Salon")
    }

    /// Zones are kept as Rooms are: made here, they are made in Apple Home with their Rooms; made there, they are here.
    @Test func zonesAreKeptBothWays() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(rooms: [("hk-salon", "Salon"), ("hk-bed", "Bedroom")], placements: [:])
        await environment.catalog.followHome()
        let created = try await environment.catalog.updateZones(["create": ["name": "Étage", "rooms": ["Bedroom"]]], by: "test")
        let zone = try #require(environment.homeLink.home.zones.first)
        #expect(zone.name == "Étage" && zone.rooms == ["hk-bed"])
        #expect(created["zones"]?[0]?["linked"] == true)

        environment.homeLink.set { $0.home.zones.append(.init(id: "hk-zone-bas", name: "Rez-de-chaussée", rooms: ["hk-salon"])) }
        await environment.catalog.followHome()
        #expect(environment.catalog.zonesJSON()["zones"]?.arrayValue?.map { $0["name"] } == ["Étage", "Rez-de-chaussée"])
        #expect(environment.catalog.located(matching: .init(zone: "rez-de-chaussee")).isEmpty)
        _ = try await move(environment, to: "Salon")
        #expect(environment.catalog.located(matching: .init(zone: "rez-de-chaussee")).map(\.accessory.id) == ["Devices:lamp"])

        // A Room renamed here keeps its place in its zones.
        _ = try await environment.catalog.updateLayout(["renameRoom": ["from": "Bedroom", "to": "Chambre"]], by: "test")
        #expect(environment.catalog.zones(ofRoom: "Chambre") == ["Étage"])
    }

    /// Groups follow Apple Home's rules: accessories of one kind, each doing one thing; made here, they are made there.
    @Test func groupsFollowAppleHomesRules() async throws {
        let environment = try await environment(bulbs: 2)
        defer { Task { await environment.stop() } }
        environment.homeLink.turnOn(placements: ["Devices:bulb1": nil, "Devices:bulb2": nil, "Devices:lamp": nil, "Devices:lock": nil])
        await environment.catalog.followHome()
        _ = try await environment.catalog.updateWall(["groups": [["name": "Bulbs", "members": ["Devices:bulb1", "Devices:bulb2"]]]])
        #expect(environment.homeLink.home.groups.map(\.members) == [["Devices:bulb1", "Devices:bulb2"]])
        #expect(environment.catalog.groupProblem(members: ["Devices:lamp", "Devices:lock"]) != nil)
        // The lock does two things (its mechanism and its trigger).
        #expect(environment.catalog.groupProblem(members: ["Devices:lock", "Devices:lamp"])?.contains("more than one thing") == true)

        environment.homeLink.set { $0.home.groups[0].name = "Lampes" }
        await environment.catalog.followHome()
        #expect(environment.catalog.wallGroups.map(\.name) == ["Lampes"])
    }

    /// Groups older versions kept on the wall (`ui-layout.json`) move to `home.json`, once; the wall keeps the rest.
    @Test func groupsMoveFromTheWallToTheHomeFile() async throws {
        let environment = try await environment(bulbs: 2)
        defer { Task { await environment.stop() } }
        let group: JSONValue = ["id": "group:old", "name": "Bulbs", "members": ["Devices:bulb1", "Devices:bulb2"]]
        _ = try environment.catalog.home.wall.save(["grouping": "room", "groups": [group]])
        #expect(environment.catalog.wallGroups.map(\.id) == ["group:old"])
        #expect(environment.catalog.home.wall.load()["groups"] == nil)
        #expect(environment.catalog.home.wall.load()["grouping"] == "room")
        #expect(environment.catalog.home.homeLink.value.groups.map(\.name) == ["Bulbs"])
        #expect(environment.catalog.wallLayout()["groups"]?[0]?["id"] == "group:old")
    }

    /// A separated Function starts in its device's Room, until it is given one of its own.
    @Test func aSeparatedFunctionStartsInItsDevicesRoom() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        _ = try await move(environment, "Devices:lock", to: "Hall")
        _ = try await environment.catalog.updateAccessorySettings([("Devices:lock", ["separateFunctions": true])], who: "test")
        let part = try #require(environment.catalog.located().first { $0.isSeparatedFunction })
        #expect(part.device.id == "Devices:lock")
        #expect(part.room == "Hall")
        _ = try await move(environment, part.accessory.id, to: "Office")
        #expect(environment.catalog.find(id: part.accessory.id)?.room == "Office")
        #expect(environment.catalog.find(id: "Devices:lock")?.room == "Hall")
    }

    /// A Room renamed here is renamed on the other hubs too (Philips Hue, DIRIGERA, eWeLink), by name, case and accents
    /// aside; a hub that refuses says so, and the Room is renamed all the same.
    @Test func otherHubsFollowRenames() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        _ = try await environment.catalog.updateLayout(["rooms": ["sejour", "Kitchen"]], by: "test")
        let renamed = try await environment.catalog.updateLayout(["renameRoom": ["from": "sejour", "to": "Living room"]], by: "test")
        #expect(renamed["hubRooms"] == [["hub": "Devices:Devices", "name": "Devices", "room": "r1", "from": "Séjour", "to": "Living room", "renamed": true]])
        let refused = try await environment.catalog.updateLayout(["renameRoom": ["from": "Kitchen", "to": "Attic"]], by: "test")
        #expect(refused["hubRooms"]?[0]?["error"] == "that name is taken")
        #expect(environment.catalog.home.layout.value.rooms == ["Living room", "Attic"])
    }
}
