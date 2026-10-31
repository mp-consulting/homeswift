import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Daikin account is the instance's. With the Developer Portal (`authMode`'s default)
// it is a Browser Redirect: Daikin's sign-in page, whose redirect the callback server catches, or whose address the
// person pastes. With the Onecta app's login it is an Account Login. The tokens stay where the plugin keeps and
// refreshes them (its own vault entries, `tokenFile`); the client and the login are Plugin Settings, sealed.
extension DaikinCloudPlugin {
    public static let accountAuthorization = AuthorizationMethod.browserRedirect

    public func accountAuthorized() async -> Bool? { activeToken().tokens != nil }

    /// The devices the account has: the running session's, else one call with the saved token.
    public func discover() async throws -> [DiscoveredDevice] {
        let listed = await listDevices(mode: nil, refresh: false)
        return (listed["devices"]?.arrayValue ?? []).compactMap { device in
            guard let id = device["id"]?.stringValue else { return nil }
            return DiscoveredDevice(deviceID: id, name: device["name"]?.stringValue ?? id, model: device["model"]?.stringValue, isSetUp: !settings.isExcluded(id),
                                    excludedBySettings: settings.isExcluded(id))
        }
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Daikin devices come with the account: they need no setup of their own")
        return settings.authMode == .mobileApp ? try await authorizeMobile(request) : try await authorizeDeveloperPortal(request)
    }

    private func authorizeMobile(_ request: SetupRequest) async throws -> SetupStep {
        guard let email = request.answer("email"), let password = request.secret("password") else {
            return .ask(SetupPrompt(message: "Sign in with the account of the Daikin Onecta app.",
                                    fields: [SetupField("email", label: "Email"), SetupField("password", label: "Password", kind: .secret)]))
        }
        let result = await testMobileLogin(["email": .string(email), "password": .string(password)])
        guard result["success"] == true else { throw SetupError(result["message"]?.stringValue ?? "Daikin refused the sign-in") }
        return .done(SetupOutcome(settings: ["daikinEmail": .string(email), "daikinPassword": .string(password)]))
    }

    /// The client, when the block has none; then Daikin's page, open until the callback server catches its redirect, or
    /// until the person pastes the address it ended on.
    private func authorizeDeveloperPortal(_ request: SetupRequest) async throws -> SetupStep {
        if request.state["url"] == nil {
            let clientID = request.answer("clientId") ?? settings.clientID
            let clientSecret = request.answer("clientSecret") ?? settings.clientSecret
            guard let clientID, let clientSecret else {
                return .ask(SetupPrompt(message: "Enter the app you made on the Daikin Developer Portal.", fields: [
                    SetupField("clientId", label: "Client ID"), SetupField("clientSecret", label: "Client Secret", kind: .secret),
                ]))
            }
            let address = settings.callbackServerExternalAddress ?? dependencies.addresses().first ?? "127.0.0.1"
            let started: JSONValue
            do {
                started = try await startAuthorization([
                    "clientId": .string(clientID), "clientSecret": .string(clientSecret), "callbackServerExternalAddress": .string(address),
                    "callbackServerPort": .number(Double(settings.callbackServerPort)),
                ])
            } catch {
                throw SetupError(message(of: error))
            }
            guard let url = started["authUrl"]?.stringValue else { throw SetupError("Daikin's sign-in did not start") }
            var typed: [String: JSONValue] = [:]
            if request.answer("clientId") != nil { typed["clientId"] = .string(clientID) }
            if request.answer("clientSecret") != nil { typed["clientSecret"] = .string(clientSecret) }
            return .ask(redirectPrompt(url), state: ["url": .string(url), "settings": .object(typed)])
        }
        let typed = request.state["settings"]?.objectValue ?? [:]
        if let pasted = request.answer("callbackUrl") {
            do {
                _ = try await completeAuthorization(["callbackUrl": .string(pasted)])
            } catch {
                throw SetupError(message(of: error))
            }
            return .done(SetupOutcome(settings: typed))
        }
        let result = await pollAuthorization()
        if result["success"] == true { return .done(SetupOutcome(settings: typed)) }
        if let error = result["error"]?.stringValue { throw SetupError(error) }
        guard pendingAuth != nil else { throw SetupError("The sign-in ended: start it again") }
        return .ask(redirectPrompt(request.state["url"]?.stringValue ?? ""), state: request.state)
    }

    private func redirectPrompt(_ url: String) -> SetupPrompt {
        SetupPrompt(
            message: "Sign in with Daikin on the page that opens. If it does not come back here by itself, paste the address the browser ends on.",
            fields: [SetupField("callbackUrl", label: "Address the browser ended on", kind: .url, optional: true)], url: url,
            waitSeconds: Int(Self.authorizationWindow.components.seconds), retryAfter: 3)
    }
}
