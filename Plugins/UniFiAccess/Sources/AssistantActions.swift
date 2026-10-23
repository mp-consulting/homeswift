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
