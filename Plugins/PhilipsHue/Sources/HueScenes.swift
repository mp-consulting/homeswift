import Foundation
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The bridge's scenes for Homeswift's Scenes page, by room or zone, as the HomeKit switches show them
    /// (`excludeScenes` leaves some out); the `scenes` option only chooses whether HomeKit gets switches.
    public func scenes() async -> [PluginScene] {
        snapshot.groups.flatMap { group in
            visibleScenes(of: group).map { scene in
                PluginScene(id: scene.id, name: scene.name, room: group.name, active: scene.active, colours: Self.swatches(scene))
            }
        }
    }

    /// Recalls a scene as its switch does: with its transition, playing when `dynamicScenes` says so.
    public func recallScene(id: String) async throws {
        try await recall(sceneID: id)
    }
}
