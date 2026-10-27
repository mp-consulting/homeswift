import Foundation
import HomeswiftPlugin

extension DirigeraPlugin {
    /// The page's routes for the Assistant: the hubs' scenes, running one, and the devices.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_scenes", title: "Look at the IKEA scenes",
            description: "Every scene of the DIRIGERA hubs: its id, the hub's host, its name, its icon (scenes_tv, scenes_moon, scenes_sun…) and whether it can be run "
                + "(runnable: wake-up scenes run on the hub's schedule and cannot). To set an ambiance the user describes (movie, bedtime, morning, dinner), list the scenes, pick the runnable one whose name and icon "
                + "fit best, then call run_scene with its host and id.",
            path: "scenes", access: .read),
        AssistantAction(
            name: "run_scene", title: "Run an IKEA scene",
            description: "Runs a scene by the host and id from list_scenes: its devices take the scene's settings.",
            method: "POST", path: "trigger", access: .control,
            inputSchema: [
                "type": "object", "required": ["host", "id"],
                "properties": ["host": ["type": "string", "description": "The hub's host"], "id": ["type": "string", "description": "The scene's id"]],
            ]),
        AssistantAction(
            name: "list_devices", title: "Look at the IKEA devices",
            description: "Every light, outlet and door or window sensor of the DIRIGERA hubs: id, host, name, room, on, brightness, colour, open.",
            path: "devices", access: .read),
    ]

    /// What the Assistant knows about the plugin with every request from the page.
    public static let assistantBackground: String? = [
        "The Homeswift IKEA DIRIGERA plugin talks to DIRIGERA hubs on the local network (https://<hub>:8443/v1), without the cloud.",
        "It pairs with the action button under the hub (OAuth with PKCE) and keeps the token in its own folder. Lights, outlets and",
        "PARASOLL sensors become HomeKit accessories, each hub's user scenes switches on one accessory (on runs, off within 30 s undoes).",
        "Never ask the user for passwords, tokens or keys.",
    ].joined(separator: " ")
}
