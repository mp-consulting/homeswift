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
    /// The accessory's shape (`signature(of:)`): a read of the homes keeps a mirror whose shape did not change.
    let signature: String

    /// nil when nothing of the accessory is usable (only HomeKit's own services).
    init?(_ source: WingmanAPI.Accessory, write: @escaping @Sendable (_ accessoryID: String, _ characteristicID: String, JSONValue) async throws -> Void) {
        var services: [Service] = []
        var characteristics: [String: Characteristic] = [:]
        let usable = source.services.filter { !Self.skippedServices.contains(HAPUUID($0.type)) }
        let primary = usable.first { $0.primary == true } ?? usable.first { Self.isMain(HAPUUID($0.type)) }
        for service in usable {
            var extra: [Characteristic] = []
            for item in service.characteristics {
                let uuid = HAPUUID(item.type)
                guard uuid != CharacteristicType.name.uuid, let type = Self.type(of: item) else { continue }
                let characteristic = Characteristic(type, value: Self.value(item.value, as: type))
                if Self.securityTypes.contains(uuid) { characteristic.isSecurityControl = true }
                if let id = item.id {
                    characteristics[id] = characteristic
                    if type.permissions.contains(.pairedWrite) {
                        let accessoryID = source.id
                        characteristic.onWrite { value in
                            do {
                                try await write(accessoryID, id, JSONValue(value))
                            } catch {
                                throw HAPStatusError(.serviceCommunicationFailure)
                            }
                        }
                    }
                }
                extra.append(characteristic)
            }
            guard !extra.isEmpty else { continue }
            // Homeswift's name for the type, which the widgets and moods know; no required characteristics: the service
            // has exactly what HomeKit reports, nothing made up.
            let uuid = HAPUUID(service.type)
            let type = ServiceType(name: ServiceType.known(uuid: uuid)?.name ?? service.description ?? service.type, uuid: uuid, required: [])
            services.append(Service(type, name: service.name, subtype: service.id, extra: extra, isPrimary: service.id == primary?.id))
        }
        guard !services.isEmpty else { return nil }
        let accessory = Accessory(
            id: "\(WingmanPlugin.platform):\(source.id)", name: source.name, manufacturer: source.manufacturer ?? Self.source,
            model: source.model ?? "Accessory", serialNumber: source.id, firmwareRevision: source.firmware ?? "1.0.0",
            category: Self.category(of: (services.first(where: \.isPrimary) ?? services[0]).type), services: services)
        accessory.mirroredFrom = Self.source
        accessory.suggestedRoom = source.room
        accessory.isUnavailable = source.reachable == false
        self.accessory = accessory
        self.characteristics = characteristics
        signature = Self.signature(of: source)
    }

    /// What decides the accessory's objects: its name, room, services and their characteristics with their props.
    /// Values and reachability are not in it: `update(from:)` takes those.
    static func signature(of source: WingmanAPI.Accessory) -> String {
        var parts = [source.name, source.room ?? "", source.manufacturer ?? "", source.model ?? ""]
        for service in source.services {
            parts.append("\(service.id ?? "")/\(service.type)/\(service.name ?? "")/\(service.primary == true)")
            for item in service.characteristics {
                parts.append("\(item.id ?? "")/\(item.type)/\(item.properties)/\(item.format ?? "")/\(item.units ?? "")/\(item.min.map { "\($0)" } ?? "")/"
                    + "\(item.max.map { "\($0)" } ?? "")/\(item.step.map { "\($0)" } ?? "")/\(item.validValues ?? [])/\(item.maxLength.map { "\($0)" } ?? "")")
            }
        }
        return parts.joined(separator: "|")
    }

    /// Takes the values and reachability of a new read of the same accessory.
    func update(from source: WingmanAPI.Accessory) {
        for service in source.services {
            for item in service.characteristics {
                if let id = item.id, let characteristic = characteristics[id] { Self.apply(item.value, to: characteristic) }
            }
        }
        let unavailable = source.reachable == false
        if accessory.isUnavailable != unavailable { accessory.isUnavailable = unavailable }
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
        json.flatMap(HAPValue.init).flatMap(type.coerce)
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
