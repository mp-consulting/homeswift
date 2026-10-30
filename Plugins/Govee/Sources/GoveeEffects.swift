import Foundation
import HomeswiftPlugin

extension GoveePlugin {
    /// The Govee library's scene that plays each style, first match in the light's library (names as the Govee app
    /// shows them). A palette has none, and music needs the music mode's own setup: Homeswift plays those.
    static let effectScenes: [LightEffect.Style: [String]] = [
        .candle: ["Candlelight"], .fire: ["Fire"], .sparkle: ["Twinkle", "Star"], .prism: ["Rainbow"],
        .opal: ["Dreamland", "Sweet"], .glisten: ["Star", "Twinkle"], .underwater: ["Deep sea", "Wave", "Sea"],
        .cosmos: ["Universe", "Starry Sky", "Galaxy"], .sunbeam: ["Sunny", "Sunshine", "Morning"], .enchant: ["Aurora", "Dreamland"],
        .sunrise: ["Sunrise"], .sunset: ["Sunset"],
    ]

    /// The code of the library scene that plays a style on a model, from the library the plugin ships.
    static func effectSceneCode(_ style: LightEffect.Style, sku: String) -> (name: String, code: String)? {
        guard let names = effectScenes[style], let library = SceneCatalogue.library(sku: sku, device: "") else { return nil }
        let scenes = library.categories.flatMap(\.scenes)
        for name in names {
            if let scene = scenes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }), !scene.code.isEmpty { return (scene.name, scene.code) }
        }
        return nil
    }

    /// Plays an animated scene's effect on the lights whose library has a scene for it, as the Govee app does. The
    /// library's scenes have their own colours and pace; the effect's colour and speed are not sent.
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        var played: Set<String> = []
        for device in devices.values where accessoryIDs.contains(device.accessoryID) {
            guard let light = device.handler as? LightDevice, let scene = Self.effectSceneCode(effect.style, sku: device.model) else { continue }
            if await light.applyLibraryScene(name: scene.name, code: scene.code) { played.insert(device.accessoryID) }
        }
        return played
    }
}
