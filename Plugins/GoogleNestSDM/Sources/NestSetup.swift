import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Device Access project is the instance's account, a Browser Redirect. The person
// enters the project (its id, the OAuth client of the Google Cloud project linked to it, the Pub/Sub subscription), opens
// Google's Partner Connections Manager page to share homes and devices, and pastes back the address Google ends on; its
// code becomes a refresh token. The client secret goes in the vault as the account's credentials, the refresh token in
// the plugin's sealed token file (Google may send a new one at run time), and the rest are Plugin Settings. Every
// device comes with the account: thermostats, their fans, cameras, doorbells and displays are of those Device Kinds.
extension GoogleNestSDMPlugin {
    public static let accountAuthorization = AuthorizationMethod.browserRedirect

    /// Set up: the project, the client, the subscription and a refresh token.
    public func accountAuthorized() async -> Bool? {
        if case .success = account() { return true }
        return false
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if deviceID.hasSuffix(" Fan") { return "fan" }
        return (thermostats[deviceID].map { _ in SDMDevice.Kind.thermostat } ?? cameras[deviceID]?.device.kind).map { $0.suffix.lowercased() }
    }

    /// The devices the account shares: the running instance's, else one list.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices = thermostats.values.map(\.device) + cameras.values.map(\.device)
        if !devicesLoaded, case .success(let account) = account() {
            devices = (try? await SDMClient(caller: caller(for: account), projectID: account.projectID).listDevices()) ?? []
        }
        return devices.compactMap { device -> [DiscoveredDevice]? in
            guard let kind = device.kind else { return nil }
            let entry = DiscoveredDevice(deviceID: device.name, name: device.displayName, model: kind.suffix, isSetUp: true, kind: kind.suffix.lowercased())
            guard kind == .thermostat, options.showFan else { return [entry] }
            return [entry, DiscoveredDevice(deviceID: "\(device.name) Fan", name: "\(device.displayName) Fan", model: "Thermostat Fan", isSetUp: true, kind: "fan")]
        }.flatMap { $0 }.sorted { $0.name < $1.name }
    }

    /// The project's keys, then Google's page and the address it ends on.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Nest devices come with the Device Access project: they need no setup of their own")
        guard let project = request.state["project"]?.objectValue else {
            let projectID = request.answer("projectId") ?? configuration.projectId
            let clientID = request.answer("clientId") ?? configuration.clientId
            let secret = request.secret("clientSecret") ?? clientSecret
            let subscription = request.answer("subscriptionId") ?? configuration.subscriptionId
            guard let projectID, let clientID, let secret, let subscription else {
                return .ask(SetupPrompt(
                    message: "Enter your Device Access project, the OAuth client of its Google Cloud project, and its Pub/Sub subscription. The README says how to make them.",
                    fields: [
                        SetupField("projectId", label: "Device Access project ID", value: configuration.projectId),
                        SetupField("clientId", label: "OAuth client ID", value: configuration.clientId),
                        SetupField("clientSecret", label: "OAuth client secret", kind: .secret),
                        SetupField("subscriptionId", label: "Pub/Sub subscription (projects/…/subscriptions/…)", value: configuration.subscriptionId),
                        SetupField("gcpProjectId", label: "Google Cloud project ID", optional: true, value: configuration.gcpProjectId),
                    ]))
            }
            guard subscription.hasPrefix("projects/"), subscription.contains("/subscriptions/") else {
                throw SetupError("The subscription is its full name: projects/<project>/subscriptions/<subscription>")
            }
            var kept: [String: JSONValue] = [
                "projectId": .string(projectID), "clientId": .string(clientID), "clientSecret": .string(secret), "subscriptionId": .string(subscription),
            ]
            if let gcp = request.answer("gcpProjectId") ?? configuration.gcpProjectId { kept["gcpProjectId"] = .string(gcp) }
            return .ask(consentPrompt(projectID: projectID, clientID: clientID), state: ["project": .object(kept)])
        }
        func value(_ key: String) -> String { project[key]?.stringValue ?? "" }
        guard let pasted = request.answer("callbackUrl") else {
            return .ask(consentPrompt(projectID: value("projectId"), clientID: value("clientId")), state: request.state)
        }
        guard let code = GoogleOAuth.code(fromPasted: pasted) else { throw SetupError("Paste the address that starts with https://www.google.com?code=") }
        let granted: GoogleOAuth.Tokens
        do {
            granted = try await GoogleOAuth.exchange(code: code, clientID: value("clientId"), clientSecret: value("clientSecret"), transport: dependencies.transport)
        } catch {
            throw SetupError("Google did not accept the code: \(error). Open the page again for a new one.")
        }
        guard let refreshToken = granted.refreshToken else { throw SetupError("Google sent no refresh token: open the page again, it asks for consent each time") }
        let account = NestAccount(clientID: value("clientId"), clientSecret: value("clientSecret"), projectID: value("projectId"), refreshToken: refreshToken,
                                  subscriptionID: value("subscriptionId"))
        // One list checks the project, and starts the events (Google sends them once a list was made).
        let count: Int
        do {
            count = try await SDMClient(caller: caller(for: account), projectID: account.projectID).listDevices().count
        } catch {
            throw SetupError("Google refused to list the devices: \(error)")
        }
        do {
            try tokens.save(StoredToken(refreshToken: refreshToken))
        } catch {
            throw SetupError("Could not keep the refresh token: \(error)")
        }
        logger.info("Signed in through Setup: \(count) devices shared.")
        var settings: [String: JSONValue] = [
            "projectId": project["projectId"] ?? .null, "clientId": project["clientId"] ?? .null, "subscriptionId": project["subscriptionId"] ?? .null,
            "clientSecret": .null, "refreshToken": .null,
        ]
        if let gcp = project["gcpProjectId"] { settings["gcpProjectId"] = gcp }
        return .done(SetupOutcome(credentials: ["clientSecret": .string(value("clientSecret"))], settings: settings))
    }

    private func consentPrompt(projectID: String, clientID: String) -> SetupPrompt {
        SetupPrompt(
            message: "On Google's page that opens, pick the homes and devices to share, and allow access. Google then opens www.google.com: paste the address it ends on.",
            fields: [SetupField("callbackUrl", label: "Address the browser ended on", kind: .url)],
            url: GoogleOAuth.authorizationURL(projectID: projectID, clientID: clientID))
    }

    // MARK: Settings

    /// The block in its canonical shape: a Homebridge block's `clientSecret` goes to the vault's credentials and its
    /// `refreshToken` to the sealed token file once the block is written, and both leave the block. The other keys are
    /// Plugin Settings as they are; the plugin has no per-device settings.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard var fields = block.objectValue, fields["clientSecret"] != nil || fields["refreshToken"] != nil else { return block }
        // The block may only name a secret (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        let secret = configuration.clientSecret, token = configuration.refreshToken
        let context = context, tokenFile = tokens
        let held = context.credentials()?.objectValue ?? [:]
        await context.whenSettingsWritten {
            if let secret, held["clientSecret"]?.stringValue != secret {
                var credentials = held
                credentials["clientSecret"] = .string(secret)
                try context.saveCredentials(.object(credentials))
            }
            // A refresh token put in the block is the person's latest: it replaces the one kept.
            if let token { try tokenFile.save(StoredToken(refreshToken: token)) }
        }
        if secret != nil || held["clientSecret"] != nil { fields.removeValue(forKey: "clientSecret") }
        if token != nil || tokens.load() != nil { fields.removeValue(forKey: "refreshToken") }
        return .object(fields)
    }
}
