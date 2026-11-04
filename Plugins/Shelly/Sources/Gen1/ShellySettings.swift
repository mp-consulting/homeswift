import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `networkInterface`, `requestTimeout` and
// `staleTimeout` (`admin` is read and ignored); each device's Plugin Accessory Settings (`type`, `colorMode`, and
// `accessories`, one entry per relay or channel) sit in `_accessories` by its Device Id, its name as the Core `name` and
// `exclude` as Excluded. Credentials are Setup's, in the vault: a device's, else the account's for every device. The
// Homebridge plugin's `devices` list and its `username`/`password` still load, read where the canonical ones say
// nothing, and `canonicalSettings` moves them.
extension ShellyPlugin {
    /// A device's Homebridge-shaped entry, by its id uppercased and trimmed.
    func legacyEntry(_ id: String) -> [String: JSONValue]? {
        for item in configuration.devices ?? [] {
            if let fields = item.objectValue, Self.normalized(fields["id"]?.stringValue) == id { return fields }
        }
        return nil
    }

    static func normalized(_ id: String?) -> String? { id?.trimmingCharacters(in: .whitespaces).uppercased().nonEmpty }

    /// The keys of a device's options, in `devices` and in `_accessories`.
    static let deviceKeys = ["type", "colorMode", "accessories"]

    /// A device's options: its Accessory Settings over its `devices` entry.
    func deviceOptions(_ id: String) -> [String: JSONValue] {
        var fields = legacyEntry(id) ?? [:]
        for (key, value) in context.accessorySettings(for: id).plugin where Self.deviceKeys.contains(key) { fields[key] = value }
        return fields
    }

    /// Accessory `index`'s options: the device's, with `accessories[index]` laid over them.
    func accessoryOptions(_ id: String, index: Int) -> Gen1AccessoryOptions {
        var fields = deviceOptions(id)
        let own = fields.removeValue(forKey: "accessories")?.arrayValue
        if let entry = own?[safe: index]?.objectValue { fields.merge(entry) { $1 } }
        return Gen1AccessoryOptions(fields)
    }

    /// Excluded in its Accessory Settings, or `exclude: true` in `devices`.
    func isLeftOut(_ id: String) -> Bool {
        context.isExcluded(id) || legacyEntry(id)?["exclude"]?.boolValue == true
    }

    /// The device's own pair when both are set, else what Setup kept for it, else the block's, else the account's.
    func credentials(for id: String) -> (username: String, password: String)? {
        func pair(_ username: String?, _ password: String?) -> (String, String)? {
            guard let username = username?.nonEmpty, let password, !password.isEmpty else { return nil }
            return (username, password)
        }
        let entry = legacyEntry(id)
        if let own = pair(entry?["username"]?.stringValue, entry?["password"]?.stringValue) { return own }
        if let kept = context.credentials(for: id, as: DeviceCredentials.self), let own = pair(kept.username ?? "admin", kept.password) { return own }
        if let global = pair(configuration.username, configuration.password) { return global }
        if let account = context.credentials(as: DeviceCredentials.self) { return pair(account.username ?? "admin", account.password) }
        return nil
    }

    public func deviceKind(of deviceID: String) async -> String? {
        guard let device = devices.values.first(where: { $0.deviceID == deviceID }) else { return nil }
        return Self.kind(of: device.model)
    }

    /// `relay` (relays and rollers), `light`, `colorLight`, `button` or `sensor`.
    static func kind(of model: Gen1Model) -> String {
        switch model.family {
        case .relays, .relaysOrRoller: "relay"
        case .whiteLight, .colorTemperatureLight: "light"
        case .colorLight, .colorOrWhiteLights: "colorLight"
        case .buttons: "button"
        case .sensor: "sensor"
        }
    }

    /// The block with each `devices` entry moved into `_accessories` under its id uppercased: `name` as the Name,
    /// `exclude: true` as Excluded, `type`, `colorMode` and `accessories` as they are. A device's `username` and
    /// `password`, and the block's, move into the vault once the block is written. An entry whose password the running
    /// configuration does not have in plain stays in `devices`, and so do the block's.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var plain: [String: DeviceCredentials] = [:]
        for item in configuration.devices ?? [] {
            guard let id = Self.normalized(item["id"]?.stringValue), let password = item["password"]?.stringValue, !password.isEmpty else { continue }
            plain[id] = DeviceCredentials(username: item["username"]?.stringValue?.nonEmpty ?? "admin", password: password)
        }
        var account: DeviceCredentials?
        if let username = configuration.username?.nonEmpty, let password = configuration.password, !password.isEmpty {
            account = DeviceCredentials(username: username, password: password)
        }
        let (canonical, moved, accountMoved) = Self.canonical(block, plain: plain, account: account)
        let context = context
        for (id, credentials) in moved {
            await context.whenSettingsWritten { try context.saveCredentials(credentials, for: id) }
        }
        if accountMoved, let account { await context.whenSettingsWritten { try context.saveCredentials(account) } }
        return canonical
    }

    static func canonical(_ block: JSONValue, plain: [String: DeviceCredentials], account: DeviceCredentials?)
        -> (JSONValue, [String: DeviceCredentials], Bool) {
        guard var fields = block.objectValue else { return (block, [:], false) }
        var moved: [String: DeviceCredentials] = [:]
        var accountMoved = false
        if fields["password"] != nil || fields["username"] != nil, account != nil || fields["password"] == nil {
            fields.removeValue(forKey: "username")
            fields.removeValue(forKey: "password")
            accountMoved = account != nil
        }
        guard let list = fields["devices"]?.arrayValue else { return (.object(fields), moved, accountMoved) }
        var entries = AccessoryEntries(fields)
        var seen: Set<String> = []
        var left: [JSONValue] = []
        for item in list {
            guard let device = item.objectValue, let id = normalized(device["id"]?.stringValue) else { continue }
            let known: Set<String> = ["id", "name", "exclude", "username", "password"]
            let movable = device.keys.allSatisfy { known.contains($0) || deviceKeys.contains($0) }
            let hasPassword = device["password"]?.stringValue?.isEmpty == false
            guard movable, !hasPassword || plain[id] != nil, seen.insert(id).inserted else {
                left.append(item)
                continue
            }
            if let name = device["name"]?.stringValue?.nonEmpty { entries.setIfAbsent("name", .string(name), on: id) }
            if device["exclude"]?.boolValue == true { entries.exclude(id) }
            for key in deviceKeys { if let value = device[key], !value.isNull { entries.setIfAbsent(key, value, on: id) } }
            if hasPassword, let credentials = plain[id] { moved[id] = credentials }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return (.object(fields), moved, accountMoved)
    }

    // MARK: Setup

    /// The devices heard or remembered (on an instance that is not running, those heard over CoIoT for a moment), each
    /// asked `GET /shelly` whether its login is on.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [String: (model: Gen1Model, host: String)] = [:]
        for device in devices.values { found[device.deviceID] = (device.model, await device.host) }
        for stored in (context.jsonFile("shelly-devices.json", as: [String: StoredDevice].self).load() ?? [:]).values {
            if let model = Gen1Models.all[stored.type], found[stored.id] == nil { found[stored.id] = (model, stored.host) }
        }
        if !listening, let socket = try? await dependencies.listen(nil) {
            try? await socket.send(Data(CoIoTStatus.request()), to: CoIoTStatus.multicastGroup, port: CoIoTStatus.port)
            let heard = await socket.datagrams.collect(for: dependencies.discoveryWindow)
            await socket.close()
            for (data, address) in heard {
                if let status = CoIoTStatus(datagram: data), let model = Gen1Models.all[status.model], found[status.deviceID] == nil {
                    found[status.deviceID] = (model, address)
                }
            }
        }
        let http = dependencies.http
        let answers = await withTaskGroup(of: (String, JSONValue?).self) { group in
            for (id, item) in found { group.addTask { (id, await ShellyNGPlugin.identify(host: item.host, http: http)) } }
            var answers: [String: JSONValue?] = [:]
            for await (id, answer) in group { answers[id] = answer }
            return answers
        }
        var list: [DiscoveredDevice] = []
        for (id, item) in found {
            let shelly = answers[id] ?? nil
            let needsLogin = shelly?["auth"]?.boolValue == true
            let name = context.accessorySettings(for: id).name ?? legacyEntry(id)?["name"]?.stringValue?.nonEmpty ?? Gen1Builder.seed(item.model, deviceID: id, index: 0, count: 1)
            var device = DiscoveredDevice(
                deviceID: id, name: name, model: item.model.name, address: item.host, authorization: needsLogin ? .accountLogin : .none,
                isSetUp: !needsLogin || credentials(for: id) != nil, excludedBySettings: legacyEntry(id)?["exclude"]?.boolValue == true,
                kind: Self.kind(of: item.model))
            device.isReachable = shelly != nil
            list.append(device)
        }
        return list.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// A device whose login is on asks for its user name and password, checked with `GET /settings` before they are kept.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard device.authorization == .accountLogin else { return .done(SetupOutcome()) }
        guard let password = request.secret("password") else {
            return .ask(SetupPrompt(
                message: "Enter the user name and password of {name}'s login, set in its web interface under Internet & Security, Restricted login.",
                values: ["name": device.name],
                fields: [SetupField("username", label: "User name", value: "admin"), SetupField("password", label: "Password", kind: .secret)]))
        }
        let username = request.answer("username") ?? "admin"
        guard let host = device.address, let model = Gen1Models.all.values.first(where: { $0.name == device.model }) else {
            throw SetupError("The device has no address: it is not on the network now")
        }
        let probe = Gen1Device(model: model, deviceID: device.deviceID, host: host, mode: nil, http: dependencies.http,
                               credentials: (username, password), timeout: requestTimeout, logger: logger)
        do {
            try await probe.request("settings")
        } catch Gen1Error.wrongCredentials {
            throw SetupError("The user name or password is not right")
        } catch {
            throw SetupError("The device does not answer: \(error)")
        }
        return .done(try SetupOutcome(encoding: DeviceCredentials(username: username, password: password)))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
