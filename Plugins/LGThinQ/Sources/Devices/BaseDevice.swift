import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// What a device handler needs from the platform: the cloud, the log, and its options.
@ThinQActor
struct DeviceEnvironment {
    let thinq: ThinQ
    let logger: Logger
    let settings: DeviceSettings
}

/// One LG appliance in HomeKit, as the Homebridge plugin's `BaseDevice`: it builds its services from the
/// device, its model and its options, applies each snapshot, and turns HomeKit writes into commands. The
/// subclasses are the device types.
@ThinQActor
class BaseDevice {
    nonisolated static let platformPrefix = "LGThinQ"

    var device: ThinQDevice
    let thinq: ThinQ
    let logger: Logger
    let config: DeviceSettings
    /// In the order the Homebridge plugin adds them.
    private(set) var services: [Service] = []
    /// The input a Television status board shows (its Active Identifier).
    var activeInput = 1

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        self.device = device
        thinq = environment.thinq
        logger = environment.logger
        config = environment.settings
    }

    var accessoryID: String { "\(Self.platformPrefix):\(device.id)" }

    /// The accessory with the services the initializer built; the information service carries LG's model and
    /// serial number (or the block's `serial_number`).
    func makeAccessory() -> Accessory {
        Accessory(
            id: accessoryID, name: device.name, manufacturer: "LG", model: device.salesModel ?? device.model.nonEmpty ?? "Unknown",
            serialNumber: config.serialNumber ?? device.serialNumber ?? "Unknown", category: DeviceRegistry.category(device.type), services: services)
    }

    /// Adds a service the way `getOrCreateService` does: named, its subtype the name unless given, with a
    /// Configured Name. A type in `optional` that the service requires replaces the required one (HAP-NodeJS's
    /// `setProps` on it).
    @discardableResult
    func addService(_ type: ServiceType, name: String, subtype: String? = nil, optional: [CharacteristicType] = [], extra: [Characteristic] = [],
                    primary: Bool = false, configuredName: Bool = true) -> Service {
        var extra = extra
        if configuredName { extra.append(Characteristic(.configuredName, value: .string(name))) }
        let service = Service(type, name: name, subtype: subtype ?? name, optional: optional, extra: extra, isPrimary: primary)
        services.append(service)
        return service
    }

    /// Adds a service built elsewhere.
    @discardableResult
    func append(_ service: Service) -> Service {
        services.append(service)
        return service
    }

    /// A snapshot (or a delta of one) from the REST poll, MQTT or a ThinQ1 poll.
    func update(_ snapshot: [String: JSONValue]) {
        logger.debug("[\(device.name)] Received snapshot: \(JSONValue.object(snapshot).text())")
        device.snapshot = mergeSnapshot(device.snapshot, snapshot)
        updateAccessoryCharacteristic(device)
    }

    /// Pushes the device's state to its characteristics. Subclasses override and call super first.
    func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        self.device = device
    }

    /// Releases timers before the handler is replaced or removed.
    func destroy() {}

    // MARK: Status

    /// The part of the snapshot the type's status reads: `snapshot[key]`, or the whole snapshot for devices
    /// with flat `airState.*` keys.
    func statusData(_ key: String? = nil) -> [String: JSONValue] {
        let key = key ?? DeviceRegistry.snapshotKey(device.type)
        guard let key else { return device.snapshot }
        return device.snapshot[key]?.objectValue ?? [:]
    }

    func hasModelFeature(_ feature: String) -> Bool {
        DeviceRegistry.hasModelFeature(device.type, feature, model: device.model)
    }

    // MARK: Commands

    /// A command that must be accepted: an error reaching LG and a refusal are both a communication failure for
    /// HomeKit, each logged in the caller's words.
    func sendAccepted(_ values: [String: JSONValue], command: String = "Set", ctrlKey: String = "basicCtrl",
                      failed: (any Error) -> Void, refused: () -> Void) async throws {
        let accepted: Bool
        do {
            accepted = try await thinq.deviceControl(device.id, values: values, command: command, ctrlKey: ctrlKey)
        } catch {
            failed(error)
            throw Self.communicationFailure()
        }
        if !accepted {
            refused()
            throw Self.communicationFailure()
        }
    }

    /// The values of a command that sets a `dataSetList`.
    nonisolated static func dataSetList(_ list: [String: JSONValue]) -> [String: JSONValue] {
        ["dataKey": .null, "dataValue": .null, "dataSetList": .object(list), "dataGetList": .null]
    }

    /// `dataKey` and `dataValue`; on success the snapshot takes the value and the characteristics follow.
    func setDeviceControl(_ dataKey: String, _ dataValue: JSONValue, updateSnapshot: Bool = true) async throws -> Bool {
        let accepted: Bool
        do {
            accepted = try await thinq.deviceControl(device.id, values: ["dataKey": .string(dataKey), "dataValue": dataValue])
        } catch {
            logger.error("[\(device.name)] Failed to set \(dataKey): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        if accepted, updateSnapshot {
            updateSnapshotValue(dataKey, dataValue)
            updateAccessoryCharacteristic(device)
        }
        return accepted
    }

    func setBooleanControl(_ dataKey: String, _ value: Bool) async throws -> Bool {
        try await setDeviceControl(dataKey, .number(value ? 1 : 0))
    }

    /// Writes a value at a dotted path of the snapshot. Air devices key their snapshot by the whole dotted path
    /// at the root (`airState.operation`), so that flat key is written when it is the shape in use.
    func updateSnapshotValue(_ path: String, _ value: JSONValue) {
        var snapshot = device.snapshot
        let keys = path.split(separator: ".").map(String.init)
        if snapshot[path] != nil || (keys.count > 1 && snapshot[keys[0]]?.objectValue == nil) {
            snapshot[path] = value
            device.snapshot = snapshot
            return
        }
        func set(_ object: [String: JSONValue], _ keys: ArraySlice<String>) -> [String: JSONValue] {
            var object = object
            guard let first = keys.first else { return object }
            if keys.count == 1 {
                object[first] = value
            } else {
                object[first] = .object(set(object[first]?.objectValue ?? [:], keys.dropFirst()))
            }
            return object
        }
        device.snapshot = set(snapshot, keys[...])
    }

    nonisolated static func communicationFailure() -> HAPStatusError { HAPStatusError(.serviceCommunicationFailure) }
}

// MARK: - Characteristic values

extension Service {
    /// Sets a value the way HAP-NodeJS's `updateCharacteristic` does: numbers clamped to the characteristic's
    /// bounds, integers rounded, a value outside `validValues` or not a number ignored, strings cut at 64.
    func set(_ type: CharacteristicType, _ value: HAPValue) {
        guard let characteristic = self[type], let fitted = Self.fit(value, to: characteristic.type) else { return }
        characteristic.value = fitted
    }

    func set(_ type: CharacteristicType, _ value: Double) { set(type, .double(value)) }
    func set(_ type: CharacteristicType, _ value: Int) { set(type, .int(value)) }
    func set(_ type: CharacteristicType, _ value: Bool) { set(type, .bool(value)) }
    func set(_ type: CharacteristicType, _ value: String) { set(type, .string(value)) }

    func value(_ type: CharacteristicType) -> HAPValue? { self[type]?.value }

    nonisolated static func fit(_ value: HAPValue, to type: CharacteristicType) -> HAPValue? {
        switch type.format {
        case .bool:
            return value.boolValue.map(HAPValue.bool)
        case .uint8, .uint16, .uint32, .uint64, .int:
            guard var number = value.doubleValue, number.isFinite else { return nil }
            number = number.rounded()
            if let minimum = type.minValue { number = Swift.max(number, minimum) }
            if let maximum = type.maxValue { number = Swift.min(number, maximum) }
            if type.format != .int { number = Swift.max(number, 0) }
            guard let int = Int(saturating: number) else { return nil }
            if let valid = type.validValues, !valid.contains(int) { return nil }
            return .int(int)
        case .float:
            guard var number = value.doubleValue, number.isFinite else { return nil }
            if let minimum = type.minValue { number = Swift.max(number, minimum) }
            if let maximum = type.maxValue { number = Swift.min(number, maximum) }
            return .double(number)
        case .string:
            guard let string = value.stringValue else { return nil }
            return .string(String(string.prefix(type.maxLength ?? 64)))
        case .tlv8, .data:
            return value
        }
    }
}

extension CharacteristicType {
    /// Eve's Total Consumption (kWh), which Eve shows for energy meters, with the Homebridge plugin's maximum.
    nonisolated static let totalConsumption = EveCharacteristic.totalConsumption.props(max: 1_000_000)

    /// HAP-NodeJS's `setProps` with explicit valid values (keeps min and max).
    func valid(_ values: [Int]) -> CharacteristicType {
        var copy = self
        copy.validValues = values
        return copy
    }

    /// `setProps({ minValue, maxValue, minStep })` that may lower bounds below the definition's.
    func props(min: Double? = nil, max: Double? = nil, step: Double? = nil) -> CharacteristicType {
        var copy = self
        if let min { copy.minValue = min }
        if let max { copy.maxValue = max }
        if let step { copy.minStep = step }
        if let valid = copy.validValues { copy.validValues = valid.filter { Double($0) >= (copy.minValue ?? -.infinity) && Double($0) <= (copy.maxValue ?? .infinity) } }
        return copy
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Characteristic {
    /// Registers a write handler running on the ThinQ actor.
    @discardableResult
    func onSet(_ handler: @escaping @ThinQActor @Sendable (HAPValue) async throws -> Void) -> Self {
        onWrite { value in try await handler(value) }
    }

    /// Registers a read handler running on the ThinQ actor.
    @discardableResult
    func onGet(_ handler: @escaping @ThinQActor @Sendable () async -> HAPValue) -> Self {
        onRead { await handler() }
    }
}
