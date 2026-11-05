import Foundation

/// A built-in pattern of the 8- and 9-byte families (section 10.3.8): its id is state byte 3 while it plays.
struct MagicHomeEffect: Sendable, Equatable, Hashable {
    let id: UInt8
    let name: String
    /// Only the families with dimmable effects play it.
    var dimmableOnly = false

    /// The table of 10.3.8, in its order.
    static let all: [MagicHomeEffect] = [
        .init(id: 0x25, name: "Colour Loop"),
        .init(id: 0x26, name: "Red Gradual Change"),
        .init(id: 0x27, name: "Green Gradual Change"),
        .init(id: 0x28, name: "Blue Gradual Change"),
        .init(id: 0x29, name: "Yellow Gradual Change"),
        .init(id: 0x2A, name: "Cyan Gradual Change"),
        .init(id: 0x2B, name: "Purple Gradual Change"),
        .init(id: 0x2C, name: "White Gradual Change"),
        .init(id: 0x2D, name: "Red Green Cross Fade"),
        .init(id: 0x2E, name: "Red Blue Cross Fade"),
        .init(id: 0x2F, name: "Green Blue Cross Fade"),
        .init(id: 0x30, name: "Seven Colour Strobe"),
        .init(id: 0x31, name: "Red Strobe"),
        .init(id: 0x32, name: "Green Strobe"),
        .init(id: 0x33, name: "Blue Strobe"),
        .init(id: 0x34, name: "Yellow Strobe"),
        .init(id: 0x35, name: "Cyan Strobe"),
        .init(id: 0x36, name: "Purple Strobe"),
        .init(id: 0x37, name: "White Strobe"),
        .init(id: 0x38, name: "Seven Colour Jump"),
        .init(id: 0x24, name: "RGB Cross Fade", dimmableOnly: true),
        .init(id: 0x39, name: "RGB Cycle", dimmableOnly: true),
        .init(id: 0x3A, name: "Seven Colour Cycle", dimmableOnly: true),
    ]

    /// The switch's subtype: fixed, it keys the iids.
    var subtype: String { String(format: "effect:%02X", id) }

    /// The speed of 0 to 100 (100 fastest) as the frames' delay, 1 (fast) to 31 (slow).
    static func delay(speed: Int) -> UInt8 {
        let speed = min(max(speed, 0), 100)
        return UInt8((100 - speed) * 30 / 100 + 1)
    }
}

extension MagicHomeFamily {
    /// Whether the family plays 10.3.8's built-in patterns with the frames the plugin sends: the 8- and 9-byte families
    /// and the 25-byte ones. The original protocol is not spoken; the CCT families, sockets, addressable strips (patterns
    /// 1 to 300 without names) and Christmas lights get none.
    var playsEffects: Bool {
        switch self {
        case .eightByte, .eightByteAutoOn, .eightByteDimmableEffects, .nineByte, .nineByteAutoOn, .nineByteDimmableEffects, .twentyFiveByte, .extendedCustom: true
        default: false
        }
    }

    var hasDimmableEffects: Bool { self == .eightByteDimmableEffects || self == .nineByteDimmableEffects }
}

extension MagicHomeProfile {
    /// The patterns this light plays: colour lights of a family that plays them.
    var effects: [MagicHomeEffect] {
        guard !isSwitch, hasColour, family.playsEffects else { return [] }
        return MagicHomeEffect.all.filter { !$0.dimmableOnly || family.hasDimmableEffects }
    }
}

extension MagicHomeFrame {
    /// A built-in pattern (10.3.8): `38 id delay brightness%` on the dimmable-effects families, `61 id delay 0F` on the
    /// others, each with its checksum.
    static func effect(_ effect: MagicHomeEffect, speed: Int, brightness: Int, family: MagicHomeFamily) -> [UInt8] {
        let delay = MagicHomeEffect.delay(speed: speed)
        if family.hasDimmableEffects { return sealed([0x38, effect.id, delay, UInt8(min(max(brightness, 0), 100))]) }
        return sealed([0x61, effect.id, delay, 0x0F])
    }
}
