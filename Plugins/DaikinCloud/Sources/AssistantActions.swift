import HomeswiftPlugin

extension DaikinCloudPlugin {
    /// The page's routes for the Assistant: the login's state, the devices, the quota, a connection test, the
    /// callback addresses, and revoking the login. The sign-in routes are left out: they take the Developer
    /// Portal secret, the Onecta password or a one-time code, which the user enters on the plugin's page.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "status", title: "Check the Daikin login",
            description: "Whether this instance holds a Daikin Onecta token (authMode mobile_app or developer_portal), when it expires and whether it refreshes "
                + "by itself, and what the running instance does: devices in HomeKit, WebSocket connected, poll interval in minutes, last fetch. "
                + "When not authenticated, tell the user to sign in on the Daikin Cloud plugin's page in the Homeswift UI.",
            path: "auth/status", access: .read),
        AssistantAction(
            name: "list_devices", title: "Look at the Daikin devices",
            description: "The units of the Daikin account: id (the value excludedDevicesByDeviceId takes), name, model, type, online, features, "
                + "room and outdoor temperature, operation mode and power. Answers the running instance's own list or one fetched in the last five minutes; "
                + "refresh calls the cloud, which spends one of the day's API calls (200 a day with the Developer Portal).",
            path: "devices/list", access: .read,
            inputSchema: [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["mobile_app", "developer_portal"], "description": "Whose token to use; the active one by default"],
                    "refresh": ["type": "boolean", "description": "Fetch from the cloud instead of a recent list"],
                ],
            ]),
        AssistantAction(
            name: "rate_limit", title: "Check the Daikin quota",
            description: "The API calls left this minute and today, as the cloud reported them on the plugin's last call, and how old that report is. Costs no call.",
            path: "rate-limit", access: .read),
        AssistantAction(
            name: "test_connection", title: "Test the Daikin connection",
            description: "Lists the devices with the saved token to check it works; answers success and the device count, or the error. Spends one API call.",
            method: "POST", path: "auth/test", access: .read),
        AssistantAction(
            name: "server_info", title: "Look at this host's addresses",
            description: "This machine's IPv4 addresses and host name, for the Developer Portal login's callback address (callbackServerExternalAddress): "
                + "the redirect URI registered in the portal is https://<address>:<callbackServerPort>.",
            path: "server/info", access: .read),
        AssistantAction(
            name: "revoke", title: "Sign out of Daikin",
            description: "Revokes the Developer Portal token at Daikin and deletes both saved tokens; the running instance disconnects until the user signs in again "
                + "on the plugin's page. The accessories stay in HomeKit.",
            method: "POST", path: "auth/revoke", access: .configure, confirm: true),
    ]

    /// The Homebridge plugin's `DAIKIN_AI_CONTEXT`, for Homeswift: what the Assistant should know to explain this
    /// plugin's errors.
    public static let assistantBackground: String? = [
        "The plugin bridges Daikin air conditioners and Altherma heat pumps (climateControl and domesticHotWaterTank",
        "management points) from the Daikin Onecta cloud to HomeKit in Homeswift; it never talks to the units on the LAN.",
        "Authentication methods (\"authMode\"): \"developer_portal\" uses OAuth 2.0 with a Client ID and Client Secret from",
        "the Daikin Developer Portal and allows 200 API calls per day; \"mobile_app\" logs in with the Onecta app email and",
        "password (Gigya login at id.daikin.eu), allows 3000 calls per day and adds real-time WebSocket updates",
        "(\"enableWebSocket\"). Developer Portal login needs a temporary HTTPS callback server with a self-signed certificate",
        "the plugin makes (the browser warns about it): the redirect URI registered in the portal must be exactly",
        "https://<callbackServerExternalAddress>:<callbackServerPort> (default port 8582), the port must be reachable from",
        "the browser, the bind address (\"oidcCallbackServerBindAddr\", default 0.0.0.0) may only be loopback when the browser",
        "runs on the Homeswift host, and the callback server stops after 10 minutes. Tokens are stored sealed in the bridge's",
        "vault (vault.json), as entries named after the token files .daikin-controller-cloud-tokenset (Developer Portal)",
        "and .daikin-mobile-tokenset (Mobile App); such a file put in the plugin's folder (plugins/DaikinCloud-<name>/)",
        "moves into the vault when the plugin reads it. Common errors: \"Unauthorized (401): Token refresh",
        "failed. Please re-authenticate.\" or \"invalid_grant\" means the refresh token expired or was revoked, so authenticate",
        "again on the plugin's page; \"Rate limited. Retry after N seconds.\" (HTTP 429) means the daily or per-minute quota is",
        "used up, so raise \"updateIntervalInMinutes\" (15+ for Developer Portal) or switch to Mobile App; \"Bad Gateway (502)\",",
        "\"Service Unavailable (503)\" or \"Gateway Timeout (504)\" with \"The Daikin API is temporarily unavailable\" is a",
        "Daikin-side outage (polls back off on their own); \"Device <id> is offline (cloud connection down)\" or a device shown",
        "Offline means its Wi-Fi adapter lost the Onecta cloud connection (check power, Wi-Fi and the Onecta app); \"Request to",
        "<host> failed after N attempts\" (ETIMEDOUT, ECONNRESET, ECONNREFUSED) points at the Homeswift host's network: DNS,",
        "firewall, broken IPv6 or a low MTU; \"returned a non-JSON response\" usually means a proxy or WAF answered instead of",
        "Daikin. Some WAFs drop a client by its TLS fingerprint: the built-in HTTP client offers the DEFAULT cipher list",
        "(DAIKIN_TLS_CIPHERS overrides it, DAIKIN_USER_AGENT the okhttp User-Agent), and \"httpTransport\": \"curl\" sends the",
        "requests through the curl binary instead (the WebSocket still uses the built-in client). Mobile App login errors",
        "carry the Gigya error code in parentheses. Hidden devices are listed in \"excludedDevicesByDeviceId\". Never ask the",
        "user for their password, Client Secret, tokens or API keys.",
    ].joined(separator: " ")
}
