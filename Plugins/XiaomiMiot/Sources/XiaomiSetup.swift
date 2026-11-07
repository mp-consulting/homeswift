import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"; docs/clean-room/XiaomiMiot.md section 3): the instance's account is a Xiaomi account,
// optional, signed in with a QR code scanned in the Mi Home app (first) or a password and an emailed code; its session is
// in the vault. Devices are found by the miIO hello broadcast and in the account's list, merged by did, the Device Id:
// those the account lists come with their token; others ask for one. Add by address takes an address and a token.
extension XiaomiMiotPlugin {
    public static let accountAuthorization = AuthorizationMethod.deviceCode
    public static let accountRequirement = AccountRequirement.optional(adds: "Finds your devices and their tokens in your Xiaomi account.")
    public static let newDevices: NewDevices? = .byAddress

    // MARK: The account's session

    /// homebridge-miot's session file, in the vault (3.6); a copy of `.miot_micloud/cachedSession` moves in when read.
    var sessionFile: SecretFile<JSONValue> {
        context.secretFile("cachedSession", as: JSONValue.self,
                           legacyFile: context.storageDirectory.appendingPathComponent(".miot_micloud").appendingPathComponent("cachedSession"))
    }

    /// The account's credentials: the session Setup gave, and the username and password of the password way.
    var accountCredentials: JSONValue? { context.credentials() }

    /// The session: the newest of Setup's and the session file's.
    func session() -> MiSession? {
        let fromSetup = accountCredentials?["session"].flatMap(MiSession.init(json:))
        let fromFile = sessionFile.load().flatMap(MiSession.init(json:))
        switch (fromSetup, fromFile) {
        case let (setup?, file?): return file.timestamp > setup.timestamp ? file : setup
        case let (setup?, nil): return setup
        case let (nil, file?): return file
        default: return nil
        }
    }

    func keep(_ session: MiSession) {
        try? sessionFile.save(session.json)
        var credentials = accountCredentials?.objectValue ?? [:]
        credentials["session"] = session.json
        try? context.saveCredentials(.object(credentials))
        logger.info("Xiaomi session saved")
    }

    public func accountAuthorized() async -> Bool? {
        if session() != nil { return true }
        let credentials = accountCredentials
        return credentials?["username"]?.stringValue != nil && credentials?["password"]?.stringValue != nil
    }

    /// The account's devices in the configured region, kept 5 minutes (3.5). A refused session is signed in again when
    /// the password is known (4.6), refreshed for a QR session, or said refused.
    func accountDevices() async -> [CloudDevice] {
        if let cloudList, dependencies.now().timeIntervalSince(cloudList.at) < dependencies.cloudListAge { return cloudList.devices }
        guard let session = session() else { return [] }
        let country = configuration.country
        do {
            let list = try await cloud.devices(session: session, country: country)
            cloudList = (list, dependencies.now())
            remember(list)
            logger.info("Found \(list.count) devices in the Xiaomi account (\(country))")
            return list
        } catch MiCloud.CloudError.refused {
            guard let renewed = await renew(session) else {
                context.accountRefused("The Xiaomi session expired; sign in again.")
                return []
            }
            keep(renewed)
            let list = (try? await cloud.devices(session: renewed, country: country)) ?? []
            cloudList = (list, dependencies.now())
            remember(list)
            return list
        } catch {
            logger.warning("Could not list the Xiaomi account's devices: \(error)")
            return []
        }
    }

    /// A new session without a person: the password again, or a QR session's refresh.
    private func renew(_ session: MiSession) async -> MiSession? {
        let credentials = accountCredentials
        if let username = credentials?["username"]?.stringValue, let password = credentials?["password"]?.stringValue {
            if case .signedIn(let renewed)? = try? await cloud.passwordLogin(username: username, password: password, identity: session.identity,
                                                                              country: configuration.country) {
                return renewed
            }
            return nil
        }
        return try? await cloud.refresh(session)
    }

    // MARK: Discovery (3.5)

    public func discover() async throws -> [DiscoveredDevice] {
        let network = dependencies.network, window = dependencies.discoveryWindow, logger = logger
        async let hello = MiioDiscovery.broadcast(network: network, window: window, logger: logger)
        let account = await accountDevices()
        let replies = await hello
        logger.info("Discovered \(replies.count) devices by hello, \(account.count) in the account")
        var found: [String: DiscoveredDevice] = [:]
        let configured = Dictionary(configuredDevices().compactMap { device in device.did.map { ($0, device) } }) { first, _ in first }
        let answered = Dictionary(replies.map { (String($0.deviceID), $0.address) }) { first, _ in first }
        for device in account {
            if device.isOutOfScope || device.model.map(MiotSpec.needsCloud(model:)) == true {
                if skippedLogged.insert(device.did).inserted { logger.debug("Skipping \(device.model ?? "a device") \(device.did): out of scope") }
                continue
            }
            let address = answered[device.did] ?? device.ip
            found[device.did] = DiscoveredDevice(
                deviceID: device.did, name: device.name ?? device.model.map { "Xiaomi \($0)" } ?? "Xiaomi device \(device.did)", model: device.model,
                address: address, authorization: device.token == nil ? .apiKey : .none, isSetUp: configured[device.did] != nil,
                kind: await kind(did: device.did, model: device.model))
            if let address, configured[device.did] != nil { await learned(address: address, for: device.did) }
        }
        for reply in replies {
            let did = String(reply.deviceID)
            guard found[did] == nil else { continue }
            let model = configured[did]?.options.model ?? knownDevices.load()?[did]?.model
            found[did] = DiscoveredDevice(deviceID: did, name: configured[did]?.options.name ?? model.map { "Xiaomi \($0)" } ?? "Xiaomi device \(did)",
                                          model: model, address: reply.address, authorization: .apiKey, isSetUp: configured[did] != nil,
                                          kind: await kind(did: did, model: model))
            if configured[did] != nil { await learned(address: reply.address, for: did) }
        }
        for (did, device) in configured where found[did] == nil {
            found[did] = DiscoveredDevice(deviceID: did, name: device.options.name ?? "Xiaomi device \(did)", model: device.options.model, address: device.ip,
                                          authorization: .apiKey, isSetUp: true, kind: await kind(did: did, model: device.options.model))
        }
        for (did, device) in found where device.isSetUp {
            // Set up, but neither the hello nor the last poll heard it: not responding.
            let polled = await devices[did]?.isReachable ?? false
            if answered[did] == nil, !polled { found[did]?.isReachable = false }
        }
        return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// A device's kind: its spec's device type when kept, else its model's middle segment.
    func kind(did: String, model: String?) async -> String {
        if let running = devices[did], case let summary = await running.summary(), let kind = summary["kind"]?.stringValue, kind != "other" { return kind }
        guard let model else { return "other" }
        if MiotSpec.isLegacyVacuum(model: model) { return "vacuum" }
        if let spec = await registry.cached(model: model) { return MiotSpec.kind(deviceType: spec.deviceType) }
        return MiotSpec.kind(model: model)
    }

    public func deviceKind(of deviceID: String) async -> String? {
        let model = context.accessorySettings(for: deviceID).plugin["model"]?.stringValue ?? knownDevices.load()?[deviceID]?.model
        return await kind(did: deviceID, model: model)
    }

    // MARK: Steps

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account: return try await authorizeAccount(request)
        case .newDevice: return try await addByAddress(request)
        case .device(let device): return try await authorizeDevice(device, request)
        }
    }

    static let regionOptions: [SetupOption] = [
        SetupOption("cn", label: "Mainland China"), SetupOption("de", label: "Europe"), SetupOption("us", label: "United States"),
        SetupOption("ru", label: "Russia"), SetupOption("tw", label: "Taiwan"), SetupOption("sg", label: "Singapore"),
        SetupOption("in", label: "India"), SetupOption("i2", label: "i2"),
    ]

    private func authorizeAccount(_ request: SetupRequest) async throws -> SetupStep {
        guard let method = request.choice("method", among: ["qr", "password"]), let country = request.choice("country", among: MiCloud.regions) else {
            return .ask(SetupPrompt(message: "Choose how Homeswift signs in to your Xiaomi account, and its region.", fields: [
                .choice("method", label: "Sign in with", options: [
                    SetupOption("qr", label: "QR code", detail: "Scanned with the Mi Home app on your phone."),
                    SetupOption("password", label: "Password", detail: "The account's email and password, then a code Xiaomi sends by email."),
                ], value: "qr"),
                .choice("country", label: "Region", options: Self.regionOptions, value: configuration.country),
            ]))
        }
        let step = method == "qr" ? try await qrStep(request, country: country) : try await passwordStep(request, country: country)
        guard case .ask = step else { return step }
        return step.keeping("method", .string(method)).keeping("country", .string(country))
    }

    /// The Plugin Settings an account Setup writes: `micloud` with its region, its sign-in keys left to the vault.
    private func accountSettings(country: String) -> [String: JSONValue] {
        var micloud = configuration.micloud
        micloud.removeValue(forKey: "username")
        micloud.removeValue(forKey: "password")
        micloud["country"] = .string(country)
        return ["micloud": .object(micloud)]
    }

    private func qrStep(_ request: SetupRequest, country: String) async throws -> SetupStep {
        let now = dependencies.now().timeIntervalSince1970
        guard let longPoll = request.state["lp"]?.stringValue, let deadline = request.state["deadline"]?.doubleValue else {
            let identity = MiCloud.Identity.random()
            let login: MiCloud.QRLogin
            do {
                login = try await cloud.startQR(identity: identity)
            } catch {
                logger.warning("Xiaomi did not make a QR code: \(error)")
                throw SetupError("Xiaomi did not make a QR code. Try again in a moment.")
            }
            let state: JSONValue = [
                "lp": .string(login.longPoll), "qr": .string(login.qr), "loginUrl": .string(login.loginURL), "deadline": .number(now + Double(login.timeout)),
                "agentId": .string(identity.agentID), "clientId": .string(identity.clientID),
            ]
            return .ask(qrPrompt(state, now: now), state: state)
        }
        guard now < deadline else { throw SetupError("The QR code expired. Start again to get a new one.") }
        let identity = MiCloud.Identity(agentID: request.state["agentId"]?.stringValue ?? "", clientID: request.state["clientId"]?.stringValue ?? "")
        let result: MiCloud.PollResult
        do {
            result = try await cloud.pollQR(longPoll, identity: identity, country: country, timeout: dependencies.qrPollTimeout)
        } catch {
            logger.warning("The QR code login failed: \(error)")
            throw SetupError("The QR code expired. Start again to get a new one.")
        }
        switch result {
        case .pending:
            return .ask(qrPrompt(request.state, now: dependencies.now().timeIntervalSince1970), state: request.state)
        case .scanned(let session):
            try? sessionFile.save(session.json)
            logger.info("Signed in to the Xiaomi account with the QR code (\(country))")
            return .done(SetupOutcome(credentials: ["session": session.json], settings: accountSettings(country: country)))
        }
    }

    private func qrPrompt(_ state: JSONValue, now: TimeInterval) -> SetupPrompt {
        let left = Int((state["deadline"]?.doubleValue ?? now) - now)
        // The prompt's link opens the image of the code (15.1); `loginUrl` stays in the state.
        return SetupPrompt(message: "Open the QR code and scan it with the Mi Home app, then confirm on the phone.", url: state["qr"]?.stringValue,
                           waitSeconds: max(left, 1), retryAfter: 2)
    }

    private func passwordStep(_ request: SetupRequest, country: String) async throws -> SetupStep {
        if let jar = request.state["jar"]?.objectValue, let context = request.state["context"]?.stringValue {
            guard let code = request.answer("code") else { return .ask(codePrompt, state: request.state) }
            let identity = MiCloud.Identity(agentID: request.state["agentId"]?.stringValue ?? "", clientID: request.state["clientId"]?.stringValue ?? "")
            let twoFactor = MiCloud.TwoFactor(jar: jar.compactMapValues(\.stringValue), context: context, flag: request.state["flag"]?.intValue ?? 8)
            do {
                let session = try await cloud.verifyTwoFactor(twoFactor, code: code, identity: identity, country: country)
                return passwordDone(session, request: request, country: country)
            } catch MiCloud.VerifyError.wrongCode {
                throw SetupError("Xiaomi did not take that code. Check it and try again.")
            } catch {
                logger.warning("The Xiaomi sign-in failed after the code: \(error)")
                throw SetupError("Xiaomi did not finish the sign-in. Start again.")
            }
        }
        guard let username = request.answer("username") ?? request.state["username"]?.stringValue, let password = request.secret("password") ?? request.state["password"]?.stringValue else {
            return .ask(SetupPrompt(message: "Enter the email, phone number or user id of your Xiaomi account, and its password.", fields: [
                SetupField("username", label: "Email, phone or user id"), SetupField("password", label: "Password", kind: .secret),
            ]), state: request.state)
        }
        let identity = MiCloud.Identity.random()
        do {
            switch try await cloud.passwordLogin(username: username, password: password, identity: identity, country: country) {
            case .signedIn(let session):
                return passwordDone(session, username: username, password: password, country: country)
            case .twoFactor(let twoFactor):
                var state = request.state.objectValue ?? [:]
                state["jar"] = .object(twoFactor.jar.mapValues(JSONValue.string))
                state["context"] = .string(twoFactor.context)
                state["flag"] = .number(Double(twoFactor.flag))
                state["agentId"] = .string(identity.agentID)
                state["clientId"] = .string(identity.clientID)
                state["username"] = .string(username)
                state["password"] = .string(password)
                return .ask(codePrompt, state: .object(state))
            }
        } catch MiCloud.PasswordError.captcha {
            throw SetupError("Xiaomi asks for a captcha. Use the QR code instead.")
        } catch MiCloud.PasswordError.phoneOnly {
            throw SetupError("Xiaomi sends this account's code by text message, which Homeswift cannot ask for. Use the QR code instead.")
        } catch MiCloud.PasswordError.wrongPassword {
            throw SetupError("Xiaomi did not take that email and password.")
        } catch {
            logger.warning("The Xiaomi sign-in failed: \(error)")
            throw SetupError("Xiaomi did not answer the sign-in. Try again in a moment.")
        }
    }

    private var codePrompt: SetupPrompt {
        SetupPrompt(message: "Enter the code Xiaomi sent to your email.", fields: [SetupField("code", label: "Code", kind: .code)])
    }

    private func passwordDone(_ session: MiSession, request: SetupRequest? = nil, username: String? = nil, password: String? = nil, country: String) -> SetupStep {
        let username = username ?? request?.state["username"]?.stringValue ?? ""
        let password = password ?? request?.state["password"]?.stringValue ?? ""
        try? sessionFile.save(session.json)
        logger.info("Signed in to the Xiaomi account with its password (\(country))")
        return .done(SetupOutcome(credentials: ["session": session.json, "username": .string(username), "password": .string(password)],
                                  settings: accountSettings(country: country)))
    }

    /// A device of the account comes with its token; another asks for one, proved with a hello and `miIO.info` (3.4).
    private func authorizeDevice(_ device: DiscoveredDevice, _ request: SetupRequest) async throws -> SetupStep {
        let listed = await accountDevices().first { $0.did == device.deviceID }
        let address = device.address ?? listed?.ip ?? context.accessorySettings(for: device.deviceID).plugin["ip"]?.stringValue
        // The model's spec, fetched now (or refreshed, once a day) while the device is set up (6.1).
        if let model = listed?.model ?? device.model, !MiotSpec.isLegacyVacuum(model: model) { _ = try? await registry.spec(model: model, refresh: true) }
        if let token = listed?.token.flatMap(MiioToken.init(hex:)) {
            var settings: [String: JSONValue] = [:]
            if let address { settings["ip"] = .string(address) }
            if let model = listed?.model ?? device.model { settings["model"] = .string(model) }
            return .done(SetupOutcome(credentials: ["token": .string(token.hex)], settings: settings))
        }
        guard let address else { throw SetupError("Homeswift does not know where the device is. Use Add by address.") }
        guard let text = request.secret("token") else {
            return .ask(SetupPrompt(message: "Enter the device's token: 32 hexadecimal characters.",
                                    fields: [SetupField("token", label: "Token", kind: .secret)]))
        }
        guard let token = MiioToken(hex: text) else { throw SetupError("A token is 32 hexadecimal characters.") }
        let probed = try await probe(address: address, token: token)
        var settings: [String: JSONValue] = ["ip": .string(address)]
        if let model = probed.model ?? device.model { settings["model"] = .string(model) }
        return .done(SetupOutcome(credentials: ["token": .string(token.hex)], settings: settings))
    }

    /// Add by address: the device's address and token; the did of its hello reply is its Device Id.
    private func addByAddress(_ request: SetupRequest) async throws -> SetupStep {
        guard let address = request.answer("ip"), let text = request.secret("token") else {
            return .ask(SetupPrompt(message: "Enter the device's IP address and its token (32 hexadecimal characters).", fields: [
                SetupField("ip", label: "IP address"), SetupField("token", label: "Token", kind: .secret),
            ]))
        }
        guard IPv4Network.parse(address) != nil else { throw SetupError("Enter an IPv4 address such as 192.168.1.50.") }
        guard let token = MiioToken(hex: text) else { throw SetupError("A token is 32 hexadecimal characters.") }
        let probed = try await probe(address: address, token: token)
        var settings: [String: JSONValue] = ["ip": .string(address)]
        if let model = probed.model { settings["model"] = .string(model) }
        logger.info("Added the device at \(address) by its address")
        return .done(SetupOutcome(credentials: ["token": .string(token.hex)], settings: settings, deviceID: probed.did))
    }

    /// A hello and `miIO.info` at the address with the token: the did and the model.
    func probe(address: String, token: MiioToken) async throws -> (did: String, model: String?) {
        let hub = hub ?? MiioHub(network: dependencies.network, logger: logger)
        let client = MiioClient(host: address, token: token, hub: hub, timings: dependencies.timings.miio, logger: logger)
        await client.attach()
        defer {
            Task {
                await client.detach()
                if self.hub == nil { await hub.close() }
            }
        }
        do {
            let info = try await client.info()
            guard let did = await client.deviceID else { throw MiioError.invalidReply }
            return (String(did), info["model"]?.stringValue)
        } catch MiioError.wrongToken {
            throw SetupError("That token does not open the device at \(address).")
        } catch {
            if await client.deviceID != nil { throw SetupError("That token does not open the device at \(address).") }
            throw SetupError("No Xiaomi device answered at \(address).")
        }
    }
}
