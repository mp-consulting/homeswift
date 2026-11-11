import Homeswift

/// Independent swing axes for climate widgets. Keep the standard Swing Mode alongside these for
/// HomeKit controllers that only understand the combined control. Add only writable device axes.
public enum ClimateSwing: String, CaseIterable, Sendable {
    case vertical, horizontal

    public var characteristic: CharacteristicType { self == .vertical ? Self.verticalType : Self.horizontalType }

    private static let verticalType = CharacteristicType(name: "Vertical Swing", uuid: HAPUUID("37C21A90-B2EC-4C72-9270-7631A2134031"),
        format: .bool, permissions: [.pairedRead, .pairedWrite, .events])
    private static let horizontalType = CharacteristicType(name: "Horizontal Swing", uuid: HAPUUID("37C21A90-B2EC-4C72-9270-7631A2134032"),
        format: .bool, permissions: [.pairedRead, .pairedWrite, .events])
}
