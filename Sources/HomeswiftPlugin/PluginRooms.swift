import Foundation

/// A room a plugin's hub or cloud keeps (a Hue Bridge's room, a DIRIGERA hub's, an eWeLink home's), listed by
/// `HomeswiftPlugin.rooms()` so a room renamed in Homeswift is renamed there too when `syncRoomNames` is on: Homeswift
/// renames, with `HomeswiftPlugin.renameRoom(id:name:)`, the hub rooms named as the room was (case and accents aside).
/// A hub that learns of its own renames (Wingman, from the Home app) tells Homeswift with `PluginContext.hubRoomRenamed`,
/// which renames Homeswift's room too; on the others a room renamed on the hub stays as Homeswift has it.
///
/// ```swift
/// func rooms() async -> [PluginRoom] {
///     (try? await hub.rooms())?.map { PluginRoom(id: $0.id, name: $0.name) } ?? []
/// }
///
/// func renameRoom(id: String, name: String) async throws {
///     try await hub.renameRoom(id, to: name)
/// }
/// ```
public struct PluginRoom: Sendable, Equatable {
    /// The hub's own id, unique within the plugin instance.
    public var id: String
    public var name: String
    /// Where the room is when the instance has several hubs or homes ("DIRIGERA 192.168.1.20", "Home"), for the log.
    public var place: String?

    public init(id: String, name: String, place: String? = nil) {
        self.id = id
        self.name = name
        self.place = place
    }
}

extension HomeswiftPlugin {
    public func rooms() async -> [PluginRoom] { [] }

    public func renameRoom(id: String, name: String) async throws {
        throw PluginRoomError("\(Self.name) cannot rename rooms")
    }
}

public struct PluginRoomError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension PluginHost {
    /// The rooms of a running plugin instance, with the instance they come from.
    public struct InstanceRooms: Sendable {
        public let instance: PlatformInstance
        public let rooms: [PluginRoom]
    }

    /// Every running instance's rooms (`HomeswiftPlugin.rooms()`), asked at the same time; paused instances and those
    /// with none are left out.
    public func pluginRooms() async -> [InstanceRooms] {
        let running = runningPlugins()
        return await withTaskGroup(of: (Int, InstanceRooms?).self) { group in
            for (index, (instance, plugin)) in running.enumerated() {
                group.addTask {
                    let rooms = await plugin.rooms()
                    return (index, rooms.isEmpty ? nil : InstanceRooms(instance: instance.described, rooms: rooms))
                }
            }
            var found: [(Int, InstanceRooms)] = []
            for await (index, rooms) in group { if let rooms { found.append((index, rooms)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Renames a room of the instance `name` of `platform` (`HomeswiftPlugin.renameRoom(id:name:)`).
    public func renameRoom(platform: String, name: String, id: String, to roomName: String) async throws {
        guard let running = runningPlugins().first(where: { $0.instance.context.platform == platform && $0.instance.context.name == name }) else {
            throw PluginRoomError("\(name) is not running")
        }
        try await running.plugin.renameRoom(id: id, name: roomName)
    }
}
