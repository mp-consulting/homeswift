import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

@testable import HomeswiftWingman

/// Wingman in memory, answering as its LocalServer does: `/info` and `/pair` open, the rest behind the token; a home
/// with a colour light (Matter, through a Hue bridge), a switch on a Homeswift bridge (left out), a temperature
/// sensor that does not respond and a lock.
final class FakeWingman: WingmanTransportFactory, @unchecked Sendable {
    static let fingerprint = String(repeating: "3f9a0c71", count: 8)
    static let token = "token-1"
    static let code = "482913"

    struct Write: Equatable {
        var accessory: String
        var characteristic: String
        var value: String
    }

    private struct State {
        var events: [[String: Any]] = []
        var seq = 0
        var writes: [Write] = []
        var tls: [HTTPClient.TLS] = []
        var tokenValid = true
        var reachable = true
    }

    private let state = NIOLockedValueBox(State())

    var writes: [Write] { state.withLockedValue { $0.writes } }
    var tlsModes: [HTTPClient.TLS] { state.withLockedValue { $0.tls } }

    /// A value change HomeKit pushed, as Wingman reports it.
    func push(accessory: String, characteristic: String, type: String, value: Any) {
        state.withLockedValue { state in
            state.seq += 1
            state.events.append(["seq": state.seq, "accessoryID": accessory, "characteristicID": characteristic, "type": type, "value": value])
        }
    }

    /// Wingman's menu removed this bridge.
    func forgetBridge() { state.withLockedValue { $0.tokenValid = false } }

    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending {
        state.withLockedValue { $0.tls.append(tls) }
        return Transport(wingman: self)
    }

    struct Transport: HTTPSending {
        let wingman: FakeWingman
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await wingman.answer(request)
        }
    }

    private func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object), certificateFingerprint: Self.fingerprint)
    }

    func answer(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch (request.method, path) {
        case ("GET", "/info"):
            return json(["service": "homeswift-wingman", "api": "1", "id": "wm-1", "version": "0.2.0", "fingerprint": Self.fingerprint, "pairing": true])
        case ("POST", "/pair"):
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            guard body?["code"] as? String == Self.code else { return json(["error": "wrong code"], status: 403) }
            return json(["token": Self.token, "bridge": "b-1", "wingman": "wm-1", "fingerprint": Self.fingerprint])
        default: break
        }
        let authorized = request.headers.contains { $0.name == "Authorization" && $0.value == "Bearer \(Self.token)" }
        guard authorized, state.withLockedValue({ $0.tokenValid }) else { return json(["error": "pair first"], status: 401) }
        switch (request.method, path) {
        case ("GET", "/homes"):
            return json(["homes": [Self.home]])
        case ("GET", "/events"):
            let since = Int(query["since"] ?? "") ?? 0
            let wait = Double(query["wait"] ?? "") ?? 0
            var answer = state.withLockedValue { state in (state.events.filter { ($0["seq"] as? Int ?? 0) > since }, state.seq) }
            if answer.0.isEmpty, wait > 0 {
                // A short wait stands for the long-poll.
                try await Task.sleep(for: .milliseconds(50))
                answer = state.withLockedValue { state in (state.events.filter { ($0["seq"] as? Int ?? 0) > since }, state.seq) }
            }
            return json(["events": answer.0, "last": answer.1])
        case ("POST", "/write"):
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
            let write = Write(accessory: body["accessory"] as? String ?? "", characteristic: body["characteristic"] as? String ?? "", value: "\(body["value"] ?? "")")
            state.withLockedValue { $0.writes.append(write) }
            if write.characteristic == "light-saturation" { return HTTPResponse(status: 500, body: Data()) }
            if write.characteristic == "lock-target" {
                return json(["error": "Lock Target State is a security control; not written through Wingman"], status: 422)
            }
            return json(["written": body["value"] ?? NSNull()])
        default:
            return json(["error": "not found"], status: 404)
        }
    }

    static let lightbulb = "00000043-0000-1000-8000-0026BB765291"

    nonisolated(unsafe) static let home: [String: Any] = [
        "id": "home-1", "name": "Maison",
        "accessories": [
            [
                "id": "light-1", "name": "Plafonnier", "room": "Salon", "reachable": true, "manufacturer": "Signify", "model": "Hue color", "matter": true,
                "bridge": ["id": "hue-bridge", "name": "Hue Bridge", "manufacturer": "Signify"],
                "services": [
                    ["id": "info-1", "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": [
                        ["id": "c-name", "type": "00000023-0000-1000-8000-0026BB765291", "properties": ["read"], "value": "Plafonnier", "format": "string"],
                    ]],
                    ["id": "bulb-1", "name": "Plafonnier", "type": lightbulb, "primary": true, "characteristics": [
                        ["id": "light-on", "type": "00000025-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 1, "format": "bool"],
                        ["id": "light-brightness", "type": "00000008-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 40, "format": "int", "min": 0, "max": 100, "step": 1],
                        ["id": "light-hue", "type": "00000013-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 30, "format": "float", "min": 0, "max": 360],
                        ["id": "light-saturation", "type": "0000002F-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 80, "format": "float"],
                        ["id": "light-ct", "type": "000000CE-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 300, "format": "int", "min": 153, "max": 454, "step": 1],
                    ]],
                ],
            ],
            [
                "id": "homeswift-switch", "name": "Plug from Homeswift", "room": "Bureau", "reachable": true, "manufacturer": "Meross",
                "bridge": ["id": "homeswift-bridge", "name": "Homeswift", "manufacturer": "Homeswift", "model": "Homeswift"],
                "services": [
                    ["id": "switch-1", "type": "00000049-0000-1000-8000-0026BB765291", "characteristics": [
                        ["id": "switch-on", "type": "00000025-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 0, "format": "bool"],
                    ]],
                ],
            ],
            [
                "id": "sensor-1", "name": "Thermomètre", "room": "Cave", "reachable": false, "manufacturer": "Eve",
                "services": [
                    ["id": "temp-1", "type": "0000008A-0000-1000-8000-0026BB765291", "primary": true, "characteristics": [
                        ["id": "temp", "type": "00000011-0000-1000-8000-0026BB765291", "properties": ["read", "events"], "value": 12.5, "format": "float", "min": -100, "max": 100, "step": 0.1],
                    ]],
                ],
            ],
            [
                "id": "lock-1", "name": "Porte", "room": "Entrée", "reachable": true, "manufacturer": "Nuki",
                "services": [
                    ["id": "lock-service", "type": "00000045-0000-1000-8000-0026BB765291", "primary": true, "characteristics": [
                        ["id": "lock-current", "type": "0000001D-0000-1000-8000-0026BB765291", "properties": ["read", "events"], "value": 1, "format": "uint8"],
                        ["id": "lock-target", "type": "0000001E-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 1, "format": "uint8"],
                    ]],
                ],
            ],
        ],
    ]
}
