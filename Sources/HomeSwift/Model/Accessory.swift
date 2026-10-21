import NIOConcurrencyHelpers

/// The HomeKit category shown during pairing, advertised as `ci`.
public enum AccessoryCategory: Int, Sendable, Codable {
    case other = 1, bridge, fan, garageDoorOpener, lightbulb, doorLock, outlet, `switch`, thermostat, sensor
    case securitySystem, door, window, windowCovering, programmableSwitch, rangeExtender, ipCamera
    case videoDoorbell, airPurifier, heater, airConditioner, humidifier, dehumidifier, appleTV, homePod
    case speaker, airport, sprinkler, faucet, showerHead, television, targetController, wifiRouter
    case audioReceiver, tvSetTopBox, tvStreamingStick
}

/// A HomeKit accessory: an Accessory Information service plus the services you give it.
///
/// `id` must be stable across launches (a serial number, MAC, or your own key): the server uses it
/// to keep the accessory's aid, and each service's iids, the same so HomeKit keeps rooms and scenes.
public final class Accessory: @unchecked Sendable {
    public let id: String
    public let category: AccessoryCategory
    public let information: Service
    public let services: [Service]

    let aidBox = NIOLockedValueBox(0)
    public var aid: Int { aidBox.withLockedValue { $0 } }

    public init(
        id: String,
        name: String,
        manufacturer: String = "HomeSwift",
        model: String = "Accessory",
        serialNumber: String? = nil,
        firmwareRevision: String = "1.0.0",
        category: AccessoryCategory = .other,
        services: [Service],
        onIdentify: (@Sendable () async -> Void)? = nil
    ) {
        self.id = id
        self.category = category
        let information = Service(.accessoryInformation, name: name)
        information.characteristic(.manufacturer).value = .string(manufacturer)
        information.characteristic(.model).value = .string(model)
        information.characteristic(.serialNumber).value = .string(serialNumber ?? id)
        information.characteristic(.firmwareRevision).value = .string(firmwareRevision)
        information.characteristic(.identify).onWrite { _ in await onIdentify?() }
        self.information = information
        self.services = [information] + services
    }

    public var name: String {
        information[.name]?.value.stringValue ?? id
    }

    /// The first service of the given type.
    public func service(_ type: ServiceType, subtype: String? = nil) -> Service? {
        services.first { $0.type.uuid == type.uuid && (subtype == nil || $0.subtype == subtype) }
    }

    func identify() async {
        try? await information.characteristic(.identify).writeHandler?(.bool(true))
    }
}
