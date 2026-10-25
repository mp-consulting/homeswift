import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// An accessory mirrored from Apple Home (Wingman's) is the catalog's like any other: listed with where it comes from
/// and the room Apple Home gives it, in the layout's rooms, and lit by a mood of that room.
@Suite struct MirroredAccessoryCatalogTests {
    static let config = """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:58", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "mirroredBulb": true },
            { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """

    @Test func aMirroredAccessoryIsListedInItsSuggestedRoomAndAMoodLightsIt() async throws {
        let environment = try MCPTestEnvironment(config: Self.config)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let located = try #require(environment.catalog.find(id: "Devices:mirrored"))
        let json = HomeswiftCatalog.accessoryJSON(located, detailed: false)
        #expect(json["mirroredFrom"] == "Apple Home")
        #expect(json["room"] == "Salon")
        #expect(json["unavailable"] == nil)
        // Apple Home's room is one of the layout's rooms.
        let rooms = environment.catalog.layoutJSON()["rooms"]?.arrayValue ?? []
        #expect(rooms.contains { $0["name"] == "Salon" && $0["accessories"]?.arrayValue?.count == 1 })

        let result = try await client.tool("start_mood", ["mood": "relax", "room": "salon"])
        #expect(result["structuredContent"]?["ok"] == true)
        #expect(environment.written.contains { $0.0 == "mirrored.brightness" })

        located.accessory.isUnavailable = true
        #expect(HomeswiftCatalog.accessoryJSON(located, detailed: false)["unavailable"] == true)
    }

    static func config(secondRoom: String) -> String {
        config.replacingOccurrences(of: #""mirroredBulb": true"#, with: #""mirroredBulb": true, "secondMirroredRoom": "\#(secondRoom)""#)
    }

    func rooms(_ layout: JSONValue) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: (layout["rooms"]?.arrayValue ?? []).map { room in
            (room["name"]?.stringValue ?? "", (room["accessories"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        })
    }

    /// Apple Home rooms that differ only in case are one room, listed once with both accessories.
    @Test func suggestedRoomsDifferingInCaseAreOne() async throws {
        let environment = try MCPTestEnvironment(config: Self.config(secondRoom: "salon"))
        try await environment.start()
        defer { Task { await environment.stop() } }
        let rooms = rooms(environment.catalog.layoutJSON())
        #expect(rooms.keys.filter { $0.lowercased() == "salon" }.count == 1)
        #expect(Set(rooms["Salon"] ?? []) == ["Devices:mirrored", "Devices:mirrored2"])
    }

    /// A room only Apple Home names can be renamed, and removed: its accessories then have no room, not the suggestion.
    @Test func aSuggestedRoomCanBeRenamedAndRemoved() async throws {
        let environment = try MCPTestEnvironment(config: Self.config(secondRoom: "Kitchen"))
        try await environment.start()
        defer { Task { await environment.stop() } }
        let renamed = rooms(try environment.catalog.updateLayout(["renameRoom": ["from": "salon", "to": "Lounge"]]))
        #expect(renamed["Lounge"] == ["Devices:mirrored"])
        #expect(renamed["Salon"] == nil)
        let removed = try environment.catalog.updateLayout(["removeRooms": ["Lounge", "Kitchen"]])
        #expect(rooms(removed)["Lounge"] == nil && rooms(removed)["Kitchen"] == nil && rooms(removed)["Salon"] == nil)
        let unassigned = (removed["unassigned"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        #expect(unassigned.contains("Devices:mirrored") && unassigned.contains("Devices:mirrored2"))
    }
}
