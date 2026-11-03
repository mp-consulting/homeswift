import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

/// Glass UI's accessory layout, for the whole bridge rather than per user, now the Arrangement only
/// (docs/adr/0003-room-and-visibility-in-accessory-settings.md): the rooms in their order, and per accessory whether it is a
/// Quick Control. An accessory's room, Hidden and Name are Accessory Settings (`updateAccessorySettings`); the room, hidden
/// flag and display name an accessory has here are what older versions wrote, read where its settings have none and
/// moved into them on its next settings write, never written again. `syncRoomNames` is Room Sync's old place, read when
/// the bridge block has no `roomSync`. Kept in `accessory-layout.json` next to config.json.
public struct AccessoryLayout: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Legacy: the room; empty for none even when the accessory's controller suggests one (`Accessory.suggestedRoom`).
        public var room: String?
        /// Legacy: Hidden.
        public var hidden: Bool?
        /// Legacy: the name the web UI showed instead of the accessory's own.
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
    /// Legacy: Room Sync, now the bridge block's `roomSync` (`HomeswiftCatalog.roomSync`), cleared by its next write.
    public var syncRoomNames: Bool?

    public init(rooms: [String] = [], accessories: [String: Entry] = [:], syncRoomNames: Bool? = nil) {
        self.rooms = rooms
        self.accessories = accessories
        self.syncRoomNames = syncRoomNames
    }

    /// The room of this name, as it is spelled in the layout, case aside.
    public func room(named name: String) -> String? {
        rooms.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static let maxRooms = 100
    static let maxName = 64
}

extension HomeswiftCatalog {
    /// `{"rooms": [{name, accessories}], "unassigned": [...], "syncRoomNames"}`: every running accessory under its
    /// room, with its display name, hidden and favourite flags, and whether renamed rooms are renamed on the hubs.
    public func layoutJSON() -> JSONValue {
        let all = located()
        func entry(_ located: Located) -> JSONValue {
            var object: [String: JSONValue] = ["id": .string(located.accessory.id), "name": .string(located.accessory.name)]
            if let name = located.layout?.name { object["displayName"] = .string(name) }
            if located.layout?.hidden == true { object["hidden"] = true }
            if located.layout?.favourite == true { object["favourite"] = true }
            return .object(object)
        }
        let byRoom = Dictionary(grouping: all) { $0.room?.lowercased() ?? "" }
        let rooms: [JSONValue] = allRoomNames(all).map { room in
            ["name": .string(room), "accessories": .array((byRoom[room.lowercased()] ?? []).map(entry))]
        }
        return ["rooms": .array(rooms), "unassigned": .array((byRoom[""] ?? []).map(entry)), "syncRoomNames": .bool(roomSync)]
    }

    /// Changes the Arrangement. `body` may hold `accessories`, an object by accessory id (or a list of objects with `id`)
    /// of `favourite`, where null clears it; `rooms`, the rooms in order (new names are added, those left out keep their
    /// place after them); `renameRoom` `{from, to}`, which every accessory's `room` setting in that room follows;
    /// `removeRooms`, whose accessories have no room afterwards; `syncRoomNames`, Room Sync, written to the bridge block
    /// (`bridge.roomSync`). A room only a mirrored controller names (Apple Home's) becomes the layout's own when it is
    /// renamed or removed. With Room Sync on, a room renamed is renamed on the plugins' hubs too (`renameHubRooms`, what
    /// each did in the answer's `hubRooms`). An accessory's room, Hidden and Name are Accessory Settings
    /// (`updateAccessorySettings`). Answers `layoutJSON()`.
    public func updateLayout(_ body: JSONValue, by: String) async throws -> JSONValue {
        let change = try await applyLayout(body)
        guard var answer = layoutJSON().objectValue else { return layoutJSON() }
        if roomSync, let renamed = change.renamed {
            answer["hubRooms"] = .array(await renameHubRooms(from: renamed.from, to: renamed.to, by: by))
        }
        return .object(answer)
    }

    /// What `applyLayout` changed that hubs may follow.
    private struct LayoutChange {
        var renamed: (from: String, to: String)?
    }

    /// Changes the layout as `updateLayout(_:by:)` says, then the Accessory Settings that name a room renamed or removed
    /// and Room Sync, in one write of config.json; answers the room renamed.
    private func applyLayout(_ body: JSONValue) async throws -> LayoutChange {
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
                return (id, object.filter { $0.key != "id" })
            }
        }
        for (id, change) in changes {
            let moved = change.keys.filter { $0 != "favourite" }.sorted()
            guard moved.isEmpty else {
                throw CatalogError("\(moved.joined(separator: ", ")) of \(id): an accessory's room, Hidden and Name are Accessory Settings, changed with update_settings (PATCH /api/settings/accessories/<id>)")
            }
        }
        let all = located()
        let known = Set(all.map(\.accessory.id))
        let suggested = Dictionary(all.compactMap { located in located.accessory.suggestedRoom.map { (located.accessory.id, $0) } }, uniquingKeysWith: { first, _ in first })
        // The accessories whose room is the suggested one: no room of their own, in their settings or the layout.
        let following = Set(all.filter { $0.layout?.room == nil && $0.accessory.suggestedRoom != nil }.map(\.accessory.id))
        if let sync = body["syncRoomNames"], !sync.isNull, sync.boolValue == nil { throw CatalogError("syncRoomNames must be true or false") }
        /// What the layout's change does to the rooms the settings name.
        var renamed: (from: String, to: String)?
        var removed: [String] = []
        /// Mirrored accessories that followed a suggested room the layout adopted, and the room they are in now ("" none).
        var adopted: [String: String] = [:]
        // Put back if the settings' write that follows fails, so the layout never names rooms the settings do not.
        let previous = home.layout.value
        try home.layout.update { layout in
            /// Gives the layout a room a mirrored controller names: the room, and its accessories that follow the suggestion.
            func adopt(_ name: String) -> String? {
                if let current = layout.room(named: name) { return current }
                // A room only accessories' settings name (a restored config.json): the layout takes it as they spell it.
                if let named = all.lazy.compactMap({ $0.layout?.room }).first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    layout.rooms.append(named)
                    return named
                }
                let followers = suggested.filter { id, room in room.caseInsensitiveCompare(name) == .orderedSame && following.contains(id) }
                guard let spelled = followers.values.first else { return nil }
                layout.rooms.append(spelled)
                for id in followers.keys { adopted[id] = spelled }
                return spelled
            }
            /// Out of its room: none, rather than the room its controller suggests.
            func noRoom(_ id: String) -> String? { suggested[id] == nil ? nil : "" }
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
                guard let from = rename["from"]?.stringValue, let current = adopt(from) else { throw CatalogError("No room \(rename["from"]?.stringValue ?? "")") }
                let to = try cleanName(rename["to"]?.stringValue ?? "", "A room's name")
                if let other = layout.room(named: to), other != current { throw CatalogError("There is already a room \(other)") }
                layout.rooms = layout.rooms.map { $0 == current ? to : $0 }
                // The legacy rooms follow too, as long as the layout has them.
                for (id, entry) in layout.accessories where entry.room == current { layout.accessories[id]?.room = to }
                for (id, room) in adopted where room == current { adopted[id] = to }
                if current != to { renamed = (current, to) }
            }
            if body["syncRoomNames"]?.boolValue != nil { layout.syncRoomNames = nil }
            for name in body["removeRooms"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard let current = adopt(name) else { continue }
                layout.rooms.removeAll { $0 == current }
                for (id, entry) in layout.accessories where entry.room == current { layout.accessories[id]?.room = noRoom(id) }
                for (id, room) in adopted where room == current { adopted[id] = "" }
                removed.append(current)
            }
            for (id, change) in changes {
                guard known.contains(id) || layout.accessories[id] != nil else { throw CatalogError("No accessory with id \(id)") }
                var entry = layout.accessories[id] ?? AccessoryLayout.Entry()
                if let favourite = change["favourite"] { entry.favourite = favourite.boolValue == true ? true : nil }
                layout.accessories[id] = entry.isEmpty ? nil : entry
            }
            guard layout.rooms.count <= AccessoryLayout.maxRooms else { throw CatalogError("At most \(AccessoryLayout.maxRooms) rooms") }
        }
        let sync = body["syncRoomNames"]?.boolValue
        guard renamed != nil || !removed.isEmpty || !adopted.isEmpty || sync != nil else {
            home.layoutChanged()
            return LayoutChange(renamed: renamed)
        }
        do {
            try await retryingWhenConfigChanges {
                try await writeLayoutRooms(renamed: renamed, removed: removed, adopted: adopted, sync: sync, suggested: suggested, all: all)
            }
        } catch {
            try? home.layout.update { $0 = previous }
            throw error
        }
        home.layoutChanged()
        return LayoutChange(renamed: renamed)
    }

    /// `applyLayout`'s write of config.json: the settings' rooms renamed or emptied (a room's name matched as the layout
    /// matches it, case aside), the adopted followers' rooms, Room Sync.
    private func writeLayoutRooms(
        renamed: (from: String, to: String)?, removed: [String], adopted: [String: String], sync: Bool?, suggested: [String: String], all: [Located]
    ) async throws {
        let same = { (a: String, b: String) in a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        if let sync { setRoomSync(sync, in: &root) }
        var platforms = root["platforms"]?.arrayValue ?? []
        for index in platforms.indices {
            guard var block = platforms[index].objectValue, let platform = block["platform"]?.stringValue else { continue }
            let name = block["name"]?.stringValue ?? platform
            var entries = block["_accessories"]?.objectValue ?? [:]
            var changed = false
            for (key, entry) in entries {
                guard var fields = entry.objectValue, let room = fields["room"]?.stringValue, !room.isEmpty else { continue }
                if let renamed, same(room, renamed.from) {
                    fields["room"] = .string(renamed.to)
                } else if removed.contains(where: { same($0, room) }) {
                    if suggested["\(platform):\(key)"] == nil { fields.removeValue(forKey: "room") } else { fields["room"] = "" }
                } else {
                    continue
                }
                // Removed, not set to nil: JSONValue takes the nil literal as JSON null.
                if fields.isEmpty { entries.removeValue(forKey: key) } else { entries[key] = .object(fields) }
                changed = true
            }
            for (id, room) in adopted {
                guard let located = all.first(where: { $0.accessory.id == id }), located.platform?.platform == platform, located.platform?.name == name else { continue }
                let key = AccessoryNaming.deviceID(of: id, platform: platform)
                var fields = entries[key]?.objectValue ?? [:]
                fields["room"] = .string(room)
                entries[key] = .object(fields)
                changed = true
            }
            guard changed else { continue }
            if entries.isEmpty { block.removeValue(forKey: "_accessories") } else { block["_accessories"] = .object(entries) }
            platforms[index] = .object(block)
        }
        root["platforms"] = .array(platforms)
        if JSONValue.object(root) != current { _ = try await applyConfig(.object(root), dryRun: false, current: current, expecting: current) }
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
                // A mirrored accessory is named where it comes from: its Name is read-only here.
                guard let found = byID[rename.uniqueId], found.accessory.mirroredFrom == nil else { return nil }
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

    /// The user's rooms, then those only a mirrored controller names (Apple Home's, through Wingman), by name, each once
    /// whatever its case.
    func allRoomNames(_ all: [Located]? = nil) -> [String] {
        let layout = home.layout.value.rooms
        var seen = Set(layout.map { $0.lowercased() })
        var suggested: [String] = []
        let located = all ?? located()
        // A room an accessory's settings name that the layout does not have (a restored config.json, a hand edit), then
        // the rooms mirrored controllers suggest.
        for name in located.compactMap({ $0.layout?.room.flatMap { $0.isEmpty ? nil : $0 } }).sorted() where seen.insert(name.lowercased()).inserted {
            suggested.append(name)
        }
        for name in located.compactMap({ $0.layout?.room == nil ? $0.accessory.suggestedRoom : nil }).sorted()
        where seen.insert(name.lowercased()).inserted {
            suggested.append(name)
        }
        return layout + suggested
    }

    /// An error naming the rooms when a filter's room is not one of them (upstream's answer), else nil.
    func unknownRoom(_ filter: AccessoryFilter) -> String? {
        guard let room = filter.room, home.layout.value.room(named: room) == nil else { return nil }
        // Not one of the user's rooms: one a mirrored controller names (Apple Home's, through Wingman)?
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
                "favourite": ["type": "boolean", "description": "Show it in the web UI's Quick Controls"],
            ],
        ]
        return [
            MCPTool(
                name: "get_accessory_layout", title: "Get room layout",
                description: "The rooms of the web UI's accessory layout, each with its accessories (id, name, displayName, hidden, favourite), and the accessories in no room. "
                    + "These are Homeswift's rooms, not the Home app's: list_accessories and set_accessories filter by them (room). "
                    + "syncRoomNames says whether Room Sync is on: rooms renamed here are renamed on the plugins' hubs too, and accessories moved move there.",
                outputSchema: Output.object(["rooms": ["type": "array"], "unassigned": ["type": "array"], "syncRoomNames": ["type": "boolean"], "hubRooms": ["type": "array"]], required: ["rooms", "unassigned"]),
                scope: .read, idempotent: true
            ) { _ in .json(catalog.layoutJSON()) },
            MCPTool(
                name: "set_accessory_layout", title: "Arrange rooms and Quick Controls",
                description: "Changes the web UI's Arrangement: order the rooms (rooms), rename one (renameRoom: the accessories in it follow) or remove some (removeRooms; their accessories are left "
                    + "without a room), and make accessories Quick Controls (favourite). An accessory's room, Hidden and Name are its Accessory Settings: change them with update_settings. "
                    + "syncRoomNames turns Room Sync on or off (a Bridge Setting, off by default): with it on, renameRoom also renames the rooms of the same name on the plugins' hubs "
                    + "(Philips Hue, IKEA DIRIGERA, eWeLink, Apple Home), hubRooms says what each did, and an accessory moved with update_settings moves on the hubs that keep rooms. "
                    + "HomeKit and the Home app are not changed unless Room Sync is on and Apple Home is synced through Wingman.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "accessories": ["type": "array", "maxItems": 500, "items": change],
                        "rooms": ["type": "array", "maxItems": 100, "items": ["type": "string", "maxLength": 64], "description": "Room names in the order to show them"],
                        "renameRoom": ["type": "object", "required": ["from", "to"], "properties": ["from": ["type": "string"], "to": ["type": "string", "maxLength": 64]]],
                        "removeRooms": ["type": "array", "items": ["type": "string"]],
                        "syncRoomNames": ["type": "boolean", "description": "Room Sync, from now on: rename the hubs' rooms of the same name when a room is renamed here, and move accessories on the hubs that keep them in rooms (Apple Home)"],
                    ],
                ],
                outputSchema: Output.object(["rooms": ["type": "array"], "unassigned": ["type": "array"], "syncRoomNames": ["type": "boolean"], "hubRooms": ["type": "array"]], required: ["rooms", "unassigned"]),
                scope: .admin, idempotent: true
            ) { call in .json(try await catalog.updateLayout(call.arguments, by: "MCP \(call.session.clientInfo?.name ?? "client")")) },
        ]
    }
}
