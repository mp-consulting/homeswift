import Foundation
import HomeswiftPlugin

extension DirigeraPlugin {
    /// The hubs' user scenes for Homeswift's Scenes page, as the HomeKit switches show them (`excludeScenes` leaves
    /// some out). The hub puts a scene in no room and does not say whether it is active. The id is the hub's address
    /// and the scene's id, `<host>|<scene id>`.
    public func scenes() async -> [PluginScene] {
        hubs.keys.sorted().flatMap { host in
            hubs[host].map { hub in visibleScenes(hub).map { PluginScene(id: "\(host)|\($0.id)", name: $0.name) } } ?? []
        }
    }

    public func recallScene(id: String) async throws {
        guard let bar = id.firstIndex(of: "|") else { throw PluginSceneError("no such scene") }
        try await trigger(host: String(id[..<bar]), sceneID: String(id[id.index(after: bar)...]))
    }
}
