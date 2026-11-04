import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"; docs/plugins.md): the instance's account is tado's, signed in with its OAuth device
// authorization (RFC 8628, docs/clean-room/Tado.md section 3.2), a Browser Redirect whose page needs no address pasted
// back: the person opens tado's page, signs in and confirms the code, while the bridge asks the token endpoint every few
// seconds. The refresh token goes in the vault under the username (`TadoAccount`), which the plugin keeps and rotates
// itself. A username with no home in the block brings the account's homes and their zones.
//
// Settings (docs/plugins.md, "Settings"): each zone's options are the Accessory Settings of its accessory (Device Id
// `<home> <zone> <Heater|Boiler|AC>`); `canonicalSettings` moves them out of `homes[].zones[]`, and an inactive zone
// becomes an Excluded one, so Add accessories includes it.
extension TadoPlugin {
    public static let accountAuthorization = AuthorizationMethod.browserRedirect

    /// Every username of the block has a refresh token in the vault (or needs none).
    public func accountAuthorized() async -> Bool? {
        let all = homeSettings().filter { !$0.skipAuth }
        guard !all.isEmpty else { return homeSettings().isEmpty ? false : true }
        for home in all where !(await account(for: home.username).isAuthorized) { return false }
        return true
    }

    /// The accessories the block makes, from the block alone (each request counts against the account's day): every
    /// zone's, Excluded ones included, and the home's others.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        for home in homeSettings() {
            for zone in home.zones {
                let id = HomeSettings.zoneDeviceID(home: home.name, zone: zone.name, type: zone.type)
                devices.append(DiscoveredDevice(deviceID: id, name: id, model: zone.type.rawValue, isSetUp: zone.active && !context.isExcluded(id),
                                                excludedBySettings: !zone.active, kind: zone.type.deviceKind))
            }
            var others: [(String, String)] = home.users.map { ("\(home.name) \($0.name)", "presence") }
            if home.anyone, !home.users.isEmpty { others.append(("\(home.name) Anyone", "presence")) }
            if home.weatherTemperature { others.append(("\(home.name) Weather", "weather")) }
            if home.solarIntensity { others.append(("\(home.name) Solar Intensity", "weather")) }
            if home.centralSwitch { others.append(("\(home.name) Central Switch", "switch")) }
            if home.presenceLock { others.append(("\(home.name) Presence Lock", "switch")) }
            if !home.childLocks.isEmpty { others.append(("\(home.name) Child Lock", "switch")) }
            for (name, kind) in others {
                devices.append(DiscoveredDevice(deviceID: name, name: name, isSetUp: !context.isExcluded(name), excludedBySettings: false, kind: kind))
            }
        }
        return devices
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("tado° zones come with the account: they need no setup of their own")
        // The account's e-mail, the block's first one without a token as the suggestion.
        guard let username = request.state["username"]?.stringValue ?? request.answer("username")?.lowercased() else {
            let all = homeSettings()
            var suggested = all.first?.username
            for home in all where !home.isTokenFile && !home.skipAuth {
                if !(await account(for: home.username).isAuthorized) { suggested = home.username; break }
            }
            return .ask(SetupPrompt(message: "Enter the email of your tado° account.", fields: [SetupField("username", label: "Email", value: suggested)]))
        }
        let counter = account(for: username).counter
        guard let deviceCode = request.state["deviceCode"]?.stringValue else {
            let started: TadoLogin.DeviceAuthorization
            do {
                started = try await TadoLogin.startDeviceAuthorization(http: http, counter: counter)
            } catch {
                throw SetupError("tado° did not start the sign-in: \(error)")
            }
            let deadline = dependencies.now().addingTimeInterval(Double(started.expiresIn)).timeIntervalSince1970
            let state: JSONValue = [
                "username": .string(username), "deviceCode": .string(started.deviceCode), "url": .string(started.url),
                "userCode": .string(started.userCode ?? ""), "interval": .number(Double(started.interval)), "deadline": .number(deadline),
            ]
            return .ask(signInPrompt(state), state: state)
        }
        guard let deadline = request.state["deadline"]?.doubleValue, dependencies.now().timeIntervalSince1970 < deadline else {
            throw SetupError("The tado° sign-in timed out: start again")
        }
        var state = request.state.objectValue ?? [:]
        switch await TadoLogin.poll(deviceCode: deviceCode, http: http, counter: counter) {
        case .pending:
            return .ask(signInPrompt(.object(state)), state: .object(state))
        case .slowDown:
            state["interval"] = .number((request.state["interval"]?.doubleValue ?? 5) + 5)
            return .ask(signInPrompt(.object(state)), state: .object(state))
        case .denied(let reason):
            throw SetupError(reason)
        case .authorized(let tokens):
            return .done(try await signedIn(username: username, tokens: tokens))
        }
    }

    private func signInPrompt(_ state: JSONValue) -> SetupPrompt {
        let interval = Int(state["interval"]?.doubleValue ?? 5)
        let left = Int((state["deadline"]?.doubleValue ?? 0) - dependencies.now().timeIntervalSince1970)
        return SetupPrompt(
            message: "Open the tado° page, sign in as {username} and confirm the code {code}. If the browser is signed in to another tado° account, use a private window.",
            values: ["username": state["username"]?.stringValue ?? "", "code": state["userCode"]?.stringValue ?? ""],
            url: state["url"]?.stringValue, waitSeconds: max(left, interval), retryAfter: interval)
    }

    /// Checks the tokens are the account's (`/me`), keeps them, and adds the account's homes when the block has none
    /// of its own.
    private func signedIn(username: String, tokens: TadoLogin.Tokens) async throws -> SetupOutcome {
        let base = homeSettings().first { $0.username.lowercased() == username }?.apiBase ?? HomeSettings.defaultAPI
        let account = account(for: username)
        let me: JSONValue
        do {
            let answer = try await TadoLogin.identity(accessToken: tokens.accessToken ?? "", apiBase: base, http: http, counter: account.counter)
            if let identity = answer.identity, identity != username {
                throw SetupError("tado° signed in \(identity), not \(username): the browser was probably signed in to another tado° account. Use a private window")
            }
            me = answer.me
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError("Could not check the tado° account: \(error)")
        }
        await account.store(tokens)
        let existing = configuration.homes
        guard !existing.contains(where: { $0["username"]?.stringValue?.lowercased() == username }) else { return SetupOutcome() }
        // The account's homes, each with its zones active (one request a home).
        let api = TadoAPI(base: base, account: account, http: http, counter: account.counter, logger: context.logger, debug: false)
        var added: [JSONValue] = []
        let known = Set(existing.compactMap { $0["name"]?.stringValue })
        for home in me["homes"]?.arrayValue ?? [] {
            guard let id = home["id"]?.saturatingIntValue, let name = home["name"]?.text, !known.contains(name) else { continue }
            let zones = ((try? await api.zones(id))?.arrayValue ?? []).compactMap { zone -> JSONValue? in
                guard let zoneID = zone["id"]?.saturatingIntValue, let zoneName = zone["name"]?.text,
                      let type = zone["type"]?.stringValue.flatMap(ZoneType.init(rawValue:)) else { return nil }
                return ["active": true, "id": .number(Double(zoneID)), "name": .string(zoneName), "type": .string(type.rawValue)]
            }
            added.append(["id": .number(Double(id)), "name": .string(name), "username": .string(username), "zones": .array(zones)])
        }
        return added.isEmpty ? SetupOutcome() : SetupOutcome(settings: ["homes": .array(existing + added)])
    }

    // MARK: Settings

    /// A zone's Device Kind is its type (`heating`, `hotWater`, `airConditioning`); the home's other accessories are
    /// `presence`, `weather` or `switch`.
    public func deviceKind(of deviceID: String) async -> String? {
        // A zone's Device Id ends with its type's word; the others fall back on what discovery said.
        ZoneType.allCases.first { deviceID.hasSuffix(" \($0.suffix)") }?.deviceKind
    }

    /// A zone's keys that are its Accessory Settings.
    static let zoneOptionKeys = [
        "mode", "modeTimer", "easyMode", "minValue", "maxValue", "minStep", "noBattery", "delaySwitch", "autoOffDelay", "openWindowSensor",
        "openWindowSwitch", "separateTemperature", "separateHumidity", "boilerTempSupport", "accTypeBoiler", "acFanSpeed", "acFanModeSwitch", "acDryModeSwitch",
    ]

    /// Also moves a home's `telegram.token` into the vault once the block is written (the running configuration has it
    /// resolved, whether the block holds it, a sealed copy or a reference), and answers the block without it.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block)
        let typed = configuration.homes.lazy.compactMap { $0["telegram"]?["token"]?.text }.last
        let hasToken = (canonical["homes"]?.arrayValue ?? []).contains { $0["telegram"]?["token"] != nil }
        guard hasToken else { return canonical }
        if let typed, telegramFile.load()?["token"] != typed {
            let file = telegramFile
            await context.whenSettingsWritten { try file.save(["token": typed]) }
        } else if typed == nil, telegramFile.load()?["token"] == nil {
            return canonical
        }
        return Self.withoutTelegramToken(canonical)
    }

    /// The block with each home's `telegram.token` taken out.
    static func withoutTelegramToken(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, let homes = fields["homes"]?.arrayValue else { return block }
        fields["homes"] = .array(homes.map { home in
            guard var homeFields = home.objectValue, var telegram = homeFields["telegram"]?.objectValue else { return home }
            telegram.removeValue(forKey: "token")
            homeFields["telegram"] = .object(telegram)
            return .object(homeFields)
        })
        return .object(fields)
    }

    /// The block with each named zone's options in `_accessories` under the zone accessory's Device Id (an entry's own
    /// values winning), an inactive zone Excluded there and active in `zones`; a home's `password` (tado's old sign-in,
    /// read by nothing) dropped. A zone without a name stays as it is.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, let homes = fields["homes"]?.arrayValue else { return block }
        var entries = AccessoryEntries(fields)
        let moved: [JSONValue] = homes.map { home in
            guard var homeFields = home.objectValue else { return home }
            homeFields.removeValue(forKey: "password")
            guard let homeName = home["name"]?.text, let zones = home["zones"]?.arrayValue else { return .object(homeFields) }
            homeFields["zones"] = .array(zones.map { zone in
                guard var zoneFields = zone.objectValue, let settings = ZoneSettings(zone) else { return zone }
                let deviceID = HomeSettings.zoneDeviceID(home: homeName, zone: settings.name, type: settings.type)
                for key in zoneOptionKeys {
                    if let value = zoneFields.removeValue(forKey: key), !value.isNull { entries.setIfAbsent(key, value, on: deviceID) }
                }
                if !settings.active { entries.exclude(deviceID) }
                zoneFields["active"] = true
                return .object(zoneFields)
            })
            return .object(homeFields)
        }
        fields["homes"] = .array(moved)
        entries.write(into: &fields)
        return .object(fields)
    }
}
