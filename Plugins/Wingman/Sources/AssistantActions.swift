import HomeswiftPlugin

extension WingmanPlugin {
    /// The page's routes for the Assistant: the paired Wingmen, those on the network, and pairing.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_wingmen", title: "Look at the paired Wingmen",
            description: "The Wingmen this instance mirrors Apple Home from: address, state (connected, unreachable, unpaired), how many accessories, "
                + "how many do not respond, the homes, the last error.",
            path: "wingmen", access: .read),
        AssistantAction(
            name: "discover", title: "Look for Wingmen",
            description: "The Wingman apps Bonjour finds on the network (_homeswift-wingman._tcp), each with its address, version, whether pairing "
                + "is open and its certificate fingerprint as this machine sees it. To pair one, the user chooses Pair a Homeswift Bridge in "
                + "Wingman's menu, compares the fingerprint with the one Wingman shows, and gives the 6-digit code.",
            path: "discover", access: .read),
        AssistantAction(
            name: "pair", title: "Pair a Wingman",
            description: "Pairs with the Wingman at host and port, with the 6-digit code its menu shows and the fingerprint discover answered "
                + "(pinned). Answers its entry for devices (id, host, token, fingerprint): add it with put_list_entry (platform Wingman, "
                + "list devices, match id), keeping every value as given.",
            method: "POST", path: "pair", access: .configure,
            inputSchema: [
                "type": "object", "required": ["host", "code", "fingerprint"],
                "properties": [
                    "host": ["type": "string"], "port": ["type": "integer"],
                    "code": ["type": "string", "pattern": "^[0-9]{6}$", "description": "The 6 digits Wingman shows"],
                    "fingerprint": ["type": "string", "description": "The certificate SHA-256 discover answered"],
                    "name": ["type": "string", "description": "A name for this Wingman, e.g. the Mac's"],
                ],
            ]),
    ]

    public static let assistantBackground: String? = """
        Wingman (Homeswift Wingman) is a menu bar app on a Mac that reads the Apple Home with HomeKit and serves it over \
        TLS on port 8619 to the Homeswift bridges paired with it; Linux and Docker bridges reach it over the network. This \
        plugin finds it over Bonjour (_homeswift-wingman._tcp, so the bridge and the Mac need the same network with mDNS), \
        pairs with the 6-digit code Wingman's menu shows for ten minutes (Pair a Homeswift Bridge), pins its certificate, \
        then mirrors the Home app's accessories into Homeswift: the web UI, moods, scenes, automations and the MCP tools \
        use them, but they are never published to HomeKit again (the Home app has them already). Homeswift's own \
        accessories are left out. "Wingman does not know this bridge any more" means it was removed from Wingman's \
        Paired Bridges: pair again. "Wingman's certificate is not the one pinned" means Wingman was reinstalled on \
        another Mac or user, or something intercepts the connection. "changes are turned off in Wingman's settings" \
        means Wingman's "Let bridges change accessories" is off. Matter accessories (Hue, IKEA) cannot be read by \
        Wingman (HomeKit error 74) but report changes and accept writes; error 74 on a write means the device did not \
        answer (switched off at the wall). Wingman runs only on Macs registered in its developer's team (development \
        signing). Never ask for the token.
        """
}
