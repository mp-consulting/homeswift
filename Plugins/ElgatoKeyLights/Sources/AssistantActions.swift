import HomeswiftPlugin

extension ElgatoKeyLightsPlugin {
    /// The page's routes for the Assistant: list the lights, check an address, flash a light.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_lights", title: "Look at the lights",
            description: "The lights this instance found (over Bonjour or from config.json), by MAC address, with their address, model, firmware and state.",
            path: "lights", access: .read),
        AssistantAction(
            name: "probe", title: "Check an address",
            description: "Asks the light at an address who it is: name, model, MAC address, serial number, firmware. "
                + "For a light Bonjour does not reach: add it with put_list_entry (platform ElgatoKeyLights, list devices, match mac) "
                + "as {\"mac\", \"name\", \"ip\", \"model\"}, plus \"port\" when it is not 9123.",
            path: "probe", access: .read,
            inputSchema: [
                "type": "object", "required": ["host"],
                "properties": ["host": ["type": "string", "description": "IP address or host name"], "port": ["type": "integer", "minimum": 1, "maximum": 65535]],
            ]),
        AssistantAction(
            name: "identify", title: "Flash a light",
            description: "Flashes a light, by MAC address, so the user can tell which one it is.",
            method: "POST", path: "identify", access: .control,
            inputSchema: ["type": "object", "required": ["mac"], "properties": ["mac": ["type": "string"]]], queryKeys: ["mac"]),
    ]
}
