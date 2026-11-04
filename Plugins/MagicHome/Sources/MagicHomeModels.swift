import Foundation

/// How a device takes its commands (section 10.1), chosen from its model and version bytes.
enum MagicHomeFamily: String, Sendable {
    case original, originalRGBW, originalCCT
    case eightByte, eightByteAutoOn, eightByteDimmableEffects
    case nineByte, nineByteAutoOn, nineByteDimmableEffects
    case twentyFiveByte, extendedCustom
    case cct, cctWrapped, socket
    case addressableV1, addressableV2, addressableV3, christmas

    /// The original LEDENET protocol (`EF 01 77`, no checksums), which the plugin does not speak.
    var isOriginal: Bool { self == .original || self == .originalRGBW || self == .originalCCT }

    /// Whether levels need `71 23 0F` first: the auto-on families must not get it, an extra power frame flashes some.
    var needsPowerOn: Bool {
        switch self {
        case .original, .originalRGBW, .originalCCT, .eightByte, .nineByte, .twentyFiveByte, .extendedCustom, .cct: true
        default: false
        }
    }

    /// Whether the device sends its changes (power, state or both) on an open connection.
    var pushes: Bool {
        switch self {
        case .eightByteDimmableEffects, .nineByteDimmableEffects, .cct, .cctWrapped, .socket, .addressableV1, .addressableV3, .christmas: true
        default: false
        }
    }

    /// Whether queries and power frames go inside the wrapper (level frames of the 25-byte families always do).
    var wrapsRequests: Bool { self == .cctWrapped || self == .addressableV3 || self == .christmas }

    /// Whether levels are the 8-byte body (`31 R G B WW CW M 0F`) rather than the 7-byte one.
    var nineByteLevels: Bool {
        switch self {
        case .nineByte, .nineByteAutoOn, .nineByteDimmableEffects, .addressableV1: true
        default: false
        }
    }
}

/// What a light's channels can show at once (section 10.2's colour modes).
enum MagicHomeColourMode: String, Sendable {
    /// Colour only.
    case rgb
    /// Colour and one white together.
    case rgbw
    /// Colour, warm and cool together.
    case rgbww
    /// Colour or one white.
    case rgbOrWhite
    /// Colour or a tunable white.
    case rgbOrCCT
    /// One white channel.
    case dim
    /// Warm and cool.
    case cct
    /// An addressable strip, colour only.
    case addressable
    /// No light to set: a switch, a plant grow light, a clock.
    case none

    var hasColour: Bool { [.rgb, .rgbw, .rgbww, .rgbOrWhite, .rgbOrCCT, .addressable].contains(self) }
    var hasTemperature: Bool { [.rgbww, .rgbOrCCT, .cct].contains(self) }

    /// flux_led's `BASE_MODE_MAP`, the low nibble of a multi-mode controller's mode byte.
    static func base(_ nibble: UInt8) -> MagicHomeColourMode? {
        switch nibble {
        case 0x01: .dim
        case 0x02: .cct
        case 0x03: .rgb
        case 0x04: .rgbw
        case 0x05: .rgbww
        case 0x06: .rgbOrWhite
        case 0x07: .rgbOrCCT
        default: nil
        }
    }
}

/// One row of section 10.2's model table.
struct MagicHomeModel: Sendable {
    enum Modes: Sendable {
        case fixed(MagicHomeColourMode)
        /// Decided from state byte 4 (section 10.4.1).
        case byModeByte
    }

    /// Where the whites travel in the levels and the state.
    enum Remap: Sendable {
        case none
        /// The single white level in the red byte (`W↔R`).
        case whiteInRed
        /// Warm in the red byte, cool in the green byte (`WW↔R, CW↔G`).
        case warmRedCoolGreen
        /// Temperature and brightness in percent: `35 B1` frames, state bytes 9 and 11.
        case percent
    }

    let byte: UInt8
    let description: String
    /// `(minimum version, family)`, highest minimum first.
    let families: [(minimum: UInt8, family: MagicHomeFamily)]
    let modes: Modes
    var remap: Remap = .none
    /// Always writes white and colours together (mask `00`).
    var writesAllTogether = false
    var isSwitch = false

    /// The first pair whose minimum the version reaches, else the last pair's.
    func family(version: UInt8) -> MagicHomeFamily {
        families.first { version >= $0.minimum }?.family ?? families[families.count - 1].family
    }

    /// The colour mode a state's mode byte gives.
    func colourMode(modeByte: UInt8) -> MagicHomeColourMode {
        switch modes {
        case .fixed(let mode): return mode
        case .byModeByte: break
        }
        let low = modeByte & 0x0F
        switch byte {
        case 0x06: return low == 0x06 ? .rgbOrWhite : .rgbw
        case 0x07: return low == 0x07 ? .rgbOrCCT : .rgbww
        // A mode byte of 0 is the factory default, RGBWW.
        case 0x25: return MagicHomeColourMode.base(low) ?? .rgbww
        default: return MagicHomeColourMode.base(low) ?? .rgb
        }
    }

    static func only(_ family: MagicHomeFamily) -> [(minimum: UInt8, family: MagicHomeFamily)] { [(0, family)] }

    /// Section 10.2, by model byte.
    static let table: [UInt8: MagicHomeModel] = {
        let rows: [MagicHomeModel] = [
            MagicHomeModel(byte: 0x01, description: "Legacy Controller RGB", families: only(.original), modes: .fixed(.rgb)),
            MagicHomeModel(byte: 0x02, description: "Legacy Controller Dimmable", families: only(.original), modes: .fixed(.dim), remap: .whiteInRed),
            MagicHomeModel(byte: 0x03, description: "Legacy Controller CCT", families: only(.originalCCT), modes: .fixed(.cct), remap: .warmRedCoolGreen),
            MagicHomeModel(byte: 0x04, description: "Controller RGB&W", families: [(6, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.rgbw), writesAllTogether: true),
            MagicHomeModel(byte: 0x06, description: "Controller RGBW", families: [(2, .eightByteDimmableEffects), (1, .eightByteAutoOn), (0, .eightByte)], modes: .byModeByte),
            MagicHomeModel(byte: 0x07, description: "Controller RGBCW", families: [(2, .nineByteDimmableEffects), (0, .nineByte)], modes: .byModeByte),
            MagicHomeModel(byte: 0x08, description: "Controller RGB with MIC", families: [(2, .eightByteDimmableEffects), (1, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.rgb), writesAllTogether: true),
            MagicHomeModel(byte: 0x09, description: "High Voltage Bulb CCT", families: only(.cct), modes: .fixed(.cct), remap: .percent),
            MagicHomeModel(byte: 0x0B, description: "Switch 1 Channel", families: only(.eightByte), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x0E, description: "Floor Lamp RGBCW", families: [(9, .nineByteDimmableEffects), (7, .nineByteAutoOn), (0, .nineByte)], modes: .fixed(.rgbOrCCT)),
            MagicHomeModel(byte: 0x10, description: "Christmas Light", families: only(.christmas), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0x16, description: "Magnetic Light CCT", families: only(.eightByte), modes: .fixed(.cct), remap: .warmRedCoolGreen, writesAllTogether: true),
            MagicHomeModel(byte: 0x17, description: "Magnetic Light Dimable", families: only(.eightByte), modes: .fixed(.dim), remap: .whiteInRed, writesAllTogether: true),
            MagicHomeModel(byte: 0x18, description: "Plant Grow Light", families: only(.eightByte), modes: .fixed(.none)),
            MagicHomeModel(byte: 0x19, description: "Socket with 2 USB", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x1A, description: "String Lights", families: only(.christmas), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0x1B, description: "Aroma Fragrance Light", families: only(.eightByte), modes: .fixed(.rgb)),
            MagicHomeModel(byte: 0x1C, description: "Table Light CCT", families: only(.cctWrapped), modes: .fixed(.cct), remap: .percent),
            MagicHomeModel(byte: 0x1D, description: "Fill Light", families: only(.eightByteAutoOn), modes: .fixed(.dim), remap: .whiteInRed, writesAllTogether: true),
            MagicHomeModel(byte: 0x1E, description: "Ceiling Light RGBCW", families: [(9, .nineByteDimmableEffects), (7, .nineByteAutoOn), (0, .nineByte)], modes: .fixed(.rgbOrCCT)),
            MagicHomeModel(byte: 0x21, description: "Bulb Dimmable", families: [(2, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.dim), remap: .whiteInRed, writesAllTogether: true),
            MagicHomeModel(byte: 0x25, description: "Controller RGB/WW/CW", families: only(.nineByte), modes: .byModeByte, writesAllTogether: true),
            MagicHomeModel(byte: 0x33, description: "Controller RGB", families: [(9, .eightByteDimmableEffects), (6, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.rgb), writesAllTogether: true),
            MagicHomeModel(byte: 0x35, description: "Bulb RGBCW", families: [(10, .twentyFiveByte), (9, .nineByteDimmableEffects), (7, .nineByteAutoOn), (0, .nineByte)], modes: .fixed(.rgbOrCCT)),
            MagicHomeModel(byte: 0x41, description: "Controller Dimmable", families: [(2, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.dim), remap: .whiteInRed),
            MagicHomeModel(byte: 0x44, description: "Bulb RGBW", families: [(9, .eightByteAutoOn), (0, .eightByte)], modes: .fixed(.rgbOrWhite)),
            MagicHomeModel(byte: 0x45, description: "Controller RGB", families: only(.eightByte), modes: .fixed(.rgb)),
            MagicHomeModel(byte: 0x52, description: "Bulb CCT", families: only(.eightByte), modes: .fixed(.cct), remap: .warmRedCoolGreen, writesAllTogether: true),
            MagicHomeModel(byte: 0x54, description: "Downlight RGBW", families: only(.eightByte), modes: .fixed(.rgbOrWhite)),
            MagicHomeModel(byte: 0x62, description: "Controller CCT", families: only(.eightByte), modes: .fixed(.cct), remap: .warmRedCoolGreen, writesAllTogether: true),
            MagicHomeModel(byte: 0x81, description: "Controller RGBW", families: only(.eightByte), modes: .fixed(.rgbw), writesAllTogether: true),
            MagicHomeModel(byte: 0x93, description: "Switch", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x94, description: "Switch Watt", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x95, description: "Switch 2 Channel", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x96, description: "Switch 4 Channel", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0x97, description: "Socket", families: only(.socket), modes: .fixed(.none), isSwitch: true),
            MagicHomeModel(byte: 0xA1, description: "Addressable v1", families: only(.addressableV1), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xA2, description: "Addressable v2", families: only(.addressableV2), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xA3, description: "Addressable v3", families: only(.addressableV3), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xA4, description: "Addressable v4", families: only(.addressableV3), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xA6, description: "Addressable v6", families: only(.addressableV3), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xA7, description: "Addressable v7", families: only(.addressableV3), modes: .fixed(.addressable)),
            MagicHomeModel(byte: 0xB6, description: "Surplife Outdoor Permanent Lighting", families: only(.extendedCustom), modes: .fixed(.rgbOrWhite)),
            MagicHomeModel(byte: 0xD1, description: "Digital Time Light", families: only(.eightByte), modes: .fixed(.none)),
            MagicHomeModel(byte: 0xE1, description: "Ceiling Light CCT", families: only(.eightByte), modes: .fixed(.cct), remap: .warmRedCoolGreen, writesAllTogether: true),
            MagicHomeModel(byte: 0xE2, description: "Ceiling Light CCT Assist", families: only(.eightByte), modes: .fixed(.cct), remap: .warmRedCoolGreen, writesAllTogether: true),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.byte, $0) })
    }()
}

/// The Homebridge plugin's "controller logic types" (section 1): how it drove the models it knew.
enum MagicHomeLogic: String, Sendable {
    case rgbStrip = "RGBStrip"
    case grbStrip = "GRBStrip"
    case rgbwBulb = "RGBWBulb"
    case rgbwStrip = "RGBWStrip"
    case rgbwwStrip = "RGBWWStrip"
    case rgbwwBulb = "RGBWWBulb"
    case cctStrip = "CCTStrip"
    case dimmerStrip = "DimmerStrip"
    case `switch` = "Switch"

    /// The name a new accessory gets (`convenientName`).
    var convenientName: String {
        switch self {
        case .rgbStrip: "RGB Strip"
        case .grbStrip: "GRB Strip"
        case .rgbwBulb: "RGBW Non-Simultaneous"
        case .rgbwStrip: "RGBW Simultaneous"
        case .rgbwwStrip: "RGBWW Simultaneous"
        case .rgbwwBulb: "RGBWW Non-Simultaneous"
        case .cctStrip: "CCT Strip"
        case .dimmerStrip: "Dimmer"
        case .switch: "Power Socket"
        }
    }

    /// Section 1's table, by type byte.
    static let table: [UInt8: MagicHomeLogic] = [
        0x04: .rgbwStrip, 0x06: .rgbwStrip, 0x07: .rgbwwStrip, 0x09: .cctStrip, 0x21: .dimmerStrip, 0x25: .rgbwwStrip, 0x33: .grbStrip,
        0x35: .rgbwwBulb, 0x41: .dimmerStrip, 0x44: .rgbwBulb, 0x52: .rgbwwBulb, 0x65: .dimmerStrip, 0x93: .switch, 0x97: .switch,
        0xA1: .rgbStrip, 0xA2: .rgbStrip,
    ]
}

/// What a device is to the plugin: its family, the HomeKit service and characteristics it gets, and how its levels are
/// written. Made from its model, version and mode bytes; an accessory is rebuilt when a new state gives another one.
struct MagicHomeProfile: Sendable, Equatable {
    /// How HomeKit's colour and brightness become levels.
    enum Writer: Sendable, Equatable {
        /// The Homebridge plugin's branches (section 5.2), for the models it drove well.
        case original(MagicHomeLogic)
        /// `35 B1` temperature and brightness (`09`, `1C`; section 10.7).
        case percentCCT
        /// Warm in the red byte, cool in the green byte (`52`, `16`, `62`, `E1`, `E2`).
        case remappedCCT
        /// flux_led's rules for the family (section 10.3).
        case family
        /// Power only.
        case powerOnly
    }

    var model: UInt8
    var version: UInt8
    var family: MagicHomeFamily
    var mode: MagicHomeColourMode
    var writer: Writer
    var isSwitch: Bool
    var hasBrightness: Bool
    var hasColour: Bool
    var hasTemperature: Bool
    var description: String

    /// The characteristics an accessory has: when they change, the accessory is rebuilt.
    var shape: [Bool] { [isSwitch, hasBrightness, hasColour, hasTemperature] }

    var logic: MagicHomeLogic? {
        if case .original(let logic) = writer { return logic }
        return nil
    }

    /// The Device Kind of Setup and Accessory Settings.
    var deviceKind: String { isSwitch ? "switch" : "light" }

    /// The profile of a model, version and mode byte; nil for a device the plugin does not drive: the original protocol,
    /// or a model byte neither table knows.
    static func make(model: UInt8, version: UInt8, modeByte: UInt8) -> MagicHomeProfile? {
        let logic = MagicHomeLogic.table[model]
        let row = MagicHomeModel.table[model]
        guard row != nil || logic != nil else { return nil }
        // `65` is only in the Homebridge plugin's table: the family that answered the 8-byte query.
        let family = row?.family(version: version) ?? .eightByte
        guard !family.isOriginal else { return nil }
        let mode = row?.colourMode(modeByte: modeByte) ?? (logic == .dimmerStrip ? .dim : .rgb)
        let description = row?.description ?? logic?.convenientName ?? "Magic Home"
        let isSwitch = row?.isSwitch ?? (logic == .switch)
        if isSwitch {
            return MagicHomeProfile(
                model: model, version: version, family: family, mode: .none, writer: .powerOnly, isSwitch: true, hasBrightness: false,
                hasColour: false, hasTemperature: false, description: description)
        }
        let writer: Writer
        switch (model, logic) {
        // Section 10's corrections of the Homebridge plugin's table.
        case (_, _) where row?.remap == .percent: writer = .percentCCT
        case (_, _) where row?.remap == .warmRedCoolGreen: writer = .remappedCCT
        case (0x35, _) where family == .twentyFiveByte: writer = .family
        case (0xA1, _), (0xA2, _): writer = .family
        case (_, .some(let logic)): writer = .original(logic)
        default: writer = mode == .none ? .powerOnly : .family
        }
        var hasColour = mode.hasColour
        var hasTemperature = mode.hasTemperature
        switch writer {
        case .original(let logic):
            // As the Homebridge plugin: Hue and Saturation on every colour type; a tunable white where section 10.7 has it.
            hasColour = logic != .dimmerStrip
            hasTemperature = logic == .rgbwwBulb || (logic == .rgbwwStrip && mode.hasTemperature)
        case .percentCCT, .remappedCCT:
            hasColour = false
            hasTemperature = true
        case .family, .powerOnly:
            break
        }
        return MagicHomeProfile(
            model: model, version: version, family: family, mode: mode, writer: writer, isSwitch: false,
            hasBrightness: mode != .none, hasColour: hasColour, hasTemperature: hasTemperature, description: description)
    }

    /// Whether a level frame needs `71 23 0F` before it: the Homebridge plugin's rule on the firmware byte for the models
    /// it drove (2 to 5, 8, or 1 on an `HF-LPB100-ZJ200` module), the family's otherwise.
    func needsPowerOnFirst(module: String) -> Bool {
        if case .original = writer {
            return (2...5).contains(version) || version == 8 || (version == 1 && module.contains("HF-LPB100-ZJ200"))
        }
        return family.needsPowerOn
    }

    /// The name a new accessory gets: the Homebridge plugin's for the models it drives as it did, the model's description
    /// otherwise;
    /// `<Bulb|Strip|Switch|LED> <last 6 of the MAC>` with `namesWithMacAddress`.
    func defaultName(mac: String, withMAC: Bool) -> String {
        let logic = MagicHomeLogic.table[model]
        guard withMAC else { return isSwitch || self.logic != nil ? logic?.convenientName ?? description : description }
        let kind = (logic?.rawValue ?? description).lowercased()
        let prefix: String
        if kind.contains("bulb") {
            prefix = "Bulb"
        } else if kind.contains("strip") || kind.contains("controller") || kind.contains("addressable") || kind.contains("string") {
            prefix = "Strip"
        } else if kind.contains("switch") || kind.contains("socket") {
            prefix = "Switch"
        } else {
            prefix = "LED"
        }
        return "\(prefix) \(mac.suffix(6))"
    }
}
