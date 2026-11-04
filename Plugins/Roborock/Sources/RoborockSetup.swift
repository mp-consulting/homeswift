import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Roborock account is the instance's, an Account Login. With a password the plugin
// logs in with it, and an account that asks for two-factor authentication (code 2031) gets the emailed code as the next
// step; without one, Roborock emails a code straight away. The session the login gives (its `rriot` keys) goes in the
// plugin's own vault entry (`roborock.UserData`, `context.secretFile`), the password in the instance's credentials; the
// block keeps the email. A Homebridge `encryptedToken` cannot be opened without the Homebridge plugin's
// `roborock.token.key`, so its owner signs in again here. The robots come with the account, each of the Device Kind
// `vacuum`.
extension RoborockPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    static let vacuumKind = "vacuum"

    public func deviceKind(of deviceID: String) async -> String? { Self.vacuumKind }

    /// Signed in: a session kept, or a password to log in with.
    public func accountAuthorized() async -> Bool? {
        storage.session.load()?.isValid == true || password != nil
    }

    /// The account's robots, from the latest home data (or the cached one).
    public func discover() async throws -> [DiscoveredDevice] {
        let current = home ?? email.flatMap { storage.cachedHome(email: $0, logger: logger) }.map(RoborockHome.init)
        guard let current else { return [] }
        return current.devices.filter { RoborockHome.isSupported(model: current.model(of: $0)) }.map { device in
            var found = DiscoveredDevice(
                deviceID: device.duid, name: device.name.isEmpty ? "Roborock Vacuum" : device.name, model: current.model(of: device), isSetUp: true,
                excludedBySettings: configuration.skipDevices?.values.contains(device.duid) == true, kind: Self.vacuumKind)
            found.isReachable = device.online != false
            return found
        }
    }

    /// The email (and a password, optionally), then the emailed code when Roborock asks for it.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Roborock robots come with the account: they need no setup of their own")
        if let host = request.state["host"]?.stringValue, let email = request.state["email"]?.stringValue,
            let k = request.state["k"]?.stringValue, let s = request.state["s"]?.stringValue
        {
            guard let code = request.answer("code")?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { throw SetupError("Enter the code Roborock emailed you") }
            let api = setupAPI(host: host, email: email)
            let result: RoborockLoginAPI.LoginResult
            do {
                result = try await api.login(
                    code: code, country: request.state["country"]?.stringValue ?? "US", countryCode: request.state["countryCode"]?.stringValue ?? "1", signature: (k, s))
            } catch {
                throw SetupError("Roborock did not answer: \(error)")
            }
            return try finish(result, email: email, host: host, password: request.state["password"]?.stringValue)
        }
        guard let email = request.answer("email")?.trimmingCharacters(in: .whitespaces), email.contains("@") else {
            return .ask(SetupPrompt(message: "Sign in with your Roborock app account. Leave the password empty to get a code by email.", fields: [
                SetupField("email", label: "Email", value: configuration.email),
                SetupField("password", label: "Password", kind: .secret, optional: true),
            ]))
        }
        let region = await setupRegion(email: email)
        let api = setupAPI(host: region.host, email: email)
        let signature: (k: String, s: String)
        do {
            signature = try await api.signature()
        } catch {
            throw SetupError("Roborock did not answer: \(error)")
        }
        let fallback = RoborockLoginAPI.fallbackCountry(host: region.host)
        let country = region.country ?? fallback.country, countryCode = region.countryCode ?? fallback.code
        if let password = request.secret("password"), !password.isEmpty {
            let result: RoborockLoginAPI.LoginResult
            do {
                result = try await api.login(password: password, country: country, signature: signature)
            } catch {
                throw SetupError("Roborock did not answer: \(error)")
            }
            if case .twoFactorRequired = result {
                return try await askForCode(api, email: email, host: region.host, signature: signature, country: country, countryCode: countryCode, password: password)
            }
            return try finish(result, email: email, host: region.host, password: password)
        }
        return try await askForCode(api, email: email, host: region.host, signature: signature, country: country, countryCode: countryCode)
    }

    private func askForCode(_ api: RoborockLoginAPI, email: String, host: String, signature: (k: String, s: String), country: String, countryCode: String, password: String? = nil) async throws -> SetupStep {
        do {
            try await api.sendEmailCode()
        } catch {
            throw SetupError("Roborock could not send the code: \(error)")
        }
        // The signature (and a password typed before the code) stay with the Setup on the bridge, never on a page.
        var state: [String: JSONValue] = [
            "host": .string(host), "email": .string(email), "k": .string(signature.k), "s": .string(signature.s),
            "country": .string(country), "countryCode": .string(countryCode),
        ]
        if let password { state["password"] = .string(password) }
        return .ask(SetupPrompt(message: "Enter the code Roborock emailed to \(email).", fields: [SetupField("code", label: "Code", kind: .code)]), state: .object(state))
    }

    private func finish(_ result: RoborockLoginAPI.LoginResult, email: String, host: String, password: String?) throws -> SetupStep {
        switch result {
        case .success(let session) where session.isValid:
            try storage.session.save(session)
            logger.info("Signed in to Roborock through Setup")
            var settings: [String: JSONValue] = ["email": .string(email), "password": .null, "encryptedToken": .null]
            if configuration.baseURL?.nonEmptyValue == nil, host != RoborockLoginAPI.defaultHost { settings["baseURL"] = .string("https://\(host)") }
            return .done(SetupOutcome(credentials: password.map { ["password": .string($0)] }, settings: settings))
        case .twoFactorRequired:
            throw SetupError("Roborock asks for two-factor authentication: leave the password empty to sign in with an emailed code")
        case .failed(let code, let message):
            throw SetupError(code == 2027 || message.lowercased().contains("code") ? "The code is not right, or it expired: try again" : "Roborock refused the sign-in\(message.isEmpty ? "" : ": \(message)")")
        case .success:
            throw SetupError("Roborock sent no session")
        }
    }

    private func setupRegion(email: String) async -> RoborockLoginAPI.Region {
        if let configured = configuration.baseURL?.nonEmptyValue { return .init(host: RoborockLoginAPI.normalizedHost(configured)) }
        return await RoborockLoginAPI.discoverRegion(email: email, transport: dependencies.transport) ?? .init(host: RoborockLoginAPI.defaultHost)
    }

    private func setupAPI(host: String, email: String) -> RoborockLoginAPI {
        RoborockLoginAPI(transport: dependencies.transport, host: host, email: email, clientID: storage.loadOrCreateClientID(), language: language)
    }

    // MARK: Settings (docs/plugins.md, "Settings")

    /// The block in its canonical shape: `skipDevices` as Excluded in `_accessories`, the block's password moved into the
    /// vault once the block is written, where the vault has none.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var canonical = Self.canonical(block)
        guard var fields = canonical.objectValue, fields["password"] != nil else { return canonical }
        if context.credentials()?["password"]?.stringValue?.nonEmptyValue == nil, let resolved = configuration.password?.nonEmptyValue {
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(["password": .string(resolved)]) }
            fields.removeValue(forKey: "password")
        } else if context.credentials()?["password"]?.stringValue?.nonEmptyValue != nil {
            fields.removeValue(forKey: "password")
        }
        canonical = .object(fields)
        return canonical
    }

    /// `skipDevices` (an array, or text with commas and new lines) moved into `_accessories` as Excluded, by duid.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, let skip = fields["skipDevices"] else { return block }
        let values: [String]
        if let text = skip.stringValue { values = Configuration.List.split(text) } else { values = (skip.arrayValue ?? []).compactMap(\.stringValue).flatMap(Configuration.List.split) }
        var entries = AccessoryEntries(fields)
        fields["skipDevices"] = .array(values.map { .string($0) })
        entries.excludeList("skipDevices", in: &fields) { [$0] }
        entries.write(into: &fields)
        return .object(fields)
    }
}
