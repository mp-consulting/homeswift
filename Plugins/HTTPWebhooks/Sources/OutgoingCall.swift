import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The request an entry makes for one action when HomeKit writes (`<prefix>_url`, `_method`, `_body`, `_form`,
/// `_headers`).
struct OutgoingCall: Sendable, Equatable {
    var url: String
    var method: String
    var body: String?
    /// A JSON object sent as `application/x-www-form-urlencoded`; it wins over `body`.
    var form: String?
    /// A JSON object of headers, as a string.
    var headers: String?
    var rejectUnauthorized: Bool

    /// Where a placeholder is replaced.
    struct Parts: OptionSet, Sendable {
        let rawValue: Int
        static let url = Parts(rawValue: 1)
        static let body = Parts(rawValue: 2)
        static let form = Parts(rawValue: 4)
        /// The URL, and the form when there is one, else the body.
        static let all: Parts = [.url, .body, .form]
    }

    /// The call with each placeholder replaced by its value in `parts`: the first occurrence only, without URL-encoding,
    /// as the Homebridge plugin does. `body` is used when `form` is not set, and only then.
    func substituting(_ substitutions: [(token: String, value: String)], in parts: Parts) -> OutgoingCall {
        var call = self
        for (token, value) in substitutions {
            if parts.contains(.url) { call.url = call.url.replacingFirst(token, with: value) }
            if parts.contains(.form), let form = call.form {
                call.form = form.replacingFirst(token, with: value)
            } else if parts.contains(.body), let body = call.body {
                call.body = body.replacingFirst(token, with: value)
            }
        }
        return call
    }

    /// Only these methods carry a body, written exactly so (as the Homebridge plugin compares them).
    var sendsBody: Bool { ["POST", "PUT", "PATCH"].contains(method) }

    enum Failure: Error, CustomStringConvertible {
        case invalidURL
        case invalidJSON(String)
        case status(Int)

        var description: String {
            switch self {
            case .invalidURL: "the URL is not valid"
            case .invalidJSON(let key): "\(key) is not a JSON object"
            case .status(let status): "it answered \(status)"
            }
        }
    }

    /// The request this call makes: the method, the headers of `headers`, the form or the body when the method takes one,
    /// and the URL's user name and password as Basic authentication.
    func request(timeout: Duration) throws -> HTTPRequest {
        guard var components = URLComponents(string: url) ?? Self.lenientComponents(url) else { throw Failure.invalidURL }
        var request = HTTPRequest(method: method, url: URL(string: "http://placeholder")!, timeout: timeout)
        if let user = components.user {
            // URLComponents gives them decoded already.
            let credentials = "\(user):\(components.password ?? "")"
            request.setHeader("Authorization", "Basic \(Data(credentials.utf8).base64EncodedString())")
            components.user = nil
            components.password = nil
        }
        guard let target = components.url, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https", target.host?.isEmpty == false else {
            throw Failure.invalidURL
        }
        request.url = target
        if let headers, !headers.isEmpty {
            guard let object = (try? JSONValue(string: headers))?.objectValue else { throw Failure.invalidJSON("headers") }
            for (name, value) in object.sorted(by: { $0.key < $1.key }) {
                request.setHeader(name, Self.text(value))
            }
        }
        if sendsBody {
            if let form, !form.isEmpty {
                guard let object = (try? JSONValue(string: form))?.objectValue else { throw Failure.invalidJSON("form") }
                request.body = Data(URLEncoding.query(object.sorted { $0.key < $1.key }.map { ($0.key, Self.text($0.value)) }).utf8)
                request.setHeader("Content-Type", "application/x-www-form-urlencoded")
            } else if let body, !body.isEmpty {
                request.body = Data(body.utf8)
            }
        }
        return request
    }

    /// The names of the headers `headers` gives, lowercased.
    var headerNames: Set<String> {
        guard let headers, let object = (try? JSONValue(string: headers))?.objectValue else { return [] }
        return Set(object.keys.map { $0.lowercased() })
    }

    /// A header or form value as JavaScript turns it into text.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): Format.number(number)
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        case .array, .object: value.text()
        }
    }

    /// A URL the strict parser refuses (a space, braces in a query): its unsafe characters percent-encoded.
    private static func lenientComponents(_ url: String) -> URLComponents? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return url.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URLComponents.init(string:))
    }

    /// The URL for a log line: its scheme, host and port only. The user, password, query and path stay out: webhook
    /// services put their keys in them (IFTTT's `/with/key/<key>`, Home Assistant's `/api/webhook/<id>`).
    var logDescription: String {
        guard let components = URLComponents(string: url), let host = components.host else { return "(an invalid URL)" }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(method) \(components.scheme ?? "http")://\(host)\(port)"
    }
}

/// Makes the outgoing calls: one request per HomeKit write, within the call's timeout, redirects of a GET followed as
/// the Homebridge plugin's HTTP library does. Answers or throws `serviceCommunicationFailure` for HomeKit.
struct OutgoingCaller: Sendable {
    /// The client for a call: the system's roots when it verifies certificates, any certificate otherwise.
    var client: @Sendable (_ rejectUnauthorized: Bool) -> any HTTPSending
    var logger: Logger
    static let maximumRedirects = 5

    static let verifying = HTTPClient(tls: .system, maximumBodySize: 1024 * 1024)
    static let trusting = HTTPClient(tls: .any, maximumBodySize: 1024 * 1024)
    static let live: @Sendable (Bool) -> any HTTPSending = { $0 ? verifying : trusting }

    /// Sends `call`; throws for HomeKit when it fails (an invalid URL or JSON, no answer within `timeout`, a status other
    /// than 2xx). `name` is the accessory's, for the log.
    func send(_ call: OutgoingCall, timeout: Duration, name: String) async throws {
        let client = client(call.rejectUnauthorized)
        let deadline = ContinuousClock.now + timeout
        do {
            var request = try call.request(timeout: timeout)
            var redirects = 0
            while true {
                let response = try await client.send(request)
                if ["GET", "HEAD"].contains(request.method.uppercased()), [301, 302, 303, 307, 308].contains(response.status), redirects < Self.maximumRedirects,
                    let location = response.header("Location"), let next = URL(string: location, relativeTo: request.url)?.absoluteURL,
                    ["http", "https"].contains(next.scheme?.lowercased() ?? "")
                {
                    redirects += 1
                    let remaining = deadline - ContinuousClock.now
                    guard remaining > .zero else { throw HTTPClientError.timeout }
                    // Credentials and the entry's own headers (API keys) stay with the host they were given for, and off
                    // a plain-HTTP hop.
                    if !Self.sameOrigin(request.url, next) || Self.downgrades(request.url, to: next) {
                        let dropped = call.headerNames.union(["authorization"])
                        request.headers.removeAll { dropped.contains($0.name.lowercased()) }
                    }
                    request.url = next
                    request.timeout = remaining
                    continue
                }
                logger.info("\(name): \(call.logDescription) answered \(response.status)")
                guard response.isSuccess else { throw OutgoingCall.Failure.status(response.status) }
                return
            }
        } catch {
            logger.warning("\(name): \(call.logDescription) failed: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }
}

extension OutgoingCaller {
    /// The same scheme, host and port: where a redirect may keep a call's credentials and headers.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int?) {
            let scheme = url.scheme?.lowercased() ?? ""
            return (scheme, url.host?.lowercased() ?? "", url.port ?? (scheme == "https" ? 443 : 80))
        }
        return origin(lhs) == origin(rhs)
    }

    static func downgrades(_ from: URL, to: URL) -> Bool {
        from.scheme?.lowercased() == "https" && to.scheme?.lowercased() == "http"
    }
}

extension String {
    /// The string with the first occurrence of `token` replaced, or as it is without one.
    func replacingFirst(_ token: String, with value: String) -> String {
        guard !token.isEmpty, let range = range(of: token) else { return self }
        return replacingCharacters(in: range, with: value)
    }
}
