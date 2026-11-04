import Foundation
import HomeswiftPlugin

/// A device as `devices.list` and `devices.get` answer it (section 3.4): its resource name, type and traits, and the room
/// it is in.
struct SDMDevice: Sendable, Equatable {
    enum Kind: String, Sendable {
        case thermostat = "sdm.devices.types.THERMOSTAT"
        case camera = "sdm.devices.types.CAMERA"
        case doorbell = "sdm.devices.types.DOORBELL"
        case display = "sdm.devices.types.DISPLAY"

        /// The suffix of its name, its model and its Device Kind.
        var suffix: String {
            switch self {
            case .thermostat: "Thermostat"
            case .camera: "Camera"
            case .doorbell: "Doorbell"
            case .display: "Display"
            }
        }
    }

    /// `enterprises/{projectId}/devices/{deviceId}`: the Device Id.
    var name: String
    var type: String
    var traits: [String: JSONValue]
    /// The first parent relation's `displayName`: the room, or a name the person gave.
    var room: String?

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        type = json["type"]?.stringValue ?? ""
        traits = json["traits"]?.objectValue ?? [:]
        room = json["parentRelations"]?.arrayValue?.lazy.compactMap { $0["displayName"]?.stringValue.nonEmptyText }.first
    }

    var kind: Kind? { Kind(rawValue: type) }

    /// "Hallway Thermostat", or `Unknown` without a room (section 5.0).
    var displayName: String {
        guard let room, let kind else { return "Unknown" }
        return "\(room) \(kind.suffix)"
    }

    /// The device's own id, the last part of its resource name: its serial number in Accessory Information.
    var shortID: String { name.split(separator: "/").last.map(String.init) ?? name }

    func trait(_ name: String) -> JSONValue? { traits["sdm.devices.traits.\(name)"] }

    /// A camera whose live view is WebRTC (2021 and later Nest Cams and Doorbells); RTSP otherwise, without the trait too.
    var isWebRTC: Bool {
        trait("CameraLiveStream")?["supportedProtocols"]?.arrayValue?.contains("WEB_RTC") ?? false
    }

    /// A trait event: each trait's fields over the cached ones, field by field, so an event that carries only the field
    /// that changed (a setpoint's `heatCelsius`) keeps the others. (The Homebridge plugin replaces a trait wholesale.)
    mutating func apply(_ update: [String: JSONValue]) {
        for (key, value) in update {
            if let old = traits[key]?.objectValue, let new = value.objectValue {
                traits[key] = .object(old.merging(new) { $1 })
            } else {
                traits[key] = value
            }
        }
    }
}

/// A Pub/Sub event (section 4.2): a trait update, device events, or a relation update the plugin ignores.
struct SDMEvent: Sendable {
    var resource: String?
    var timestamp: Date?
    var traits: [String: JSONValue]?
    var events: [String: JSONValue]?
    /// `STARTED`, `UPDATED`, `ENDED`, or nil.
    var threadState: String?

    init(data: Data) throws {
        let json = try JSONValue(data: data)
        let update = json["resourceUpdate"]
        resource = update?["name"]?.stringValue
        traits = update?["traits"]?.objectValue
        events = update?["events"]?.objectValue
        threadState = json["eventThreadState"]?.stringValue
        timestamp = json["timestamp"]?.stringValue.flatMap(Self.date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// More than 30 seconds old; an event without a timestamp is fresh.
    func isStale(now: Date) -> Bool {
        guard let timestamp else { return false }
        return now.timeIntervalSince(timestamp) > 30
    }
}
