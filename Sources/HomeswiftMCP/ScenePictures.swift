import Foundation
import HomeswiftPlugin

// The pictures people give scenes, Homeswift's and the hubs' alike, kept by the core in `scene-pictures/` by scene id
// (`PluginPictures`): the Scenes page and the Hue and IKEA pages show and change the same ones. A scene's JSON carries
// its picture's `picture` version; the page fetches the picture once per version.

extension HomeswiftCatalog {
    var scenePictures: PluginPictures { .scenePictures(root: host.storageDirectory) }

    /// The picture of a scene, Homeswift's or a hub's: its bytes and media type.
    public func scenePicture(_ id: String) -> (data: Data, type: String)? { scenePictures.picture(key: id) }

    /// Gives a scene a picture (a JPEG, PNG or WebP `data:` URL); answers its version. The scene must exist.
    public func setScenePicture(_ id: String, dataURL: String) async throws -> JSONValue {
        try await requireScene(id)
        do {
            return ["id": .string(id), "picture": .string(try scenePictures.save(key: id, dataURL: dataURL))]
        } catch let failure as PluginPictures.Failure {
            throw CatalogError(failure.description)
        }
    }

    public func removeScenePicture(_ id: String) async throws {
        try await requireScene(id)
        scenePictures.remove(key: id)
    }

    private func requireScene(_ id: String) async throws {
        if home.scenes.value.scenes.contains(where: { $0.id == id }) { return }
        guard await foundPluginScenes().contains(where: { $0.id == id }) else { throw CatalogError("No scene \(id)") }
    }
}
