import Foundation
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
    /// A string's longest value in UTF-8 bytes: 64 when nil, at most `maxStringLength` whatever it says.
    public var maxLength: Int?
    /// A data value's longest base64 string: `defaultMaxDataLength` when nil.
    public var maxDataLength: Int?
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
        validValueRange: ClosedRange<Int>? = nil,
        maxDataLength: Int? = nil
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
        self.maxDataLength = maxDataLength
    }

    /// The spec's limit on any string's `maxLen` (HAP-NodeJS caps it there too).
    public static let maxStringLength = 256
    /// A data value's limit without `maxDataLength`, as HAP-NodeJS's and the ADK's (2 MiB).
    public static let defaultMaxDataLength = 0x200000

    /// The longest string a value may be.
    var stringLimit: Int { min(maxLength ?? 64, Self.maxStringLength) }

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
            .int(validValues?.first ?? minValue.flatMap { Int(saturating: $0) } ?? 0)
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
            guard var int = value.intValue else { return nil }
            let bounds: ClosedRange<Int> =
                switch format {
                case .uint8: 0...Int(UInt8.max)
                case .uint16: 0...Int(UInt16.max)
                case .uint32: 0...Int(UInt32.max)
                case .uint64: 0...Int.max
                default: Int(Int32.min)...Int(Int32.max)
                }
            if let minStep, minStep > 1 { int = Int(Self.round(Double(int), toStep: minStep, from: minValue ?? 0)) }
            guard bounds.contains(int) else { return nil }
            if let minValue, Double(int) < minValue { return nil }
            if let maxValue, Double(int) > maxValue { return nil }
            if let validValues, !validValues.contains(int) { return nil }
            if let validValueRange, !validValueRange.contains(int) { return nil }
            return .int(int)
        case .float:
            guard var double = value.doubleValue, double.isFinite else { return nil }
            if let minStep, minStep > 0 { double = Self.round(double, toStep: minStep, from: minValue ?? 0) }
            let tolerance = (minStep ?? 0) / 2
            if let minValue, double < minValue - tolerance { return nil }
            if let maxValue, double > maxValue + tolerance { return nil }
            return .double(double)
        case .string:
            guard let string = value.stringValue, string.utf8.count <= stringLimit else { return nil }
            return .string(string)
        case .data:
            // As HAP-NodeJS, the base64 text is measured, not decoded.
            guard let string = value.stringValue, string.utf8.count <= maxDataLength ?? Self.defaultMaxDataLength else { return nil }
            return .string(string)
        case .tlv8:
            return value.stringValue.map(HAPValue.string)
        }
    }

    /// `value` on the grid of `step` from `base`, as HAP-NodeJS rounds the values plugins set: 21.43 with a step of
    /// 0.1 is 21.4. Kept to the decimals of the step and the base, without binary noise (21.400000000000002).
    static func round(_ value: Double, toStep step: Double, from base: Double) -> Double {
        let stepped = step * ((value - base) / step).rounded() + base
        let scale = pow(10, Double(max(decimals(step), decimals(base))))
        return (stepped * scale).rounded() / scale
    }

    /// How many decimals `value` has, up to 10.
    private static func decimals(_ value: Double) -> Int {
        var scaled = value
        for count in 0..<10 {
            if abs(scaled - scaled.rounded()) < 1e-9 * max(1, abs(scaled)) { return count }
            scaled *= 10
        }
        return 10
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

extension CharacteristicType {
    private static let byUUID = Dictionary(all.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })

    /// Apple's type with this UUID, from `Definitions.swift`: for plugins that learn types from another controller
    /// (Wingman reads them from HomeKit) and want the names and props Homeswift's own accessories have.
    public static func known(uuid: HAPUUID) -> CharacteristicType? { byUUID[uuid] }
}

extension ServiceType {
    private static let byUUID = Dictionary(all.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })

    /// Apple's service with this UUID, from `Definitions.swift`.
    public static func known(uuid: HAPUUID) -> ServiceType? { byUUID[uuid] }
}
