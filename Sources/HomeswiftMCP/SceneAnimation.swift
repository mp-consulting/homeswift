import Foundation
import Homeswift
import HomeswiftPlugin

// Animated scenes (docs/scenes-design.md, "Animation"). A scene's animation plays on fixed lights after its actions:
// an effect (`LightEffect`: fire, candle…), which each plugin plays natively on the lights it owns
// (`HomeswiftPlugin.animate`) while Homeswift's player plays the rest; or a sequence, timed steps across the lights
// (a siren, lightning), always Homeswift's. Every light is put back when the scene stops, as after any run.

public struct SceneAnimation: Codable, Sendable, Equatable {
    /// The accessories whose lights it plays on.
    public var lights: [String]
    public var effect: LightEffect?
    /// A sequence's steps, as a mood's.
    public var steps: [MoodStep]?
    /// A sequence plays again and again until `durationSeconds` is up.
    public var loop: Bool?
    public var durationSeconds: Double?

    public var kind: String { effect != nil ? "effect" : "sequence" }

    /// An animation from a request body, checked: lights, and one of an effect or steps, in range.
    static func checked(_ value: JSONValue) throws -> SceneAnimation {
        let animation: SceneAnimation
        do {
            animation = try JSONDecoder().decode(SceneAnimation.self, from: Data(value.text().utf8))
        } catch {
            throw CatalogError("An animation has lights, and an effect (style, colors, speed, brightness, durationSeconds) or steps")
        }
        guard (1...MoodRules.maxLights).contains(Set(animation.lights).count) else { throw CatalogError("An animation plays on 1 to \(MoodRules.maxLights) lights") }
        guard (animation.effect == nil) != (animation.steps == nil) else { throw CatalogError("An animation has an effect or steps, not both") }
        if let effect = animation.effect {
            if let speed = effect.speed, !(0...1).contains(speed) { throw CatalogError("The effect's speed is 0 to 1") }
            if let brightness = effect.brightness, !(1...100).contains(brightness) { throw CatalogError("The effect's brightness is 1 to 100") }
            if let duration = effect.durationSeconds, !(10...MoodRules.maxDuration).contains(duration) { throw CatalogError("The effect's durationSeconds is 10 to \(Int(MoodRules.maxDuration))") }
            for color in effect.colors ?? [] {
                if let hue = color.hue, !(0...360).contains(hue) { throw CatalogError("A colour's hue is 0 to 360") }
                if let saturation = color.saturation, !(0...100).contains(saturation) { throw CatalogError("A colour's saturation is 0 to 100") }
                if let mired = color.colorTemperature, !(140...500).contains(mired) { throw CatalogError("A colour's colorTemperature is 140 to 500") }
            }
            if effect.style == .palette, (effect.colors ?? []).count < 2 { throw CatalogError("A palette has 2 colours or more") }
        }
        if let steps = animation.steps {
            try MoodRules.check(Mood(name: "Sequence", steps: steps, loop: animation.loop, durationSeconds: animation.durationSeconds))
        }
        return animation
    }
}

extension HomeswiftCatalog {
    /// Whether a scene's animation plays now: natively on a plugin's lights, or by Homeswift's player.
    func isPlaying(_ sceneID: String) -> Bool {
        home.nativeAnimations.withLockedValue { $0[sceneID] != nil }
            || home.runningMoods.withLockedValue { $0.values.contains { $0.mood.id == "scene:" + sceneID && !$0.isHeld } }
    }

    /// Starts a scene's animation: the plugins play what they can natively, Homeswift's player the rest. Answers which
    /// lights each plays.
    func startAnimation(_ animation: SceneAnimation, of scene: Scene, by: String) async -> JSONValue {
        let lights = Self.lights(of: Array(Set(animation.lights)).compactMap { find(id: $0) })
        guard !lights.isEmpty else { return ["native": [], "played": [], "error": "none of its lights is here"] }
        let moodID = "scene:" + scene.id
        var native: Set<String> = []
        var rest = lights
        let mood: Mood?
        if let effect = animation.effect {
            let before = Dictionary(uniqueKeysWithValues: lights.map { ($0.key, $0.snapshot()) })
            native = await host.animate(effect, accessoryIDs: Array(Set(lights.map(\.located.accessory.id))))
            let played = lights.filter { native.contains($0.located.accessory.id) }
            if !played.isEmpty {
                // Held as a set once, so stopping the scene puts them back once their plugins stopped the effect.
                let snapshots = await takeOver(played, before: before)
                _ = hold(Mood(id: moodID, name: scene.name, steps: [MoodStep(played.map(\.color), seconds: MoodRules.minSeconds)]),
                         on: played, snapshots: snapshots, by: by, room: nil)
                home.nativeAnimations.withLockedValue { $0[scene.id] = Array(native) }
            }
            rest = lights.filter { !native.contains($0.located.accessory.id) }
            mood = Self.fallbackMood(effect, id: moodID, name: scene.name)
        } else {
            mood = Mood(id: moodID, name: scene.name, steps: animation.steps ?? [], loop: animation.loop, durationSeconds: animation.durationSeconds, restore: false)
        }
        var playedByHomeswift: [String] = []
        if let mood, !rest.isEmpty {
            _ = await play(mood, on: rest, by: by, room: nil)
            playedByHomeswift = Array(Set(rest.map(\.located.accessory.id))).sorted()
        }
        logger.info("Scene \"\(scene.name)\" animates \(native.count) accessory(ies) natively, \(playedByHomeswift.count) by Homeswift")
        return ["kind": .string(animation.kind), "native": .array(native.sorted().map(JSONValue.string)), "played": .array(playedByHomeswift.map(JSONValue.string))]
    }

    /// How Homeswift's player plays an effect on lights no plugin animates: the collection's animated moods where one
    /// fits, else a palette of the style's colours; tinted, sped up or slowed down, and dimmed as the effect says. It
    /// plays for an hour at most and stays as it ends; nil for music, which only a device that hears plays.
    static func fallbackMood(_ effect: LightEffect, id: String, name: String) -> Mood? {
        func colour(_ hue: Double, _ saturation: Double, _ brightness: Double) -> MoodColor { MoodColor(brightness: brightness, hue: hue, saturation: saturation) }
        func white(_ mired: Double, _ brightness: Double) -> MoodColor { MoodColor(brightness: brightness, colorTemperature: mired) }
        let pace = 1.6 - (effect.speed ?? 0.5) * 1.2 // 0.4 (fast) to 1.6 (slow) times the style's own steps
        var steps: [MoodStep]
        var loop = true
        switch effect.style {
        case .music:
            return nil
        case .candle: steps = MoodLibrary.find("candle-flicker")?.steps ?? []
        case .fire: steps = MoodLibrary.find("fireplace")?.steps ?? []
        case .underwater: steps = MoodLibrary.find("ocean")?.steps ?? []
        case .cosmos: steps = MoodLibrary.find("northern-lights")?.steps ?? []
        case .prism: steps = MoodLibrary.find("rainbow-wave")?.steps ?? []
        case .sparkle: steps = [MoodStep([white(250, 80), white(250, 40), white(220, 95)], assign: .random, seconds: 0.6, jitter: 35)]
        case .glisten: steps = MoodStep.shimmer([white(300, 60), white(260, 75)])
        case .opal: steps = MoodLibrary.rotations([colour(200, 25, 60), colour(320, 25, 60), colour(50, 30, 65), colour(160, 25, 60)], seconds: 6)
        case .sunbeam: steps = MoodStep.shimmer([white(330, 80), colour(45, 40, 85)])
        case .enchant: steps = MoodLibrary.rotations([colour(300, 60, 55), colour(270, 55, 50), colour(42, 70, 60)], seconds: 5)
        case .palette:
            let palette = (effect.colors ?? []).map { MoodColor(brightness: effect.brightness ?? 80, hue: $0.hue, saturation: $0.saturation, colorTemperature: $0.hue == nil ? $0.colorTemperature : nil) }
            steps = MoodLibrary.rotations(palette, seconds: 4)
        case .sunrise, .sunset:
            loop = false
            let ramp = [colour(5, 100, 2), colour(15, 95, 15), colour(28, 85, 40), white(400, 70), white(330, 100)]
            let ordered = effect.style == .sunrise ? ramp : ramp.reversed()
            let each = (effect.durationSeconds ?? LightEffect.defaultDuration) / Double(ordered.count)
            steps = ordered.map { MoodStep([$0], seconds: min(each, MoodRules.maxSeconds)) }
        }
        guard !steps.isEmpty else { return nil }
        if loop { steps = steps.map { var step = $0; step.seconds = max(MoodRules.minSeconds, step.seconds * pace); return step } }
        if let tint = effect.colors?.first, effect.style != .palette, effect.style != .sunrise, effect.style != .sunset {
            steps = steps.map { var step = $0; step.colors = step.colors.map { $0.tinted(tint) }; return step }
        }
        if let brightness = effect.brightness, effect.style != .palette {
            steps = steps.map { var step = $0; step.colors = step.colors.map { var color = $0; color.brightness = color.brightness.map { $0 * brightness / 100 }; return color }; return step }
        }
        return Mood(id: id, name: name, steps: steps, loop: loop, durationSeconds: loop ? MoodRules.maxDuration : nil, restore: false)
    }
}

extension MoodStep {
    /// A gentle shimmer between a few whites or soft colours, each light on its own.
    static func shimmer(_ colors: [MoodColor]) -> [MoodStep] {
        [MoodStep(colors, assign: .random, seconds: 2.5, jitter: 15), MoodStep(colors.reversed(), assign: .random, seconds: 2.5, jitter: 15)]
    }
}

extension MoodColor {
    /// This colour in a tint's colour, keeping its brightness: a fire in blue.
    func tinted(_ tint: LightEffect.Color) -> MoodColor {
        guard !isOff else { return self }
        if let hue = tint.hue { return MoodColor(on: on, brightness: brightness, hue: hue, saturation: tint.saturation ?? saturation ?? 100) }
        if let mired = tint.colorTemperature { return MoodColor(on: on, brightness: brightness, colorTemperature: mired) }
        return self
    }
}
