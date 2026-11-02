import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the MyDolphin account is the instance's, an Account Login whose second step is the
// code Maytronics sends (Cognito's CUSTOM_AUTH, as the setup page's wizard). The refresh token goes in the vault, never
// in config.json; the robots come with the account and need nothing more.
extension DolphinPoolCleanerPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// The refresh token Setup keeps in the vault; preferred over the block's `refreshToken`.
    var storedRefreshToken: String? { context.credentials()?["refreshToken"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    /// Signed in: a refresh token Setup kept, or the block's (a Homebridge block pasted in: a refresh token, or an email
    /// and a password).
    public func accountAuthorized() async -> Bool? { storedRefreshToken != nil || configuration.hasCredentials }

    public func discover() async throws -> [DiscoveredDevice] {
        robots.map { DiscoveredDevice(deviceID: $0.serialNumber, name: $0.name, model: "Dolphin", isSetUp: true) }
    }

    /// The email, then each code Cognito asks for; the Cognito session between the steps is in the Setup's state.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Dolphin robots come with the account: they need no setup of their own")
        let cognito = CognitoClient(transport: dependencies.transport, timeout: Maytronics.setupRequestTimeout)
        let response: JSONValue
        let email: String
        if let challenge = request.state["challenge"]?.stringValue, let session = request.state["session"]?.stringValue, let asked = request.state["email"]?.stringValue {
            guard let code = request.answer("code") else { throw SetupError("Enter the code") }
            email = asked
            let field = ["SMS_MFA": "SMS_MFA_CODE", "SOFTWARE_TOKEN_MFA": "SOFTWARE_TOKEN_MFA_CODE", "CUSTOM_CHALLENGE": "ANSWER"][challenge] ?? "SMS_MFA_CODE"
            do {
                response = try await cognito.respondToAuthChallenge(name: challenge, session: session, responses: ["USERNAME": email, field: code])
            } catch {
                throw SetupError(SetupWizard.message(for: error))
            }
        } else {
            guard let typed = request.answer("email") else {
                return .ask(SetupPrompt(message: "Sign in with your MyDolphin account: Maytronics sends you a code.", fields: [SetupField("email", label: "Email")]))
            }
            email = typed
            do {
                response = try await cognito.initiateAuth(flow: "CUSTOM_AUTH", parameters: ["USERNAME": email])
            } catch {
                throw SetupError(SetupWizard.message(for: error))
            }
        }
        if let challenge = response["ChallengeName"]?.stringValue, !challenge.isEmpty {
            guard challenge != "MFA_SETUP" else { throw SetupError("Set up two-factor authentication in the MyDolphin app first") }
            let message = [
                "SMS_MFA": "Enter the code sent to your phone.", "SOFTWARE_TOKEN_MFA": "Enter the code from your authenticator app.",
            ][challenge] ?? "Enter the code sent to your email."
            return .ask(SetupPrompt(message: message, fields: [SetupField("code", label: "Code", kind: .code)]),
                        state: ["email": .string(email), "challenge": .string(challenge), "session": response["Session"] ?? ""])
        }
        guard let tokens = SetupWizard.Tokens(response) else { throw SetupError("Maytronics sent no token") }
        let robot = await wizard.completeAuthentication(tokens)
        guard robot["success"] == true else { throw SetupError(robot["error"]?.stringValue ?? "MyDolphin authentication failed") }
        guard let refreshToken = robot["refreshToken"]?.stringValue else { throw SetupError("Maytronics sent no refresh token") }
        logger.info("Signed in through Setup", metadata: ["robot": "\(robot["robotName"]?.stringValue ?? "")"])
        return .done(SetupOutcome(credentials: ["refreshToken": .string(refreshToken)], settings: ["email": .string(email)]))
    }
}
