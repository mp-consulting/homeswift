import HomeswiftPlugin

extension DolphinPoolCleanerPlugin {
    /// The page's routes for the Assistant: the robots and how the plugin is doing. Signing in is Setup's
    /// (`start_setup` for an AI agent), never a route of the page.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_robots", title: "Look at the pool robots",
            description: "The plugin's state (status: notConfigured, signingIn, ready, retrying, failed or stopped, with error when the last sign-in failed) "
                + "and the account's robots: serialNumber, name, model, whether the robot is connected and cleaning, the cleaning mode, "
                + "the filter bag (ok, needs_cleaning, unknown), the minutes left in the cycle, the water temperature in °C and any fault. "
                + "With status notConfigured or failed, the user signs in again on Add accessories in the web UI (an AI agent through start_setup).",
            path: "robots", access: .read),
    ]
}

extension DolphinPoolCleanerPlugin {
    /// What the Assistant knows about the robots and the MyDolphin cloud with every Explain and request from the page.
    public static let assistantBackground: String? = [
        "The Homeswift plugin bridges Maytronics Dolphin pool robots from the MyDolphin Plus cloud to HomeKit (a start/stop switch,",
        "water temperature and filter status); it never talks to the robot on the LAN. Setup (Add accessories in the web UI, or",
        "start_setup for an AI agent) signs in with the MyDolphin Plus email only: AWS Cognito (CUSTOM_AUTH) sends a verification",
        "code by email (CUSTOM_CHALLENGE), SMS (SMS_MFA) or an authenticator app (SOFTWARE_TOKEN_MFA). MFA_SETUP means two-factor",
        "setup must first be finished in the MyDolphin app (\"Set up two-factor authentication in the MyDolphin app first\").",
        "After the code, the MyDolphin backend (authenticate-user) returns the robot serial number, name and connection type",
        "(deviceType 62 or 60 = IoT connected, 50 = BLE connected), and Setup keeps a Cognito refresh token in the bridge's vault",
        "instead of the password. Setup errors: \"Invalid email or password\" (also a code session that expired: start over) or",
        "\"User not found. Please check your email address.\" (use the exact MyDolphin Plus account email), \"Please confirm your",
        "email address first\", \"Invalid verification code\", \"Verification code has expired. Please try again.\",",
        "\"Cognito service error: HTTP 5xx\" or \"Maytronics API error: HTTP",
        "5xx\" (cloud outage, retry later), other texts are the MyDolphin backend Alert shown as-is (for example when the",
        "account has no robot), and a timeout means the Homeswift host could not reach AWS or Maytronics: check DNS, firewall",
        "and internet access. At runtime the plugin logs \"Refresh token expired. Please re-authenticate through the plugin",
        "settings.\" when the stored token is no longer valid (sign in again on Add accessories), gets temporary AWS IoT",
        "credentials (region eu-west-1 by default, \"iotRegion\") and controls the robot through the AWS IoT Thing Shadow over MQTT,",
        "polling every \"pollingInterval\" seconds (30-600, default 60); AWS IoT may throttle shadow requests (429",
        "TOO_MANY_REQUESTS), which the plugin retries. A \"notConnected\" state is normal when the robot is out of the water or",
        "the power supply is off; water temperature only shows while the robot is in the water (the last reading is kept in",
        "last-temperatures.json in the plugin's directory, plugins/DolphinPoolCleaner-<name>/ under the Homeswift config",
        "directory). Robot fault codes: 1 motor, 2 out of water, 3 communication, 4 filter blocked, 5 impeller blocked,",
        "6 overheating. Never ask the user for their password, verification codes, tokens or API keys.",
    ].joined(separator: " ")
}
