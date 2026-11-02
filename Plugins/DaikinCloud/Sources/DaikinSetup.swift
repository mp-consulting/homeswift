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
        // How to sign in, asked first, the block's picked: it becomes the block's `authMode`.
        guard let chosen = request.choice("authMode", among: AuthMode.allCases.map(\.rawValue)), let mode = AuthMode(rawValue: chosen) else {
            return .ask(SetupPrompt(message: "Choose how Homeswift signs in to Daikin.", fields: [
                .choice("authMode", label: "Sign in with", options: [
                    SetupOption(AuthMode.developerPortal.rawValue, label: "Daikin Developer Portal",
                                detail: "An app you make on Daikin's portal, then Daikin's sign-in page: 200 requests a day."),
                    SetupOption(AuthMode.mobileApp.rawValue, label: "Onecta app account",
                                detail: "The email and password of the Onecta app: 3000 requests a day and live updates."),
                ], value: settings.authMode.rawValue),
            ]))
        }
        // The answer that chose is not one the next step reads.
        let next = SetupRequest(target: request.target, answers: request.answers.filter { $0.key != "authMode" }, state: request.state)
        var step = mode == .mobileApp ? try await authorizeMobile(next) : try await authorizeDeveloperPortal(next)
        // Another way of signing in takes its recommended polling with it, as the Homebridge page's switch did.
        if case .done(var outcome) = step, mode != settings.authMode {
            for (key, value) in Self.recommendedPolling(mode) where outcome.settings[key] == nil { outcome.settings[key] = value }
            step = .done(outcome)
        }
        return step.keeping("authMode", .string(mode.rawValue))
    }

    /// What each way of signing in polls with: the Developer Portal's 200 calls a day, the Onecta app's 3000 and its WebSocket.
    static func recommendedPolling(_ mode: AuthMode) -> [String: JSONValue] {
        switch mode {
        case .developerPortal: ["updateIntervalInMinutes": 15, "forceUpdateDelay": 60000, "enableWebSocket": false]
        case .mobileApp: ["updateIntervalInMinutes": 5, "forceUpdateDelay": 10000, "enableWebSocket": true]
        }
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

    /// The client, when the block has none, with the callback server's address and port, which make the app's redirect
    /// URI (this host's detected address and the block's port unless typed); then Daikin's page, open until the callback
    /// server catches its redirect, or until the person pastes the address it ended on.
    private func authorizeDeveloperPortal(_ request: SetupRequest) async throws -> SetupStep {
        if request.state["url"] == nil {
            let clientID = request.answer("clientId") ?? settings.clientID
            let clientSecret = request.answer("clientSecret") ?? settings.clientSecret
            let detected = settings.callbackServerExternalAddress ?? dependencies.addresses().first ?? "127.0.0.1"
            guard let clientID, let clientSecret else {
                return .ask(SetupPrompt(
                    message: "Enter the app you made on the Daikin Developer Portal. Its redirect URI is {redirectURI}, unless you change the callback server's address or port.",
                    values: ["redirectURI": DeveloperPortalOAuth.redirectURI(address: detected, port: settings.callbackServerPort)],
                    fields: [
                        SetupField("clientId", label: "Client ID"), SetupField("clientSecret", label: "Client Secret", kind: .secret),
                        SetupField("callbackServerExternalAddress", label: "Callback server address", optional: true),
                        SetupField("callbackServerPort", label: "Callback server port", optional: true),
                    ]))
            }
            let typedAddress = request.answer("callbackServerExternalAddress")
            let typedPort = request.answer("callbackServerPort")
            if typedAddress != nil || typedPort != nil {
                // Checked as the block is: Daikin's redirect has to reach this host from the browser.
                var raw: [String: JSONValue] = ["authMode": .string(AuthMode.developerPortal.rawValue), "clientId": .string(clientID), "clientSecret": .string(clientSecret),
                                                "callbackServerExternalAddress": .string(typedAddress ?? detected)]
                if let typedPort { raw["callbackServerPort"] = .string(typedPort) }
                if let error = DaikinSettings.validate(raw).errors.first { throw SetupError(error) }
            }
            let address = typedAddress ?? detected
            let port = typedPort.flatMap { DaikinSettings.port(.string($0)) } ?? settings.callbackServerPort
            let started: JSONValue
            do {
                started = try await startAuthorization([
                    "clientId": .string(clientID), "clientSecret": .string(clientSecret), "callbackServerExternalAddress": .string(address),
                    "callbackServerPort": .number(Double(port)),
                ])
            } catch {
                throw SetupError(message(of: error))
            }
            guard let url = started["authUrl"]?.stringValue else { throw SetupError("Daikin's sign-in did not start") }
            var typed: [String: JSONValue] = [:]
            if request.answer("clientId") != nil { typed["clientId"] = .string(clientID) }
            if request.answer("clientSecret") != nil { typed["clientSecret"] = .string(clientSecret) }
            if let typedAddress { typed["callbackServerExternalAddress"] = .string(typedAddress) }
            if typedPort != nil { typed["callbackServerPort"] = .number(Double(port)) }
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
