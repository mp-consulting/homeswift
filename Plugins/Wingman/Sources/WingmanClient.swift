import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// What Wingman answers, as `homeswift-wingman`'s LocalServer writes it (API version 1).
enum WingmanAPI {
    struct Info: Decodable, Sendable, Equatable {
        var id: String
        var version: String?
        var pairing: Bool?
        /// "structure" when it serves rooms, scenes and automations (docs/apple-home-design.md).
        var features: [String]? = nil
        /// Whether its owner lets bridges edit them now (**Let bridges edit rooms, scenes and automations**).
        var structure: Bool? = nil

        var servesStructure: Bool { features?.contains("structure") == true }
    }

    struct Paired: Decodable, Sendable {
        var token: String
        var wingman: String?
    }

    struct Homes: Decodable, Sendable {
        var homes: [Home]
    }

    struct Home: Decodable, Sendable {
        var id: String? = nil
        var name: String
        /// Whether this Mac's user administers the home: HomeKit refuses structural edits otherwise.
        var editable: Bool? = nil
        var rooms: [Room]? = nil
        var accessories: [Accessory]
    }

    struct Room: Decodable, Sendable, Equatable {
        var id: String
        var name: String
    }

    struct Scenes: Decodable, Sendable {
        var scenes: [Scene]
    }

    /// An action set: a scene, or one of the four built in (`wakeUp`, `sleep`, `homeArrival`, `homeDeparture`).
    struct Scene: Decodable, Sendable, Equatable {
        var id: String
        var home: String
        var name: String
        var type: String?
        var builtIn: Bool?
        var actions: [Action]
        /// Actions Wingman cannot show (a shortcut, media): its actions are not replaced, which would drop them.
        var unsupported: Int?
    }

    /// A characteristic an action set writes.
    struct Action: Codable, Sendable, Equatable {
        var accessory: String
        var characteristic: String
        /// Its HAP UUID; not sent back.
        var type: String? = nil
        var value: JSONValue
    }

    struct Automations: Decodable, Sendable {
        var automations: [Automation]
    }

    struct Automation: Decodable, Sendable, Equatable {
        var id: String
        var home: String
        var name: String
        var enabled: Bool
        var lastFired: String?
        var trigger: Trigger
        var endEvents: [TriggerEvent]?
        var conditions: [Condition]?
        var scenes: [String]?
        var actions: [Action]?
        var unsupported: Int?
    }

    struct Trigger: Decodable, Sendable, Equatable {
        /// "time" (a timer, or a sunrise or sunset alone) or "event".
        var kind: String
        var time: Time?
        var events: [TriggerEvent]?
    }

    /// A clock time, or a sunrise or sunset with an offset, on weekdays (1 is Sunday).
    struct Time: Codable, Sendable, Equatable {
        var hour: Int? = nil
        var minute: Int? = nil
        var significant: String? = nil
        var offsetMinutes: Int? = nil
        var weekdays: [Int]? = nil
    }

    /// What starts or ends an event trigger.
    struct TriggerEvent: Decodable, Sendable, Equatable {
        /// "characteristic", "threshold", "presence", "location", "duration", "time" or "other".
        var kind: String
        var accessory: String?
        var characteristic: String?
        var type: String?
        var value: JSONValue?
        var min: Double?
        var max: Double?
        var who: String?
        var arriving: Bool?
        var seconds: Int?
        var time: Time?
        var text: String?
    }

    struct Condition: Decodable, Sendable, Equatable {
        /// "time", "characteristic", "presence" or "other".
        var kind: String
        var after: Time?
        var before: Time?
        var accessory: String?
        var characteristic: String?
        var type: String?
        var comparison: String?
        var value: JSONValue?
        var who: String?
        var home: Bool?
        var text: String?
    }

    struct Created: Decodable, Sendable {
        var id: String
    }

    struct Bridge: Decodable, Sendable, Equatable {
        var name: String
        var manufacturer: String?
        var model: String?
    }

    struct Accessory: Decodable, Sendable {
        var id: String
        var name: String
        var room: String?
        var reachable: Bool?
        var supportsIdentify: Bool? = nil
        var bridge: Bridge?
        var manufacturer: String?
        var model: String?
        var firmware: String?
        var services: [Service]

        /// The Serial Number of its Accessory Information, as HomeKit keeps it.
        var serialNumber: String? {
            services.first { HAPUUID($0.type) == ServiceType.accessoryInformation.uuid }?
                .characteristics.first { HAPUUID($0.type) == CharacteristicType.serialNumber.uuid }?.value?.stringValue
        }
    }

    struct Service: Decodable, Sendable {
        var id: String?
        var name: String?
        var type: String
        var description: String?
        var primary: Bool?
        var characteristics: [Characteristic]
    }

    struct Characteristic: Decodable, Sendable {
        var id: String?
        var type: String
        var description: String?
        /// "read", "write", "events", "hidden".
        var properties: [String]
        var value: JSONValue?
        var format: String?
        var units: String?
        var min: Double?
        var max: Double?
        var step: Double?
        var validValues: [Int]?
        var maxLength: Int?
    }

    struct Events: Decodable, Sendable {
        var events: [Event]
        var last: Int?
        /// The oldest event Wingman still keeps: a `since` before it missed some.
        var first: Int?
    }

    struct Event: Decodable, Sendable {
        var seq: Int?
        /// "homes" when accessories, rooms, names or reachability changed (no characteristic then); a value change
        /// has "value", or no kind from an older Wingman.
        var kind: String?
        var accessoryID: String?
        var characteristicID: String?
        var value: JSONValue?
    }

    /// An error answer's body.
    struct Failure: Decodable, Sendable {
        var error: String?
    }
}

enum WingmanError: Error, CustomStringConvertible, Equatable {
    /// Nothing answered, or the connection broke.
    case unreachable(String)
    /// Wingman's certificate is not the one pinned at pairing.
    case certificateMismatch
    /// The token was refused: Wingman forgot this bridge (removed from its menu).
    case unauthorized
    /// Wingman answered with an error: wrong code, pairing closed, a write it refused.
    case refused(status: Int, message: String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .unreachable(let detail): "cannot reach Wingman (\(detail))"
        case .certificateMismatch: "Wingman's certificate is not the one pinned when it was paired: pair it again, or something on the network intercepts the connection"
        case .unauthorized: "Wingman does not know this bridge any more (removed from its Paired Bridges): pair it again"
        case .refused(_, let message): message
        case .invalidResponse(let detail): "Wingman answered something unexpected (\(detail))"
        }
    }
}

/// Makes the HTTPS transport for a Wingman: the real client, or a fake in tests. A fresh one per TLS mode, since the
/// pin is learnt at discovery.
protocol WingmanTransportFactory: Sendable {
    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending
}

struct NetworkTransportFactory: WingmanTransportFactory {
    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending { HTTPClient(tls: tls) }
}

/// One Wingman's API over HTTPS. `token` is nil before pairing (`/info` and `/pair` need none).
struct WingmanClient: Sendable {
    let host: String
    let port: Int
    let token: String?
    let transport: any HTTPSending

    /// `fingerprint` pins the certificate; nil accepts any and reports it (discovery's `/info`).
    init(host: String, port: Int, token: String?, fingerprint: String?, transports: any WingmanTransportFactory) {
        self.host = host
        self.port = port
        self.token = token
        transport = transports.makeTransport(tls: fingerprint.map { .pinned($0) } ?? .any)
    }

    func info() async throws -> (info: WingmanAPI.Info, observedFingerprint: String?) {
        let response = try await send("GET", "info", timeout: .seconds(5))
        return (try decode(WingmanAPI.Info.self, response), response.certificateFingerprint)
    }

    func pair(code: String, name: String) async throws -> WingmanAPI.Paired {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        return try decode(WingmanAPI.Paired.self, try await send("POST", "pair", body: body, timeout: .seconds(10)))
    }

    func homes() async throws -> [WingmanAPI.Home] {
        try decode(WingmanAPI.Homes.self, try await send("GET", "homes", timeout: .seconds(20))).homes
    }

    /// The value changes after `since`, waiting up to `wait` seconds for one.
    func events(since: Int, wait: Int) async throws -> WingmanAPI.Events {
        try decode(WingmanAPI.Events.self, try await send("GET", "events?since=\(since)&wait=\(wait)", timeout: .seconds(Int64(wait) + 15)))
    }

    /// Writes a characteristic by its id; Wingman answers once HomeKit has (a refusal comes back as an error status).
    func write(accessory: String, characteristic: String, value: JSONValue) async throws {
        let body = try JSONEncoder().encode(["accessory": .string(accessory), "characteristic": .string(characteristic), "value": value] as JSONValue)
        _ = try await send("POST", "write", body: body, timeout: .seconds(15))
    }

    func scenes() async throws -> [WingmanAPI.Scene] {
        try decode(WingmanAPI.Scenes.self, try await send("GET", "scenes", timeout: .seconds(20))).scenes
    }

    func automations() async throws -> [WingmanAPI.Automation] {
        try decode(WingmanAPI.Automations.self, try await send("GET", "automations", timeout: .seconds(20))).automations
    }

    /// One of the structural edits (`rooms/rename`, `scenes/actions`, `automations/enable`…); Wingman answers once
    /// HomeKit has. Answers what Wingman did.
    @discardableResult
    func edit(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        let response = try await send("POST", path, body: body.encoded(), timeout: .seconds(20))
        return (try? JSONValue(data: response.body)) ?? .null
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, timeout: Duration) async throws -> HTTPResponse {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "https://\(address):\(port)/\(path)") else { throw WingmanError.unreachable("bad address \(host)") }
        var request = HTTPRequest(method: method, url: url, body: body, timeout: timeout)
        if body != nil { request.setHeader("Content-Type", "application/json") }
        if let token { request.setHeader("Authorization", "Bearer \(token)") }
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPClientError {
            if case .certificateMismatch = error { throw WingmanError.certificateMismatch }
            throw WingmanError.unreachable(error.description)
        } catch {
            throw WingmanError.unreachable("\(error)")
        }
        if response.status == 401 { throw WingmanError.unauthorized }
        guard response.isSuccess else {
            let message = (try? JSONDecoder().decode(WingmanAPI.Failure.self, from: response.body))?.error ?? "HTTP \(response.status)"
            throw WingmanError.refused(status: response.status, message: message)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw WingmanError.invalidResponse("\(error)")
        }
    }
}
