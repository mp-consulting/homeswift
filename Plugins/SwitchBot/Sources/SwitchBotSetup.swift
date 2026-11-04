import Foundation
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the account is an API Key, the OpenAPI token and secret from the SwitchBot app, kept in
// the vault once a device list works with them. Every device and IR remote comes with the account: each is a
// Discovered Device by its Device Id (`<deviceId>-<deviceType>`), of its family's Device Kind. A block's
// `credentials` (or 5.x's `openApiToken` and `openApiSecret`) still work, and move into the vault with the next
// settings write (SwitchBotSettings.swift).
extension SwitchBotPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    public func accountAuthorized() async -> Bool? { keys != nil }

    /// The account's devices and remotes, from the last list (or a new one on an instance that is not running), a
    /// secondary curtain of a group left out. One the block's own lists leave out is `excludedBySettings`.
    public func discover() async throws -> [DiscoveredDevice] {
        var list = latest
        if list == nil, let keys { list = try await makeClient(token: keys.token, secret: keys.secret, attempts: 1).deviceList(attempts: 1) }
        guard let list else { return [] }
        var found: [DiscoveredDevice] = []
        for raw in list.devices {
            guard let cloudID = raw["deviceId"]?.stringValue, let type = raw["deviceType"]?.stringValue, let family = Family(deviceType: type) else { continue }
            if ["Curtain", "Curtain3", "Blind Tilt"].contains(type), raw["master"]?.boolValue == false { continue }
            let listed = listedEntry(cloudID, remote: false)
            let deviceID = deviceID(cloudID: cloudID, type: type, listed: listed)
            var device = DiscoveredDevice(
                deviceID: deviceID, name: listed?.string("configDeviceName") ?? raw["deviceName"]?.stringValue ?? cloudID, model: type, isSetUp: true,
                excludedBySettings: leftOutByList(deviceID, listed: listed, remote: false) || listed?.flag("hide_device") == true, kind: family.kind)
            device.isReachable = raw["enableCloudService"]?.boolValue != false
            found.append(device)
        }
        for raw in list.remotes {
            guard let cloudID = raw["deviceId"]?.stringValue, let type = raw["remoteType"]?.stringValue, let family = RemoteFamily(remoteType: type) else { continue }
            let listed = listedEntry(cloudID, remote: true)
            let deviceID = deviceID(cloudID: cloudID, type: type, listed: listed)
            found.append(DiscoveredDevice(
                deviceID: deviceID, name: listed?.string("configDeviceName") ?? raw["deviceName"]?.stringValue ?? cloudID, model: type, isSetUp: true,
                excludedBySettings: leftOutByList(deviceID, listed: listed, remote: true) || listed?.flag("hide_device") == true, kind: family.kind))
        }
        return found
    }

    /// The token and secret, checked with a device list, kept in the vault; the block's copies go.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
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
}
