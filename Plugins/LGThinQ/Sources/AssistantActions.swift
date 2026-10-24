import HomeswiftPlugin

extension LGThinQPlugin {
    /// The page's routes for the Assistant: what the instance runs, the account's devices, LG's sign-in page.
    /// The sign-ins themselves (a password, or the address LG's page ends on, which carries a token) stay on
    /// the plugin's page.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_devices", title: "Look at the appliances",
            description: "The LG appliances this instance runs: id (LG's device id), name, type (AC, WASHER, DISHWASHER…), model, "
                + "platform (thinq1 is polled, thinq2 is pushed), online (as LG last reported it), external (paired in the Home app on its own) "
                + "and accessory (the accessory id for get_accessory, which has their current state).",
            path: "devices", access: .read),
        AssistantAction(
            name: "list_account_devices", title: "Look at the LG account",
            description: "Every appliance of the LG account this instance signed in with, asked from LG's cloud: id, name, type, model, platform, online, "
                + "supported (Homeswift has a HomeKit accessory for it), configured (the block's devices list is empty, so it runs all of them, or lists it) "
                + "and running. complete is false when LG did not answer for every home. To run only some appliances, add each with put_list_entry "
                + "(platform LGThinQ, list devices, match id) as {\"id\", \"name\", \"type\"} with the values given here; thinq1 appliances also need "
                + "\"thinq1\": true in the block.",
            path: "account-devices", access: .read),
        AssistantAction(
            name: "login_url", title: "Get LG's sign-in page",
            description: "The address of LG's own sign-in page, for LG accounts that sign in with Google, Apple, Facebook or Amazon. Give it to the user: "
                + "after signing in there, they paste the address the page ends on (it contains iabClose) on the LG ThinQ plugin page in the web UI, "
                + "never in the chat, since it carries a sign-in token. country and language default to the block's (US, en-US without one).",
            path: "login-url", access: .read,
            inputSchema: [
                "type": "object",
                "properties": [
                    "country": ["type": "string", "description": "The account's country code, such as US or FR"],
                    "language": ["type": "string", "description": "The account's language, such as en-US or fr-FR"],
                ],
            ]),
    ]

    /// What the Assistant knows about LG ThinQ and its errors (`THINQ_AI_CONTEXT` of the Homebridge plugin).
    public static let assistantBackground: String? = [
        "The plugin bridges LG ThinQ appliances (AC, air purifiers and AeroTowers, refrigerators, washers, dryers, wash towers, dishwashers,",
        "dehumidifiers, ovens, microwaves, range hoods, stylers) to HomeKit through the LG ThinQ cloud, in Homeswift (a HomeKit bridge); there is no",
        "local control. ThinQ v2 devices get real-time updates over MQTT (AWS IoT); legacy ThinQ v1 devices are only added when \"thinq1\" is",
        "enabled and are polled every \"refresh_interval\" seconds. Authentication (\"auth_mode\"): \"account\" signs in with the LG account email and",
        "password; \"token\" uses a refresh token. Accounts that sign in to LG with Google, Apple, Facebook or Amazon cannot use a password: they",
        "need a refresh token, which the plugin's page gets from LG's sign-in page (paste the address LG ends on). The page signs in with email and",
        "password once, then stores only the refresh token in the block (unless asked to remember them). \"country\" and \"language\" (e.g. US /",
        "en-US) must match the LG account region, or login and the device list fail. Errors: \"LG rejected the sign-in\" means wrong credentials",
        "or a social-login account; \"Your account was already used to registered in ...\" (LG code MS.001.03) means the account belongs to another",
        "country; resultCode 0110 (manual process needed) and \"Open the LG ThinQ app and accept the new terms\" mean the user must sign in to the LG",
        "ThinQ app and accept new agreements; 0102 is an expired token (the plugin refreshes it; HTTP 401/403 too); 0106/0111 or 9999 (not",
        "connected) mean the device or the LG server is not reachable (the plugin retries discovery every 30 s); HTTP 429 / resultCode 9012 is LG",
        "rate limiting (\"LG ThinQ API rate limit hit\": requests pause 1 to 30 minutes; increase the refresh interval or use fewer ThinQ",
        "integrations); \"Internal Server Error\" or connection errors are LG outages. The MQTT client key, its certificate request and the models",
        "are kept in the plugin's directory under the Homeswift configuration directory (plugins/<platform>-<name>/persist, such as",
        "~/.homeswift/plugins/LGThinQ-LG-ThinQ/persist). An appliance shown offline is not connected to LG's cloud (Wi-Fi, power, or removed",
        "from the ThinQ app). An air conditioner's humidity sensor (ac_humidity_sensor) reads 0 % and is marked inactive (Status Active off)",
        "while the AC is off, because LG reports humidity only while it runs: that is expected, not a fault. Never ask the user for their",
        "password, refresh token or API keys.",
    ].joined(separator: " ")
}
