import Foundation
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The bridge's rooms (not its zones, which cross rooms), for Homeswift to rename the one named like a room renamed
    /// there (`syncRoomNames`).
    public func rooms() async -> [PluginRoom] {
        guard client != nil else { return [] }
        return snapshot.groups.filter { $0.kind == "room" }.map { PluginRoom(id: $0.id, name: $0.name) }
    }

    /// `PUT /clip/v2/resource/room/<id>` with its `metadata.name`, at most 32 characters as the bridge takes; the room
    /// keeps its archetype.
    public func renameRoom(id: String, name: String) async throws {
        guard let client else { throw PluginRoomError("the Hue Bridge is not paired") }
        guard snapshot.groups.contains(where: { $0.id == id && $0.kind == "room" }) else { throw PluginRoomError("no such room") }
        try await client.put("room", id: id, ["metadata": ["name": .string(Self.roomName(name))]])
        await refresh()
    }

    static func roomName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespaces).prefix(32)) }
}
