import Foundation
import Homeswift
import HomeswiftPlugin

/// An Apple Home accessory as Homeswift shows it: Homeswift's own service and characteristic types (the web UI's
/// widgets and the moods know them by name), with the ranges HomeKit reports for this device, its values, and a
/// write handler for each writable characteristic. Mirrored (`Accessory.mirroredFrom`), so it never goes back to
/// HomeKit, which has it already.
struct Mirror {
    static let source = "Apple Home"

    /// Services HomeKit keeps for itself or that a widget cannot use.
    static let skippedServices: Set<HAPUUID> = [
        ServiceType.accessoryInformation.uuid, ServiceType.protocolInformation.uuid, ServiceType.cameraRTPStreamManagement.uuid,
        ServiceType.cameraRecordingManagement.uuid, ServiceType.dataStreamTransportManagement.uuid, ServiceType.siri.uuid,
        ServiceType.transferTransportManagement.uuid, ServiceType.accessoryRuntimeInformation.uuid,
    ]

    /// Lock, garage door and alarm targets: Wingman refuses to write them, and Homeswift asks before it tries.
    static let securityTypes: Set<HAPUUID> = [
        CharacteristicType.lockTargetState.uuid, CharacteristicType.targetDoorState.uuid,
        CharacteristicType.securitySystemTargetState.uuid, CharacteristicType.lockControlPoint.uuid,
    ]

    let accessory: Accessory
    /// Each characteristic by its HomeKit id, for the events.
    let characteristics: [String: Characteristic]

    /// nil when nothing of the accessory is usable (only HomeKit's own services).
    init?(_ source: WingmanAPI.Accessory, platform: String, write: @escaping @Sendable (_ accessoryID: String, _ characteristicID: String, JSONValue) async throws -> Void) {
        var services: [Service] = []
        var characteristics: [String: Characteristic] = [:]
        let usable = source.services.filter { !Self.skippedServices.contains(HAPUUID($0.type)) }
        let primaryIndex = usable.firstIndex { $0.primary == true } ?? usable.firstIndex { Self.isMain(HAPUUID($0.type)) } ?? 0
        for (index, service) in usable.enumerated() {
            var extra: [Characteristic] = []
            for item in service.characteristics {
                let uuid = HAPUUID(item.type)
                guard uuid != CharacteristicType.name.uuid, let type = Self.type(of: item) else { continue }
                let characteristic = Characteristic(type, value: Self.value(item.value, as: type) ?? Characteristic(type).value)
                if Self.securityTypes.contains(uuid) { characteristic.isSecurityControl = true }
                if let id = item.id {
                    characteristics[id] = characteristic
                    if type.permissions.contains(.pairedWrite) {
                        let accessoryID = source.id
                        characteristic.onWrite { value in
                            do {
                                try await write(accessoryID, id, Self.json(value))
                            } catch {
                                throw HAPStatusError(.serviceCommunicationFailure)
                            }
                        }
                    }
                }
                extra.append(characteristic)
            }
            guard !extra.isEmpty else { continue }
            let serviceType = ServiceType.known(uuid: HAPUUID(service.type))
                ?? ServiceType(name: service.description ?? service.type, uuid: HAPUUID(service.type), required: [])
            // No required characteristics: the service has exactly what HomeKit reports, nothing made up.
            let bare = ServiceType(name: serviceType.name, uuid: serviceType.uuid, required: [])
            services.append(Service(bare, name: service.name, subtype: service.id, extra: extra, isPrimary: index == primaryIndex))
        }
        guard !services.isEmpty else { return nil }
        let accessory = Accessory(
            id: "\(platform):\(source.id)", name: source.name, manufacturer: source.manufacturer ?? Self.source,
            model: source.model ?? "Accessory", serialNumber: source.id, firmwareRevision: source.firmware ?? "1.0.0",
            category: Self.category(of: services[primaryIndex < services.count ? primaryIndex : 0].type), services: services)
        accessory.mirroredFrom = Self.source
        accessory.suggestedRoom = source.room
        accessory.isUnavailable = source.reachable == false
        self.accessory = accessory
        self.characteristics = characteristics
    }

    /// What Homeswift's types say, with the bounds this device reports; a type Homeswift does not know is described
    /// from HomeKit's metadata. nil for what a widget cannot use (TLV8 and data, hidden ones).
    static func type(of item: WingmanAPI.Characteristic) -> CharacteristicType? {
        guard !item.properties.contains("hidden") else { return nil }
        let uuid = HAPUUID(item.type)
        var type: CharacteristicType
        if let known = CharacteristicType.known(uuid: uuid) {
            type = known
        } else {
            guard let format = item.format.flatMap(CharacteristicFormat.init(rawValue:)) else { return nil }
            type = CharacteristicType(name: item.description ?? item.type, uuid: uuid, format: format, permissions: [])
            type.unit = item.units.flatMap(CharacteristicUnit.init(rawValue:))
        }
        guard type.format != .tlv8, type.format != .data else { return nil }
        var permissions: Set<CharacteristicPermission> = []
        if item.properties.contains("read") { permissions.insert(.pairedRead) }
        if item.properties.contains("write") { permissions.insert(.pairedWrite) }
        if item.properties.contains("events") { permissions.insert(.events) }
        type.permissions = permissions
        if let min = item.min { type.minValue = min }
        if let max = item.max { type.maxValue = max }
        if let step = item.step { type.minStep = step }
        if let valid = item.validValues, !valid.isEmpty { type.validValues = valid }
        if let length = item.maxLength { type.maxLength = length }
        return type
    }

    /// A value from Wingman in the characteristic's format; nil when it does not fit.
    static func value(_ json: JSONValue?, as type: CharacteristicType) -> HAPValue? {
        let raw: HAPValue
        switch json {
        case .bool(let bool)?: raw = .bool(bool)
        case .number(let number)?: raw = Int(exactly: number).map(HAPValue.int) ?? .double(number)
        case .string(let string)?: raw = .string(string)
        default: return nil
        }
        return type.coerce(raw)
    }

    static func json(_ value: HAPValue) -> JSONValue {
        switch value {
        case .bool(let bool): .bool(bool)
        case .int(let int): .number(Double(int))
        case .double(let double): .number(double)
        case .string(let string): .string(string)
        case .null: .null
        }
    }

    /// Sets a characteristic from an event: the web UI and the moods see it at once.
    static func apply(_ json: JSONValue?, to characteristic: Characteristic) {
        guard let value = value(json, as: characteristic.type) else { return }
        characteristic.value = value
    }

    private static func isMain(_ uuid: HAPUUID) -> Bool {
        uuid != ServiceType.battery.uuid && uuid != ServiceType.lightSensor.uuid
    }

    static func category(of type: ServiceType) -> AccessoryCategory {
        switch type.uuid {
        case ServiceType.lightbulb.uuid: .lightbulb
        case ServiceType.outlet.uuid: .outlet
        case ServiceType.switch.uuid, ServiceType.statelessProgrammableSwitch.uuid: .switch
        case ServiceType.fan.uuid, ServiceType.fanv2.uuid: .fan
        case ServiceType.thermostat.uuid: .thermostat
        case ServiceType.heaterCooler.uuid: .airConditioner
        case ServiceType.airPurifier.uuid: .airPurifier
        case ServiceType.humidifierDehumidifier.uuid: .humidifier
        case ServiceType.windowCovering.uuid: .windowCovering
        case ServiceType.window.uuid: .window
        case ServiceType.door.uuid: .door
        case ServiceType.garageDoorOpener.uuid: .garageDoorOpener
        case ServiceType.lockMechanism.uuid: .doorLock
        case ServiceType.securitySystem.uuid: .securitySystem
        case ServiceType.valve.uuid, ServiceType.irrigationSystem.uuid: .sprinkler
        case ServiceType.television.uuid: .television
        case ServiceType.speaker.uuid, ServiceType.smartSpeaker.uuid: .speaker
        case ServiceType.doorbell.uuid: .videoDoorbell
        case ServiceType.temperatureSensor.uuid, ServiceType.humiditySensor.uuid, ServiceType.motionSensor.uuid,
             ServiceType.contactSensor.uuid, ServiceType.lightSensor.uuid, ServiceType.occupancySensor.uuid,
             ServiceType.leakSensor.uuid, ServiceType.smokeSensor.uuid, ServiceType.carbonMonoxideSensor.uuid,
             ServiceType.carbonDioxideSensor.uuid, ServiceType.airQualitySensor.uuid:
            .sensor
        default: .other
        }
    }
}
