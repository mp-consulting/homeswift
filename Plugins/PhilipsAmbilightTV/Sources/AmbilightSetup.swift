import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each TV is a device whose Device Id is its MAC, authorized with the PIN it shows (a
// Device Code). Its keys go in the vault; its address and options in its Accessory Settings. The Homebridge plugin's
// `devices` list still works as it was (docs/adr/0001-canonical-accessory-settings.md).
extension PhilipsAmbilightTVPlugin {
    /// The keys a pairing gives a TV, kept in the vault under its MAC.
    struct TVCredentials: Codable, Sendable {
        var username: String
        var password: String
        var certFingerprint: String?
    }

    /// The TVs to run: those of `devices`, then those set up through Setup (Accessory Settings with keys in the vault),
    /// a MAC in both counting once, `devices`' first.
    func configuredDevices() -> [Configuration.Device] {
        let listed = configuration.devices ?? []
        let listedMACs = Set(listed.compactMap { $0.mac.flatMap(MACAddress.canonical) })
        let setUp = context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { mac, settings -> Configuration.Device? in
            guard !settings.excluded, !listedMACs.contains(mac), let credentials = context.credentials(for: mac, as: TVCredentials.self) else { return nil }
            var fields = settings.plugin
            fields["mac"] = .string(mac)
            fields["username"] = .string(credentials.username)
            fields["password"] = .string(credentials.password)
            if let fingerprint = credentials.certFingerprint { fields["certFingerprint"] = .string(fingerprint) }
            if let name = settings.name { fields["name"] = .string(name) }
            guard let data = try? JSONValue.object(fields).encoded() as Data else { return nil }
            return try? JSONDecoder().decode(Configuration.Device.self, from: data)
        }
        return listed + setUp
    }

    /// The TVs the plugin runs, set up, and those Bonjour finds that it does not, which need their PIN. A TV found on
    /// the network goes by its MAC when this machine's ARP table has it, else by its address until it is paired.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        for device in configuredDevices() {
            guard let mac = device.mac.flatMap(MACAddress.canonical) else { continue }
            found.append(DiscoveredDevice(deviceID: mac, name: device.name ?? mac, model: "Philips TV", address: device.ip, authorization: .deviceCode, isSetUp: true))
        }
        let known = Set(found.compactMap(\.address))
        for tv in await dependencies.discover(logger) where !known.contains(tv.host) {
            let mac = await dependencies.lookUpARP(tv.host).flatMap(MACAddress.canonical)
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
                        state: ["session": try JSONValue(data: JSONEncoder().encode(session))])
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
        let keys = try JSONValue(data: JSONEncoder().encode(TVCredentials(username: credentials.username, password: credentials.password, certFingerprint: credentials.certFingerprint)))
        let client = JointSpaceClient(ip: ip, username: credentials.username, password: credentials.password, certificateFingerprint: credentials.certFingerprint,
                                      transports: dependencies.transports, logger: logger)
        guard let mac = await lookUpMAC(ip: ip, client: client) else {
            return .ask(SetupPrompt(message: "The TV did not give its MAC address. Enter it, from the TV's network settings.",
                                    fields: [SetupField("mac", label: "MAC address")]), state: ["credentials": keys])
        }
        return .done(SetupOutcome(credentials: keys, settings: ["ip": .string(ip), "name": .string(device.name)], deviceID: mac))
    }
}
