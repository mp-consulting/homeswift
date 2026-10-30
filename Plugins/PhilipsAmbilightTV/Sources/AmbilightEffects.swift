import Foundation
import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// Ambilight follows the TV's sound for an animated scene's music (`FOLLOW_AUDIO`, energy colours); Homeswift plays
    /// the other styles on it as on any light. Putting its colour back afterwards ends the music mode.
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        guard effect.style == .music else { return [] }
        var played: Set<String> = []
        for (mac, device) in devices {
            let id = "\(Self.platform):\(mac)"
            guard accessoryIDs.contains(id) else { continue }
            do {
                try await device.client.setAmbilightStyle("FOLLOW_AUDIO", algorithm: "ENERGY_ADAPTIVE_COLORS")
                played.insert(id)
            } catch {
                context.logger.warning("Ambilight did not follow the sound: \(error)")
            }
        }
        return played
    }
}
