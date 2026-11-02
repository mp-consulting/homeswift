import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each TV is a device whose Device Id is its MAC, authorized with the PIN it shows (a
// Device Code). Its keys go in the vault; its address and options in its Accessory Settings. The Homebridge plugin's
// `devices` list still works as it was (docs/adr/0001-canonical-accessory-settings.md), and an entry of it with only an
// address is a TV for Setup to pair: the way to reach one Bonjour does not.
extension PhilipsAmbilightTVPlugin {
    /// The keys a pairing gives a TV, kept in the vault under its MAC.
    struct TVCredentials: Codable, Sendable {
        var username: String
        var password: String
        var certFingerprint: String?
    }

    /// The TVs to run: those of `devices`, then those set up through Setup (Accessory Settings with keys in the vault),
    /// a MAC in both counting once, `devices`' first. An entry of `devices` with an address but no keys (a TV Bonjour does
    /// not reach, typed in the settings to be found by Setup) takes the MAC and the keys of the TV Setup paired there.
    func configuredDevices() -> [Configuration.Device] {
        var setUp = context.setUpDevices(credentials: TVCredentials.self)
        // A TV Setup paired keeps its keys in the vault under its MAC: they take the place of the entry's.
        let listed = (configuration.devices ?? []).map { device -> Configuration.Device in
            var device = device
            if let mac = device.mac.flatMap(MACAddress.canonical), let keys = context.credentials(for: mac, as: TVCredentials.self) {
                device.username = keys.username
                device.password = keys.password
                device.certFingerprint = keys.certFingerprint ?? device.certFingerprint
            } else if !Self.hasKeys(device), device.mac.flatMap(MACAddress.canonical) == nil, let ip = Self.address(device),
                      let index = setUp.firstIndex(where: { $0.settings.plugin["ip"]?.stringValue?.trimmingCharacters(in: .whitespaces) == ip }) {
                let (mac, _, keys) = setUp.remove(at: index)
                device.mac = mac
                device.username = keys.username
                device.password = keys.password
                device.certFingerprint = keys.certFingerprint ?? device.certFingerprint
            }
            return device
        }
        let listedMACs = Set(listed.compactMap { $0.mac.flatMap(MACAddress.canonical) })
        let added = setUp.filter { !listedMACs.contains($0.deviceID) }.compactMap { mac, settings, keys in
            settings.decode(Configuration.Device.self, adding: [
                "mac": .string(mac), "username": .string(keys.username), "password": .string(keys.password),
                "certFingerprint": keys.certFingerprint.map(JSONValue.string) ?? .null,
            ])
        }
        return listed + added
    }

    /// Whether an entry carries the keys a pairing gives.
    static func hasKeys(_ device: Configuration.Device) -> Bool {
        device.username?.isEmpty == false && device.password?.isEmpty == false
    }

    /// An entry's IPv4 address, trimmed; nil when it has none.
    static func address(_ device: Configuration.Device) -> String? {
        device.ip.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { WakeOnLAN.ipv4($0) != nil ? $0 : nil }
    }

    /// The TVs the plugin runs, set up; the entries of `devices` without keys, which need their PIN (a TV typed in the
    /// settings by its address, for networks Bonjour does not cross); and those Bonjour finds that it does not, which
    /// need their PIN too. A TV found on the network goes by its MAC when this machine's ARP table has it, else by its
    /// address until it is paired.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        for device in configuredDevices() {
            let mac = device.mac.flatMap(MACAddress.canonical), ip = Self.address(device)
            let keys = Self.hasKeys(device)
            // Set up: by its MAC. Waiting for its PIN: by its MAC, else its address, and only with an address to pair at.
            guard let deviceID = keys ? mac : ip.flatMap({ _ in mac }) ?? ip.map({ "ip:\($0)" }) else { continue }
            found.append(DiscoveredDevice(deviceID: deviceID, name: device.name ?? deviceID, model: "Philips TV", address: ip ?? device.ip,
                                          authorization: .deviceCode, isSetUp: keys))
        }
        let known = Set(found.compactMap(\.address))
        for tv in await dependencies.discover(logger) where !known.contains(tv.host) {
            let mac = await dependencies.lookUpARP(tv.host).flatMap(MACAddress.canonical)
            guard !found.contains(where: { $0.deviceID == mac }) else { continue }
            found.append(DiscoveredDevice(deviceID: mac ?? "ip:\(tv.host)", name: tv.name, model: "Philips TV", address: tv.host, authorization: .deviceCode))
        }
        return found
    }

    /// Asks the TV for its PIN, then grants it; when neither the TV nor the ARP table gives its MAC, asks for it.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard let ip = device.address, WakeOnLAN.ipv4(ip) != nil else { throw SetupError("The TV has no IPv4 address: switch it on and find it again") }
        // The last step: the MAC the TV did not give, typed.
        if let credentials = request.state["credentials"], let mac = request.answer("mac") {
            guard let canonical = MACAddress.canonical(mac) else { throw SetupError("That is not a MAC address") }
            return .done(SetupOutcome(credentials: credentials, settings: ["ip": .string(ip), "name": .string(device.name)], deviceID: canonical))
        }
        guard let pin = request.answer("pin"), let data = try? request.state["session"]?.encoded(),
              let session = try? JSONDecoder().decode(JointSpacePairing.Session.self, from: data) else {
            let session: JointSpacePairing.Session
            do {
                session = try await JointSpacePairing.request(ip: ip, deviceName: "Homeswift", transport: dependencies.transports.makeTransport(tls: .any))
            } catch {
                throw SetupError("Cannot reach the TV at \(ip): is it on, and on this network? (\(error))")
            }
            logger.info("Pairing started", metadata: ["ip": "\(ip)"])
            return .ask(SetupPrompt(message: "Enter the PIN the TV shows.", fields: [SetupField("pin", label: "PIN", kind: .code)]),
                        state: ["session": try JSONValue(encoding: session)])
        }
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { throw SetupError("The PIN has four digits") }
        let credentials: JointSpacePairing.Credentials
        do {
            let transport = dependencies.transports.makeTransport(tls: session.certificateFingerprint.map { .pinned($0) } ?? .any)
            credentials = try await JointSpacePairing.grant(session, pin: pin, transport: transport)
        } catch JointSpaceError.pairingRefused {
            throw SetupError("The TV turned the PIN down: check it and try again")
        } catch {
            throw SetupError("\(error)")
        }
        logger.info("Paired", metadata: ["ip": "\(ip)"])
        let keys = try JSONValue(encoding: TVCredentials(username: credentials.username, password: credentials.password, certFingerprint: credentials.certFingerprint))
        let client = JointSpaceClient(ip: ip, username: credentials.username, password: credentials.password, certificateFingerprint: credentials.certFingerprint,
                                      transports: dependencies.transports, logger: logger)
        // A TV known by its MAC keeps it (its entry, or its accessory when it is paired again): a TV with two interfaces
        // could answer with the other one, a new accessory.
        var known = MACAddress.canonical(device.deviceID)
        if known == nil { known = await lookUpMAC(ip: ip, client: client) }
        guard let mac = known else {
            return .ask(SetupPrompt(message: "The TV did not give its MAC address. Enter it, from the TV's network settings.",
                                    fields: [SetupField("mac", label: "MAC address")]), state: ["credentials": keys])
        }
        return .done(SetupOutcome(credentials: keys, settings: ["ip": .string(ip), "name": .string(device.name)], deviceID: mac))
    }
}
