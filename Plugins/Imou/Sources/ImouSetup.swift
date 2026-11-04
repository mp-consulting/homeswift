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
// camera keeps its accessory when the cloud lists it later. The App Secret and the safety codes go in the vault; the
// address and options in the camera's Accessory Settings.
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

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard case .device(let device) = request.target else { return try await authorizeAccount(request) }
        return try await authorizeCamera(device, request)
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
                ? "Enter the camera's safety code, printed on its label (or the password you gave it in IMOU Life)."
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
        guard let client = DahuaClient(host: host, port: port, username: username, password: password, transport: dependencies.local) else {
            throw SetupError("That is not an address.")
        }
        var serial: String?
        do {
            serial = try await client.serialNumber()
        } catch DahuaError.wrongPassword {
            throw SetupError("The camera at \(host) refused this safety code.")
        } catch let error as DahuaError {
            logger.info("The camera at \(host) gave no serial number (\(error)): reading its realm")
            if case .unsupported = error {
                // Nothing checked the safety code yet: a snapshot asks for it.
                do { _ = try await client.snapshot(channel: 1) } catch DahuaError.wrongPassword { throw SetupError("The camera at \(host) refused this safety code.") } catch {}
            }
            serial = try? await client.realm().flatMap(DahuaClient.serial(realm:))
        } catch {
            throw SetupError("Cannot reach the camera at \(host): is it on, and on this network? (\(error))")
        }
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

    // MARK: Settings

    /// The block in its canonical shape (`canonical`): its App Secret and its cameras' safety codes kept in the vault once
    /// it is written (`whenSettingsWritten`), where the vault has none.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let setUpHosts = Set(context.allAccessorySettings.compactMap { $0.value.plugin["host"]?.stringValue })
        let (canonical, moved) = Self.canonical(block, setUpHosts: setUpHosts)
        let context = context
        let secret = block["appSecret"] != nil && context.credentials(as: ImouAccountCredentials.self) == nil ? configuration.appSecret : nil
        // The block may name a secret (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        var passwords: [String: String] = [:]
        for deviceID in moved {
            guard context.credentials(for: deviceID, as: ImouCameraCredentials.self)?.password == nil,
                  let password = configuration.devices.first(where: { $0.deviceID == deviceID })?.password else { continue }
            passwords[deviceID] = password
        }
        if secret != nil || !passwords.isEmpty {
            let passwords = passwords
            await context.whenSettingsWritten {
                if let secret { try context.saveCredentials(ImouAccountCredentials(appSecret: secret)) }
                for (deviceID, password) in passwords.sorted(by: { $0.key < $1.key }) {
                    try context.saveCredentials(ImouCameraCredentials(password: password), for: deviceID)
                }
            }
        }
        return canonical
    }

    /// The block without `appSecret`, each `devices` entry with a Device Id moved into `_accessories` (its name as the Name,
    /// its options as they are, what the entry there has winning) without its safety code, and each entry by address whose
    /// camera Setup set up dropped. Answers the Device Ids moved.
    static func canonical(_ block: JSONValue, setUpHosts: Set<String>) -> (block: JSONValue, moved: [String]) {
        guard var fields = block.objectValue else { return (block, []) }
        fields.removeValue(forKey: "appSecret")
        var moved: [String] = []
        if let list = fields["devices"]?.arrayValue {
            var entries = AccessoryEntries(fields)
            var left: [JSONValue] = []
            for item in list {
                let entry = Device(json: item)
                if let deviceID = entry.deviceID {
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
