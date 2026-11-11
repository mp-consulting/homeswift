import HomeswiftPlugin

extension WingmanPlugin {
    /// The page's routes for the Assistant: the paired Wingmen. Finding and pairing one is Setup's (`discover_devices`,
    /// `start_setup`).
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_wingmen", title: "Look at the paired Wingmen",
            description: "The Wingmen this instance mirrors Apple Home from: address, state (connected, unreachable, unpaired), how many accessories, "
                + "how many do not respond, the homes, the last error.",
            path: "wingmen", access: .read),
        AssistantAction(
            name: "list_empty_groups", title: "Look for Apple Home's empty groups",
            description: "The groups of the bridge's home in Apple Home that hold fewer than two accessories (counted in Apple Home, "
                + "Homeswift's or not): the Home app does not show them, and an interrupted group creation can leave one, which then "
                + "takes its name (HMErrorDomain 13) and counts towards HomeKit's limit (HMErrorDomain 49). id, name, accessories.",
            path: "empty-groups", access: .read),
        AssistantAction(
            name: "remove_empty_groups", title: "Remove Apple Home's empty groups",
            description: "Removes from Apple Home the groups list_empty_groups gives (all of them, or those of ids) that still hold "
                + "fewer than two accessories. Answers removed and failed.",
            method: "POST", path: "empty-groups/remove", access: .configure,
            inputSchema: ["type": "object", "properties": ["ids": ["type": "array", "items": ["type": "string"], "description": "Group ids from list_empty_groups; all of them when left out"]]],
            confirm: true),
    ]

    public static let assistantBackground: String? = """
        Wingman (Homeswift Wingman) is a menu bar app on a Mac that reads the Apple Home with HomeKit and serves it over \
        TLS on port 8619 to the Homeswift bridges paired with it; Linux and Docker bridges reach it over the network. A \
        Wingman is added through Setup (Add accessories in the web UI, or discover_devices and start_setup): the plugin \
        finds it over Bonjour (_homeswift-wingman._tcp, so the bridge and the Mac need the same network with mDNS; across \
        networks or from a container, an entry of the block's devices with only its host, and port, is found there), \
        shows the certificate to compare with Wingman's window, pairs with the 6-digit code Wingman's menu shows for ten \
        minutes (Pair a Homeswift Bridge), pins its certificate, then mirrors the Home app's accessories into Homeswift: the web UI, moods, scenes, automations and the MCP tools \
        use them, but they are never published to HomeKit again (the Home app has them already). Homeswift's own \
        accessories are left out. Each mirrored accessory (Wingman:<HomeKit id>) and each bridge of Apple Home \
        (Wingman:bridge:<name>) is a device Excluded through its Accessory Settings (update_settings with excluded: true; \
        discover_devices lists them), which leaves it, or the bridge's accessories, out of Homeswift; homes is a Plugin \
        Setting. "Wingman does not know this bridge any more" means it was removed from Wingman's \
        Paired Bridges: set it up again on Add accessories. "Wingman's certificate is not the one pinned" means Wingman was reinstalled on \
        another Mac or user, or something intercepts the connection. "changes are turned off in Wingman's settings" \
        means Wingman's "Let bridges change accessories" is off. Matter accessories (Hue, IKEA) cannot be read by \
        Wingman (HomeKit error 74) but report changes and accept writes; error 74 on a write means the device did not \
        answer (switched off at the wall). Wingman runs only on Macs registered in its developer's team (development \
        signing). Never ask for the token. When Wingman serves Apple Home's structure (and its owner turned on "Let bridges \
        edit rooms, scenes and automations"), Apple Home's scenes are hub scenes (list_scenes, run_scene, update_hub_scene, \
        delete_hub_scene, save_scene with its hub), its automations are list_hub_automations, update_hub_automation and \
        delete_hub_automation. Wingman is the Home Link: the bridge's Rooms, Zones and Groups are Apple Home's (get_home_link), \
        so renaming a room with set_accessory_layout, moving an accessory with update_settings, changing a zone with \
        set_zones or a group with set_wall_layout does the same in the Home app, and the other way round. "structural edits are turned off in \
        Wingman's settings" means that setting is off; "only an administrator of the home can change it" means the Mac's \
        Apple Account is not an administrator of that home. Built-in scenes (Good Morning and the like) cannot be renamed \
        or deleted; automations' accessory triggers and conditions, and new automations, are made in the Home app. \
        Apple Home keeps groups of fewer than two accessories that the Home app hides: an interrupted group creation \
        leaves one, which keeps its name and counts towards HomeKit's limit. When Apple Home refuses a group with \
        "HMErrorDomain 13: Object already exists in the home" or "HMErrorDomain 49: Reached maximum limit of objects for \
        requested type", or the user asks to tidy groups, call list_empty_groups, tell them which, and remove them with \
        remove_empty_groups (all of them, or by ids), which the user confirms.
        """
}
