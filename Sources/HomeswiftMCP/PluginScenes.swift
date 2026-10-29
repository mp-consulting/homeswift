import Foundation
import Homeswift
import HomeswiftPlugin

// The scenes plugins' hubs keep (`HomeswiftPlugin.scenes()`), listed with Homeswift's own and run like them. Their id
// is `<platform>:<instance name>:<hub id>`; the hub keeps them, Homeswift asks again each time. A recall goes through
// `holdLightChanges`, so the lights it changed can be put back as after any scene. docs/scenes-design.md.

/// A plugin scene with the instance it comes from.
struct FoundPluginScene: Sendable {
    let instance: PluginHost.PlatformInstance
    let scene: PluginScene

    var id: String { HomeswiftCatalog.pluginSceneID(platform: instance.platform, name: instance.name, scene: scene.id) }
}

extension HomeswiftCatalog {
    static func pluginSceneID(platform: String, name: String, scene: String) -> String { "\(platform):\(name):\(scene)" }

    func foundPluginScenes() async -> [FoundPluginScene] {
        await host.pluginScenes().flatMap { entry in entry.scenes.map { FoundPluginScene(instance: entry.instance, scene: $0) } }
    }

    /// The plugin scene with this id, or the only one with this name (case aside).
    func pluginScene(_ reference: String) async -> FoundPluginScene? {
        let all = await foundPluginScenes()
        if let exact = all.first(where: { $0.id == reference }) { return exact }
        let named = all.filter { $0.scene.name.caseInsensitiveCompare(reference) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    /// The room of these accessories when they share one.
    func sharedRoom(of ids: some Sequence<String>) -> String? {
        let rooms = Set(Set(ids).map { find(id: $0)?.room })
        guard rooms.count == 1, let room = rooms.first else { return nil }
        return room
    }

    /// The Homeswift room a plugin scene sits in: its accessories' room, else the room named as the hub's room or zone.
    func room(of found: FoundPluginScene, rooms: [String]) -> String? {
        if !found.scene.accessoryIDs.isEmpty, let room = sharedRoom(of: found.scene.accessoryIDs) { return room }
        guard let hubRoom = found.scene.room else { return nil }
        return rooms.first { $0.compare(hubRoom, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func pluginSceneJSON(_ found: FoundPluginScene, rooms: [String]) -> JSONValue {
        let entry = host.registry.entry(for: found.instance.platform)
        var object: [String: JSONValue] = [
            "id": .string(found.id), "name": .string(found.scene.name),
            "room": room(of: found, rooms: rooms).map(JSONValue.string) ?? .null,
            "hubRoom": found.scene.room.map(JSONValue.string) ?? .null,
            "active": found.scene.active.map(JSONValue.bool) ?? .null,
            "colours": .array(found.scene.colours.prefix(5).map(JSONValue.string)),
            "capabilities": .array(PluginScene.Capability.allCases.filter(found.scene.capabilities.contains).map { .string($0.rawValue) }),
            "source": [
                "platform": .string(found.instance.platform), "name": .string(found.instance.name),
                "pluginName": .string(found.instance.pluginName), "icon": entry?.icon.map(JSONValue.string) ?? .null,
            ],
        ]
        if let artwork = SceneArtwork.matching(name: found.scene.name) { object["artworkId"] = .string(artwork.id) }
        return .object(object)
    }

    /// What the Scenes page and list_scenes show: Homeswift's scenes, then those of the plugins' hubs.
    public func allScenesJSON(now: Date = Date()) async -> JSONValue {
        guard var answer = scenesJSON(now: now).objectValue else { return scenesJSON(now: now) }
        let rooms = Array(Set(located().compactMap(\.room))).sorted()
        answer["pluginScenes"] = .array(await foundPluginScenes().map { pluginSceneJSON($0, rooms: rooms) })
        return .object(answer)
    }

    /// Recalls a plugin scene; the lights it changed are held, so stopping it puts them back.
    func runPluginScene(_ found: FoundPluginScene, by: String) async throws -> JSONValue {
        guard found.scene.capabilities.contains(.recall) else { throw CatalogError("\(found.scene.name) cannot be recalled from Homeswift") }
        let held = try await holdLightChanges(found.scene.name, platform: found.instance, by: by) {
            try await host.recallScene(platform: found.instance.platform, name: found.instance.name, id: found.scene.id)
            return true
        }
        logger.info("Scene \"\(found.scene.name)\" recalled on \(found.instance.name)", metadata: ["by": "\(by)"])
        var answer: [String: JSONValue] = ["sceneId": .string(found.id), "name": .string(found.scene.name), "ok": true, "results": []]
        if let held { answer["run"] = .string(held.id) }
        return .object(answer)
    }
}
