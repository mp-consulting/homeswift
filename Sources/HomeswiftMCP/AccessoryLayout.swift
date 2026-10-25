import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

/// Glass UI's accessory layout, for the whole bridge rather than per user: rooms in their order, and per accessory
/// its room, whether the web UI hides it, a display name of the web UI's own and whether it is a Quick Control.
/// HomeKit never sees any of it (the Home app keeps its own rooms); `list_accessories` filters by these rooms.
/// Kept in `accessory-layout.json` next to config.json.
public struct AccessoryLayout: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var room: String?
        public var hidden: Bool?
        /// The name the web UI shows instead of the accessory's own (an Assistant's rename, say).
        public var name: String?
        /// On the Quick Controls.
        public var favourite: Bool?

        public init(room: String? = nil, hidden: Bool? = nil, name: String? = nil, favourite: Bool? = nil) {
            self.room = room
            self.hidden = hidden
            self.name = name
            self.favourite = favourite
        }

        var isEmpty: Bool { room == nil && hidden != true && name == nil && favourite != true }
    }

    /// The rooms in the order the pages show them, empty ones included.
    public var rooms: [String] = []
    public var accessories: [String: Entry] = [:]

    public init(rooms: [String] = [], accessories: [String: Entry] = [:]) {
        self.rooms = rooms
        self.accessories = accessories
    }

    /// The room of this name, as it is spelled in the layout, case aside.
    public func room(named name: String) -> String? {
        rooms.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static let maxRooms = 100
    static let maxName = 64
}

extension HomeswiftCatalog {
    /// `{"rooms": [{name, accessories}], "unassigned": [...]}`: every running accessory under its room, with its
    /// display name, hidden and favourite flags.
    public func layoutJSON() -> JSONValue {
        let all = located()
        func entry(_ located: Located) -> JSONValue {
            var object: [String: JSONValue] = ["id": .string(located.accessory.id), "name": .string(located.accessory.name)]
            if let name = located.layout?.name { object["displayName"] = .string(name) }
            if located.layout?.hidden == true { object["hidden"] = true }
            if located.layout?.favourite == true { object["favourite"] = true }
            return .object(object)
        }
        let rooms: [JSONValue] = allRoomNames(all).map { room in
            ["name": .string(room), "accessories": .array(all.filter { $0.room == room }.map(entry))]
        }
        return ["rooms": .array(rooms), "unassigned": .array(all.filter { $0.room == nil }.map(entry))]
    }

    /// Changes the layout. `body` may hold `accessories`, an object by accessory id (or a list of objects with
    /// `id`) of `room`, `hidden`, `name` and `favourite`, where null clears one; `rooms`, the rooms in order (new
    /// names are added, those left out keep their place after them); `renameRoom` `{from, to}`; `removeRooms`, whose
    /// accessories have no room afterwards. A room an accessory moves to is added. Answers `layoutJSON()`.
    public func updateLayout(_ body: JSONValue) throws -> JSONValue {
        func cleanName(_ value: String, _ what: String) throws -> String {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= AccessoryLayout.maxName else { throw CatalogError("\(what) must be 1 to \(AccessoryLayout.maxName) characters") }
            return name
        }
        var changes: [(String, [String: JSONValue])] = []
        if let byID = body["accessories"]?.objectValue {
            changes = try byID.sorted { $0.key < $1.key }.map { id, value in
                guard let object = value.objectValue else { throw CatalogError("the change for \(id) must be an object") }
                return (id, object)
            }
        } else if let list = body["accessories"]?.arrayValue {
            changes = try list.map { value in
                guard let object = value.objectValue, let id = object["id"]?.stringValue else { throw CatalogError("each accessory change needs its id") }
                return (id, object)
            }
        }
        let known = Set(located().map(\.accessory.id))
        try home.layout.update { layout in
            if let order = body["rooms"]?.arrayValue {
                let names = try order.map { value -> String in
                    guard let text = value.stringValue else { throw CatalogError("rooms must be names") }
                    return try cleanName(text, "A room's name")
                }
                var seen: Set<String> = []
                let ordered = names.compactMap { name -> String? in
                    let spelled = layout.room(named: name) ?? name
                    return seen.insert(spelled.lowercased()).inserted ? spelled : nil
                }
                layout.rooms = ordered + layout.rooms.filter { !seen.contains($0.lowercased()) }
            }
            if let rename = body["renameRoom"], !rename.isNull {
                guard let from = rename["from"]?.stringValue, let current = layout.room(named: from) else { throw CatalogError("No room \(rename["from"]?.stringValue ?? "")") }
                let to = try cleanName(rename["to"]?.stringValue ?? "", "A room's name")
                if let other = layout.room(named: to), other != current { throw CatalogError("There is already a room \(other)") }
                layout.rooms = layout.rooms.map { $0 == current ? to : $0 }
                for (id, entry) in layout.accessories where entry.room == current { layout.accessories[id]?.room = to }
            }
            for name in body["removeRooms"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard let current = layout.room(named: name) else { continue }
                layout.rooms.removeAll { $0 == current }
                for (id, entry) in layout.accessories where entry.room == current { layout.accessories[id]?.room = nil }
            }
            for (id, change) in changes {
                guard known.contains(id) || layout.accessories[id] != nil else { throw CatalogError("No accessory with id \(id)") }
                var entry = layout.accessories[id] ?? AccessoryLayout.Entry()
                if let room = change["room"] {
                    if let name = room.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        let clean = try cleanName(name, "A room's name")
                        if let existing = layout.room(named: clean) {
                            entry.room = existing
                        } else {
                            entry.room = clean
                            layout.rooms.append(clean)
                        }
                    } else {
                        entry.room = nil
                    }
                }
                if let hidden = change["hidden"] { entry.hidden = hidden.boolValue == true ? true : nil }
                if let favourite = change["favourite"] { entry.favourite = favourite.boolValue == true ? true : nil }
                if let name = change["name"] {
                    let text = name.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    entry.name = try text.isEmpty ? nil : cleanName(text, "A display name")
                }
                layout.accessories[id] = entry.isEmpty ? nil : entry
            }
            guard layout.rooms.count <= AccessoryLayout.maxRooms else { throw CatalogError("At most \(AccessoryLayout.maxRooms) rooms") }
        }
        return layoutJSON()
    }

    /// The Assistant's rooms and names for the running accessories (`AssistantService.suggestOrganization`):
    /// `rooms` (name and the ids of known accessories), `renames` (id, current name, suggested name, reason),
    /// `orphans` (id, name, reason). Nothing changes until the page applies what the user kept.
    public func suggestRooms(language: String? = nil, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> JSONValue {
        guard let assistant = host.assistant?.speaking(language) else { throw CatalogError("the Assistant is off: add a HomeswiftAiKit block") }
        let all = located()
        let byID = Dictionary(all.map { ($0.accessory.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accessories: [JSONValue] = all.map { located in
            let accessory = located.accessory
            var object: [String: JSONValue] = [
                "id": .string(accessory.id), "name": .string(located.layout?.name ?? accessory.name), "category": .string("\(accessory.category)"),
                "services": .array(accessory.services.filter { $0.type.uuid != ServiceType.accessoryInformation.uuid && !Self.isInternal($0) }.map { .string($0.type.name) }),
            ]
            if let maker = accessory.information[.manufacturer]?.value.stringValue { object["manufacturer"] = .string(maker) }
            if let model = accessory.information[.model]?.value.stringValue { object["model"] = .string(model) }
            if let platform = located.platform?.name { object["plugin"] = .string(platform) }
            if let room = located.room { object["room"] = .string(room) }
            return .object(object)
        }
        let rooms = home.layout.value.rooms
        let suggestion = try await assistant.suggestOrganization(accessories: accessories, rooms: rooms.isEmpty ? nil : .array(rooms.map(JSONValue.string)), onProgress: onProgress)
        return [
            "rooms": .array(suggestion.rooms.map { room in
                ["name": .string(room.name), "accessories": .array(room.accessories.filter { byID[$0] != nil }.map(JSONValue.string))]
            }),
            "renames": .array(suggestion.renames.compactMap { rename in
                guard let found = byID[rename.uniqueId] else { return nil }
                var object: [String: JSONValue] = ["id": .string(rename.uniqueId), "current": .string(found.layout?.name ?? found.accessory.name), "name": .string(rename.name)]
                if let reason = rename.reason { object["reason"] = .string(reason) }
                return .object(object)
            }),
            "orphans": .array(suggestion.orphans.compactMap { orphan in
                guard let found = byID[orphan.uniqueId] else { return nil }
                return ["id": .string(orphan.uniqueId), "name": .string(found.accessory.name), "reason": .string(orphan.reason)]
            }),
            "model": .string(assistant.model),
        ]
    }

    /// The user's rooms, then those only a mirrored controller names (Apple Home's, through Wingman), by name.
    func allRoomNames(_ all: [Located]? = nil) -> [String] {
        let layout = home.layout.value.rooms
        let suggested = Set((all ?? located()).compactMap { $0.layout?.room == nil ? $0.accessory.suggestedRoom : nil })
            .filter { name in !layout.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }.sorted()
        return layout + suggested
    }

    /// An error naming the rooms when a filter's room is not one of them (upstream's answer), else nil.
    func unknownRoom(_ filter: AccessoryFilter) -> String? {
        guard let room = filter.room else { return nil }
        // The user's rooms, and those a mirrored controller names (Apple Home's, through Wingman).
        let rooms = allRoomNames()
        guard !rooms.contains(where: { $0.caseInsensitiveCompare(room) == .orderedSame }) else { return nil }
        return "Room not found: \"\(room)\". Rooms: \(rooms.isEmpty ? "none yet (set them with set_accessory_layout or on the web UI's Accessories page)" : rooms.joined(separator: ", "))."
    }

    var layoutTools: [MCPTool] {
        let catalog = self
        let change: JSONValue = [
            "type": "object", "required": ["id"], "additionalProperties": false,
            "properties": [
                "id": ["type": "string", "description": "The accessory id, from list_accessories"],
                "room": ["type": ["string", "null"], "maxLength": 64, "description": "The room; null takes it out of its room. A new name adds the room"],
                "hidden": ["type": "boolean", "description": "Hide it on the web UI's pages"],
                "name": ["type": ["string", "null"], "maxLength": 64, "description": "A display name for the web UI (HomeKit keeps the accessory's own); null clears it"],
                "favourite": ["type": "boolean", "description": "Show it in the web UI's Quick Controls"],
            ],
        ]
        return [
            MCPTool(
                name: "get_accessory_layout", title: "Get room layout",
                description: "The rooms of the web UI's accessory layout, each with its accessories (id, name, displayName, hidden, favourite), and the accessories in no room. "
                    + "These are Homeswift's rooms, not the Home app's: list_accessories and set_accessories filter by them (room).",
                outputSchema: Output.object(["rooms": ["type": "array"], "unassigned": ["type": "array"]], required: ["rooms", "unassigned"]),
                scope: .read, idempotent: true
            ) { _ in .json(catalog.layoutJSON()) },
            MCPTool(
                name: "set_accessory_layout", title: "Set rooms and hidden accessories",
                description: "Changes the web UI's accessory layout: put accessories in rooms (a new room name adds the room), hide them, give them a display name or make them Quick Controls; "
                    + "order the rooms (rooms), rename one (renameRoom) or remove some (removeRooms; their accessories are left without a room). HomeKit and the Home app are not changed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "accessories": ["type": "array", "maxItems": 500, "items": change],
                        "rooms": ["type": "array", "maxItems": 100, "items": ["type": "string", "maxLength": 64], "description": "Room names in the order to show them"],
                        "renameRoom": ["type": "object", "required": ["from", "to"], "properties": ["from": ["type": "string"], "to": ["type": "string", "maxLength": 64]]],
                        "removeRooms": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
                outputSchema: Output.object(["rooms": ["type": "array"], "unassigned": ["type": "array"]], required: ["rooms", "unassigned"]),
                scope: .admin, idempotent: true
            ) { call in .json(try catalog.updateLayout(call.arguments)) },
        ]
    }
}
