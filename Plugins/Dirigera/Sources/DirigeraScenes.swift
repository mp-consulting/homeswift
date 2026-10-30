import Foundation
import HomeswiftPlugin

extension DirigeraPlugin {
    /// The hubs' user scenes for Homeswift's Scenes page, as the HomeKit switches show them (`excludeScenes` leaves
    /// some out). The hub puts a scene in no room and does not say whether it is active. The id is the hub's (a UUID,
    /// unique across hubs), as the page's pictures are keyed. A scene the hub runs on its own schedule (a wake-up) is
    /// listed but neither run nor changed.
    public func scenes() async -> [PluginScene] {
        hubs.keys.sorted().flatMap { host in
            hubs[host].map { hub in
                visibleScenes(hub).map { scene in
                    PluginScene(
                        id: scene.id, name: scene.name, accessoryIDs: scene.deviceIDs.map { Self.accessoryID(deviceID: $0) },
                        capabilities: scene.isRunnable ? [.recall, .rename, .update, .delete] : [])
                }
            } ?? []
        }
    }

    public func recallScene(id: String) async throws {
        guard let host = host(ofScene: id) else { throw PluginSceneError("no such scene") }
        try await trigger(host: host, sceneID: id)
    }

    /// The hub that keeps this scene.
    func host(ofScene id: String) -> String? {
        hubs.keys.sorted().first { hubs[$0]?.scenes.contains { $0.id == id } == true }
    }

    // MARK: Writing (lpgera/dirigera's scenes API)

    /// The hub's device id of one of this plugin's accessories (`accessoryID(deviceID:)` the other way).
    static func deviceID(ofAccessory id: String) -> String {
        let prefix = "\(platform):"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// The hub whose lights these all are.
    func sceneHub(accessoryIDs: [String]) -> Hub? {
        let ids = accessoryIDs.map(Self.deviceID(ofAccessory:))
        guard !ids.isEmpty else { return nil }
        return hubs.keys.sorted().compactMap { hubs[$0] }.first { hub in ids.allSatisfy { hub.devices[$0]?.kind == .light } }
    }

    public func sceneTarget(accessoryIDs: [String]) async -> String? {
        sceneHub(accessoryIDs: accessoryIDs).map { "DIRIGERA \($0.host)" }
    }

    /// A user scene the person runs from the app (an `app` trigger), with the heart icon.
    public func createScene(name: String, lights: [PluginSceneLight]) async throws -> String {
        guard let hub = sceneHub(accessoryIDs: lights.map(\.accessoryID)) else { throw PluginSceneError("no DIRIGERA hub has all these lights") }
        let id = try await hub.client.createScene([
            "info": ["name": .string(Self.sceneName(name)), "icon": "scenes_heart"], "type": "userScene",
            "actions": .array(Self.sceneActions(lights)), "triggers": [["type": "app"]],
        ])
        await refresh(hub)
        return id
    }

    /// A scene Homeswift may change (not one the hub runs on its own schedule), with its hub.
    private func writableScene(_ id: String) throws -> (Hub, DirigeraScene) {
        guard let host = host(ofScene: id), let hub = hubs[host], let scene = hub.scenes.first(where: { $0.id == id }), scene.isRunnable else {
            throw PluginSceneError("no such scene")
        }
        return (hub, scene)
    }

    public func updateScene(id: String, name: String?, lights: [PluginSceneLight]?) async throws {
        let (hub, scene) = try writableScene(id)
        if let lights, sceneHub(accessoryIDs: lights.map(\.accessoryID)) !== hub { throw PluginSceneError("the scene's hub does not have all these lights") }
        try await hub.client.updateScene(id: id, [
            "info": ["name": .string(name.map(Self.sceneName) ?? scene.name), "icon": .string(scene.icon ?? "scenes_heart")], "type": .string(scene.type),
            "actions": lights.map { .array(Self.sceneActions($0)) } ?? scene.actions, "triggers": scene.triggers,
        ])
        await refresh(hub)
    }

    public func deleteScene(id: String) async throws {
        let (hub, _) = try writableScene(id)
        try await hub.client.deleteScene(id: id)
        await refresh(hub)
    }

    static func sceneName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespaces).prefix(64)) }

    /// Each light's `device` action: on, level (1 to 100), a colour (saturation 0 to 1) or a white in kelvin.
    static func sceneActions(_ lights: [PluginSceneLight]) -> [JSONValue] {
        lights.map { light in
            var attributes: [String: JSONValue] = ["isOn": .bool(light.on)]
            if light.on {
                if let level = light.brightness { attributes.merge(DirigeraLightCommands.level(level)) { $1 } }
                if light.hasColour, let hue = light.hue, let saturation = light.saturation {
                    attributes.merge(DirigeraLightCommands.colour(hue: hue, saturation: saturation)) { $1 }
                } else if let mirek = light.colorTemperature, mirek > 0 {
                    attributes.merge(DirigeraLightCommands.white(mirek: mirek)) { $1 }
                }
            }
            return ["type": "device", "deviceId": .string(deviceID(ofAccessory: light.accessoryID)), "attributes": .object(attributes)]
        }
    }
}
