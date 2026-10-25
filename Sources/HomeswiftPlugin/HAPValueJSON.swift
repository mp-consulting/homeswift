import Homeswift
import HomeswiftAI

extension JSONValue {
    /// A characteristic's value as JSON.
    public init(_ value: HAPValue) {
        switch value {
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .number(Double(int))
        case .double(let double): self = .number(double)
        case .string(let string): self = .string(string)
        case .null: self = .null
        }
    }
}

extension HAPValue {
    /// A characteristic's value from JSON: a whole number is an int, any other number a double; nil for an array or
    /// an object.
    public init?(_ json: JSONValue) {
        switch json {
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = Int(exactly: number).map(HAPValue.int) ?? .double(number)
        case .string(let string): self = .string(string)
        case .null: self = .null
        default: return nil
        }
    }
}
