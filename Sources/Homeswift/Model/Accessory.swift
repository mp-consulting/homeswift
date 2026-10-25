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
    private let servicesBox: NIOLockedValueBox<[Service]>
    /// The Accessory Information service first, then the services given at creation.
    public var services: [Service] { servicesBox.withLockedValue { $0 } }

    let aidBox = NIOLockedValueBox(0)
    private let mirrorBox = NIOLockedValueBox<(source: String?, room: String?)>((nil, nil))
    /// The camera that answers snapshot requests (`configureController`).
    let cameraControllerBox = NIOLockedValueBox<CameraController?>(nil)
    public var aid: Int { aidBox.withLockedValue { $0 } }

    public init(
        id: String,
        name: String,
        manufacturer: String = "Homeswift",
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
        servicesBox = NIOLockedValueBox([information] + services)
    }

    /// The first service of the given type, if any.
    public subscript(type: ServiceType) -> Service? { service(type) }

    /// Adds a service the server needs on every accessory (Protocol Information).
    func append(_ service: Service) {
        servicesBox.withLockedValue { $0.append(service) }
    }

    public var name: String {
        information[.name]?.value.stringValue ?? id
    }

    /// The first service of the given type.
    public func service(_ type: ServiceType, subtype: String? = nil) -> Service? {
        services.first { $0.type.uuid == type.uuid && (subtype == nil || $0.subtype == subtype) }
    }

    /// Copies the values of a cached accessory onto this one, rebuilt from the device, so the Home app keeps showing the
    /// last readings and the names it was given until the device answers. Services match on type and subtype,
    /// characteristics on type; Accessory Information is left alone (`Service.takeValues(from:)` has the rule).
    public func takeValues(from cached: Accessory) {
        for service in services where service.type.uuid != ServiceType.accessoryInformation.uuid {
            guard let old = cached.services.first(where: { $0.type.uuid == service.type.uuid && $0.subtype == service.subtype }) else {
                continue
            }
            service.takeValues(from: old)
        }
    }

    /// Whether the accessory answers: while it does not, every read and write of its characteristics fails with
    /// "No Response" and reaches none of their handlers, so nothing is sent to the device (a paused plugin).
    /// Values and handlers are kept.
    /// A change is announced with an event of a value that did not change, so the pages following the accessory (the
    /// web UI's event stream carries `unavailable`) learn it at once.
    public var isUnavailable: Bool {
        get { services.contains { $0.characteristics.contains(where: \.isUnavailable) } }
        set {
            let characteristics = services.flatMap(\.characteristics)
            guard characteristics.contains(where: { $0.isUnavailable != newValue }) else { return }
            for characteristic in characteristics { characteristic.isUnavailable = newValue }
            // A state, never a button's press (which automations take as one), and never an empty value.
            let announcer = characteristics.first {
                $0.type.permissions.contains(.events) && $0.type.uuid != CharacteristicType.programmableSwitchEvent.uuid && $0.value != .null
            }
            if let announcer { announcer.update(announcer.value, origin: nil, force: true) }
        }
    }

    /// The controller this accessory mirrors, for an accessory HomeKit already has another way ("Apple Home": the
    /// Wingman plugin shows the Home app's accessories). The bridge keeps a mirrored accessory out of HomeKit (it
    /// is not in `GET /accessories`, and controllers cannot read, write or subscribe to it) while the web UI, the MCP
    /// server, scenes and moods use it as any other; the UI says where it comes from. Set before `context.add`.
    public var mirroredFrom: String? {
        get { mirrorBox.withLockedValue { $0.source } }
        set { mirrorBox.withLockedValue { $0.source = newValue } }
    }

    /// The room the mirrored controller puts it in: the web UI's until the user gives it one of its own.
    public var suggestedRoom: String? {
        get { mirrorBox.withLockedValue { $0.room } }
        set { mirrorBox.withLockedValue { $0.room = newValue } }
    }

    func identify() async {
        guard !isUnavailable else { return }
        try? await information.characteristic(.identify).writeHandler(for: .bool(true))?(.bool(true))
    }
}
