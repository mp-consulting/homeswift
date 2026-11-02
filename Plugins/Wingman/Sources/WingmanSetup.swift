import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each Wingman is a device whose Device Id is its own id (its Bonjour TXT `id`),
// authorized with the 6-digit code its menu shows (a Device Code) once the person has checked its certificate. The token
// and the pinned certificate go in the vault under its id; its address in its Accessory Settings. The `devices` list
// the plugin's page used to write still works as it was (docs/adr/0001-canonical-accessory-settings.md), and an entry of
// it with an address but no id is a Wingman for Setup to pair: the way to reach one Bonjour does not.
extension WingmanPlugin {
    /// What pairing gives a Wingman, kept in the vault under its id.
    struct Credentials: Codable, Sendable, Equatable {
        var token: String
        /// Wingman's certificate SHA-256, pinned: the token goes to no other.
        var fingerprint: String
    }

    /// The Accessory Settings Setup writes for a Wingman, besides its name.
    struct SetUpSettings: Decodable, Sendable {
        var host: String?
        var port: Int?
    }

    /// The Wingmen to run: those of `devices`, then those set up through Setup (Accessory Settings with credentials in the
    /// vault), an id in both counting once, `devices`' first. The vault's token and certificate win over an entry's.
    nonisolated func configuredDevices() -> [Configuration.Device] {
        var devices: [Configuration.Device] = []
        var seen: Set<String> = []
        for var device in configuration.devices ?? [] where !device.id.isEmpty && seen.insert(device.id).inserted {
            if let saved = context.credentials(for: device.id, as: Credentials.self) {
                device.token = saved.token
                device.fingerprint = saved.fingerprint
            }
            devices.append(device)
        }
        for (id, settings, saved) in context.setUpDevices(credentials: Credentials.self) where !seen.contains(id) {
            let address = settings.decode(SetUpSettings.self)
            devices.append(Configuration.Device(id: id, name: settings.name, host: address?.host, port: address?.port, token: saved.token, fingerprint: saved.fingerprint))
        }
        return devices
    }

    /// A token and a certificate the page used to write into `devices`, moved into the vault the first time the plugin
    /// sees them (an entry without a pinned certificate never had a usable token: it stays as it is).
    static func moveLegacyCredentials(_ configuration: Configuration, _ context: PluginContext) {
        for device in configuration.devices ?? [] where !device.id.isEmpty {
            guard let token = device.token, !token.isEmpty, let fingerprint = device.fingerprint, !fingerprint.isEmpty,
                  context.credentials(for: device.id) == nil else { continue }
            do {
                try context.saveCredentials(Credentials(token: token, fingerprint: HTTPClient.normalizeFingerprint(fingerprint)), for: device.id)
            } catch {
                context.logger.warning("Could not keep a Wingman's token in the vault: \(error)", metadata: ["wingman": "\(device.name ?? device.id)"])
            }
        }
    }

    /// Pairs with the Wingman at `host`, its certificate pinned to `fingerprint`, with the code its menu shows: its id and
    /// the token, for Setup.
    nonisolated func pair(host: String, port: Int, code: String, fingerprint: String) async throws -> (id: String, token: String) {
        let client = WingmanClient(host: host, port: port, token: nil, fingerprint: fingerprint, transports: dependencies.transports)
        let paired = try await client.pair(code: code, name: dependencies.bridgeName)
        var id = paired.wingman
        if id?.isEmpty != false { id = try await client.info().info.id }
        guard let id, !id.isEmpty else { throw WingmanError.invalidResponse("no id") }
        logger.info("Paired with Wingman", metadata: ["host": "\(host)"])
        return (id, paired.token)
    }

    /// The entries of `devices` with an address and no id: Wingmen typed in the settings, for networks Bonjour does not
    /// cross (another network, a container without multicast), by their address.
    nonisolated func typedAddresses() -> [(address: String, name: String?)] {
        (configuration.devices ?? []).compactMap { device in
            guard device.id.isEmpty, let address = Self.address(host: device.host?.trimmingCharacters(in: .whitespaces), port: device.port) else { return nil }
            return (address, device.name)
        }
    }

    /// The Wingmen the plugin runs (set up once they have a token and a pinned certificate), those Bonjour finds that it
    /// does not, and those typed in the settings by their address (`address:<host>`) that are neither: the last two need
    /// their code.
    public func discover() async throws -> [DiscoveredDevice] {
        let configured = configuredDevices()
        let found = isBrowsing ? Array(announced.values) : await browseOnce()
        var devices = configured.map { device in
            let seen = found.first { $0.id == device.id }
            return DiscoveredDevice(
                deviceID: device.id, name: device.name ?? seen?.name ?? device.id, model: "Homeswift Wingman",
                address: Self.address(host: seen?.host ?? device.host, port: seen?.port ?? device.port), authorization: .deviceCode,
                isSetUp: device.token?.isEmpty == false && device.fingerprint?.isEmpty == false)
        }
        let known = Set(configured.map(\.id))
        for wingman in found.sorted(by: { $0.name < $1.name }) where !known.contains(wingman.id) {
            devices.append(DiscoveredDevice(
                deviceID: wingman.id, name: wingman.name, model: "Homeswift Wingman", address: Self.address(host: wingman.host, port: wingman.port), authorization: .deviceCode))
        }
        // At the address Bonjour or Setup knows a Wingman by: that Wingman, set up or found already.
        let addresses = Set((devices.compactMap(\.address) + configured.compactMap { Self.address(host: $0.host, port: $0.port) }).map { $0.lowercased() })
        for (address, name) in typedAddresses() where !addresses.contains(address.lowercased()) {
            devices.append(DiscoveredDevice(deviceID: "address:\(address)", name: name ?? address, model: "Homeswift Wingman", address: address, authorization: .deviceCode))
        }
        return devices
    }

    /// Asks Wingman for its certificate, then for the code its menu shows, which pairs over that certificate pinned.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard let address = device.address, let (host, port) = Self.endpoint(address) else {
            throw SetupError("Wingman has no address: open it on the Mac and find it again")
        }
        // The second step: the code, over the certificate the first step showed.
        if let fingerprint = request.state["fingerprint"]?.stringValue, let code = request.answer("code") {
            let digits = code.filter(\.isNumber)
            guard digits.count == 6 else { throw SetupError("The code has six digits") }
            let paired: (id: String, token: String)
            do {
                paired = try await pair(host: host, port: port, code: digits, fingerprint: fingerprint)
            } catch WingmanError.refused(let status, let message) {
                logger.warning("Pairing with Wingman failed: \(message)", metadata: ["host": "\(host)"])
                throw SetupError(status == 403 ? "Wingman turned the code down: check it and try again" : message)
            } catch {
                throw SetupError("\(error)")
            }
            var settings: [String: JSONValue] = ["host": .string(host), "name": .string(device.name)]
            if port != Self.defaultPort { settings["port"] = .number(Double(port)) }
            let credentials = try JSONValue(encoding: Credentials(token: paired.token, fingerprint: fingerprint))
            return .done(SetupOutcome(credentials: credentials, settings: settings, deviceID: paired.id == device.deviceID ? nil : paired.id))
        }
        // The first step: the certificate this bridge sees, for the person to compare with Wingman's window.
        let client = WingmanClient(host: host, port: port, token: nil, fingerprint: nil, transports: dependencies.transports)
        let seen: String?
        do {
            seen = try await client.info().observedFingerprint
        } catch {
            throw SetupError("Cannot reach Wingman at \(host): is it open on the Mac? (\(error))")
        }
        guard let fingerprint = seen.map(HTTPClient.normalizeFingerprint), fingerprint.count == 64 else {
            throw SetupError("Wingman did not show a certificate: check that it is up to date")
        }
        let message = "In Wingman's menu, choose Pair a Homeswift Bridge. Check that the certificate in Wingman's window (Bridges tab) starts with "
            + "{fingerprint}, then enter the code it shows."
        return .ask(SetupPrompt(message: message, values: ["fingerprint": Self.formatFingerprint(fingerprint)], fields: [SetupField("code", label: "Code", kind: .code)]),
                    state: ["fingerprint": .string(fingerprint)])
    }

    /// `AB:CD:…` for people: the first six bytes, as Wingman's window and the plugin's page show them.
    static func formatFingerprint(_ hex: String) -> String {
        let bytes = Array(hex.uppercased().prefix(12))
        return stride(from: 0, to: bytes.count, by: 2).map { String(bytes[$0..<min($0 + 2, bytes.count)]) }.joined(separator: ":")
    }

    /// `host`, or `host:port` when the port is not Wingman's own (`[v6]:port` for an IPv6 address).
    static func address(host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        guard let port, port != defaultPort else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The host and port of an address `address(host:port:)` wrote.
    static func endpoint(_ address: String) -> (host: String, port: Int)? {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return nil }
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (address, defaultPort)
    }
}

extension WingmanPlugin.Configuration.Device {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, token, fingerprint
    }

    /// An entry without an `id` is one typed by its address, for Setup to pair: its id stays empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "", name: try container.decodeIfPresent(String.self, forKey: .name),
            host: try container.decodeIfPresent(String.self, forKey: .host), port: try container.decodeIfPresent(Int.self, forKey: .port),
            token: try container.decodeIfPresent(String.self, forKey: .token), fingerprint: try container.decodeIfPresent(String.self, forKey: .fingerprint))
    }
}
