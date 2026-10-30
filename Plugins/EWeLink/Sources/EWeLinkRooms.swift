import Foundation
import HomeswiftPlugin

// The account's rooms, renamed when a room of the same name is renamed in Homeswift (`syncRoomNames`).
extension EWeLinkPlugin {
    /// The rooms of every home of the account, asked now through the platform's session; none before it logged in.
    public func rooms() async -> [PluginRoom] {
        guard let api = await platformCore()?.api else { return [] }
        do {
            let rooms = try await api.rooms()
            let homes = Set(rooms.map(\.homeID))
            return rooms.map { PluginRoom(id: $0.id, name: $0.name, place: homes.count > 1 ? $0.home : nil) }
        } catch {
            context.logger.warning("eWeLink did not list the rooms: \(error)")
            return []
        }
    }

    public func renameRoom(id: String, name: String) async throws {
        guard let api = await platformCore()?.api else { throw PluginRoomError("not logged in to eWeLink yet") }
        try await api.renameRoom(id, name: String(name.trimmingCharacters(in: .whitespaces).prefix(64)))
    }
}
