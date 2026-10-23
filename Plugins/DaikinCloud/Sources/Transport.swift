import Foundation
import HomeswiftNetwork

/// Every request to the Daikin cloud: the shared defaults (User-Agent, timeout), the transport the
/// configuration picks, and errors in the terms the retry logic and the logs use.
///
/// The Daikin endpoints sit behind a firewall that classifies clients by their TLS fingerprint and drops
/// some silently. The plugin identifies as OkHttp, as the Onecta app whose OAuth client the Mobile App
/// login emulates, and never as a browser (a browser User-Agent with a non-browser fingerprint is flagged).
struct DaikinHTTP: Sendable {
    /// Overridable for diagnostics, as in the Homebridge plugin.
    static let userAgent = ProcessInfo.processInfo.environment["DAIKIN_USER_AGENT"] ?? "okhttp/4.12.0"
    static let timeout: Duration = .seconds(30)

    let transport: any HTTPSending

    /// The transport for a mode; `DAIKIN_HTTP_TRANSPORT` wins over the configuration, as in Homebridge.
    static func transport(for mode: TransportMode?, environment: [String: String] = ProcessInfo.processInfo.environment) -> TransportMode {
        if let forced = environment["DAIKIN_HTTP_TRANSPORT"].flatMap(TransportMode.init(rawValue:)) { return forced }
        return mode ?? .node
    }

    static func makeTransport(_ mode: TransportMode) -> any HTTPSending {
        switch mode {
        case .node: HTTPClient(tls: .system, maximumBodySize: 10 * 1024 * 1024)
        case .curl: CurlTransport()
        }
    }

    func send(_ method: String, _ url: URL, headers: [(name: String, value: String)] = [], body: Data? = nil, timeout: Duration = timeout) async throws -> HTTPResponse {
        var request = HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeout)
        if request.header("User-Agent") == nil { request.setHeader("User-Agent", Self.userAgent) }
        do {
            return try await transport.send(request)
        } catch let error as CancellationError {
            throw error
        } catch let error as DaikinNetworkError {
            throw error
        } catch {
            throw DaikinNetworkError(error, timeout: timeout)
        }
    }

    /// POSTs a form.
    func postForm(_ url: URL, _ fields: [(String, String)], headers: [(name: String, value: String)] = []) async throws -> HTTPResponse {
        try await send("POST", url, headers: [("Content-Type", "application/x-www-form-urlencoded")] + headers, body: Data(URLEncoding.form(fields).utf8))
    }
}

/// A request that got no HTTP response at all, with the errno-style code the retry logic matches on
/// (`ETIMEDOUT`, `ECONNREFUSED`, ...), as Node reports it.
struct DaikinNetworkError: Error, CustomStringConvertible, Equatable, Sendable {
    var code: String
    var message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: any Error, timeout: Duration) {
        switch error as? HTTPClientError {
        case .timeout:
            self.init(code: "ETIMEDOUT", message: "no response after \(Int(timeout / .milliseconds(1)))ms")
        case .cannotConnect(_, _, let errno, let reason):
            let name = errno.flatMap(Self.errnoNames.index(forKey:)).map { Self.errnoNames[$0].value }
            self.init(code: name ?? (reason.lowercased().contains("dns") || reason.lowercased().contains("resolve") ? "ENOTFOUND" : "ECONNREFUSED"), message: reason)
        case .connectionClosed:
            self.init(code: "ECONNRESET", message: "the connection closed before the response ended")
        case .some(let other):
            self.init(code: "EPROTO", message: other.description)
        case nil:
            self.init(code: "EUNKNOWN", message: "\(error)")
        }
    }

    /// Failures where trying again may work: a dropped packet, a host still bringing its network up, a
    /// flaky resolver.
    static let retryableCodes: Set<String> = [
        "ETIMEDOUT", "ECONNRESET", "ECONNREFUSED", "ECONNABORTED", "EPIPE", "EAI_AGAIN", "ENOTFOUND", "ENETUNREACH", "EHOSTUNREACH",
    ]

    var isRetryable: Bool { Self.retryableCodes.contains(code) }
    var description: String { "\(message) (\(code))" }

    static let errnoNames: [Int32: String] = [
        ECONNREFUSED: "ECONNREFUSED", ETIMEDOUT: "ETIMEDOUT", ECONNRESET: "ECONNRESET", ECONNABORTED: "ECONNABORTED",
        EPIPE: "EPIPE", ENETUNREACH: "ENETUNREACH", EHOSTUNREACH: "EHOSTUNREACH",
    ]
}

/// Reading values out of URLs; writing them is `URLEncoding`'s.
enum URLQuery {
    /// The value of a query parameter of a URL, decoded as `URLSearchParams.get` does; nil when absent.
    static func parameter(_ name: String, in url: String) -> String? {
        guard let start = url.firstIndex(of: "?") else { return nil }
        let query = url[url.index(after: start)...].prefix { $0 != "#" }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map({ URLEncoding.decode(String($0)) }) == name else { continue }
            return URLEncoding.decode(parts.count > 1 ? String(parts[1]) : "")
        }
        return nil
    }

    /// What `/name=([^&]+)/` captures anywhere in a string, undecoded: how the Mobile App login reads the
    /// `Location` of a redirect.
    static func match(_ name: String, in string: String) -> String? {
        guard let range = string.range(of: "\(name)=") else { return nil }
        let value = string[range.upperBound...].prefix { $0 != "&" }
        return value.isEmpty ? nil : String(value)
    }
}

extension HTTPResponse {
    var text: String { String(decoding: body, as: UTF8.self) }

    /// Every value of a header, e.g. the several `Set-Cookie` lines of one response.
    func values(of name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// A header as an integer, as `parseInt` reads it.
    func integer(_ name: String) -> Int? {
        guard let value = header(name)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let digits = value.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }
}
