import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the eWeLink account is the instance's, an Account Login checked with a login before it
// is kept. The plugin logs in with the password at each launch, so the username and the password go in the vault,
// preferred over the block's, which go; the session the login gives stays where the plugin keeps it (`TokenStorage`,
// its own vault entry). The devices come with the account, by their eWeLink device id, each of the Device Kind of its
// category (EWeLinkSettings.swift); a Homebridge block's `ignoredDevices` still leaves devices out, as Excluded does.
extension EWeLinkPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// A channel's or an RF sub-device's accessory (`<deviceid>SW<n>`) is its device's: Excluded reaches it.
    public static func deviceID(ofAccessory suffix: String) -> String? {
        let parent = DeviceLimits.parentDeviceID(suffix)
        return parent == suffix ? nil : parent
    }

    /// What Setup keeps in the vault: the password, and the account it is for (nil in an entry kept before).
    struct StoredPassword: Codable, Sendable, Equatable {
        var password: String
        var username: String?
    }

    /// The configuration with the account from the vault: its password in place of the block's, its username where the
    /// block has none, when Setup (or a settings write, `canonicalSettings`) kept them.
    static func withStoredPassword(_ configuration: Configuration, _ context: PluginContext) -> Configuration {
        guard let stored = context.credentials(as: StoredPassword.self), !stored.password.isEmpty else { return configuration }
        var configuration = configuration
        configuration.password = stored.password
        if configuration.username?.isEmpty != false, let username = stored.username, !username.isEmpty { configuration.username = username }
        return configuration
    }

    /// The block logs in by itself: an account and a password (the vault's or the block's).
    public func accountAuthorized() async -> Bool? {
        configuration.username?.isEmpty == false && configuration.password?.isEmpty == false
    }

    /// The account's devices and groups: with the plugin's saved session, or a login. A device in
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
                excludedBySettings: configuration.isIgnored(device.deviceid), kind: DeviceCategory.resolve(device).rawValue)
        }
        let groupsFound = groups.compactMap { group -> DiscoveredDevice? in
            guard let id = group["id"]?.jsString, !id.isEmpty else { return nil }
            let name = group["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Group \(id)"
            return DiscoveredDevice(deviceID: id, name: name, model: "Group", isSetUp: true, excludedBySettings: configuration.isIgnored(id), kind: DeviceCategory.group.rawValue)
        }
        return found + groupsFound
    }

    /// The account's email or phone number and its password, checked with a login: the password goes in the vault,
    /// the session in the plugin's own entry.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("eWeLink devices come with the account: they need no setup of their own")
        guard let username = request.answer("username"), let password = request.secret("password") else {
            return .ask(SetupPrompt(message: "Sign in with your eWeLink account.", fields: [
                SetupField("username", label: "Email or phone number"), SetupField("password", label: "Password", kind: .secret),
                .choice("countryCode", label: "Country", options: SetupOption.countries(Array(EWeLinkCloud.callingCodes.keys)) { "+" + (EWeLinkCloud.callingCodes[$0] ?? "1") },
                        value: configuration.countryCode.flatMap { $0.isEmpty ? nil : "+" + $0.filter(\.isNumber) }, optional: true),
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
        var settings: [String: JSONValue] = ["username": .null, "password": .null]
        if let typedCountry { settings["countryCode"] = .string(typedCountry.hasPrefix("+") ? typedCountry : "+\(typedCountry)") }
        return .done(SetupOutcome(credentials: try JSONValue(encoding: StoredPassword(password: password, username: username)), settings: settings))
    }
}
