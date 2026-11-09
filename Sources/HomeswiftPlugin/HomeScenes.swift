// The home's Scenes (GLOSSARY.md, "Scene") live above the plugins (the catalog): Homeswift's own and its plugins' hubs'.
// The catalog lends the host a way to run one, for a Remote's Control (`RemoteControls`).

/// Runs one of the home's Scenes by id as an Automation's step does, locks, garage doors and alarms left as they are:
/// lent by the catalog once it runs (the CLI sets it, `PluginHost.homeScenes`).
public struct HomeScenes: Sendable {
    public var run: @Sendable (_ id: String) async throws -> Void

    public init(run: @escaping @Sendable (_ id: String) async throws -> Void) {
        self.run = run
    }
}
