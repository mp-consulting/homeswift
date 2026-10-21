import Foundation

/// Host names as `Host` and `Origin` headers carry them: `[::1]:8581`, `Mac-Mini.local.`, `fe80::1%en0`.
public enum HostName {
    /// The host part, lower-cased, without the port, brackets or a trailing dot.
    public static func of(_ header: String) -> String {
        var host = header.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") {
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if let colon = host.lastIndex(of: ":"), !host[..<colon].contains(":") {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// The port of a `Host` header, when it names one.
    public static func port(of header: String) -> Int? {
        let host = header.trimmingCharacters(in: .whitespaces)
        let rest: Substring
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            rest = host[host.index(after: close)...]
        } else if let colon = host.lastIndex(of: ":"), !host[..<colon].contains(":") {
            rest = host[colon...]
        } else {
            return nil
        }
        return rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
    }

    /// An IPv4 or IPv6 literal, with or without a zone.
    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            let address = host.prefix { $0 != "%" }
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { $0 <= 255 } == true
        }
    }

    /// This machine, as a browser names it: localhost and the loopback addresses.
    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
    }
}
