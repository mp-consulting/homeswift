import Foundation
import HomeswiftNetwork
#if canImport(Glibc)
import Glibc
#endif

/// What devices on the network call themselves, for picking a Person's devices: the name Apple devices announce over
/// mDNS ("Alex's iPhone", from `_companion-link._tcp` and `_device-info._tcp`), else the one the router's DNS has for
/// the address, which is the host name the device gave DHCP ("Galaxy-S24.lan" reads "Galaxy-S24"). Nothing is asked
/// beyond the local network.
enum NetworkNames {
    /// The mDNS services whose instance names are a device's own name.
    static let services = ["_companion-link._tcp.local", "_device-info._tcp.local"]
    static let mdnsWindow: Duration = .milliseconds(1500)
    /// How long the reverse lookups may take in all, and how many run at once (`getnameinfo` holds a thread each).
    static let dnsWindow: Duration = .seconds(2)
    static let dnsLookupsAtOnce = 8

    static func lookUp(_ ips: [String]) async -> [String: String] {
        guard !ips.isEmpty else { return [:] }
        async let announced = announcedNames()
        async let registered = reverseNames(ips)
        let wanted = Set(ips)
        var names = await registered.filter { wanted.contains($0.key) }
        for (ip, name) in await announced where wanted.contains(ip) { names[ip] = name }
        return names
    }

    /// Names announced over mDNS, by the address that announced them.
    static func announcedNames() async -> [String: String] {
        await withTaskGroup(of: [MDNSQuery.Response].self) { group in
            for service in services {
                group.addTask { (try? await MDNSQuery.query(service, duration: mdnsWindow)) ?? [] }
            }
            var names: [String: String] = [:]
            for await responses in group {
                for response in responses {
                    guard names[response.sender] == nil, let name = response.names.lazy.compactMap({ instance(of: $0) }).first else { continue }
                    names[response.sender] = name
                }
            }
            return names
        }
    }

    /// The instance part of a service instance's name: `Alex’s iPhone` of `Alex’s iPhone._companion-link._tcp.local`.
    static func instance(of name: String) -> String? {
        for service in services {
            let suffix = "." + service
            guard name.hasSuffix(suffix) else { continue }
            let instance = String(name.dropLast(suffix.count)).replacingOccurrences(of: "\\032", with: " ").trimmingCharacters(in: .whitespaces)
            return instance.isEmpty ? nil : String(instance.prefix(64))
        }
        return nil
    }

    /// The router's names for the addresses (DHCP host names, through its DNS), those found within `dnsWindow`.
    static func reverseNames(_ ips: [String]) async -> [String: String] {
        let found = LockedNames()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { lookups in
                    for (index, ip) in ips.enumerated() {
                        if index >= dnsLookupsAtOnce { await lookups.next() }
                        guard !Task.isCancelled else { return }
                        lookups.addTask {
                            if let name = await reverseName(ip) { found.set(ip, name) }
                        }
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: dnsWindow) }
            await group.next()
            group.cancelAll()
        }
        return found.all
    }

    /// One address's name in the system resolver, on a thread of its own (`getnameinfo` blocks); nil for none, or for a
    /// name that only spells the address out.
    static func reverseName(_ ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: lookUpSync(ip).flatMap { hostLabel($0, ip: ip) })
            }
        }
    }

    private static func lookUpSync(_ ip: String) -> String? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The first label of a host name, unless it is the address spelled out (`192-168-1-20`) or a number.
    static func hostLabel(_ host: String, ip: String) -> String? {
        let label = String(host.split(separator: ".").first ?? "")
        let digits = ip.split(separator: ".")
        guard !label.isEmpty, !label.allSatisfy({ $0.isNumber || $0 == "-" }), !digits.allSatisfy({ label.contains($0) }) else { return nil }
        return String(label.prefix(64))
    }
}

/// Names found by the lookups running at once.
private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func set(_ ip: String, _ name: String) { lock.withLock { names[ip] = name } }
    var all: [String: String] { lock.withLock { names } }
}
