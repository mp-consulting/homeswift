import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the instance's account is the Overkiz setup, an Account Login that asks which service
// (a cloud by brand and region, or a gateway's local API), then the user and password (for the local API, the gateway's
// PIN or address and a Developer Mode token), checked by signing in. Setup keeps them in the vault and takes the
// block's `user` and `password` out. Every device comes with the account and asks nothing more; its Device Id is its
// deviceURL, the same on the cloud and on the local API.
extension TahomaPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// Signed in: an account Setup kept, or the block's `user` and `password`.
    public func accountAuthorized() async -> Bool? { account != nil }

    /// The setup's devices and scenarios: those of the running instance, or on an instance made for Setup a listing
    /// of the account's, when it has one.
    public func discover() async throws -> [DiscoveredDevice] {
        var listed = devices
        if listed.isEmpty, account != nil, client == nil {
            listed = (try? await withTimeout(scaled(8)) { [self] in try await connect(minting: false).devices() }) ?? []
        }
        let exclusions = DeviceGrouping.builtInExclusions.union(configuration.exclude ?? [])
        var found: [DiscoveredDevice] = []
        for group in DeviceGrouping.group(listed) {
            let device = group.device
            guard !DeviceGrouping.builtInExclusions.contains(where: { [device.uiClass, device.widgetName, device.controllableName].contains($0) }),
                  let type = MapperTable.mapper(for: device) else { continue }
            var discovered = DiscoveredDevice(
                deviceID: device.deviceURL, name: device.label, model: "\(device.uiClass) \(device.widgetName)", isSetUp: true,
                excludedBySettings: DeviceGrouping.isExcluded(device, by: exclusions), kind: type.kind)
            discovered.isReachable = device.available
            found.append(discovered)
        }
        for scenario in scenarios {
            found.append(DiscoveredDevice(deviceID: Self.scenarioDeviceID(oid: scenario.oid), name: scenario.label, model: "Scenario", isSetUp: true, kind: "scenario"))
        }
        return found
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if deviceID.hasPrefix("scene:") { return "scenario" }
        return devices.first { $0.deviceURL == deviceID }.flatMap(MapperTable.mapper(for:))?.kind
    }

    /// Asks which service and the account's user and password, and signs in with them: a refusal is an answer to
    /// correct, a server that does not answer too.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount()
        let values = OverkizService.allCases.map(\.rawValue)
        let current = account.flatMap { OverkizService(configured: $0.service) }?.rawValue ?? OverkizService.somfyEurope.rawValue
        guard let chosen = request.choice("service", among: values), let service = OverkizService(rawValue: chosen),
              let user = request.answer("user"), let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Sign in with the account of the vendor's app. For a gateway's local API, turn on Developer Mode in the TaHoma by Somfy app (tap the box's PIN seven times in its settings) and give the PIN and a token it generates.",
                fields: [
                    .choice("service", label: "Service", options: OverkizService.allCases.map { SetupOption($0.rawValue, label: $0.title) }, value: current),
                    SetupField("user", label: "E-mail, or the gateway's PIN or IP address"),
                    SetupField("password", label: "Password, or the Developer Mode token", kind: .secret),
                ]))
        }
        if service == .local, !Self.isPIN(user), !Self.isIPv4(user) {
            throw SetupError("Give the gateway's PIN (1234-5678-9012) or its IP address.")
        }
        let client: OverkizClient
        if service == .local {
            client = try await localClient(user: user, token: password, refusesAccount: false)
        } else {
            client = makeClient(.cloud(service, user: user, password: password), http: dependencies.cloudHTTP, refusesAccount: false)
        }
        do {
            try await client.signIn()
        } catch let error as OverkizError {
            if error.isBadCredentials || error.status == 401 || error.status == 400 {
                logger.info("The Overkiz account refused the credentials given through Setup")
                throw SetupError(service == .local ? "The gateway refused this token." : "The account refused this user and password.")
            }
            logger.info("Could not check the Overkiz account: \(error)")
            throw SetupError("Could not reach \(service == .local ? "the gateway" : "Overkiz"): \(error.message)")
        }
        logger.info("Signed in to the Overkiz account through Setup")
        let outcome = try SetupOutcome(
            encoding: TahomaAccount(service: service.rawValue, user: user, password: password),
            settings: ["service": .string(service.rawValue), "user": .null, "password": .null])
        return .done(outcome)
    }
}

/// Runs `body`, giving up after `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw OverkizError(message: "no answer within \(timeout)")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
