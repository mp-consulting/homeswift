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
            let model = TapoCameraKind(type: device.type)?.model ?? TapoKind(type: device.type).model
            let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? device.trimmedHost ?? deviceID
            var discovered = DiscoveredDevice(deviceID: deviceID, name: name, model: model, address: device.trimmedHost, isSetUp: true)
            if let running = devices[deviceID] { discovered.isReachable = await running.isReachable }
            found.append(discovered)
        }
        return found
    }

    /// The account's email and password, checked with a handshake on the first device of `devices` when there is one: a
    /// device that refuses them is an answer to correct; one that does not answer leaves them unchecked. With a camera
    /// whose motion is on, the account also signs in to the TP-Link cloud (docs/clean-room/TapoCloudEvents.md, 3), which
    /// e-mails a code the first time: the email and password wait in the Setup's state (on the bridge) for it.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { return .done(SetupOutcome()) }
        if let username = request.state["username"]?.stringValue, let password = request.state["password"]?.stringValue,
           let process = request.state["process"]?.stringValue {
            guard let code = request.answer("code") else { throw SetupError("Enter the code the Tapo cloud e-mailed.") }
            let credentials = TapoCredentials(username: username, password: password)
            let cloud = Self.makeCloud(context: context, dependencies: dependencies) { credentials }
            do {
                try await cloud.finish(code: code.trimmingCharacters(in: .whitespaces), processID: process)
            } catch {
                logger.info("The Tapo cloud refused the code given through Setup: \(error)")
                throw SetupError("The Tapo cloud refused this code.")
            }
            logger.info("Signed in to the Tapo account and its cloud through Setup")
            return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: ["username": .null, "password": .null]))
        }
        guard let username = request.answer("username"), let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Sign in with your Tapo account, and turn on Third-Party Compatibility in the Tapo app. For a battery camera, use its owner's account.",
                fields: [SetupField("username", label: "Email"), SetupField("password", label: "Password", kind: .secret)]))
        }
        let credentials = TapoCredentials(username: username, password: password)
        if configuredDevices().contains(where: { !context.isExcluded($0.deviceID) && TapoCameraKind(type: $0.device.type) != nil && $0.device.motion != false }) {
            let cloud = Self.makeCloud(context: context, dependencies: dependencies) { credentials }
            do {
                try await cloud.signIn()
            } catch TapoCloudError.mfaRequired(let process) {
                do {
                    try await cloud.requestCode()
                } catch {
                    logger.info("The Tapo cloud did not send a code: \(error)")
                    throw SetupError("The Tapo cloud wants a code but did not send one.")
                }
                return .ask(SetupPrompt(message: "The Tapo cloud e-mailed a code to \(username): enter it so the bridge can follow the cameras' motion.",
                                        fields: [SetupField("code", label: "Code", kind: .code)]),
                            state: ["username": .string(username), "password": .string(password), "process": .string(process)])
            } catch let error as TapoCloudError where error.isRefusedSignIn {
                logger.info("The Tapo cloud refused the account given through Setup: \(error)")
                throw SetupError("The Tapo cloud refused this email and password.")
            } catch {
                logger.info("Could not sign in to the Tapo cloud: \(error)")
            }
        }
        if let (deviceID, device) = configuredDevices().first(where: { !context.isExcluded($0.deviceID) && TapoCameraKind(type: $0.device.type) == nil }),
           let host = device.trimmedHost {
            let connection = makeConnection(
                deviceID: deviceID, host: host, requestTimeout: dependencies.setupTimeout, handshakeTimeout: dependencies.setupTimeout) { credentials }
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
