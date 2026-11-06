import Foundation
import HomeswiftNetwork

/// A device seen on the network, for picking a Person's devices: its MAC (`MACAddress.canonical`), where it answers and
/// what it calls itself when something says (mDNS, the router's DNS from DHCP).
struct NetworkDevice: Sendable, Equatable {
    var mac: String
    var address: String
    var name: String?

    /// A locally administered address: one a phone made up for this network (iOS's and Android's private Wi-Fi
    /// address), rather than the one its maker gave it. A Rotating one changes, and the Person's device is lost.
    var isPrivate: Bool { Self.isPrivate(mac) }

    static func isPrivate(_ mac: String) -> Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }
}

/// Where Presence learns which devices are on the network. The ARP table and a probe of each address are the first
/// (`NetworkPresenceSource`); a UniFi Network controller's clients can be another, without the plugin changing.
protocol PresenceSource: Sendable {
    /// Which of `macs` are on the network now.
    func seen(_ macs: Set<String>) async -> Set<String>
    /// The devices on the network now, for Setup to pick from.
    func devices() async -> [NetworkDevice]
}

/// What `NetworkPresenceSource` asks of the machine's network; tests give a fake one.
protocol LocalNetwork: Sendable {
    /// The ARP table's complete entries: IPv4 addresses and their MACs.
    func arpEntries() async -> [(ip: String, mac: String)]
    /// Makes the system resolve every address of the local networks, so a device that said nothing lately is listed.
    func resolve(lookingFor macs: Set<String>) async
    /// Whether the address answers now.
    func isReachable(_ ip: String) async -> Bool
    /// What the devices at these addresses call themselves, where something says.
    func names(of ips: [String]) async -> [String: String]
}

/// Presence by ARP and probe: a device is on the network when its MAC is in the ARP table at an address that answers a
/// TCP connection (accepted or refused alike: ICMP needs privileges the bridge does not have), and the table still
/// gives that MAC for it after the probe, so an address handed to another device does not count. A MAC the table lacks
/// makes the system resolve the local networks first. A phone asleep may not answer for a while: the grace period
/// covers it.
struct NetworkPresenceSource: PresenceSource {
    let network: any LocalNetwork

    func seen(_ macs: Set<String>) async -> Set<String> {
        guard !macs.isEmpty else { return [] }
        var table = Self.addresses(await network.arpEntries(), of: macs)
        let missing = macs.subtracting(table.keys)
        if !missing.isEmpty {
            await network.resolve(lookingFor: missing)
            table = Self.addresses(await network.arpEntries(), of: macs)
        }
        let answered = await withTaskGroup(of: (String, Bool).self) { group in
            for (mac, ips) in table {
                for ip in ips { group.addTask { (mac + "@" + ip, await network.isReachable(ip)) } }
            }
            var answered: Set<String> = []
            for await (key, reachable) in group where reachable { answered.insert(key) }
            return answered
        }
        guard !answered.isEmpty else { return [] }
        // The same pairs once more: an address that answered for another device does not count for this one.
        let after = Self.addresses(await network.arpEntries(), of: macs)
        return Set(after.compactMap { mac, ips in ips.contains { answered.contains(mac + "@" + $0) } ? mac : nil })
    }

    func devices() async -> [NetworkDevice] {
        await network.resolve(lookingFor: [])
        var byMAC: [String: String] = [:]
        for entry in await network.arpEntries() { byMAC[entry.mac] = entry.ip }
        let names = await network.names(of: Array(byMAC.values))
        return byMAC.map { NetworkDevice(mac: $0.key, address: $0.value, name: names[$0.value]) }
            .sorted { ($0.name == nil ? 1 : 0, $0.name?.lowercased() ?? "", Self.order($0.address)) < ($1.name == nil ? 1 : 0, $1.name?.lowercased() ?? "", Self.order($1.address)) }
    }

    /// The addresses the table gives each of `macs`.
    static func addresses(_ entries: [(ip: String, mac: String)], of macs: Set<String>) -> [String: [String]] {
        var table: [String: [String]] = [:]
        for entry in entries where macs.contains(entry.mac) { table[entry.mac, default: []].append(entry.ip) }
        return table
    }

    /// An IPv4 address as a number, to sort by.
    static func order(_ address: String) -> UInt32 {
        address.split(separator: ".").reduce(0) { $0 << 8 | (UInt32($1) ?? 0) }
    }
}

/// The machine's own network: `ARPTable`, `TCPReachabilityProbe`, `NetworkNames`.
struct SystemNetwork: LocalNetwork {
    /// Phones keep 62078 open (Apple's lockdown service); others answer, or refuse, on the web ports.
    static let ports = [62078, 80, 443]

    func arpEntries() async -> [(ip: String, mac: String)] { await ARPTable.entries() }

    func resolve(lookingFor macs: Set<String>) async { await ARPTable.resolveLocalNetworks(lookingFor: macs) }

    func isReachable(_ ip: String) async -> Bool {
        await TCPReachabilityProbe(timeout: .seconds(2)).isReachable(ReachabilityTarget(host: ip, ports: Self.ports)) == true
    }

    func names(of ips: [String]) async -> [String: String] { await NetworkNames.lookUp(ips) }
}
