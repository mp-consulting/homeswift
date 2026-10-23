import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// One data point as the cloud describes it: its value and, when it has them, the allowed values, the range
/// and whether it can be set. A missing data point has a nil `value` (JavaScript's `undefined`).
struct DataPoint: Sendable, Equatable {
    var value: JSONValue?
    var values: [String]?
    var minValue: Double?
    var maxValue: Double?
    var stepValue: Double?
    var settable: Bool?

    static let missing = DataPoint()

    init(value: JSONValue? = nil) { self.value = value }

    /// A Daikin characteristic object: `{ value, values, minValue, maxValue, stepValue, settable }`.
    init(object: [String: JSONValue]) {
        value = object["value"]
        values = object["values"]?.arrayValue?.compactMap(\.stringValue)
        minValue = object["minValue"]?.doubleValue
        maxValue = object["maxValue"]?.doubleValue
        stepValue = object["stepValue"]?.doubleValue
        settable = object["settable"]?.boolValue
    }

    var string: String? { value?.stringValue }
    var number: Double? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        return number
    }
}

/// A firmware update Daikin has staged (the gateway's `firmwareUpdate.value`), present while one is available.
struct FirmwareUpdateInfo: Sendable, Equatable {
    var id: String
    var version: String?
    var description: String?
    var type: String?
}

/// A device was offline in the cloud (its Wi-Fi adapter lost the Onecta connection), so it takes no writes.
struct DeviceOfflineError: Error, CustomStringConvertible, Equatable {
    var deviceID: String
    var description: String { "Device \(deviceID) is offline (cloud connection down)" }
}

/// A Daikin device as the cloud describes it: its raw JSON, read by path, written through the API and
/// patched in place by WebSocket pushes and successful writes. Reads are synchronous (the HomeKit side
/// reads many values at once); the lock makes them safe from any task.
final class DaikinCloudDevice: @unchecked Sendable {
    private let state: NIOLockedValueBox<State>
    private let api: any DaikinDeviceWriting

    private struct State {
        var raw: JSONValue
        var lastUpdated = Date()
        /// Numbers `setData` calls in the order they were made; writes to one target are sent in that order.
        var writeSequence = 0
        /// The newest write applied locally, by target: an older one finishing later must not undo it.
        var appliedWrites: [String: Int] = [:]
    }

    init(_ raw: JSONValue, api: any DaikinDeviceWriting) {
        state = NIOLockedValueBox(State(raw: raw))
        self.api = api
    }

    var raw: JSONValue { state.withLockedValue { $0.raw } }
    var id: String { raw["id"]?.stringValue ?? "" }
    var deviceModel: String { raw["deviceModel"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown" }
    var type: String? { raw["type"]?.stringValue }
    var isCloudConnectionUp: Bool? { raw["isCloudConnectionUp"]?["value"]?.boolValue }
    var lastUpdated: Date { state.withLockedValue { $0.lastUpdated } }
    var managementPoints: [JSONValue] { raw["managementPoints"]?.arrayValue ?? [] }


    // MARK: Reading

    /// The embedded id of the first management point of a type (`gateway`, `climateControl`, ...).
    func managementPointID(type: String) -> String? {
        managementPoints.first { $0["managementPointType"]?.stringValue == type }?["embeddedId"]?.stringValue
    }

    /// The embedded ids of every management point of a type.
    func managementPointIDs(type: String) -> [String] {
        managementPoints.filter { $0["managementPointType"]?.stringValue == type }.compactMap { $0["embeddedId"]?.stringValue }
    }

    func hasManagementPoint(type: String) -> Bool { managementPointID(type: type) != nil }

    /// A data point of a management point, optionally at a path inside it
    /// (`/operationModes/cooling/setpoints/roomTemperature`).
    func data(_ managementPointID: String, _ dataPoint: String, _ path: String? = nil) -> DataPoint {
        Self.data(in: raw, managementPointID, dataPoint, path)
    }

    /// The operation mode of a management point; `fallback` when it has none, or an empty one.
    func operationMode(_ managementPointID: String, default fallback: String = Daikin.OperationMode.auto.rawValue) -> String {
        guard let mode = data(managementPointID, "operationMode").string, !mode.isEmpty else { return fallback }
        return mode
    }

    static func data(in raw: JSONValue, _ managementPointID: String, _ dataPoint: String, _ path: String?) -> DataPoint {
        guard let point = managementPoint(managementPointID, in: raw), let data = point[dataPoint], isTruthy(data) else { return .missing }
        guard let path, !path.isEmpty, path != "/" else {
            if case .object(let object) = data { return DataPoint(object: object) }
            return .missing
        }
        return navigate(data, path)
    }

    /// Follows a path through Daikin's `{ value: { ... } }` wrapping, as the Homebridge plugin does.
    private static func navigate(_ data: JSONValue, _ path: String) -> DataPoint {
        var current: JSONValue? = data
        for part in path.split(separator: "/").map(String.init) {
            guard var node = current, !node.isNull else { return .missing }
            if case .object(let object) = node, let inner = object["value"] { node = inner }
            switch node {
            case .object(let object):
                guard let next = object[part] else { return .missing }
                current = next
            case .array(let array):
                guard let index = Int(part), array.indices.contains(index) else { return .missing }
                current = array[index]
            default:
                return .missing
            }
        }
        if case .object(let object) = current, object["value"] != nil { return DataPoint(object: object) }
        return DataPoint(value: current)
    }

    private static func managementPoint(_ id: String, in raw: JSONValue) -> JSONValue? {
        raw["managementPoints"]?.arrayValue?.first { $0["embeddedId"]?.stringValue == id }
    }

    private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let bool): bool
        case .number(let number): number != 0
        case .string(let string): !string.isEmpty
        default: true
        }
    }

    // MARK: Writing

    /// Writes a data point (at a path inside it) and reflects it in the data at once, so reads see the new
    /// value instead of the old one until the next poll: switches derived from a data point (Auto fan mode
    /// from the fan's current mode) follow a related change right away. The next poll reconciles any drift.
    ///
    /// The value applied is the one the request carried (a write merged into a newer one's request carries the
    /// newer value), and only when no later write to the same target was applied first: the callers of
    /// coalesced writes resume in any order, and a stale value here would make the next identical change look
    /// like a no-op.
    func setData(_ managementPointID: String, _ dataPoint: String, _ value: JSONValue, path: String? = nil) async throws {
        if isCloudConnectionUp == false { throw DeviceOfflineError(deviceID: id) }
        let target = "\(managementPointID)|\(dataPoint)|\(path ?? "")"
        let sequence = state.withLockedValue { state in
            state.writeSequence += 1
            return state.writeSequence
        }
        let sent = try await api.updateDevice(id, embeddedID: managementPointID, dataPoint: dataPoint, value: value, path: path)
        state.withLockedValue { state in
            guard sequence > state.appliedWrites[target, default: 0] else { return }
            state.appliedWrites[target] = sequence
            state.raw = Self.writing(sent, into: state.raw, managementPointID, dataPoint, path)
            state.lastUpdated = Date()
        }
    }

    /// Holiday (away) mode, through its own endpoint; reflected in the data like `setData`.
    func setHolidayMode(_ managementPointID: String, enabled: Bool, startDate: String? = nil, endDate: String? = nil) async throws {
        if isCloudConnectionUp == false { throw DeviceOfflineError(deviceID: id) }
        try await api.setHolidayMode(id, embeddedID: managementPointID, enabled: enabled, startDate: startDate, endDate: endDate)
        state.withLockedValue { state in
            state.raw = Self.updatingManagementPoint(managementPointID, in: state.raw) { point in
                guard case .object(var holiday) = point["holidayMode"], case .object(var value) = holiday["value"] else { return }
                value["enabled"] = .bool(enabled)
                if let startDate { value["startDate"] = .string(startDate) }
                if let endDate { value["endDate"] = .string(endDate) }
                holiday["value"] = .object(value)
                point["holidayMode"] = .object(holiday)
            }
            state.lastUpdated = Date()
        }
    }

    // MARK: Firmware

    /// The update Daikin staged for a management point, nil when the device is up to date.
    func firmwareUpdateInfo(_ managementPointID: String) -> FirmwareUpdateInfo? {
        guard let value = data(managementPointID, "firmwareUpdate").value, let id = value["id"]?.stringValue else { return nil }
        return FirmwareUpdateInfo(id: id, version: value["version"]?.stringValue, description: value["description"]?.stringValue, type: value["type"]?.stringValue)
    }

    /// `in-progress`, `succeeded` or `failed`; nil when no update ran lately.
    func firmwareUpdateStatus(_ managementPointID: String) -> String? { data(managementPointID, "firmwareUpdateStatus").string }

    func isFirmwareUpdateSupported(_ managementPointID: String) -> Bool { data(managementPointID, "isFirmwareUpdateSupported").value == .bool(true) }

    /// Installs the staged update and marks it in progress until the next poll tells how it goes.
    @discardableResult
    func triggerFirmwareUpdate(_ managementPointID: String) async throws -> FirmwareUpdateInfo {
        if isCloudConnectionUp == false { throw DeviceOfflineError(deviceID: id) }
        guard let info = firmwareUpdateInfo(managementPointID) else { throw DaikinError("No firmware update is currently staged for this device") }
        try await api.triggerFirmwareUpdate(id, embeddedID: managementPointID, firmwareID: info.id)
        state.withLockedValue { state in
            state.raw = Self.updatingManagementPoint(managementPointID, in: state.raw) { $0["firmwareUpdateStatus"] = ["value": "in-progress"] }
            state.lastUpdated = Date()
        }
        return info
    }

    // MARK: Updates from the cloud

    /// The data of a fresh poll.
    func update(raw: JSONValue) {
        state.withLockedValue { state in
            state.raw = raw
            state.lastUpdated = Date()
        }
    }

    /// A push from the WebSocket. Daikin sends partial sub-trees (one operation mode's fan direction, say):
    /// objects are merged key by key so the rest stays, values and arrays replace.
    func apply(_ update: WebSocketDeviceUpdate) {
        state.withLockedValue { state in
            guard Self.managementPoint(update.embeddedID, in: state.raw) != nil else { return }
            state.raw = Self.updatingManagementPoint(update.embeddedID, in: state.raw) { point in
                var characteristic = point[update.characteristicName]?.objectValue ?? [:]
                let data = update.data
                if let value = data["value"] { characteristic["value"] = Self.merge(characteristic["value"], value) }
                for key in ["values", "settable", "minValue", "maxValue", "stepValue"] {
                    if let value = data[key] { characteristic[key] = value }
                }
                point[update.characteristicName] = .object(characteristic)
            }
            state.lastUpdated = Date()
        }
    }

    /// Deep merge: objects key by key, anything else replaces.
    static func merge(_ existing: JSONValue?, _ incoming: JSONValue) -> JSONValue {
        guard case .object(var merged) = existing, case .object(let patch) = incoming else { return incoming }
        for (key, value) in patch { merged[key] = merge(merged[key], value) }
        return .object(merged)
    }

    // MARK: JSON surgery

    private static func updatingManagementPoint(_ id: String, in raw: JSONValue, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        guard case .object(var root) = raw, case .array(var points) = root["managementPoints"],
            let index = points.firstIndex(where: { $0["embeddedId"]?.stringValue == id }), case .object(var point) = points[index]
        else { return raw }
        change(&point)
        points[index] = .object(point)
        root["managementPoints"] = .array(points)
        return .object(root)
    }

    /// The local copy of a successful write: navigates like `navigate` and sets the leaf's `value`; does
    /// nothing when the path does not resolve.
    static func writing(_ value: JSONValue, into raw: JSONValue, _ managementPointID: String, _ dataPoint: String, _ path: String?) -> JSONValue {
        updatingManagementPoint(managementPointID, in: raw) { point in
            guard case .object(var data) = point[dataPoint] else { return }
            guard let path, !path.isEmpty else {
                data["value"] = value
                point[dataPoint] = .object(data)
                return
            }
            let parts = path.split(separator: "/").map(String.init)
            if let updated = set(value, at: parts[...], in: .object(data)) { point[dataPoint] = updated }
        }
    }

    /// Descends one part (through a `value` wrapper first, as `navigate` does) and sets `value` at the end.
    private static func set(_ value: JSONValue, at parts: ArraySlice<String>, in node: JSONValue) -> JSONValue? {
        guard case .object(var object) = node else { return nil }
        guard let part = parts.first else {
            guard object["value"] != nil else { return nil }
            object["value"] = value
            return .object(object)
        }
        if let wrapped = object["value"] {
            guard case .object(var inner) = wrapped, let child = inner[part], let updated = set(value, at: parts.dropFirst(), in: child) else { return nil }
            inner[part] = updated
            object["value"] = .object(inner)
            return .object(object)
        }
        guard let child = object[part], let updated = set(value, at: parts.dropFirst(), in: child) else { return nil }
        object[part] = updated
        return .object(object)
    }

    // MARK: Logs

    /// The data with what identifies the owner masked, for debug logs.
    static func masked(_ raw: JSONValue) -> JSONValue {
        guard case .object(var root) = raw, case .array(let points) = root["managementPoints"] else { return raw }
        root["managementPoints"] = .array(points.map { point in
            guard case .object(var object) = point else { return point }
            for key in ["ipAddress", "macAddress", "ssid", "serialNumber", "wifiConnectionSSID"] {
                if case .object(var field) = object[key] {
                    field["value"] = "REDACTED"
                    object[key] = .object(field)
                }
            }
            for key in ["consumptionData", "schedule"] where object[key] != nil { object[key] = "REDACTED" }
            return .object(object)
        })
        return .object(root)
    }
}

/// A characteristic update pushed over the WebSocket.
struct WebSocketDeviceUpdate: Sendable, Equatable {
    var deviceID: String
    var embeddedID: String
    var managementPointID: String?
    var characteristicName: String
    /// `{ name, value, values, settable, minValue, maxValue, stepValue, ref }`.
    var data: JSONValue
}
