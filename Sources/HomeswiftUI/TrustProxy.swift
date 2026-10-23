import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `trustProxy`: the reverse proxies whose `X-Forwarded-For` and `X-Forwarded-Proto` the web UI believes, after
/// upstream's setting. Addresses and CIDR ranges (`127.0.0.1`, `10.0.0.0/8`, `fd00::/8`) or the names `loopback`,
/// `linklocal` and `uniquelocal`; never "everyone", which would let any client pick its own address and step
/// around the login throttle. Without it the headers are ignored.
public struct TrustedProxies: Sendable, Equatable {
    struct Range: Sendable, Equatable {
        var bytes: [UInt8]
        var prefix: Int

        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == bytes.count else { return false }
            var remaining = prefix
            for index in bytes.indices where remaining > 0 {
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
                if address[index] & mask != bytes[index] & mask { return false }
                remaining -= bits
            }
            return true
        }
    }

    public static let keywords = ["loopback", "linklocal", "uniquelocal"]
    let ranges: [Range]
    public let entries: [String]

    public var isEmpty: Bool { ranges.isEmpty }

    public init() {
        ranges = []
        entries = []
    }

    /// Throws the entries that are none of the accepted forms.
    public init(_ entries: [String]) throws {
        var ranges: [Range] = []
        var invalid: [String] = []
        for entry in entries {
            switch entry.lowercased() {
            case "loopback": ranges += [Range(bytes: [127, 0, 0, 0], prefix: 8), Range(bytes: Self.parse("::1")!, prefix: 128)]
            case "linklocal": ranges += [Range(bytes: [169, 254, 0, 0], prefix: 16), Range(bytes: Self.parse("fe80::")!, prefix: 10)]
            case "uniquelocal": ranges += [Range(bytes: [10, 0, 0, 0], prefix: 8), Range(bytes: [172, 16, 0, 0], prefix: 12), Range(bytes: [192, 168, 0, 0], prefix: 16), Range(bytes: Self.parse("fc00::")!, prefix: 7)]
            default:
                let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count <= 2, let bytes = Self.parse(String(parts[0])) else { invalid.append(entry); continue }
                var prefix = bytes.count * 8
                if parts.count == 2 {
                    if let number = Int(parts[1]), parts[1].allSatisfy(\.isNumber), (0...prefix).contains(number) {
                        prefix = number
                    } else if bytes.count == 4, let mask = Self.parse(String(parts[1])), mask.count == 4 {
                        // A dotted netmask, 10.0.0.0/255.0.0.0.
                        prefix = mask.reduce(0) { $0 + $1.nonzeroBitCount }
                    } else {
                        invalid.append(entry)
                        continue
                    }
                }
                ranges.append(Range(bytes: bytes, prefix: prefix))
            }
        }
        guard invalid.isEmpty else { throw UIConfigurationError.invalid(key: "trustProxy", expected: "addresses or CIDR ranges (or loopback, linklocal, uniquelocal), not \(invalid.joined(separator: ", "))") }
        self.ranges = ranges
        self.entries = entries
    }

    /// An IPv4 or IPv6 address as bytes; an IPv4-mapped IPv6 address as its IPv4 bytes.
    static func parse(_ text: String) -> [UInt8]? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { trimmed = String(trimmed.dropFirst().dropLast()) }
        guard !trimmed.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff { return Array(bytes[12...]) }
            return bytes
        }
        return nil
    }

    public func trusts(_ address: String) -> Bool {
        guard let bytes = Self.parse(address) else { return false }
        return ranges.contains { $0.contains(bytes) }
    }

    /// The client behind the proxies: the right-most address of `X-Forwarded-For` that is not a trusted proxy, when
    /// the connection comes from one; the connection's own address otherwise.
    public func client(remote: String, forwardedFor: String?) -> String {
        guard trusts(remote), let forwardedFor else { return remote }
        let hops = forwardedFor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for hop in hops.reversed() {
            guard Self.parse(hop) != nil else { return remote }
            if !trusts(hop) { return hop }
        }
        return hops.first ?? remote
    }

    /// Whether the browser reached the proxy over HTTPS: `X-Forwarded-Proto` from a trusted proxy.
    public func forwardedHTTPS(remote: String, proto: String?) -> Bool {
        guard trusts(remote), let proto else { return false }
        return proto.split(separator: ",").first?.trimmingCharacters(in: .whitespaces).lowercased() == "https"
    }
}
