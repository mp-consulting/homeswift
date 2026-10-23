import Foundation
import Homeswift
import HomeswiftNetwork
import Logging

/// Finds Dyson devices over mDNS: each announces `_dyson_mqtt._tcp` under a name with its serial number.
enum Discovery {
    static let serviceType = "_dyson_mqtt._tcp"

    /// Browses for `duration` and answers serial number → address. Only addresses on the local network count:
    /// the plugin sends the device's credentials to whatever answers, so a spoofed record pointing at a public
    /// address is ignored.
    ///
    /// A one-shot mDNS query runs alongside: its answers come with the device's own address, which dns_sd does
    /// not give. When a device's records carry no local IPv4 address, that sender is used if it is a private IPv4
    /// one, as the Homebridge plugin falls back to bonjour-service's `referer`.
    @Sendable static func discover(duration: Duration, logger: Logger) async -> [String: String] {
        let deadline = ContinuousClock.now + duration
        let browse = Task { () -> [String: [String]] in
            var addresses: [String: [String]] = [:]
            for await event in BonjourBrowser.browse(type: serviceType, logger: logger) {
                guard case .found(let service) = event, let serial = serial(fromServiceName: service.name) else { continue }
                addresses[serial, default: []].append(contentsOf: service.addresses)
            }
            return addresses
        }
        let query = Task { () -> [MDNSQuery.Response] in
            do {
                return try await MDNSQuery.query("\(serviceType).local", duration: duration)
            } catch {
                logger.debug("mDNS query for \(serviceType) failed: \(error)")
                return []
            }
        }
        try? await Task.sleep(until: deadline)
        browse.cancel()
        return merge(addresses: await browse.value, referers: senders(of: await query.value))
    }

    /// Serial number → the address that answered for it, from one-shot query answers.
    static func senders(of responses: [MDNSQuery.Response]) -> [String: String] {
        var senders: [String: String] = [:]
        for response in responses {
            for name in response.names {
                // Only the instance names: `<serial>._dyson_mqtt._tcp.local`, not the host names.
                guard name.lowercased().contains(serviceType), let serial = serial(fromServiceName: name), senders[serial] == nil else { continue }
                senders[serial] = response.sender
            }
        }
        return senders
    }

    /// Each serial's address: from its records, else from who answered for it.
    static func merge(addresses: [String: [String]], referers: [String: String]) -> [String: String] {
        var found: [String: String] = [:]
        for serial in Set(addresses.keys).union(referers.keys) {
            if let address = address(of: addresses[serial] ?? [], referer: referers[serial]) { found[serial] = address }
        }
        return found
    }

    /// The serial in a service name: `ABC-AB-12345678`, `ABC-AB-12345678_dyson_mqtt`, `455_ABC-AB-12345678`.
    static func serial(fromServiceName name: String) -> String? {
        let pattern = /(?:^\d+_)?([A-Za-z0-9]{2,3}-[A-Za-z0-9]{2}-[A-Za-z0-9]{8})/
        guard let match = name.firstMatch(of: pattern) else { return nil }
        return String(match.output.1).uppercased()
    }

    /// The first local IPv4 address, else the sender of the answer (`referer`) if it is a private IPv4 address,
    /// else the first local IPv6 one.
    static func address(of addresses: [String], referer: String? = nil) -> String? {
        let local = addresses.filter(isLocalNetworkAddress)
        if let ipv4 = local.first(where: isIPv4) { return ipv4 }
        if let referer, isIPv4(referer), isLocalNetworkAddress(referer) { return referer }
        return local.first
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
