import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The page's routes for the Assistant: the connection's state, the account's devices, a test command.
    /// Signing in (`POST login`) takes the account's password, so it stays the page's.
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
                + "when the instance never signed in (the user then signs in on the plugin's page). The deviceId is what singleDevices, "
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
}
