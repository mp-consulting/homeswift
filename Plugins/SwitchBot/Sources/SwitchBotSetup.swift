import Foundation
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the account is an API Key, the OpenAPI token and secret from the SwitchBot app, kept in
// the vault once a device list works with them. Every device and IR remote comes with the account: each is a
// Discovered Device by its Device Id (`<deviceId>-<deviceType>`), of its family's Device Kind. A block's
// `credentials` (or 5.x's `openApiToken` and `openApiSecret`) still work, and move into the vault with the next
// settings write (SwitchBotSettings.swift).
//
// A device reached over Bluetooth that needs a secret is an API Key of its own: a Smart Lock its encryption key and key
// id from the SwitchBot app, a Bot with a password set in the app its password (§7.4). Its step asks for them and keeps
// them in the vault under its Device Id, where the Bluetooth layer reads them before the Accessory Settings' copies
// (`encryptionKey`, `encryptionKeyId` or `keyId`, `botPassword`), which go with the step.

/// What Setup keeps for a device on Bluetooth, in the vault under its Device Id.
struct BluetoothSecrets: Codable, Sendable, Equatable {
    enum Kind { case lockKey, botPassword }

    var encryptionKey: String?
    var encryptionKeyId: String?
    /// A Bot's password; nil for a Bot without one.
    var botPassword: String?
}

extension SwitchBotPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    public func accountAuthorized() async -> Bool? { keys != nil }

    /// The account's devices and remotes, from the last list (or a new one on an instance that is not running), a
    /// secondary curtain of a group left out, by the bridge's own rules (`physicalInfo`, `remoteInfo`). One the block
    /// leaves out is `excludedBySettings`.
    public func discover() async throws -> [DiscoveredDevice] {
        var list = latest
        if list == nil, let keys { list = try await makeClient(token: keys.token, secret: keys.secret, attempts: 1).deviceList(attempts: 1) }
        if list == nil, keys == nil { list = localDeviceList() }
        guard let list else { return [] }
        var found: [DiscoveredDevice] = []
        for raw in list.devices {
            guard let info = physicalInfo(raw), let family = Family(deviceType: info.type) else { continue }
            var device = DiscoveredDevice(
                deviceID: info.deviceID, name: info.name, model: info.type, isSetUp: true, excludedBySettings: info.leftOut, kind: family.kind)
            device.isReachable = raw["enableCloudService"]?.boolValue != false
            // On Bluetooth, a lock without its key, or a Bot that refused for its password, Needs Authorization.
            switch bluetoothSecretKind(info) {
            case .lockKey?:
                device.authorization = .apiKey
                device.isSetUp = (try? bluetoothKey(info)) != nil
            case .botPassword?:
                device.authorization = .apiKey
                device.isSetUp = !botPasswordRefused.contains(info.deviceID)
            case nil: break
            }
            found.append(device)
        }
        for raw in list.remotes {
            guard let info = remoteInfo(raw), RemoteFamily(remoteType: info.type) != nil else { continue }
            found.append(DiscoveredDevice(
                deviceID: info.deviceID, name: info.name, model: info.type, isSetUp: true, excludedBySettings: info.leftOut, kind: RemoteFamily.kind))
        }
        return found
    }

    /// The token and secret, checked with a device list, kept in the vault; the block's copies go. A device on Bluetooth:
    /// its key or password (`authorizeBluetooth`).
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        if case .device(let device) = request.target, let kind = device.model.flatMap(BLEModel.init(deviceType:)).flatMap(Self.secretKind) {
            return try authorizeBluetooth(device, kind: kind, request)
        }
        try request.requireAccount("SwitchBot devices come with the account: they need no setup of their own")
        guard let token = request.secret("token")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let secret = request.secret("secret")?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            return .ask(SetupPrompt(
                message: "Enter the OpenAPI token and client secret of your SwitchBot account. In the SwitchBot app: Profile, Preferences, tap App Version ten times, then Developer Options.",
                fields: [SetupField("token", label: "Token", kind: .secret), SetupField("secret", label: "Client secret", kind: .secret)]))
        }
        let list: DeviceList
        do {
            list = try await makeClient(token: token, secret: secret, attempts: 1).deviceList(attempts: 1)
        } catch {
            throw SetupError("SwitchBot refused the token and secret: \(error)")
        }
        logger.info("OpenAPI token checked through Setup", metadata: ["devices": "\(list.devices.count)", "remotes": "\(list.remotes.count)"])
        return .done(try SetupOutcome(
            encoding: AccountKeys(token: token, secret: secret), settings: ["credentials": .null, "openApiToken": .null, "openApiSecret": .null]))
    }

    static func secretKind(_ model: BLEModel) -> BluetoothSecrets.Kind? {
        model.isLock ? .lockKey : model == .bot ? .botPassword : nil
    }

    /// A lock's key id and encryption key (2 and 32 hex digits), or a Bot's password (4 letters or digits, none for a Bot
    /// without one), kept in the vault under the device's Device Id; its Accessory Settings' copies go.
    func authorizeBluetooth(_ device: DiscoveredDevice, kind: BluetoothSecrets.Kind, _ request: SetupRequest) throws -> SetupStep {
        switch kind {
        case .lockKey:
            guard let keyID = request.secret("encryptionKeyId")?.trimmingCharacters(in: .whitespacesAndNewlines), !keyID.isEmpty,
                  let key = request.secret("encryptionKey")?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return .ask(Self.lockKeyPrompt(device))
            }
            guard BLEKey(key: key, id: keyID) != nil else {
                throw SetupError("The key id is 2 hexadecimal digits and the encryption key 32")
            }
            logger.info("Bluetooth key of \(device.name) kept through Setup")
            return .done(try SetupOutcome(
                encoding: BluetoothSecrets(encryptionKey: key.uppercased(), encryptionKeyId: keyID.uppercased()),
                settings: ["encryptionKey": .null, "encryptionKeyId": .null, "keyId": .null]))
        case .botPassword:
            // Asked once: an empty answer is a Bot without a password.
            if request.state["asked"] == nil { return .ask(Self.botPasswordPrompt(device), state: ["asked": true]) }
            let password = request.secret("botPassword")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let password, !password.isEmpty, !validBotPassword(password) {
                throw SetupError("A Bot's password is 4 letters or digits")
            }
            botPasswordRefused.remove(device.deviceID)
            logger.info("Bluetooth password of \(device.name) kept through Setup")
            return .done(try SetupOutcome(
                encoding: BluetoothSecrets(botPassword: password?.isEmpty == false ? password : nil), settings: ["botPassword": .null]))
        }
    }

    static func lockKeyPrompt(_ device: DiscoveredDevice) -> SetupPrompt {
        SetupPrompt(
            message: "Enter the key id and encryption key of {name}, from the SwitchBot app's device information page: the bridge reaches the lock over Bluetooth with them.",
            values: ["name": device.name],
            fields: [SetupField("encryptionKeyId", label: "Key id", kind: .secret), SetupField("encryptionKey", label: "Encryption key", kind: .secret)])
    }

    static func botPasswordPrompt(_ device: DiscoveredDevice) -> SetupPrompt {
        SetupPrompt(
            message: "Enter the password of {name}, set in the SwitchBot app: 4 letters or digits. Leave it empty for a Bot without one.",
            values: ["name": device.name], fields: [SetupField("botPassword", label: "Bot password", kind: .secret, optional: true)])
    }
}
