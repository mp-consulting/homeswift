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

extension ElgatoKeyLightsPlugin {
    /// What the Assistant knows about the lights with every Explain and request from the page.
    public static let assistantBackground: String? = [
        "The Homeswift plugin bridges Elgato Key Light, Key Light Air, Key Light Mini and Ring Light to HomeKit. It is local only:",
        "there is no cloud, account or password. Lights are found over Bonjour (service type _elg._tcp, TXT \"id\" = MAC address,",
        "\"md\" = model) and controlled through their HTTP API on port 9123 (/elgato/accessory-info, /elgato/lights,",
        "/elgato/lights/settings, /elgato/identify). Lights are keyed by MAC address: announcements without an id are ignored",
        "(\"Ignoring an Elgato service without a device id\"); entries in config.json without an ip or host only name and tune a light",
        "once Bonjour finds it. A light can be added by IP address and port on the plugin page; such a light is registered even",
        "when Bonjour fails (a container without host networking, VLANs, multicast filtering, Wi-Fi client isolation) and announcements",
        "never move it. By default the plugin connects to the light's .local host name, resolved through the ARP table and then the",
        "addresses Bonjour announced (\"Resolved <host> to <address>\"); \"useIP\" makes it use the announced IP address directly.",
        "A DHCP reservation keeps the address stable. The plugin polls /elgato/lights every \"pollingRate\" ms (default 1000,",
        "minimum 250); after 3 failed polls in a row it logs \"is not responding, will keep retrying\" and HomeKit shows No Response",
        "until a poll succeeds (\"is responding again\"). \"Could not reach <light> at <address>, skipping\" means the first info, lights",
        "and settings requests failed (5 s timeout); the light is retried when Bonjour announces it again. \"The request timed out\"",
        "means no answer (light off or asleep, weak Wi-Fi, wrong address), \"Could not connect to the server\" that nothing listens",
        "on that port, an unreachable host that the address is on another subnet or VLAN. Closing the Elgato Control Center app and",
        "power cycling the light are common fixes. Power-on behaviour: 1 restores the last state, 2 uses the default brightness",
        "(3-100 %) and colour temperature (2900-7000 K, 143-344 mirek); per light, 0 uses the platform's setting, and a colour",
        "temperature of 0 keeps the light's own. Never ask the user for passwords, tokens or API keys.",
    ].joined(separator: " ")
}
