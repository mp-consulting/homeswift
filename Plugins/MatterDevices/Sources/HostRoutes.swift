import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Whether the bridge's host can route to a Thread device at all. A Thread network's prefix is a Unique Local one that
/// its border routers announce in Router Advertisements (Route Information Options, RFC 4191); a Linux kernel built
/// without them (a Synology NAS's) never learns it, and the device's address then goes to the default route, which drops
/// it. Setup says so instead of blaming the device.
enum HostRoutes {
    /// Linux's IPv6 routing table, every table's routes; macOS and others have none, and learn the border routers' routes.
    static let linuxTable = "/proc/net/ipv6_route"

    /// The /64 of a Unique Local address (fc00::/7, Thread's) the host has no route to other than its default one; nil
    /// when it has one, the address is no such address, or the host's table cannot be read.
    static func missingRoute(to host: String) -> String? {
        missingRoute(to: host, table: try? String(contentsOfFile: linuxTable, encoding: .utf8))
    }

    static func missingRoute(to host: String, table: String?) -> String? {
        guard let table, let address = bytes(of: host), address[0] & 0xFE == 0xFC, !hasRoute(to: address, in: table) else { return nil }
        return prefix64(of: address)
    }

    /// Whether a route of the table other than the default (::/0) covers the address. A line of /proc/net/ipv6_route is
    /// its destination and prefix length, source and its length, next hop, metric, reference count, use count, flags and
    /// device, numbers in hexadecimal; a reject route (an unreachable one) leads nowhere.
    static func hasRoute(to address: [UInt8], in table: String) -> Bool {
        table.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, let destination = hexBytes(fields[0]), destination.count == 16,
                  let length = Int(fields[1], radix: 16), (1...128).contains(length),
                  let flags = UInt32(fields[8], radix: 16), flags & rejectFlag == 0 else { return false }
            return covers(destination, length: length, address)
        }
    }

    /// RTF_REJECT: an unreachable or prohibited route.
    static let rejectFlag: UInt32 = 0x0200

    static func covers(_ prefix: [UInt8], length: Int, _ address: [UInt8]) -> Bool {
        let whole = length / 8, rest = length % 8
        guard prefix[..<whole] == address[..<whole] else { return false }
        guard rest > 0 else { return true }
        let mask = UInt8(0xFF) << (8 - rest)
        return prefix[whole] & mask == address[whole] & mask
    }

    static func bytes(of host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func hexBytes(_ text: Substring) -> [UInt8]? {
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// "fd12:3456:789a::/64".
    static func prefix64(of address: [UInt8]) -> String {
        var groups = (0..<4).map { String(UInt16(address[$0 * 2]) << 8 | UInt16(address[$0 * 2 + 1]), radix: 16) }
        while groups.last == "0" { groups.removeLast() }
        return groups.joined(separator: ":") + "::/64"
    }
}
