import HomeswiftPlugin

extension UniFiProtectPlugin {
    /// The page's routes for the Assistant: the running controllers and their devices, the feature option
    /// catalog, console discovery and a reachability check. All read-only: the routes that sign in with a
    /// password the page sends (`devices`, `onvif`) or fetch a URL that may carry one (`snapshot`) stay the
    /// page's.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_controllers", title: "Look at the controllers",
            description: "The UniFi Protect controllers this instance runs: address, name, whether it is connected (bootstrapped), throttled "
                + "(paused for five minutes after repeated errors) and following realtime events, the pinned TLS certificate fingerprint, and each "
                + "device it put in HomeKit with its accessory id, type (modelKey: camera, chime, light, sensor, viewer), MAC and whether Protect reports it online.",
            path: "controllers", access: .read),
        AssistantAction(
            name: "list_options", title: "Read the feature options",
            description: "The catalog of feature options: categories, and per category each option's name, default (on or off), default value "
                + "and description. An option is written Enable.<Category>.<Option> or Disable.<Category>.<Option> in the block's options list, "
                + "optionally with .<value> and a device MAC (or the controller's MAC or address) at the end to scope it.",
            path: "options", access: .read),
        AssistantAction(
            name: "discover", title: "Look for UniFi consoles",
            description: "Looks for UniFi consoles on the local network for a few seconds. Answers each console's name, model (model, modelLong), "
                + "IPv4 address (ip), MAC and firmware, for the address of a new controller entry.",
            path: "discover", access: .read),
        AssistantAction(
            name: "check_controller", title: "Check a controller",
            description: "Whether a controller answers HTTPS on port 443 at an address (an IP address or a host name on the local network), "
                + "within five seconds. Answers online true or false; loopback, link-local and unspecified addresses are refused (false).",
            method: "POST", path: "check-status", access: .read,
            inputSchema: ["type": "object", "required": ["address"], "properties": ["address": ["type": "string", "description": "The controller's IP address or host name"]]]),
    ]
}
