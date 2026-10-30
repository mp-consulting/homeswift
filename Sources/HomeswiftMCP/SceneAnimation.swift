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
    /// A sequence's steps, as a show's.
    public var steps: [LightStep]?
    /// A sequence plays again and again until `durationSeconds` is up.
    public var loop: Bool?
    public var durationSeconds: Double?
    /// A sequence puts the lights back as they were when it ends (a signal such as an alert flash).
    public var restore: Bool?

    public var kind: String { effect != nil ? "effect" : "sequence" }

    /// An animation from a request body, checked: lights, and one of an effect or steps, in range.
    static func checked(_ value: JSONValue) throws -> SceneAnimation {
        let animation: SceneAnimation
        do {
            animation = try JSONDecoder().decode(SceneAnimation.self, from: Data(value.text().utf8))
        } catch {
            throw CatalogError("An animation has lights, and an effect (style, colors, speed, brightness, durationSeconds) or steps")
        }
        guard (1...LightShowRules.maxLights).contains(Set(animation.lights).count) else { throw CatalogError("An animation plays on 1 to \(LightShowRules.maxLights) lights") }
        guard (animation.effect == nil) != (animation.steps == nil) else { throw CatalogError("An animation has an effect or steps, not both") }
        if let effect = animation.effect {
            if let speed = effect.speed, !(0...1).contains(speed) { throw CatalogError("The effect's speed is 0 to 1") }
            if let brightness = effect.brightness, !(1...100).contains(brightness) { throw CatalogError("The effect's brightness is 1 to 100") }
            if let duration = effect.durationSeconds, !(10...LightShowRules.maxDuration).contains(duration) { throw CatalogError("The effect's durationSeconds is 10 to \(Int(LightShowRules.maxDuration))") }
            for color in effect.colors ?? [] {
                if let hue = color.hue, !(0...360).contains(hue) { throw CatalogError("A colour's hue is 0 to 360") }
                if let saturation = color.saturation, !(0...100).contains(saturation) { throw CatalogError("A colour's saturation is 0 to 100") }
                if let mired = color.colorTemperature, !(140...500).contains(mired) { throw CatalogError("A colour's colorTemperature is 140 to 500") }
            }
            if effect.style == .palette, (effect.colors ?? []).count < 2 { throw CatalogError("A palette has 2 colours or more") }
        }
        if let steps = animation.steps {
            try LightShowRules.check(LightShow(name: "Sequence", steps: steps, loop: animation.loop, durationSeconds: animation.durationSeconds, restore: animation.restore))
        }
        return animation
    }
}

extension HomeswiftCatalog {
    /// Whether a scene's animation plays now: natively on a plugin's lights, or by Homeswift's player.
    func isPlaying(_ sceneID: String) -> Bool {
        home.nativeAnimations.withLockedValue { $0[sceneID] != nil } || !lightRuns(of: sceneID, held: false).isEmpty
    }

    /// The id of the light runs a scene, a hub's scene or a plan holds or plays.
    static func showID(of sceneID: String) -> String { "scene:" + sceneID }

    /// The light runs of a scene (`held`: only those holding values, or only those playing); their run ids.
    func lightRuns(of sceneID: String, held: Bool? = nil) -> [String] {
        let show = Self.showID(of: sceneID)
        return home.lightRuns.withLockedValue { $0.values.filter { $0.show.id == show && (held == nil || $0.isHeld == held) }.map(\.id) }
    }

    /// Whether `stop_scene` can still put back what this scene, hub scene or plan changed: an undo younger than 12
    /// hours, or lights it holds or plays.
    func isStoppable(_ sceneID: String) -> Bool {
        let undo = home.sceneUndo.value[sceneID]
        return undo.map { Date().timeIntervalSince($0.at) < LightShowRules.undoSeconds && !$0.actions.isEmpty } == true || !lightRuns(of: sceneID).isEmpty
    }

    /// Starts a scene's animation: the plugins play what they can natively, Homeswift's player the rest. Answers which
    /// lights each plays.
    func startAnimation(_ animation: SceneAnimation, of scene: Scene, by: String) async -> JSONValue {
        let lights = Self.lights(of: Array(Set(animation.lights)).compactMap { find(id: $0) })
        guard !lights.isEmpty else { return ["native": [], "played": [], "error": "none of its lights is here"] }
        let showID = Self.showID(of: scene.id)
        var native: Set<String> = []
        var rest = lights
        let show: LightShow?
        if let effect = animation.effect {
            let before = Dictionary(uniqueKeysWithValues: lights.map { ($0.key, $0.snapshot()) })
            native = await host.animate(effect, accessoryIDs: Array(Set(lights.map(\.located.accessory.id))))
            let played = lights.filter { native.contains($0.located.accessory.id) }
            if !played.isEmpty {
                // Held as a set once, so stopping the scene puts them back once their plugins stopped the effect.
                let snapshots = await takeOver(played, before: before)
                _ = hold(LightShow(id: showID, name: scene.name, steps: [LightStep(played.map(\.color), seconds: LightShowRules.minSeconds)]),
                         on: played, snapshots: snapshots, by: by)
                home.nativeAnimations.withLockedValue { $0[scene.id] = Array(native) }
            }
            rest = lights.filter { !native.contains($0.located.accessory.id) }
            show = Self.fallbackShow(effect, id: showID, name: scene.name)
        } else {
            show = LightShow(id: showID, name: scene.name, steps: animation.steps ?? [], loop: animation.loop, durationSeconds: animation.durationSeconds, restore: animation.restore ?? false)
        }
        var playedByHomeswift: [String] = []
        if let show, !rest.isEmpty {
            _ = await play(show, on: rest, by: by)
            playedByHomeswift = Array(Set(rest.map(\.located.accessory.id))).sorted()
        }
        logger.info("Scene \"\(scene.name)\" animates \(native.count) accessory(ies) natively, \(playedByHomeswift.count) by Homeswift")
        return ["kind": .string(animation.kind), "native": .array(native.sorted().map(JSONValue.string)), "played": .array(playedByHomeswift.map(JSONValue.string))]
    }

    /// How Homeswift's player plays an effect on lights no plugin animates: the collection's animated shows where one
    /// fits, else a palette of the style's colours; tinted, sped up or slowed down, and dimmed as the effect says. It
    /// plays for an hour at most and stays as it ends; nil for music, which only a device that hears plays.
    static func fallbackShow(_ effect: LightEffect, id: String, name: String) -> LightShow? {
        func colour(_ hue: Double, _ saturation: Double, _ brightness: Double) -> LightColor { LightColor(brightness: brightness, hue: hue, saturation: saturation) }
        func white(_ mired: Double, _ brightness: Double) -> LightColor { LightColor(brightness: brightness, colorTemperature: mired) }
        let pace = 1.6 - (effect.speed ?? 0.5) * 1.2 // 0.4 (fast) to 1.6 (slow) times the style's own steps
        var steps: [LightStep]
        var loop = true
        switch effect.style {
        case .music:
            return nil
        case .candle: steps = SceneTemplateLibrary.find("candle-flicker")?.steps ?? []
        case .fire: steps = SceneTemplateLibrary.find("fireplace")?.steps ?? []
        case .underwater: steps = SceneTemplateLibrary.find("ocean")?.steps ?? []
        case .cosmos: steps = SceneTemplateLibrary.find("northern-lights")?.steps ?? []
        case .prism: steps = SceneTemplateLibrary.find("rainbow-wave")?.steps ?? []
        case .sparkle: steps = [LightStep([white(250, 80), white(250, 40), white(220, 95)], assign: .random, seconds: 0.6, jitter: 35)]
        case .glisten: steps = LightStep.shimmer([white(300, 60), white(260, 75)])
        case .opal: steps = SceneTemplateLibrary.rotations([colour(200, 25, 60), colour(320, 25, 60), colour(50, 30, 65), colour(160, 25, 60)], seconds: 6)
        case .sunbeam: steps = LightStep.shimmer([white(330, 80), colour(45, 40, 85)])
        case .enchant: steps = SceneTemplateLibrary.rotations([colour(300, 60, 55), colour(270, 55, 50), colour(42, 70, 60)], seconds: 5)
        case .palette:
            let palette = (effect.colors ?? []).map { LightColor(brightness: effect.brightness ?? 80, hue: $0.hue, saturation: $0.saturation, colorTemperature: $0.hue == nil ? $0.colorTemperature : nil) }
            steps = SceneTemplateLibrary.rotations(palette, seconds: 4)
        case .sunrise, .sunset:
            loop = false
            let ramp = [colour(5, 100, 2), colour(15, 95, 15), colour(28, 85, 40), white(400, 70), white(330, 100)]
            let ordered = effect.style == .sunrise ? ramp : ramp.reversed()
            let each = (effect.durationSeconds ?? LightEffect.defaultDuration) / Double(ordered.count)
            steps = ordered.map { LightStep([$0], seconds: min(each, LightShowRules.maxSeconds)) }
        }
        guard !steps.isEmpty else { return nil }
        if loop { steps = steps.map { var step = $0; step.seconds = max(LightShowRules.minSeconds, step.seconds * pace); return step } }
        if let tint = effect.colors?.first, effect.style != .palette, effect.style != .sunrise, effect.style != .sunset {
            steps = steps.map { var step = $0; step.colors = step.colors.map { $0.tinted(tint) }; return step }
        }
        if let brightness = effect.brightness, effect.style != .palette {
            steps = steps.map { var step = $0; step.colors = step.colors.map { var color = $0; color.brightness = color.brightness.map { $0 * brightness / 100 }; return color }; return step }
        }
        return LightShow(id: id, name: name, steps: steps, loop: loop, durationSeconds: loop ? LightShowRules.maxDuration : nil, restore: false)
    }
}

extension LightStep {
    /// A gentle shimmer between a few whites or soft colours, each light on its own.
    static func shimmer(_ colors: [LightColor]) -> [LightStep] {
        [LightStep(colors, assign: .random, seconds: 2.5, jitter: 15), LightStep(colors.reversed(), assign: .random, seconds: 2.5, jitter: 15)]
    }
}

extension LightColor {
    /// This colour in a tint's colour, keeping its brightness: a fire in blue.
    func tinted(_ tint: LightEffect.Color) -> LightColor {
        guard !isOff else { return self }
        if let hue = tint.hue { return LightColor(on: on, brightness: brightness, hue: hue, saturation: tint.saturation ?? saturation ?? 100) }
        if let mired = tint.colorTemperature { return LightColor(on: on, brightness: brightness, colorTemperature: mired) }
        return self
    }
}
