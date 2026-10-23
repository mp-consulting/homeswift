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
}
