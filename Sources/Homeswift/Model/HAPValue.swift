/// A characteristic value as it travels in HAP JSON.
///
/// `tlv8` and `data` characteristics carry base64 strings.
public enum HAPValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported HAP value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string, .null: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .bool(let value): value ? 1 : 0
        case .int(let value): value
        case .double(let value): value.isFinite ? Int(value.rounded()) : nil
        case .string, .null: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .bool(let value): value ? 1 : 0
        case .int(let value): Double(value)
        case .double(let value): value
        case .string, .null: nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension HAPValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByNilLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(nilLiteral: ()) { self = .null }
}
