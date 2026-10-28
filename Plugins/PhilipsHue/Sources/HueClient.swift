import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// A Hue Bridge's local API v2 (CLIP v2) over HTTPS: `hue-application-key` on every request, the resources under
/// `/clip/v2/resource`, pairing still on v1's `POST /api`. The bridge serves a certificate of its own CA, pinned on first
/// use (`HTTPClient.TrustOnFirstUse`). It refuses more than three requests at a time with 429, so they wait their turn,
/// and 429 or 503 is retried a few times, as aiohue does.
actor HueClient {
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// `POST /api` before the link button was pressed (error type 101).
        case linkButtonNotPressed
        /// The application key was refused (403, or error type 1).
        case unauthorized
        case status(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .linkButtonNotPressed: "the link button on the Hue Bridge was not pressed"
            case .unauthorized: "the Hue Bridge refused the application key: pair again"
            case .status(let code, let message): "the Hue Bridge answered \(code)\(message.isEmpty ? "" : ": \(message)")"
            case .malformed(let what): "the Hue Bridge sent \(what) this plugin cannot read"
            }
        }
    }

    let host: String
    private(set) var applicationKey: String?
    private let transport: any HueTransport
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    static let maximumInFlight = 3
    static let retries = 4

    init(host: String, applicationKey: String?, transport: any HueTransport) {
        self.host = host
        self.applicationKey = applicationKey
        self.transport = transport
    }

    func setApplicationKey(_ key: String?) { applicationKey = key }

    // MARK: Pairing

    /// Asks for an application key: answers it once the link button was pressed, throws `linkButtonNotPressed` before.
    func pair(deviceType: String) async throws -> String {
        let body: JSONValue = ["devicetype": .string(String(deviceType.prefix(40))), "generateclientkey": true]
        let response = try await send("POST", "/api", body: body, authenticated: false)
        let reply = try JSONValue(data: response.body)
        guard let first = reply[0] else { throw Failure.malformed("a pairing answer") }
        if let error = first["error"] {
            if error["type"]?.intValue == 101 { throw Failure.linkButtonNotPressed }
            throw Failure.status(response.status, error["description"]?.stringValue ?? "")
        }
        guard let key = first["success"]?["username"]?.stringValue, !key.isEmpty else { throw Failure.malformed("a pairing answer") }
        applicationKey = key
        return key
    }

    /// The bridge's v1 configuration, readable without a key: its id (`bridgeid`), name and model.
    func configuration() async throws -> JSONValue {
        let response = try await send("GET", "/api/config", authenticated: false)
        return try JSONValue(data: response.body)
    }

    // MARK: Resources

    /// Every resource, as `GET /clip/v2/resource` answers: one request for a whole poll.
    func resources() async throws -> [JSONValue] {
        try await data(of: send("GET", "/clip/v2/resource"))
    }

    /// Changes a resource: `PUT /clip/v2/resource/<type>/<id>`.
    func put(_ type: String, id: String, _ body: JSONValue) async throws {
        _ = try await data(of: send("PUT", "/clip/v2/resource/\(type)/\(id)", body: body))
    }

    /// The bridge's event stream (`GET /eventstream/clip/v2`): each event's data is a JSON array of changes, each with
    /// a `type` (`update`, `add`, `delete`) and its resources' changed parts in `data`. It goes on until the connection
    /// drops; it does not count among the three requests in flight, which it would hold forever.
    func events() async throws -> HTTPStreamingResponse.Events {
        guard let url = URL(string: "https://\(Self.hostForURL(host))/eventstream/clip/v2") else { throw HTTPClientError.invalidURL(host) }
        guard let applicationKey else { throw Failure.unauthorized }
        let request = HTTPRequest(method: "GET", url: url, headers: [("Accept", "text/event-stream"), ("hue-application-key", applicationKey)], timeout: .seconds(10))
        let response = try await transport.stream(request)
        switch response.status {
        case 200..<300: return response.events
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.status(response.status, "")
        }
    }

    private func data(of response: HTTPResponse) throws -> [JSONValue] {
        let reply = try JSONValue(data: response.body)
        if let errors = reply["errors"]?.arrayValue, !errors.isEmpty {
            throw Failure.status(response.status, errors.compactMap { $0["description"]?.stringValue }.joined(separator: "; "))
        }
        guard let data = reply["data"]?.arrayValue else { throw Failure.malformed("an answer") }
        return data
    }

    // MARK: Sending

    private func send(_ method: String, _ path: String, body: JSONValue? = nil, authenticated: Bool = true) async throws -> HTTPResponse {
        guard let url = URL(string: "https://\(Self.hostForURL(host))\(path)") else { throw HTTPClientError.invalidURL(host) }
        var headers: [(name: String, value: String)] = [("Accept", "application/json")]
        if authenticated {
            guard let applicationKey else { throw Failure.unauthorized }
            headers.append(("hue-application-key", applicationKey))
        }
        if body != nil { headers.append(("Content-Type", "application/json")) }
        let request = HTTPRequest(method: method, url: url, headers: headers, body: body?.encoded(), timeout: .seconds(10))
        await acquire()
        defer { release() }
        var attempt = 0
        while true {
            let response = try await transport.send(request)
            switch response.status {
            case 200..<300: return response
            case 403 where authenticated, 401: throw Failure.unauthorized
            case 429 where attempt < Self.retries, 503 where attempt < Self.retries:
                attempt += 1
                try await Task.sleep(for: .milliseconds(250 * attempt))
            default:
                let message = (try? JSONValue(data: response.body))?["errors"]?.arrayValue?.compactMap { $0["description"]?.stringValue }.joined(separator: "; ") ?? ""
                throw Failure.status(response.status, message)
            }
        }
    }

    private func acquire() async {
        if inFlight < Self.maximumInFlight {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { inFlight -= 1 } else { waiting.removeFirst().resume() }
    }

    /// An IPv6 address in brackets; a name or IPv4 address as it is, with its port when it has one (`10.0.0.2:8443`).
    static func hostForURL(_ host: String) -> String {
        host.filter { $0 == ":" }.count > 1 && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

/// What the client talks to the bridge with: requests, and the event stream.
protocol HueTransport: HTTPSending, HTTPStreaming {}

/// `HTTPClient` with the bridge's certificate pinned once seen: the first connection takes any, the next only that one.
struct PinningTransport: HueTransport {
    let trust: HTTPClient.TrustOnFirstUse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await trust.client.send(request)
        trust.observe(response.certificateFingerprint)
        return response
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let response = try await trust.client.stream(request)
        trust.observe(response.certificateFingerprint)
        return response
    }
}
