import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The page's routes for the Assistant: the connection's state, the account's devices, a test command.
    /// Signing in is Setup's (`start_setup` for an AI agent), never a route of the page.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "status", title: "Check the connection",
            description: "Whether the instance is configured and initialized, its connection mode (auto, lan or wan), whether the eWeLink "
                + "WebSocket is connected, how many devices LAN control found, how many accessories it publishes, and whether it is waiting "
                + "to retry a failed login or discovery (the bridge's log says why).",
            path: "status", access: .read),
        AssistantAction(
            name: "list_devices", title: "Look at the devices",
            description: "The devices of the eWeLink account, from the cloud, with what a 3-second mDNS scan finds on the LAN: deviceId, name, "
                + "brand, model, uiid, online, lanEnabled, lanIp and lanPort. RF remotes and sensors an RF Bridge learned follow their "
                + "bridge as <bridge id>SW<n> (isRfSubdevice, parentDeviceId, buttons). Uses the instance's own session; it answers 401 "
                + "when the instance never signed in (the user then signs in on Add accessories, or an AI agent through start_setup). The deviceId is what singleDevices, "
                + "multiDevices and ignoredDevices take in config.json.",
            path: "devices", access: .read),
        AssistantAction(
            name: "test_device", title: "Send a test command",
            description: "Sends parameters to a device through the eWeLink cloud, by deviceId (list_devices), to check it answers: "
                + "{\"switch\": \"on\"} by default. A multi-channel device takes {\"switches\": [{\"outlet\": 0, \"switch\": \"on\"}]} "
                + "(outlets count from 0: outlet 0 is the Home app's channel 1). Answers success and a message.",
            method: "POST", path: "test-device", access: .configure,
            inputSchema: [
                "type": "object", "required": ["deviceId"],
                "properties": [
                    "deviceId": ["type": "string", "description": "The device's eWeLink id, such as 1000ab23cd"],
                    "params": ["type": "object", "description": "The parameters to send; {\"switch\": \"on\"} when left out"],
                ],
            ],
            confirm: true),
    ]

    /// The Homebridge plugin's `EWELINK_AI_CONTEXT`, for Homeswift: what the Assistant should know to explain this
    /// plugin's errors.
    public static let assistantBackground: String? = [
        "The plugin bridges eWeLink (Sonoff and other eWeLink-compatible) devices to HomeKit in Homeswift.",
        "Connection modes (\"mode\"): \"auto\" tries LAN first and falls back to the cloud, \"lan\" is LAN only, \"wan\" is cloud only.",
        "LAN control needs the device on the same subnet as the Homeswift host and announced over mDNS (_ewelink._tcp); VLANs,",
        "client isolation or mDNS filtering make devices show \"LAN: No IP\" on the plugin's page. Sub-devices (RF remotes,",
        "Zigbee) go through their bridge (RF Bridge UIID 28/98). Cloud mode logs in with the eWeLink account (email or phone",
        "number, password, country code); the country code picks the API region (eu, us, as, cn) and the server redirects to",
        "the right one (error 10004). The session is kept sealed in the bridge's vault (vault.json, the entry",
        "plugin.<instance>.ewelink-tokens.json; it was ewelink-tokens.json in the plugin's folder plugins/eWeLink-<name>/ before, beside",
        "devices.json, the last discovery). Common eWeLink errors:",
        "10001/10014 wrong password or account; 401/402 access token expired (the plugin refreshes it); 406 on the WebSocket",
        "(logged as AUTH_TOKEN_INVALIDATED) means the session was invalidated, usually because the same account logged in",
        "elsewhere with the same app ID - a dedicated eWeLink account shared to the main one avoids it; 500 eWeLink server",
        "error; 503/504 or \"offline\" means the device did not answer (powered off, weak Wi-Fi, or not connected to the cloud).",
        "Devices are identified by deviceId and UIID (the eWeLink model type). Never ask the user for their password, tokens",
        "or API keys.",
    ].joined(separator: " ")
}
