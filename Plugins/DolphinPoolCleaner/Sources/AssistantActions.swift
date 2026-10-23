import HomeswiftPlugin

extension DolphinPoolCleanerPlugin {
    /// The page's routes for the Assistant: the robots and how the plugin is doing. The page's sign-in
    /// (`authenticate`, `verify-otp`) is left out: it takes a one-time code mailed to the user, which belongs
    /// on the page, not in a chat.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_robots", title: "Look at the pool robots",
            description: "The plugin's state (status: notConfigured, signingIn, ready, retrying, failed or stopped, with error when the last sign-in failed) "
                + "and the account's robots: serialNumber, name, model, whether the robot is connected and cleaning, the cleaning mode, "
                + "the filter bag (ok, needs_cleaning, unknown), the minutes left in the cycle, the water temperature in °C and any fault. "
                + "With status notConfigured or failed, the user signs in again on the plugin's page in the web UI.",
            path: "robots", access: .read),
    ]
}
