import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// A UPnP service of a zone player: the root device's (`ZonePlayer`) or one of its `MediaRenderer` or `MediaServer`
/// sub-devices'.
enum UPnPService: String, Sendable, CaseIterable {
    case alarmClock = "AlarmClock"
    case deviceProperties = "DeviceProperties"
    case zoneGroupTopology = "ZoneGroupTopology"
    case avTransport = "AVTransport"
    case groupRenderingControl = "GroupRenderingControl"
    case renderingControl = "RenderingControl"
    case contentDirectory = "ContentDirectory"

    var device: String? {
        switch self {
        case .alarmClock, .deviceProperties, .zoneGroupTopology: nil
        case .avTransport, .groupRenderingControl, .renderingControl: "MediaRenderer"
        case .contentDirectory: "MediaServer"
        }
    }

    var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
    private var base: String { device.map { "/\($0)/\(rawValue)" } ?? "/\(rawValue)" }
    var controlPath: String { "\(base)/Control" }
    var eventPath: String { "\(base)/Event" }

    /// The service an event path names (`/MediaRenderer/AVTransport/Event`).
    init?(eventPath: String) {
        guard let service = Self.allCases.first(where: { $0.eventPath == eventPath }) else { return nil }
        self = service
    }
}

enum SonosError: Error, CustomStringConvertible, Equatable {
    case http(Int, String)
    case soapFault(action: String, code: String?)
    case badResponse(String)
    case addressMismatch(expected: String, found: String)
    case noCoordinator

    var description: String {
        switch self {
        case .http(let status, let what): "\(what): HTTP status \(status)"
        case .soapFault(let action, let code): "\(action): SOAP fault\(code.map { " \($0)" } ?? "")"
        case .badResponse(let what): "unexpected response: \(what)"
        case .addressMismatch(let expected, let found): "address mismatch: expected \(expected), found \(found)"
        case .noCoordinator: "no group coordinator"
        }
    }
}

enum SOAP {
    /// The request body: an envelope around `u:<action>` with one element per argument, in order, its value as given
    /// (URIs and metadata come escaped already).
    static func envelope(service: UPnPService, action: String, arguments: [(String, String)]) -> String {
        let inner = arguments.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
            + #"<u:\#(action) xmlns:u="\#(service.urn)">\#(inner)</u:\#(action)></s:Body></s:Envelope>"#
    }

    /// The fields of `u:<action>Response`, by name; a fault (any `Fault` in the body) throws.
    static func response(_ body: Data, action: String) throws -> [String: String] {
        let root = try XML.parse(String(decoding: body, as: UTF8.self))
        if let fault = root.first("Fault") {
            throw SonosError.soapFault(action: action, code: fault.first("errorCode")?.text)
        }
        guard let response = root.first("\(action)Response") else { throw SonosError.badResponse("no \(action)Response") }
        var fields: [String: String] = [:]
        for child in response.children { fields[child.localName] = child.text }
        return fields
    }
}

/// One zone player's HTTP side: SOAP actions, GENA subscriptions and its device description, always to its IP on
/// port 1400. The address follows the player when it moves (a discovery or topology entry says so).
final class PlayerClient: Sendable {
    let id: String
    private let http: any HTTPSending
    private let timeout: Duration
    private let state: NIOLockedValueBox<(address: String, lastSeen: Date?)>

    init(id: String, address: String, http: any HTTPSending, timeout: Duration) {
        self.id = id
        self.http = http
        self.timeout = timeout
        state = NIOLockedValueBox((address, nil))
    }

    var address: String { state.withLockedValue { $0.address } }
    var lastSeen: Date? { state.withLockedValue { $0.lastSeen } }

    /// Moves the client to a new address; true when it changed.
    @discardableResult
    func move(to address: String) -> Bool {
        state.withLockedValue { state in
            guard state.address != address else { return false }
            state.address = address
            return true
        }
    }

    /// Any message from the player: a response, an event, an SSDP or mDNS announcement.
    func seen(at date: Date = Date()) {
        state.withLockedValue { $0.lastSeen = date }
    }

    private func url(_ path: String) -> URL {
        // An IPv4 address or a host name; Sonos refuses requests addressed by name, so discovery gives addresses.
        URL(string: "http://\(address):1400\(path)")!
    }

    private func send(_ method: String, _ path: String, headers: [(String, String)], body: Data? = nil) async throws -> HTTPResponse {
        let request = HTTPRequest(method: method, url: url(path), headers: headers.map { (name: $0.0, value: $0.1) }, body: body, timeout: timeout)
        let response = try await http.send(request)
        seen()
        return response
    }

    /// Calls a SOAP action and answers its response's fields.
    @discardableResult
    func call(_ service: UPnPService, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        let body = SOAP.envelope(service: service, action: action, arguments: arguments)
        let response = try await send("POST", service.controlPath, headers: [
            ("SOAPaction", "\"\(service.urn)#\(action)\""), ("content-type", "text/xml; charset=utf-8"),
        ], body: Data(body.utf8))
        guard response.isSuccess || response.status == 500 else { throw SonosError.http(response.status, action) }
        return try SOAP.response(response.body, action: action)
    }

    /// `GET /xml/device_description.xml`.
    func deviceDescription() async throws -> DeviceDescription {
        let response = try await send("GET", "/xml/device_description.xml", headers: [])
        guard response.isSuccess else { throw SonosError.http(response.status, "device description") }
        return try DeviceDescription(xml: response.body)
    }

    struct Subscription: Sendable, Equatable {
        var sid: String
        /// The seconds the player granted.
        var timeout: Int?
    }

    /// A new subscription to `eventPath`, events sent to `callback`, for `seconds`.
    func subscribe(_ eventPath: String, callback: String, seconds: Int) async throws -> Subscription {
        let response = try await send("SUBSCRIBE", eventPath, headers: [("CALLBACK", "<\(callback)>"), ("NT", "upnp:event"), ("TIMEOUT", "Second-\(seconds)")])
        guard response.isSuccess, let sid = response.header("SID") else { throw SonosError.http(response.status, "SUBSCRIBE \(eventPath)") }
        return Subscription(sid: sid, timeout: Self.seconds(response.header("TIMEOUT")))
    }

    /// Renews a subscription; a 412 (the player forgot it) throws `SonosError.http(412, …)`.
    func renew(_ eventPath: String, sid: String, seconds: Int) async throws -> Subscription {
        let response = try await send("SUBSCRIBE", eventPath, headers: [("SID", sid), ("TIMEOUT", "Second-\(seconds)")])
        guard response.isSuccess else { throw SonosError.http(response.status, "renew \(eventPath)") }
        return Subscription(sid: response.header("SID") ?? sid, timeout: Self.seconds(response.header("TIMEOUT")))
    }

    func unsubscribe(_ eventPath: String, sid: String) async throws {
        let response = try await send("UNSUBSCRIBE", eventPath, headers: [("SID", sid)])
        guard response.isSuccess else { throw SonosError.http(response.status, "UNSUBSCRIBE \(eventPath)") }
    }

    /// `Second-1830` → 1830; `infinite` and anything else → nil.
    static func seconds(_ header: String?) -> Int? {
        guard let header, header.lowercased().hasPrefix("second-") else { return nil }
        return Int(header.dropFirst(7))
    }
}

/// What a player's `/xml/device_description.xml` says of it.
struct DeviceDescription: Sendable, Equatable {
    var id: String
    var modelName: String
    var modelNumber: String
    var displayVersion: String
    var roomName: String
    var audioIn: Bool
    var tvIn: Bool

    init(id: String, modelName: String, modelNumber: String, displayVersion: String, roomName: String, audioIn: Bool = false, tvIn: Bool = false) {
        self.id = id
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.displayVersion = displayVersion
        self.roomName = roomName
        self.audioIn = audioIn
        self.tvIn = tvIn
    }

    init(xml: Data) throws {
        let root = try XML.parse(String(decoding: xml, as: UTF8.self))
        guard let device = root.child("device") ?? root.first("device"), let udn = device.value("UDN") else {
            throw SonosError.badResponse("device description without a UDN")
        }
        let parts = udn.split(separator: ":", omittingEmptySubsequences: false)
        id = parts.count > 1 ? String(parts[1]) : udn
        modelName = device.value("modelName") ?? ""
        modelNumber = device.value("modelNumber") ?? ""
        displayVersion = device.value("displayVersion") ?? ""
        roomName = device.value("roomName") ?? ""
        // The root device's own services: the fourth field of each serviceId.
        let ids = device.child("serviceList")?.children("service").compactMap { $0.value("serviceId") } ?? []
        let names = ids.map { $0.split(separator: ":", omittingEmptySubsequences: false) }.compactMap { $0.count > 3 ? String($0[3]) : nil }
        audioIn = names.contains("AudioIn")
        tvIn = names.contains("HTControl")
    }

    /// The first word of the model name: `Sonos`.
    var manufacturer: String { modelName.split(separator: " ").first.map(String.init) ?? "Sonos" }
    /// The second word of the model name and the model number: `One (S18)`.
    var model: String {
        let words = modelName.split(separator: " ")
        let name = words.count > 1 ? String(words[1]) : modelName
        return modelNumber.isEmpty ? name : "\(name) (\(modelNumber))"
    }
    /// S1 for firmware 11 and before, S2 after.
    var generation: String { (Int(displayVersion.split(separator: ".").first ?? "") ?? 12) <= 11 ? "S1" : "S2" }
}
