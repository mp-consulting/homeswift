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
}
