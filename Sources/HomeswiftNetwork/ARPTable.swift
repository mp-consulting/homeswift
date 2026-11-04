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
        for line in table.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4, columns[0] == ip, columns[2] != "0x0" else { continue }
            if let mac = normalized(String(columns[3])) { return mac }
        }
        return nil
    }

    /// The address in canonical form; nil for `(incomplete)`, all zeros and broadcast.
    static func normalized(_ address: String) -> String? {
        guard let mac = MACAddress.canonical(address), mac != "00:00:00:00:00:00", mac != "FF:FF:FF:FF:FF:FF" else { return nil }
        return mac
    }

    #if canImport(Darwin)
    /// Runs a tool and returns what it printed. Nothing waits on a thread of Swift's pool: the output is read
    /// on Foundation's handler thread once the tool exits (one line of `arp`, far below a pipe's buffer).
    private static func run(_ path: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
    #endif
}
