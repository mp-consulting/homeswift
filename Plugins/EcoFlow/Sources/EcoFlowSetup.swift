import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the instance's account is read through the route Setup asks for first (`route`): the
// developer API's keys, an API Key the bridge keeps in the vault once a read of the devices works with them, the EcoFlow
// app's email and password, checked with a sign-in (the email a Plugin Setting, the password in the vault), or both. The
// block's `accessKey`, `secretKey` and `password` still work, and go when Setup keeps them or at the next settings change
// (EcoFlowSettings.swift). Each device comes with the account, of the Device Kind `stream`, `home`, `portable` or
// `powerBank`.
extension EcoFlowPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    /// What the vault keeps for the account: the developer keys, the app's password, or both.
    struct AccountCredentials: Codable, Sendable, Equatable {
        var accessKey: String?
        var secretKey: String?
        var password: String?

        var hasKeys: Bool { accessKey?.isEmpty == false && secretKey?.isEmpty == false }
        var hasPassword: Bool { password?.isEmpty == false }
    }

    /// The configuration with the keys and the password from the vault in place of the block's, when the vault has them.
    static func withStoredKeys(_ configuration: Configuration, _ context: PluginContext) -> Configuration {
        guard let saved = context.credentials(as: AccountCredentials.self) else { return configuration }
        var configuration = configuration
        if saved.hasKeys {
            configuration.accessKey = saved.accessKey
            configuration.secretKey = saved.secretKey
        }
        if saved.hasPassword { configuration.password = saved.password }
        return configuration
    }

    public func accountAuthorized() async -> Bool? {
        Self.developerKeys(Self.withStoredKeys(configuration, context)) != nil || dependencies.api != nil
    }

    public func discover() async throws -> [DiscoveredDevice] {
        latest.map { found in
            DiscoveredDevice(
                deviceID: found.id, name: configuration.devices?.first { $0.id == found.id }?.name ?? found.name, model: found.model?.name, isSetUp: true,
                kind: found.kind.rawValue)
        }
    }

    /// The route first, the block's picked; then the developer keys, checked with a read of the devices, and the app's
    /// email and password, checked with a sign-in, as the route reads them.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("EcoFlow devices come with the account: they need no setup of their own")
        guard let route = request.choice("route", among: ["both", "developer", "app"]) else {
            return .ask(SetupPrompt(message: "Choose how Homeswift reads your EcoFlow devices.", fields: [
                .choice("route", label: "Read through", options: [
                    SetupOption("both", label: "Developer API and EcoFlow app", detail: "Each device through whichever reads it, and the energy history."),
                    SetupOption("developer", label: "Developer API", detail: "Keys from developer.ecoflow.com. Reads the devices EcoFlow's developer API offers, such as a STREAM."),
                    SetupOption("app", label: "EcoFlow app account", detail: "The app's email and password. Reads every device the app shows, live, and imports the energy history."),
                ], value: Route(configuration.route) == .developer ? "developer" : Route(configuration.route) == .app ? "app" : "both"),
            ]))
        }
        let next = SetupRequest(target: request.target, answers: request.answers.filter { $0.key != "route" }, state: request.state)
        return try await authorize(next, route: Route(route)).keeping("route", .string(route))
    }

    private func authorize(_ request: SetupRequest, route: Route) async throws -> SetupStep {
        var state = request.state.objectValue ?? [:]
        // The developer keys first, unless the route reads the app only; kept in the state while the app is asked.
        if route != .app, state["keys"] == nil {
            guard let accessKey = request.answer("accessKey"), let secretKey = request.answer("secretKey") else {
                return .ask(SetupPrompt(message: "Enter the keys of your EcoFlow developer account, from developer.ecoflow.com.", fields: [
                    SetupField("accessKey", label: "Access key", kind: .secret), SetupField("secretKey", label: "Secret key", kind: .secret),
                    .choice("region", label: "Region", options: [
                        SetupOption("eu", label: "Europe"), SetupOption("us", label: "United States"),
                    ], value: configuration.region, optional: true),
                ]), state: request.state)
            }
            let region = request.answer("region")?.lowercased() ?? configuration.region
            guard region == nil || region == "us" || region == "eu" else { throw SetupError("The region is us or eu") }
            let api = dependencies.developerAPI(accessKey, secretKey, region)
            let found: [EcoFlowDevice]
            do {
                found = try await api.devices()
            } catch {
                await api.stop()
                throw SetupError("EcoFlow refused the keys: \(error)")
            }
            await api.stop()
            logger.info("Developer keys checked through Setup", metadata: ["devices": "\(found.count)"])
            state["keys"] = ["accessKey": .string(accessKey), "secretKey": .string(secretKey), "region": region.map(JSONValue.string) ?? .null]
            if route == .both { return .ask(appPrompt, state: .object(state)) }
        }
        var settings: [String: JSONValue] = [:]
        var credentials = AccountCredentials()
        if route != .developer {
            guard let email = request.answer("email"), let password = request.secret("password") else { return .ask(appPrompt, state: .object(state)) }
            do {
                try await dependencies.appSignIn(email, password)
            } catch {
                throw SetupError("EcoFlow refused the sign-in: \(error)")
            }
            logger.info("EcoFlow app sign-in checked through Setup")
            settings["email"] = .string(email)
            settings["password"] = .null
            credentials.password = password
        }
        if let keys = state["keys"], let accessKey = keys["accessKey"]?.stringValue, let secretKey = keys["secretKey"]?.stringValue {
            credentials.accessKey = accessKey
            credentials.secretKey = secretKey
            settings["accessKey"] = .null
            settings["secretKey"] = .null
            if let region = keys["region"]?.stringValue { settings["region"] = .string(region) }
        }
        return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: settings))
    }

    private var appPrompt: SetupPrompt {
        SetupPrompt(message: "Sign in with the account of the EcoFlow app.", fields: [
            SetupField("email", label: "Email"), SetupField("password", label: "Password", kind: .secret),
        ])
    }
}
