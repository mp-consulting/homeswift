import Foundation
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The bridge's scenes for Homeswift's Scenes page, by room or zone, as the HomeKit switches show them
    /// (`excludeScenes` leaves some out); the `scenes` option only chooses whether HomeKit gets switches. A scene can
    /// be renamed, changed and removed from Homeswift; a smart scene, which follows the time of day, only recalled.
    public func scenes() async -> [PluginScene] {
        snapshot.groups.flatMap { group in
            visibleScenes(of: group).map { scene in
                PluginScene(
                    id: scene.id, name: scene.name, room: group.name, accessoryIDs: scene.lightIDs.map { Self.accessoryID(lightID: $0) },
                    active: scene.active, colours: Self.swatches(scene), capabilities: scene.smart ? [.recall] : [.recall, .rename, .update, .delete])
            }
        }
    }

    /// Recalls a scene as its switch does: with its transition, playing when `dynamicScenes` says so.
    public func recallScene(id: String) async throws {
        try await recall(sceneID: id)
    }

    // MARK: Writing

    /// The room or zone a new scene of exactly these lights goes in: one that holds them all, the one that holds just
    /// them first, then the smallest, a room before a zone.
    func sceneGroup(accessoryIDs: [String]) -> HueGroup? {
        let prefix = "\(Self.platform):"
        let wanted = Set(accessoryIDs.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 })
        let known = Set(snapshot.lights.map(\.id))
        guard !wanted.isEmpty, wanted.isSubset(of: known) else { return nil }
        return snapshot.groups.filter { wanted.isSubset(of: Set($0.lightIDs)) }
            .min { ($0.lightIDs.count, $0.kind == "room" ? 0 : 1, $0.name) < ($1.lightIDs.count, $1.kind == "room" ? 0 : 1, $1.name) }
    }

    public func sceneTarget(accessoryIDs: [String]) async -> String? {
        sceneGroup(accessoryIDs: accessoryIDs)?.name
    }

    /// A scene in the room or zone that holds the lights (`sceneGroup`), named at most 32 characters as the bridge takes.
    public func createScene(name: String, lights: [PluginSceneLight]) async throws -> String {
        guard let client else { throw PluginSceneError("the Hue Bridge is not paired") }
        guard let group = sceneGroup(accessoryIDs: lights.map(\.accessoryID)) else { throw PluginSceneError("no room or zone of the Hue Bridge holds these lights") }
        let id = try await client.post("scene", [
            "metadata": ["name": .string(Self.sceneName(name))], "group": ["rid": .string(group.id), "rtype": .string(group.kind)],
            "actions": .array(try sceneActions(lights)),
        ])
        await refresh()
        return id
    }

    public func updateScene(id: String, name: String?, lights: [PluginSceneLight]?) async throws {
        guard let client else { throw PluginSceneError("the Hue Bridge is not paired") }
        guard let scene = snapshot.scenes.first(where: { $0.id == id }), !scene.smart else { throw PluginSceneError("no such scene") }
        var body: [String: JSONValue] = [:]
        if let name { body["metadata"] = ["name": .string(Self.sceneName(name))] }
        if let lights { body["actions"] = .array(try sceneActions(lights)) }
        try await client.put("scene", id: id, .object(body))
        await refresh()
    }

    public func deleteScene(id: String) async throws {
        guard let client else { throw PluginSceneError("the Hue Bridge is not paired") }
        guard let scene = snapshot.scenes.first(where: { $0.id == id }), !scene.smart else { throw PluginSceneError("no such scene") }
        try await client.delete("scene", id: id)
        await refresh()
    }

    static func sceneName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespaces).prefix(32)) }

    /// A scene's actions: each light's on, brightness (no lower than it goes), colour in its gamut or white in its range.
    func sceneActions(_ lights: [PluginSceneLight]) throws -> [JSONValue] {
        let prefix = "\(Self.platform):"
        return try lights.map { light in
            let lightID = light.accessoryID.hasPrefix(prefix) ? String(light.accessoryID.dropFirst(prefix.count)) : light.accessoryID
            guard let known = snapshot.lights.first(where: { $0.id == lightID }) else { throw PluginSceneError("the Hue Bridge has no light \(light.accessoryID)") }
            var action: [String: JSONValue] = ["on": ["on": .bool(light.on)]]
            if light.on {
                if let level = light.brightness, known.dims { action["dimming"] = ["brightness": .number(max(known.minimumBrightness, level))] }
                if light.hasColour, let hue = light.hue, let saturation = light.saturation, known.hasColour {
                    let point = HueColor.xy(hue: hue, saturation: saturation, gamut: known.gamut ?? .c)
                    action["color"] = ["xy": ["x": .number(point.x), "y": .number(point.y)]]
                } else if let mirek = light.colorTemperature, let range = known.mirekRange {
                    action["color_temperature"] = ["mirek": .number(Double(min(range.upperBound, max(range.lowerBound, mirek))))]
                }
            }
            return ["target": ["rid": .string(lightID), "rtype": "light"], "action": .object(action)]
        }
    }
}
