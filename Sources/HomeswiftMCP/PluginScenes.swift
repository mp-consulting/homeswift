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

    /// The plugin scene with this id, or the only one with this name (case aside). An id asks only the instance it
    /// names.
    func pluginScene(_ reference: String) async -> FoundPluginScene? {
        for instance in host.runningInstanceNames() where reference.hasPrefix(Self.pluginSceneID(platform: instance.platform, name: instance.name, scene: "")) {
            guard let entry = await host.pluginScenes(platform: instance.platform, name: instance.name),
                  let scene = entry.scenes.first(where: { Self.pluginSceneID(platform: instance.platform, name: instance.name, scene: $0.id) == reference }) else { continue }
            return FoundPluginScene(instance: entry.instance, scene: scene)
        }
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

    func pluginSceneJSON(_ found: FoundPluginScene, rooms: [String], pictures: [String: String]) -> JSONValue {
        let entry = host.registry.entry(for: found.instance.platform)
        var object: [String: JSONValue] = [
            "id": .string(found.id), "name": .string(found.scene.name),
            "room": room(of: found, rooms: rooms).map(JSONValue.string) ?? .null,
            "hubRoom": found.scene.room.map(JSONValue.string) ?? .null,
            "active": found.scene.active.map(JSONValue.bool) ?? .null,
            "colours": .array(found.scene.colours.prefix(5).map(JSONValue.string)),
            "picture": pictures[found.id].map(JSONValue.string) ?? .null,
            "accessoryIds": .array(found.scene.accessoryIDs.map(JSONValue.string)),
            "stoppable": .bool(!lightRuns(of: found.id).isEmpty),
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
        await withLookup { await allScenesJSONIndexed(now: now) }
    }

    private func allScenesJSONIndexed(now: Date) async -> JSONValue {
        // The hubs are asked while the saved scenes are described.
        async let asked = foundPluginScenes()
        var answer = scenesObject(now: now)
        let found = await asked
        let rooms = found.contains { $0.scene.room != nil } ? Array(Set((Self.lookup.map { Array($0.values) } ?? located()).compactMap(\.room))).sorted() : []
        let pictures = scenePictures.versions()
        answer["pluginScenes"] = .array(found.map { pluginSceneJSON($0, rooms: rooms, pictures: pictures) })
        let names = Dictionary(found.map { ($0.id, $0.scene.name) }, uniquingKeysWith: { first, _ in first })
        answer["scenes"] = answer["scenes"]?.arrayValue.map { scenes in
            .array(scenes.map { scene in
                guard var object = scene.objectValue, let actions = object["actions"]?.arrayValue else { return scene }
                object["actions"] = .array(actions.map { action in
                    guard var entry = action.objectValue, let recall = entry["recall"]?.stringValue else { return action }
                    if let name = names[recall] { entry["name"] = .string(name) } else { entry["missing"] = true }
                    return .object(entry)
                })
                return .object(object)
            })
        }
        return .object(answer)
    }

    /// Recalls a plugin scene; the lights it changed are held under `holdAs` (a scene that recalls it), else under its
    /// own id, so `stopScene` puts them back.
    func runPluginScene(_ found: FoundPluginScene, by: String, holdAs: String? = nil) async throws -> JSONValue {
        guard found.scene.capabilities.contains(.recall) else { throw CatalogError("\(found.scene.name) cannot be recalled from Homeswift") }
        let held = try await holdLightChanges(found.scene.name, id: Self.showID(of: holdAs ?? found.id), platform: found.instance, by: by) {
            try await host.recallScene(platform: found.instance.platform, name: found.instance.name, id: found.scene.id)
            return true
        }
        logger.info("Scene \"\(found.scene.name)\" recalled on \(found.instance.name)", metadata: ["by": "\(by)"])
        var answer: [String: JSONValue] = ["sceneId": .string(found.id), "name": .string(found.scene.name), "ok": true, "results": []]
        if let held { answer["run"] = .string(held.id) }
        return .object(answer)
    }
}
