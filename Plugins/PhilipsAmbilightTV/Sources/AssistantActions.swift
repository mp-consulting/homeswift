import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// The page's routes for the Assistant: list, find and pair TVs, wake one, press a key.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_tvs", title: "Look at the TVs",
            description: "The TVs this instance runs, by MAC address, with their address, power, input, Ambilight and whether they answer.",
            path: "tvs", access: .read),
        AssistantAction(
            name: "discover", title: "Look for TVs",
            description: "Looks for Philips Android TVs on the network for about five seconds (they announce themselves only while on). Answers each TV's name and IPv4 address (host).",
            path: "discover", access: .read),
        AssistantAction(
            name: "pair", title: "Start pairing",
            description: "Starts pairing with the TV at an IPv4 address: the TV then shows a 4-digit PIN on screen for a few minutes. "
                + "Ask the user for that PIN, then call pair_grant. The TV must be on.",
            method: "POST", path: "pair", access: .configure,
            inputSchema: ["type": "object", "required": ["ip"], "properties": ["ip": ["type": "string", "description": "The TV's IPv4 address"]]]),
        AssistantAction(
            name: "pair_grant", title: "Finish pairing",
            description: "Finishes pairing with the PIN the TV shows. Answers the TV's entry for the devices list (ip, username, password, certFingerprint, mac): "
                + "add it with put_list_entry (platform PhilipsAmbilightTV, list devices, match mac) with a name for the Home app, and keep every value as given. "
                + "Without a mac, ask the user for the TV's MAC address (Settings › Network › View network settings).",
            method: "POST", path: "pair/grant", access: .configure,
            inputSchema: [
                "type": "object", "required": ["ip", "pin"],
                "properties": ["ip": ["type": "string"], "pin": ["type": "string", "pattern": "^[0-9]{4}$", "description": "The 4 digits the TV shows"]],
            ]),
        AssistantAction(
            name: "wake", title: "Wake a TV",
            description: "Sends a Wake-on-LAN packet to a TV by its MAC address (a configured TV, or one being paired), to switch it on from deep standby.",
            method: "POST", path: "wake", access: .control,
            inputSchema: ["type": "object", "required": ["mac"], "properties": ["mac": ["type": "string"]]], queryKeys: ["mac"]),
        AssistantAction(
            name: "press_key", title: "Press a remote key",
            description: "Sends one remote key to a configured TV, by its MAC address: Standby, Home, Back, VolumeUp, Mute, AmbilightOnOff, CursorUp, Confirm and so on.",
            method: "POST", path: "key", access: .control,
            inputSchema: [
                "type": "object", "required": ["mac", "key"],
                "properties": ["mac": ["type": "string"], "key": ["type": "string", "enum": .array(RemoteKeys.all.sorted().map(JSONValue.string))]],
            ]),
    ]
}

extension PhilipsAmbilightTVPlugin {
    /// The Homebridge plugin's `PHILIPS_TV_AI_CONTEXT`, for this port: its files, its messages.
    public static let assistantBackground: String? = """
        The plugin exposes Philips Android TVs (Ambilight) to HomeKit as Television accessories, each on a HAP server of its \
        own (added in the Home app with the bridge's setup code), all on the local network: it talks to the TV's JointSpace \
        API v6 over HTTPS on port 1926 with Digest authentication and follows state with a long-poll on /6/notifychange \
        plus regular polling ("pollingInterval", default 10000 ms; out of 1000-60000 the default is used with a warning). \
        Discovery on the plugin's page looks for the Android TV remote service over mDNS (_androidtvremote2._tcp) for about \
        5 seconds, so the TV must be on (not in deep standby) and on the same subnet/VLAN as Homeswift with mDNS allowed; \
        otherwise enter the IP by hand. Pairing: the plugin asks the TV for a PIN (pair/request), the TV shows a 4-digit \
        PIN, and the grant (pair/grant) returns the username and password (auth key) saved in the TV's entry. A pairing \
        expires after 5 minutes ("the pairing expired; start again"). Pairing errors from the TV: 401 invalid PIN, 403 the \
        TV rejected the pairing request, 404 pairing endpoint not found (older or non-Android TVs without JointSpace v6 \
        pairing are not supported), 408 timeout, 500 TV internal error, 503 TV temporarily unavailable. "Cannot reach the \
        TV" and "the TV did not answer" mean the TV is off or in standby, on another network, or the IP changed (a DHCP \
        reservation helps). "the TV refused the credentials: pair it again" follows a reset of the TV. The TV \
        certificate's SHA-256 fingerprint ("certFingerprint") is pinned at pairing; "the TV's certificate (...) is not the \
        pinned one" means the TV was reset or replaced (pair again) or something on the network intercepts the connection. \
        Turning the TV on from standby uses Wake-on-LAN to its MAC address (the TV's Wake on LAN / switch on with Wi-Fi or \
        Chromecast setting must be enabled; Docker or several networks can send the packet out the wrong interface). A TV \
        that just woke is slow to list its apps, so "Refresh from TV" can fail until the Home screen shows. "Detect from \
        TV" for custom apps needs the app open in the foreground, not live TV or Home; "Could not launch ...: set the app's \
        launch activity" means the app needs its className in customApps. The plugin keeps inputs-<mac>.json and \
        switch-names-<mac>.json in its storage directory (plugins/PhilipsAmbilightTV-<instance>/ under the Homeswift \
        configuration directory). Changing the MAC address makes the TV a new HomeKit accessory. Never ask the user for \
        the pairing username, password (auth key) or API keys.
        """
}
