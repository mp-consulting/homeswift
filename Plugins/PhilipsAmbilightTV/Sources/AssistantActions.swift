import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// The page's routes for the Assistant: list, find and pair TVs, wake one, press a key.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_tvs", title: "Look at the TVs",
            description: "The TVs this instance runs, by MAC address, with their address, power, input, Ambilight and whether they answer.",
            path: "tvs", access: .read),
        AssistantAction(
            name: "discover", title: "Look for TVs",
            description: "Looks for Philips Android TVs on the network for about five seconds (they announce themselves only while on). Answers each TV's name and IPv4 address (host).",
            path: "discover", access: .read),
        AssistantAction(
            name: "pair", title: "Start pairing",
            description: "Starts pairing with the TV at an IPv4 address: the TV then shows a 4-digit PIN on screen for a few minutes. "
                + "Ask the user for that PIN, then call pair_grant. The TV must be on.",
            method: "POST", path: "pair", access: .configure,
            inputSchema: ["type": "object", "required": ["ip"], "properties": ["ip": ["type": "string", "description": "The TV's IPv4 address"]]]),
        AssistantAction(
            name: "pair_grant", title: "Finish pairing",
            description: "Finishes pairing with the PIN the TV shows. Answers the TV's entry for the devices list (ip, username, password, certFingerprint, mac): "
                + "add it with put_list_entry (platform PhilipsAmbilightTV, list devices, match mac) with a name for the Home app, and keep every value as given. "
                + "Without a mac, ask the user for the TV's MAC address (Settings › Network › View network settings).",
            method: "POST", path: "pair/grant", access: .configure,
            inputSchema: [
                "type": "object", "required": ["ip", "pin"],
                "properties": ["ip": ["type": "string"], "pin": ["type": "string", "pattern": "^[0-9]{4}$", "description": "The 4 digits the TV shows"]],
            ]),
        AssistantAction(
            name: "wake", title: "Wake a TV",
            description: "Sends a Wake-on-LAN packet to a configured TV, by its MAC address, to switch it on from deep standby.",
            method: "POST", path: "wake", access: .control,
            inputSchema: ["type": "object", "required": ["mac"], "properties": ["mac": ["type": "string"]]], queryKeys: ["mac"]),
        AssistantAction(
            name: "press_key", title: "Press a remote key",
            description: "Sends one remote key to a configured TV, by its MAC address: Standby, Home, Back, VolumeUp, Mute, AmbilightOnOff, CursorUp, Confirm and so on.",
            method: "POST", path: "key", access: .control,
            inputSchema: [
                "type": "object", "required": ["mac", "key"],
                "properties": ["mac": ["type": "string"], "key": ["type": "string", "enum": .array(RemoteKeys.all.sorted().map(JSONValue.string))]],
            ]),
    ]
}
