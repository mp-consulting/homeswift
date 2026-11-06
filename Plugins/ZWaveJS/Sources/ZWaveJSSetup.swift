import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A zwave-js-server mDNS announces (`_zwave-js-server._tcp`, its TXT `homeId`).
struct ServerAnnouncement: Sendable, Equatable {
    var name: String
    var host: String
    var port: Int
    /// The home id of its network, as decimal text.
    var homeID: String?
}

enum ZWaveDiscovery {
    static let serviceType = "_zwave-js-server._tcp"

    /// What mDNS announces within `window`.
    static func browse(for window: Duration, logger: Logger) async -> [ServerAnnouncement] {
        let events = BonjourBrowser.browse(type: serviceType, logger: logger)
        var found: [String: ServerAnnouncement] = [:]
        for event in await events.collect(for: window) {
            guard case .found(let service) = event else { continue }
            var host = service.addresses.first { $0.contains(".") && !$0.hasPrefix("169.254.") } ?? service.hostName
            if host.hasSuffix(".") { host.removeLast() }
            let homeID = service.txt["homeId"].flatMap { ServerVersion.homeID(.string($0)) }
            let announcement = ServerAnnouncement(name: service.name, host: host, port: service.port, homeID: homeID)
            found[homeID ?? "\(host):\(service.port)"] = announcement
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

// Setup (GLOSSARY.md, "Setup"): nothing to sign in to. A zwave-js-server is a device (Device Kind `server`, Device Id the
// home id of its Z-Wave network), found over mDNS or added by its address (Add by address); its Setup checks the server
// answers and keeps its `host` and `port` in its Accessory Settings. The nodes come with their server and need nothing
// more: each is a device with its Device Kind (`light`, `cover`, `switch`, `lock`, `thermostat`, `sensor`, `button`),
// which can be Excluded. Including a new node in the network stays in Z-Wave JS UI.
extension ZWaveJSPlugin {
    public static let addsDevicesByAddress = true

    /// How long Setup's check of an address may take.
    static let probeTimeout: Duration = .seconds(8)

    /// The servers set up, those mDNS announces, and the nodes of the servers connected.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [String: DiscoveredDevice] = [:]
        for (homeID, server) in servers {
            var device = DiscoveredDevice(
                deviceID: homeID, name: Self.serverName(homeID: homeID), model: "zwave-js-server", address: Self.address(host: server.host, port: server.port),
                isSetUp: true, kind: Self.serverKind)
            device.isReachable = server.client != nil || server.failures == 0
            found[homeID] = device
        }
        for announcement in await dependencies.browse(dependencies.setupDiscoveryWindow, logger) {
            let id = announcement.homeID ?? "address:\(Self.address(host: announcement.host, port: announcement.port))"
            guard found[id] == nil else { continue }
            found[id] = DiscoveredDevice(
                deviceID: id, name: announcement.homeID.map(Self.serverName) ?? announcement.name, model: "zwave-js-server",
                address: Self.address(host: announcement.host, port: announcement.port), kind: Self.serverKind)
        }
        for (homeID, server) in servers {
            for node in server.nodes.values {
                let deviceID = Self.deviceID(homeID: homeID, nodeID: node.nodeID)
                var device = DiscoveredDevice(
                    deviceID: deviceID, name: node.displayName, model: node.label ?? node.productDescription, isSetUp: true,
                    kind: accessories[deviceID]?.kind)
                device.isReachable = server.client != nil && !node.isDead
                found[deviceID] = device
            }
        }
        return found.values.sorted { ($0.kind == Self.serverKind ? 0 : 1, $0.name, $0.deviceID) < ($1.kind == Self.serverKind ? 0 : 1, $1.name, $1.deviceID) }
    }

    static func serverName(homeID: String) -> String { "Z-Wave network \(homeID)" }

    /// A server found on the network: checked at its address. Added by address: its address asked first. A node: nothing.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account:
            return .done(SetupOutcome())
        case .device(let device):
            guard device.kind == Self.serverKind || !device.deviceID.contains("-") || device.deviceID.hasPrefix("address:") else {
                return .done(SetupOutcome())
            }
            guard let address = device.address, let (host, port) = Self.split(address) else {
                throw SetupError("The server has no address: add it by its address")
            }
            return try await check(host: host, port: port, expected: device.deviceID.hasPrefix("address:") ? nil : device.deviceID)
        case .newDevice:
            guard let host = request.answer("host") else {
                return .ask(SetupPrompt(
                    message: "Enter the address of zwave-js-server: the host running Z-Wave JS UI or Home Assistant's Z-Wave JS add-on, and its WebSocket port (3000 by default).",
                    fields: [SetupField("host", label: "IP address or host name"), SetupField("port", label: "Port", optional: true)]))
            }
            let trimmed = Self.hostOnly(host)
            guard !trimmed.isEmpty, trimmed.count <= 253, !trimmed.contains(where: { $0.isWhitespace || $0 == "/" }) else {
                throw SetupError("That is not an address: type an IP address or a host name, such as 192.168.1.50")
            }
            let port = try request.answer("port").map { text in
                guard let port = Int(text), (1...65535).contains(port) else { throw SetupError("The port must be between 1 and 65535") }
                return port
            } ?? Self.split(host)?.1 ?? Self.defaultPort
            return try await check(host: trimmed, port: port, expected: nil)
        }
    }

    /// Asks the server at an address for its version message; keeps where it answers under its home id.
    private func check(host: String, port: Int, expected: String?) async throws -> SetupStep {
        let address = Self.address(host: host, port: port)
        let version: ServerVersion
        do {
            version = try await probe(host: host, port: port)
        } catch {
            logger.info("No zwave-js-server answered at \(address): \(error)")
            throw SetupError("No zwave-js-server answered at \(address)")
        }
        if let expected, expected != version.homeID {
            throw SetupError("Another Z-Wave network answered at \(address): find the server again")
        }
        logger.info("zwave-js-server \(version.serverVersion ?? "?") at \(address) runs the Z-Wave network \(version.homeID)")
        return .done(SetupOutcome(
            settings: ["host": .string(host), "port": port == Self.defaultPort ? .null : .number(Double(port))], deviceID: version.homeID))
    }

    /// The server's version message, read on a connection opened for it.
    func probe(host: String, port: Int) async throws -> ServerVersion {
        guard let url = Self.url(host: host, port: port) else { throw SetupError("That is not an address.") }
        let connect = dependencies.connect
        return try await withTimeout(Self.probeTimeout, error: { ZWaveError.timeout("the version message") }) {
            let socket = try await connect(url)
            let client = ZWaveClient(socket: socket, timeout: Self.probeTimeout)
            let reader = Task { await client.run() }
            defer { reader.cancel() }
            do {
                let version = try await client.version()
                await client.close()
                return version
            } catch {
                await client.close()
                throw error
            }
        }
    }

    /// A host typed with a scheme or a port (`ws://192.168.1.5:3000`) without them.
    static func hostOnly(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespaces)
        for scheme in ["ws://", "wss://"] where host.lowercased().hasPrefix(scheme) { host = String(host.dropFirst(scheme.count)) }
        if host.hasSuffix("/") { host.removeLast() }
        return split(host)?.0 ?? host
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port`.
    static func split(_ address: String) -> (String, Int)? {
        var text = address.trimmingCharacters(in: .whitespaces)
        for scheme in ["ws://", "wss://"] where text.lowercased().hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = text.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        if parts.count > 2 { return (text, defaultPort) }
        return text.isEmpty ? nil : (text, defaultPort)
    }
}
