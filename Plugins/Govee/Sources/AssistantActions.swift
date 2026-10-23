import HomeswiftPlugin

extension GoveePlugin {
    /// The page's routes for the Assistant: the instance's devices, the account's, scenes and DIY effects for a
    /// light, and clearing the kept login. Logins use the instance's account, so no password goes through the model.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_devices", title: "Look at the Govee devices",
            description: "The devices this instance runs, by deviceId: name, model, the config.json list their entry goes in (list: lightDevices, "
                + "switchDevices, thermoDevices…), kind, and for each way of reaching them (lan, aws, ble) enabled, disabled or unsupported; "
                + "lastUpdate is when the device last reported, in milliseconds since 1970. A device that never reports, or has every way "
                + "disabled or unsupported, cannot be controlled.",
            path: "devices", access: .read),
        AssistantAction(
            name: "discovered_devices", title: "Look at the discovered devices",
            description: "The devices the instance found at its last start, in the Govee account and on the LAN: deviceId, deviceName, model, "
                + "deviceType (the config.json list for its entry) and ip when the LAN answered. Settings of a device go in an entry of that list "
                + "with put_list_entry (platform Govee, list = deviceType, match deviceId), e.g. {\"deviceId\", \"label\"}, or "
                + "{\"deviceId\", \"customIPAddress\"} for a light the LAN scan does not reach, or {\"deviceId\", \"ignoreDevice\": true}. "
                + "put_list_entry replaces the whole entry: read the block's current entry first and keep its keys.",
            path: "cached-devices", access: .read),
        AssistantAction(
            name: "discover", title: "Ask Govee for the devices",
            description: "Asks Govee's cloud for the account's devices now (the instance's login): deviceId, deviceName, model, deviceType "
                + "(the config.json list for its entry), goodsType, pactType, pactCode, versionSoft, versionHard. Fails without a username and "
                + "password in the block.",
            path: "discover", access: .read),
        AssistantAction(
            name: "scenes", title: "Look at a light's scenes",
            description: "The scene library Govee offers for a light, by category: each scene has sceneId, name and code (and variants). source is "
                + "cloud, or offline (the bundled library, with a warning) when Govee cannot be reached. The answer can be long. A scene becomes a "
                + "HomeKit switch when it is in the light's scenes array: {\"name\", \"sceneCode\": code, \"sceneId\", \"kind\": \"scene\"} in its "
                + "lightDevices entry, written with put_list_entry (platform Govee, list lightDevices, match deviceId) keeping the entry's other keys.",
            method: "POST", path: "scenes", access: .read,
            inputSchema: [
                "type": "object", "required": ["deviceId", "model"],
                "properties": [
                    "deviceId": ["type": "string", "description": "As list_devices gives it, AA:BB:CC:DD:EE:FF:00:11"],
                    "model": ["type": "string", "description": "The model (sku), H6008"],
                    "goodsType": ["type": "integer", "description": "From discover, when known"],
                ],
            ]),
        AssistantAction(
            name: "diy_effects", title: "Look at a light's DIY effects",
            description: "The DIY effects the user made for a light in the Govee app (from the cloud): diyId, name, code. One goes in the light's scenes "
                + "array like a scene: {\"name\", \"sceneCode\": code, \"sceneId\": diyId, \"kind\": \"diy\"}.",
            method: "POST", path: "diys", access: .read,
            inputSchema: [
                "type": "object", "required": ["deviceId", "model"],
                "properties": ["deviceId": ["type": "string"], "model": ["type": "string"], "goodsType": ["type": "integer"]],
            ]),
        AssistantAction(
            name: "clear_cache", title: "Forget the Govee login",
            description: "Deletes the kept login and AWS IoT certificate, the discovered devices and the devices' kept state, for a login that "
                + "keeps failing or a changed account. The next start logs in again (Govee may email a verification code, which goes in the block's "
                + "code option); restart the bridge afterwards.",
            method: "POST", path: "clear-cache", access: .configure, confirm: true),
    ]
}
