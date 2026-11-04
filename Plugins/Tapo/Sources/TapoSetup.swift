import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the instance's account is the Tapo account, an Account Login whose email and password
// every device of the block checks in its handshake; Setup keeps them in the vault and takes the block's `username` and
// `password` out. Each device is one of `devices`, by address (the devices announce nothing the plugin reads), whose
// Device Id is its host and name run together, the seed of the Homebridge plugin's accessory, and which asks nothing
// more.
extension TapoPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// Signed in: an account Setup kept, or the block's `username` and `password`.
    public func accountAuthorized() async -> Bool? { credentials != nil }

    /// The devices of `devices`: those running, with whether they answer, and, on an instance made for Setup, the others.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        for (deviceID, device) in configuredDevices() {
            let kind = TapoKind(type: device.type)
            let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? device.trimmedHost ?? deviceID
            var discovered = DiscoveredDevice(deviceID: deviceID, name: name, model: kind.model, address: device.trimmedHost, isSetUp: true)
            if let running = devices[deviceID] { discovered.isReachable = await running.isReachable }
            found.append(discovered)
        }
        return found
    }

    /// The account's email and password, checked with a handshake on the first device of `devices` when there is one: a
    /// device that refuses them is an answer to correct; one that does not answer leaves them unchecked.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { return .done(SetupOutcome()) }
        guard let username = request.answer("username"), let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Sign in with your Tapo account, and turn on Third-Party Compatibility in the Tapo app.",
                fields: [SetupField("username", label: "Email"), SetupField("password", label: "Password", kind: .secret)]))
        }
        let credentials = TapoCredentials(username: username, password: password)
        if let (_, device) = configuredDevices().first, let host = device.trimmedHost {
            let connection = TapoConnection(
                host: host, http: dependencies.http, requestTimeout: dependencies.setupTimeout, handshakeTimeout: dependencies.setupTimeout,
                logger: logger) { credentials }
            do {
                _ = try await connection.call("get_device_info")
            } catch TapoError.invalidCredentials {
                logger.info("The Tapo device at \(host) refused the account given through Setup")
                throw SetupError("A Tapo device refused this email and password.")
            } catch {
                logger.info("Could not check the Tapo account on \(host): \(error)")
            }
        }
        logger.info("Signed in to the Tapo account through Setup")
        return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: ["username": .null, "password": .null]))
    }
}
