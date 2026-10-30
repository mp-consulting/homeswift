import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// An IKEA DIRIGERA hub's local API: `https://<hub>:8443/v1`, a bearer token from pairing (OAuth 2 with PKCE: the
/// hub's action button approves it), devices read and changed with `PATCH /v1/devices/<id>`, scenes triggered and
/// undone, and changes pushed over a websocket at the same address. The hub's certificate is IKEA's own, pinned on
/// first use. As Leggin/dirigera and lpgera/dirigera do.
actor DirigeraClient {
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// The token request before the action button was pressed (403).
        case buttonNotPressed
        case unauthorized
        case status(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .buttonNotPressed: "the action button on the DIRIGERA hub was not pressed"
            case .unauthorized: "the DIRIGERA hub refused the token: pair again"
            case .status(let code, let message): "the DIRIGERA hub answered \(code)\(message.isEmpty ? "" : ": \(message)")"
            case .malformed(let what): "the DIRIGERA hub sent \(what) this plugin cannot read"
            }
        }
    }

    static let port = 8443
    let host: String
    private(set) var token: String?
    private let transport: any HTTPSending

    init(host: String, token: String?, transport: any HTTPSending) {
        self.host = host
        self.token = token
        self.transport = transport
    }

    func setToken(_ token: String?) { self.token = token }

    var baseURL: String { "https://\(Self.hostForURL(host)):\(Self.port)/v1" }

    // MARK: Pairing

    /// A PKCE verifier: 128 characters of `[A-Za-z0-9]`, as homebridge-dirigera makes them.
    static func makeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String(Secrets.randomBytes(128).map { alphabet[Int($0) % alphabet.count] })
    }

    /// `base64url(SHA256(verifier))` without padding.
    static func challenge(for verifier: String) -> String {
        Secrets.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Step 1: a code for this verifier.
    func authorize(verifier: String) async throws -> String {
        let query = "audience=homesmart.local&response_type=code&code_challenge=\(Self.challenge(for: verifier))&code_challenge_method=S256"
        let response = try await send("GET", "/oauth/authorize?\(query)", authenticated: false)
        guard let code = try JSONValue(data: response.body)["code"]?.stringValue, !code.isEmpty else { throw Failure.malformed("an authorization code") }
        return code
    }

    /// Step 2, once the action button was pressed: the token. Throws `buttonNotPressed` before.
    func token(code: String, verifier: String, name: String) async throws -> String {
        let form = [("code", code), ("name", name), ("grant_type", "authorization_code"), ("code_verifier", verifier)]
            .map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&")
        let response = try await send("POST", "/oauth/token", body: Data(form.utf8), contentType: "application/x-www-form-urlencoded", authenticated: false, accept: [200, 403])
        if response.status == 403 { throw Failure.buttonNotPressed }
        guard let token = try JSONValue(data: response.body)["access_token"]?.stringValue, !token.isEmpty else { throw Failure.malformed("a token") }
        self.token = token
        return token
    }

    // MARK: Devices and scenes

    func devices() async throws -> [JSONValue] {
        guard let list = try await JSONValue(data: send("GET", "/devices").body).arrayValue else { throw Failure.malformed("a device list") }
        return list
    }

    func scenes() async throws -> [JSONValue] {
        guard let list = try await JSONValue(data: send("GET", "/scenes").body).arrayValue else { throw Failure.malformed("a scene list") }
        return list
    }

    /// `PATCH /v1/devices/<id>` with `[{"attributes": …, "transitionTime": ms}]`.
    func patch(deviceID: String, attributes: JSONValue, transitionMs: Int? = nil) async throws {
        var change: [String: JSONValue] = ["attributes": attributes]
        if let transitionMs { change["transitionTime"] = .number(Double(transitionMs)) }
        _ = try await send("PATCH", "/devices/\(Self.segment(deviceID))", body: JSONValue.array([.object(change)]).encoded(), contentType: "application/json")
    }

    func trigger(sceneID: String) async throws {
        _ = try await send("POST", "/scenes/\(Self.segment(sceneID))/trigger")
    }

    func undo(sceneID: String) async throws {
        _ = try await send("POST", "/scenes/\(Self.segment(sceneID))/undo")
    }

    func identify(deviceID: String) async throws {
        _ = try await send("PUT", "/devices/\(Self.segment(deviceID))/identify", body: JSONValue.object(["period": 5]).encoded(), contentType: "application/json")
    }

    // MARK: Sending

    private func send(
        _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, authenticated: Bool = true, accept: Set<Int> = []
    ) async throws -> HTTPResponse {
        guard let url = URL(string: baseURL + path) else { throw HTTPClientError.invalidURL(host) }
        var headers: [(name: String, value: String)] = [("Accept", "application/json")]
        if authenticated {
            guard let token else { throw Failure.unauthorized }
            headers.append(("Authorization", "Bearer \(token)"))
        }
        if let contentType { headers.append(("Content-Type", contentType)) }
        let response = try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: .seconds(10)))
        if accept.contains(response.status) || (200..<300).contains(response.status) { return response }
        if authenticated, response.status == 401 || response.status == 403 { throw Failure.unauthorized }
        throw Failure.status(response.status, logExcerpt(String(decoding: response.body, as: UTF8.self)) ?? "")
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// An id as one path segment: `/`, `?`, `#`, `%` and `..` cannot reach another of the hub's paths.
    static func segment(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func hostForURL(_ host: String) -> String {
        host.filter { $0 == ":" }.count > 1 && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

/// `HTTPClient` with the hub's certificate pinned once seen.
struct PinningTransport: HTTPSending {
    let trust: HTTPClient.TrustOnFirstUse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await trust.client.send(request)
        trust.observe(response.certificateFingerprint)
        return response
    }
}

/// The hub's events: its websocket's messages as JSON, for as long as it stays open.
enum DirigeraEvents {
    @Sendable static func connect(host: String, token: String, tls: HTTPClient.TLS) async throws -> AsyncThrowingStream<JSONValue, any Error> {
        guard let url = URL(string: "wss://\(DirigeraClient.hostForURL(host)):\(DirigeraClient.port)/v1") else { throw HTTPClientError.invalidURL(host) }
        // The hub closes idle connections: a ping every 30 s keeps it open, and a silent one is noticed.
        let options = WebSocket.Options(headers: [("Authorization", "Bearer \(token)")], tls: TLSOptions(tls), heartbeat: .seconds(30))
        let socket = try await WebSocket.connect(to: url, options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in socket.messages {
                        if let text = message.text, let event = try? JSONValue(string: text) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await socket.close() }
            }
        }
    }
}

/// Finds DIRIGERA hubs over mDNS (`_ihsp._tcp`).
enum DirigeraDiscovery {
    @Sendable static func find() async -> [String] {
        guard let answers = try? await MDNSQuery.query("_ihsp._tcp.local", duration: .seconds(3)) else { return [] }
        var seen: Set<String> = []
        return answers.map(\.sender).filter { seen.insert($0).inserted }
    }
}
