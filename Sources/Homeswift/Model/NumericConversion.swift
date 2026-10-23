/// Integer conversions that never trap. `Int(someDouble)` traps on NaN, ±infinity and values outside the type's range,
/// and numbers from devices, clouds, config files and controllers reach those conversions; these clamp instead.
/// For an integer source the standard library's `init(clamping:)` already does this (`Int(clamping: someUInt64)`).
extension FixedWidthInteger {
    /// `value` rounded toward zero like `init(_:)`, clamped to the type's range; nil for NaN.
    @inlinable
    public init?<Source: BinaryFloatingPoint>(saturating value: Source) {
        guard !value.isNaN else { return nil }
        if let exact = Self(exactly: value.rounded(.towardZero)) {
            self = exact
        } else {
            // Out of range (or infinite): the sign says which end.
            self = value < 0 ? .min : .max
        }
    }

    /// `value` rounded toward zero, clamped to `range`; nil for NaN.
    @inlinable
    public init?<Source: BinaryFloatingPoint>(saturating value: Source, in range: ClosedRange<Self>) {
        guard let converted = Self(saturating: value) else { return nil }
        self = Swift.min(Swift.max(converted, range.lowerBound), range.upperBound)
    }
}

extension BinaryFloatingPoint {
    /// The value when finite, else nil: for readings that must not reach arithmetic, JSON or storage as NaN or ±inf.
    @inlinable
    public var finite: Self? { isFinite ? self : nil }
}
