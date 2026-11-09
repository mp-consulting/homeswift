import Foundation
import Homeswift
import HomeswiftPlugin
import Matter
import NIOConcurrencyHelpers
import NIOCore

/// A node with a commissioning window open, as DNS-SD announces it (Core §4.3.1).
struct CommissionableNode: Sendable, Equatable {
    /// Its `_matterc._udp` instance name: random, new with each window.
    var instance: String
    var info: CommissionableNodeInfo
    var address: NodeAddress
}

/// Where a node answers: its address and port, and the MRP intervals its record gives.
struct NodeAddress: Sendable, Equatable, Codable {
    var host: String
    var port: Int
    var parameters: SessionParameters?

    /// "[fd4d:…:90ad]:5540" or "192.0.2.4:5540", for the page and the log.
    var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// How the plugin finds Matter nodes on the network; tests give a fake.
protocol MatterDiscovery: Sendable {
    /// The nodes with a commissioning window open, gathered for `duration` (or until one matches `until`).
    func commissionable(for duration: Duration, until match: (@Sendable (CommissionableNode) -> Bool)?) async -> [CommissionableNode]
    /// Where an operational node answers: its `_matter._tcp` instance name (Core §4.3.2.1), within `timeout`.
    func operational(instance: String, timeout: Duration) async -> NodeAddress?
}

/// Matter's DNS-SD records through dns_sd (Avahi on Linux), the bridge's Bonjour browser.
struct BonjourMatterDiscovery: MatterDiscovery {
    func commissionable(for duration: Duration, until match: (@Sendable (CommissionableNode) -> Bool)?) async -> [CommissionableNode] {
        let browse = BonjourBrowser.browse(type: "_matterc._udp")
        let events: [BonjourBrowser.Event]
        if let match {
            // A match ends the browse early.
            let seen = NIOLockedValueBox<[BonjourBrowser.Event]>([])
            _ = try? await withTimeout(duration) {
                for await event in browse {
                    seen.withLockedValue { $0.append(event) }
                    if let window = Self.window(event), match(window) { return }
                }
            }
            events = seen.withLockedValue { $0 }
        } else {
            events = await browse.collect(for: duration)
        }
        // The last record of each window wins.
        let windows = events.compactMap(Self.window)
        return Dictionary(windows.map { ($0.instance, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.instance < $1.instance }
    }

    /// A commissionable record with its window open, as a node to commission.
    static func window(_ event: BonjourBrowser.Event) -> CommissionableNode? {
        guard case .found(let service) = event, let info = CommissionableNodeInfo(txt: service.txt), info.isCommissionable,
              let host = reachableAddress(service.addresses) else { return nil }
        return CommissionableNode(instance: service.name, info: info, address: NodeAddress(host: host, port: service.port, parameters: info.parameters))
    }

    func operational(instance: String, timeout: Duration) async -> NodeAddress? {
        try? await withTimeout(timeout) {
            for await event in BonjourBrowser.browse(type: "_matter._tcp") {
                guard case .found(let service) = event, service.name.caseInsensitiveCompare(instance) == .orderedSame,
                      let host = Self.reachableAddress(service.addresses) else { continue }
                return NodeAddress(host: host, port: service.port, parameters: SessionParameters(txt: service.txt))
            }
            throw CancellationError()
        }
    }

    /// The address to reach a node at: a routable IPv6 address first (a Thread device has only those, through its
    /// border router), then IPv4. A link-local IPv6 address needs its interface, which a datagram socket address here
    /// does not carry, so it is left out.
    static func reachableAddress(_ addresses: [String]) -> String? {
        let cleaned = addresses.map { $0.split(separator: "%").first.map(String.init) ?? $0 }
        let ipv6 = cleaned.filter { $0.contains(":") && !$0.lowercased().hasPrefix("fe80") }
        return ipv6.first ?? cleaned.first { !$0.contains(":") }
    }
}
