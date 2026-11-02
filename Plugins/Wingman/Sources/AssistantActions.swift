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
        accessories are left out. "Wingman does not know this bridge any more" means it was removed from Wingman's \
        Paired Bridges: set it up again on Add accessories. "Wingman's certificate is not the one pinned" means Wingman was reinstalled on \
        another Mac or user, or something intercepts the connection. "changes are turned off in Wingman's settings" \
        means Wingman's "Let bridges change accessories" is off. Matter accessories (Hue, IKEA) cannot be read by \
        Wingman (HomeKit error 74) but report changes and accept writes; error 74 on a write means the device did not \
        answer (switched off at the wall). Wingman runs only on Macs registered in its developer's team (development \
        signing). Never ask for the token.
        """
}
