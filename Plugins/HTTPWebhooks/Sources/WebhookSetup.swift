import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the accessories are the block's entries, virtual and set up already. The instance's
// account is the webhooks' Basic authentication: an Account Login whose user name and password go in the vault, never in
// config.json; a Homebridge block's `http_auth_user` and `http_auth_pass` still work, and go from it once Setup ran.
extension HTTPWebhooksPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin
    /// Optional: without it the webhooks answer anyone on the network, as a Homebridge block without `http_auth_user` does.
    public static let accountRequirement = AccountRequirement.optional(adds: "Protects the webhooks with a user name and password.")

    /// The Basic credentials: Setup's in the vault first, else the block's.
    var credentials: (user: String, password: String)? {
        if let stored = context.credentials(), let user = stored["user"]?.stringValue, let password = stored["password"]?.stringValue,
            !user.isEmpty, !password.isEmpty
        {
            return (user, password)
        }
        return configuration.credentials
    }

    /// Authorized once the webhooks ask for credentials.
    public func accountAuthorized() async -> Bool? { credentials != nil }

    /// The entries of the block, each a device set up already: nothing to authorize, as the accessories are virtual.
    public func discover() async throws -> [DiscoveredDevice] {
        Self.validEntries(configuration, logger: nil).map { valid in
            DiscoveredDevice(
                deviceID: valid.name, name: context.accessorySettings(for: valid.name).name ?? valid.name, model: valid.model,
                address: "accessoryId=\(valid.id)", isSetUp: true)
        }
    }

    /// The user name and the password the webhooks must give.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Webhook accessories are the block's entries: they need no setup of their own")
        guard let user = request.answer("user"), let password = request.answers["password"], !password.isEmpty else {
            return .ask(SetupPrompt(
                message: "Choose the user name and the password every webhook must give (HTTP Basic authentication).",
                fields: [SetupField("user", label: "User name"), SetupField("password", label: "Password", kind: .secret)]))
        }
        guard !user.contains(":") else { throw SetupError("A user name cannot contain a colon (:)") }
        return .done(SetupOutcome(
            credentials: ["user": .string(user), "password": .string(password)], settings: ["http_auth_user": .null, "http_auth_pass": .null]))
    }
}
