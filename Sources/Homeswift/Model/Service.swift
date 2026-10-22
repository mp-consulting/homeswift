import NIOConcurrencyHelpers

/// A group of characteristics that make up one function of an accessory, such as a lightbulb.
public final class Service: @unchecked Sendable {
    public let type: ServiceType
    /// Distinguishes several services of the same type on one accessory (e.g. two outlets).
    public let subtype: String?
    public let characteristics: [Characteristic]
    public let isPrimary: Bool
    public let isHidden: Bool

    let iidBox = NIOLockedValueBox(0)
    public var iid: Int { iidBox.withLockedValue { $0 } }

    private let linkedBox = NIOLockedValueBox<[Service]>([])
    /// Services of the same accessory this one groups, listed by iid as `linked`: a Television lists its
    /// input sources and speaker, so the Home app shows them with it.
    public var linked: [Service] {
        get { linkedBox.withLockedValue { $0 } }
        set { linkedBox.withLockedValue { $0 = newValue } }
    }

    /// Creates a service with its required characteristics, plus the `optional` ones you list.
    ///
    /// Pass `name` to add a Name characteristic. Extra characteristics (custom types, or types not
    /// listed in the definition) go in `extra`. `linked` names the services this one groups.
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
        for optionalType in optional where !seen.contains(optionalType.uuid) {
            characteristics.append(Characteristic(optionalType))
            seen.insert(optionalType.uuid)
        }
        for characteristic in extra where !seen.contains(characteristic.type.uuid) {
            characteristics.append(characteristic)
            seen.insert(characteristic.type.uuid)
        }
        self.characteristics = characteristics
    }

    /// The characteristic of the given type, if the service has it.
    public subscript(type: CharacteristicType) -> Characteristic? {
        characteristics.first { $0.type.uuid == type.uuid }
    }

    /// The characteristic of the given type. Traps if the service does not have it.
    public func characteristic(_ type: CharacteristicType) -> Characteristic {
        guard let characteristic = self[type] else {
            preconditionFailure("\(self.type.name) has no \(type.name) characteristic")
        }
        return characteristic
    }
}
