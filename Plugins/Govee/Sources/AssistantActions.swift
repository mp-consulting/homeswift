import HomeswiftPlugin

extension GoveePlugin {
    /// The Homebridge plugin's `GOVEE_AI_CONTEXT` (`homebridge-ui/assistant.js`), for Homeswift's files and logs.
    public static let assistantBackground: String? = [
        "The plugin bridges Govee lights, plugs, sensors, fans, heaters, humidifiers, purifiers, diffusers, kettles and ice makers to",
        "HomeKit. It has four connections, tried in this order for commands: LAN, AWS IoT (cloud), then Bluetooth (BLE); HTTP polling of",
        "the Govee cloud's device list (\"httpRefreshTime\", default and minimum 30 s) refreshes sensors. LAN uses the Govee LAN API:",
        "multicast discovery on 239.255.255.250 (scan port 4001, replies on 4002, commands to port 4003); it needs the device on the same",
        "network or a \"customIPAddress\" plus a DHCP reservation across VLANs, and only models with LAN control turned on in the Govee app.",
        "LAN and BLE work without Govee credentials; the cloud needs the Govee account email and password. The first login triggers",
        "Govee's new-device check (app status 454): Govee emails a one-time verification code to enter in \"code\" (Verification Code),",
        "then restart; \"the Govee verification code was not accepted\" means a wrong or expired code (clear it to get a new one). A login",
        "Homebridge kept in its govee_cache is imported at the first start (homebridgeStoragePath, else ~/.homebridge), so Govee does",
        "not ask again. \"Govee login failed: <message> (HTTP n)\" or \"without an account token\" usually means wrong credentials, or the",
        "account needs attention in the Govee Home app (verification, new terms). \"account token was rejected, logging in again\" is",
        "normal token renewal. \"Unable to reach Govee, retrying in 30 seconds\" is a network problem to app2.govee.com. \"not connected",
        "to AWS\" means the AWS IoT session is down (awsDisable, or the account's IoT certificate is missing from the vault, where the",
        "login is kept with it; Clear Cache removes both with the discovered devices and the devices' state in plugins/Govee-<name>/,",
        "then restart Homeswift; Add accessories signs in to the account again). \"no connection method available\" means a device has no working LAN, AWS or",
        "BLE path. BLE on macOS goes through CoreBluetooth and finds devices by the name they advertise; homeswift must run on its own",
        "(launchd, brew services) or from a terminal app that declares Bluetooth use, or BLE is disabled and the log names the app. On",
        "Linux it uses the adapter hci0 (NOBLE_HCI_DEVICE_ID picks another) through a raw HCI socket, which needs root or CAP_NET_RAW,",
        "and finds devices by MAC address; \"Bluetooth not available on this system\" disables it. \"ignoreMatter\" skips Matter-capable",
        "models. Devices are identified by deviceId (colon-separated hex) and model (SKU such as H6159); \"is not currently supported\"",
        "means an unknown model. The Scene Library falls back to a bundled catalogue without credentials. Never ask the user for their",
        "password, verification code, tokens or API keys.",
    ].joined(separator: " ")

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
