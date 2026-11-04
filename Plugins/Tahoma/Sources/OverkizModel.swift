import Crypto
import Foundation
import HomeswiftAI
import HomeswiftPlugin

/// One device of the setup's listing (`GET /setup/devices`, docs/clean-room/Tahoma.md 4.2), the fields the plugin reads.
struct OverkizDevice: Sendable, Equatable {
    var deviceURL: String
    /// The cloud's UUID of the device; absent on the local API.
    var oid: String?
    var label: String
    var controllableName: String
    var uiClass: String
    var widgetName: String
    /// The command names the device takes.
    var commands: Set<String>
    /// The states it reported in the listing, by name, decoded by type (`OverkizState.value`).
    var states: [String: JSONValue]
    /// Whether it has a `states` list at all: an RTS motor has none.
    var hasStates: Bool
    var available: Bool

    /// The part of `controllableName` before the first `:` (`io`, `rts`, `zwave`).
    var protocolName: String {
        controllableName.split(separator: ":", maxSplits: 1).first.map(String.init) ?? controllableName
    }

    /// The part of `controllableName` after the last `:`.
    var uniqueName: String {
        controllableName.split(separator: ":").last.map(String.init) ?? controllableName
    }

    /// The component after `#`: 1 when there is none.
    var component: Int {
        guard let hash = deviceURL.lastIndex(of: "#") else { return 1 }
        return Int(deviceURL[deviceURL.index(after: hash)...]) ?? 1
    }

    var isMain: Bool { component == 1 }

    /// The gateway's PIN, the URL's host part (`io://1234-5678-9012/7654321`).
    var gatewayID: String? {
        guard let scheme = deviceURL.range(of: "://") else { return nil }
        let rest = deviceURL[scheme.upperBound...]
        return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    func has(_ command: String) -> Bool { commands.contains(command) }

    /// The Serial Number (4.2): the URL without what lies between its first and last `/`, at most 64 characters.
    var serialNumber: String {
        guard let first = deviceURL.firstIndex(of: "/"), let last = deviceURL.lastIndex(of: "/"), first < last else {
            return String(deviceURL.prefix(64))
        }
        return String((deviceURL[..<first] + deviceURL[deviceURL.index(after: last)...]).prefix(64))
    }

    /// homebridge-tahoma's accessory UUID (5.1), which a `devicesConfig` key may name: the `oid` when it is a UUID, else
    /// UUID v5 of the `oid` (or of the `deviceURL` without one) in the OID namespace. Homeswift's id is the deviceURL.
    var legacyUUID: String {
        if let oid, !oid.isEmpty {
            if let uuid = UUID(uuidString: oid) { return uuid.uuidString.lowercased() }
            return Self.uuidV5(oid)
        }
        return Self.uuidV5(deviceURL)
    }

    /// RFC 4122 UUID version 5 of `name` in the OID namespace (`6ba7b812-9dad-11d1-80b4-00c04fd430c8`), lowercase.
    static func uuidV5(_ name: String) -> String {
        let namespace: [UInt8] = [0x6B, 0xA7, 0xB8, 0x12, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4, 0x30, 0xC8]
        var bytes = Array(Insecure.SHA1.hash(data: namespace + Array(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

extension OverkizDevice {
    /// A device from its JSON; nil without a `deviceURL`. Everything else is optional: a cloud answers what it answers.
    init?(json: JSONValue) {
        guard let url = json["deviceURL"]?.stringValue, !url.isEmpty else { return nil }
        deviceURL = url
        oid = json["oid"]?.stringValue
        label = json["label"]?.stringValue ?? url
        controllableName = json["controllableName"]?.stringValue ?? ""
        let definition = json["definition"]
        uiClass = definition?["uiClass"]?.stringValue ?? json["uiClass"]?.stringValue ?? ""
        widgetName = definition?["widgetName"]?.stringValue ?? json["widget"]?.stringValue ?? ""
        commands = Set((definition?["commands"]?.arrayValue ?? []).compactMap { $0["commandName"]?.stringValue })
        let list = json["states"]?.arrayValue
        hasStates = !(list ?? []).isEmpty
        states = OverkizState.decode(list ?? [])
        available = json["available"]?.boolValue ?? true
    }

    static func list(_ json: JSONValue) -> [OverkizDevice] {
        (json.arrayValue ?? []).compactMap(OverkizDevice.init(json:))
    }
}

/// A state's value (4.2), decoded by its `type`: 1 integer, 2 float, 3 string, 6 boolean, 10 and 11 JSON. A number sent as
/// text (`{"type": 1, "value": "23247220"}`) becomes a number, and JSON sent as text is parsed.
enum OverkizState {
    static func decode(_ list: [JSONValue]) -> [String: JSONValue] {
        var states: [String: JSONValue] = [:]
        for item in list {
            guard let name = item["name"]?.stringValue, let value = item["value"] else { continue }
            states[name] = normalized(value, type: item["type"]?.intValue)
        }
        return states
    }

    static func normalized(_ value: JSONValue, type: Int?) -> JSONValue {
        switch (type, value) {
        case (1, .string(let text)), (2, .string(let text)):
            if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return .number(number) }
            return value
        case (6, .string(let text)):
            switch text.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return value
            }
        case (10, .string(let text)), (11, .string(let text)):
            return (try? JSONValue(string: text)) ?? value
        case (_, .number(let number)) where !number.isFinite:
            return .null
        default:
            return value
        }
    }
}

extension JSONValue {
    /// The value as a finite number: a JSON number, or numeric text.
    var number: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }

    /// The value as text, a number written without a fraction when it has none.
    var scalarText: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }
}

/// A command of an execution (4.4): its name and parameters, always an array.
struct OverkizCommand: Sendable, Equatable, CustomStringConvertible {
    var name: String
    var parameters: [JSONValue]

    init(_ name: String, _ parameters: [JSONValue] = []) {
        self.name = name
        self.parameters = parameters
    }

    init(_ name: String, _ parameter: JSONValue) {
        self.init(name, [parameter])
    }

    var json: JSONValue {
        ["type": 1, "name": .string(name), "parameters": .array(parameters)]
    }

    /// "<name>[<parameters as JSON>]", as the log says it.
    var description: String {
        parameters.isEmpty ? name : "\(name)\(JSONValue.array(parameters).text())"
    }
}

/// The states of an execution (4.3), with the plugin's own `TIMED_OUT`.
enum ExecutionState: String, Sendable, Equatable {
    case initialized = "INITIALIZED"
    case notTransmitted = "NOT_TRANSMITTED"
    case transmitted = "TRANSMITTED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case queuedGatewaySide = "QUEUED_GATEWAY_SIDE"
    case queuedServerSide = "QUEUED_SERVER_SIDE"
    case timedOut = "TIMED_OUT"
    case unknown = "UNKNOWN"

    init(text: String?) {
        self = text.flatMap(ExecutionState.init(rawValue:)) ?? .unknown
    }

    var isFinal: Bool { self == .completed || self == .failed || self == .timedOut }
}

/// What an action of an execution became: its state, and on a failure the server's `failureType`.
struct ExecutionUpdate: Sendable, Equatable {
    var state: ExecutionState
    var failureType: String?
    var execID: String
}

/// An event of `POST /events/<id>/fetch` (4.3), the three the plugin reads.
enum OverkizEvent: Sendable, Equatable {
    case deviceStateChanged(deviceURL: String, states: [String: JSONValue])
    case executionStateChanged(execID: String, newState: ExecutionState, final: Bool, failureType: String?, failedDevices: Set<String>?)
    case refreshAllCompleted

    init?(json: JSONValue) {
        switch json["name"]?.stringValue {
        case "DeviceStateChangedEvent":
            guard let url = json["deviceURL"]?.stringValue else { return nil }
            self = .deviceStateChanged(deviceURL: url, states: OverkizState.decode(json["deviceStates"]?.arrayValue ?? []))
        case "ExecutionStateChangedEvent":
            guard let execID = json["execId"]?.stringValue else { return nil }
            let failed = json["failedCommands"]?.arrayValue.map { Set($0.compactMap { $0["deviceURL"]?.stringValue }) }
            self = .executionStateChanged(
                execID: execID, newState: ExecutionState(text: json["newState"]?.stringValue),
                final: json["timeToNextState"]?.number == -1, failureType: json["failureType"]?.stringValue, failedDevices: failed)
        case "RefreshAllDevicesStatesCompletedEvent":
            self = .refreshAllCompleted
        default:
            return nil
        }
    }

    static func list(_ json: JSONValue) -> [OverkizEvent] {
        (json.arrayValue ?? []).compactMap(OverkizEvent.init(json:))
    }
}

/// A scenario (Overkiz "action group", 5.12).
struct OverkizScenario: Sendable, Equatable {
    var oid: String
    var label: String

    static func list(_ json: JSONValue) -> [OverkizScenario] {
        (json.arrayValue ?? []).compactMap { item in
            guard let oid = item["oid"]?.stringValue, !oid.isEmpty else { return nil }
            return OverkizScenario(oid: oid, label: item["label"]?.stringValue ?? "")
        }
    }
}
