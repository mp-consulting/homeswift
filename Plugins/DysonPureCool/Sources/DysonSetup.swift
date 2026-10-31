import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Dyson account is the instance's, an Account Login whose second step is the code
// Dyson emails (the page's sign-in, the same calls). Its token goes in the vault and lists the account's devices, each a
// device whose Device Id is its serial number: setting one up reads its local MQTT credential from the account into the
// vault under the serial, and its product type into its Accessory Settings. The block's `devices` list still works as it
// was (docs/adr/0001-canonical-accessory-settings.md), a credential in the vault preferred over its `localCredentials`.
extension DysonPureCoolPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// What the account's sign-in gives, kept in the vault.
    struct AccountToken: Codable, Sendable {
        var token: String
    }

    /// A device's local MQTT credential, kept in the vault under its serial.
    struct DeviceCredentials: Codable, Sendable {
        var localCredentials: String
    }

    /// The account's token Setup keeps.
    var storedToken: String? { context.credentials(as: AccountToken.self)?.token.nonEmpty }

    /// The credential Setup keeps for a device; preferred over the block's `localCredentials`.
    func storedLocalCredentials(serial: String) -> String? {
        context.credentials(for: serial, as: DeviceCredentials.self)?.localCredentials.nonEmpty
    }

    /// The devices to run: those of `devices`, then those set up through Setup (Accessory Settings with a credential in
    /// the vault), a serial in both counting once, `devices`' first.
    func configuredDevices() -> [Configuration.Device] {
        let listed = (configuration.devices ?? []).map { entry -> Configuration.Device in
            guard let serial = entry.serial?.trimmingCharacters(in: .whitespaces).nonEmpty, let stored = storedLocalCredentials(serial: serial) else { return entry }
            var entry = entry
            entry.localCredentials = stored
            entry.credentials = nil
            return entry
        }
        let listedSerials = Set(listed.compactMap { $0.serial?.trimmingCharacters(in: .whitespaces) })
        let setUp = context.setUpDevices(credentials: DeviceCredentials.self).filter { !listedSerials.contains($0.deviceID) }.compactMap { serial, settings, stored -> Configuration.Device? in
            guard let credentials = stored.localCredentials.nonEmpty else { return nil }
            return settings.decode(Configuration.Device.self, adding: ["serial": .string(serial), "localCredentials": .string(credentials), "credentials": .null])
        }
        return listed + setUp
    }

    /// The devices the plugin runs or has a credential for, then those the account has that it does not: an Account
    /// Login reads their credential.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        for device in configuredDevices() {
            guard let serial = device.serial?.trimmingCharacters(in: .whitespaces).nonEmpty, !found.contains(where: { $0.deviceID == serial }) else { continue }
            let hasCredential = (device.credentials ?? device.localCredentials)?.nonEmpty != nil
            found.append(DiscoveredDevice(
                deviceID: serial, name: device.name?.nonEmpty ?? "Dyson \(serial)", model: device.productType.map(DeviceCatalog.modelName),
                address: device.ipAddress?.nonEmpty, authorization: .accountLogin, isSetUp: hasCredential))
        }
        guard let token = storedToken else { return found }
        let listed: [DysonCloud.CloudDevice]
        do {
            listed = try await cloud.devices(token: token)
        } catch {
            logger.warning("Could not list the Dyson account's devices: \(error)")
            return found
        }
        for device in listed where !found.contains(where: { $0.deviceID == device.serial }) && DeviceCatalog.isSupported(device.productType) {
            found.append(DiscoveredDevice(
                deviceID: device.serial, name: device.name ?? "Dyson \(device.serial)", model: DeviceCatalog.modelName(device.productType), authorization: .accountLogin))
        }
        return found
    }

    /// The account: its sign-in, the token in the vault. A device: its credential from the account, with the token Setup
    /// kept, or after signing in again when there is none or Dyson turns it down.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard case .device(let device) = request.target else {
            switch try await signIn(request, message: "Sign in with your Dyson account: Dyson emails you a code.") {
            case .asking(let step):
                return step
            case .signedIn(let token, let countryCode):
                logger.info("Signed in to the Dyson account through Setup")
                return .done(SetupOutcome(credentials: try JSONValue(encoding: AccountToken(token: token)), settings: ["countryCode": .string(countryCode)]))
            }
        }
        if request.isFirst, let token = storedToken {
            do {
                return try await deviceOutcome(serial: device.deviceID, token: token)
            } catch let failure as DysonCloud.Failure where failure.status == 401 {
                logger.info("The Dyson account's token was turned down: signing in again")
            }
        }
        switch try await signIn(request, message: "Sign in with your Dyson account to read this device's credential: Dyson emails you a code.") {
        case .asking(let step):
            return step
        case .signedIn(let token, _):
            // A fresh token for the account too: the next device needs no sign-in.
            do {
                try context.saveCredentials(AccountToken(token: token))
            } catch {
                logger.warning("Could not keep the Dyson account's token: \(error)")
            }
            do {
                return try await deviceOutcome(serial: device.deviceID, token: token)
            } catch let failure as DysonCloud.Failure {
                throw SetupError(failure.message)
            }
        }
    }

    /// The device's credential and product type, from the account's devices.
    private func deviceOutcome(serial: String, token: String) async throws -> SetupStep {
        let listed: [DysonCloud.CloudDevice]
        do {
            listed = try await cloud.devices(token: token)
        } catch let failure as DysonCloud.Failure where failure.status == 401 {
            throw failure
        } catch {
            throw SetupError("\(error)")
        }
        guard let device = listed.first(where: { $0.serial == serial }) else { throw SetupError("The Dyson account has no device with the serial number \(serial)") }
        guard DeviceCatalog.isSupported(device.productType) else { throw SetupError("Homeswift does not support the \(DeviceCatalog.modelName(device.productType))") }
        guard !device.localCredentials.isEmpty else { throw SetupError("Dyson gave no local credential for this device") }
        logger.info("Read the credential of device \(serial) through Setup")
        var settings: [String: JSONValue] = ["productType": .string(device.productType)]
        if let name = device.name { settings["name"] = .string(name) }
        if !device.version.isEmpty { settings["firmwareVersion"] = .string(device.version) }
        return .done(SetupOutcome(credentials: try JSONValue(encoding: DeviceCredentials(localCredentials: device.localCredentials)), settings: settings))
    }

    private enum SignInStep {
        case asking(SetupStep)
        case signedIn(token: String, countryCode: String)
    }

    /// The email and the country, then the password with the emailed code; the challenge between them in the Setup's
    /// state, never the password.
    private func signIn(_ request: SetupRequest, message: String) async throws -> SignInStep {
        if let challengeID = request.state["challengeId"]?.stringValue, let email = request.state["email"]?.stringValue,
           let countryCode = request.state["countryCode"]?.stringValue {
            guard let password = request.secret("password") else { throw SetupError("Enter the password") }
            do {
                let code = try CloudInput.code(request.answer("code").map(JSONValue.string))
                let token = try await cloud.verify(email: email, password: password, challengeID: challengeID, code: code, countryCode: countryCode)
                return .signedIn(token: token, countryCode: countryCode)
            } catch let failure as DysonCloud.Failure {
                throw SetupError(failure.message.contains("Invalid") ? "Invalid verification code" : failure.message)
            }
        }
        guard let typed = request.answer("email") else {
            return .asking(.ask(SetupPrompt(message: message, fields: [
                SetupField("email", label: "Email"), SetupField("countryCode", label: "Country (two letters, such as GB or US)", optional: true),
            ])))
        }
        do {
            let email = try CloudInput.email(.string(typed))
            let countryCode = try CloudInput.countryCode((request.answer("countryCode") ?? configuration.countryCode?.nonEmpty).map(JSONValue.string))
            switch try await cloud.requestCode(email: email, countryCode: countryCode) {
            case .token(let token):
                return .signedIn(token: token, countryCode: countryCode)
            case .code(let challengeID):
                return .asking(.ask(
                    SetupPrompt(message: "Enter your Dyson password and the code Dyson emailed you.", fields: [
                        SetupField("password", label: "Password", kind: .secret), SetupField("code", label: "Code", kind: .code),
                    ]),
                    state: ["email": .string(email), "countryCode": .string(countryCode), "challengeId": .string(challengeID)]))
            }
        } catch let failure as DysonCloud.Failure {
            throw SetupError(failure.message)
        }
    }
}
