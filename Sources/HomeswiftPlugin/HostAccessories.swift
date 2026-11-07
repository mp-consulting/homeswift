import Homeswift

// What a plugin may read of the other plugins' accessories: those on every server the host runs, and their changes. For
// a plugin whose accessories the bridge derives from others (Helpers); it reads them, and writes through their own
// characteristics only as any controller does.

/// How a context follows the host's servers (`PluginHost`'s feeds).
struct HostFeeds: Sendable {
    var find: @Sendable (String) -> Accessory?
    var changes: @Sendable (@escaping HAPServer.ChangeObserver) -> Observation
    var structure: @Sendable (@escaping @Sendable () -> Void) -> Observation
}

extension PluginContext {
    /// Every accessory on the host's servers (its bridges, main and child, and the accessories published on their own),
    /// other plugins' included; the bridges themselves left out. Empty in a context no host runs.
    public var hostAccessories: [Accessory] {
        publishedAccessories().filter { $0.id != "bridge" }
    }

    /// The accessory with this id on any of the host's servers; nil when none has it (a plugin not started yet, a device
    /// Excluded or gone).
    public func hostAccessory(id: String) -> Accessory? {
        id == "bridge" ? nil : hostFeeds?.find(id)
    }

    /// Calls `observer` with every characteristic change on the host's servers, those it adds later included, until the
    /// observation is cancelled (in `stop()`). It is called on the thread that made the change: hand it on, don't work there.
    /// nil in a context no host runs.
    public func observeHostChanges(_ observer: @escaping HAPServer.ChangeObserver) -> Observation? {
        hostFeeds?.changes(observer)
    }

    /// Calls `observer` after an accessory is added, replaced or removed on any of the host's servers, and when the host
    /// adds a server, until the observation is cancelled. It says nothing of what changed: look again. nil in a context no
    /// host runs.
    public func observeHostStructure(_ observer: @escaping @Sendable () -> Void) -> Observation? {
        hostFeeds?.structure(observer)
    }
}
