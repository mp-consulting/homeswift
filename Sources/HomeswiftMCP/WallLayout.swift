import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The Accessories page's wall, for every user of the bridge: the accessories' order, the size each one was given,
/// the size of each kind of widget by default, and whether the page groups them by plugin (one wall by default).
/// In `ui-layout.json` next to config.json; what the page or `set_wall_layout` sends is checked and trimmed to that
/// before it is kept.
///
///     { "order": ["Govee:…", …], "sizes": { "Govee:…": "small" }, "defaults": { "climate": "large" }, "grouping": "none" }
public final class WallLayout: Sendable {
    static let sizes: Set<String> = ["small", "medium", "large", "xlarge"]
    static let groupings: Set<String> = ["plugin", "room", "none"]
    /// The kinds of widget (widgets.js's `kindOf`) and each one's own size: what `defaults` are by.
    static let kinds: KeyValuePairs<String, String> = [
        "climate": "xlarge", "air-purifier": "xlarge", "television": "xlarge", "camera": "large", "light": "medium (small without colour)",
        "fan": "medium", "switch-group": "medium", "garage-door": "medium", "lock": "medium", "security-system": "medium", "valve": "medium",
        "toggle": "small", "cover": "small", "sensor": "small", "battery": "small", "remote": "small", "inspector": "small",
    ]
    /// Far more than a bridge has: what keeps a page from filling the disk.
    static let maximumAccessories = 5000

    public let url: URL
    private let lock = NIOLock()

    public init(url: URL) { self.url = url }

    /// The layout kept, or an empty one.
    public func load() -> JSONValue {
        lock.withLock { read() }
    }

    /// Keeps `body` once checked; answers what was kept.
    public func save(_ body: JSONValue) throws -> JSONValue {
        try update { _ in body }
    }

    /// Changes the layout kept: `change` gets it and answers the new one, which is checked and kept, both under the lock.
    @discardableResult
    func update(_ change: (JSONValue) throws -> JSONValue) throws -> JSONValue {
        try lock.withLock {
            let layout = try Self.checked(change(read()))
            try OwnerOnlyFile.write(Data(layout.text(pretty: true).utf8), to: url)
            return layout
        }
    }

    private func read() -> JSONValue {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONValue(data: data), let layout = try? Self.checked(stored) else { return Self.empty }
        return layout
    }

    static let empty: JSONValue = ["order": [], "sizes": [:], "defaults": [:], "grouping": "none"]

    public struct Invalid: Error, CustomStringConvertible { public let description: String }

    /// The layout in `body` with nothing else: accessory ids as strings of a sane length, one of the four sizes, kinds
    /// as short lower-case names. Each part may be left out (it is then empty).
    static func checked(_ body: JSONValue) throws -> JSONValue {
        guard let object = body.objectValue else { throw Invalid(description: "the layout must be a JSON object") }
        let isID = { (id: String) in !id.isEmpty && id.utf8.count <= 512 }
        var order: [JSONValue] = [], seen = Set<String>()
        for entry in object["order"]?.arrayValue ?? [] {
            guard let id = entry.stringValue, isID(id) else { throw Invalid(description: "order lists accessory ids") }
            if seen.insert(id).inserted { order.append(.string(id)) }
        }
        let checkedSize = { (value: JSONValue) throws -> JSONValue in
            guard let size = value.stringValue, Self.sizes.contains(size) else { throw Invalid(description: "a size is small, medium, large or xlarge") }
            return .string(size)
        }
        let sizes = try (object["sizes"]?.objectValue ?? [:]).mapValues(checkedSize)
        guard sizes.keys.allSatisfy(isID) else { throw Invalid(description: "sizes are by accessory id") }
        let defaults = try (object["defaults"]?.objectValue ?? [:]).mapValues(checkedSize)
        guard defaults.keys.allSatisfy({ !$0.isEmpty && $0.count <= 40 && $0.allSatisfy { $0.isLowercase || $0 == "-" } }) else {
            throw Invalid(description: "defaults are by kind of widget (climate, light…)")
        }
        guard order.count <= maximumAccessories, sizes.count <= maximumAccessories else { throw Invalid(description: "too many accessories") }
        let grouping = object["grouping"]?.stringValue ?? "none"
        guard groupings.contains(grouping) else { throw Invalid(description: "grouping is plugin, room or none") }
        var groups: [JSONValue] = [], groupIDs = Set<String>(), members = Set<String>()
        if let value = object["groups"], value.arrayValue == nil { throw Invalid(description: "groups must be an array") }
        for group in object["groups"]?.arrayValue ?? [] {
            guard let id = group["id"]?.stringValue, id.hasPrefix("group:"), isID(id), groupIDs.insert(id).inserted,
                  let name = group["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
                  let ids = group["members"]?.arrayValue, ids.count >= 2, ids.count <= 100 else { throw Invalid(description: "invalid accessory group") }
            var checkedMembers: [JSONValue] = []
            for value in ids {
                guard let member = value.stringValue, isID(member), !member.hasPrefix("group:"), members.insert(member).inserted else { throw Invalid(description: "an accessory belongs to only one group") }
                checkedMembers.append(.string(member))
            }
            groups.append(["id": .string(id), "name": .string(name), "members": .array(checkedMembers)])
        }
        guard groups.count <= 100 else { throw Invalid(description: "too many groups") }
        var result: [String: JSONValue] = ["order": .array(order), "sizes": .object(sizes), "defaults": .object(defaults), "grouping": .string(grouping)]
        if object["groups"] != nil { result["groups"] = .array(groups) }
        return .object(result)
    }
}

extension HomeswiftCatalog {
    /// The services an accessory group drives (groups.js): lights, switches, outlets, fans and blinds.
    static let groupServices: Set<String> = ["Lightbulb", "Switch", "Outlet", "Fan", "Fanv2", "WindowCovering"]
    static let groupCharacteristics: Set<String> = ["On", "Active", "Brightness", "Color Temperature", "Hue", "Saturation", "Rotation Speed", "Target Position"]

    /// The controls a group can send to `accessory`, as groups.js finds them: those of its primary service when that is
    /// one a group drives, else of every such service; none when two services share one (which would it be?), or
    /// when one is a security control.
    static func groupControls(_ accessory: Accessory) -> Set<String> {
        let services = accessory.services.filter { groupServices.contains($0.type.name) }
        var controls = Set<String>()
        for service in services.first(where: \.isPrimary).map({ [$0] }) ?? services {
            for characteristic in service.characteristics
            where groupCharacteristics.contains(characteristic.type.name) && characteristic.type.permissions.contains(.pairedWrite) {
                // A switch that unlocks a door (a security control) is never one tap among others.
                guard !characteristic.isSecurityControl, controls.insert(characteristic.type.name).inserted else { return [] }
            }
        }
        return controls
    }

    /// Whether these accessories make a group: what they share turns them on or off, or moves them.
    static func canGroup(_ accessories: [Accessory]) -> Bool {
        guard let first = accessories.first else { return false }
        let shared = accessories.dropFirst().reduce(groupControls(first)) { $0.intersection(groupControls($1)) }
        return !shared.isDisjoint(with: ["On", "Active", "Target Position"])
    }

    /// The wall as the Accessories page draws it: `grouping`, `defaults`, and `sections` in their order (the rooms, then
    /// no room, when grouped by room; the plugins when grouped by plugin; one otherwise), each with its widgets in
    /// their order: an accessory (id, name, room, plugin, services, the size given to it, `groupable`) or a group
    /// (id, name, `members`), in the section of its first member, where its members' widgets give way to it. Hidden
    /// accessories are left out, as on the page.
    public func wallJSON() -> JSONValue {
        let layout = home.wall.load()
        let order = layout["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let sizes = layout["sizes"]?.objectValue ?? [:]
        let grouping = layout["grouping"]?.stringValue ?? "none"
        let shown = located().filter { $0.layout?.hidden != true }
        let rank = Self.wallRanks(shown, saved: order)
        let groups = (layout["groups"]?.arrayValue ?? []).compactMap { group -> (id: String, name: String, members: [String])? in
            guard let id = group["id"]?.stringValue, let name = group["name"]?.stringValue else { return nil }
            return (id, name, group["members"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        let grouped = Set(groups.flatMap(\.members))
        let byID = Dictionary(shown.map { ($0.accessory.id, $0) }, uniquingKeysWith: { first, _ in first })
        func entry(_ located: Located) -> JSONValue {
            let accessory = located.accessory
            var object: [String: JSONValue] = [
                "id": .string(accessory.id), "name": .string(located.layout?.name ?? accessory.name),
                "services": .array(accessory.services.filter { $0.type.uuid != ServiceType.accessoryInformation.uuid && !Self.isInternal($0) }.map { .string($0.type.name) }),
            ]
            if let room = located.room { object["room"] = .string(room) }
            if let platform = located.platform?.name { object["plugin"] = .string(platform) }
            if let size = sizes[accessory.id] { object["size"] = size }
            if Self.canGroup([accessory]) { object["groupable"] = true }
            return .object(object)
        }
        let section: (Located) -> String
        let names: [String]
        switch grouping {
        case "room":
            let rooms = allRoomNames(shown)
            section = { located in rooms.first { $0.caseInsensitiveCompare(located.room ?? "") == .orderedSame } ?? "" }
            names = rooms + [""]
        case "plugin":
            section = { $0.platform?.name ?? "" }
            names = Set(shown.map(section)).sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }
        default:
            section = { _ in "" }
            names = [""]
        }
        // Each widget with its section and rank: a group before the accessories when the order does not list it, as on the page.
        var widgets: [(section: String, rank: Int, json: JSONValue)] = shown.filter { !grouped.contains($0.accessory.id) }.map { located in
            (section(located), rank[located.accessory.id] ?? 0, entry(located))
        }
        for group in groups {
            guard let first = group.members.lazy.compactMap({ byID[$0] }).first else { continue }
            widgets.append((section(first), order.firstIndex(of: group.id) ?? -1, ["id": .string(group.id), "name": .string(group.name), "members": .array(group.members.map(JSONValue.string))]))
        }
        let bySection = Dictionary(grouping: widgets, by: \.section)
        return [
            "grouping": .string(grouping), "defaults": layout["defaults"] ?? [:],
            "sections": .array(names.compactMap { name in
                guard let members = bySection[name] else { return nil }
                return ["name": name.isEmpty ? .null : .string(name), "accessories": .array(members.sorted { $0.rank < $1.rank }.map(\.json))]
            }),
        ]
    }

    /// Each accessory's place on the wall: its index in the saved order, else after them by plugin and name.
    static func wallRanks(_ all: [Located], saved: [String]) -> [String: Int] {
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let byPlugin = all.sorted { a, b in
            let (pa, pb) = (a.platform?.name ?? "", b.platform?.name ?? "")
            return pa == pb ? a.accessory.name.localizedCompare(b.accessory.name) == .orderedAscending : (pa.isEmpty ? 1 : 0, pa) < (pb.isEmpty ? 1 : 0, pb)
        }
        return Dictionary(byPlugin.enumerated().map { ($1.accessory.id, rank[$1.accessory.id] ?? saved.count + $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The accessories in the wall's order.
    static func wallOrder(_ all: [Located], saved: [String]) -> [Located] {
        let rank = wallRanks(all, saved: saved)
        return all.sorted { rank[$0.accessory.id] ?? 0 < rank[$1.accessory.id] ?? 0 }
    }

    /// Changes the wall. `body` may hold `groups`, groups to make (no id) or change (an existing id), each a name and
    /// the accessories it controls together, which leave any other group; `ungroup`, group ids to dissolve; `order`,
    /// accessory and group ids in the order to show them, placed in the places they hold together now (so one room's
    /// accessories can be sorted without moving the others); `sizes`, a size by accessory id, null for its kind's;
    /// `defaults`, a size by kind of widget, null for the kind's own; `grouping`. Answers `wallJSON()`.
    public func updateWall(_ body: JSONValue) throws -> JSONValue {
        let all = located()
        let byID = Dictionary(all.map { ($0.accessory.id, $0.accessory) }, uniquingKeysWith: { first, _ in first })
        do {
            try home.wall.update { current in
                guard var layout = current.objectValue else { return current }
                var saved = layout["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
                var groups = layout["groups"]?.arrayValue ?? []
                /// Every widget in its place now: the running accessories the order does not list yet included, then
                /// what it keeps for accessories not running and groups.
                func fullOrder() -> [String] {
                    let running = Self.wallOrder(all, saved: saved).map(\.accessory.id)
                    let listed = Set(running)
                    return running + saved.filter { !listed.contains($0) }
                }
                func removeGroups(_ ids: Set<String>) {
                    groups.removeAll { ids.contains($0["id"]?.stringValue ?? "") }
                    saved.removeAll { ids.contains($0) }
                }
                for id in body["ungroup"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                    guard groups.contains(where: { $0["id"]?.stringValue == id }) else { throw CatalogError("No group with id \(id)") }
                    removeGroups([id])
                }
                var claimed = Set<String>()
                for change in body["groups"]?.arrayValue ?? [] {
                    let members = change["members"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let name = change["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !name.isEmpty, name.count <= 64 else { throw CatalogError("A group needs a name of 1 to 64 characters") }
                    guard Set(members).count == members.count, members.count >= 2 else { throw CatalogError("The group \(name) needs two different accessories or more") }
                    let accessories = try members.map { id in
                        guard let accessory = byID[id] else { throw CatalogError("No accessory with id \(id)") }
                        return accessory
                    }
                    guard claimed.isDisjoint(with: members) else { throw CatalogError("An accessory belongs to only one group") }
                    claimed.formUnion(members)
                    guard Self.canGroup(accessories) else {
                        throw CatalogError("The group \(name) has no control its members share: a group turns lights, switches, outlets or fans on and off, or moves blinds")
                    }
                    let existing = change["id"]?.stringValue
                    if let existing, !groups.contains(where: { $0["id"]?.stringValue == existing }) { throw CatalogError("No group with id \(existing)") }
                    let id = existing ?? "group:\(UUID().uuidString.lowercased())"
                    // Its members leave the other groups; one left with fewer than two is dissolved.
                    var emptied = Set<String>()
                    groups = groups.compactMap { group in
                        guard let other = group["id"]?.stringValue, other != id, var object = group.objectValue else { return group }
                        let left = (group["members"]?.arrayValue ?? []).filter { !members.contains($0.stringValue ?? "") }
                        guard left.count >= 2 else { emptied.insert(other); return nil }
                        object["members"] = .array(left)
                        return .object(object)
                    }
                    removeGroups(emptied)
                    let group: JSONValue = ["id": .string(id), "name": .string(name), "members": .array(members.map(JSONValue.string))]
                    if let index = groups.firstIndex(where: { $0["id"]?.stringValue == id }) {
                        groups[index] = group
                    } else {
                        groups.append(group)
                        // A new group takes the place of its first member on the wall.
                        var full = fullOrder()
                        full.insert(id, at: full.firstIndex { members.contains($0) } ?? full.endIndex)
                        saved = full
                    }
                }
                let groupIDs = Set(groups.compactMap { $0["id"]?.stringValue })
                func check(_ id: String) throws {
                    guard byID[id] != nil || groupIDs.contains(id) || saved.contains(id) else { throw CatalogError("No accessory or group with id \(id)") }
                }
                if let value = body["order"], !value.isNull {
                    guard let ids = value.arrayValue?.compactMap(\.stringValue), ids.count == value.arrayValue?.count else { throw CatalogError("order lists accessory ids") }
                    var seen = Set<String>()
                    let wanted = try ids.filter { id in
                        try check(id)
                        return seen.insert(id).inserted
                    }
                    var full = fullOrder()
                    full += wanted.filter { !full.contains($0) }
                    let slots = full.indices.filter { seen.contains(full[$0]) }
                    for (slot, id) in zip(slots, wanted) { full[slot] = id }
                    saved = full
                }
                layout["order"] = .array(saved.map(JSONValue.string))
                if body["groups"] != nil || body["ungroup"] != nil { layout["groups"] = .array(groups) }
                if let changes = body["sizes"]?.objectValue {
                    var sizes = layout["sizes"]?.objectValue ?? [:]
                    for (id, size) in changes {
                        try check(id)
                        if size.isNull { sizes.removeValue(forKey: id) } else { sizes[id] = size }
                    }
                    layout["sizes"] = .object(sizes)
                }
                if let changes = body["defaults"]?.objectValue {
                    var defaults = layout["defaults"]?.objectValue ?? [:]
                    for (kind, size) in changes {
                        guard WallLayout.kinds.contains(where: { $0.key == kind }) else {
                            throw CatalogError("No kind of widget \(kind): \(WallLayout.kinds.map(\.key).joined(separator: ", "))")
                        }
                        if size.isNull { defaults.removeValue(forKey: kind) } else { defaults[kind] = size }
                    }
                    layout["defaults"] = .object(defaults)
                }
                if let grouping = body["grouping"], !grouping.isNull { layout["grouping"] = grouping }
                return .object(layout)
            }
        } catch let error as WallLayout.Invalid {
            throw CatalogError(error.description)
        }
        return wallJSON()
    }

    var wallTools: [MCPTool] {
        let catalog = self
        let size: JSONValue = ["type": ["string", "null"], "enum": ["small", "medium", "large", "xlarge", .null]]
        let kinds = WallLayout.kinds.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        let output = Output.object(["grouping": ["type": "string"], "sections": ["type": "array"]], required: ["grouping", "sections"])
        return [
            MCPTool(
                name: "get_wall_layout", title: "Get the accessories wall",
                description: "The web UI's Accessories wall as it is drawn: its grouping (none, room or plugin), the sections in order, "
                    + "each with its widgets in order: accessories (id, name, room, plugin, services, size when one was chosen for it, "
                    + "groupable when it can join a group) and accessory groups (id, name, members), which stand in for their members. "
                    + "Also the default size of each kind of widget the user chose (defaults). Hidden accessories are left out.",
                outputSchema: output, scope: .read, idempotent: true
            ) { _ in .json(catalog.wallJSON()) },
            MCPTool(
                name: "set_wall_layout", title: "Arrange the accessories wall",
                description: "Arranges the web UI's Accessories wall (the same for every user; HomeKit and the Home app are not changed). "
                    + "groups: accessories that go together as one widget whose controls drive them all (the lights of a room, its blinds, "
                    + "a pair of lamps); without an id a group is made, with one it is changed; an accessory is in one group at most, and "
                    + "joining a group takes it out of another. Only groupable accessories (lights, switches, outlets, fans, blinds) "
                    + "sharing an on/off or a position make a group: never mix blinds with lights. ungroup: group ids to dissolve. "
                    + "order: accessory and group ids in the order to show them; they take the places they hold together now, so the ids of "
                    + "one room sort that room and leave the rest, and every id sorts the whole wall. sizes: a size by accessory id (null: its kind's). "
                    + "defaults: a size by kind of widget (null: the kind's own); the kinds and their own sizes: \(kinds); a group is large unless sized (sizes takes group ids too). "
                    + "grouping: none (one wall), room (a wall per room, in get_accessory_layout's room order; set_accessory_layout orders "
                    + "the rooms and puts accessories in them) or plugin. "
                    + "Sizes: small is a 1×1 tile (tap to toggle), medium 1×2 (two smalls fit beside it), large and xlarge span two "
                    + "columns with the full controls. To compose a good wall: group by room, group a room's lights or blinds when it has "
                    + "two or more (keep each one's own widget only when it is used alone), put what is used most first in each "
                    + "room (lights, then climate, shutters, switches; sensors and batteries last), give climate, televisions and "
                    + "purifiers xlarge, colour lights medium or large, and switches, shutters and sensors small, keeping smalls in pairs so the rows pack.",
                inputSchema: [
                    "type": "object", "additionalProperties": false,
                    "properties": [
                        "groups": [
                            "type": "array", "maxItems": 100,
                            "items": [
                                "type": "object", "required": ["name", "members"], "additionalProperties": false,
                                "properties": [
                                    "id": ["type": "string", "description": "An existing group's id, to change it"],
                                    "name": ["type": "string", "maxLength": 64],
                                    "members": ["type": "array", "minItems": 2, "maxItems": 100, "items": ["type": "string"], "description": "Accessory ids"],
                                ],
                            ],
                        ],
                        "ungroup": ["type": "array", "items": ["type": "string"], "description": "Group ids to dissolve"],
                        "order": ["type": "array", "maxItems": 1000, "items": ["type": "string"], "description": "Accessory and group ids in the order to show them"],
                        "sizes": ["type": "object", "additionalProperties": size, "description": "A size by accessory id"],
                        "defaults": ["type": "object", "additionalProperties": size, "description": "A size by kind of widget"],
                        "grouping": ["type": "string", "enum": ["none", "room", "plugin"]],
                    ],
                ],
                outputSchema: output, scope: .admin
            ) { call in .json(try catalog.updateWall(call.arguments)) },
        ]
    }
}
