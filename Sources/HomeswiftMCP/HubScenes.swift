import Foundation
import Homeswift
import HomeswiftPlugin

// Writing scenes to the hubs that keep them (a Hue Bridge, an IKEA hub): a new scene saved there instead of in
// Homeswift, a hub scene renamed, updated from its lights as they are or from a plan's values, or removed. The hub
// stays the scene's only keeper; Homeswift writes through and reads back. A hub scene keeps lights only: their On,
// Brightness, colour and white; triggers, animations, hub scenes to recall and other accessories are refused.
// docs/scenes-design.md, "Writing to hubs".

extension HomeswiftCatalog {
    /// The id of a hub that can keep scenes (`<platform>:<instance>`), as `save_scene`'s `hub` takes it.
    static func hubID(_ instance: PluginHost.PlatformInstance) -> String { "\(instance.platform):\(instance.name)" }

    /// The hubs that can keep a scene of exactly these lights: `{hub, name, label}`.
    public func hubTargets(accessoryIDs: [String]) async -> [JSONValue] {
        await host.sceneTargets(accessoryIDs: Array(Set(accessoryIDs)).sorted()).map { target in
            ["hub": .string(Self.hubID(target.instance)), "name": .string(target.instance.name), "label": .string(target.label)]
        }
    }

    /// The lights' states a hub scene would keep from these actions; anything a hub scene cannot keep is refused.
    func hubLights(from actions: [SceneAction]) throws -> [PluginSceneLight] {
        var order: [String] = []
        var lights: [String: PluginSceneLight] = [:]
        for action in actions {
            guard action.recall == nil else { throw CatalogError("A hub scene cannot recall another scene") }
            if lights[action.id] == nil {
                guard find(id: action.id) != nil else { throw CatalogError("No accessory \(action.id)") }
                order.append(action.id)
                lights[action.id] = PluginSceneLight(accessoryID: action.id, on: true)
            }
            let number = SceneRules.number(action.value)
            switch Self.normalized(action.characteristic) {
            case "on": lights[action.id]?.on = number.map { $0 != 0 } ?? true
            case "brightness": lights[action.id]?.brightness = number.map { min(100, max(0, $0)) }
            case "hue": lights[action.id]?.hue = number.map { min(360, max(0, $0)) }
            case "saturation": lights[action.id]?.saturation = number.map { min(100, max(0, $0)) }
            case "colortemperature": lights[action.id]?.colorTemperature = number.map { Int($0.rounded()) }
            default: throw CatalogError("A hub scene keeps only lights' On, Brightness, Hue, Saturation and Color Temperature, not \(action.characteristic)")
            }
        }
        guard !order.isEmpty else { throw CatalogError("A hub scene needs at least one light") }
        return order.compactMap { lights[$0] }
    }

    /// The lights' states now, for a hub scene updated "from the lights as they are".
    func currentHubLights(_ ids: [String]) throws -> [PluginSceneLight] {
        var actions: [SceneAction] = []
        for id in ids {
            guard let found = find(id: id) else { throw CatalogError("No accessory \(id)") }
            for name in ["On", "Brightness", "Hue", "Saturation", "Color Temperature"] {
                guard let target = try? characteristic(in: found, service: nil, characteristic: name) else { continue }
                actions.append(SceneAction(id: id, service: nil, characteristic: name, value: Self.json(target.value), recall: nil))
            }
        }
        return try hubLights(from: actions)
    }

    /// Saves a plan as a new scene on a hub (`hub`, from `hubTargets`); a dry run answers what would be kept there.
    public func saveHubScene(_ plan: JSONValue, name: String, hub: String, dryRun: Bool) async throws -> JSONValue {
        guard var object = plan.objectValue else { throw CatalogError("A plan is an object with actions") }
        object["name"] = .string(name)
        let scene = try planScene(.object(object))
        guard scene.animation == nil else { throw CatalogError("A hub scene cannot animate: save it in Homeswift") }
        let lights = try hubLights(from: scene.actions)
        let targets = await host.sceneTargets(accessoryIDs: lights.map(\.accessoryID))
        guard let target = targets.first(where: { Self.hubID($0.instance) == hub }) else {
            throw CatalogError("\(hub) cannot keep a scene of these lights" + (targets.isEmpty ? "" : "; it can be kept on \(targets.map { Self.hubID($0.instance) }.joined(separator: ", "))"))
        }
        if dryRun { return ["dryRun": true, "name": .string(scene.name), "hub": .string(hub), "where": .string(target.label), "lights": .array(lights.map(Self.lightJSON))] }
        let id = try await Self.onHub { try await host.createScene(platform: target.instance.platform, name: target.instance.name, sceneName: scene.name, lights: lights) }
        let sceneID = Self.pluginSceneID(platform: target.instance.platform, name: target.instance.name, scene: id)
        logger.info("Scene \"\(scene.name)\" saved to \(target.instance.name)")
        return ["created": ["id": .string(sceneID), "name": .string(scene.name), "hub": .string(hub), "where": .string(target.label)]]
    }

    /// Renames a hub's scene and/or replaces its lights: from a plan's values, or from its lights as they are now
    /// (`fromCurrent`). A dry run answers what would change.
    public func updateHubScene(_ reference: String, name: String?, plan: JSONValue?, fromCurrent: Bool, dryRun: Bool) async throws -> JSONValue {
        guard let found = await pluginScene(reference) else { throw CatalogError("No hub scene \"\(reference)\"", notFound: true) }
        let name = name?.trimmingCharacters(in: .whitespaces).nonEmpty.map { String($0.prefix(64)) }
        var lights: [PluginSceneLight]?
        if plan != nil || fromCurrent, !found.scene.capabilities.contains(.update) {
            throw CatalogError("\(found.scene.name)'s lights cannot be changed from Homeswift")
        }
        if let plan {
            let scene = try planScene(plan)
            guard scene.animation == nil else { throw CatalogError("A hub scene cannot animate") }
            lights = try hubLights(from: scene.actions)
        } else if fromCurrent {
            guard !found.scene.accessoryIDs.isEmpty else { throw CatalogError("The hub does not say which lights \(found.scene.name) sets") }
            lights = try currentHubLights(found.scene.accessoryIDs)
        }
        if name != nil, !found.scene.capabilities.contains(.rename) { throw CatalogError("\(found.scene.name) cannot be renamed from Homeswift") }
        guard name != nil || lights != nil else { throw CatalogError("Pass a new name, a plan or fromCurrent") }
        var answer: [String: JSONValue] = ["id": .string(found.id), "name": .string(name ?? found.scene.name)]
        if let lights { answer["lights"] = .array(lights.map(Self.lightJSON)) }
        if dryRun {
            answer["dryRun"] = true
            return .object(answer)
        }
        try await Self.onHub { try await host.updateScene(platform: found.instance.platform, name: found.instance.name, id: found.scene.id, sceneName: name, lights: lights) }
        logger.info("Scene \"\(found.scene.name)\" changed on \(found.instance.name)\(name.map { ", renamed \"\($0)\"" } ?? "")")
        answer["updated"] = true
        return .object(answer)
    }

    /// Removes a hub's scene from its hub, and its picture.
    public func deleteHubScene(_ reference: String, dryRun: Bool = false) async throws -> JSONValue {
        guard let found = await pluginScene(reference) else { throw CatalogError("No hub scene \"\(reference)\"", notFound: true) }
        guard found.scene.capabilities.contains(.delete) else { throw CatalogError("\(found.scene.name) cannot be removed from Homeswift") }
        let answer: JSONValue = ["id": .string(found.id), "name": .string(found.scene.name), "hub": .string(found.instance.name)]
        if dryRun { return answer }
        try await Self.onHub { try await host.deleteScene(platform: found.instance.platform, name: found.instance.name, id: found.scene.id) }
        scenePictures.remove(key: found.id)
        logger.info("Scene \"\(found.scene.name)\" removed from \(found.instance.name)")
        return answer
    }

    /// A hub's refusal or failure as the catalog's error, so the page and the tools show its words.
    static func onHub<T: Sendable>(_ write: () async throws -> T) async throws -> T {
        do {
            return try await write()
        } catch let error as PluginSceneError {
            throw CatalogError("The hub refused: \(error.description)")
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError("The hub did not answer: \(error)")
        }
    }

    static func lightJSON(_ light: PluginSceneLight) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(light.accessoryID), "on": .bool(light.on)]
        if let value = light.brightness { object["brightness"] = .number(value) }
        if let value = light.hue { object["hue"] = .number(value) }
        if let value = light.saturation { object["saturation"] = .number(value) }
        if let value = light.colorTemperature { object["colorTemperature"] = .number(Double(value)) }
        return .object(object)
    }
}
