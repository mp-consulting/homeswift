import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Govee account is the instance's, an Account Login whose second step is the code
// Govee emails for a new device (its "new device" check). The login it gives, the AWS IoT certificate and the password
// go in the vault (`StoredLogin`), never in config.json; the block's `username`, `password` and `code` still work. The
// devices are the account's and the LAN's, by their Govee device id (`AA:BB:…`, as their accessories' ids): the
// account's need nothing more, and one found only on the LAN is published once it has Accessory Settings.
extension GoveePlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// The account's username and password: those Setup kept in the vault, unless the block names another user; else
    /// the block's, with its one-time `code`.
    struct AccountLogin: Equatable {
        var username: String
        var password: String
        var code: String?
    }

    func accountLogin() -> AccountLogin? {
        let stored = CredentialStore.stored(context)
        if let stored, let password = stored.password, configuration.username == nil || configuration.username == stored.username {
            return AccountLogin(username: stored.username, password: password)
        }
        guard let username = configuration.username, let password = configuration.password else { return nil }
        return AccountLogin(username: username, password: password, code: configuration.code)
    }

    /// Signed in: a login kept in the vault, or a username and password in the block (the plugin signs in with them).
    public func accountAuthorized() async -> Bool? {
        accountLogin() != nil || CredentialStore.stored(context)?.credentials != nil
    }

    /// The account's devices and those of the LAN, as the running instance last found them (`discovered-devices.json`);
    /// an instance that has found none yet reads the account's list with the token the vault keeps.
    public func discover() async throws -> [DiscoveredDevice] {
        var entries = discovered.isEmpty ? discoveredFile.load() ?? [] : discovered
        if entries.isEmpty, let login = CredentialStore.stored(context), let credentials = login.credentials {
            let api = GoveeAPI(transport: dependencies.http, clientId: GoveeAPI.clientId(username: login.username))
            entries = try await api.devices(token: credentials.token).map { device in
                ["deviceId": .string(Govee.colonDeviceId(device["device"]?.stringValue ?? "")), "deviceName": device["deviceName"] ?? .null,
                 "model": device["sku"] ?? .null, "account": true]
            }
        }
        let signedIn = accountLogin() != nil
        return entries.compactMap { entry in
            guard let id = entry["deviceId"]?.stringValue, !id.isEmpty else { return nil }
            let model = entry["model"]?.stringValue
            let name = deviceSettings[id]?.label ?? entry["deviceName"]?.stringValue?.nonEmpty ?? id
            // As `initializeDevices` decides: the account's devices, and with an account, of the LAN's only those configured.
            let published = devices[id] != nil
                || (!started && !isIgnored(id, model: model) && (entry["account"] == true || !signedIn || deviceSettings[id] != nil))
            return DiscoveredDevice(
                deviceID: id, name: name, model: model, address: entry["ip"]?.stringValue, isSetUp: published,
                excludedBySettings: isIgnoredBySettings(id, model: model))
        }
    }

    /// The account: the email and password, then the code Govee emails when it does not know this bridge; the login is
    /// checked with Govee and its IoT certificate fetched before it is kept. A device: given Accessory Settings, which is
    /// what publishes one found only on the LAN.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        if case .device(let device) = request.target {
            return .done(SetupOutcome(settings: ["name": .string(device.name)]))
        }
        let username: String, password: String, code: String?
        if let asked = request.state["username"]?.stringValue, let kept = request.state["password"]?.stringValue {
            guard let typed = request.answer("code") else { throw SetupError("Enter the code") }
            (username, password, code) = (asked, kept, typed)
        } else {
            guard let typed = request.answer("username"), let secret = request.answers["password"], !secret.isEmpty else {
                return .ask(SetupPrompt(message: "Sign in with your Govee account.", fields: [
                    SetupField("username", label: "Email"), SetupField("password", label: "Password", kind: .secret),
                ]))
            }
            (username, password, code) = (typed, secret, nil)
        }
        let api = GoveeAPI(transport: dependencies.http, clientId: GoveeAPI.clientId(username: username))
        let account = GoveeAccount(api: api, username: username, password: password, code: code, logger: context.logger)
        let result: GoveeAccount.LoginResult
        do {
            // No retries: the person is waiting, and answers again.
            result = try await account.login(retry: GoveeAccount.maximumRetries)
        } catch GoveeAPIError.twoFactorRequired {
            // Kept by the bridge between the steps, never shown: the login with the code needs the password again.
            return .ask(SetupPrompt(message: "Govee emailed you a verification code. Enter it.", fields: [SetupField("code", label: "Code", kind: .code)]),
                        state: ["username": .string(username), "password": .string(password)])
        } catch GoveeAPIError.twoFactorInvalid {
            throw SetupError("Govee refused the code: check it and try again")
        } catch {
            throw SetupError("Govee refused the sign-in: \(error)")
        }
        context.logger.info("[HTTP] Signed in through Setup")
        let login = StoredLogin(username: username, password: password, credentials: result.credentials, iot: result.iot)
        return .done(SetupOutcome(
            credentials: try JSONValue(data: JSONEncoder().encode(login)), settings: ["username": .string(username), "password": .null, "code": .null]))
    }
}
