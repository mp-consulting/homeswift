import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each controller is a device whose Device Id is its MAC (`001122334455`, as Protect
// gives it and its own accessories carry it: `<MAC>.NVRSystemInfo`, `<MAC>.Security`), authorized with an Account Login:
// a local account of the console. The instance has no account of its own: one block runs several controllers, each with
// its own login, and the Homebridge plugin already treats a controller as a device (`Disable.Device.<NVR MAC>` turns it
// off). The login goes in the vault under the controller's MAC and its address in its Accessory Settings, as Philips
// Ambilight's TVs; the block's `controllers` still work as they were, their passwords sealed in config.json. Cameras,
// lights, sensors, chimes and viewers come with their controller and need nothing more; `Disable.Device.<MAC>` is their
// exclusion of the block's own, and an Excluded device is one more `Disable.Device.<MAC>` before the block's options
// (docs/adr/0001-canonical-accessory-settings.md). UniFi Access does the same in AccessSetup.swift.
extension UniFiProtectPlugin {
    /// A controller's local account, kept in the vault under its MAC.
    struct ControllerLogin: Codable, Sendable, Equatable {
        var username: String
        var password: String
    }

    /// A `Disable.Device.<MAC>` for each Excluded device, to go before the block's options.
    static func exclusions(_ context: PluginContext) -> [String] {
        context.excludedDeviceIDs.filter { !$0.hasPrefix("address:") }.sorted().map { "Disable.Device.\($0)" }
    }

    /// The controllers to run: those of `controllers`, with the login Setup kept for the same address in place of theirs,
    /// then those set up through Setup only (Accessory Settings with an `address`, and a login in the vault), unless
    /// Excluded.
    func controllerEntries() -> [Configuration.Controller] {
        var setUp: [Configuration.Controller] = []
        for (mac, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key }) {
            guard !settings.excluded, let address = settings.plugin["address"]?.stringValue?.trimmingCharacters(in: .whitespaces), !address.isEmpty,
                  let login = context.credentials(for: mac, as: ControllerLogin.self) else { continue }
            var fields = settings.plugin
            fields["username"] = .string(login.username)
            fields["password"] = .string(login.password)
            guard let data = try? JSONValue.object(fields).encoded() as Data, let controller = try? JSONDecoder().decode(Configuration.Controller.self, from: data) else { continue }
            setUp.append(controller)
        }
        func key(_ controller: Configuration.Controller) -> String { controller.address.trimmingCharacters(in: .whitespaces).lowercased() }
        var entries = configuration.controllers.map { entry -> Configuration.Controller in
            guard let kept = setUp.first(where: { key($0) == key(entry) }) else { return entry }
            var entry = entry
            entry.username = kept.username
            entry.password = kept.password
            return entry
        }
        let listed = Set(entries.map(key))
        entries += setUp.filter { !listed.contains(key($0)) }
        return entries
    }

    /// The block's feature options, with the Excluded devices (`exclusions`) or without them.
    func featureOptions(excluding: Bool) -> FeatureOptions {
        FeatureOptions(categories: FeatureOptionCatalog.categories, options: FeatureOptionCatalog.options,
                       configuredOptions: (excluding ? Self.exclusions(context) : []) + configuration.options, dottedIdentifiers: controllerEntries().map(\.address))
    }

    /// The controllers, those running with their devices, and the UniFi consoles on the network that are not set up,
    /// which need a login. An instance that runs none reads each configured controller once.
    public func discover() async throws -> [DiscoveredDevice] {
        let configured = featureOptions(excluding: false)
        var found: [DiscoveredDevice] = []
        var addresses = Set<String>()
        func add(_ bootstrap: JSONValue, address: String, name: String?, connected: Bool, isSetUp: (String, [String]) -> Bool) {
            let mac = bootstrap.at("nvr")?.string("mac")?.nonEmpty
            let scopes = [mac, address].compactMap { $0 }
            found.append(controllerDevice(mac: mac, name: bootstrap.at("nvr")?.string("name") ?? name ?? address, address: address,
                                          isSetUp: connected && mac.map { isSetUp($0, scopes) } != false,
                                          excludedBySettings: mac.map { !configured.test("Device", device: $0, controllers: scopes) } ?? false))
            for category in ProtectNVR.deviceCategories {
                for device in bootstrap.array(category + "s") where device.bool("isAdopted") && !device.bool("isAdoptedByOther") {
                    guard let deviceMAC = device.string("mac")?.nonEmpty else { continue }
                    found.append(DiscoveredDevice(
                        deviceID: deviceMAC, name: device.string("name") ?? device.string("marketName") ?? deviceMAC, model: device.string("marketName"),
                        isSetUp: isSetUp(deviceMAC, scopes), excludedBySettings: !configured.test("Device", device: deviceMAC, controllers: scopes)))
                }
            }
        }
        if !controllers.isEmpty {
            for nvr in controllers {
                let state = await nvr.setupState()
                addresses.insert(state.address.lowercased())
                guard let bootstrap = state.bootstrap else {
                    found.append(controllerDevice(mac: nil, name: state.name, address: state.address, isSetUp: false, excludedBySettings: false))
                    continue
                }
                add(bootstrap, address: state.address, name: state.name, connected: true) { mac, _ in
                    mac == state.mac ? state.enabled : state.published.contains(ProtectPlatform.accessoryID(mac))
                }
            }
        } else {
            let options = featureOptions(excluding: true)
            for entry in controllerEntries() where !entry.address.isEmpty {
                addresses.insert(entry.address.lowercased())
                guard case .read(let bootstrap) = await read(address: entry.address, username: entry.username, password: entry.password, verifyTls: entry.verifyTls == true) else {
                    found.append(controllerDevice(mac: nil, name: entry.name ?? entry.address, address: entry.address, isSetUp: false, excludedBySettings: false))
                    continue
                }
                add(bootstrap, address: entry.address, name: entry.name, connected: true) { mac, scopes in options.test("Device", device: mac, controllers: scopes) }
            }
        }
        let known = Set(found.map(\.deviceID))
        for console in await dependencies.discover(ProtectLog(logger: logger)) where !addresses.contains(console.ip.lowercased()) {
            let deviceID = console.mac.isEmpty ? "address:\(console.ip)" : Self.normalizedMAC(console.mac)
            guard !known.contains(deviceID) else { continue }
            found.append(DiscoveredDevice(deviceID: deviceID, name: console.name.isEmpty ? console.ip : console.name, model: console.modelLong.nonEmpty,
                                          address: console.ip, authorization: .accountLogin))
        }
        return found
    }

    /// `aa:bb:cc:dd:ee:ff` as Protect writes MACs: `AABBCCDDEEFF`.
    static func normalizedMAC(_ mac: String) -> String { mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased() }

    /// A controller as a device: by its MAC once it is known, else by its address.
    private func controllerDevice(mac: String?, name: String, address: String, isSetUp: Bool, excludedBySettings: Bool) -> DiscoveredDevice {
        DiscoveredDevice(deviceID: mac ?? "address:\(address)", name: name, model: "UniFi Protect", address: address, authorization: .accountLogin,
                         isSetUp: isSetUp, excludedBySettings: excludedBySettings)
    }

    /// A controller: the user name and password of a local account of its console, checked with a login and a bootstrap
    /// before they are kept. Its MAC, read from the bootstrap, is its Device Id. Its devices need nothing.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard device.authorization == .accountLogin else { return .done(SetupOutcome()) }
        guard let address = device.address?.nonEmpty else { throw SetupError("The controller has no address: find it again") }
        guard let username = request.answer("username"), let password = request.answers["password"], !password.isEmpty else {
            return .ask(SetupPrompt(message: "Sign in to the UniFi console with a local account that can use UniFi Protect.", fields: [
                SetupField("username", label: "User name"), SetupField("password", label: "Password", kind: .secret),
            ]))
        }
        let bootstrap: JSONValue
        switch await read(address: address, username: username, password: password, verifyTls: false) {
        case .read(let read): bootstrap = read
        case .failed(let message): throw SetupError("The controller at \(address) refused the sign-in: \(message)")
        }
        let mac = bootstrap.at("nvr")?.string("mac")?.nonEmpty ?? device.deviceID
        logger.info("Signed in to the controller at \(address) through Setup.")
        let login = try JSONValue(data: JSONEncoder().encode(ControllerLogin(username: username, password: password)))
        return .done(SetupOutcome(credentials: login, settings: ["address": .string(address)], deviceID: mac))
    }
}

extension ProtectNVR {
    /// What Setup lists of a running controller: its bootstrap once it has one, whether it is on (`Disable.Device`), and
    /// the accessory ids of the devices it published.
    struct SetupState: Sendable {
        var mac: String
        var name: String
        var address: String
        var bootstrap: JSONValue?
        var enabled: Bool
        var published: Set<String>
    }

    func setupState() async -> SetupState {
        SetupState(mac: mac, name: ufp.string("name") ?? config.name ?? config.address, address: config.address, bootstrap: await api.bootstrap,
                   enabled: hasFeature("Device") && hasFeature("Device", device: mac), published: Set(configuredDevices.keys))
    }
}
