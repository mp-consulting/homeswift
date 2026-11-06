import Foundation
import Homeswift
import HomeswiftPlugin

// The Zones (GLOSSARY.md, "Zone"): the Home's sets of Rooms, such as Upstairs, kept like the Rooms (`home.json`'s
// `zones`, linked to Apple Home's through the Home Link). A Room may be in several. The tools and the pages' routes for
// them, and for the Home Link itself.

extension HomeswiftCatalog {
    static let maxZones = 50

    /// `{zones: [{id, name, rooms, linked}]}`, in their order.
    public func zonesJSON() -> JSONValue {
        ["zones": .array(home.homeLink.value.zones.map { zone in
            ["id": .string(zone.id), "name": .string(zone.name), "rooms": .array(zone.rooms.map(JSONValue.string)), "linked": .bool(zone.homeKitID != nil)]
        })]
    }

    /// The Zones a Room is in, by name.
    func zones(ofRoom room: String) -> [String] {
        home.homeLink.value.zones.filter { $0.rooms.contains { Self.sameRoomName($0, room) } }.map(\.name)
    }

    /// Changes the Zones. `body` holds one of: `create` `{name, rooms?}`; `zone` (an id) with `name`, `rooms` (all of its
    /// Rooms, by name) or `delete: true`; `order`, the zones' ids in the order to show them. Every change is in Apple Home
    /// too, through the Home Link, as the Rooms'. Answers `zonesJSON()`, with `appleHomeRefused` when it refused.
    public func updateZones(_ body: JSONValue, by: String) async throws -> JSONValue {
        if let refusal = await homeLinkRefusal(), body["order"] == nil || body.objectValue?.count != 1 { throw CatalogError(refusal) }
        let rooms = home.layout.value.rooms
        func cleanName(_ value: JSONValue?) throws -> String {
            let name = (value?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= AccessoryLayout.maxName else { throw CatalogError("A zone's name must be 1 to \(AccessoryLayout.maxName) characters") }
            return name
        }
        func roomNames(_ value: JSONValue?) throws -> [String] {
            guard let value, !value.isNull else { return [] }
            guard let list = value.arrayValue else { throw CatalogError("rooms must be a list of room names") }
            var seen: Set<String> = []
            return try list.compactMap { item in
                guard let text = item.stringValue, let room = rooms.first(where: { Self.sameRoomName($0, text) }) else {
                    throw CatalogError("No room \(item.stringValue ?? "\(item)")")
                }
                return seen.insert(room).inserted ? room : nil
            }
        }
        var changes: [HomeLinkFile.PendingChange] = []
        try home.homeLink.update { file in
            func taken(_ name: String, except id: String? = nil) -> Bool {
                file.zones.contains { $0.id != id && Self.sameRoomName($0.name, name) }
            }
            if let create = body["create"], !create.isNull {
                let name = try cleanName(create["name"])
                guard !taken(name) else { throw CatalogError("There is already a zone \(name)") }
                guard file.zones.count < Self.maxZones else { throw CatalogError("At most \(Self.maxZones) zones") }
                let zone = HomeLinkFile.Zone(id: "zone:\(UUID().uuidString.lowercased())", homeKitID: nil, name: name, rooms: try roomNames(create["rooms"]))
                file.zones.append(zone)
                changes.append(.init(.createZone, zone: zone.id))
            }
            if let id = body["zone"]?.stringValue {
                guard let index = file.zones.firstIndex(where: { $0.id == id }) else { throw CatalogError("No zone \(id)", notFound: true) }
                let zone = file.zones[index]
                if body["delete"]?.boolValue == true {
                    file.zones.remove(at: index)
                    if zone.homeKitID != nil { changes.append(.init(.deleteZone, homeKitID: zone.homeKitID)) }
                } else {
                    if body["name"] != nil {
                        let name = try cleanName(body["name"])
                        guard !taken(name, except: id) else { throw CatalogError("There is already a zone \(name)") }
                        if name != zone.name {
                            file.zones[index].name = name
                            changes.append(.init(.renameZone, name: name, zone: id))
                        }
                    }
                    if body["rooms"] != nil {
                        let next = try roomNames(body["rooms"])
                        let add = next.filter { !zone.rooms.contains($0) }, remove = zone.rooms.filter { !next.contains($0) }
                        file.zones[index].rooms = next
                        if !add.isEmpty || !remove.isEmpty { changes.append(.init(.setZoneRooms, zone: id, add: add, remove: remove)) }
                    }
                }
            }
            if let order = body["order"]?.arrayValue?.compactMap(\.stringValue) {
                let byID = Dictionary(file.zones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let ordered = order.compactMap { byID[$0] }
                file.zones = ordered + file.zones.filter { !order.contains($0.id) }
            }
        }
        // Not linked yet: the zones it created are the first link's to make in Apple Home.
        if home.homeLink.value.homeID == nil { changes = [] }
        let refused = await homeLinkRecord(changes)
        var answer = zonesJSON().objectValue ?? [:]
        if !refused.isEmpty { answer["appleHomeRefused"] = .array(refused) }
        logger.info("Zones changed", metadata: ["by": "\(by)"])
        home.layoutChanged()
        return .object(answer)
    }

    /// The Zones follow a Room renamed or removed (`applyLayout`). The links stay: the change made in Apple Home finds
    /// the Room's id by its old name (`push`), and one Apple Home made updates them itself (`adopt`).
    func roomsChangedInZones(renamed: (from: String, to: String)?, removed: [String]) {
        guard renamed != nil || !removed.isEmpty, !home.homeLink.value.zones.isEmpty else { return }
        try? home.homeLink.update { file in
            for index in file.zones.indices {
                file.zones[index].rooms = file.zones[index].rooms.compactMap { room in
                    if let renamed, Self.sameRoomName(room, renamed.from) { return renamed.to }
                    return removed.contains { Self.sameRoomName($0, room) } ? nil : room
                }
            }
        }
    }

    var homeLinkTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_home_link", title: "Get the Home Link",
                description: "Whether the bridge's Rooms, Zones and Groups are Apple Home's: the Home Link (through Homeswift Wingman) is up, readOnly (Apple Home does not let the "
                    + "bridge edit; reason says what to turn on), down (changes made meanwhile wait as pending) or none (no Wingman). linked says whether the bridge is linked to "
                    + "its home; comparison, when present, is what its first link would change, waiting for confirm_home_link; refused lists changes Apple Home refused.",
                outputSchema: Output.object(["state": ["type": "string"], "linked": ["type": "boolean"], "pending": ["type": "number"]], required: ["state", "linked"]),
                scope: .read, idempotent: true
            ) { _ in .json(await catalog.homeLinkJSON()) },
            MCPTool(
                name: "confirm_home_link", title: "Link the bridge to Apple Home",
                description: "Confirms the bridge's first link to its home in Apple Home, as get_home_link's comparison says: Rooms only the bridge has are created in Apple Home, "
                    + "Apple Home's are taken, accessories go where Apple Home has them (No Room there keeps the bridge's Room), and groups Apple Home cannot have are ungrouped.",
                outputSchema: Output.object(["state": ["type": "string"], "linked": ["type": "boolean"]], required: ["state", "linked"]),
                scope: .admin, destructive: true
            ) { call in .json(try await catalog.confirmHomeLink(by: "MCP \(call.session.clientInfo?.name ?? "client")")) },
            MCPTool(
                name: "get_zones", title: "Get zones",
                description: "The Zones: Apple Home's sets of Rooms, such as Upstairs, each with its Rooms. A Room can be in several. list_accessories and set_accessories filter by them (zone).",
                outputSchema: Output.object(["zones": ["type": "array"]], required: ["zones"]),
                scope: .read, idempotent: true
            ) { _ in .json(catalog.zonesJSON()) },
            MCPTool(
                name: "set_zones", title: "Change zones",
                description: "Creates a zone (create: {name, rooms}), changes one (zone: its id, with name, rooms: all of its Rooms by name, or delete: true) or orders them (order: "
                    + "the ids). Made in Apple Home too through the Home Link, as Rooms are; appleHomeRefused lists what it refused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "create": ["type": "object", "required": ["name"], "properties": ["name": ["type": "string", "maxLength": 64], "rooms": ["type": "array", "items": ["type": "string"]]]],
                        "zone": ["type": "string", "description": "The id of the zone to change, from get_zones"],
                        "name": ["type": "string", "maxLength": 64],
                        "rooms": ["type": "array", "items": ["type": "string"], "description": "Every Room of the zone, by name"],
                        "delete": ["type": "boolean"],
                        "order": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
                outputSchema: Output.object(["zones": ["type": "array"], "appleHomeRefused": ["type": "array"]], required: ["zones"]),
                scope: .admin, idempotent: false
            ) { call in .json(try await catalog.updateZones(call.arguments, by: "MCP \(call.session.clientInfo?.name ?? "client")")) },
        ]
    }
}
