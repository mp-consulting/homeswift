import Foundation
import Homeswift
import HomeswiftAI
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
    /// The Zones, in the order the pages show them.
    public var zones: [Zone] = []
    /// The Groups, linked to Apple Home's once made or found there; the wall keeps only where each one stands.
    var groups: [WallGroup] = []
    /// Whether the wall's groups (`ui-layout.json`, where older versions kept them) were moved here.
    var groupsMoved = false
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
        /// Its Rooms, by their id (`AccessoryLayout.Room.id`), so a renamed Room stays in it.
        public var rooms: [String]
    }

    /// A change made here for Apple Home, naming what it changes as the bridge does: Rooms by name, Zones and Groups by
    /// the bridge's id (by the Home's once the bridge no longer has them), accessories by theirs.
    public enum PendingChange: Codable, Sendable, Equatable {
        case createRoom(name: String)
        case renameRoom(from: String, to: String)
        /// With the Home's id of the Room, which the bridge no longer has.
        case deleteRoom(name: String, homeKitID: String?)
        /// To `room`, or out of every Room (Apple Home's Default Room) when it is empty.
        case moveAccessory(accessory: String, room: String)
        case createZone(zone: String)
        case renameZone(zone: String, name: String)
        case deleteZone(homeKitID: String)
        /// Rooms by id.
        case setZoneRooms(zone: String, add: [String], remove: [String])
        case createGroup(group: String)
        case renameGroup(group: String, name: String)
        case deleteGroup(homeKitID: String)
        /// Accessories by id.
        case setGroupMembers(group: String, add: [String], remove: [String])

        /// A change of a Group: one Apple Home cannot make (a member it does not have) is said, never dropped quietly.
        var isGroupChange: Bool {
            switch self {
            case .createGroup, .renameGroup, .deleteGroup, .setGroupMembers: true
            default: false
            }
        }

        /// What it is about: the Rooms (by name), Zones, Groups or accessories it changes. A change that reaches Apple
        /// Home settles an earlier refusal about the same.
        var subjects: Set<String> {
            switch self {
            case .createRoom(let name): ["room:\(name)"]
            case .renameRoom(let from, let to): ["room:\(from)", "room:\(to)"]
            case .deleteRoom(let name, _): ["room:\(name)"]
            case .moveAccessory(let accessory, _): ["accessory:\(accessory)"]
            case .createZone(let zone), .renameZone(let zone, _), .setZoneRooms(let zone, _, _): ["zone:\(zone)"]
            case .deleteZone(let homeKitID): ["zone:\(homeKitID)"]
            case .createGroup(let group), .renameGroup(let group, _), .setGroupMembers(let group, _, _): ["group:\(group)"]
            case .deleteGroup(let homeKitID): ["group:\(homeKitID)"]
            }
        }

        /// What it does, for the log and the pages.
        var described: String {
            switch self {
            case .createRoom(let name): "create the room \(name)"
            case .renameRoom(let from, let to): "rename the room \(from) \(to)"
            case .deleteRoom(let name, _): "remove the room \(name)"
            case .moveAccessory(let accessory, let room): room.isEmpty ? "take \(accessory) out of its room" : "move \(accessory) to \(room)"
            case .createZone: "create a zone"
            case .renameZone(_, let name): "rename a zone \(name)"
            case .deleteZone: "remove a zone"
            case .setZoneRooms: "change a zone's rooms"
            case .createGroup: "create a group"
            case .renameGroup(_, let name): "rename a group \(name)"
            case .deleteGroup: "remove a group"
            case .setGroupMembers: "change a group's accessories"
            }
        }
    }

    /// What a bridge's first link would change, for a person to confirm. Its JSON is what the pages show.
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

        public struct Group: Codable, Sendable, Equatable {
            /// The wall's id.
            public var id: String
            public var name: String
        }

        public var homeID: String
        public var homeName: String
        /// Rooms only the bridge has: created in Apple Home.
        public var roomsOnlyHere: [String]
        /// Rooms only Apple Home has: the bridge takes them.
        public var roomsOnlyInHome: [String]
        public var accessories: [Placement]
        /// The wall's groups Apple Home could not have (`groupProblem`): ungrouped.
        public var groupsUngrouped: [Group]
        /// The wall's groups made in Apple Home.
        public var groupsCreated: [Group]
        /// Room names that differ only by case or accents: the bridge must rename one before linking.
        public var clashes: [[String]]

        /// Whether linking changes something of the bridge's own: a Room, a Group, or an accessory's Room it gave.
        var needsConfirmation: Bool {
            !roomsOnlyHere.isEmpty || !accessories.isEmpty || !groupsUngrouped.isEmpty || !groupsCreated.isEmpty || !clashes.isEmpty
        }
    }

    public struct Refused: Codable, Sendable, Equatable {
        public var change: PendingChange
        public var reason: String

        var json: JSONValue { ["change": .string(change.described), "reason": .string(reason)] }
    }
}

/// What the Home Link last said, for checks that cannot wait for it (a Room renamed while it is up but not allowed to
/// edit is refused at once).
struct LastHome: Sendable {
    var state: HomeLinkState
    var snapshot: HomeSnapshot?
}

/// The Home Link plugin as `PluginHost.homeLink()` answers it.
typealias HomeLinkPlugin = (instance: PluginHost.PlatformInstance, state: HomeLinkState, plugin: any HomeswiftPlugin)

extension HomeswiftCatalog {
    // MARK: Status

    /// `{state, reason?, via?, home?, linked, pending, comparison?, refused}`: what the pages and `get_home_link` show,
    /// the link asked now (or `link`, already asked).
    public func homeLinkJSON() async -> JSONValue {
        homeLinkJSON(link: await host.homeLink())
    }

    func homeLinkJSON(link: HomeLinkPlugin?) -> JSONValue {
        var object = homeLinkStatus(state: link?.state, via: link?.instance.name)
        let file = home.homeLink.value
        if let comparison = file.comparison, let json = try? JSONValue(encoding: comparison) { object["comparison"] = json }
        if link != nil, !file.refused.isEmpty { object["refused"] = .array(file.refused.suffix(10).map(\.json)) }
        return .object(object)
    }

    /// `homeLinkJSON()` without asking the link: its state as it last said (the room layout's `homeLink`).
    func homeLinkSummary() -> JSONValue {
        let state = home.lastHome.withLockedValue { $0?.state }
        var object = homeLinkStatus(state: state, via: nil)
        if home.homeLink.value.comparison != nil { object["waiting"] = true }
        // Without a Home Link, what Apple Home once refused is no longer the pages' concern.
        let refused = home.homeLink.value.refused
        if state != nil, !refused.isEmpty { object["refused"] = .array(refused.suffix(10).map(\.json)) }
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
        guard home.homeLink.value.homeID != nil, let link = await host.homeLink() else { return nil }
        return Self.refusal(link.state)
    }

    static func refusal(_ state: HomeLinkState) -> String? {
        guard case .readOnly(let reason) = state else { return nil }
        return "Apple Home does not let the bridge change it: \(reason)"
    }

    /// Whether Apple Home has this accessory, as the Home Link last saw it (nil before it saw the Home).
    func isInHome(_ accessoryID: String) -> Bool? {
        home.lastHome.withLockedValue { $0?.snapshot }.map { $0.placements[accessoryID] != nil }
    }

    // MARK: Following the Home

    /// Reads the Home Link's snapshot and follows it: replays the Pending Changes first when it may edit, then takes the
    /// Home's Rooms, Zones, Groups and placements. A bridge never linked compares first, and waits for a person to confirm
    /// when its first link would change anything of its own. Calls that come while one waits make no other: the one
    /// waiting reads the newest snapshot.
    public func followHome() async {
        let waiting = home.followQueued.withLockedValue { queued in
            defer { queued = true }
            return queued
        }
        guard !waiting else { return }
        do {
            try await home.homeLinkWork.run { [self] in
                home.followQueued.withLockedValue { $0 = false }
                try await followHomeNow()
            }
        } catch {
            logger.warning("Could not follow Apple Home: \(error)")
        }
    }

    private func followHomeNow() async throws {
        guard let link = await host.homeLink() else {
            // No Home Link: what Apple Home refused is settled, and must not come back with a new pairing.
            home.lastHome.withLockedValue { $0 = nil }
            if !home.homeLink.value.refused.isEmpty { try home.homeLink.update { $0.refused = [] } }
            return
        }
        let snapshot = await link.plugin.homeSnapshot()
        home.lastHome.withLockedValue { $0 = LastHome(state: link.state, snapshot: snapshot) }
        guard link.state.isUp, var snapshot else { home.layoutChanged(); return }
        let file = home.homeLink.value
        if file.homeID != snapshot.homeID {
            let comparison = await compareWithHome(snapshot)
            if comparison.needsConfirmation {
                if file.comparison != comparison {
                    try home.homeLink.update { $0.comparison = comparison }
                    logger.info("Apple Home's \(snapshot.homeName) differs from the bridge's Rooms: waiting for the first link to be confirmed")
                }
                home.layoutChanged()
                return
            }
            try await linkHome(snapshot, comparison: comparison, link: link)
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
    /// added here, an accessory moved there moves here, and the same for Zones and Groups. Nothing goes back. A step that
    /// fails (a name another Room has) is logged, and the others go on.
    private func adopt(_ snapshot: HomeSnapshot) async throws {
        func step(_ what: String, _ body: JSONValue) async -> Bool {
            do {
                _ = try await updateLayout(body, by: "Apple Home", fromHome: true)
                return true
            } catch {
                logger.warning("Could not \(what) as in Apple Home: \(error)")
                return false
            }
        }
        let linked = Dictionary(home.layout.value.roomEntries.compactMap { room in room.homeKitID.map { (room.name, $0) } }, uniquingKeysWith: { first, _ in first })
        var links = linked
        let homeRooms = Dictionary(snapshot.rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Linked Rooms renamed in the Home, one by one (a rename is one change of the layout), and those gone, at once.
        var gone: [String] = []
        for (name, id) in linked.sorted(by: { $0.key < $1.key }) {
            guard let room = homeRooms[id] else { gone.append(name); continue }
            guard room.name != name,
                  await step("rename the room \(name) \(room.name)", ["renameRoom": ["from": .string(name), "to": .string(room.name)]]) else { continue }
            links.removeValue(forKey: name)
            links[room.name] = id
        }
        if !gone.isEmpty, await step("remove the rooms \(gone.joined(separator: ", "))", ["removeRooms": .array(gone.map(JSONValue.string))]) {
            for name in gone { links.removeValue(forKey: name) }
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
        if links != linked || home.layout.value.roomEntries.contains(where: { $0.homeKitID != links[$0.name] }) {
            try home.layout.update { layout in
                for index in layout.roomEntries.indices { layout.roomEntries[index].homeKitID = links[layout.roomEntries[index].name] }
            }
        }

        // Where each accessory the Home has is, read once the Rooms are as Apple Home has them.
        let moves = withLookup {
            snapshot.placements.sorted(by: { $0.key < $1.key }).compactMap { accessoryID, roomID -> (accessoryID: String, settings: [String: JSONValue])? in
                guard let found = find(id: accessoryID) else { return nil }
                let wanted = roomID.flatMap { id in links.first { $0.value == id }?.key } ?? ""
                return Self.sameRoomName(wanted, found.room ?? "") ? nil : (accessoryID, ["room": .string(wanted)])
            }
        }
        if !moves.isEmpty {
            do {
                _ = try await updateAccessorySettings(moves, fromHome: true, by: .person, who: "Apple Home")
                logger.info("\(moves.count) accessories moved as in Apple Home")
            } catch {
                logger.warning("Could not move \(moves.count) accessories as in Apple Home: \(error)")
            }
        }
        try adoptZones(snapshot)
        try adoptGroups(snapshot)
    }

    private func adoptZones(_ snapshot: HomeSnapshot) throws {
        let layout = home.layout.value
        let names = { (ids: [String]) in ids.compactMap { layout.room(homeKitID: $0)?.id } }
        let current = home.homeLink.value.zones
        var zones: [HomeLinkFile.Zone] = []
        for zone in current {
            // One never linked keeps its place: a Pending Change creates it.
            guard let id = zone.homeKitID else { zones.append(zone); continue }
            guard let there = snapshot.zones.first(where: { $0.id == id }) else { continue }
            zones.append(.init(id: zone.id, homeKitID: id, name: there.name, rooms: names(there.rooms)))
        }
        for zone in snapshot.zones where !zones.contains(where: { $0.homeKitID == zone.id }) {
            zones.append(.init(id: "zone:\(UUID().uuidString.lowercased())", homeKitID: zone.id, name: zone.name, rooms: names(zone.rooms)))
        }
        if zones != current { try home.homeLink.update { $0.zones = zones } }
    }

    private func adoptGroups(_ snapshot: HomeSnapshot) throws {
        let current = wallGroups
        // A read-only reconnect (or an interrupted replay) must not erase the local ids and edits still queued.
        let pending = home.homeLink.value.pending
        let edited = Set(pending.compactMap { change -> String? in
            switch change {
            case .createGroup(let id), .renameGroup(let id, _), .setGroupMembers(let id, _, _): id
            default: nil
            }
        })
        let deleted = Set(pending.compactMap { change -> String? in
            if case .deleteGroup(let id) = change { return id }
            return nil
        })
        var groups: [WallGroup] = []
        var taken = Set<String>()
        for group in current {
            if edited.contains(group.id) { groups.append(group); continue }
            guard let id = group.homeKitID else { groups.append(group); continue }
            guard let there = snapshot.groups.first(where: { $0.id == id }), there.members.count >= 2 else { continue }
            groups.append(WallGroup(id: group.id, name: there.name, members: there.members, homeKitID: id))
        }
        for group in snapshot.groups where group.members.count >= 2 && !deleted.contains(group.id) && !groups.contains(where: { $0.homeKitID == group.id }) {
            groups.append(WallGroup(id: "group:\(UUID().uuidString.lowercased())", name: group.name, members: group.members, homeKitID: group.id))
        }
        // Pending edits win, then linked groups, then groups never linked.
        func priority(_ group: WallGroup) -> Int { edited.contains(group.id) ? 0 : (group.homeKitID != nil ? 1 : 2) }
        groups = groups.sorted { priority($0) < priority($1) }.compactMap { group in
            var group = group
            group.members = group.members.filter { taken.insert($0).inserted }
            return group.members.count >= 2 ? group : nil
        }
        if groups != current { try setWallGroups(groups) }
    }

    /// Puts these groups in place of the Groups (`home.json`), checked as the wall checks them.
    func setWallGroups(_ groups: [WallGroup]) throws {
        _ = try updateWallLayout { layout in
            var object = layout.objectValue ?? [:]
            object["groups"] = .array(groups.map(\.json))
            return .object(object)
        }
    }

    /// The Groups.
    var wallGroups: [WallGroup] {
        moveWallGroups()
        return home.homeLink.value.groups
    }

    /// The wall as the pages and the tools see it: `ui-layout.json`'s order, sizes and positions, with the Groups.
    public func wallLayout() -> JSONValue {
        var object = home.wall.load().objectValue ?? [:]
        object["groups"] = .array(wallGroups.map(\.json))
        return .object(object)
    }

    /// Changes the wall as `wallLayout()` has it: `change` gets it and answers the new one, which is checked; its
    /// groups go to `home.json`, the rest to `ui-layout.json`. Answers what was kept, groups included.
    @discardableResult
    func updateWallLayout(_ change: (JSONValue) throws -> JSONValue) throws -> JSONValue {
        let groups = wallGroups
        var kept: [WallGroup] = groups
        let layout = try home.wall.update { current in
            var object = current.objectValue ?? [:]
            object["groups"] = .array(groups.map(\.json))
            var next = try WallLayout.checked(change(.object(object))).objectValue ?? [:]
            kept = (next.removeValue(forKey: "groups")?.arrayValue ?? []).compactMap(WallGroup.init)
            return .object(next)
        }
        if kept != groups {
            try home.homeLink.update { $0.groups = kept }
            home.layoutChanged()
        }
        var object = layout.objectValue ?? [:]
        object["groups"] = .array(kept.map(\.json))
        return .object(object)
    }

    /// Moves the groups older versions kept on the wall (`ui-layout.json`) to `home.json`, once.
    private func moveWallGroups() {
        guard !home.homeLink.value.groupsMoved else { return }
        let old = Self.groups(of: home.wall.load())
        do {
            try home.homeLink.update { file in
                if file.groups.isEmpty { file.groups = old }
                file.groupsMoved = true
            }
            if !old.isEmpty {
                try home.wall.update { layout in
                    var object = layout.objectValue ?? [:]
                    object.removeValue(forKey: "groups")
                    return .object(object)
                }
            }
        } catch {
            logger.warning("Could not move the wall's groups to home.json: \(error)")
        }
    }

    // MARK: Changes made here

    /// Hands changes made here to the Home Link and says in `answer`'s `appleHomeRefused` what Apple Home refused: made
    /// there at once while it is up and may edit, kept as Pending Changes, after those already kept, while it is down,
    /// refused while it may not edit.
    func recordForHome(_ changes: [HomeLinkFile.PendingChange], into answer: inout [String: JSONValue]) async {
        let refused = await homeLinkRecord(changes)
        if !refused.isEmpty { answer["appleHomeRefused"] = .array(refused) }
        answer["homeLink"] = homeLinkSummary()
    }

    /// `recordForHome` without an answer: what Apple Home refused.
    @discardableResult
    func homeLinkRecord(_ changes: [HomeLinkFile.PendingChange]) async -> [JSONValue] {
        // Before the first link, the bridge's Rooms are its own: the comparison takes them to Apple Home.
        guard !changes.isEmpty, home.homeLink.value.homeID != nil else { return [] }
        do {
            return try await home.homeLinkWork.run { [self] in
                let link = await host.homeLink()
                if let link, let refusal = Self.refusal(link.state) {
                    let refused = changes.map { HomeLinkFile.Refused(change: $0, reason: refusal) }
                    try keepRefused(refused)
                    return refused.map(\.json)
                }
                try home.homeLink.update { $0.pending += changes }
                guard let link, link.state.canEdit else { return [] }
                let refused = await replayPending(link: link)
                if !refused.isEmpty, let snapshot = await link.plugin.homeSnapshot() {
                    do { try adoptGroups(snapshot) }
                    catch { logger.warning("Could not restore Apple Home's groups after a refused change: \(error)") }
                }
                return refused.map(\.json)
            }
        } catch {
            logger.warning("Could not keep a change for Apple Home: \(error)")
            return []
        }
    }

    private func keepRefused(_ refused: [HomeLinkFile.Refused]) throws {
        try home.homeLink.update { file in
            // The newest refusal about a thing replaces the earlier ones.
            let subjects = refused.reduce(into: Set<String>()) { $0.formUnion($1.change.subjects) }
            file.refused.removeAll { !$0.change.subjects.isDisjoint(with: subjects) }
            file.refused += refused
            if file.refused.count > 20 { file.refused.removeFirst(file.refused.count - 20) }
        }
    }

    /// Drops the refusals about what `change` changes: Apple Home has it now, or no longer has it. A Zone or Group
    /// removed (named by the Home's id) also settles the refusals of edits to the ones the bridge no longer has.
    private func settleRefusals(of change: HomeLinkFile.PendingChange) {
        let subjects = change.subjects
        let groups = Set(wallGroups.map(\.id)), zones = Set(home.homeLink.value.zones.map(\.id))
        func settled(_ refused: HomeLinkFile.Refused) -> Bool {
            if !refused.change.subjects.isDisjoint(with: subjects) { return true }
            switch (change, refused.change) {
            case (.deleteGroup, .renameGroup(let id, _)), (.deleteGroup, .setGroupMembers(let id, _, _)): return !groups.contains(id)
            case (.deleteZone, .renameZone(let id, _)), (.deleteZone, .setZoneRooms(let id, _, _)): return !zones.contains(id)
            default: return false
            }
        }
        guard home.homeLink.value.refused.contains(where: settled) else { return }
        try? home.homeLink.update { file in file.refused.removeAll(where: settled) }
    }

    /// An accessory's id as a reason may give it: `PhilipsHue:5ecd…`.
    private static let accessoryIDPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_-]*:[^\s,;()]+"#)

    /// `reason` with the accessories it names by id named as the pages name them.
    func named(_ reason: String) -> String {
        var result = reason
        for match in Self.accessoryIDPattern.matches(in: reason, range: NSRange(reason.startIndex..., in: reason)).reversed() {
            guard let range = Range(match.range, in: reason), let located = find(id: String(reason[range])) else { continue }
            result.replaceSubrange(range, with: located.accessory.name)
        }
        return result
    }

    /// Makes the Pending Changes in the Home, in order, until one finds the link down: that one and the rest stay.
    @discardableResult
    private func replayPending(link: HomeLinkPlugin) async -> [HomeLinkFile.Refused] {
        var refused: [HomeLinkFile.Refused] = []
        while let change = home.homeLink.value.pending.first {
            do {
                try await push(change, plugin: link.plugin)
                settleRefusals(of: change)
            } catch let error as HomeChangeError where error.kind == .unreachable {
                logger.info("Apple Home is not reachable: \(home.homeLink.value.pending.count) changes wait for it")
                return refused
            } catch let error as HomeChangeError where error.kind == .notFound && !change.isGroupChange {
                // A move of an accessory Apple Home does not have (Not in Home), a room or zone already gone there.
                logger.debug("\(change.described): no longer in Apple Home")
                settleRefusals(of: change)
            } catch {
                logger.warning("Apple Home refused: \(change.described): \(error)")
                let failure = HomeLinkFile.Refused(change: change, reason: named("\(error)"))
                refused.append(failure)
                try? keepRefused([failure])
                if case .createGroup(let id) = change {
                    // A refused creation is not a local-only Group that looks successfully synchronized.
                    try? setWallGroups(wallGroups.filter { $0.id != id })
                }
            }
            try? home.homeLink.update { file in
                if file.pending.first == change { file.pending.removeFirst() }
            }
        }
        return refused
    }

    /// One change made in the Home, by the Home's ids as the links know them now; links what it creates.
    private func push(_ change: HomeLinkFile.PendingChange, plugin: any HomeswiftPlugin) async throws {
        let file = home.homeLink.value
        func roomID(_ name: String) async throws -> String {
            if let id = home.layout.value.homeKitID(ofRoom: name) { return id }
            let id = try await plugin.applyHomeChange(.createRoom(name: name))
            guard let id else { throw HomeChangeError(.refused, "Apple Home did not create the room \(name)") }
            try home.layout.update { layout in layout.link(layout.room(named: name) ?? name, to: id) }
            return id
        }
        /// The name of the Room of this id, for a change that names it so.
        func roomName(_ id: String) -> String? { home.layout.value.room(id: id)?.name }
        func zoneHomeKitID(_ id: String) -> String? { file.zones.first { $0.id == id }?.homeKitID }
        func groupHomeKitID(_ id: String) -> String? { wallGroups.first { $0.id == id }?.homeKitID }
        func checkGroup(_ members: [String], in snapshot: HomeSnapshot) throws {
            guard members.count >= 2, Set(members).count == members.count else {
                throw HomeChangeError(.refused, "A group needs at least two different accessories")
            }
            guard members.allSatisfy({ snapshot.placements[$0] != nil }) else {
                throw HomeChangeError(.notFound, "An accessory of the group is no longer in Apple Home")
            }
            if let problem = groupProblem(members: members) { throw HomeChangeError(.refused, problem) }
            guard Self.canGroup(members.compactMap { find(id: $0)?.accessory }) else {
                throw HomeChangeError(.refused, "The group's accessories no longer share a control")
            }
        }
        switch change {
        case .createRoom(let name):
            _ = try await roomID(name)
        case .renameRoom(let from, let to):
            // Renamed here already: the Room kept its link under its new name.
            let layout = home.layout.value
            guard let id = layout.homeKitID(ofRoom: to) ?? layout.homeKitID(ofRoom: from) else { _ = try await roomID(to); return }
            _ = try await plugin.applyHomeChange(.renameRoom(id: id, name: to))
        case .deleteRoom(let name, let homeKitID):
            guard let id = homeKitID ?? home.layout.value.homeKitID(ofRoom: name) else { return }
            _ = try await plugin.applyHomeChange(.deleteRoom(id: id))
        case .moveAccessory(let accessory, let room):
            _ = try await plugin.applyHomeChange(.moveAccessory(accessoryID: accessory, roomID: room.isEmpty ? nil : try await roomID(room)))
        case .createZone(let zone):
            guard let local = file.zones.first(where: { $0.id == zone }), local.homeKitID == nil else { return }
            let id = try await plugin.applyHomeChange(.createZone(name: local.name))
            guard let id else { throw HomeChangeError(.refused, "Apple Home did not create the zone \(local.name)") }
            var rooms: [String] = []
            for name in local.rooms.compactMap(roomName) { rooms.append(try await roomID(name)) }
            if !rooms.isEmpty { _ = try await plugin.applyHomeChange(.setZoneRooms(id: id, add: rooms, remove: [])) }
            try home.homeLink.update { file in
                if let index = file.zones.firstIndex(where: { $0.id == local.id }) { file.zones[index].homeKitID = id }
            }
        case .renameZone(let zone, let name):
            guard let id = zoneHomeKitID(zone) else { return }
            _ = try await plugin.applyHomeChange(.renameZone(id: id, name: name))
        case .deleteZone(let id):
            _ = try await plugin.applyHomeChange(.deleteZone(id: id))
        case .setZoneRooms(let zone, let add, let remove):
            guard let id = zoneHomeKitID(zone) else { return }
            var added: [String] = []
            for name in add.compactMap(roomName) { added.append(try await roomID(name)) }
            let layout = home.layout.value
            _ = try await plugin.applyHomeChange(.setZoneRooms(id: id, add: added, remove: remove.compactMap { layout.room(id: $0)?.homeKitID }))
        case .createGroup(let group):
            let groups = wallGroups
            guard let local = groups.first(where: { $0.id == group }), local.homeKitID == nil else { return }
            guard let snapshot = await plugin.homeSnapshot() else { throw HomeChangeError(.unreachable, "Apple Home is not reachable") }
            try checkGroup(local.members, in: snapshot)
            let id: String
            // Apple Home refuses a second group of a name (HMErrorDomain 13), and the Home app hides one of fewer than
            // two accessories, which an earlier attempt can leave: one of that name no other wall group has is this one.
            let linked = Set(groups.compactMap(\.homeKitID))
            if let existing = snapshot.groups.first(where: { !linked.contains($0.id) && Self.sameRoomName($0.name, local.name) }) {
                id = existing.id
                let add = local.members.filter { !existing.members.contains($0) }, remove = existing.members.filter { !local.members.contains($0) }
                if !add.isEmpty || !remove.isEmpty { _ = try await plugin.applyHomeChange(.setGroupMembers(id: id, add: add, remove: remove)) }
                if existing.name != local.name { _ = try await plugin.applyHomeChange(.renameGroup(id: id, name: local.name)) }
            } else {
                guard let created = try await plugin.applyHomeChange(.createGroup(name: local.name, members: local.members)) else {
                    throw HomeChangeError(.refused, "Apple Home did not create the group \(local.name)")
                }
                id = created
            }
            try setWallGroups(groups.map { one in
                var one = one
                if one.id == local.id { one.homeKitID = id }
                return one
            })
        case .renameGroup(let group, let name):
            guard let id = groupHomeKitID(group) else { throw HomeChangeError(.notFound, "The group is no longer linked to Apple Home") }
            _ = try await plugin.applyHomeChange(.renameGroup(id: id, name: name))
        case .deleteGroup(let id):
            _ = try await plugin.applyHomeChange(.deleteGroup(id: id))
        case .setGroupMembers(let group, let add, let remove):
            guard let id = groupHomeKitID(group) else { throw HomeChangeError(.notFound, "The group is no longer linked to Apple Home") }
            guard let snapshot = await plugin.homeSnapshot() else { throw HomeChangeError(.unreachable, "Apple Home is not reachable") }
            guard let remote = snapshot.groups.first(where: { $0.id == id }) else { throw HomeChangeError(.notFound, "The group is no longer in Apple Home") }
            let members = remote.members.filter { !remove.contains($0) } + add.filter { !remote.members.contains($0) }
            try checkGroup(members, in: snapshot)
            _ = try await plugin.applyHomeChange(.setGroupMembers(id: id, add: add, remove: remove))
        }
    }

    // MARK: The first link

    /// What linking the bridge to this Home would change.
    func compareWithHome(_ snapshot: HomeSnapshot) async -> HomeLinkFile.Comparison {
        withLookup {
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
                placements.append(.init(accessory: accessoryID, name: found.accessory.name, here: here, home: there, result: there.isEmpty ? here : there))
            }
            var ungrouped: [HomeLinkFile.Comparison.Group] = [], created: [HomeLinkFile.Comparison.Group] = []
            for group in wallGroups where group.homeKitID == nil {
                let entry = HomeLinkFile.Comparison.Group(id: group.id, name: group.name)
                if groupProblem(members: group.members) == nil { created.append(entry) } else { ungrouped.append(entry) }
            }
            return .init(
                homeID: snapshot.homeID, homeName: snapshot.homeName, roomsOnlyHere: onlyHere, roomsOnlyInHome: onlyInHome,
                accessories: placements, groupsUngrouped: ungrouped, groupsCreated: created, clashes: clashes)
        }
    }

    /// Confirms the first link that waits (`compareWithHome`): the bridge's own Rooms and Groups made in Apple Home,
    /// Apple Home's taken, each accessory where the comparison said. Answers `homeLinkJSON()`.
    public func confirmHomeLink(by who: String) async throws -> JSONValue {
        let link = try await home.homeLinkWork.run { [self] () -> HomeLinkPlugin in
            guard let link = await host.homeLink(), link.state.isUp, let snapshot = await link.plugin.homeSnapshot() else {
                throw CatalogError("Apple Home is not reachable: the Home Link is down")
            }
            if let refusal = Self.refusal(link.state) { throw CatalogError(refusal) }
            let comparison = await compareWithHome(snapshot)
            guard comparison.clashes.isEmpty else {
                throw CatalogError("Rename one of \(comparison.clashes.map { $0.joined(separator: " and ") }.joined(separator: "; ")) first: Apple Home would take them for one room")
            }
            try await linkHome(snapshot, comparison: comparison, link: link)
            logger.info("Linked to Apple Home's \(snapshot.homeName)", metadata: ["by": "\(who)"])
            if let fresh = await link.plugin.homeSnapshot() { try await adopt(fresh) }
            home.layoutChanged()
            return link
        }
        return homeLinkJSON(link: link)
    }

    /// Links the bridge to the Home as `comparison` says: its Rooms, Zones and Groups Apple Home lacks are made there, its
    /// Rooms and Apple Home's of the same name linked, the accessories in No Room there that have a Room here moved there,
    /// and the groups Apple Home cannot have ungrouped.
    private func linkHome(_ snapshot: HomeSnapshot, comparison: HomeLinkFile.Comparison, link: HomeLinkPlugin) async throws {
        let ungrouped = Set(comparison.groupsUngrouped.map(\.id))
        let groups = wallGroups.filter { !ungrouped.contains($0.id) }
        var changes: [HomeLinkFile.PendingChange] = comparison.roomsOnlyHere.map { .createRoom(name: $0) }
        changes += comparison.accessories.filter { $0.home.isEmpty }.map { .moveAccessory(accessory: $0.accessory, room: $0.here) }
        changes += groups.filter { $0.homeKitID == nil }.map { .createGroup(group: $0.id) }
        changes += home.homeLink.value.zones.filter { $0.homeKitID == nil }.map { .createZone(zone: $0.id) }
        if !ungrouped.isEmpty { try setWallGroups(groups) }
        // The Rooms and Apple Home's of the same name are one; the others are linked once made there.
        try home.layout.update { layout in
            for index in layout.roomEntries.indices {
                let name = layout.roomEntries[index].name
                layout.roomEntries[index].homeKitID = snapshot.rooms.first { Self.sameRoomName($0.name, name) }?.id
            }
        }
        try home.homeLink.update { file in
            if file.homeID != snapshot.homeID { file.refused = [] }
            file.homeID = snapshot.homeID
            file.homeName = snapshot.homeName
            file.comparison = nil
            file.pending = changes + file.pending
        }
        if link.state.canEdit { await replayPending(link: link) }
    }

    // MARK: Groups

    /// Why Apple Home would not group these accessories, or nil: the Home app groups accessories of one kind, each with
    /// one grouping Function (possibly a primary light with associated controls), every one in Apple Home.
    func groupProblem(members: [String]) -> String? {
        let found = members.compactMap(find(id:))
        guard found.count == members.count else { return "an accessory of the group is not on the bridge" }
        var kinds = Set<String>()
        for located in found {
            guard let function = Self.groupingFunction(located.accessory) else {
                return "\(located.accessory.name) does more than one thing: separate its Functions to group it"
            }
            if isInHome(located.accessory.id) == false || located.bridge.server.isHiddenFromHomeKit(located.accessory.id) {
                return "\(located.accessory.name) is not in Apple Home"
            }
            kinds.insert(function.type.uuid.uuidString)
        }
        return kinds.count > 1 ? "Apple Home groups accessories of one kind only" : nil
    }
}
