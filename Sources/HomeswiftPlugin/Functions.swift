import Foundation
import Homeswift

/// An accessory's Functions (GLOSSARY.md, "Function"): the services that each do one thing Apple Home shows on its own,
/// such as a light, a motion sensor or an outlet. What only describes or serves the accessory is none: its identity,
/// battery, filter, the services HomeKit runs a camera or a television with, a lock's management, a hidden service or
/// one of a type HomeKit does not define (Eve's history).
public enum Functions {
    static let neverFunctions: Set<HAPUUID> = [
        ServiceType.accessoryInformation.uuid, ServiceType.protocolInformation.uuid, ServiceType.battery.uuid,
        ServiceType.filterMaintenance.uuid, ServiceType.accessoryRuntimeInformation.uuid, ServiceType.siri.uuid,
        ServiceType.transferTransportManagement.uuid, ServiceType.accessoryMetrics.uuid, ServiceType.wiFiTransport.uuid,
        ServiceType.threadTransport.uuid, ServiceType.cameraRTPStreamManagement.uuid, ServiceType.cameraRecordingManagement.uuid,
        ServiceType.cameraOperatingMode.uuid, ServiceType.dataStreamTransportManagement.uuid, ServiceType.inputSource.uuid,
        ServiceType.televisionSpeaker.uuid, ServiceType.lockManagement.uuid, ServiceType.serviceLabel.uuid,
    ]

    /// A camera's microphone and speaker are the camera's, not Functions of their own.
    static let cameraParts: Set<HAPUUID> = [ServiceType.microphone.uuid, ServiceType.speaker.uuid]

    /// The services of HomeKit's own types end in this.
    static let appleBase = "-0000-1000-8000-0026BB765291"

    /// The accessory's Functions, in its order.
    public static func of(_ accessory: Accessory) -> [Service] {
        let isCamera = accessory.services.contains { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid }
        return accessory.services.filter { service in
            isFunction(service) && !(isCamera && cameraParts.contains(service.type.uuid))
        }
    }

    /// Whether the service is a Function wherever it is.
    public static func isFunction(_ service: Service) -> Bool {
        !service.isHidden && !neverFunctions.contains(service.type.uuid) && service.type.uuid.uuidString.uppercased().hasSuffix(appleBase)
    }

    /// The category an accessory doing this one thing shows as.
    public static func category(of type: ServiceType) -> AccessoryCategory {
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
