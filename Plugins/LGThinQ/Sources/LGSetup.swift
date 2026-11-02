import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the LG account is the instance's, and the only way it signs in (the plugin's page leads
// here). It is a Browser Redirect: LG's own sign-in page (which takes LG, Google, Apple, Facebook and Amazon accounts),
// in the account's region (LGRegions.swift, the Homebridge page's list), whose address the person pastes back
// once it ends on `iabClose`. A block whose `auth_mode` is `account` signs in with the account's email and password
// instead (an Account Login). Either way the refresh token goes in the vault, preferred over the block's `refresh_token`,
// which goes. The appliances come with the account, by LG's device id; the block's `devices`, when it lists some, is the
// Homebridge plugin's allow list (docs/adr/0001-canonical-accessory-settings.md).
extension LGThinQPlugin {
    public static let accountAuthorization = AuthorizationMethod.browserRedirect

    /// What Setup keeps in the vault.
    struct StoredToken: Codable, Sendable {
        var refreshToken: String
    }

    /// The configuration with the refresh token from the vault in place of the block's, when Setup kept one.
    static func withStoredToken(_ configuration: Configuration, _ context: PluginContext) -> Configuration {
        guard let token = context.credentials(as: StoredToken.self)?.refreshToken, !token.isEmpty else { return configuration }
        var configuration = configuration
        configuration.refresh_token = token
        return configuration
    }

    /// The block signs in by itself: a refresh token (the vault's or the block's), or an account's email and password.
    public func accountAuthorized() async -> Bool? {
        configuration.refresh_token?.isEmpty == false || (configuration.username?.isEmpty == false && configuration.password?.isEmpty == false)
    }

    /// The account's appliances, from the running platform or one signed in for the question. One the block's `devices`
    /// leaves out, or a ThinQ v1 appliance without `thinq1`, is excluded by its settings; one Homeswift has no accessory
    /// for is not listed.
    public func discover() async throws -> [DiscoveredDevice] {
        let running = platformInstance
        let platform: LGThinQPlatform
        if let running {
            platform = running
        } else {
            platform = await LGThinQPlatform(configuration: configuration, context: context, transport: dependencies.transport, mqtt: dependencies.mqtt)
        }
        let listing = await platform.isConfigured ? await platform.accountDevices() : nil
        if running == nil { await platform.stop() }
        guard let listing else { return [] }
        let thinq1 = configuration.thinq1 ?? false
        return listing.devices.compactMap { device in
            guard let id = device["id"]?.stringValue, device["supported"] == true else { return nil }
            let excluded = device["configured"] == false || (device["platform"]?.stringValue == PlatformType.thinq1 && !thinq1)
            let model = device["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? device["type"]?.stringValue
            return DiscoveredDevice(deviceID: id, name: device["name"]?.stringValue ?? id, model: model, isSetUp: true, excludedBySettings: excluded)
        }
    }

    /// How to sign in, then the region when the block has none, then LG's page (or the account's email and password); the refresh token
    /// goes in the vault once LG lists the account's appliances with it.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("LG appliances come with the account: they need no setup of their own")
        // How to sign in, asked first, the block's picked: it becomes the block's `auth_mode`.
        guard let mode = request.choice("auth_mode", among: ["token", "account"]) else {
            return .ask(SetupPrompt(message: "Choose how Homeswift signs in to LG ThinQ.", fields: [
                .choice("auth_mode", label: "Sign in with", options: [
                    SetupOption("token", label: "LG's sign-in page", detail: "Takes an LG, Google, Apple, Facebook or Amazon account, in your browser."),
                    SetupOption("account", label: "Email and password", detail: "An LG account with a password of its own, typed here."),
                ], value: configuration.auth_mode == "account" ? "account" : "token"),
            ]))
        }
        let next = SetupRequest(target: request.target, answers: request.answers.filter { $0.key != "auth_mode" }, state: request.state)
        return try await authorize(next, mode: mode).keeping("auth_mode", .string(mode))
    }

    private func authorize(_ request: SetupRequest, mode: String) async throws -> SetupStep {
        var region: [String: JSONValue] = request.state["region"]?.objectValue ?? [:]
        if region.isEmpty, let country = request.answer("country"), let language = request.answer("language") {
            guard country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw SetupError("The country has two letters, such as US or FR") }
            guard language.count >= 2, language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "_") }) else {
                throw SetupError("The language is a code such as en-US or fr-FR")
            }
            region = ["country": .string(country.uppercased()), "language": .string(language)]
        }
        let country = region["country"]?.stringValue ?? configuration.country.flatMap { $0.isEmpty ? nil : $0 }
        let language = region["language"]?.stringValue ?? configuration.language.flatMap { $0.isEmpty ? nil : $0 }
        guard let country, let language else {
            return .ask(SetupPrompt(message: "Choose the country and the language of your LG account.", fields: [
                .choice("country", label: "Country", options: LGRegions.countries(), value: configuration.country?.uppercased()),
                .choice("language", label: "Language", options: LGRegions.languages(), value: configuration.language),
            ]))
        }
        let token: String
        var settings = region
        if mode == "account" {
            guard let username = request.answer("username"), let password = request.secret("password") else {
                return .ask(SetupPrompt(message: "Sign in with your LG account.", fields: [
                    SetupField("username", label: "Email"), SetupField("password", label: "Password", kind: .secret),
                ]), state: ["region": .object(region)])
            }
            do {
                token = try await Self.login(username: username, password: password, country: country, language: language, transport: dependencies.transport, logger: logger)
            } catch {
                throw SetupError(Self.message(error, fallback: "LG refused the sign-in"))
            }
            settings["username"] = .string(username)
        } else {
            guard let pasted = request.answer("callbackUrl"), request.state["url"] != nil else {
                let url: String
                do {
                    url = try await Self.thirdPartyLoginURL(country: country, language: language, transport: dependencies.transport, logger: logger)
                } catch {
                    throw SetupError("Cannot reach LG: \(Self.message(error, fallback: "no answer"))")
                }
                return .ask(redirectPrompt(url), state: ["region": .object(region), "url": .string(url)])
            }
            do {
                token = try await Self.loginWithRedirect(pasted, country: country, language: language, transport: dependencies.transport, logger: logger)
            } catch {
                throw SetupError(Self.message(error, fallback: "LG refused the sign-in"))
            }
        }
        // A token LG does not take never reaches the vault.
        let devices: [JSONValue]
        do {
            devices = try await Self.listDevices(refreshToken: token, country: country, language: language, transport: dependencies.transport, logger: logger)
        } catch {
            throw SetupError("LG did not accept the sign-in: \(Self.message(error, fallback: "no answer"))")
        }
        logger.info("Signed in to LG ThinQ through Setup", metadata: ["country": "\(country)", "devices": "\(devices.count)"])
        settings["refresh_token"] = .null
        return .done(SetupOutcome(credentials: try JSONValue(encoding: StoredToken(refreshToken: token)), settings: settings))
    }

    private func redirectPrompt(_ url: String) -> SetupPrompt {
        SetupPrompt(
            message: "Sign in on LG's page that opens. When it ends on a blank page, paste the address the browser shows (it contains iabClose).",
            fields: [SetupField("callbackUrl", label: "Address the browser ended on", kind: .url)], url: url)
    }
}
