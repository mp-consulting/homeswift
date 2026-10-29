import Foundation
import HomeswiftPlugin

extension DirigeraPlugin {
    /// The hubs' user scenes for Homeswift's Scenes page, as the HomeKit switches show them (`excludeScenes` leaves
    /// some out). The hub puts a scene in no room and does not say whether it is active. The id is the hub's (a UUID,
    /// unique across hubs), as the page's pictures are keyed.
    public func scenes() async -> [PluginScene] {
        hubs.keys.sorted().flatMap { host in
            hubs[host].map { hub in visibleScenes(hub).map { PluginScene(id: $0.id, name: $0.name) } } ?? []
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
}
