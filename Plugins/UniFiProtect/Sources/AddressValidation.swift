import Foundation
import HomeswiftNetwork
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the web page may make the bridge connect to (the Homebridge plugin's ui/server.js): controllers and
/// cameras live on private networks, so those are allowed, but loopback, link-local (the cloud metadata
/// address among them) and unspecified addresses are refused, and a name is resolved once and the vetted
/// address used, so a second DNS answer cannot steer the connection elsewhere.
enum AddressValidation {
    struct Vetted: Sendable, Equatable {
        var address: String
        var hostname: String
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case invalidAddress
        case cannotResolve(String)
        case notPermitted(String)

        var description: String {
            switch self {
            case .invalidAddress: "Invalid address."
            case .cannotResolve(let host): "Unable to resolve \(host)."
            case .notPermitted(let host): "Connections to \(host) are not permitted."
            }
        }
    }

    /// Largest snapshot passed to the page.
    static let snapshotMaxBytes = 10 * 1024 * 1024

    /// Whether an address is refused. Anything that is not an IP address is refused; an IPv4-mapped IPv6
    /// address is judged as the IPv4 address it carries.
    static func isBlocked(_ ip: String) -> Bool {
        var text = ip.trimmingCharacters(in: .whitespaces)
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if let v4 = ipv4Bytes(text) { return isBlockedIPv4(v4) }
        guard let v6 = ipv6Bytes(text) else { return true }
        if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF { return isBlockedIPv4(Array(v6[12..<16])) }
        // ::/96 (unspecified, loopback, IPv4-compatible), fe80::/10, and fd00:ec2::254 (the EC2 metadata endpoint).
        if v6[0..<12].allSatisfy({ $0 == 0 }) { return true }
        if v6[0] == 0xFE, v6[1] & 0xC0 == 0x80 { return true }
        if v6 == ipv6Bytes("fd00:ec2::254") { return true }
        return false
    }

    private static func isBlockedIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0 || bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254)
    }

    /// The four bytes of a dotted-quad IPv4 address (strictly four decimal parts).
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return nil }
            return UInt8(part)
        }
        return bytes.count == 4 ? bytes : nil
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard text.contains(":"), inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func isIP(_ text: String) -> Bool { ipv4Bytes(text) != nil || ipv6Bytes(text) != nil }

    /// The host an address names (a bare host, `host:port`, an IPv6 literal with or without brackets), with
    /// the other spellings of IPv4 addresses (`0x7f.1`, `2130706433`) made dotted-quad. nil when unusable.
    static func canonicalHostname(_ address: String?) -> String? {
        guard let trimmed = address?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        if isIP(trimmed) { return trimmed.lowercased() }
        guard let host = URLComponents(string: "http://" + trimmed)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return nil }
        if ipv6Bytes(host) != nil { return host.lowercased() }
        var v4 = in_addr()
        if host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }), inet_aton(host, &v4) != 0 {
            let raw = UInt32(bigEndian: v4.s_addr)
            return [raw >> 24, raw >> 16 & 0xFF, raw >> 8 & 0xFF, raw & 0xFF].map(String.init).joined(separator: ".")
        }
        return host.lowercased()
    }

    /// Resolves an address and checks every IP it maps to: a name with one blocked address is refused.
    static func resolveAllowed(_ address: String?, resolve: @Sendable (String) async throws -> [String] = systemResolve,
                               isBlocked: (String) -> Bool = AddressValidation.isBlocked) async throws -> Vetted {
        guard let hostname = canonicalHostname(address) else { throw Failure.invalidAddress }
        let addresses = isIP(hostname) ? [hostname] : ((try? await resolve(hostname)) ?? [])
        guard let first = addresses.first else { throw Failure.cannotResolve(hostname) }
        if addresses.contains(where: isBlocked) { throw Failure.notPermitted(hostname) }
        return Vetted(address: first, hostname: hostname)
    }

    /// The system resolver (`getaddrinfo`), every address in its order.
    @Sendable static func systemResolve(_ host: String) async throws -> [String] {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw Failure.cannotResolve(host) }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !addresses.contains(text) { addresses.append(text) }
                }
                cursor = entry.pointee.ai_next
            }
            return addresses
        }.value
    }

    /// A snapshot for the page's ONVIF profile picker: http(s) only, a permitted host, an image, 10 MB at
    /// most. Credentials in the URL go as Basic authentication, and only to the host the user named.
    static func fetchSnapshot(_ url: String?, expectedHost: String?, resolve: @Sendable (String) async throws -> [String] = systemResolve,
                              transport: any ProtectHTTPTransport = NetworkHTTPTransport(), timeout: Duration = .seconds(15)) async throws -> (contentType: String, data: Data) {
        guard let url, !url.isEmpty else { throw SnapshotError.message("url is required.") }
        guard let parsed = URLComponents(string: url), let scheme = parsed.scheme?.lowercased() else { throw SnapshotError.message("Invalid URL.") }
        guard scheme == "http" || scheme == "https" else { throw SnapshotError.message("Only http(s) snapshot URLs are supported.") }
        let hostPart = (parsed.host ?? "") + (parsed.port.map { ":\($0)" } ?? "")
        let vetted = try await resolveAllowed(hostPart, resolve: resolve)
        var target = parsed
        target.user = nil
        target.password = nil
        target.host = vetted.address.contains(":") ? "[\(vetted.address)]" : vetted.address
        guard let targetURL = target.url else { throw SnapshotError.message("Invalid URL.") }
        var request = HTTPRequest(method: "GET", url: targetURL, timeout: timeout)
        if let user = parsed.user, !user.isEmpty, expectedHost == nil || canonicalHostname(expectedHost) == vetted.hostname {
            let credentials = (user.removingPercentEncoding ?? user) + ":" + ((parsed.password ?? "").removingPercentEncoding ?? "")
            request.setHeader("Authorization", "Basic " + Data(credentials.utf8).base64EncodedString())
        }
        request.setHeader("Host", hostPart)
        let response: HTTPResponse
        do {
            response = try await transport.send(request, tls: .any)
        } catch HTTPClientError.responseTooLarge {
            throw SnapshotError.message("Snapshot payload exceeded \(snapshotMaxBytes / (1024 * 1024)) MB and was aborted.")
        } catch HTTPClientError.timeout {
            throw SnapshotError.message("Snapshot fetch timed out.")
        }
        guard response.status == 200 else {
            throw SnapshotError.message("HTTP \(response.status)" + (response.header("www-authenticate").map { " (\($0))" } ?? ""))
        }
        let contentType = (response.header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard contentType.hasPrefix("image/") else {
            throw SnapshotError.message("Snapshot URL did not return an image (content-type: \(contentType.isEmpty ? "none" : contentType)).")
        }
        guard response.body.count <= snapshotMaxBytes else {
            throw SnapshotError.message("Snapshot payload exceeded \(snapshotMaxBytes / (1024 * 1024)) MB and was aborted.")
        }
        return (contentType, response.body)
    }

    enum SnapshotError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Whether a controller answers HTTPS on port 443 within five seconds. Refused addresses are offline.
    static func checkStatus(_ address: String?, resolve: @Sendable (String) async throws -> [String] = systemResolve,
                            transport: any ProtectHTTPTransport = NetworkHTTPTransport()) async -> Bool {
        guard let vetted = try? await resolveAllowed(address, resolve: resolve) else { return false }
        let host = vetted.address.contains(":") ? "[\(vetted.address)]" : vetted.address
        guard let url = URL(string: "https://\(host):443/") else { return false }
        var request = HTTPRequest(method: "HEAD", url: url, timeout: .seconds(5))
        request.setHeader("Host", vetted.hostname)
        return (try? await transport.send(request, tls: .any)) != nil
    }
}
