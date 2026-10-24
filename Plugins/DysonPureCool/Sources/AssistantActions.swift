import HomeswiftPlugin

extension DysonPureCoolPlugin {
    /// The page's routes for the Assistant: list the devices and their state, the product types, and read or
    /// set continuous monitoring. Not the Dyson account sign-in, which takes the user's password and emailed code.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_devices", title: "Look at the Dyson devices",
            description: "The devices this instance runs, by serial number: name, model, product type, address, whether the bridge is connected "
                + "(retrying means it did not answer and is tried again every five minutes), power, auto mode, fan speed (1-10), "
                + "continuous monitoring, temperature (°C), humidity (%), PM2.5 and filter life (%).",
            path: "devices", access: .read),
        AssistantAction(
            name: "product_types", title: "List the Dyson models",
            description: "The product type codes the plugin knows (\"438\" is a Pure Cool Tower TP04, \"527\" a Hot+Cool HP04…) with their names, "
                + "and which of them heat or have Jet Focus. A device's productType in config.json is one of these codes.",
            path: "get-product-types", access: .read),
        AssistantAction(
            name: "device_state", title: "Check a Dyson device",
            description: "Asks a configured device, by serial number, whether continuous monitoring is on, over the bridge's connection or a short "
                + "one of its own. When the device answered at a new address, discoveredIp is it: ipAddress in its devices entry can be updated to it.",
            method: "POST", path: "get-device-state", access: .read,
            inputSchema: ["type": "object", "required": ["serial"], "properties": ["serial": ["type": "string", "description": "The serial number, as list_devices gives it"]]]),
        AssistantAction(
            name: "set_continuous_monitoring", title: "Set continuous monitoring",
            description: "Switches continuous monitoring of a configured device, by serial number, on or off: on, the sensors keep measuring while "
                + "the fan is off (a little power); off, Link models report their temperature and humidity as not current while the fan is idle.",
            method: "POST", path: "set-continuous-monitoring", access: .configure,
            inputSchema: [
                "type": "object", "required": ["serial", "enabled"],
                "properties": ["serial": ["type": "string"], "enabled": ["type": "boolean"]],
            ],
            confirm: true),
    ]

    /// The Homebridge plugin's `DYSON_AI_CONTEXT`, for Homeswift: what the Assistant should know to explain this
    /// plugin's errors.
    public static let assistantBackground: String? = [
        "The plugin bridges Dyson purifiers and fans (Pure Cool, Hot+Cool HP, Humidify+Cool PH, Big+Quiet) to HomeKit in Homeswift.",
        "The Dyson account is only used on the plugin's page (Plugins, Open), to download each device's local MQTT credentials from",
        "the Dyson cloud (appapi.cp.dyson.com): it checks the account status, emails a 6-digit verification code, then reads the",
        "device manifest; the devices and their credentials are saved in the instance's block of config.json (devices[]). The country",
        "must match the account's Dyson market, or the code is issued for the wrong region. Page errors: \"Account not active or not",
        "found\" (wrong email or country), \"Unable to authenticate\" (Dyson rejected the login; the password is checked together with",
        "the code), \"Invalid verification code\", \"No pending authentication\" (the code request expired after 10 minutes, start",
        "again), \"Session expired\" (the cloud token was rejected while listing devices), \"Request timed out\" or \"Network error\"",
        "(the Homeswift host cannot reach the Dyson cloud), \"Invalid response from Dyson API\". After setup everything is local: the",
        "plugin finds each device over mDNS (_dyson_mqtt._tcp, for discoveryTimeout seconds; an mDNS answer without a local IPv4",
        "record falls back to the private address that sent it) or uses its saved \"ipAddress\", and connects to the device's MQTT",
        "broker on TCP port 1883 with the serial number as user name and the local credential as password, trying several CONNECT",
        "variants (client id, clean session, MQTT 3.1.1, 5 and 3.1) when the device refuses one. \"Device <serial> not found on",
        "network\" means mDNS did not see it and no IP worked: the device must be on the same subnet (VLANs, client isolation or mDNS",
        "filtering block discovery), so set a DHCP reservation and its IP. \"Connection timeout after <n>ms\" or \"Timeout waiting for",
        "device state\" means the device did not answer on port 1883 (offline, weak Wi-Fi, firewall, or a changed IP); after five",
        "failed reconnections the device is retried every five minutes. \"Connection refused: Not authorized\" or \"Connection",
        "refused: Bad username or password\" means the saved local credential is stale, so use Re-sync from Dyson Cloud on the page.",
        "Older Link models (HP02, TP02, DP01) and newer models (HP04+, TP04+) use different MQTT fields; Link models are also asked",
        "for their sensor data on every poll. Continuous monitoring (\"rhtm\") keeps the sensors running while the fan is off and is",
        "needed for sensor updates then. Without it the device reports its sensors as OFF while the fan is idle: the temperature",
        "and humidity sensors are marked inactive (Status Active off) and keep their last reading, and with no reading since the",
        "bridge started they show -40 °C and 0 %. That is not a fault or an offline device: turning the fan on, or continuous",
        "monitoring on (the device's switch, shown with isContinuousMonitoringEnabled), brings readings back. \"pollingInterval\"",
        "sets how often state is requested (seconds); temperatureOffset and",
        "humidityOffset calibrate readings. Never ask the user for their password, verification codes, local credentials, tokens or",
        "API keys.",
    ].joined(separator: " ")
}
