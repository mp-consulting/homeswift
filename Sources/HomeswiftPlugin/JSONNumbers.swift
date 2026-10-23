import Homeswift
import HomeswiftAI

extension JSONValue {
    /// A number truncated toward zero and clamped to `Int`'s range, as `Int(saturating:)` does; nil for anything
    /// else. `intValue` is the strict form (whole numbers only). Device and cloud JSON reach this, so a 1e300 or a
    /// fraction never traps.
    public var saturatingIntValue: Int? {
        doubleValue.flatMap { Int(saturating: $0) }
    }

    /// The same, clamped to `range`.
    public func saturatingIntValue(in range: ClosedRange<Int>) -> Int? {
        doubleValue.flatMap { Int(saturating: $0, in: range) }
    }
}
