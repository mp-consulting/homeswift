import Foundation
import HomeswiftNetwork

/// Turns a light's host name into the address to connect to, as the Homebridge plugin's `dns-resolver.ts`
/// does: an IPv4 address is kept; otherwise the ARP table's entry for the light's MAC, then the addresses
/// Bonjour announced (IPv4 first), and the host name itself as the last resort.
enum HostResolution {
    static func resolve(host: String, mac: String, addresses: [String], arp: @Sendable (String) async -> String?) async -> String {
        if isIPv4(host) { return host }
        if let address = await arp(mac) { return address }
        return addresses.first(where: isIPv4) ?? addresses.first ?? host
    }

    /// Four decimal octets of at most 255.
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }

    /// The IPv4 address the ARP table has for `mac`: `arp -an` on macOS, `/proc/net/arp` on Linux.
    @Sendable static func arpAddress(forMAC mac: String) async -> String? {
        #if canImport(Darwin)
        guard let output = await run("/usr/sbin/arp", ["-an"]) else { return nil }
        return address(in: output, mac: mac)
        #else
        guard let table = try? String(contentsOfFile: "/proc/net/arp", encoding: .utf8) else { return nil }
        return address(in: table, mac: mac)
        #endif
    }

    /// The IPv4 address on the line of an ARP listing that carries `mac`, in any of the tables' formats:
    /// `? (192.168.1.20) at 3c:6a:9d:4:a:b on en0` (macOS drops leading zeros), `/proc/net/arp`'s columns,
    /// `192.168.1.20 dev eth0 lladdr 3c:6a:9d:04:0a:0b REACHABLE` (`ip neighbor`).
    static func address(in table: String, mac: String) -> String? {
        guard let target = MACAddress.canonical(mac) else { return nil }
        for line in table.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" }).map(String.init)
            guard tokens.contains(where: { $0.contains(":") || $0.contains("-") ? MACAddress.canonical($0) == target : false }) else { continue }
            if let address = tokens.first(where: isIPv4) { return address }
        }
        return nil
    }

    #if canImport(Darwin)
    /// Runs a tool and returns what it printed. The output is read on a dispatch thread while the tool runs
    /// (a large table can fill a pipe's buffer), so nothing blocks a thread of Swift's pool.
    private static func run(_ path: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
    #endif
}
