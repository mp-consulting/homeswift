import HomeswiftPlugin

extension LGThinQPlugin {
    /// The page's routes for the Assistant: what the instance runs and the account's devices. Signing in is Setup's
    /// (`start_setup`, or Add accessories in the web UI).
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_devices", title: "Look at the appliances",
            description: "The LG appliances this instance runs: id (LG's device id), name, type (AC, WASHER, DISHWASHER…), model, "
                + "platform (thinq1 is polled, thinq2 is pushed), online (as LG last reported it), external (paired in the Home app on its own) "
                + "and accessory (the accessory id for get_accessory, which has their current state).",
            path: "devices", access: .read),
        AssistantAction(
            name: "list_account_devices", title: "Look at the LG account",
            description: "Every appliance of the LG account this instance signed in with, asked from LG's cloud: id (the Device Id: the accessory is LGThinQ:<id>), "
                + "name, type (its Device Kind: AC, WASHER, DISHWASHER…), model, platform, online, supported (Homeswift has a HomeKit accessory for it), "
                + "excluded (Excluded in its Accessory Settings), configured (false when a Homebridge block's devices list leaves it out) and running. "
                + "complete is false when LG did not answer for every home. An appliance's settings (its Name, Excluded, serial_number and the options "
                + "of its type, such as ac_mode or washer_trigger) are read with get_settings and written with update_settings by accessory "
                + "(LGThinQ:<id>); thinq1, refresh_interval, country and language by plugin. thinq1 appliances also need \"thinq1\": true.",
            path: "account-devices", access: .read),
    ]

    /// What the Assistant knows about LG ThinQ and its errors (`THINQ_AI_CONTEXT` of the Homebridge plugin).
    public static let assistantBackground: String? = [
        "The plugin bridges LG ThinQ appliances (AC, air purifiers and AeroTowers, refrigerators, washers, dryers, wash towers, dishwashers,",
        "dehumidifiers, ovens, microwaves, range hoods, stylers) to HomeKit through the LG ThinQ cloud, in Homeswift (a HomeKit bridge); there is no",
        "local control. ThinQ v2 devices get real-time updates over MQTT (AWS IoT); legacy ThinQ v1 devices are only added when \"thinq1\" is",
        "enabled and are polled every \"refresh_interval\" seconds. Authentication (\"auth_mode\"): \"account\" signs in with the LG account email and",
        "password; \"token\" uses a refresh token. Accounts that sign in to LG with Google, Apple, Facebook or Amazon cannot use a password: they",
        "sign in on LG's own page. Signing in is Setup's (start_setup for the LGThinQ account, or Add accessories in the web UI): it asks the way, the",
        "region, then the email and password or LG's page and the address it ends on, and keeps only the refresh token (and the email), sealed in the vault. \"country\" and \"language\" (e.g. US /",
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
        "while the AC is off, because LG reports humidity only while it runs: that is expected, not a fault. Settings are read with",
        "get_settings and written with update_settings: by plugin for \"thinq1\", \"refresh_interval\", \"country\" and \"language\", by accessory",
        "(LGThinQ:<device id>) for an appliance's Name, Excluded, \"serial_number\" and the options of its type (ac_mode, ac_swing_mode,",
        "ac_temperature_unit, ac_buttons and the ac_* switches for an AC; washer_trigger, washer_tub_clean, washer_door_lock for washers and",
        "dryers; dishwasher_trigger; ref_express_freezer, ref_express_fridge, ref_eco_friendly; air_fast_mode). Never ask the user for their",
        "password, refresh token or API keys.",
    ].joined(separator: " ")
}
