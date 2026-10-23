import Foundation
import Homeswift
import Logging

/// Finds Dyson devices over mDNS: each announces `_dyson_mqtt._tcp` under a name with its serial number.
enum Discovery {
    static let serviceType = "_dyson_mqtt._tcp"

    /// Browses for `duration` and answers serial number → address. Only addresses on the local network count:
    /// the plugin sends the device's credentials to whatever answers, so a spoofed record pointing at a public
    /// address is ignored.
    @Sendable static func discover(duration: Duration, logger: Logger) async -> [String: String] {
        let deadline = ContinuousClock.now + duration
        let task = Task { () -> [String: String] in
            var found: [String: String] = [:]
            for await event in BonjourBrowser.browse(type: serviceType, logger: logger) {
                guard case .found(let service) = event, let serial = serial(fromServiceName: service.name),
                      let address = address(of: service.addresses), found[serial] == nil else { continue }
                found[serial] = address
            }
            return found
        }
        try? await Task.sleep(until: deadline)
        task.cancel()
        return await task.value
    }

    /// The serial in a service name: `ABC-AB-12345678`, `ABC-AB-12345678_dyson_mqtt`, `455_ABC-AB-12345678`.
    static func serial(fromServiceName name: String) -> String? {
        let pattern = /(?:^\d+_)?([A-Za-z0-9]{2,3}-[A-Za-z0-9]{2}-[A-Za-z0-9]{8})/
        guard let match = name.firstMatch(of: pattern) else { return nil }
        return String(match.output.1).uppercased()
    }

    /// The first local IPv4 address, else the first local IPv6 one.
    static func address(of addresses: [String]) -> String? {
        let local = addresses.filter(isLocalNetworkAddress)
        return local.first(where: isIPv4) ?? local.first
    }

    /// RFC 1918 private IPv4, or IPv6 link-local (fe80::/10) and unique-local (fc00::/7).
    static func isLocalNetworkAddress(_ address: String) -> Bool {
        if isIPv4(address) { return isPrivateIPv4(address) }
        guard address.contains(":") else { return false }
        let lower = address.lowercased()
        return lower.range(of: "^fe[89ab]", options: .regularExpression) != nil || lower.range(of: "^f[cd]", options: .regularExpression) != nil
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        guard isIPv4(address) else { return false }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
    }

    static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        // Digits only: `UInt8("+19")` alone would take a sign.
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil }
    }
}
