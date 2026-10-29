import Foundation
import Homeswift
import HomeswiftPlugin

// Scenes composed on the fly: a plan is a scene's actions (values to set, hubs' scenes to recall) that runs at once
// and is not saved. Its changes are kept under its run id for `MoodRules.undoSeconds`, so `stopScene` puts them back;
// `save_scene` keeps one. An MCP client writes the plan itself. docs/scenes-design.md, "Scenes composed on the fly".

extension HomeswiftCatalog {
    /// What run_scene and save_scene take as `plan`.
    static let planSchema: JSONValue = [
        "type": "object", "required": ["actions"],
        "description": .string("A scene composed now: its actions run in order. Each is a value to set ({id, service?, characteristic, value}, ids from list_accessories) "
            + "or a hub's scene to recall ({recall: id}, ids from list_scenes' pluginScenes)."),
        "properties": [
            "name": ["type": "string", "maxLength": 64],
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
        answer["plan"] = ["name": .string(scene.name), "actions": (try? JSONValue(encoding: scene.actions)) ?? []]
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
