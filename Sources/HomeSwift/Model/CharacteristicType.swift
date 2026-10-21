public enum CharacteristicFormat: String, Sendable, Codable {
    case bool, uint8, uint16, uint32, uint64, int, float, string, tlv8, data
}

public enum CharacteristicPermission: String, Sendable, Codable, CaseIterable {
    case pairedRead = "pr"
    case pairedWrite = "pw"
    case events = "ev"
    case additionalAuthorization = "aa"
    case timedWrite = "tw"
    case hidden = "hd"
    case writeResponse = "wr"
}

public enum CharacteristicUnit: String, Sendable, Codable {
    case celsius, percentage, arcdegrees, lux, seconds
}

/// The definition of a characteristic: its UUID, format, permissions and constraints.
///
/// Apple's types are generated into `Definitions.swift` (`CharacteristicType.on`, `.brightness`, ...).
/// Define your own with a full UUID for custom characteristics.
public struct CharacteristicType: Sendable, Hashable {
    public var name: String
    public var uuid: HAPUUID
    public var format: CharacteristicFormat
    public var permissions: Set<CharacteristicPermission>
    public var unit: CharacteristicUnit?
    public var minValue: Double?
    public var maxValue: Double?
    public var minStep: Double?
    public var maxLength: Int?
    public var validValues: [Int]?
    public var validValueRange: ClosedRange<Int>?

    public init(
        name: String,
        uuid: HAPUUID,
        format: CharacteristicFormat,
        permissions: Set<CharacteristicPermission>,
        unit: CharacteristicUnit? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        minStep: Double? = nil,
        maxLength: Int? = nil,
        validValues: [Int]? = nil,
        validValueRange: ClosedRange<Int>? = nil
    ) {
        self.name = name
        self.uuid = uuid
        self.format = format
        self.permissions = permissions
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.minStep = minStep
        self.maxLength = maxLength
        self.validValues = validValues
        self.validValueRange = validValueRange
    }

    /// The same type with different bounds, e.g. `.currentTemperature.with(minValue: -40)`.
    public func with(minValue: Double? = nil, maxValue: Double? = nil, minStep: Double? = nil, validValues: [Int]? = nil) -> Self {
        var copy = self
        if let minValue { copy.minValue = minValue }
        if let maxValue { copy.maxValue = maxValue }
        if let minStep { copy.minStep = minStep }
        if let validValues { copy.validValues = validValues }
        return copy
    }

    var defaultValue: HAPValue {
        switch format {
        case .bool: .bool(false)
        case .uint8, .uint16, .uint32, .uint64, .int:
            .int(validValues?.first ?? Int(minValue ?? 0))
        case .float: .double(minValue ?? 0)
        case .string, .tlv8, .data: .string("")
        }
    }

    /// Converts a value to this type's format and checks its bounds. Returns nil when it does not fit.
    public func coerce(_ value: HAPValue) -> HAPValue? {
        switch format {
        case .bool:
            return value.boolValue.map(HAPValue.bool)
        case .uint8, .uint16, .uint32, .uint64, .int:
            guard let int = value.intValue else { return nil }
            let bounds: ClosedRange<Int> =
                switch format {
                case .uint8: 0...Int(UInt8.max)
                case .uint16: 0...Int(UInt16.max)
                case .uint32: 0...Int(UInt32.max)
                case .uint64: 0...Int.max
                default: Int(Int32.min)...Int(Int32.max)
                }
            guard bounds.contains(int) else { return nil }
            if let minValue, Double(int) < minValue { return nil }
            if let maxValue, Double(int) > maxValue { return nil }
            if let validValues, !validValues.contains(int) { return nil }
            if let validValueRange, !validValueRange.contains(int) { return nil }
            return .int(int)
        case .float:
            guard let double = value.doubleValue, double.isFinite else { return nil }
            let tolerance = (minStep ?? 0) / 2
            if let minValue, double < minValue - tolerance { return nil }
            if let maxValue, double > maxValue + tolerance { return nil }
            return .double(double)
        case .string:
            guard let string = value.stringValue, string.utf8.count <= (maxLength ?? 64) else { return nil }
            return .string(string)
        case .tlv8, .data:
            return value.stringValue.map(HAPValue.string)
        }
    }
}

/// The definition of a service: its UUID and the characteristics it requires or allows.
public struct ServiceType: Sendable, Hashable {
    public var name: String
    public var uuid: HAPUUID
    public var required: [CharacteristicType]
    public var optional: [CharacteristicType]

    public init(name: String, uuid: HAPUUID, required: [CharacteristicType], optional: [CharacteristicType] = []) {
        self.name = name
        self.uuid = uuid
        self.required = required
        self.optional = optional
    }
}
