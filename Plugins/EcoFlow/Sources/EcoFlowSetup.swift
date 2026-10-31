import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the developer keys are the instance's account, an API Key the bridge keeps in the vault
// once a read of the devices works with them. The block's `accessKey` and `secretKey` still work, and go when Setup
// keeps the keys; the EcoFlow app's email and password stay Plugin Settings.
extension EcoFlowPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    /// The developer keys Setup kept.
    struct DeveloperKeys: Codable, Sendable {
        var accessKey: String
        var secretKey: String
    }

    /// The configuration with the keys from the vault in place of the block's, when Setup kept some.
    static func withStoredKeys(_ configuration: Configuration, _ context: PluginContext) -> Configuration {
        guard let keys = context.credentials(as: DeveloperKeys.self) else { return configuration }
        var configuration = configuration
        configuration.accessKey = keys.accessKey
        configuration.secretKey = keys.secretKey
        return configuration
    }

    public func accountAuthorized() async -> Bool? {
        Self.developerKeys(Self.withStoredKeys(configuration, context)) != nil || dependencies.api != nil
    }

    public func discover() async throws -> [DiscoveredDevice] {
        latest.map { found in DiscoveredDevice(deviceID: found.id, name: configuration.devices?.first { $0.id == found.id }?.name ?? found.name, isSetUp: true) }
    }

    /// The keys, checked with a read of the devices before they are kept.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("EcoFlow devices come with the account: they need no setup of their own")
        guard let accessKey = request.answer("accessKey"), let secretKey = request.answer("secretKey") else {
            return .ask(SetupPrompt(message: "Enter the keys of your EcoFlow developer account, from developer.ecoflow.com.", fields: [
                SetupField("accessKey", label: "Access key", kind: .secret), SetupField("secretKey", label: "Secret key", kind: .secret),
                SetupField("region", label: "Region (us or eu)", optional: true),
            ]))
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
        var settings: [String: JSONValue] = ["accessKey": .null, "secretKey": .null]
        if let region { settings["region"] = .string(region) }
        return .done(SetupOutcome(credentials: try JSONValue(encoding: DeveloperKeys(accessKey: accessKey, secretKey: secretKey)), settings: settings))
    }
}
