import Foundation
import HomeswiftPlugin

// A room renamed in Homeswift, renamed on the plugins' hubs too when the layout's `syncRoomNames` is on: every hub room
// named as the room was, case and accents aside (as a hub scene's room is matched), takes the new name. The other way
// only for a hub that says so (`PluginContext.hubRoomRenamed`, Wingman for the Home app): `followHubRoomRename`. docs/ui.md,
// "Rooms on the hubs".

extension HomeswiftCatalog {
    /// Renames, on every running plugin's hub, the rooms named `from` (`HomeswiftPlugin.rooms()`); answers what each
    /// did: `{hub, name, room, from, to, renamed, error?}`. A hub that fails leaves the others to go on.
    func renameHubRooms(from: String, to: String, by: String) async -> [JSONValue] {
        let matching = await host.pluginRooms().flatMap { entry in
            entry.rooms.filter { Self.sameRoomName($0.name, from) && $0.name != to }.map { (instance: entry.instance, room: $0) }
        }
        return await withTaskGroup(of: (Int, JSONValue).self) { group in
            for (index, (instance, room)) in matching.enumerated() {
                group.addTask { [host, logger] in
                    var answer: [String: JSONValue] = [
                        "hub": .string(Self.hubID(instance)), "name": .string(instance.name), "room": .string(room.id),
                        "from": .string(room.name), "to": .string(to),
                    ]
                    if let place = room.place { answer["place"] = .string(place) }
                    let on = room.place.map { "\(instance.name) (\($0))" } ?? instance.name
                    do {
                        try await host.renameRoom(platform: instance.platform, name: instance.name, id: room.id, to: to)
                        answer["renamed"] = true
                        logger.info("Room \"\(room.name)\" renamed \"\(to)\" on \(on)", metadata: ["by": "\(by)"])
                    } catch {
                        answer["renamed"] = false
                        answer["error"] = .string("\(error)")
                        logger.warning("Room \"\(room.name)\" not renamed \"\(to)\" on \(on): \(error)", metadata: ["by": "\(by)"])
                    }
                    return (index, .object(answer))
                }
            }
            var done: [(Int, JSONValue)] = []
            for await result in group { done.append(result) }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// A room renamed on a plugin's hub (in the Home app, through Wingman), followed when `syncRoomNames` is on: the
    /// layout's room of the old name takes the new one, and so do the other hubs' (`updateLayout(_:by:)`). The hub that
    /// made it already has the new name, so nothing goes back to it. A layout without that room, or with a room of the
    /// new name already, is left as it is.
    func followHubRoomRename(on instance: PluginHost.PlatformInstance, from: String, to: String) async {
        guard home.layout.value.syncRoomNames == true, from != to,
              let room = home.layout.value.rooms.first(where: { Self.sameRoomName($0, from) }) else { return }
        do {
            _ = try await updateLayout(["renameRoom": ["from": .string(room), "to": .string(to)]], by: instance.name)
            logger.info("Room \"\(room)\" renamed \"\(to)\" as on \(instance.name)")
        } catch {
            logger.warning("Room \"\(room)\" not renamed \"\(to)\" as on \(instance.name): \(error)")
        }
    }

    /// Whether two room names are the same, case and accents aside.
    static func sameRoomName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
