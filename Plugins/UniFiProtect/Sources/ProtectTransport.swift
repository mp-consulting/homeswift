import Foundation
import HomeswiftNetwork

/// What the plugin needs from the network, behind seams so tests drive a fake controller: HTTPS with a TLS
/// policy per request, WebSockets (`WebSocketConnection`) and MQTT (`MQTTConnection`).

/// HTTPS to a controller, with the TLS policy of each request: the system's roots (`verifyTls`), the pinned
/// certificate, or any certificate on first contact (its fingerprint comes back on the response).
protocol ProtectHTTPTransport: Sendable {
    func send(_ request: HTTPRequest, tls: HTTPClient.TLS) async throws -> HTTPResponse
}

/// The real transport: `HTTPClient`, one connection per request, as NIOSSL so a self-signed controller can be
/// pinned on Linux too.
struct NetworkHTTPTransport: ProtectHTTPTransport {
    /// The bootstrap of a large site runs to several megabytes.
    static let maximumBodySize = 64 * 1024 * 1024

    func send(_ request: HTTPRequest, tls: HTTPClient.TLS) async throws -> HTTPResponse {
        try await HTTPClient(tls: tls, maximumBodySize: Self.maximumBodySize).send(request)
    }
}

/// Opens a WebSocket (`WebSocket.connect`); tests answer with fakes.
typealias ProtectWebSocketFactory = @Sendable (URL, WebSocket.Options) async throws -> any WebSocketConnection

/// The broker URL a connection was made for could not be used.
enum ProtectMQTTURLError: Error, Equatable {
    case missingProtocol
    case unsupportedProtocol(String)
}

/// Validates a broker URL the way the Homebridge plugin's MQTT connection did.
enum MQTTBrokerURL {
    static let supportedSchemes: Set<String> = ["mqtt", "mqtts", "tcp", "ssl"]

    static func validate(_ url: String) throws -> URL {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), parsed.host != nil else {
            throw ProtectMQTTURLError.missingProtocol
        }
        guard supportedSchemes.contains(scheme) else { throw ProtectMQTTURLError.unsupportedProtocol(scheme + ":") }
        return parsed
    }
}
