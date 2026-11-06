import Foundation

// The Home Link (GLOSSARY.md, "Home Link"; docs/adr/0005-apple-home-owns-rooms-zones-and-groups.md): the plugin that
// reaches the Home (Wingman, through the Home app) gives Homeswift the Home's Rooms, Zones, Groups and where each of
// Homeswift's accessories is, as one snapshot, and makes the changes Homeswift asks for. Homeswift keeps a copy, so a
// person can still put accessories in Rooms while the link is down; what changed meanwhile reaches Apple Home when it
// is back up.
//
// ```swift
// func homeLinkState() async -> HomeLinkState? { link.isUp ? (link.canEdit ? .up : .readOnly("…")) : .down("…") }
// func homeSnapshot() async -> HomeSnapshot? { link.snapshot }
// func applyHomeChange(_ change: HomeChange) async throws -> String? { try await link.apply(change) }
// ```
//
// A plugin that is no Home Link answers nil to `homeLinkState()`, the default. One that is tells Homeswift whenever
// its snapshot or its state changed (`PluginContext.homeChanged()`), for a change made in the Home app or the link
// coming up or going down.

/// The Home as the Home Link last saw it. Ids are the Home's own (HomeKit's); accessories are Homeswift's ids.
public struct HomeSnapshot: Sendable, Equatable {
    public struct Room: Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Zone: Sendable, Equatable {
        public var id: String
        public var name: String
        /// Its Rooms' ids.
        public var rooms: [String]

        public init(id: String, name: String, rooms: [String]) {
            self.id = id
            self.name = name
            self.rooms = rooms
        }
    }

    public struct Group: Sendable, Equatable {
        public var id: String
        public var name: String
        /// Its members Homeswift has, by Homeswift's accessory id.
        public var members: [String]

        public init(id: String, name: String, members: [String]) {
            self.id = id
            self.name = name
            self.members = members
        }
    }

    public var homeID: String
    public var homeName: String
    public var rooms: [Room]
    public var zones: [Zone]
    public var groups: [Group]
    /// The room id of every accessory of Homeswift's the Home has (mirrored ones and its own), nil for No Room (Apple
    /// Home's Default Room). One left out is not in the Home: Not in Home, or in another home.
    public var placements: [String: String?]

    public init(homeID: String, homeName: String, rooms: [Room], zones: [Zone] = [], groups: [Group] = [], placements: [String: String?]) {
        self.homeID = homeID
        self.homeName = homeName
        self.rooms = rooms
        self.zones = zones
        self.groups = groups
        self.placements = placements
    }

    public func room(_ id: String) -> Room? { rooms.first { $0.id == id } }
}

/// Whether the Home Link is up.
public enum HomeLinkState: Sendable, Equatable {
    /// Up: Homeswift's Rooms, Zones and Groups are the Home's, and a change on either side reaches the other.
    case up
    /// Up, but Apple Home does not let the bridge edit (the reason says what to turn on): its changes still reach
    /// Homeswift, Homeswift's own are refused.
    case readOnly(String)
    /// Down (the reason says why): Homeswift works on its copy, and keeps its changes as Pending Changes.
    case down(String)

    public var isUp: Bool { if case .down = self { false } else { true } }
    public var canEdit: Bool { self == .up }
}

/// A change Homeswift asks the Home Link to make, by the Home's ids.
public enum HomeChange: Sendable, Equatable {
    case createRoom(name: String)
    case renameRoom(id: String, name: String)
    case deleteRoom(id: String)
    /// To `roomID`, or to No Room (the Default Room) when nil.
    case moveAccessory(accessoryID: String, roomID: String?)
    case createZone(name: String)
    case renameZone(id: String, name: String)
    case deleteZone(id: String)
    case setZoneRooms(id: String, add: [String], remove: [String])
    case createGroup(name: String, members: [String])
    case renameGroup(id: String, name: String)
    case deleteGroup(id: String)
    case setGroupMembers(id: String, add: [String], remove: [String])
}

/// Why the Home Link did not make a change.
public struct HomeChangeError: Error, CustomStringConvertible, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Apple Home will not: not allowed, a name taken, an accessory it cannot group. Not tried again.
        case refused
        /// The link is down: kept as a Pending Change.
        case unreachable
        /// What it names is no longer in the Home.
        case notFound
    }

    public let kind: Kind
    public let description: String

    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }
}

extension HomeswiftPlugin {
    /// nil: this plugin is no Home Link.
    public func homeLinkState() async -> HomeLinkState? { nil }

    /// The Home as the link last saw it; nil while it has not seen it.
    public func homeSnapshot() async -> HomeSnapshot? { nil }

    /// Makes the change in the Home; answers the id of what it created (a room, a zone, a group).
    public func applyHomeChange(_ change: HomeChange) async throws -> String? {
        throw HomeChangeError(.refused, "\(Self.name) is no Home Link")
    }
}

extension PluginHost {
    /// The running plugin that is the Home Link, one that is up first, with its state; nil when none runs. The one
    /// that answered last is asked first: only a Home Link plugin answers, and most bridges have one.
    public func homeLink() async -> (instance: PlatformInstance, state: HomeLinkState, plugin: any HomeswiftPlugin)? {
        let running = runningPlugins()
        let known = homeLinkKey.withLockedValue { $0 }
        if let known, let (instance, plugin) = running.first(where: { $0.instance.context.key == known }),
           let state = await plugin.homeLinkState(), state.isUp {
            return (instance.described, state, plugin)
        }
        var found: (instance: PlatformInstance, state: HomeLinkState, plugin: any HomeswiftPlugin, key: String)?
        for (instance, plugin) in running {
            guard let state = await plugin.homeLinkState() else { continue }
            if state.isUp {
                homeLinkKey.withLockedValue { $0 = instance.context.key }
                return (instance.described, state, plugin)
            }
            if found == nil { found = (instance.described, state, plugin, instance.context.key) }
        }
        homeLinkKey.withLockedValue { $0 = found?.key }
        return found.map { ($0.instance, $0.state, $0.plugin) }
    }
}
