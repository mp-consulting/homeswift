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

extension HomeswiftPlugin {
    public func scenes() async -> [PluginScene] { [] }

    public func recallScene(id: String) async throws {
        throw PluginSceneError("\(Self.name) has no scenes")
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
        let running = instances.compactMap { instance -> (PlatformInstance, any HomeswiftPlugin)? in
            guard !instance.block.paused, let plugin = instance.plugin.withLockedValue({ $0 }) else { return nil }
            let described = PlatformInstance(
                name: instance.context.name, platform: instance.context.platform, pluginName: instance.entry.name, bridge: instance.context.bridge,
                accessoryIDs: instance.context.accessories.map(\.id))
            return (described, plugin)
        }
        return await withTaskGroup(of: (Int, InstanceScenes?).self) { group in
            for (index, (described, plugin)) in running.enumerated() {
                group.addTask {
                    let scenes = await plugin.scenes()
                    return (index, scenes.isEmpty ? nil : InstanceScenes(instance: described, scenes: scenes))
                }
            }
            var found: [(Int, InstanceScenes)] = []
            for await (index, scenes) in group { if let scenes { found.append((index, scenes)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Recalls a scene of the instance `name` of `platform` (`HomeswiftPlugin.recallScene(id:)`).
    public func recallScene(platform: String, name: String, id: String) async throws {
        guard let instance = instances.first(where: { $0.context.platform == platform && $0.context.name == name }), !instance.block.paused,
              let plugin = instance.plugin.withLockedValue({ $0 }) else { throw PluginSceneError("\(name) is not running") }
        try await plugin.recallScene(id: id)
    }
}
