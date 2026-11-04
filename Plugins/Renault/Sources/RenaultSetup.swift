import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the MyRenault account is the instance's, an Account Login of the locale, the e-mail and
// the password, then, when Gigya asks for it, the one-time code it e-mails (3.3). The 2FA tokens and the password wait in
// the Setup's state (on the bridge) between steps; the vault keeps the login token, the device ids Gigya remembers this
// bridge by, the e-mail and the password (so a dead login token can be replaced without the person). The block keeps
// the locale, the e-mail and the Kamereon account. The vehicles come with the account, each of the Device Kind `vehicle`,
// with the Parts its model has.
extension RenaultPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    public func accountAuthorized() async -> Bool? { storedCredentials() != nil }

    public func discover() async throws -> [DiscoveredDevice] {
        let known: [VehicleInfo]
        if vehicles.isEmpty {
            known = context.jsonFile("renault-vehicles.json", as: [VehicleInfo].self).load() ?? []
        } else {
            var running: [VehicleInfo] = []
            for vehicle in vehicles.values { running.append(vehicle.info) }
            known = running
        }
        let dropped = droppedStore.load() ?? [:]
        let wanted = Set(configuration.vins?.compactMap { VehicleInfo.cleanVIN($0) } ?? [])
        return known.sorted { $0.vin < $1.vin }.map { info in
            let parts = context.accessorySettings(for: info.vin).parts
            let available = RenaultVehicle.parts(for: info, dropped: Self.dropped(in: dropped, for: info, forgetAfter: dependencies.timing.forgetDropped))
            var device = DiscoveredDevice(
                deviceID: info.vin, name: info.displayName, model: info.modelName ?? info.modelCode, isSetUp: true,
                excludedBySettings: !wanted.isEmpty && !wanted.contains(info.vin), kind: Self.vehicleKind)
            device.parts = available.map { DevicePart($0.rawValue, name: $0.name, icon: $0.icon, included: parts[$0.rawValue] ?? $0.includedByDefault) }
            return device
        }
    }

    public func deviceKind(of deviceID: String) async -> String? { Self.vehicleKind }

    /// The steps: the sign-in, the address the code goes to (when there are several), the code, the account (when
    /// several have cars).
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Renault vehicles come with the account: they need no setup of their own")
        var state = request.state.objectValue ?? [:]
        let locale = request.choice("locale", among: RenaultLocale.known) ?? state["locale"]?.stringValue ?? locale
        guard let servers = RenaultLocale.servers(for: locale) else { throw SetupError("Pick a country") }
        state["locale"] = .string(locale)
        let gigya = GigyaClient(http: dependencies.http, servers: servers, timeout: dependencies.timing.requestTimeout)

        guard let email = state["email"]?.stringValue ?? request.answer("email"),
            let password = state["password"]?.stringValue ?? request.secret("password")
        else {
            return .ask(SetupPrompt(message: "Sign in with your MyRenault account.", fields: [
                .choice("locale", label: "Country", options: RenaultLocale.known.map { SetupOption($0, label: Self.localeLabel($0), country: String($0.suffix(2))) }, value: locale),
                SetupField("email", label: "E-mail", value: configuration.username),
                SetupField("password", label: "Password", kind: .secret),
            ]))
        }
        state["email"] = .string(email)
        state["password"] = .string(password)
        var deviceIDs = state["gmid"]?.stringValue.flatMap { gmid in state["ucid"]?.stringValue.map { GigyaDeviceIDs(gmid: gmid, ucid: $0) } }
            ?? context.credentials(as: RenaultCredentials.self)?.deviceIDs

        // The account step: a login token is in hand.
        if let loginToken = state["loginToken"]?.stringValue {
            return try await finish(loginToken: loginToken, deviceIDs: deviceIDs, email: email, password: password, locale: locale, servers: servers, request: request, state: state)
        }

        do {
            if let regToken = state["regToken"]?.stringValue, let ids = deviceIDs, let assertion = state["assertion"]?.stringValue {
                // The 2FA steps.
                if state["phvToken"] == nil {
                    guard let emailID = request.answer("emailID") ?? state["emailID"]?.stringValue else { throw SetupError("Pick an address") }
                    state["emailID"] = .string(emailID)
                    state["phvToken"] = .string(try await gigya.sendCode(assertion: assertion, emailID: emailID, deviceIDs: ids))
                    return .ask(codePrompt(state), state: .object(state))
                }
                guard let code = request.answer("code"), let phvToken = state["phvToken"]?.stringValue else { throw SetupError("Enter the code") }
                let provider = try await gigya.verify(code: code, assertion: assertion, phvToken: phvToken, deviceIDs: ids)
                try await gigya.finalize(assertion: assertion, providerAssertion: provider, regToken: regToken, deviceIDs: ids)
            }
            let token = try await gigya.login(email: email, password: password, deviceIDs: deviceIDs)
            logger.info("Signed in to MyRenault through Setup")
            for key in ["regToken", "assertion", "phvToken", "emailID", "emails"] { state.removeValue(forKey: key) }
            state["loginToken"] = .string(token)
            return try await finish(loginToken: token, deviceIDs: deviceIDs, email: email, password: password, locale: locale, servers: servers, request: request, state: state)
        } catch RenaultError.needsTwoFactor(let regToken) {
            if deviceIDs == nil {
                deviceIDs = try await setupCall { try await gigya.bootstrapDeviceIDs() }
            }
            guard let ids = deviceIDs else { throw SetupError("Renault sent no device id") }
            state["gmid"] = .string(ids.gmid)
            state["ucid"] = .string(ids.ucid)
            state["regToken"] = .string(regToken)
            let assertion = try await setupCall { try await gigya.initTFA(regToken: regToken, deviceIDs: ids) }
            state["assertion"] = .string(assertion)
            let emails = try await setupCall { try await gigya.emails(assertion: assertion, deviceIDs: ids) }
            guard let first = emails.first else { throw SetupError("Renault has no e-mail address for the code: add one in the MyRenault app") }
            if emails.count > 1 {
                return .ask(SetupPrompt(message: "Renault sends a code to confirm the sign-in. Which address should it go to?", fields: [
                    .choice("emailID", label: "Address", options: emails.map { SetupOption($0.id, label: $0.obfuscated) }, value: first.id),
                ]), state: .object(state.merging(["emails": .object(Dictionary(emails.map { ($0.id, JSONValue.string($0.obfuscated)) }, uniquingKeysWith: { a, _ in a }))]) { $1 }))
            }
            state["emailID"] = .string(first.id)
            state["emails"] = [first.id: .string(first.obfuscated)]
            state["phvToken"] = .string(try await setupCall { try await gigya.sendCode(assertion: assertion, emailID: first.id, deviceIDs: ids) })
            return .ask(codePrompt(state), state: .object(state))
        } catch RenaultError.wrongCode {
            // The challenge stays as it was: the same code prompt again, no new code.
            throw SetupError("The code is wrong; check it and try again")
        } catch RenaultError.invalidCredentials {
            throw SetupError("Renault refused the e-mail or the password")
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError("Renault did not answer: \(error)")
        }
    }

    private func codePrompt(_ state: [String: JSONValue]) -> SetupPrompt {
        let address = state["emailID"]?.stringValue.flatMap { state["emails"]?[$0]?.stringValue } ?? "your e-mail"
        return SetupPrompt(message: "Enter the code Renault sent to {address}.", values: ["address": address], fields: [SetupField("code", label: "Code", kind: .code)])
    }

    private func setupCall<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch let error as RenaultError { throw SetupError(error.description) }
    }

    /// The person, the accounts with cars, and the outcome; with several such accounts, the choice of one.
    private func finish(
        loginToken: String, deviceIDs: GigyaDeviceIDs?, email: String, password: String, locale: String, servers: RenaultServers,
        request: SetupRequest, state: [String: JSONValue]
    ) async throws -> SetupStep {
        var state = state
        let credentials = RenaultCredentials(loginToken: loginToken, gmid: deviceIDs?.gmid, ucid: deviceIDs?.ucid, username: email, password: password)
        let accountID: String
        if let chosen = request.answer("account") ?? state["account"]?.stringValue, state["accounts"]?[chosen] != nil {
            accountID = chosen
        } else {
            // A session of its own: Setup may run on an instance that never started.
            let budget = RequestBudget(maxCallsPerHour: maxCalls, hour: dependencies.timing.hour, cooldown: dependencies.timing.cooldown)
            let session = RenaultSession(
                http: dependencies.http, locale: locale, credentials: credentials, budget: budget, timing: dependencies.timing, logger: logger
            ) { _ in }
            var qualified: [(account: KamereonAccount, cars: Int)] = []
            do {
                let accounts = try await session.perform(.action) { session in try await session.accounts(.action) }
                for account in accounts {
                    let cars = (try? await session.perform(.action) { session in try await session.vehicles(accountID: account.id, .action) })?.vehicles.count ?? 0
                    if cars > 0 { qualified.append((account, cars)) }
                }
            } catch {
                throw SetupError("Renault did not list the account's cars: \(error)")
            }
            guard let preferred = qualified.first(where: { $0.account.type == "MYRENAULT" }) ?? qualified.first else {
                throw SetupError("This MyRenault account has no car yet: add it in the MyRenault app")
            }
            if qualified.count > 1 {
                state["accounts"] = .object(Dictionary(qualified.map { ($0.account.id, JSONValue.bool(true)) }, uniquingKeysWith: { a, _ in a }))
                return .ask(SetupPrompt(message: "Several of your Renault accounts have cars. Which one should the bridge use?", fields: [
                    .choice("account", label: "Account", options: qualified.map {
                        SetupOption($0.account.id, label: "\($0.account.type ?? "Account"): \($0.cars) \($0.cars == 1 ? "car" : "cars")")
                    }, value: preferred.account.id),
                ]), state: .object(state))
            }
            accountID = preferred.account.id
        }
        return .done(try SetupOutcome(encoding: credentials, settings: [
            "locale": .string(locale), "username": .string(email), "kamereonAccountId": .string(accountID), "password": .null,
        ]))
    }

    static func localeLabel(_ locale: String) -> String {
        let english = Locale(identifier: "en_US")
        let country = english.localizedString(forRegionCode: String(locale.suffix(2))) ?? String(locale.suffix(2))
        let language = english.localizedString(forLanguageCode: String(locale.prefix(2))) ?? String(locale.prefix(2))
        return "\(country) (\(language))"
    }

    // Settings (docs/plugins.md, "Settings"): `vins` (only these cars) becomes Excluded Accessory Settings of the other
    // known cars; one that names cars the plugin does not know yet stays as it is.

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var known: [String] = []
        for vehicle in vehicles.values { known.append(vehicle.info.vin) }
        if known.isEmpty { known = (context.jsonFile("renault-vehicles.json", as: [VehicleInfo].self).load() ?? []).map(\.vin) }
        return Self.canonical(block, knownVINs: known)
    }

    static func canonical(_ block: JSONValue, knownVINs: [String]) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["vins"]?.arrayValue else { return block }
        let wanted = Set(list.compactMap { VehicleInfo.cleanVIN($0.stringValue) })
        let known = Set(knownVINs)
        if wanted.isEmpty {
            fields.removeValue(forKey: "vins")
            return .object(fields)
        }
        guard !known.isEmpty, wanted.isSubset(of: known) else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        for vin in known.subtracting(wanted) {
            var entry = entries[vin]?.objectValue ?? [:]
            if entry["excluded"] == nil { entry["excluded"] = true }
            entries[vin] = .object(entry)
        }
        fields.removeValue(forKey: "vins")
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
