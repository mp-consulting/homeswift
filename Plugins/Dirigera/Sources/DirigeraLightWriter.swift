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
        if let level = changes.brightness { commands.append((.object(Self.level(level)), transitionMs)) }
        if changes.hue != nil || changes.saturation != nil {
            let current = currentColour()
            commands.append((.object(Self.colour(hue: changes.hue ?? current.hue, saturation: changes.saturation ?? current.saturation)), transitionMs))
        } else if let mirek = changes.mirek, mirek > 0 {
            commands.append((.object(Self.white(mirek: mirek)), transitionMs))
        }
        return commands
    }

    // The hub's attributes for HomeKit's values; a scene's actions take the same (DirigeraScenes.swift).

    /// The level, 1 to 100: the hub has no 0.
    static func level(_ brightness: Double) -> [String: JSONValue] { ["lightLevel": .number(min(max(brightness.rounded(), 1), 100))] }

    /// A colour: hue 0 to 360, saturation 0 to 1.
    static func colour(hue: Double, saturation: Double) -> [String: JSONValue] {
        ["colorHue": .number(min(max(hue, 0), 360)), "colorSaturation": .number(min(max(saturation, 0), 100) / 100)]
    }

    /// A white in kelvin, from HomeKit's mireds.
    static func white(mirek: Int) -> [String: JSONValue] { ["colorTemperature": .number(kelvin(mirek: mirek))] }

    static func kelvin(mirek: Int) -> Double { (1_000_000 / Double(mirek)).rounded() }
}
