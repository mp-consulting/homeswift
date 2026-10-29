import Foundation
import Homeswift
import HomeswiftPlugin

// Scenes composed on the fly: a plan is a scene's actions (values to set, hubs' scenes to recall) that runs at once
// and is not saved. Its changes are kept under its run id for `MoodRules.undoSeconds`, so `stopScene` puts them back;
// `save_scene` keeps one. An MCP client writes the plan itself. docs/scenes-design.md, "Scenes composed on the fly".

extension HomeswiftCatalog {
    /// What run_scene and save_scene take as `plan`.
    static let planSchema: JSONValue = [
        "type": "object",
        "description": .string("A scene composed now: its actions run in order, then its animation plays. Each action is a value to set ({id, service?, characteristic, value}, ids from list_accessories) "
            + "or a hub's scene to recall ({recall: id}, ids from list_scenes' pluginScenes)."),
        "properties": [
            "name": ["type": "string", "maxLength": 64],
            "animation": HomeswiftCatalog.animationSchema,
            "actions": [
                "type": "array", "minItems": 1, "maxItems": .number(Double(SceneRules.maxActions)),
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"], "service": ["type": "string"], "characteristic": ["type": "string"],
                        "value": ["description": "A boolean, a number or a short text"], "recall": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    /// A scene's or a plan's `animation`.
    static let animationSchema: JSONValue = [
        "type": "object", "required": ["lights"],
        "description": .string("Makes the lights move after the actions. effect: a style each brand plays its own way where its lights have it (a Hue light's fire, a Govee light's "
            + "library scene, an IKEA light's long fade for sunrise or sunset, an Ambilight TV following the music), Homeswift's player elsewhere; or steps, a timed sequence "
            + "across the lights (colors spread or random, seconds each, loop, durationSeconds) that Homeswift always plays. stop_scene puts the lights back."),
        "properties": [
            "lights": ["type": "array", "minItems": 1, "maxItems": .number(Double(MoodRules.maxLights)), "items": ["type": "string"], "description": "Accessory ids of lights, from list_accessories"],
            "effect": [
                "type": "object", "required": ["style"],
                "properties": [
                    "style": ["type": "string", "enum": .array(LightEffect.Style.allCases.map { .string($0.rawValue) })],
                    "colors": ["type": "array", "maxItems": 5, "description": "The effect's tint (its first colour), or a palette's colours (2 or more)",
                               "items": ["type": "object", "properties": ["hue": ["type": "number"], "saturation": ["type": "number"], "colorTemperature": ["type": "number"]]]],
                    "speed": ["type": "number", "minimum": 0, "maximum": 1],
                    "brightness": ["type": "number", "minimum": 1, "maximum": 100],
                    "durationSeconds": ["type": "number", "minimum": 10, "maximum": .number(MoodRules.maxDuration), "description": "A sunrise's or a sunset's length"],
                ],
            ],
            "steps": ["type": "array", "items": ["type": "object"]],
            "loop": ["type": "boolean"],
            "durationSeconds": ["type": "number"],
        ],
    ]

    /// A plan, checked as a scene's actions are; it has no triggers or conditions, and an id of its own.
    func planScene(_ plan: JSONValue) throws -> Scene {
        guard var object = plan.objectValue else { throw CatalogError("A plan is an object with actions") }
        if (object["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty { object["name"] = "Composed scene" }
        object["triggers"] = []
        object["conditions"] = []
        return try SceneRules.scene(from: .object(object), id: "plan-" + SceneRules.newID(), existing: nil)
    }

    /// Runs a plan now without saving it; the answer has its `run` id, for `stopScene`, and the plan as it ran.
    public func runPlan(_ plan: JSONValue, allowSecurity: Bool = false) async throws -> JSONValue {
        let scene = try planScene(plan)
        var answer = try await run(scene, trigger: .manual, allowSecurity: allowSecurity).objectValue ?? [:]
        answer["run"] = .string(scene.id)
        var ran: [String: JSONValue] = ["name": .string(scene.name), "actions": (try? JSONValue(encoding: scene.actions)) ?? []]
        if let animation = scene.animation { ran["animation"] = (try? JSONValue(encoding: animation)) ?? .null }
        if let artwork = scene.artworkId { ran["artworkId"] = .string(artwork) }
        answer["plan"] = .object(ran)
        return .object(answer)
    }

    /// Saves a plan as a scene called `name`; a dry run answers what would be saved.
    public func savePlan(_ plan: JSONValue, name: String, dryRun: Bool) throws -> JSONValue {
        guard var object = plan.objectValue else { throw CatalogError("A plan is an object with actions") }
        object["name"] = .string(name)
        if dryRun {
            let scene = try planScene(.object(object))
            return ["dryRun": true, "name": .string(scene.name), "actions": (try? JSONValue(encoding: scene.actions)) ?? []]
        }
        return try createScene(.object(object))
    }
}
