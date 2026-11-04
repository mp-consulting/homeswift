import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the accessories are the block's entries, virtual and set up already. The instance's
// account is the webhooks' Basic authentication: an Account Login whose user name and password go in the vault, never in
// config.json; a Homebridge block's `http_auth_user` and `http_auth_pass` still work, and go from it once Setup ran.
extension HTTPWebhooksPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

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
        var devices: [DiscoveredDevice] = []
        var names: Set<String> = []
        for list in Self.kinds {
            for entry in configuration.entries(list) {
                guard let id = entry.id, !id.isEmpty, let name = entry.name, names.insert(name).inserted else { continue }
                let model = list == "sensors" ? entry.string("type").flatMap(SensorAccessory.Kind.init(rawValue:))?.label : Self.label(of: list)
                guard let model else { continue }
                let shown = context.accessorySettings(for: name).name ?? name
                devices.append(DiscoveredDevice(deviceID: name, name: shown, model: model, address: "accessoryId=\(id)", isSetUp: true))
            }
        }
        return devices
    }

    /// The user name and the password the webhooks must give.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Webhook accessories are the block's entries: they need no setup of their own")
        guard let user = request.answer("user"), let password = request.answer("password") else {
            return .ask(SetupPrompt(
                message: "Choose the user name and the password every webhook must give (HTTP Basic authentication).",
                fields: [SetupField("user", label: "User name"), SetupField("password", label: "Password", kind: .secret)]))
        }
        return .done(SetupOutcome(
            credentials: ["user": .string(user), "password": .string(password)], settings: ["http_auth_user": .null, "http_auth_pass": .null]))
    }

    static func label(of list: String) -> String? {
        [
            "switches": "Switch", "pushbuttons": "Push button", "doorbells": "Doorbell", "lights": "Light", "thermostats": "Thermostat",
            "outlets": "Outlet", "security": "Security system", "garagedooropeners": "Garage door", "windowcoverings": "Window covering",
            "statelessswitches": "Stateless switch", "lockmechanisms": "Lock", "fanv2s": "Fan", "co2sensors": "Carbon dioxide sensor", "valves": "Valve",
        ][list]
    }
}
