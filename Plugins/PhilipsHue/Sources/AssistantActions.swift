import Foundation
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The page's routes for the Assistant: the scenes, described so a model can pick one for "something cozy", and
    /// recalling one; the lights.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_scenes", title: "Look at the Hue scenes",
            description: "Every scene of the Hue Bridge: its id, name, room or zone, whether it is active, and its look (its colours in "
                + "words, warm or cool). To set an ambiance the user describes (cozy, relaxing, focus, party, a place or a season), list the "
                + "scenes, pick the one whose name and look fit best in the room they mean (ask which room when it is unclear and several fit), "
                + "then call recall_scene with its id. Optional: room, to list one room's or zone's scenes.",
            path: "assistant-scenes", access: .read,
            inputSchema: ["type": "object", "properties": ["room": ["type": "string", "description": "A room or zone name"]]]),
        AssistantAction(
            name: "recall_scene", title: "Recall a Hue scene",
            description: "Recalls a scene by its id from list_scenes: its room's or zone's lights take the scene, with the plugin's transition. "
                + "Smart scenes (natural light) are activated.",
            method: "POST", path: "recall", access: .control,
            inputSchema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string", "description": "The scene's id"]]],
            changesLights: true),
        AssistantAction(
            name: "list_lights", title: "Look at the Hue lights",
            description: "Every light of the Hue Bridge: id, name, product, on, brightness, colour, effects, whether it answers.",
            path: "lights", access: .read),
    ]

    /// What the Assistant knows about the plugin with every request from the page.
    public static let assistantBackground: String? = [
        "The Homeswift Philips Hue plugin talks to a Hue Bridge on the local network through its API v2 (CLIP v2), without the cloud.",
        "It pairs through Setup (Add accessories, or start_setup) with the bridge's link button and keeps the application key in the vault. Each light is a HomeKit lightbulb, each",
        "room's and zone's scenes are switches on one accessory, effects are switches on their light. A light marked not responding has a",
        "Zigbee connectivity issue on the bridge (switched off at the wall, out of range). Never ask the user for passwords, tokens or keys.",
    ].joined(separator: " ")

    /// The scenes as the Assistant reads them: compact, with their look in words.
    func assistantScenes(room: String?) -> JSONValue {
        let wanted = room?.trimmingCharacters(in: .whitespaces).lowercased()
        var list: [JSONValue] = []
        for group in snapshot.groups where wanted == nil || wanted == "" || group.name.lowercased() == wanted {
            for scene in snapshot.scenes where scene.groupID == group.id {
                list.append([
                    "id": .string(scene.id), "name": .string(scene.name), "room": .string(group.name), "kind": .string(group.kind),
                    "active": .bool(scene.active), "smart": .bool(scene.smart),
                    "look": .string(scene.smart ? "follows the time of day, warm to daylight" : SceneLook.describe(colours: scene.colours, whites: scene.whites)),
                ])
            }
        }
        return ["scenes": .array(list)]
    }
}

/// A scene's colours in words, for a model choosing a scene: "warm: orange, pink and deep red", "cool white".
enum SceneLook {
    static func describe(colours: [HueXY], whites: [Int]) -> String {
        var names: [String] = []
        var warm = 0, cool = 0
        for point in colours {
            let colour = HueColor.hueSaturation(point)
            let name = colourName(hue: colour.hue, saturation: colour.saturation)
            if !names.contains(name) { names.append(name) }
            if colour.saturation < 25 || (colour.hue < 70 || colour.hue >= 300) { warm += 1 } else { cool += 1 }
        }
        for mirek in whites {
            let name = mirek >= 370 ? "warm white" : mirek >= 250 ? "neutral white" : "cool daylight white"
            if !names.contains(name) { names.append(name) }
            if mirek >= 300 { warm += 1 } else { cool += 1 }
        }
        guard !names.isEmpty else { return "no colours set" }
        let list = names.prefix(4)
        let words = list.count == 1 ? list[0] : list.dropLast().joined(separator: ", ") + " and " + list.last!
        let tone = warm > cool ? "warm" : cool > warm ? "cool" : "mixed"
        return colours.isEmpty ? words : "\(tone): \(words)"
    }

    /// A plain name for a HomeKit hue and saturation.
    static func colourName(hue: Double, saturation: Double) -> String {
        if saturation < 20 { return "soft white" }
        let base: String = switch hue {
        case ..<15, 345...: "red"
        case ..<40: "orange"
        case ..<65: "amber"
        case ..<160: "green"
        case ..<200: "turquoise"
        case ..<255: "blue"
        case ..<290: "purple"
        default: "pink"
        }
        return saturation < 50 ? "pale \(base)" : base
    }
}
