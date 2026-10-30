import Foundation

/// An animation for lights, said the same way for every brand: a style (fire, candle…) with an optional colour, speed
/// and brightness. Each plugin plays the lights it owns the way its own app does (`HomeswiftPlugin.animate`); Homeswift
/// plays the others itself. docs/scenes-design.md, "Animation".
public struct LightEffect: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case candle, fire, sparkle, prism, opal, glisten, underwater, cosmos, sunbeam, enchant
        /// The colours, moving from light to light.
        case palette
        /// A slow rise from a dim red glow to bright warm white, or the way back, over `durationSeconds`.
        case sunrise, sunset
        /// Following the room's sound: only a device that hears it (a TV) plays it; other lights stay as they are.
        case music
    }

    /// A colour, or a white.
    public struct Color: Codable, Sendable, Equatable {
        /// 0 to 360.
        public var hue: Double?
        /// 0 to 100.
        public var saturation: Double?
        /// In mired, 140 to 500.
        public var colorTemperature: Double?

        public init(hue: Double? = nil, saturation: Double? = nil, colorTemperature: Double? = nil) {
            self.hue = hue
            self.saturation = saturation
            self.colorTemperature = colorTemperature
        }
    }

    public var style: Style
    /// The effect's tint (its first colour), or a palette's colours.
    public var colors: [Color]?
    /// 0 (slow) to 1 (fast); the style's own pace when nil.
    public var speed: Double?
    /// 1 to 100.
    public var brightness: Double?
    /// How long a sunrise or a sunset takes; 15 minutes when nil.
    public var durationSeconds: Double?

    public init(style: Style, colors: [Color]? = nil, speed: Double? = nil, brightness: Double? = nil, durationSeconds: Double? = nil) {
        self.style = style
        self.colors = colors
        self.speed = speed
        self.brightness = brightness
        self.durationSeconds = durationSeconds
    }

    public static let defaultDuration: Double = 15 * 60
}

extension HomeswiftPlugin {
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> { [] }
    public func stopAnimation(accessoryIDs: [String]) async {}
}

extension PluginHost {
    /// Hands each running instance the lights it owns among `accessoryIDs` (`HomeswiftPlugin.animate`); answers those
    /// they play themselves. The others are Homeswift's to play.
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        await withTaskGroup(of: Set<String>.self) { group in
            for (plugin, owned) in owners(of: accessoryIDs) {
                group.addTask { await plugin.animate(effect, accessoryIDs: owned) }
            }
            var played: Set<String> = []
            for await ids in group { played.formUnion(ids) }
            return played.intersection(accessoryIDs)
        }
    }

    /// Asks the instances that own these lights to stop what they play (`HomeswiftPlugin.stopAnimation`).
    public func stopAnimation(accessoryIDs: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for (plugin, owned) in owners(of: accessoryIDs) {
                group.addTask { await plugin.stopAnimation(accessoryIDs: owned) }
            }
        }
    }

    /// The running plugins that own some of these accessories, each with its own, in the order given.
    private func owners(of accessoryIDs: [String]) -> [(any HomeswiftPlugin, [String])] {
        runningPlugins().compactMap { instance, plugin in
            let mine = Set(instance.context.accessories.map(\.id))
            let owned = accessoryIDs.filter(mine.contains)
            return owned.isEmpty ? nil : (plugin, owned)
        }
    }
}
