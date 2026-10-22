import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The HTTP API of Elgato lights: JSON over port 9123, under /elgato/.

/// `GET /elgato/accessory-info`.
struct KeyLightInfo: Codable, Sendable, Equatable {
    var productName: String?
    var hardwareBoardType: Int?
    var firmwareBuildNumber: Int?
    var firmwareVersion: String?
    var serialNumber: String?
    var displayName: String?
    var features: [String]?
    /// Current firmware reports it; older lights leave it out.
    var macAddress: String?
}

/// One light in `GET` and `PUT /elgato/lights`. Only the keys sent are changed, so each is optional.
struct LightState: Codable, Sendable, Equatable {
    /// 0 or 1.
    var on: Int?
    /// 0...100.
    var brightness: Int?
    /// Mirek, 143 (7000 K) to 344 (2900 K); the light may report values just outside.
    var temperature: Int?

    static let temperatureRange = 143...344

    static func clamp(temperature: Int) -> Int {
        min(max(temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
    }

    /// `self` with the keys `other` sets.
    func merging(_ other: LightState) -> LightState {
        LightState(on: other.on ?? on, brightness: other.brightness ?? brightness, temperature: other.temperature ?? temperature)
    }
}

struct LightsPayload: Codable, Sendable, Equatable {
    var numberOfLights: Int?
    var lights: [LightState]
}

/// `GET` and `PUT /elgato/lights/settings`: power-on behaviour and transitions.
struct KeyLightSettings: Codable, Sendable, Equatable {
    /// 1 restores the last settings, 2 the defaults below.
    var powerOnBehavior: Int?
    var powerOnBrightness: Int?
    /// Mirek.
    var powerOnTemperature: Int?
    var switchOnDurationMs: Int?
    var switchOffDurationMs: Int?
    var colorChangeDurationMs: Int?
}

struct KeyLightRequest: Sendable {
    var method: String
    var url: URL
    var body: Data?
    var timeout: TimeInterval
}

struct KeyLightResponse: Sendable {
    var status: Int
    var body: Data
}

/// How requests reach a light. Tests replace it with a fake light.
protocol KeyLightTransport: Sendable {
    func send(_ request: KeyLightRequest) async throws -> KeyLightResponse
}

struct URLSessionTransport: KeyLightTransport {
    func send(_ request: KeyLightRequest) async throws -> KeyLightResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        return KeyLightResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

enum KeyLightError: Error, CustomStringConvertible, Equatable {
    case invalidAddress(host: String, port: Int)
    case httpStatus(Int)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .invalidAddress(let host, let port): "cannot build a URL for \(host):\(port)"
        case .httpStatus(let status): "HTTP \(status)"
        case .invalidResponse(let detail): "unexpected response: \(detail)"
        }
    }
}

/// The API of one light.
struct KeyLightClient: Sendable {
    static let defaultPort = 9123
    static let requestTimeout: TimeInterval = 5

    var host: String
    var port: Int
    let transport: any KeyLightTransport

    var baseURL: URL? {
        guard Self.isValidHost(host), Self.isValidPort(port) else { return nil }
        // IPv6 literals must be bracketed inside a URL.
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)/elgato/")
    }

    /// An IP literal or a DNS host name: nothing that could smuggle a path or query into the URL.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == ":"
        }
    }

    static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    func info() async throws -> KeyLightInfo {
        try await get("accessory-info", timeout: Self.requestTimeout)
    }

    func lights(timeout: TimeInterval = requestTimeout) async throws -> LightsPayload {
        try await get("lights", timeout: timeout)
    }

    /// Sends only the keys set in `state`; the light keeps the others.
    func setLight(_ state: LightState) async throws {
        _ = try await send("PUT", "lights", body: LightsPayload(numberOfLights: 1, lights: [state]))
    }

    func settings() async throws -> KeyLightSettings {
        try await get("lights/settings", timeout: Self.requestTimeout)
    }

    func updateSettings(_ settings: KeyLightSettings) async throws {
        _ = try await send("PUT", "lights/settings", body: settings)
    }

    /// Flashes the light.
    func identify() async throws {
        _ = try await send("POST", "identify", body: nil as Data?)
    }

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval) async throws -> T {
        let response = try await send("GET", path, body: nil as Data?, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw KeyLightError.invalidResponse("\(path): \(error)")
        }
    }

    private func send(_ method: String, _ path: String, body: (some Encodable)?, timeout: TimeInterval = requestTimeout) async throws -> KeyLightResponse {
        guard let url = baseURL?.appendingPathComponent(path) else {
            throw KeyLightError.invalidAddress(host: host, port: port)
        }
        let data = try body.map { try JSONEncoder().encode($0) }
        let response = try await transport.send(KeyLightRequest(method: method, url: url, body: data, timeout: timeout))
        guard (200..<300).contains(response.status) else { throw KeyLightError.httpStatus(response.status) }
        return response
    }
}
