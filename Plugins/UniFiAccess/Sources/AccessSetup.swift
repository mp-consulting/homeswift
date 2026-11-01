import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each controller is a device whose Device Id is its MAC (`AABBCCDDEEFF`, the id
// feature options give it), authorized with an Account Login: a local account of the console. The instance has no
// account of its own: one block runs several controllers, each with its own login, and the Homebridge plugin already
// treats a controller as a device (`Disable.Device.<controller MAC>` turns it off). The login goes in the vault under
// the controller's MAC and its address in its Accessory Settings, as Philips Ambilight's TVs; the block's `controllers`
// still work as they were, their passwords sealed in config.json. The hubs and readers come with their controller and
// need nothing more; `Disable.Device.<id>` is their exclusion of the block's own, and an Excluded device is one more
// `Disable.Device.<id>` before the block's options (docs/adr/0001-canonical-accessory-settings.md).
extension UniFiAccessPlugin {
    /// A controller's local account, kept in the vault under its MAC.
    struct ControllerLogin: Codable, Sendable, Equatable {
        var username: String
        var password: String
    }

    /// A `Disable.Device.<id>` for each Excluded device, to go before the block's options.
    static func exclusions(_ context: PluginContext) -> [String] {
        context.excludedDeviceIDs.filter(AccessSettings.isAccessIdentifier).sorted().map { "Disable.Device.\($0)" }
    }

    /// The parts a person chose on Add accessories (Accessory Settings' `parts`), as the hub options of that device:
    /// `{ "SideDoor": false }` is `Disable.Hub.SideDoor.<id>`. A device's own option wins over the block's.
    static func partChoices(_ context: PluginContext) -> [String] {
        context.allAccessorySettings.sorted { $0.key < $1.key }.flatMap { deviceID, settings in
            settings.parts.sorted { $0.key < $1.key }.map { "\($0.value ? "Enable" : "Disable").Hub.\($0.key).\(deviceID)" }
        }
    }

    /// The controllers to run: those of `controllers`, with the login Setup kept for the same address in place of theirs,
    /// then those set up through Setup only (Accessory Settings with an `address`, and a login in the vault), unless
    /// Excluded.
    func controllerEntries() -> [Configuration.Controller] {
        var setUp: [(address: String, controller: Configuration.Controller)] = []
        for (_, settings, login) in context.setUpDevices(credentials: ControllerLogin.self) {
            guard let address = settings.plugin["address"]?.stringValue?.trimmingCharacters(in: .whitespaces), !address.isEmpty,
                  let controller = settings.decode(Configuration.Controller.self, adding: ["username": .string(login.username), "password": .string(login.password)]) else { continue }
            setUp.append((address.lowercased(), controller))
        }
        var entries = configuration.controllers.map { entry -> Configuration.Controller in
            guard let address = entry.address?.trimmingCharacters(in: .whitespaces).lowercased(),
                  let kept = setUp.first(where: { $0.address == address })?.controller else { return entry }
            var entry = entry
            entry.username = kept.username
            entry.password = kept.password
            return entry
        }
        let listed = Set(entries.compactMap { $0.address?.trimmingCharacters(in: .whitespaces).lowercased() })
        entries += setUp.filter { !listed.contains($0.address) }.map(\.controller)
        return entries
    }

    /// The controllers, those running with their hubs and readers, and the UniFi consoles on the network that are not set
    /// up, which need a login. An instance that runs none reads each configured controller once.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        var addresses = Set<String>()
        if !controllers.isEmpty {
            for controller in controllers {
                let mac = await controller.id
                let settings = controller.settings
                addresses.insert(settings.address.lowercased())
                found.append(controllerDevice(mac: mac, name: await controller.name, address: settings.address, isSetUp: await controller.connected))
                let hubs = await controller.hubs
                for device in await controller.api.devices ?? [] {
                    let hub = hubs["\(Self.platform):\(device.identifier.uppercased())"]
                    if var device = hubDevice(device, controller: mac, isSetUp: hub != nil) {
                        device.parts = await hub?.parts ?? []
                        found.append(device)
                    }
                }
            }
        } else {
            for entry in controllerEntries() {
                guard let address = entry.address?.trimmingCharacters(in: .whitespaces), AccessSettings.isValidAddress(address) else { continue }
                addresses.insert(address.lowercased())
                guard case .read(let info, let devices) = await read(address: address, username: entry.username ?? "", password: entry.password ?? "",
                                                                     verifyTLS: entry.verifyTls == true) else {
                    found.append(controllerDevice(mac: nil, name: entry.name ?? address, address: address, isSetUp: false))
                    continue
                }
                let mac = info?.hostMAC.map(AccessSettings.normalizeMac)
                found.append(controllerDevice(mac: mac, name: entry.name ?? address, address: address, isSetUp: options.test("Device", device: mac, controller: mac)))
                for device in devices {
                    let enabled = options.test("Device", device: device.identifier, controller: mac)
                    if let device = hubDevice(device, controller: mac, isSetUp: enabled) { found.append(device) }
                }
            }
        }
        let known = Set(found.map(\.deviceID))
        for console in await dependencies.discover(logger) where !addresses.contains(console.ip.lowercased()) {
            let deviceID = console.mac.isEmpty ? "address:\(console.ip)" : AccessSettings.normalizeMac(console.mac)
            guard !known.contains(deviceID) else { continue }
            found.append(DiscoveredDevice(deviceID: deviceID, name: console.name.isEmpty ? console.ip : console.name, model: console.modelLong.isEmpty ? nil : console.modelLong,
                                          address: console.ip, authorization: .accountLogin))
        }
        return found
    }

    /// A controller as a device: by its MAC once it is known, else by its address.
    private func controllerDevice(mac: String?, name: String, address: String, isSetUp: Bool) -> DiscoveredDevice {
        DiscoveredDevice(deviceID: mac ?? "address:\(address)", name: name, model: "UniFi Access", address: address, authorization: .accountLogin,
                         isSetUp: isSetUp, excludedBySettings: mac.map { !configuredOptions.test("Device", device: $0, controller: $0) } ?? false)
    }

    /// A hub or a reader of a controller; nil for what the plugin does not support.
    private func hubDevice(_ device: AccessDevice, controller: String?, isSetUp: Bool) -> DiscoveredDevice? {
        guard device.isManaged, device.isSupported, !device.mac.isEmpty else { return nil }
        let id = device.identifier.uppercased()
        return DiscoveredDevice(deviceID: id, name: device.resolvedName, model: device.displayModel, isSetUp: isSetUp,
                                excludedBySettings: !configuredOptions.test("Device", device: device.identifier, controller: controller))
    }

    /// A controller: the user name and password of a local account of its console, checked with a login and a bootstrap
    /// before they are kept. Its MAC, read from the controller, is its Device Id. Hubs and readers need nothing.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard device.authorization == .accountLogin else { return .done(SetupOutcome()) }
        guard let address = device.address, AccessSettings.isValidAddress(address) else { throw SetupError("The controller has no address: find it again") }
        guard let username = request.answer("username"), let password = request.secret("password") else {
            return .ask(SetupPrompt(message: "Sign in to the UniFi console with a local account that can use UniFi Access.", fields: [
                SetupField("username", label: "User name"), SetupField("password", label: "Password", kind: .secret),
            ]))
        }
        let info: AccessControllerInfo?
        switch await read(address: address, username: username, password: password, verifyTLS: false) {
        case .read(let controller, _): info = controller
        case .failed(let message): throw SetupError("The controller at \(address) refused the sign-in: \(message)")
        }
        let mac = info?.hostMAC.map(AccessSettings.normalizeMac) ?? device.deviceID
        logger.info("Signed in to the controller at \(address) through Setup.")
        let login = try JSONValue(encoding: ControllerLogin(username: username, password: password))
        return .done(SetupOutcome(credentials: login, settings: ["address": .string(address)], deviceID: mac))
    }
}
