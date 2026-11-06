import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

// The bridge's copy of the Home (docs/adr/0005-apple-home-owns-rooms-zones-and-groups.md, GLOSSARY.md "Home"): which of
// its Rooms, Zones and Groups are which of the Home's, the changes made while the Home Link was down (Pending Changes),
// and the comparison a bridge's first link waits on. The Rooms themselves stay the layout's (`AccessoryLayout.rooms`, in
// their order), an accessory's room its Accessory Settings', a Group the wall's; `home.json` only links them.

/// `home.json`: what links the bridge's Rooms, Zones and Groups to the Home's.
public struct HomeLinkFile: Codable, Sendable, Equatable {
    /// The Home the bridge is linked to; nil before its first link is confirmed.
    public var homeID: String?
    public var homeName: String?
    /// The Home's id of each linked Room, by the Room's name as the layout spells it.
    public var rooms: [String: String] = [:]
    /// The Zones, in the order the pages show them.
    public var zones: [Zone] = []
    /// What changed while the Home Link was down, in order, to reach Apple Home when it is back up.
    public var pending: [PendingChange] = []
    /// A first link waiting for a person to confirm what it changes.
    public var comparison: Comparison?
    /// The latest changes Apple Home refused, newest last, for the pages.
    public var refused: [Refused] = []

    public init() {}

    public struct Zone: Codable, Sendable, Equatable {
        /// The bridge's own id, `zone:<uuid>`.
        public var id: String
        public var homeKitID: String?
        public var name: String
        /// Its Rooms, by name.
        public var rooms: [String]
    }

    /// A change made while the Home Link was down, naming what it changes as the bridge does: Rooms by name, Zones and
    /// Groups by the bridge's id, accessories by theirs.
    public struct PendingChange: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case createRoom, renameRoom, deleteRoom, moveAccessory
            case createZone, renameZone, deleteZone, setZoneRooms
            case createGroup, renameGroup, deleteGroup, setGroupMembers
        }

        public var kind: Kind
        /// A Room's, Zone's or Group's (new) name.
        public var name: String?
        /// A renamed Room's old name.
        public var from: String?
        public var accessory: String?
        /// A moved accessory's Room; empty for No Room.
        public var room: String?
        public var zone: String?
        public var group: String?
        /// Rooms (by name) or accessories (by id) a Zone or Group gains or loses.
        public var add: [String]?
        public var remove: [String]?
        /// A removed Zone's or Group's id in the Home: the bridge no longer has it.
        public var homeKitID: String?
        public var at: Date

        init(_ kind: Kind, name: String? = nil, from: String? = nil, accessory: String? = nil, room: String? = nil, zone: String? = nil,
             group: String? = nil, add: [String]? = nil, remove: [String]? = nil, homeKitID: String? = nil, at: Date = Date()) {
            (self.kind, self.name, self.from, self.accessory, self.room, self.zone, self.group, self.add, self.remove, self.homeKitID, self.at) =
                (kind, name, from, accessory, room, zone, group, add, remove, homeKitID, at)
        }
    }

    /// What a bridge's first link would change, for a person to confirm.
    public struct Comparison: Codable, Sendable, Equatable {
        public struct Placement: Codable, Sendable, Equatable {
            public var accessory: String
            public var name: String
            /// Its Room here and in Apple Home; empty for No Room.
            public var here: String
            public var home: String
            /// The Room it ends in once confirmed.
            public var result: String
        }

        public var homeID: String
        public var homeName: String
        /// Rooms only the bridge has: created in Apple Home.
        public var roomsOnlyHere: [String]
        /// Rooms only Apple Home has: the bridge takes them.
        public var roomsOnlyInHome: [String]
        public var accessories: [Placement]
        /// The wall's groups Apple Home could not have (`groupProblem`): ungrouped.
        public var groupsUngrouped: [String]
        /// The wall's groups made in Apple Home.
        public var groupsCreated: [String]
        /// Room names that differ only by case or accents: the bridge must rename one before linking.
        public var clashes: [[String]]
    }

    public struct Refused: Codable, Sendable, Equatable {
        public var change: PendingChange
        public var reason: String
    }

    func homeKitID(ofRoom name: String) -> String? {
        rooms.first { HomeswiftCatalog.sameRoomName($0.key, name) }?.value
    }

    func roomName(ofHomeKitID id: String) -> String? { rooms.first { $0.value == id }?.key }
}

/// Runs the Home Link's work one piece after the other: a snapshot followed, a change pushed, a comparison confirmed.
final class SerialWork: Sendable {
    private let tail = NIOLockedValueBox<Task<Void, Never>?>(nil)

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = tail.withLockedValue { tail -> Task<T, any Error> in
            let previous = tail
            let task = Task<T, any Error> {
                await previous?.value
                return try await work()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}

/// What the Home Link last said, for checks that cannot wait for it (a Room renamed while it is up but not allowed to
/// edit is refused at once).
struct LastHome: Sendable {
    var state: HomeLinkState
    var snapshot: HomeSnapshot?
}

extension HomeswiftCatalog {
    // MARK: Status

    /// `{state, reason?, via?, home?, linked, pending, comparison?, refused}`: what the pages and `get_home_link` show,
    /// the link asked now.
    public func homeLinkJSON() async -> JSONValue {
        let link = await host.homeLink()
        var object = homeLinkStatus(state: link?.state, via: link?.instance.name)
        let file = home.homeLink.value
        if let comparison = file.comparison { object["comparison"] = Self.json(comparison) }
        if !file.refused.isEmpty {
            object["refused"] = .array(file.refused.suffix(10).map { refused in
                ["change": .string(Self.describe(refused.change)), "reason": .string(refused.reason)]
            })
        }
        return .object(object)
    }

    /// `homeLinkJSON()` without asking the link: its state as it last said (the room layout's `homeLink`).
    func homeLinkSummary() -> JSONValue {
        var object = homeLinkStatus(state: home.lastHome.withLockedValue { $0?.state }, via: nil)
        if home.homeLink.value.comparison != nil { object["waiting"] = true }
        return .object(object)
    }

    private func homeLinkStatus(state: HomeLinkState?, via: String?) -> [String: JSONValue] {
        let file = home.homeLink.value
        var object: [String: JSONValue] = ["linked": .bool(file.homeID != nil), "pending": .number(Double(file.pending.count))]
        switch state {
        case .up: object["state"] = "up"
        case .readOnly(let reason): object["state"] = "readOnly"; object["reason"] = .string(reason)
        case .down(let reason): object["state"] = "down"; object["reason"] = .string(reason)
        case nil: object["state"] = "none"
        }
        if let via { object["via"] = .string(via) }
        if let name = file.homeName { object["home"] = .string(name) }
        return object
    }

    /// Whether the Home Link refuses edits now (up, but not allowed to edit): the reason, else nil.
    func homeLinkRefusal() async -> String? {
        guard let link = await host.homeLink(), case .readOnly(let reason) = link.state, home.homeLink.value.homeID != nil else { return nil }
        return "Apple Home does not let the bridge change it: \(reason)"
    }

    /// Whether Apple Home has this accessory, as the Home Link last saw it (nil before it saw the Home).
    func isInHome(_ accessoryID: String) -> Bool? {
        home.lastHome.withLockedValue { $0?.snapshot }.map { $0.placements[accessoryID] != nil }
    }

    // MARK: Following the Home

    /// Reads the Home Link's snapshot and follows it: replays the Pending Changes first when it may edit, then takes the
    /// Home's Rooms, Zones, Groups and placements. A bridge never linked compares first, and waits for a person to confirm
    /// when its first link would change anything of its own.
    public func followHome() async {
        do {
            try await home.homeLinkWork.run { [self] in try await followHomeNow() }
        } catch {
            logger.warning("Could not follow Apple Home: \(error)")
        }
    }

    private func followHomeNow() async throws {
        guard let link = await host.homeLink() else { return }
        let snapshot = await link.plugin.homeSnapshot()
        home.lastHome.withLockedValue { $0 = LastHome(state: link.state, snapshot: snapshot) }
        guard link.state.isUp, var snapshot else { home.layoutChanged(); return }
        let file = home.homeLink.value
        if file.homeID != snapshot.homeID {
            let comparison = compareWithHome(snapshot)
            if comparison.needsConfirmation {
                if file.comparison != comparison {
                    try home.homeLink.update { $0.comparison = comparison }
                    logger.info("Apple Home's \(snapshot.homeName) differs from the bridge's Rooms: waiting for the first link to be confirmed")
                }
                home.layoutChanged()
                return
            }
            try await linkHome(snapshot, link: link)
            snapshot = await link.plugin.homeSnapshot() ?? snapshot
        }
        if link.state.canEdit, !home.homeLink.value.pending.isEmpty {
            await replayPending(link: link)
            snapshot = await link.plugin.homeSnapshot() ?? snapshot
        }
        try await adopt(snapshot)
        home.lastHome.withLockedValue { $0 = LastHome(state: link.state, snapshot: snapshot) }
        home.layoutChanged()
    }

    /// Takes the Home's Rooms, Zones, Groups and placements: a Room renamed or removed there is here, one added there is
    /// added here, an accessory moved there moves here, and the same for Zones and Groups. Nothing goes back.
    private func adopt(_ snapshot: HomeSnapshot) async throws {
        /// One step of following the Home: one that fails (a name another Room has) is logged, and the others go on.
        func step(_ what: String, _ body: JSONValue) async -> Bool {
            do {
                _ = try await updateLayout(body, by: "Apple Home", fromHome: true)
                return true
            } catch {
                logger.warning("Could not \(what) as in Apple Home: \(error)")
                return false
            }
        }
        var links = home.homeLink.value.rooms
        let homeRooms = Dictionary(snapshot.rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Linked Rooms renamed or gone in the Home.
        for (name, id) in links.sorted(by: { $0.key < $1.key }) {
            if let room = homeRooms[id] {
                guard room.name != name,
                      await step("rename the room \(name) \(room.name)", ["renameRoom": ["from": .string(name), "to": .string(room.name)]]) else { continue }
                links.removeValue(forKey: name)
                links[room.name] = id
            } else if await step("remove the room \(name)", ["removeRooms": [.string(name)]]) {
                links.removeValue(forKey: name)
            }
        }
        // The Home's Rooms the bridge has not linked: one of the same name takes the link, else the bridge adds it.
        let layoutRooms = home.layout.value.rooms
        var added: [String] = []
        for room in snapshot.rooms where !links.values.contains(room.id) {
            if let local = layoutRooms.first(where: { Self.sameRoomName($0, room.name) && links[$0] == nil }) {
                if local != room.name, !(await step("rename the room \(local) \(room.name)", ["renameRoom": ["from": .string(local), "to": .string(room.name)]])) {
                    continue
                }
            } else {
                added.append(room.name)
            }
            links[room.name] = room.id
        }
        if !added.isEmpty, !(await step("add the rooms \(added.joined(separator: ", "))", ["rooms": .array((home.layout.value.rooms + added).map(JSONValue.string))])) {
            for room in added { links.removeValue(forKey: room) }
        }
        try home.homeLink.update { $0.rooms = links }

        // Where each accessory the Home has is.
        var moves: [(accessoryID: String, settings: [String: JSONValue])] = []
        for (accessoryID, roomID) in snapshot.placements.sorted(by: { $0.key < $1.key }) {
            guard let found = find(id: accessoryID) else { continue }
            let wanted = roomID.flatMap { id in links.first { $0.value == id }?.key } ?? ""
            if !Self.sameRoomName(wanted, found.room ?? "") { moves.append((accessoryID, ["room": .string(wanted)])) }
        }
        if !moves.isEmpty {
            do {
                _ = try await updateAccessorySettings(moves, moveOnHubs: false, by: .person, who: "Apple Home")
                logger.info("\(moves.count) accessories moved as in Apple Home")
            } catch {
                logger.warning("Could not move \(moves.count) accessories as in Apple Home: \(error)")
            }
        }
        try adoptZones(snapshot, links: links)
        try adoptGroups(snapshot)
    }

    private func adoptZones(_ snapshot: HomeSnapshot, links: [String: String]) throws {
        let names = { (ids: [String]) in ids.compactMap { id in links.first { $0.value == id }?.key } }
        try home.homeLink.update { file in
            var zones: [HomeLinkFile.Zone] = []
            for zone in file.zones {
                // One never linked keeps its place: a Pending Change creates it.
                guard let id = zone.homeKitID else { zones.append(zone); continue }
                guard let there = snapshot.zones.first(where: { $0.id == id }) else { continue }
                zones.append(.init(id: zone.id, homeKitID: id, name: there.name, rooms: names(there.rooms)))
            }
            for zone in snapshot.zones where !zones.contains(where: { $0.homeKitID == zone.id }) {
                zones.append(.init(id: "zone:\(UUID().uuidString.lowercased())", homeKitID: zone.id, name: zone.name, rooms: names(zone.rooms)))
            }
            file.zones = zones
        }
    }

    private func adoptGroups(_ snapshot: HomeSnapshot) throws {
        let current = Self.groups(of: home.wall.load())
        var groups: [WallGroup] = []
        var taken = Set<String>()
        for group in current {
            guard let id = group.homeKitID else { groups.append(group); continue }
            guard let there = snapshot.groups.first(where: { $0.id == id }), there.members.count >= 2 else { continue }
            groups.append(WallGroup(id: group.id, name: there.name, members: there.members, homeKitID: id))
        }
        for group in snapshot.groups where group.members.count >= 2 && !groups.contains(where: { $0.homeKitID == group.id }) {
            groups.append(WallGroup(id: "group:\(UUID().uuidString.lowercased())", name: group.name, members: group.members, homeKitID: group.id))
        }
        // An accessory is in one group at most: a linked group wins over one never linked.
        groups = groups.sorted { ($0.homeKitID != nil ? 0 : 1) < ($1.homeKitID != nil ? 0 : 1) }.compactMap { group in
            var group = group
            group.members = group.members.filter { taken.insert($0).inserted }
            return group.members.count >= 2 ? group : nil
        }
        guard groups != current else { return }
        try home.wall.update { layout in
            var object = layout.objectValue ?? [:]
            object["groups"] = .array(groups.map(\.json))
            return .object(object)
        }
    }

    // MARK: Changes made here

    /// Hands changes made here to the Home Link: made in Apple Home at once while it is up and may edit, else kept as
    /// Pending Changes, after those already kept. Answers what Apple Home refused, for the change's answer.
    @discardableResult
    func homeLinkRecord(_ changes: [HomeLinkFile.PendingChange]) async -> [JSONValue] {
        // Before the first link, the bridge's Rooms are its own: the comparison takes them to Apple Home.
        guard !changes.isEmpty, home.homeLink.value.homeID != nil else { return [] }
        do {
            return try await home.homeLinkWork.run { [self] in
                try home.homeLink.update { $0.pending += changes }
                guard let link = await host.homeLink(), link.state.canEdit, home.homeLink.value.homeID != nil else { return [] }
                let before = home.homeLink.value.refused.count
                await replayPending(link: link)
                return home.homeLink.value.refused.dropFirst(before).map { refused in
                    ["change": .string(Self.describe(refused.change)), "reason": .string(refused.reason)]
                }
            }
        } catch {
            logger.warning("Could not keep a change for Apple Home: \(error)")
            return []
        }
    }

    /// Makes the Pending Changes in the Home, in order, until one finds the link down: that one and the rest stay.
    private func replayPending(link: (instance: PluginHost.PlatformInstance, state: HomeLinkState, plugin: any HomeswiftPlugin)) async {
        while let change = home.homeLink.value.pending.first {
            do {
                try await push(change, plugin: link.plugin)
            } catch let error as HomeChangeError where error.kind == .unreachable {
                logger.info("Apple Home is not reachable: \(home.homeLink.value.pending.count) changes wait for it")
                return
            } catch let error as HomeChangeError where error.kind == .notFound && ![.createGroup, .setGroupMembers].contains(change.kind) {
                // A move of an accessory Apple Home does not have (Not in Home), a room or zone already gone there.
                logger.debug("\(Self.describe(change)): no longer in Apple Home")
            } catch {
                logger.warning("Apple Home refused: \(Self.describe(change)): \(error)")
                try? home.homeLink.update { file in
                    file.refused.append(.init(change: change, reason: "\(error)"))
                    if file.refused.count > 20 { file.refused.removeFirst(file.refused.count - 20) }
                }
            }
            try? home.homeLink.update { file in
                if file.pending.first == change { file.pending.removeFirst() }
            }
        }
    }

    /// One change made in the Home, by the Home's ids as the links know them now; links what it creates.
    private func push(_ change: HomeLinkFile.PendingChange, plugin: any HomeswiftPlugin) async throws {
        let file = home.homeLink.value
        func roomID(_ name: String) async throws -> String {
            if let id = home.homeLink.value.homeKitID(ofRoom: name) { return id }
            let id = try await plugin.applyHomeChange(.createRoom(name: name))
            guard let id else { throw HomeChangeError(.refused, "Apple Home did not create the room \(name)") }
            try home.homeLink.update { $0.rooms[name] = id }
            return id
        }
        func zone(_ id: String?) -> HomeLinkFile.Zone? { file.zones.first { $0.id == id } }
        func groupHomeKitID(_ id: String?) -> String? {
            Self.groups(of: home.wall.load()).first { $0.id == id }?.homeKitID
        }
        switch change.kind {
        case .createRoom:
            guard let name = change.name else { return }
            _ = try await roomID(name)
        case .renameRoom:
            guard let from = change.from, let name = change.name else { return }
            guard let id = file.homeKitID(ofRoom: from) else { _ = try await roomID(name); return }
            _ = try await plugin.applyHomeChange(.renameRoom(id: id, name: name))
            try home.homeLink.update { file in
                file.rooms = file.rooms.filter { $0.value != id }
                file.rooms[name] = id
            }
        case .deleteRoom:
            guard let name = change.name, let id = file.homeKitID(ofRoom: name) else { return }
            _ = try await plugin.applyHomeChange(.deleteRoom(id: id))
            try home.homeLink.update { file in file.rooms = file.rooms.filter { $0.value != id } }
        case .moveAccessory:
            guard let accessory = change.accessory else { return }
            let room = change.room ?? ""
            _ = try await plugin.applyHomeChange(.moveAccessory(accessoryID: accessory, roomID: room.isEmpty ? nil : try await roomID(room)))
        case .createZone:
            guard let local = zone(change.zone), local.homeKitID == nil else { return }
            let id = try await plugin.applyHomeChange(.createZone(name: local.name))
            guard let id else { throw HomeChangeError(.refused, "Apple Home did not create the zone \(local.name)") }
            var rooms: [String] = []
            for name in local.rooms { rooms.append(try await roomID(name)) }
            if !rooms.isEmpty { _ = try await plugin.applyHomeChange(.setZoneRooms(id: id, add: rooms, remove: [])) }
            try home.homeLink.update { file in
                if let index = file.zones.firstIndex(where: { $0.id == local.id }) { file.zones[index].homeKitID = id }
            }
        case .renameZone:
            guard let id = zone(change.zone)?.homeKitID, let name = change.name else { return }
            _ = try await plugin.applyHomeChange(.renameZone(id: id, name: name))
        case .deleteZone:
            // Gone from the file already: its Home id travels with the change.
            guard let id = change.homeKitID else { return }
            _ = try await plugin.applyHomeChange(.deleteZone(id: id))
        case .setZoneRooms:
            guard let id = zone(change.zone)?.homeKitID else { return }
            var add: [String] = []
            for name in change.add ?? [] { add.append(try await roomID(name)) }
            let remove = (change.remove ?? []).compactMap(file.homeKitID(ofRoom:))
            _ = try await plugin.applyHomeChange(.setZoneRooms(id: id, add: add, remove: remove))
        case .createGroup:
            let groups = Self.groups(of: home.wall.load())
            guard let local = groups.first(where: { $0.id == change.group }), local.homeKitID == nil else { return }
            let id = try await plugin.applyHomeChange(.createGroup(name: local.name, members: local.members))
            guard let id else { throw HomeChangeError(.refused, "Apple Home did not create the group \(local.name)") }
            try home.wall.update { layout in
                var object = layout.objectValue ?? [:]
                object["groups"] = .array(groups.map { group in
                    var group = group
                    if group.id == local.id { group.homeKitID = id }
                    return group.json
                })
                return .object(object)
            }
        case .renameGroup:
            guard let id = groupHomeKitID(change.group), let name = change.name else { return }
            _ = try await plugin.applyHomeChange(.renameGroup(id: id, name: name))
        case .deleteGroup:
            guard let id = change.homeKitID else { return }
            _ = try await plugin.applyHomeChange(.deleteGroup(id: id))
        case .setGroupMembers:
            guard let id = groupHomeKitID(change.group) else { return }
            _ = try await plugin.applyHomeChange(.setGroupMembers(id: id, add: change.add ?? [], remove: change.remove ?? []))
        }
    }

    // MARK: The first link

    /// What linking the bridge to this Home would change.
    func compareWithHome(_ snapshot: HomeSnapshot) -> HomeLinkFile.Comparison {
        let layoutRooms = home.layout.value.rooms
        let homeNames = snapshot.rooms.map(\.name)
        let onlyHere = layoutRooms.filter { local in !homeNames.contains { Self.sameRoomName($0, local) } }
        let onlyInHome = homeNames.filter { name in !layoutRooms.contains { Self.sameRoomName($0, name) } }
        // Two of the bridge's Rooms Apple Home would take for one.
        var clashes: [[String]] = []
        var seen = Set<String>()
        for room in layoutRooms where !seen.contains(room) {
            let same = layoutRooms.filter { Self.sameRoomName($0, room) }
            same.forEach { seen.insert($0) }
            if same.count > 1 { clashes.append(same) }
        }
        var placements: [HomeLinkFile.Comparison.Placement] = []
        for (accessoryID, roomID) in snapshot.placements.sorted(by: { $0.key < $1.key }) {
            guard let found = find(id: accessoryID) else { continue }
            let here = found.layout?.room.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            let there = roomID.flatMap { snapshot.room($0)?.name } ?? ""
            // One in no Room here has nothing of its own to lose: it takes Apple Home's.
            guard !here.isEmpty, !Self.sameRoomName(here, there) else { continue }
            // Apple Home's placement wins, but No Room there takes the bridge's Room.
            let result = there.isEmpty ? here : there
            placements.append(.init(accessory: accessoryID, name: found.accessory.name, here: here, home: there, result: result))
        }
        let groups = Self.groups(of: home.wall.load()).filter { $0.homeKitID == nil }
        var ungrouped: [String] = [], created: [String] = []
        for group in groups {
            if groupProblem(members: group.members) == nil { created.append(group.name) } else { ungrouped.append(group.name) }
        }
        return .init(
            homeID: snapshot.homeID, homeName: snapshot.homeName, roomsOnlyHere: onlyHere, roomsOnlyInHome: onlyInHome,
            accessories: placements, groupsUngrouped: ungrouped, groupsCreated: created, clashes: clashes)
    }

    /// Confirms the first link that waits (`compareWithHome`): the bridge's own Rooms and Groups made in Apple Home,
    /// Apple Home's taken, each accessory where the comparison said. Answers `homeLinkJSON()`.
    public func confirmHomeLink(by who: String) async throws -> JSONValue {
        try await home.homeLinkWork.run { [self] in
            guard let link = await host.homeLink(), link.state.isUp, let snapshot = await link.plugin.homeSnapshot() else {
                throw CatalogError("Apple Home is not reachable: the Home Link is down")
            }
            guard link.state.canEdit else { throw CatalogError(await homeLinkRefusal() ?? "Apple Home does not let the bridge change it") }
            let comparison = compareWithHome(snapshot)
            guard comparison.clashes.isEmpty else {
                throw CatalogError("Rename one of \(comparison.clashes.map { $0.joined(separator: " and ") }.joined(separator: "; ")) first: Apple Home would take them for one room")
            }
            try await linkHome(snapshot, link: link)
            logger.info("Linked to Apple Home's \(snapshot.homeName)", metadata: ["by": "\(who)"])
            if let fresh = await link.plugin.homeSnapshot() { try await adopt(fresh) }
            home.layoutChanged()
            return ()
        }
        return await homeLinkJSON()
    }

    /// Links the bridge to the Home: its Rooms and Groups Apple Home lacks are made there, its Rooms and Apple Home's of
    /// the same name linked, and the accessories in No Room there that have a Room here moved there.
    private func linkHome(
        _ snapshot: HomeSnapshot, link: (instance: PluginHost.PlatformInstance, state: HomeLinkState, plugin: any HomeswiftPlugin)
    ) async throws {
        let comparison = compareWithHome(snapshot)
        var changes: [HomeLinkFile.PendingChange] = []
        var links: [String: String] = [:]
        for local in home.layout.value.rooms {
            if let room = snapshot.rooms.first(where: { Self.sameRoomName($0.name, local) }) { links[local] = room.id }
        }
        changes += comparison.roomsOnlyHere.map { .init(.createRoom, name: $0) }
        changes += comparison.accessories.filter { $0.home.isEmpty }.map { .init(.moveAccessory, accessory: $0.accessory, room: $0.here) }
        var groups = Self.groups(of: home.wall.load())
        let ungrouped = Set(comparison.groupsUngrouped)
        groups.removeAll { $0.homeKitID == nil && ungrouped.contains($0.name) }
        changes += groups.filter { $0.homeKitID == nil }.map { .init(.createGroup, group: $0.id) }
        changes += home.homeLink.value.zones.filter { $0.homeKitID == nil }.map { .init(.createZone, zone: $0.id) }
        let kept = groups
        try home.wall.update { layout in
            var object = layout.objectValue ?? [:]
            object["groups"] = .array(kept.map(\.json))
            return .object(object)
        }
        try home.homeLink.update { file in
            file.homeID = snapshot.homeID
            file.homeName = snapshot.homeName
            file.rooms = links
            file.comparison = nil
            file.pending = changes + file.pending
        }
        if link.state.canEdit { await replayPending(link: link) }
    }

    // MARK: Groups

    /// Why Apple Home would not group these accessories, or nil: the Home app groups accessories of one kind, each with
    /// one Function, every one of them in Apple Home.
    func groupProblem(members: [String]) -> String? {
        let found = members.compactMap(find(id:))
        guard found.count == members.count else { return "an accessory of the group is not on the bridge" }
        var kinds = Set<String>()
        for located in found {
            let functions = Functions.of(located.accessory)
            guard functions.count == 1, let function = functions.first else {
                return "\(located.accessory.name) does more than one thing: separate its Functions to group it"
            }
            if isInHome(located.accessory.id) == false || located.bridge.server.isHiddenFromHomeKit(located.accessory.id) {
                return "\(located.accessory.name) is not in Apple Home"
            }
            kinds.insert(function.type.uuid.uuidString)
        }
        return kinds.count > 1 ? "Apple Home groups accessories of one kind only" : nil
    }

    // MARK: Words

    static func describe(_ change: HomeLinkFile.PendingChange) -> String {
        switch change.kind {
        case .createRoom: "create the room \(change.name ?? "")"
        case .renameRoom: "rename the room \(change.from ?? "") \(change.name ?? "")"
        case .deleteRoom: "remove the room \(change.name ?? "")"
        case .moveAccessory: (change.room ?? "").isEmpty ? "take \(change.accessory ?? "") out of its room" : "move \(change.accessory ?? "") to \(change.room ?? "")"
        case .createZone: "create a zone"
        case .renameZone: "rename a zone \(change.name ?? "")"
        case .deleteZone: "remove a zone"
        case .setZoneRooms: "change a zone's rooms"
        case .createGroup: "create a group"
        case .renameGroup: "rename a group \(change.name ?? "")"
        case .deleteGroup: "remove a group"
        case .setGroupMembers: "change a group's accessories"
        }
    }

    static func json(_ comparison: HomeLinkFile.Comparison) -> JSONValue {
        [
            "home": .string(comparison.homeName),
            "roomsOnlyHere": .array(comparison.roomsOnlyHere.map(JSONValue.string)),
            "roomsOnlyInHome": .array(comparison.roomsOnlyInHome.map(JSONValue.string)),
            "accessories": .array(comparison.accessories.map { placement in
                [
                    "accessory": .string(placement.accessory), "name": .string(placement.name), "here": .string(placement.here),
                    "home": .string(placement.home), "result": .string(placement.result),
                ]
            }),
            "groupsCreated": .array(comparison.groupsCreated.map(JSONValue.string)),
            "groupsUngrouped": .array(comparison.groupsUngrouped.map(JSONValue.string)),
            "clashes": .array(comparison.clashes.map { .array($0.map(JSONValue.string)) }),
        ]
    }
}

extension HomeLinkFile.Comparison {
    /// Whether linking changes something of the bridge's own: a Room, a Group, or an accessory's Room it gave.
    var needsConfirmation: Bool {
        !roomsOnlyHere.isEmpty || !accessories.isEmpty || !groupsUngrouped.isEmpty || !groupsCreated.isEmpty || !clashes.isEmpty
    }
}
