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
}
