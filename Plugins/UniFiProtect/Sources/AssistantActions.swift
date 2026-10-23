import HomeswiftPlugin

extension UniFiProtectPlugin {
    /// The page's routes for the Assistant: the running controllers and their devices, the feature option
    /// catalog, console discovery and a reachability check. All read-only: the routes that sign in with a
    /// password the page sends (`devices`, `onvif`) or fetch a URL that may carry one (`snapshot`) stay the
    /// page's.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_controllers", title: "Look at the controllers",
            description: "The UniFi Protect controllers this instance runs: address, name, whether it is connected (bootstrapped), throttled "
                + "(paused for five minutes after repeated errors) and following realtime events, the pinned TLS certificate fingerprint, and each "
                + "device it put in HomeKit with its accessory id, type (modelKey: camera, chime, light, sensor, viewer), MAC and whether Protect reports it online.",
            path: "controllers", access: .read),
        AssistantAction(
            name: "list_options", title: "Read the feature options",
            description: "The catalog of feature options: categories, and per category each option's name, default (on or off), default value "
                + "and description. An option is written Enable.<Category>.<Option> or Disable.<Category>.<Option> in the block's options list, "
                + "optionally with .<value> and a device MAC (or the controller's MAC or address) at the end to scope it.",
            path: "options", access: .read),
        AssistantAction(
            name: "discover", title: "Look for UniFi consoles",
            description: "Looks for UniFi consoles on the local network for a few seconds. Answers each console's name, model (model, modelLong), "
                + "IPv4 address (ip), MAC and firmware, for the address of a new controller entry.",
            path: "discover", access: .read),
        AssistantAction(
            name: "check_controller", title: "Check a controller",
            description: "Whether a controller answers HTTPS on port 443 at an address (an IP address or a host name on the local network), "
                + "within five seconds. Answers online true or false; loopback, link-local and unspecified addresses are refused (false).",
            method: "POST", path: "check-status", access: .read,
            inputSchema: ["type": "object", "required": ["address"], "properties": ["address": ["type": "string", "description": "The controller's IP address or host name"]]]),
    ]

    /// What the Assistant knows about Protect controllers and their errors (`UNIFI_PROTECT_AI_CONTEXT` of the Homebridge plugin).
    public static let assistantBackground: String? = [
        "The plugin bridges a UniFi Protect controller (a UniFi OS console or NVR running Protect v6 or later; official releases only, no betas) and its cameras,",
        "doorbells, sensors, chimes, lights and viewers, plus third-party ONVIF cameras adopted in Protect, to HomeKit, with FFmpeg-based streaming, HomeKit",
        "Secure Video (HKSV), realtime events over the controller's events WebSocket and optional MQTT publishing. It runs in Homeswift, a HomeKit bridge.",
        "Each entry in \"controllers\" has an address, username and password; it connects locally over HTTPS (port 443) to the UniFi OS API. It needs a local",
        "user on the console (Ubiquiti.com/UI.com cloud accounts and two-factor authentication are not supported); the Full Management role gives every",
        "feature, at least view-only is needed to see cameras, and enabling RTSP streams needs the Administrator role (\"Insufficient privileges to enable",
        "RTSP\"). Common errors: \"Invalid login credentials given\" is HTTP 401 (wrong username or password, or a cloud account); \"Insufficient privileges for",
        "this user\" is HTTP 403; \"Unable to connect to the Protect controller. This is temporary and may occur during device reboots.\" covers 400, 404, 429 and",
        "5xx answers (Protect not installed, updating or restarting); \"Connection refused\", \"Connection timed out\" and \"Hostname or IP address not found\" mean",
        "a wrong address or a console unreachable from the Homeswift host (VLAN, firewall, Docker networking); \"Protect controller is taking too long to respond\"",
        "is a 3.5 second request timeout; after 10 consecutive errors the plugin pauses API calls for 5 minutes (\"Throttling API calls\"). The plugin's settings",
        "page gives a controller 20 seconds to log in and bootstrap (\"Timed out after 20s waiting for ... to respond\") and refuses loopback and link-local",
        "addresses (\"Connections to ... are not permitted\"). TLS: by default (\"verifyTls\" off) the console's self-signed certificate is pinned on first",
        "connection (trust on first use) in unifi-protect-tls-pins.json, in the plugin's directory under the Homeswift configuration directory",
        "(plugins/<platform>-<name>/, such as ~/.homeswift/plugins/UniFi-Protect-UniFi-Protect/); \"does not match the pinned certificate. Refusing to",
        "connect\" means the certificate was regenerated (remove that controller's entry from the file and restart Homeswift) or the connection is being",
        "intercepted. \"verifyTls\" on requires a CA-signed certificate. Discovery uses the Ubiquiti discovery protocol (UDP port 10001) on local and nearby",
        "subnets, so consoles behind routers may need to be added by address. A device whose state is not CONNECTED is offline in Protect itself (power, PoE,",
        "Wi-Fi, adoption). Third-party cameras get their RTSP and snapshot URLs from ONVIF discovery, which tries ports 80, 8000, 8080, 2020 and 8899 on",
        "/onvif/device_service; \"No reachable ONVIF service\" usually means ONVIF is disabled on the camera or uses another port or path, and authorization",
        "errors mean wrong camera (ONVIF) credentials. \"Snapshots work but video streaming does not\" is almost always the network interface Homeswift",
        "advertises (Docker, VMs, several NICs). Streaming needs FFmpeg with fdk-aac or AudioToolbox AAC (the ffmpeg on the path, or the \"videoProcessor\"",
        "option). Feature options (\"options\") enable or disable features per controller or device. Never ask the user for their controller or camera",
        "password, API keys or tokens.",
    ].joined(separator: " ")
}
