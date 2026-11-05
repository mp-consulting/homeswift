import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the instance's account is the Tapo account, an Account Login whose email and password
// every device of the block checks in its handshake; Setup keeps them in the vault and takes the block's `username` and
// `password` out, and signs in to the TP-Link cloud with them (with the code it e-mails a new terminal), which lists the
// account's cameras and reports their motion. A plug or a bulb is one of `devices`, by address (they announce nothing the
// plugin reads), whose Device Id is its host and name run together, the seed of the Homebridge plugin's accessory, and
// which asks nothing more. A camera the cloud lists and the block does not have yet is discovered by its cloud id, which
// becomes its Device Id, at the address the ARP table gives its MAC (the cloud has none, and asking the camera would wake
// it); its Setup asks for the address only when the bridge did not find it, and writes it with the camera's type and cloud
// id into its Accessory Settings.
extension TapoPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// Signed in: an account Setup kept, or the block's `username` and `password`.
    public func accountAuthorized() async -> Bool? { credentials != nil }

    /// The devices of the block, with whether they answer, then the cameras the account's cloud lists that the block does
    /// not have yet.
    public func discover() async throws -> [DiscoveredDevice] {
        let configured = configuredDevices()
        var found: [DiscoveredDevice] = []
        for (deviceID, device) in configured {
            let model = TapoCameraKind(type: device.type)?.model ?? TapoKind(type: device.type).model
            let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? device.trimmedHost ?? deviceID
            var discovered = DiscoveredDevice(deviceID: deviceID, name: name, model: model, address: device.trimmedHost, isSetUp: true)
            if let running = devices[deviceID] { discovered.isReachable = await running.isReachable }
            found.append(discovered)
        }
        return found + (await cloudCameras(besides: configured))
    }

    /// The cameras of the account the cloud lists (docs/clean-room/TapoCloudEvents.md, 4.1) that are none of `configured`:
    /// by cloud id, by the MAC behind a device's host, or by name. Each at the address the ARP table gives its MAC, else the
    /// one the cloud's registry keeps (on any subnet, without waking the camera); when neither places one, the system
    /// resolves every address of the local networks once (`ARPTable.resolveLocalNetworks`) and the table is read again. Only with a session the cloud gave already:
    /// discovery never signs in, which could e-mail a code or count towards the account's lockout.
    func cloudCameras(besides configured: [(deviceID: String, device: Configuration.Device)]) async -> [DiscoveredDevice] {
        guard credentials != nil, await cloud.isSignedIn else { return [] }
        let cloud = cloud
        let timeout = dependencies.cloudListTimeout
        guard let listed = try? await withTimeout(timeout, { try await cloud.cameras() }) else {
            logger.info("The Tapo cloud did not list the account's cameras")
            return []
        }
        var neighbours = await dependencies.neighbours()
        let hosts = Set(configured.compactMap { $0.device.trimmedHost })
        let configuredMACs = Set(neighbours.filter { hosts.contains($0.ip) }.map { TapoCloud.normalizedMAC($0.mac) })
        var known = Set(configured.map(\.deviceID))
        known.formUnion(configured.compactMap { $0.device.cloudId?.trimmingCharacters(in: .whitespaces).nonEmpty })
        let names = Set(configured.compactMap { context.accessorySettings(for: $0.deviceID).name ?? $0.device.trimmedName }.map { $0.lowercased() })
        let cameras = listed.filter { camera in
            !known.contains(camera.deviceID) && !(camera.mac.nonEmpty.map(configuredMACs.contains) ?? false) && !names.contains(camera.alias.lowercased())
        }
        // The address the ARP table gives the camera's MAC; else the one the cloud's registry keeps (TapoCloudEvents.md
        // 4.4.1), asked for each camera at once, unless the table says another device has it now (a DHCP change since the
        // camera reported it); else the local networks resolved once, and the table read again.
        let unplaced = cameras.filter { Self.address(of: $0, in: neighbours) == nil }
        let logger = logger
        let reported = await withTaskGroup(of: (String, String?).self) { group in
            for camera in unplaced {
                group.addTask {
                    do {
                        return (camera.deviceID, try await withTimeout(timeout) { try await cloud.lanAddress(of: camera.deviceID) })
                    } catch {
                        logger.info("The Tapo cloud gave no address for \(camera.alias): \(error)")
                        return (camera.deviceID, nil)
                    }
                }
            }
            return await group.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        }
        if unplaced.contains(where: { !$0.mac.isEmpty && Self.address(of: $0, reported: reported[$0.deviceID], in: neighbours) == nil }) {
            await dependencies.resolveNeighbours(Set(unplaced.map(\.mac).compactMap(MACAddress.canonical)))
            neighbours = await dependencies.neighbours()
        }
        var found: [DiscoveredDevice] = []
        for camera in cameras {
            found.append(DiscoveredDevice(deviceID: camera.deviceID, name: camera.alias.nonEmpty ?? "Tapo \(camera.model)", model: "Tapo \(camera.model)",
                                          address: Self.address(of: camera, reported: reported[camera.deviceID], in: neighbours),
                                          authorization: .accountLogin, kind: "camera"))
        }
        return found
    }

    /// A camera's address: the ARP table's entry for its MAC, else `reported` (the cloud's) unless the table says another
    /// device has it now (a DHCP change since the camera reported it).
    static func address(of camera: TapoCloud.Device, reported: String?, in table: [(ip: String, mac: String)]) -> String? {
        if let entry = address(of: camera, in: table) { return entry }
        guard let reported, !table.contains(where: { $0.ip == reported }) else { return nil }
        return reported
    }

    /// The address the ARP table gives a camera's MAC.
    static func address(of camera: TapoCloud.Device, in table: [(ip: String, mac: String)]) -> String? {
        guard !camera.mac.isEmpty else { return nil }
        return table.first { TapoCloud.normalizedMAC($0.mac) == camera.mac }?.ip
    }

    /// A camera's kind from the model the cloud gives: a C675D has two lenses, the others one.
    static func cameraKind(model: String?) -> TapoCameraKind {
        model?.uppercased().contains("C675") == true ? .dualLens : .single
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account: return try await authorizeAccount(request)
        case .device(let device) where device.authorization == .accountLogin: return try await authorizeCamera(device, request)
        default: return .done(SetupOutcome())
        }
    }

    /// A camera the cloud lists: its address, the one discovery found unless the person gives another, checked against
    /// the camera's MAC when the ARP table knows the address. The camera itself is not asked: that would wake it, and its
    /// stream signs in with the account, which Setup checked already.
    private func authorizeCamera(_ device: DiscoveredDevice, _ request: SetupRequest) async throws -> SetupStep {
        guard credentials != nil else { throw SetupError("Sign in with the Tapo account first.") }
        let given = request.answer("host") ?? (request.isFirst ? device.address : nil)
        guard let host = given?.trimmingCharacters(in: .whitespaces).nonEmpty else {
            return .ask(SetupPrompt(
                message: "The bridge did not find {name} on the network. Enter its IP address, from your router or the Tapo app (the camera's Device Info).",
                values: ["name": device.name], fields: [SetupField("host", label: "Address", value: device.address)]))
        }
        let cloud = cloud
        let listed = (try? await withTimeout(dependencies.cloudListTimeout) { try await cloud.cameras() })?.first { $0.deviceID == device.deviceID }
        if let expected = listed?.mac.nonEmpty, let mac = await dependencies.neighbours().first(where: { $0.ip == host })?.mac,
           TapoCloud.normalizedMAC(mac) != expected {
            throw SetupError("\(host) is another device, not \(device.name): check its address in the Tapo app.")
        }
        let kind = Self.cameraKind(model: listed?.model ?? device.model)
        logger.info("Set up the camera \(device.name) at \(host)")
        return .done(SetupOutcome(settings: [
            "host": .string(host), "type": .string(kind == .dualLens ? "DualLensCamera" : "Camera"), "cloudId": .string(device.deviceID),
            "name": .string(device.name),
        ]))
    }

    /// The account's email and password, checked with the TP-Link cloud (which lists the account's cameras and reports
    /// their motion, docs/clean-room/TapoCloudEvents.md, 3) and with a handshake on the first plug or bulb of `devices`
    /// when there is one: a refusal is an answer to correct; no answer leaves them unchecked. The first time, the cloud
    /// e-mails a code for this new terminal: the email and password wait in the Setup's state (on the bridge) for it.
    /// Without cameras the code may be left out: the account then works for plugs and bulbs alone.
    private func authorizeAccount(_ request: SetupRequest) async throws -> SetupStep {
        if let username = request.state["username"]?.stringValue, let password = request.state["password"]?.stringValue,
           let process = request.state["process"]?.stringValue {
            let credentials = TapoCredentials(username: username, password: password)
            guard let code = request.answer("code")?.trimmingCharacters(in: .whitespaces).nonEmpty else {
                logger.info("Signed in to the Tapo account through Setup, without its cloud")
                return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: ["username": .null, "password": .null]))
            }
            let cloud = Self.makeCloud(context: context, dependencies: dependencies) { credentials }
            do {
                try await cloud.finish(code: code, processID: process)
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
        let cloud = Self.makeCloud(context: context, dependencies: dependencies) { credentials }
        var signedIn = false
        do {
            try await cloud.signIn()
            signedIn = true
        } catch TapoCloudError.mfaRequired(let process) {
            do {
                try await cloud.requestCode()
            } catch {
                logger.info("The Tapo cloud did not send a code: \(error)")
                throw SetupError("The Tapo cloud wants a code but did not send one.")
            }
            return .ask(SetupPrompt(message: "The Tapo cloud e-mailed a code to {email}: enter it so the bridge can list your cameras and follow their motion. Without Tapo cameras, leave it empty.",
                                    values: ["email": username], fields: [SetupField("code", label: "Code", kind: .code, optional: true)]),
                        state: ["username": .string(username), "password": .string(password), "process": .string(process)])
        } catch let error as TapoCloudError where error.isRefusedSignIn {
            logger.info("The Tapo cloud refused the account given through Setup: \(error)")
            throw SetupError("The Tapo cloud refused this email and password.")
        } catch {
            logger.info("Could not sign in to the Tapo cloud: \(error)")
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
        logger.info(signedIn ? "Signed in to the Tapo account and its cloud through Setup" : "Signed in to the Tapo account through Setup")
        return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: ["username": .null, "password": .null]))
    }
}
