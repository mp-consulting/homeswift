import NIOConcurrencyHelpers

// The home's Scenes (GLOSSARY.md, "Scene"), lent to plugins: Homeswift's own and its plugins' hubs' scenes live above
// the plugins (the catalog), and a plugin that offers them (a remote whose press runs one) reads and runs them here.

/// A Scene as a plugin may offer it: its id (what `run` takes), its name and room.
public struct HomeScene: Sendable, Equatable {
    public var id: String
    public var name: String
    public var room: String?

    public init(id: String, name: String, room: String? = nil) {
        self.id = id
        self.name = name
        self.room = room
    }
}

/// What the host lends of the home's Scenes once its catalog runs (the CLI sets it, `PluginHost.homeScenes`): the list,
/// and a run, which leaves locks, garage doors and alarms as they are, as an Automation's does.
public struct HomeScenes: Sendable {
    public var list: @Sendable () async -> [HomeScene]
    public var run: @Sendable (_ id: String) async throws -> Void

    public init(list: @escaping @Sendable () async -> [HomeScene], run: @escaping @Sendable (_ id: String) async throws -> Void) {
        self.list = list
        self.run = run
    }
}

extension PluginContext {
    /// The home's Scenes, to offer and run (a remote's press); nil in a context no host runs, or before the catalog.
    public var homeScenes: HomeScenes? { homeScenesSource() }
}
