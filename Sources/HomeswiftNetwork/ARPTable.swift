import Foundation

/// The operating system's ARP table: the MAC address behind an IPv4 address on the local network that this
/// machine talked to lately. Linux has it in `/proc/net/arp`; macOS has no file for it, so `arp -n` is asked.
public enum ARPTable {
    /// The MAC address of `ip` (`MACAddress.canonical`), or nil when the table has no complete entry for it.
    public static func macAddress(for ip: String) async -> String? {
        guard WakeOnLAN.ipv4(ip) != nil else { return nil }
        #if canImport(Darwin)
        guard let output = await run("/usr/sbin/arp", ["-n", ip]) else { return nil }
        return darwinEntry(in: output, ip: ip)
        #else
        guard let table = try? String(contentsOfFile: "/proc/net/arp", encoding: .utf8) else { return nil }
        return linuxEntry(in: table, ip: ip)
        #endif
    }

    /// Every complete entry of the table: the IPv4 addresses this machine talked to lately and their MAC addresses
    /// (`MACAddress.canonical`). Plugins filter it by a vendor's prefix to find devices that announce nothing.
    public static func entries() async -> [(ip: String, mac: String)] {
        #if canImport(Darwin)
        guard let output = await run("/usr/sbin/arp", ["-an"]) else { return [] }
        return darwinEntries(in: output)
        #else
        guard let table = try? String(contentsOfFile: "/proc/net/arp", encoding: .utf8) else { return [] }
        return linuxEntries(in: table)
        #endif
    }

    /// Makes the system resolve the MAC address of every address of this machine's local IPv4 networks, so `entries()`
    /// lists the devices that are on but said nothing to this machine lately: one empty datagram to the discard port (9)
    /// of each address, then up to `settle` for the answers, less once every MAC of `wanted` (`MACAddress.canonical`)
    /// is in the table. Only networks of at most `maximumHosts` addresses are covered (a container's /16 bridge is not),
    /// loopback aside. Nothing listens on the discard port: a device answers the ARP request and drops the datagram.
    public static func resolveLocalNetworks(lookingFor wanted: Set<String> = [], maximumHosts: UInt32 = 1024, settle: Duration = .milliseconds(1500)) async {
        let networks = localIPv4Networks().filter { !$0.isLoopback && ~$0.netmask >= 2 && ~$0.netmask <= maximumHosts }
        guard !networks.isEmpty, let socket = try? await UDPSocket.bind() else { return }
        for network in networks {
            let base = network.address & network.netmask
            for host in 1..<(~network.netmask) where base | host != network.address {
                try? await socket.send(Data(), to: IPv4Network.dotted(base | host), port: 9)
            }
        }
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: min(.milliseconds(250), deadline - .now))
            if !wanted.isEmpty, wanted.isSubset(of: Set(await entries().map(\.mac))) { break }
        }
        await socket.close()
    }

    /// `arp -an`'s lines: `? (192.168.1.20) at 0:11:22:aa:bb:c on en0 ifscope [ethernet]`.
    static func darwinEntries(in output: String) -> [(ip: String, mac: String)] {
        output.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { return nil }
            let ip = String(line[line.index(after: open)..<close])
            guard WakeOnLAN.ipv4(ip) != nil, let mac = darwinEntry(in: String(line), ip: ip) else { return nil }
            return (ip, mac)
        }
    }

    /// `/proc/net/arp`'s complete entries.
    static func linuxEntries(in table: String) -> [(ip: String, mac: String)] {
        table.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4, columns[2] != "0x0", let mac = normalized(String(columns[3])) else { return nil }
            return (String(columns[0]), mac)
        }
    }

    /// `? (192.168.1.20) at 0:11:22:aa:bb:c on en0 ifscope [ethernet]`: macOS drops leading zeros.
    static func darwinEntry(in output: String, ip: String) -> String? {
        let marker = "(\(ip)) at "
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let address = line[range.upperBound...].prefix { !$0.isWhitespace }
            if let mac = normalized(String(address)) { return mac }
        }
        return nil
    }

    /// `/proc/net/arp`: a header, then `IP address  HW type  Flags  HW address  Mask  Device`; flags `0x0`
    /// mark an entry still being resolved.
    static func linuxEntry(in table: String, ip: String) -> String? {
        linuxEntries(in: table).first { $0.ip == ip }?.mac
    }

    /// The address in canonical form; nil for `(incomplete)`, all zeros and broadcast.
    static func normalized(_ address: String) -> String? {
        guard let mac = MACAddress.canonical(address), mac != "00:00:00:00:00:00", mac != "FF:FF:FF:FF:FF:FF" else { return nil }
        return mac
    }

    #if canImport(Darwin)
    /// Runs a tool and returns what it printed, through `ChildProcess` (`posix_spawn`) on a thread of its own, so nothing
    /// waits on a thread of Swift's pool. Not Foundation's `Process`: it reads the current directory as it starts, which
    /// blocks on macOS's privacy check when the bridge was started from a protected folder (`~/Documents`).
    private static func run(_ path: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: try? ChildProcess.run(path, arguments: arguments).text)
            }
        }
    }
    #endif
}
