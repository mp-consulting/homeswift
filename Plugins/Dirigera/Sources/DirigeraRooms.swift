import Foundation
import HomeswiftPlugin

// The hubs' rooms, renamed when a room of the same name is renamed in Homeswift (`syncRoomNames`): lpgera/dirigera's
// rooms API.
extension DirigeraPlugin {
    /// Every connected hub's rooms, asked now. The id names the hub too (`<room id>@<hub>`): several hubs may be set up.
    public func rooms() async -> [PluginRoom] {
        var found: [PluginRoom] = []
        for host in hubs.keys.sorted() {
            guard let hub = hubs[host], await hub.client.token != nil else { continue }
            do {
                for room in try await hub.client.rooms() {
                    guard let id = room["id"]?.stringValue, let name = room["name"]?.stringValue else { continue }
                    found.append(PluginRoom(id: "\(id)@\(host)", name: name, place: hubs.count > 1 ? "DIRIGERA \(host)" : nil))
                }
            } catch {
                logger.warning("The DIRIGERA hub at \(host) did not list its rooms: \(error)")
            }
        }
        return found
    }

    /// The room keeps its icon and colour, which the hub wants with the name.
    public func renameRoom(id: String, name: String) async throws {
        guard let at = id.firstIndex(of: "@"), let hub = hubs[String(id[id.index(after: at)...])] else { throw PluginRoomError("no such room") }
        let roomID = String(id[..<at])
        guard let room = try await hub.client.rooms().first(where: { $0["id"]?.stringValue == roomID }) else { throw PluginRoomError("no such room") }
        var body: [String: JSONValue] = ["name": .string(Self.roomName(name))]
        if let icon = room["icon"], !icon.isNull { body["icon"] = icon }
        if let color = room["color"], !color.isNull { body["color"] = color }
        try await hub.client.updateRoom(id: roomID, .object(body))
        await refresh(hub)
    }

    static func roomName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespaces).prefix(64)) }
}
