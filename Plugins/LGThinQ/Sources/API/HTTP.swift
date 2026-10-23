import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension HTTPResponse {
    /// The `name=value` pair of each cookie the response sets, in order.
    var cookies: [String] {
        headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .map { String($0.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
    }

    /// The body as axios gives it: parsed JSON, or the text when it is not JSON.
    var data: JSONValue {
        if body.isEmpty { return .string("") }
        return (try? JSONValue(data: body)) ?? .string(String(decoding: body, as: UTF8.self))
    }
}

/// A failure below HTTP: no answer at all. `isConnectionError` is what axios calls `ECONN*`, which is retried.
public struct ThinQNetworkError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var isConnectionError: Bool

    public init(_ message: String, isConnectionError: Bool) {
        self.message = message
        self.isConnectionError = isConnectionError
    }

    public var description: String { message }
}

/// URLSession without cookie storage or cache: the sign-in carries its cookies by hand, as the Homebridge
/// plugin does, and nothing of an account stays in a shared store. Each cookie the response sets comes back
/// as one `Set-Cookie: name=value` header.
public struct URLSessionThinQTransport: HTTPSending {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            let connection: Set<URLError.Code> = [.cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet, .secureConnectionFailed]
            throw ThinQNetworkError("\(request.url.host ?? "LG"): \(error.localizedDescription)", isConnectionError: connection.contains(error.code))
        }
        guard let http = response as? HTTPURLResponse else { throw ThinQNetworkError("not an HTTP response", isConnectionError: false) }
        var headers: [(name: String, value: String)] = []
        var cookieFields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            if name.lowercased() == "set-cookie" { cookieFields["Set-Cookie"] = value } else { headers.append((name.lowercased(), value)) }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: cookieFields, for: request.url) {
            headers.append(("set-cookie", "\(cookie.name)=\(cookie.value)"))
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// `qs.parse` of a query string, flat: the last value of a key wins.
func parseQuery(_ query: String) -> [String: String] {
    var result: [String: String] = [:]
    for part in query.split(separator: "&") {
        let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        result[URLEncoding.decode(String(pieces[0]))] = pieces.count > 1 ? URLEncoding.decode(String(pieces[1])) : ""
    }
    return result
}

/// Luxon's `DateTime.utc().toRFC2822()`: `Thu, 22 Oct 2026 08:05:09 +0000`. LG checks it against its clock.
enum RFC2822 {
    /// Only formats (thread-safe); never changed after it is made.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return formatter
    }()

    static func string(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}
