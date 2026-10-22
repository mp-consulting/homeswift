import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// This machine's network interfaces.
public enum NetworkInterfaces {
    /// Every IPv4 address of an interface, with its netmask, loopback included.
    public static func ipv4() -> [(address: UInt32, netmask: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(UInt32, UInt32)] = []
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, let mask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET), mask.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            found.append((local, netmask))
        }
        return found
    }

}
