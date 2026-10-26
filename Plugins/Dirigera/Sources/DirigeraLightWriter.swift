import Foundation
import HomeswiftPlugin

/// A light's gathered changes (`LightChangeBatcher`) as the PATCHes the hub wants, in its order, one each: On first
/// when it turns on, the level, then the colour (hue and saturation together) or the white, with the transition; Off
/// alone. Every library for the hub sends them apart, and openHAB found a light fading ignores the next command, so
/// they go one after the other.
struct DirigeraLightCommands: Sendable {
    /// How long the hub's events about a light just written are left alone: they may still carry the old values.
    static let settleTime = Duration.seconds(1)

    let transitionMs: Int
    let currentColour: @Sendable () -> (hue: Double, saturation: Double)

    /// The PATCHes, in order, each with its transition (nil for On).
    func commands(for changes: LightChangeBatcher.Changes) -> [(JSONValue, Int?)] {
        if changes.on == false { return [(["isOn": false], nil)] }
        var commands: [(JSONValue, Int?)] = []
        if changes.on == true { commands.append((["isOn": true], nil)) }
        if let level = changes.brightness { commands.append((["lightLevel": .number(min(max(level.rounded(), 1), 100))], transitionMs)) }
        if changes.hue != nil || changes.saturation != nil {
            let current = currentColour()
            let hue = changes.hue ?? current.hue, saturation = changes.saturation ?? current.saturation
            commands.append((["colorHue": .number(min(max(hue, 0), 360)), "colorSaturation": .number(min(max(saturation, 0), 100) / 100)], transitionMs))
        } else if let mirek = changes.mirek, mirek > 0 {
            commands.append((["colorTemperature": .number((1_000_000 / Double(mirek)).rounded())], transitionMs))
        }
        return commands
    }
}

extension LightChangeBatcher {
    /// Whether a command went within `DirigeraLightCommands.settleTime`, when the hub's events may still be old.
    var isSettling: Bool { lastSent.map { ContinuousClock.now - $0 < DirigeraLightCommands.settleTime } ?? false }
}
