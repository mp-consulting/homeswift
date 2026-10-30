import NIOConcurrencyHelpers

/// A group of characteristics that make up one function of an accessory, such as a lightbulb.
public final class Service: @unchecked Sendable {
    public let type: ServiceType
    /// Distinguishes several services of the same type on one accessory (e.g. two outlets).
    public let subtype: String?
    private let characteristicsBox: NIOLockedValueBox<[Characteristic]>
    public var characteristics: [Characteristic] { characteristicsBox.withLockedValue { $0 } }
    public let isPrimary: Bool
    public let isHidden: Bool

    let iidBox = NIOLockedValueBox(0)
    public var iid: Int { iidBox.withLockedValue { $0 } }

    private let linkedBox = NIOLockedValueBox<[Service]>([])
    private let standsForBox = NIOLockedValueBox<ServiceStandsFor?>(nil)

    /// What the service controls when HAP has no service type for it (a switch that runs a pool robot): HomeKit sees
    /// the service as it is, other ecosystems that have the type (Matter) show it as that. Set before `context.add`.
    public var standsFor: ServiceStandsFor? {
        get { standsForBox.withLockedValue { $0 } }
        set { standsForBox.withLockedValue { $0 = newValue } }
    }
    /// Services of the same accessory this one groups, listed by iid as `linked`: a Television lists its
    /// input sources and speaker, so the Home app shows them with it.
    public var linked: [Service] {
        get { linkedBox.withLockedValue { $0 } }
        set { linkedBox.withLockedValue { $0 = newValue } }
    }

    /// The controller that gives a lightbulb Adaptive Lighting, once one was made for it; weak, as the controller
    /// holds the service.
    public var adaptiveLighting: AdaptiveLightingController? { adaptiveLightingBox.withLockedValue { $0.controller } }
    let adaptiveLightingBox = NIOLockedValueBox(WeakAdaptiveLighting())
    struct WeakAdaptiveLighting { weak var controller: AdaptiveLightingController? }

    /// Creates a service with its required characteristics, plus the `optional` ones you list; an optional type the
    /// service already has (a required one with other bounds, say) replaces it.
    ///
    /// Pass `name` to add a Name characteristic. Extra characteristics (custom types, or types not
    /// listed in the definition) go in `extra`; one whose type the service already has replaces it, to give a
    /// required characteristic other props or a value. `linked` names the services this one groups.
    public init(
        _ type: ServiceType,
        name: String? = nil,
        subtype: String? = nil,
        optional: [CharacteristicType] = [],
        extra: [Characteristic] = [],
        linked: [Service] = [],
        isPrimary: Bool = false,
        isHidden: Bool = false
    ) {
        self.type = type
        self.subtype = subtype
        self.isPrimary = isPrimary
        self.isHidden = isHidden
        linkedBox.withLockedValue { $0 = linked }
        var characteristics = type.required.map { Characteristic($0) }
        var seen = Set(type.required.map(\.uuid))
        if let name, !seen.contains(CharacteristicType.name.uuid) {
            characteristics.append(Characteristic(.name, value: .string(name)))
            seen.insert(CharacteristicType.name.uuid)
        }
        // An optional type already there with other props replaces it in place, so
        // `optional: [.targetTemperature.with(minValue: 30)]` works as setProps; the value carries over when it fits.
        for optionalType in optional {
            if let index = characteristics.firstIndex(where: { $0.type.uuid == optionalType.uuid }) {
                let existing = characteristics[index]
                if existing.type != optionalType {
                    characteristics[index] = Characteristic(optionalType, value: existing.value)
                }
            } else {
                characteristics.append(Characteristic(optionalType))
                seen.insert(optionalType.uuid)
            }
        }
        // An extra of a type already there replaces it in place, so `extra` can change the props of a required or
        // optional characteristic (HAP-NodeJS's setProps).
        for characteristic in extra {
            if let index = characteristics.firstIndex(where: { $0.type.uuid == characteristic.type.uuid }) {
                characteristics[index] = characteristic
            } else {
                characteristics.append(characteristic)
                seen.insert(characteristic.type.uuid)
            }
        }
        characteristicsBox = NIOLockedValueBox(characteristics)
    }

    /// The characteristic of the given type, if the service has it.
    public subscript(type: CharacteristicType) -> Characteristic? {
        characteristics.first { $0.type.uuid == type.uuid }
    }

    /// The characteristic of the given type, added when the service does not have it yet (HAP-NodeJS's
    /// `getCharacteristic`). Add characteristics before the accessory goes on a server: iids are given then.
    @discardableResult
    public func characteristic(adding type: CharacteristicType) -> Characteristic {
        characteristicsBox.withLockedValue { list in
            if let existing = list.first(where: { $0.type.uuid == type.uuid }) { return existing }
            let added = Characteristic(type)
            list.append(added)
            return added
        }
    }

    /// Copies the values another service (the same one on a cached accessory) had, when they still fit: readable
    /// characteristics only, not Name (the accessory's own name wins), nor an empty Configured Name, nor a value the
    /// new bounds reject.
    public func takeValues(from old: Service) {
        for characteristic in characteristics
        where characteristic.type.permissions.contains(.pairedRead) && characteristic.type.uuid != CharacteristicType.name.uuid {
            guard let previous = old[characteristic.type]?.value, previous != .null, let value = characteristic.type.coerce(previous) else {
                continue
            }
            if characteristic.type.uuid == CharacteristicType.configuredName.uuid, value.stringValue?.isEmpty != false { continue }
            characteristic.value = value
        }
    }

    /// The characteristic of the given type. Traps if the service does not have it.
    public func characteristic(_ type: CharacteristicType) -> Characteristic {
        guard let characteristic = self[type] else {
            preconditionFailure("\(self.type.name) has no \(type.name) characteristic")
        }
        return characteristic
    }
}

/// A device a service stands for, that HAP has no service type for.
public enum ServiceStandsFor: String, Sendable, Equatable, Codable {
    /// A cleaning robot (a robot vacuum, a pool robot) on a Switch: On while it cleans.
    case cleaningRobot
}
