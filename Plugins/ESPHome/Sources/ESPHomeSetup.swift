import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

// Setup (GLOSSARY.md, "Setup"): each ESPHome device is a device whose Device Id is its MAC, found over mDNS
// (`_esphomelib._tcp`) or at an address of `devices`. One whose API is encrypted (its TXT `api_encryption`) asks for its
// encryption key; one on firmware before 2026.1 with an API password asks for that; others ask nothing. Each answer is
// checked by connecting to the device, and what works goes in the vault, its address in its Accessory Settings.
extension ESPHomePlugin {
    /// The devices the plugin runs, those mDNS announces, and those `devices` and `_accessories` name: a running plugin
    /// answers from what it has seen; an instance made only for Setup browses for `setupDiscoveryWindow` first.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [String: DiscoveredDevice] = [:]
        func add(_ id: String, name: String, model: String?, address: String?, encrypted: Bool, setUp: Bool, reachable: Bool = true) {
            var device = found[id] ?? DiscoveredDevice(deviceID: id, name: name, kind: Self.deviceKind)
            device.name = context.accessorySettings(for: id).name ?? (found[id] == nil ? name : device.name)
            device.model = model ?? device.model
            device.address = address ?? device.address
            if encrypted { device.authorization = .apiKey }
            device.isSetUp = device.isSetUp || setUp
            device.isReachable = reachable
            found[id] = device
        }
        let announcements = browsed ? Array(announced.values) : await dependencies.browse(dependencies.setupDiscoveryWindow, logger)
        for announcement in announcements {
            guard let mac = announcement.mac else { continue }
            add(mac, name: announcement.displayName, model: nil, address: Self.address(announcement.preferredAddress ?? announcement.hostName, announcement.port),
                encrypted: announcement.encrypted, setUp: false)
        }
        for (mac, settings) in context.allAccessorySettings {
            guard let own = settings.decode(DeviceSettings.self), let host = own.host, !host.isEmpty, let mac = MACAddress.canonical(mac) else { continue }
            let encrypted = context.credentials(for: mac, as: ESPHomeCredentials.self)?.encryptionKey != nil
            add(mac, name: learnedInfo[mac]?.displayName ?? host, model: learnedInfo[mac]?.model.nonEmpty, address: Self.address(host, own.port ?? ESPHomeEndpoint.defaultPort),
                encrypted: encrypted, setUp: true)
        }
        for device in configuration.devices ?? [] {
            guard let host = device.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { continue }
            let port = device.port ?? ESPHomeEndpoint.defaultPort
            let id = learnedMACs[Self.hostKey(host, port)] ?? host
            add(id, name: learnedInfo[id]?.displayName ?? host, model: nil, address: Self.address(host, port), encrypted: device.encryptionKey != nil, setUp: true)
        }
        for (key, device) in devices {
            guard let mac = await device.mac else { continue }
            let connected = await device.isConnected
            let info = await device.info
            let endpoint = await device.endpoint
            add(mac, name: info?.displayName ?? key, model: info?.model.nonEmpty, address: Self.address(endpoint.host, endpoint.port),
                encrypted: endpoint.encryptionKey != nil, setUp: true, reachable: connected)
        }
        return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// One step for a device: connects with what it has (nothing, then the key or password asked), and asks again until
    /// the device opens. The key and the password go in the vault, the address in the device's Accessory Settings.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard let address = device.address, let (host, port) = Self.split(address) else {
            throw SetupError("The device has no address: find it again, or add its host to the devices list")
        }
        let encryptionKey = request.secret("encryptionKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = request.secret("password")
        if request.isFirst, device.authorization == .apiKey {
            return .ask(Self.keyPrompt)
        }
        let credentials = ESPHomeCredentials(encryptionKey: encryptionKey?.nonEmpty, password: password)
        let info: DeviceInfo
        do {
            info = try await probe(ESPHomeEndpoint(
                host: host, port: port, encryptionKey: credentials.encryptionKey, password: credentials.password,
                expectedMAC: MACAddress.canonical(device.deviceID)))
        } catch ESPHomeError.wrongDevice {
            throw SetupError("Another device answered at \(address): find the device again")
        } catch ESPHomeError.requiresEncryption {
            return .ask(Self.keyPrompt)
        } catch ESPHomeError.passwordRequired {
            return .ask(Self.passwordPrompt)
        } catch ESPHomeError.invalidEncryptionKey {
            throw SetupError("The device rejected that encryption key")
        } catch ESPHomeError.malformedKey {
            throw SetupError("That is not an encryption key: it is the base64 text of 32 bytes, as in the device's api: encryption: key:")
        } catch ESPHomeError.invalidPassword {
            throw SetupError("The device rejected that password")
        } catch ESPHomeError.usesPlaintext {
            // Never a quiet fall back to plaintext: what answers there may not be the device.
            throw SetupError("The device answered without encryption: enable encryption on it, or check its address")
        } catch {
            throw SetupError("Could not reach the device at \(address): \(ESPHomeDevice.describe(error))")
        }
        guard let mac = MACAddress.canonical(info.mac) else { throw SetupError("The device did not give its MAC address") }
        if let chosen = MACAddress.canonical(device.deviceID), chosen != mac {
            throw SetupError("Another device answered at \(address) (\(mac)): find the device again")
        }
        var settings: [String: JSONValue] = ["host": .string(host)]
        if port != ESPHomeEndpoint.defaultPort { settings["port"] = .number(Double(port)) }
        return .done(try SetupOutcome(encoding: credentials, settings: settings, deviceID: mac).keepingNone(if: credentials.isEmpty))
    }

    static let keyPrompt = SetupPrompt(
        message: "Enter the device's encryption key: the key under api: encryption: in its ESPHome configuration.",
        fields: [SetupField("encryptionKey", label: "Encryption key", kind: .secret)])

    static let passwordPrompt = SetupPrompt(
        message: "The device asks for its API password: the password under api: in its ESPHome configuration.",
        fields: [SetupField("password", label: "API password", kind: .secret)])

    /// Opens a session until the device listed its entities, and answers what it said of itself.
    func probe(_ endpoint: ESPHomeEndpoint) async throws -> DeviceInfo {
        let transport = dependencies.transport, log = context.logger
        // A person waits: shorter than a running device's patience, but long enough for a slow ESP8266 handshake.
        var timing = dependencies.timing
        timing.connectTimeout = min(timing.connectTimeout, .seconds(10))
        timing.responseTimeout = min(timing.responseTimeout, .seconds(15))
        timing.handshakeTimeout = min(timing.handshakeTimeout, .seconds(45))
        let result = NIOLockedValueBox<DeviceInfo?>(nil)
        do {
            try await ESPHomeSession.run(
                endpoint: endpoint, transport: transport, timing: timing, logger: log,
                onReady: { ready in
                    result.withLockedValue { $0 = ready.info }
                    await ready.link.close()
                }, onState: { _, _ in })
        } catch {
            if let info = result.withLockedValue { $0 } { return info }
            throw error
        }
        if let info = result.withLockedValue { $0 } { return info }
        throw ESPHomeError.connectionLost
    }

    static func address(_ host: String, _ port: Int) -> String {
        hostHeader(host: host, port: port, defaultPort: ESPHomeEndpoint.defaultPort)
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port`.
    static func split(_ address: String) -> (String, Int)? {
        let text = address.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, ESPHomeEndpoint.defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = text.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        if parts.count > 2 { return (text, ESPHomeEndpoint.defaultPort) }
        return text.isEmpty ? nil : (text, ESPHomeEndpoint.defaultPort)
    }
}

extension DeviceInfo {
    var displayName: String { friendlyName.isEmpty ? name : friendlyName }
}

extension SetupOutcome {
    /// No credentials for a device that needs none: Authorized means credentials kept.
    fileprivate func keepingNone(if empty: Bool) -> SetupOutcome {
        guard empty else { return self }
        var outcome = self
        outcome.credentials = nil
        return outcome
    }
}

