import Foundation

/// A scene a plugin's hub keeps (a Hue Bridge's, a DIRIGERA hub's, a Govee light's picks), listed by
/// `HomeswiftPlugin.scenes()` so the web UI's Scenes page, the MCP tools and the Assistant show it with Homeswift's own
/// scenes, and run by `HomeswiftPlugin.recallScene(id:)`. The hub stays the scene's only keeper: Homeswift asks again
/// each time it lists them and keeps no copy. docs/scenes-design.md has the whole design.
///
/// ```swift
/// func scenes() async -> [PluginScene] {
///     hub.scenes.map { PluginScene(id: $0.id, name: $0.name, room: $0.roomName, active: $0.isActive, colours: $0.swatches) }
/// }
///
/// func recallScene(id: String) async throws {
///     try await hub.recall(id)
/// }
/// ```
public struct PluginScene: Sendable, Equatable {
    /// What Homeswift may do with the scene through its plugin.
    public enum Capability: String, Sendable, CaseIterable {
        case recall, rename, update, create, delete, animate
    }

    /// The hub's own id: unique within the plugin instance, without a `/`. Homeswift's id for the scene is
    /// `<platform>:<instance name>:<id>`.
    public var id: String
    public var name: String
    /// The room or zone the hub puts it in; Homeswift places the scene in its room of the same name.
    public var room: String?
    /// The accessories it changes, when the plugin knows them (a Govee light's pick): Homeswift places the scene in
    /// their room when they share one.
    public var accessoryIDs: [String]
    /// Whether the hub reports it active now; nil when the hub does not tell.
    public var active: Bool?
    /// Up to five CSS colours that draw its tile (`#ff8800`).
    public var colours: [String]
    public var capabilities: Set<Capability>

    public init(id: String, name: String, room: String? = nil, accessoryIDs: [String] = [], active: Bool? = nil, colours: [String] = [], capabilities: Set<Capability> = [.recall]) {
        self.id = id
        self.name = name
        self.room = room
        self.accessoryIDs = accessoryIDs
        self.active = active
        self.colours = colours
        self.capabilities = capabilities
    }
}

/// A light's state as a hub scene keeps it, in HomeKit's units, for `HomeswiftPlugin.createScene` and `updateScene`.
/// A light switched off keeps only `on`.
public struct PluginSceneLight: Sendable, Equatable {
    public var accessoryID: String
    public var on: Bool
    /// 0 to 100.
    public var brightness: Double?
    /// A colour: hue 0 to 360 and saturation 0 to 100.
    public var hue: Double?
    public var saturation: Double?
    /// A white, in mireds (HomeKit's Color Temperature).
    public var colorTemperature: Int?

    public init(accessoryID: String, on: Bool, brightness: Double? = nil, hue: Double? = nil, saturation: Double? = nil, colorTemperature: Int? = nil) {
        self.accessoryID = accessoryID
        self.on = on
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.colorTemperature = colorTemperature
    }

    /// Whether it sets a colour (both hue and saturation), which wins over a white.
    public var hasColour: Bool { hue != nil && saturation != nil }
}

extension HomeswiftPlugin {
    public func scenes() async -> [PluginScene] { [] }

    public func recallScene(id: String) async throws {
        throw PluginSceneError("\(Self.name) has no scenes")
    }

    public func sceneTarget(accessoryIDs: [String]) async -> String? { nil }

    public func createScene(name: String, lights: [PluginSceneLight]) async throws -> String {
        throw PluginSceneError("\(Self.name) cannot keep new scenes")
    }

    public func updateScene(id: String, name: String?, lights: [PluginSceneLight]?) async throws {
        throw PluginSceneError("\(Self.name) cannot change its scenes")
    }

    public func deleteScene(id: String) async throws {
        throw PluginSceneError("\(Self.name) cannot remove its scenes")
    }
}

public struct PluginSceneError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension PluginHost {
    /// The scenes of a running plugin instance, with the instance they come from.
    public struct InstanceScenes: Sendable {
        public let instance: PlatformInstance
        public let scenes: [PluginScene]
    }

    /// Every running instance's scenes (`HomeswiftPlugin.scenes()`), asked at the same time; paused instances and
    /// those with none are left out.
    public func pluginScenes() async -> [InstanceScenes] {
        await scenes(of: runningPlugins())
    }

    /// The scenes of the instance `name` of `platform` only, when it runs: a hub scene's id names its instance.
    public func pluginScenes(platform: String, name: String) async -> InstanceScenes? {
        await scenes(of: runningPlugins().filter { $0.instance.context.platform == platform && $0.instance.context.name == name }).first
    }

    private func scenes(of running: [(instance: Instance, plugin: any HomeswiftPlugin)]) async -> [InstanceScenes] {
        await withTaskGroup(of: (Int, InstanceScenes?).self) { group in
            for (index, (instance, plugin)) in running.enumerated() {
                group.addTask {
                    let scenes = await plugin.scenes()
                    // Described only when it has some: most plugins have none.
                    return (index, scenes.isEmpty ? nil : InstanceScenes(instance: instance.described, scenes: scenes))
                }
            }
            var found: [(Int, InstanceScenes)] = []
            for await (index, scenes) in group { if let scenes { found.append((index, scenes)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Recalls a scene of the instance `name` of `platform` (`HomeswiftPlugin.recallScene(id:)`).
    public func recallScene(platform: String, name: String, id: String) async throws {
        try await runningPlugin(platform: platform, name: name).recallScene(id: id)
    }

    /// A hub that can keep a new scene of exactly these lights.
    public struct SceneTarget: Sendable {
        public let instance: PlatformInstance
        /// Where the hub would keep it ("Living room on Hue Bridge").
        public let label: String
    }

    /// The running instances that can keep a scene of these lights (`HomeswiftPlugin.sceneTarget`), asked at once.
    public func sceneTargets(accessoryIDs: [String]) async -> [SceneTarget] {
        guard !accessoryIDs.isEmpty else { return [] }
        // Only an instance that has every one of the lights is asked.
        let candidates = runningPlugins().filter { candidate in
            let ids = Set(candidate.instance.context.accessories.map(\.id))
            return accessoryIDs.allSatisfy(ids.contains)
        }
        return await withTaskGroup(of: (Int, SceneTarget?).self) { group in
            for (index, (instance, plugin)) in candidates.enumerated() {
                group.addTask { (index, await plugin.sceneTarget(accessoryIDs: accessoryIDs).map { SceneTarget(instance: instance.described, label: $0) }) }
            }
            var found: [(Int, SceneTarget)] = []
            for await (index, target) in group { if let target { found.append((index, target)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func createScene(platform: String, name: String, sceneName: String, lights: [PluginSceneLight]) async throws -> String {
        try await runningPlugin(platform: platform, name: name).createScene(name: sceneName, lights: lights)
    }

    public func updateScene(platform: String, name: String, id: String, sceneName: String?, lights: [PluginSceneLight]?) async throws {
        try await runningPlugin(platform: platform, name: name).updateScene(id: id, name: sceneName, lights: lights)
    }

    public func deleteScene(platform: String, name: String, id: String) async throws {
        try await runningPlugin(platform: platform, name: name).deleteScene(id: id)
    }

    private func runningPlugin(platform: String, name: String) throws -> any HomeswiftPlugin {
        guard let running = runningPlugins().first(where: { $0.instance.context.platform == platform && $0.instance.context.name == name }) else {
            throw PluginSceneError("\(name) is not running")
        }
        return running.plugin
    }
}
