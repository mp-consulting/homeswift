import Foundation
import Homeswift
import HomeswiftPlugin

// Scene templates and scenes the Assistant writes (docs/scenes-design.md, "Surfaces"). A template is one of the
// collection's ambiances (candlelight, a fireplace, a police siren) or the gallery's pictures; for a room's lights it
// becomes a plan: values set once, an effect each brand plays its own way, or a timed sequence. A description becomes
// one the same way, through the Assistant. A plan runs at once with undo, and is saved as a scene when the person
// likes it.

/// A plan tried from the web UI, while it can be stopped.
struct PlanRun: Sendable {
    var id: String
    var name: String
    var template: String?
    var room: String?
    var startedAt: Date
    /// The plan as it ran, for saving it as a scene.
    var plan: JSONValue
}

extension HomeswiftCatalog {
    /// The collection's ambiances that are an effect, played the brands' own way where their lights have it.
    static let templateEffects: [String: LightEffect.Style] = [
        "candle-flicker": .candle, "fireplace": .fire, "ocean": .underwater, "northern-lights": .cosmos, "rainbow-wave": .prism,
        "sunrise": .sunrise, "sunset": .sunset,
    ]

    /// `static` (values set once), `effect` or `sequence`.
    static func templateKind(_ show: LightShow) -> String {
        guard show.isAnimated else { return "static" }
        return show.id.flatMap { templateEffects[$0] } != nil ? "effect" : "sequence"
    }

    static func templateJSON(_ show: LightShow) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(show.id ?? ""), "name": .string(show.name), "kind": .string(templateKind(show)),
            "swatch": .array(SceneTemplateLibrary.swatch(show).map(JSONValue.string)),
        ]
        if let artwork = SceneArtwork.forTemplate(show.id) { object["artworkId"] = .string(artwork.id) }
        if let description = show.description { object["description"] = .string(description) }
        if let category = show.category { object["category"] = .string(category) }
        return .object(object)
    }

    /// The templates, the plans tried that can still be stopped, and whether the Assistant can write one.
    public func sceneTemplatesJSON() -> JSONValue {
        [
            "templates": .array(SceneTemplateLibrary.all.map(Self.templateJSON)),
            "tries": .array(activeTries().map { run in
                var object: [String: JSONValue] = ["run": .string(run.id), "name": .string(run.name), "startedAt": .string(Timestamp.iso8601(run.startedAt)), "playing": .bool(isPlaying(run.id))]
                if let template = run.template { object["template"] = .string(template) }
                if let room = run.room { object["room"] = .string(room) }
                object["plan"] = run.plan
                return .object(object)
            }),
            "assistant": .bool(host.assistant != nil),
        ]
    }

    /// The tried plans still playing or still to undo; the others are forgotten.
    func activeTries() -> [PlanRun] {
        let live = Set(home.planRuns.withLockedValue { Array($0.keys) }.filter { isPlaying($0) || isStoppable($0) })
        return home.planRuns.withLockedValue { runs in
            runs = runs.filter { live.contains($0.key) }
            return runs.values.sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// A template for these lights as a plan.
    func templatePlan(_ show: LightShow, lights: [SceneLight]) -> JSONValue {
        var plan: [String: JSONValue] = ["name": .string(show.name)]
        if let artwork = SceneArtwork.forTemplate(show.id) { plan["artworkId"] = .string(artwork.id) }
        let ids: JSONValue = .array(Array(Set(lights.map(\.located.accessory.id))).sorted().map(JSONValue.string))
        if !show.isAnimated {
            plan["actions"] = .array(staticActions(show.steps[0], on: lights))
        } else if let style = show.id.flatMap({ Self.templateEffects[$0] }) {
            var effect: [String: JSONValue] = ["style": .string(style.rawValue)]
            if style == .sunrise || style == .sunset { effect["durationSeconds"] = .number(min(show.steps.reduce(0) { $0 + $1.seconds }, LightShowRules.maxDuration)) }
            plan["animation"] = ["lights": ids, "effect": .object(effect)]
        } else {
            var animation: [String: JSONValue] = ["lights": ids, "steps": (try? JSONValue(encoding: show.steps)) ?? []]
            if let loop = show.loop { animation["loop"] = .bool(loop) }
            if let duration = show.durationSeconds { animation["durationSeconds"] = .number(duration) }
            if show.restoresAtEnd { animation["restore"] = true }
            plan["animation"] = .object(animation)
        }
        return .object(plan)
    }

    /// The plan a `template` or a `description` makes for the lights of `room` (or `ids`, or `filter`).
    func composedPlan(_ arguments: JSONValue, language: String?) async throws -> (plan: JSONValue, template: String?, room: String?, designed: Bool) {
        var filter = AccessoryFilter(arguments["filter"])
        if let room = arguments["room"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty { filter.room = room }
        let lights = try sceneLights(ids: arguments["ids"]?.arrayValue?.compactMap(\.stringValue), filter: filter)
        if let reference = arguments["template"]?.stringValue {
            guard let show = SceneTemplateLibrary.find(reference) else { throw CatalogError("No template \"\(reference)\": list_scene_templates lists them") }
            return (templatePlan(show, lights: lights), show.id, filter.room, false)
        }
        let description = arguments["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty, description.count <= 500 else { throw CatalogError("Pass a template, or a description of 1 to 500 characters") }
        let show = try await designScene(description, lights: lights, language: language)
        return (templatePlan(show, lights: lights), nil, filter.room, true)
    }

    /// Runs a plan, a template or a description now without saving it, and keeps it among the tries the page shows.
    public func tryScene(_ arguments: JSONValue, language: String? = nil) async throws -> JSONValue {
        let composed: (plan: JSONValue, template: String?, room: String?, designed: Bool)
        if let plan = arguments["plan"] {
            composed = (plan, nil, arguments["room"]?.stringValue, false)
        } else {
            composed = try await composedPlan(arguments, language: language)
        }
        if let refusal = securityRefusal(try planScene(composed.plan)) { throw CatalogError(refusal) }
        var answer = try await runPlan(composed.plan).objectValue ?? [:]
        if let run = answer["run"]?.stringValue {
            let name = answer["name"]?.stringValue ?? "Composed scene"
            let ran = answer["plan"] ?? composed.plan
            home.planRuns.withLockedValue { $0[run] = PlanRun(id: run, name: name, template: composed.template, room: composed.room, startedAt: Date(), plan: ran) }
        }
        if let template = composed.template { answer["template"] = .string(template) }
        if composed.designed { answer["designed"] = true }
        return .object(answer)
    }
}
