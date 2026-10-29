import Foundation
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// Plays an animated scene's effect on the lights that have it, as the Hue app does: `effects_v2` with its colour
    /// and speed (plain `effects` on older lights), `timed_effects` for a sunrise or a sunset. A palette moves only in a
    /// scene saved to the bridge, and the bridge does not hear music: Homeswift plays those.
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        guard let client else { return [] }
        var played: Set<String> = []
        for id in accessoryIDs {
            guard let light = snapshot.lights.first(where: { Self.accessoryID(lightID: $0.id) == id }), let body = Self.effectBody(effect, for: light) else { continue }
            do {
                try await client.put("light", id: light.id, body)
                played.insert(id)
            } catch {
                context.logger.warning("\(light.name) did not take the \(effect.style.rawValue) effect: \(error)")
            }
        }
        return played
    }

    /// Stops the effects and timed effects of these lights; Homeswift then puts their colours back.
    public func stopAnimation(accessoryIDs: [String]) async {
        guard let client else { return }
        for id in accessoryIDs {
            guard let light = snapshot.lights.first(where: { Self.accessoryID(lightID: $0.id) == id }) else { continue }
            var body: [String: JSONValue] = [:]
            if !light.effects.isEmpty { body[light.effectsV2 ? "effects_v2" : "effects"] = light.effectsV2 ? ["action": ["effect": "no_effect"]] : ["effect": "no_effect"] }
            if !light.timedEffects.isEmpty { body["timed_effects"] = ["effect": "no_effect"] }
            guard !body.isEmpty else { continue }
            try? await client.put("light", id: light.id, .object(body))
        }
    }

    /// The light's body for an effect, nil when it does not have it.
    static func effectBody(_ effect: LightEffect, for light: HueLight) -> JSONValue? {
        var body: [String: JSONValue] = [:]
        switch effect.style {
        case .palette, .music:
            return nil
        case .sunrise, .sunset:
            guard light.timedEffects.contains(effect.style.rawValue) else { return nil }
            let milliseconds = ((effect.durationSeconds ?? LightEffect.defaultDuration) * 1000).rounded()
            body["timed_effects"] = ["effect": .string(effect.style.rawValue), "duration": .number(milliseconds)]
            return .object(body)
        default:
            let name = effect.style.rawValue
            guard light.effects.contains(name) else { return nil }
            if light.effectsV2 {
                var action: [String: JSONValue] = ["effect": .string(name)]
                var parameters: [String: JSONValue] = [:]
                if let tint = effect.colors?.first {
                    if let hue = tint.hue, light.xy != nil {
                        let xy = HueColor.xy(hue: hue, saturation: tint.saturation ?? 100, gamut: light.gamut ?? .c)
                        parameters["color"] = ["xy": ["x": .number(xy.x), "y": .number(xy.y)]]
                    } else if let mired = tint.colorTemperature, let range = light.mirekRange {
                        parameters["color_temperature"] = ["mirek": .number(Double(min(max(Int(mired.rounded()), range.lowerBound), range.upperBound)))]
                    }
                }
                if let speed = effect.speed { parameters["speed"] = .number(speed) }
                if !parameters.isEmpty { action["parameters"] = .object(parameters) }
                body["effects_v2"] = ["action": .object(action)]
            } else {
                body["effects"] = ["effect": .string(name)]
            }
        }
        body["on"] = ["on": true]
        if let brightness = effect.brightness, light.brightness != nil { body["dimming"] = ["brightness": .number(max(brightness, light.minimumBrightness))] }
        return .object(body)
    }
}
