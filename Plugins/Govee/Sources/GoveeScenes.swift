import Foundation
import HomeswiftPlugin

extension GoveePlugin {
    /// The scenes picked from the Govee library on the plugin's page (one switch each), for Homeswift's Scenes page:
    /// a light's picks sit in its room. The library itself stays a place to pick from. The id is the device's and the
    /// switch's subtype, `<device id>|<subtype>`.
    public func scenes() async -> [PluginScene] {
        var list: [PluginScene] = []
        for device in devices.values.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
            guard let light = device.handler as? LightDevice else { continue }
            for pick in await light.librarySceneNames {
                list.append(PluginScene(id: "\(device.id)|\(pick.key)", name: "\(pick.name) · \(device.name)", accessoryIDs: [device.accessoryID]))
            }
        }
        return list
    }

    public func recallScene(id: String) async throws {
        guard let bar = id.firstIndex(of: "|"), let light = devices[String(id[..<bar])]?.handler as? LightDevice else { throw PluginSceneError("no such scene") }
        try await light.applyScene(key: String(id[id.index(after: bar)...]))
    }
}
