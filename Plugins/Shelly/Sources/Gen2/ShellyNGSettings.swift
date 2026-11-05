import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `mdns` and `websocket`, as the Homebridge plugin has
// them; each device's Plugin Accessory Settings (`hostname`, `switch:0` … `switch:3`, `cover:0`) sit in `_accessories`
// by its Device Id, its name as the Core `name` and `exclude` as Excluded. A device's password is Setup's, in the vault.
// The Homebridge plugin's `devices` list still loads, read where `_accessories` says nothing, and `canonicalSettings`
// moves it there (the password into the vault once the block is written).
extension ShellyNGPlugin {
    /// The keys of a `devices` entry that move into `_accessories` as they are.
    static func isDeviceKey(_ key: String) -> Bool { key == "hostname" || ComponentKey(key) != nil }

    /// Devices with relays or covers, an I4's inputs, lights, or meters.
    static let relayKind = "relay", inputKind = "input", lightKind = "light", meterKind = "meter"

    /// A device's Homebridge-shaped entry, by its id lowercased.
    func legacyEntry(_ id: String) -> [String: JSONValue]? {
        for item in configuration.devices ?? [] {
            if let fields = item.objectValue, fields["id"]?.stringValue?.lowercased() == id { return fields }
        }
        return nil
    }

    /// A device's options: its Accessory Settings over its `devices` entry.
    func options(for id: String) -> Gen2DeviceOptions {
        var fields = legacyEntry(id) ?? [:]
        for (key, value) in context.accessorySettings(for: id).plugin where Self.isDeviceKey(key) { fields[key] = value }
        return Gen2DeviceOptions(fields)
    }

    /// Every device config.json names.
    func allOptions() -> [String: Gen2DeviceOptions] {
        var ids = Set(context.allAccessorySettings.keys)
        for item in configuration.devices ?? [] { if let id = item["id"]?.stringValue?.lowercased() { ids.insert(id) } }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, options(for: $0)) })
    }

    public func deviceKind(of deviceID: String) async -> String? {
        guard let device = devices[deviceID] else { return nil }
        return Self.kind(of: await device.layout)
    }

    static func kind(of layout: Gen2Layout) -> String {
        for item in layout.items {
            switch item.part {
            case .switch, .cover: return relayKind
            case .buttons, .inputSwitch: return inputKind
            case .light, .rgb, .rgbw, .cct: return lightKind
            case .meter: continue
            }
        }
        return meterKind
    }

    /// The block with each `devices` entry moved into `_accessories` under its id lowercased: `name` as the Name,
    /// `exclude: true` as Excluded, `hostname` and the component objects as they are. Its `password` moves into the vault
    /// once the block is written; an entry whose password the running configuration does not have in plain, or with
    /// another key (`protocol`), stays in `devices`.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var passwords: [String: String] = [:]
        for item in configuration.devices ?? [] {
            if let id = item["id"]?.stringValue?.lowercased(), let password = item["password"]?.stringValue, !password.isEmpty { passwords[id] = password }
        }
        let (canonical, moved) = Self.canonical(block, passwords: passwords)
        let context = context
        for (id, password) in moved where context.credentials(for: id, as: DeviceCredentials.self)?.password != password {
            await context.whenSettingsWritten { try context.saveCredentials(DeviceCredentials(password: password), for: id) }
        }
        return canonical
    }

    /// The canonical block, and the passwords it took out to keep in the vault, by Device Id.
    static func canonical(_ block: JSONValue, passwords: [String: String]) -> (JSONValue, [String: String]) {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return (block, [:]) }
        var entries = AccessoryEntries(fields)
        var moved: Set<String> = []
        var vaulted: [String: String] = [:]
        var left: [JSONValue] = []
        for item in list {
            guard let device = item.objectValue, let id = device["id"]?.stringValue?.lowercased(), !id.isEmpty else { continue }
            let known: Set<String> = ["id", "name", "exclude", "password"]
            let movable = device.keys.allSatisfy { known.contains($0) || isDeviceKey($0) }
            let password = device["password"]?.stringValue
            let passwordKept = password == nil || password?.isEmpty == true || passwords[id] != nil
            guard movable, passwordKept, moved.insert(id).inserted else {
                left.append(item)
                continue
            }
            if let name = device["name"]?.stringValue?.trimmedNonEmpty { entries.setIfAbsent("name", .string(name), on: id) }
            if device["exclude"]?.boolValue == true { entries.exclude(id) }
            for (key, value) in device where isDeviceKey(key) && !value.isNull { entries.setIfAbsent(key, value, on: id) }
            if device["password"] != nil, let password = passwords[id] { vaulted[id] = password }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return (.object(fields), vaulted)
    }

    // MARK: Setup

    /// The devices running, those config.json and the cache name, and those mDNS announces (browsed for a moment on an
    /// instance that is not running), each asked `GET /shelly` whether it wants a password when the plugin does not know.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [String: DiscoveredDevice] = [:]
        for (id, device) in devices {
            let authorized = device.info["auth_en"]?.boolValue == true
            found[id] = DiscoveredDevice(
                deviceID: id, name: await device.baseName, model: device.modelName, address: await device.host,
                authorization: authorized ? .accountLogin : .none, isSetUp: true, kind: Self.kind(of: await device.layout))
        }
        var addresses: [String: String] = [:]
        for (id, cached) in cachedDevices() { addresses[id] = cached.hostname }
        for (id, options) in allOptions() { if let host = options.hostname { addresses[id] = host } }
        for (id, host) in sightings { addresses[id] = host }
        if !browsing {
            for sighting in await dependencies.browse(logger, nil).collect(for: dependencies.discoveryWindow) { addresses[sighting.deviceID] = sighting.host }
        }
        let http = dependencies.http
        let probed = await withTaskGroup(of: (String, String, JSONValue?).self) { group in
            for (id, host) in addresses where found[id] == nil {
                group.addTask { (id, host, await Self.identify(host: host, http: http)) }
            }
            var answers: [(String, String, JSONValue?)] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        for (id, host, shelly) in probed {
            let options = options(for: id)
            let needsPassword = shelly?["auth_en"]?.boolValue == true
            let hasPassword = options.password != nil || !context.haveCredentials([id]).isEmpty
            let model = shelly?["model"]?.stringValue.map { Gen2Models.name(model: $0, app: shelly?["app"]?.stringValue) }
            found[id] = DiscoveredDevice(
                deviceID: id, name: options.name ?? shelly?["name"]?.stringValue?.trimmedNonEmpty ?? model ?? id, model: model, address: host,
                authorization: needsPassword ? .accountLogin : .none, isSetUp: !needsPassword || hasPassword, excludedBySettings: options.exclude)
            found[id]?.isReachable = shelly != nil
        }
        return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// `GET /shelly`, which needs no password: the device's id, model and whether authentication is on.
    static func identify(host: String, http: any HTTPSending) async -> JSONValue? {
        guard let url = URL(string: "http://\(ShellyRPC.bracketed(host))/shelly"),
              let response = try? await http.send(HTTPRequest(url: url, timeout: .seconds(3))), response.isSuccess else { return nil }
        return try? JSONValue(data: response.body)
    }

    // The Shelly Cloud account (an Optional Account, an Account Login): the Shelly app's email and password, which import
    // the energy history the Shelly app keeps for plugs and relays (`ShellyCloud`, the app's own unofficial sign-in and
    // endpoint). The devices never need it: they are reached on the LAN.
    public static let accountAuthorization = AuthorizationMethod.accountLogin
    public static let accountRequirement = AccountRequirement.optional(
        adds: "Imports the energy history the Shelly app keeps for plugs and relays, from Shelly Cloud, as the app gets it (Shelly does not document it).")

    public func accountAuthorized() async -> Bool? {
        context.credentials(as: ShellyCloudCredentials.self) != nil
    }

    /// The cloud account, from the vault; nil without one.
    var cloud: ShellyCloud? {
        context.credentials(as: ShellyCloudCredentials.self).map { ShellyCloud(credentials: $0, http: dependencies.http, logger: logger) }
    }

    /// The account: the Shelly app's email and password, checked by signing in to Shelly Cloud before they are kept.
    private func authorizeCloud(_ request: SetupRequest) async throws -> SetupStep {
        guard let email = request.answer("email"), let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Sign in with your Shelly app account. Homeswift imports the history the app shows for plugs and relays, as the app gets it: Shelly does not document this, and it may stop working.",
                fields: [SetupField("email", label: "Email", value: context.credentials(as: ShellyCloudCredentials.self)?.email),
                         SetupField("password", label: "Password", kind: .secret)]))
        }
        let credentials = ShellyCloudCredentials(email: email, password: password)
        switch await ShellyCloud(credentials: credentials, http: dependencies.http, logger: logger).signIn() {
        case .signedIn: break
        case .refused: throw SetupError("Shelly Cloud refused this email and password")
        case .failed(let reason): throw SetupError("Cannot sign in to Shelly Cloud: \(reason)")
        }
        logger.info("Signed in to Shelly Cloud through Setup")
        return .done(try SetupOutcome(encoding: credentials))
    }

    /// A device whose authentication is on asks for its password (the user is always `admin`), checked with
    /// `Shelly.GetStatus` before it is kept in the vault; the account, its cloud key.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard case .device = request.target else { return try await authorizeCloud(request) }
        let device = try request.device()
        guard device.authorization == .accountLogin else { return .done(SetupOutcome()) }
        guard let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Enter the password of {name}: the one set in its web interface or the Shelly app, under Settings, Authentication.",
                values: ["name": device.name], fields: [SetupField("password", label: "Password", kind: .secret)]))
        }
        guard let host = device.address else { throw SetupError("The device has no address: it is not on the network now") }
        let rpc = ShellyRPC(host: host, clientID: clientID, password: password, settings: rpcSettings, connector: dependencies.connector, logger: logger)
        defer { Task { await rpc.stop() } }
        do {
            _ = try await rpc.call("Shelly.GetStatus")
        } catch RPCError.invalidPassword, RPCError.unauthorized {
            throw SetupError("The password is not right")
        } catch {
            throw SetupError("The device does not answer: \(error)")
        }
        return .done(try SetupOutcome(encoding: DeviceCredentials(password: password)))
    }
}
