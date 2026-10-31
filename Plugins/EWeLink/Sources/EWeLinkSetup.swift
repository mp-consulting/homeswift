import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the eWeLink account is the instance's, an Account Login checked with a login before it
// is kept. The plugin logs in with the password at each launch, so the password goes in the vault, preferred over the
// block's `password`, which goes; the session the login gives stays where the plugin keeps it (`TokenStorage`, its own
// vault entry). The devices come with the account, by their eWeLink device id; `ignoredDevices` still leaves devices out
// (docs/adr/0001-canonical-accessory-settings.md). Its entries' `ignoreDevice` keeps having no effect, as its schema says.
extension EWeLinkPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// What Setup keeps in the vault.
    struct StoredPassword: Codable, Sendable {
        var password: String
    }

    /// The configuration with the password from the vault in place of the block's, when Setup kept one.
    static func withStoredPassword(_ configuration: Configuration, _ context: PluginContext) -> Configuration {
        guard let password = context.credentials(as: StoredPassword.self)?.password, !password.isEmpty else { return configuration }
        var configuration = configuration
        configuration.password = password
        return configuration
    }

    /// The block logs in by itself: an account and a password (the vault's or the block's).
    public func accountAuthorized() async -> Bool? {
        configuration.username?.isEmpty == false && configuration.password?.isEmpty == false
    }

    /// The account's devices and groups: with the page's session, the plugin's saved one, or a login. A device in
    /// `ignoredDevices` is excluded by its settings; an RF Bridge stands for its remotes and sensors.
    public func discover() async throws -> [DiscoveredDevice] {
        var api = await sessionAPI()
        if api == nil, configuration.username?.isEmpty == false, configuration.password?.isEmpty == false {
            let fresh = CloudAPI(
                credentials: .init(username: configuration.username, password: configuration.password, countryCode: configuration.countryCode),
                transport: dependencies.transport, storage: TokenStorage(context: context), logger: logger)
            try await fresh.login()
            api = fresh
        }
        guard let api else { return [] }
        let (devices, groups) = try await api.devices()
        let found = devices.filter { !$0.deviceid.isEmpty }.map { device in
            DiscoveredDevice(
                deviceID: device.deviceid, name: device.name, model: device.productModel ?? device.model, isSetUp: true,
                excludedBySettings: configuration.isIgnored(device.deviceid))
        }
        let groupsFound = groups.compactMap { group -> DiscoveredDevice? in
            guard let id = group["id"]?.jsString, !id.isEmpty else { return nil }
            let name = group["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Group \(id)"
            return DiscoveredDevice(deviceID: id, name: name, model: "Group", isSetUp: true, excludedBySettings: configuration.isIgnored(id))
        }
        return found + groupsFound
    }

    /// The account's email or phone number and its password, checked with a login: the password goes in the vault,
    /// the session in the plugin's own entry.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { throw SetupError("eWeLink devices come with the account: they need no setup of their own") }
        guard let username = request.answer("username"), let password = request.answer("password") else {
            return .ask(SetupPrompt(message: "Sign in with your eWeLink account.", fields: [
                SetupField("username", label: "Email or phone number"), SetupField("password", label: "Password", kind: .secret),
                SetupField("countryCode", label: "Country calling code (such as +1 or +44)", optional: true),
            ]))
        }
        let typedCountry = request.answer("countryCode")
        if let typedCountry {
            let digits = typedCountry.hasPrefix("+") ? typedCountry.dropFirst() : Substring(typedCountry)
            guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw SetupError("The country calling code is a number such as +1 or +44")
            }
        }
        let api = CloudAPI(
            credentials: .init(username: username, password: password, countryCode: typedCountry ?? configuration.countryCode),
            transport: dependencies.transport, storage: TokenStorage(context: context), logger: logger)
        do {
            try await api.login()
        } catch {
            throw SetupError("\(error)")
        }
        let region = await api.region.rawValue
        logger.info("Signed in to eWeLink through Setup", metadata: ["region": "\(region)"])
        var settings: [String: JSONValue] = ["username": .string(username), "password": .null]
        if let typedCountry { settings["countryCode"] = .string(typedCountry.hasPrefix("+") ? typedCountry : "+\(typedCountry)") }
        return .done(SetupOutcome(credentials: try JSONValue(data: JSONEncoder().encode(StoredPassword(password: password))), settings: settings))
    }
}
