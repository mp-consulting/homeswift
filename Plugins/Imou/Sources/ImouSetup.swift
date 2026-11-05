import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"; docs/clean-room/Imou.md, section 2): the instance's account is an IMOU developer app, an API
// Key (its App Id and App Secret, and its region), optional: it lists the account's cameras and adds what only the cloud
// does. Each camera is a device whose Device Id is its serial (the cloud's `deviceId`), authorized with its safety code (a
// Device Code) for the local path, or with nothing for the cloud alone. A camera the cloud does not list is one of the
// block's `devices` by address: its Setup asks the safety code and reads the serial from the camera
// (`magicBox.cgi?action=getSerialNo`, else its Digest realm `Login to <serial>`), which becomes its Device Id, so the same
// camera keeps its accessory when the cloud lists it later. A camera neither lists is added by address (GLOSSARY.md, "Add
// by address"): its address, then its safety code, read the same way. The App Secret and the safety codes go in the vault;
// the address and options in the camera's Accessory Settings.
extension ImouPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey
    public static let accountRequirement = AccountRequirement.optional(adds: "Lists the cameras of your IMOU account, and adds privacy mode, the siren and the spotlight.")

    public func accountAuthorized() async -> Bool? {
        configuration.appID != nil && appSecret != nil
    }

    public func deviceKind(of deviceID: String) async -> String? { Self.cameraKind }

    /// The cameras the account lists (from the running instance's last listing, else one asked now), those set up on the LAN
    /// alone, and the block's `devices` by address still to set up.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        var devices = Array(cloudDevices.values)
        if devices.isEmpty, let cloud = cloud ?? makeCloud() {
            devices = ((try? await cloud.listDevices()) ?? []).filter { $0.productID == nil }
        }
        let setUp = Set(context.haveCredentials(devices.map(\.deviceID) + localCameras().map(\.deviceID)).compactMap { $0 })
        var hosts = Set<String>()
        for device in devices.sorted(by: { $0.deviceID < $1.deviceID }) {
            let settings = cameraSettings(deviceID: device.deviceID)
            var discovered = DiscoveredDevice(
                deviceID: device.deviceID, name: context.accessorySettings(for: device.deviceID).name ?? device.name, model: device.model, address: settings.host,
                authorization: .deviceCode, isSetUp: setUp.contains(device.deviceID), kind: Self.cameraKind)
            if let camera = cameras[Self.accessoryID(deviceID: device.deviceID, channel: device.cameraChannels[0].id)] {
                discovered.isReachable = await camera.online != .offline
            }
            if let host = settings.host { hosts.insert(host) }
            found.append(discovered)
        }
        for (deviceID, name) in localCameras() where !found.contains(where: { $0.deviceID == deviceID }) {
            let host = cameraSettings(deviceID: deviceID).host
            if let host { hosts.insert(host) }
            var discovered = DiscoveredDevice(deviceID: deviceID, name: context.accessorySettings(for: deviceID).name ?? name ?? "IMOU \(deviceID)", address: host,
                                              authorization: .deviceCode, isSetUp: true, kind: Self.cameraKind)
            if let camera = cameras[Self.accessoryID(deviceID: deviceID, channel: "0")] { discovered.isReachable = await camera.localEventsUp != false }
            found.append(discovered)
        }
        for entry in configuration.devices where entry.deviceID == nil {
            guard let host = entry.host, hosts.insert(host).inserted else { continue }
            found.append(DiscoveredDevice(deviceID: "ip:\(host)", name: entry.name ?? host, address: host, authorization: .deviceCode, kind: Self.cameraKind))
        }
        return found
    }

    /// A camera on the LAN alone that neither the account nor `devices` lists is added by its address (Add by address).
    public static let addsDevicesByAddress = true

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account: return try await authorizeAccount(request)
        case .device(let device): return try await authorizeCamera(device, request)
        case .newDevice: return try await authorizeNewCamera(request)
        }
    }

    /// Add by address: the camera's address, checked for an answer, then its safety code, checked as a camera's by
    /// address is; its serial is its Device Id, its safety code its credentials.
    private func authorizeNewCamera(_ request: SetupRequest) async throws -> SetupStep {
        let port = CameraSettings(fields: [:], password: nil, defaults: configuration).httpPort
        guard let host = request.state["host"]?.stringValue ?? request.answer("host") else {
            return .ask(SetupPrompt(
                message: "Enter the camera's address: its IP address or host name on your network, from your router or IMOU Life.",
                fields: [SetupField("host", label: "Address")]))
        }
        let codePrompt = SetupPrompt(
            message: Self.safetyCodeMessage,
            fields: [SetupField("password", label: "Safety code", kind: .secret), SetupField("username", label: "User name", optional: true, value: "admin")])
        guard request.state["host"] == nil else {
            guard let password = request.secret("password") else { return .ask(codePrompt, state: ["host": .string(host)]) }
            let username = request.answer("username") ?? "admin"
            let client = try dahuaClient(host: host, port: port, username: username, password: password)
            guard let serial = try await readSerial(client, host: host) else { throw SetupError("The camera at \(host) did not give its serial number.") }
            logger.info("Added the camera \(serial) at \(host) by its address")
            return .done(try SetupOutcome(encoding: ImouCameraCredentials(password: password),
                                          settings: ["host": .string(host), "username": .string(username)], deviceID: serial))
        }
        // Asked without credentials, a camera answers with its challenge: something is there before the code is asked.
        let client = try dahuaClient(host: host, port: port, username: "admin", password: "")
        do {
            _ = try await client.realm()
        } catch {
            logger.info("No camera answered at \(host): \(error)")
            throw SetupError("No camera answered at \(host): check the address, and that the camera is on and on this network.")
        }
        return .ask(codePrompt, state: ["host": .string(host)])
    }

    /// The developer app's App Id, App Secret and region, checked by fetching a token.
    private func authorizeAccount(_ request: SetupRequest) async throws -> SetupStep {
        let regions = ImouRegion.allCases.map(\.rawValue)
        guard let appID = request.answer("appId"), let secret = request.secret("appSecret"), let region = request.choice("region", among: regions).flatMap(ImouRegion.init(rawValue:)) else {
            return .ask(SetupPrompt(
                message: "Enter the App Id and App Secret of your app on the IMOU Open Platform (open.imoulife.com, My App, App Information), and the region it was made in.",
                fields: [
                    SetupField("appId", label: "App Id", value: configuration.appID),
                    SetupField("appSecret", label: "App Secret", kind: .secret),
                    .choice("region", label: "Region", options: ImouRegion.allCases.map { SetupOption($0.rawValue, label: $0.label) },
                            value: configuration.cloudRegion.rawValue),
                ]))
        }
        let cloud = makeCloud(appID: appID, appSecret: secret, region: region)
        do {
            try await cloud.verify()
        } catch let error as ImouError where error.isAuthRefused {
            logger.info("The IMOU cloud refused the App Id and App Secret given through Setup")
            throw SetupError("The IMOU cloud refused this App Id and App Secret: check them, the region, and this computer's clock.")
        } catch {
            throw SetupError("Cannot reach the IMOU cloud: \(error)")
        }
        logger.info("Signed in to the IMOU cloud through Setup")
        return .done(try SetupOutcome(encoding: ImouAccountCredentials(appSecret: secret),
                                      settings: ["appId": .string(appID), "region": .string(region.rawValue), "appSecret": .null]))
    }

    /// A camera's address and safety code, checked on the camera: it must take the code and, for a camera of the account,
    /// be that camera. A camera of the account may go without an address: it then runs on the cloud alone.
    private func authorizeCamera(_ device: DiscoveredDevice, _ request: SetupRequest) async throws -> SetupStep {
        let byAddress = device.deviceID.hasPrefix("ip:")
        // A camera by address may be a `devices` entry's: its options (its HTTP port among them) go with it.
        let entry = byAddress ? configuration.devices.first { $0.deviceID == nil && $0.host != nil && $0.host == device.address } : nil
        let current = byAddress
            ? entry.map { CameraSettings(fields: $0.options, password: nil, defaults: configuration) }
            : cameraSettings(deviceID: device.deviceID)
        let prompt = SetupPrompt(
            message: byAddress
                ? Self.safetyCodeMessage
                : "Enter the camera's address on your network and its safety code, printed on its label, for local video and events. Leave them empty to use the IMOU cloud alone.",
            fields: [
                SetupField("host", label: "Address", optional: !byAddress, value: device.address ?? current?.host),
                SetupField("password", label: "Safety code", kind: .secret, optional: !byAddress),
                SetupField("username", label: "User name", optional: true, value: current?.username ?? "admin"),
            ])
        if request.isFirst { return .ask(prompt) }
        guard let host = request.answer("host") ?? (byAddress ? device.address : nil) else {
            if byAddress { return .ask(prompt) }
            return .done(try SetupOutcome(encoding: ImouCameraCredentials(password: nil), settings: ["host": .null]))
        }
        guard let password = request.secret("password") else { throw SetupError("Enter the camera's safety code.") }
        let username = request.answer("username") ?? "admin"
        let port = current?.httpPort ?? 80
        let client = try dahuaClient(host: host, port: port, username: username, password: password)
        let serial = try await readSerial(client, host: host)
        if byAddress {
            guard let serial else { throw SetupError("The camera at \(host) did not give its serial number.") }
            logger.info("Set up the camera \(serial) at \(host)")
            return .done(try SetupOutcome(encoding: ImouCameraCredentials(password: password),
                                          settings: (entry?.options ?? [:]).merging(["host": .string(host), "username": .string(username), "name": .string(device.name)]) { $1 },
                                          deviceID: serial))
        }
        if let serial, serial.caseInsensitiveCompare(device.deviceID) != .orderedSame {
            throw SetupError("The camera at \(host) is \(serial), not \(device.deviceID).")
        }
        logger.info("Set up \(device.deviceID) on the local network at \(host)")
        return .done(try SetupOutcome(encoding: ImouCameraCredentials(password: password), settings: ["host": .string(host), "username": .string(username)]))
    }

    static let safetyCodeMessage = "Enter the camera's safety code, printed on its label (or the password you gave it in IMOU Life)."

    /// The CGI client of the camera at `host`.
    private func dahuaClient(host: String, port: Int, username: String, password: String) throws -> DahuaClient {
        guard let client = DahuaClient(host: host, port: port, username: username, password: password, transport: dependencies.local) else {
            throw SetupError("That is not an address.")
        }
        return client
    }

    /// The camera's serial, checking its safety code: `getSerialNo`, else its Digest realm (a snapshot checks the code of
    /// a camera without `getSerialNo`); nil when it gives none. Throws `SetupError` for a refused code or no answer.
    private func readSerial(_ client: DahuaClient, host: String) async throws -> String? {
        do {
            return try await client.serialNumber()
        } catch DahuaError.wrongPassword {
            throw Self.refused(host)
        } catch let error as DahuaError {
            logger.info("The camera at \(host) gave no serial number (\(error)): reading its realm")
            // Nothing checked the safety code yet: a snapshot asks for it.
            do { _ = try await client.snapshot(channel: 1) } catch DahuaError.wrongPassword { throw Self.refused(host) } catch {}
            return try? await client.realm().flatMap(DahuaClient.serial(realm:))
        } catch {
            throw SetupError("Cannot reach the camera at \(host): is it on, and on this network? (\(error))")
        }
    }

    private static func refused(_ host: String) -> SetupError { SetupError("The camera at \(host) refused this safety code.") }

    // MARK: Settings

    /// The block in its canonical shape (`canonical`): its App Secret and its cameras' safety codes kept in the vault once
    /// it is written (`whenSettingsWritten`). A value written in the block (a new one, or a changed one) is the one kept;
    /// one the block only names (a `vault:` reference, a sealed copy) comes resolved from the running configuration. A
    /// secret with nowhere to go yet stays in the block.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let context = context
        let setUpHosts = Set(context.allAccessorySettings.compactMap { $0.value.plugin["host"]?.stringValue })
        let storedSecret = context.credentials(as: ImouAccountCredentials.self)?.appSecret
        var secret: String?
        if block["appSecret"] != nil {
            if let written = Self.writtenSecret(block["appSecret"]), written != storedSecret {
                secret = written
            } else if storedSecret == nil {
                secret = configuration.appSecret
            }
        }
        var passwords: [String: String] = [:]
        var unsaved: Set<String> = []
        for item in block["devices"]?.arrayValue ?? [] {
            let entry = Device(json: item)
            guard let deviceID = entry.deviceID, entry.password != nil else { continue }
            let stored = context.credentials(for: deviceID, as: ImouCameraCredentials.self)?.password
            if let written = Self.writtenSecret(item["password"]) ?? Self.writtenSecret(item["safetyCode"]), written != stored {
                passwords[deviceID] = written
            } else if stored == nil {
                if let resolved = configuration.devices.first(where: { $0.deviceID == deviceID })?.password {
                    passwords[deviceID] = resolved
                } else {
                    unsaved.insert(deviceID)
                }
            }
        }
        let keepSecret = block["appSecret"] != nil && secret == nil && storedSecret == nil
        let (canonical, _) = Self.canonical(block, setUpHosts: setUpHosts, keepingSecret: keepSecret, keepingEntries: unsaved)
        if secret != nil || !passwords.isEmpty {
            let passwords = passwords, secret = secret
            await context.whenSettingsWritten {
                if let secret { try context.saveCredentials(ImouAccountCredentials(appSecret: secret)) }
                for (deviceID, password) in passwords.sorted(by: { $0.key < $1.key }) {
                    try context.saveCredentials(ImouCameraCredentials(password: password), for: deviceID)
                }
            }
        }
        return canonical
    }

    /// A secret written out in the block: not a reference to one, nor a sealed copy.
    static func writtenSecret(_ value: JSONValue?) -> String? {
        guard let text = value.text, SecretReference(text) == nil, !SecretBox.isSealed(text) else { return nil }
        return text
    }

    /// The block without `appSecret`, each `devices` entry with a Device Id moved into `_accessories` (its name as the Name,
    /// its options as they are, what the entry there has winning) without its safety code, and each entry by address whose
    /// camera Setup set up dropped. Answers the Device Ids moved. `keepingSecret` and `keepingEntries` (by Device Id) leave
    /// the App Secret and those entries as they are: their secret has nowhere else to go yet.
    static func canonical(_ block: JSONValue, setUpHosts: Set<String>, keepingSecret: Bool = false,
                          keepingEntries: Set<String> = []) -> (block: JSONValue, moved: [String]) {
        guard var fields = block.objectValue else { return (block, []) }
        if !keepingSecret { fields.removeValue(forKey: "appSecret") }
        var moved: [String] = []
        if let list = fields["devices"]?.arrayValue {
            var entries = AccessoryEntries(fields)
            var left: [JSONValue] = []
            for item in list {
                let entry = Device(json: item)
                if let deviceID = entry.deviceID, keepingEntries.contains(deviceID) {
                    left.append(item)
                } else if let deviceID = entry.deviceID {
                    if let name = entry.name { entries.setIfAbsent("name", .string(name), on: deviceID) }
                    if let host = entry.host { entries.setIfAbsent("host", .string(host), on: deviceID) }
                    for (key, value) in entry.options.sorted(by: { $0.key < $1.key }) where !value.isNull { entries.setIfAbsent(key, value, on: deviceID) }
                    moved.append(deviceID)
                } else if let host = entry.host, setUpHosts.contains(host) {
                    continue
                } else {
                    left.append(item)
                }
            }
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
            entries.write(into: &fields)
        }
        return (.object(fields), moved)
    }
}
