import HomeswiftPlugin

extension UniFiAccessPlugin {
    /// The page's routes for the Assistant: what the instance runs, the feature options, finding consoles and
    /// checking an address. Nothing here unlocks: doors and gates are HomeKit accessories, written only through
    /// `set_security_accessory`. The page's `devices` route is left out, as it takes the controller's password.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_controllers", title: "Look at the controllers",
            description: "The UniFi Access controllers this instance runs: address, name, MAC, whether it is connected, and its hubs and readers "
                + "(accessory id, name, model, online, featureId for feature options) with their state: locked, door (open, closed, opening, closing) "
                + "when it has a position sensor or is a UA Gate, sideDoorLocked and sideDoor for a UA Gate's side door, accessMethods (on or off) for a reader.",
            path: "controllers", access: .read),
        AssistantAction(
            name: "list_options", title: "Look at the feature options",
            description: "The feature options the plugin knows, by category: name, default, description, and defaultValue for those that take a number. "
                + "An option goes in the block's options array as Enable.<name> or Disable.<name>, optionally scoped with .<featureId> of a device or "
                + ".<MAC without separators> of a controller, and for an option with a value followed by it: Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5.",
            path: "options", access: .read),
        AssistantAction(
            name: "discover", title: "Look for UniFi consoles",
            description: "Looks for UniFi consoles on the local network for about five seconds (Ubiquiti's discovery protocol). "
                + "Answers each one's ip, mac, name, model and firmware. A console is added to the block's controllers list with its address "
                + "and a local user's username and password, which the user types in the plugin's page or config.json.",
            path: "discover", access: .read),
        AssistantAction(
            name: "check_controller", title: "Check a controller's address",
            description: "Whether a UniFi console answers at an address (an IP address or host name, optionally with a port): {\"online\": true or false}. "
                + "Loopback, link-local and unspecified addresses are refused and answer false.",
            method: "POST", path: "status", access: .read,
            inputSchema: ["type": "object", "required": ["address"], "properties": ["address": ["type": "string", "description": "IP address or host name"]]]),
    ]
}

extension UniFiAccessPlugin {
    /// What the Assistant knows about UniFi Access with every Explain and request from the page.
    public static let assistantBackground: String? = [
        "The Homeswift plugin bridges a UniFi Access controller (a UniFi OS console such as a UDM, UDM Pro, UDR, Cloud Key or UNVR running the Access",
        "application) and its devices (UA Hub, UA Hub Door Mini, UA Ultra, UA Gate, UA readers) to HomeKit as locks, a garage door opener for a UA Gate,",
        "doorbells, door position (DPS) and request-to-exit sensors and access method switches, with realtime updates over the controller's events",
        "WebSocket and optional MQTT publishing. Each entry in \"controllers\" has an address, username and password; it connects locally over HTTPS",
        "(port 443) to the UniFi OS API (/proxy/access/api/v2/...). Use a local user on the console whose role grants access to UniFi Access; Ubiquiti",
        "cloud (SSO) accounts with 2FA are not supported. Common errors: \"Invalid login credentials given\" is HTTP 401 (wrong username or password, or",
        "a cloud account); \"Insufficient privileges for this user\" is HTTP 403 (the user lacks an Access role); \"Unable to connect to the Access",
        "controller. This is usually temporary and will occur during device reboots.\" covers 400, 404, 429 and 5xx answers (the Access application is",
        "not installed, updating or restarting); \"Connection refused.\" and \"Hostname or IP address not found\" mean a wrong address or the console is",
        "unreachable from the Homeswift host (VLAN, firewall); \"Access controller is taking too long to respond\" is a 3.5 second request timeout;",
        "after 10 consecutive errors the plugin pauses API calls for 5 minutes (\"Throttling API calls\"). TLS: by default (\"verifyTls\" off) the",
        "console's self-signed certificate is pinned on first connection (trust on first use) in unifi-access-tls-pins.json in the plugin's directory",
        "(under plugins/ in the Homeswift config directory); \"does not match the pinned certificate\" or \"Refusing TLS connection\" means the",
        "certificate was regenerated (for example after a console reset or replacement; remove that controller's entry from the pin file) or the",
        "connection is being intercepted. \"verifyTls\" on requires a CA-signed certificate. Discovery uses the Ubiquiti discovery protocol (UDP port",
        "10001) on local and nearby subnets, so consoles behind routers or firewalls may need to be added by address. A device shown as disconnected is",
        "offline in UniFi Access itself (power, PoE, cabling or adoption). Feature options (\"options\") enable or disable features per controller, hub",
        "or device; \"debugAll\" logs the plugin's debug lines at the info level. Never ask the user for their controller password, API keys or tokens.",
    ].joined(separator: " ")
}
