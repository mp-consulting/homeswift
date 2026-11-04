import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Ring account is the instance's, an Account Login of an email and a password, then
// the 2FA code Ring sends (or the authenticator app's). The email and the password are used once and never kept; the
// vault keeps the refresh token Ring answers (rotated on every use, stored each time) and the hardware id Ring knows this
// client by. A Homebridge block's `refreshToken` is read once and moved into the vault (`canonicalSettings`). The
// devices come with the account.
extension RingPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    public func accountAuthorized() async -> Bool? {
        if let stored = context.credentials(as: RingAccount.self) { return stored.refused != true }
        return configuration.refreshToken?.isEmpty == false
    }

    public func discover() async throws -> [DiscoveredDevice] {
        built.sorted { $0.key < $1.key }.map { seed, device in
            DiscoveredDevice(
                deviceID: seed, name: device.name, model: device.deviceType, isSetUp: true,
                kind: device.isCamera ? Self.cameraKind : Self.deviceKind)
        }
    }

    static let cameraKind = "camera"
    static let deviceKind = "device"

    public func deviceKind(of deviceID: String) async -> String? { deviceID.hasSuffix("camera") ? Self.cameraKind : Self.deviceKind }

    /// The email and password, then the code Ring asks for; the email and password wait in the Setup's state (on the
    /// bridge) for the code step.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Ring devices come with the account: they need no setup of their own")
        let email: String, password: String
        var code: String?
        if let asked = request.state["email"]?.stringValue, let kept = request.state["password"]?.stringValue {
            email = asked
            password = kept
            guard let typed = request.answer("code") else { throw SetupError("Enter the code") }
            code = typed
        } else {
            guard let typed = request.answer("email"), let secret = request.secret("password") else {
                return .ask(SetupPrompt(message: "Sign in with your Ring account.", fields: [
                    SetupField("email", label: "Email"), SetupField("password", label: "Password", kind: .secret),
                ]))
            }
            email = typed
            password = secret
        }
        let hardwareID = context.credentials(as: RingAccount.self)?.hardwareId ?? hardwareID()
        let token: RingClient.Token
        do {
            token = try await RingClient.requestToken(
                http: dependencies.http, grant: .password(email: email, password: password), hardwareID: hardwareID, code: code,
                timeout: dependencies.timing.requestTimeout)
        } catch RingError.needsCode(let prompt) {
            return .ask(SetupPrompt(message: "\(prompt).", fields: [SetupField("code", label: "Code", kind: .code)]),
                        state: ["email": .string(email), "password": .string(password)])
        } catch let error as RingError {
            throw SetupError(error.description)
        } catch {
            throw SetupError("Ring did not answer: \(error)")
        }
        logger.info("Signed in to Ring through Setup")
        let previous = context.credentials(as: RingAccount.self)
        let account = RingAccount(refreshToken: token.refreshToken, hardwareId: hardwareID, wrapper: previous?.wrapper, importedFrom: nil)
        return .done(try SetupOutcome(encoding: account, settings: ["refreshToken": .null]))
    }

    // Settings (docs/plugins.md, "Settings"): the Plugin Settings are the Homebridge plugin's options; there are no
    // Plugin Accessory Settings. `hideDeviceIds` (Homebridge UUIDs) still hides, and `canonicalSettings` turns the ones of
    // known accessories into Excluded Accessory Settings by Device Id. The block's `refreshToken` goes into the vault.

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard var fields = block.objectValue else { return block }
        if let hidden = fields["hideDeviceIds"]?.arrayValue {
            var entries = fields["_accessories"]?.objectValue ?? [:]
            let seeds = Dictionary(knownSeeds.map { (RingIdentity.homebridgeUUID($0), $0) }, uniquingKeysWith: { first, _ in first })
            var left: [JSONValue] = []
            for item in hidden {
                guard let uuid = item.stringValue?.lowercased(), let seed = seeds[uuid] else {
                    left.append(item)
                    continue
                }
                var entry = entries[seed]?.objectValue ?? [:]
                if entry["excluded"] == nil { entry["excluded"] = true }
                entries[seed] = .object(entry)
            }
            if left.isEmpty { fields.removeValue(forKey: "hideDeviceIds") } else { fields["hideDeviceIds"] = .array(left) }
            if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        }
        if fields["refreshToken"] != nil, let token = configuration.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            // Moved once the block is written; the block answered as if the vault had it.
            let fingerprint = RingIdentity.sha256(token)
            if context.credentials(as: RingAccount.self)?.importedFrom != fingerprint {
                let wrapper = RingTokenWrapper(parsing: token)
                let context = context
                let stored = context.credentials(as: RingAccount.self)
                let account = RingAccount(
                    refreshToken: wrapper.refreshToken, hardwareId: wrapper.hardwareID ?? stored?.hardwareId ?? hardwareID(),
                    wrapper: wrapper.others.isEmpty ? nil : wrapper.others, importedFrom: fingerprint)
                await context.whenSettingsWritten { try context.saveCredentials(account) }
            }
            fields.removeValue(forKey: "refreshToken")
        }
        return .object(fields)
    }
}
