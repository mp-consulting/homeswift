import Foundation
import Homeswift

/// The bytes Magic Home's Wi-Fi modules speak on TCP 5577 (docs/clean-room/MagicHome.md, sections 4 and 10): frames with
/// an 8-bit sum checksum, the `B0 B1 B2 B3` wrapper some families need, and their replies.
enum MagicHomeFrame {
    /// The low 8 bits of the sum of `bytes` (section 4.2).
    static func checksum<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) })
    }

    /// `bytes` with their checksum appended.
    static func sealed(_ bytes: [UInt8]) -> [UInt8] { bytes + [checksum(bytes)] }

    // MARK: Requests (section 4.3, 10.3)

    /// `81 8A 8B 96`.
    static let stateQuery = sealed([0x81, 0x8A, 0x8B])

    /// `71 23 0F A3` on, `71 24 0F A4` off.
    static func power(_ on: Bool) -> [UInt8] { sealed([0x71, on ? 0x23 : 0x24, 0x0F]) }

    /// The 7-byte body (flux_led's "8-byte protocol"): `31 R G B W M 0F`, `41` instead of `31` when it is not kept.
    static func levels(red: UInt8, green: UInt8, blue: UInt8, white: UInt8, mask: UInt8, persist: Bool = true) -> [UInt8] {
        sealed([persist ? 0x31 : 0x41, red, green, blue, white, mask, 0x0F])
    }

    /// The 8-byte body (flux_led's "9-byte protocol"): `31 R G B WW CW M 0F`.
    static func levels(red: UInt8, green: UInt8, blue: UInt8, warm: UInt8, cool: UInt8, mask: UInt8, persist: Bool = true) -> [UInt8] {
        sealed([persist ? 0x31 : 0x41, red, green, blue, warm, cool, mask, 0x0F])
    }

    /// `35 B1 X Y 00 00 00 03`: a tunable white's temperature and brightness in percent (section 10.3.5).
    static func temperature(_ temperature: UInt8, brightness: UInt8) -> [UInt8] {
        sealed([0x35, 0xB1, temperature, brightness, 0x00, 0x00, 0x00, 0x03])
    }

    /// An addressable v2 strip's fixed colour, `41 01 R G B 00 00 00 60 FF 00 00` (section 10.3.7).
    static func addressableColour(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        sealed([0x41, 0x01, red, green, blue, 0x00, 0x00, 0x00, 0x60, 0xFF, 0x00, 0x00])
    }

    /// An addressable v2 strip's white level, `47 W`.
    static func addressableWhite(_ white: UInt8) -> [UInt8] { sealed([0x47, white]) }

    /// A Christmas light's colour, `3B A1 h s v` and seven zeros, with its own checksum before it is wrapped.
    static func christmasColour(hue: UInt8, saturation: UInt8, value: UInt8) -> [UInt8] {
        sealed([0x3B, 0xA1, hue, saturation, value, 0, 0, 0, 0, 0, 0, 0])
    }

    /// The 25-byte family's level frame, wrapped with version 2 and without a checksum of its own:
    /// `E0 01 00 M h s v T L 00 00 14 00 00`. `mask` is `A1` (colour), `B1` (white) or `00` (both).
    static func extendedLevels(mask: UInt8, hue: UInt8, saturation: UInt8, value: UInt8, temperature: UInt8, brightness: UInt8) -> [UInt8] {
        [0xE0, 0x01, 0x00, mask, hue, saturation, value, temperature, brightness, 0x00, 0x00, 0x14, 0x00, 0x00]
    }

    // Effects, the clock and the other queries (sections 10.3.8, 10.5): the plugin sends none of them (HomeKit has no
    // effects, and the bridge does not use the device's timers); they are here so their layouts are tested with the rest.

    /// A built-in pattern on the 8/9-byte families: `61 id delay 0F`.
    static func effect(_ pattern: UInt8, delay: UInt8) -> [UInt8] { sealed([0x61, pattern, delay, 0x0F]) }

    /// A built-in pattern on the dimmable-effects families: `38 id delay brightness%`.
    static func dimmableEffect(_ pattern: UInt8, delay: UInt8, brightness: UInt8) -> [UInt8] { sealed([0x38, pattern, delay, brightness]) }

    /// An addressable v1 effect, 1 to 300: `61 hi lo speed 0F`, `hi lo` the big-endian effect + 99.
    static func addressableV1Effect(_ effect: Int, speed: UInt8) -> [UInt8] {
        let code = UInt16(clamping: min(max(effect, 1), 300) + 99)
        return sealed([0x61, UInt8(code >> 8), UInt8(code & 0xFF), speed, 0x0F])
    }

    /// An addressable v2/v3 effect, 1 to 100: `42 id speed brightness%`.
    static func addressableEffect(_ effect: UInt8, speed: UInt8, brightness: UInt8) -> [UInt8] { sealed([0x42, effect, speed, brightness]) }

    /// A pattern's delay (1 fast, 31 slow) for a speed of 0 to 100.
    static func delay(speed: Int) -> UInt8 {
        let speed = min(max(speed, 0), 100)
        return UInt8((100 - speed) * 30 / 100 + 1)
    }

    /// The speed (0 to 100) of a delay of 1 to 31.
    static func speed(delay: Int) -> Int {
        let delay = min(max(delay, 1), 31)
        return 100 - (delay - 1) * 100 / 30
    }

    /// Sets the device's clock: `10 14 YY MM DD hh mm ss dow 00 0F`, `dow` 1 for Monday to 7 for Sunday.
    static func setTime(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, weekday: Int) -> [UInt8] {
        let fields = [year - 2000, month, day, hour, minute, second, weekday].map { UInt8(clamping: $0) }
        return sealed([0x10, 0x14] + fields + [0x00, 0x0F])
    }

    static let timeQuery = sealed([0x11, 0x1A, 0x1B, 0x0F])
    static let powerRestoreQuery = sealed([0x32, 0x3A, 0x3B, 0x0F])
    static let stripConfigurationQuery = sealed([0x63, 0x12, 0x21, 0x0F])
    /// An addressable v1 strip's, four literal bytes.
    static let addressableV1ConfigurationQuery: [UInt8] = [0x63, 0x12, 0x21, 0x36]
    /// Models with 2.4 GHz remotes; wrapped.
    static let remoteConfigurationQuery = sealed([0x2B, 0x2C, 0x2D])
}

/// The outer message some families need (section 10.3.6): `B0 B1 B2 B3 00 01`, a version, a counter, the inner length
/// big-endian, the inner message, and a checksum of everything before it.
struct MagicHomeWrapper: Sendable {
    static let header: [UInt8] = [0xB0, 0xB1, 0xB2, 0xB3, 0x00, 0x01]
    /// The longest inner message accepted from a device.
    static let maximumInnerLength = 512

    /// The counter of the next wrapped message: 0 first, up to 254, then 0 again (255 is never used).
    private(set) var counter: UInt8 = 0

    init(counter: UInt8 = 0) { self.counter = counter }

    mutating func wrap(_ inner: [UInt8], version: UInt8 = 1) -> [UInt8] {
        let message = Self.wrap(inner, version: version, counter: counter)
        counter = counter >= 254 ? 0 : counter + 1
        return message
    }

    static func wrap(_ inner: [UInt8], version: UInt8, counter: UInt8) -> [UInt8] {
        let length = UInt16(clamping: inner.count)
        return MagicHomeFrame.sealed(header + [version, counter, UInt8(length >> 8), UInt8(length & 0xFF)] + inner)
    }

    /// The inner message of a whole wrapped message whose header and checksum are right; nil otherwise.
    static func unwrap(_ message: [UInt8]) -> [UInt8]? {
        guard message.count >= 11, Array(message.prefix(6)) == header else { return nil }
        let length = Int(message[8]) << 8 | Int(message[9])
        guard message.count == 10 + length + 1, MagicHomeFrame.checksum(message.dropLast()) == message[message.count - 1] else { return nil }
        return Array(message[10..<(message.count - 1)])
    }
}

/// A state reply in the 14-byte layout (section 4.4, 10.4): the extended reply is converted to it.
struct MagicHomeState: Sendable, Equatable, Codable {
    var model: UInt8
    var isOn: Bool
    /// Byte 3: `61` static, `60` custom, `62` music, the others effects.
    var pattern: UInt8 = 0x61
    /// Byte 4: wiring and colour mode on multi-mode controllers.
    var mode: UInt8 = 0
    var speed: UInt8 = 0
    var red: UInt8 = 0
    var green: UInt8 = 0
    var blue: UInt8 = 0
    /// Byte 9; a tunable white's temperature in percent on `09`/`1C`.
    var warm: UInt8 = 0
    /// Byte 10, which picks the family.
    var version: UInt8 = 0
    /// Byte 11; a tunable white's brightness in percent on `09`/`1C`.
    var cool: UInt8 = 0
    /// Byte 12: `F0` colours were set last, `0F` whites, `00` both.
    var colourMode: UInt8 = 0

    init(model: UInt8, isOn: Bool, pattern: UInt8 = 0x61, mode: UInt8 = 0, speed: UInt8 = 0, red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0,
         warm: UInt8 = 0, version: UInt8 = 0, cool: UInt8 = 0, colourMode: UInt8 = 0) {
        self.model = model
        self.isOn = isOn
        self.pattern = pattern
        self.mode = mode
        self.speed = speed
        self.red = red
        self.green = green
        self.blue = blue
        self.warm = warm
        self.version = version
        self.cool = cool
        self.colourMode = colourMode
    }

    /// The standard reply: exactly 14 bytes, head `81`, a correct checksum.
    init?(standard bytes: [UInt8]) {
        guard bytes.count == 14, bytes[0] == 0x81, MagicHomeFrame.checksum(bytes.prefix(13)) == bytes[13] else { return nil }
        self.init(
            model: bytes[1], isOn: bytes[2] == 0x23, pattern: bytes[3], mode: bytes[4], speed: bytes[5], red: bytes[6], green: bytes[7], blue: bytes[8],
            warm: bytes[9], version: bytes[10], cool: bytes[11], colourMode: bytes[12])
    }

    /// The extended reply (`EA 81`, 20 bytes or more; section 10.4.3), its colour from hue, saturation and value and its
    /// whites from the temperature and brightness in percent.
    init?(extended bytes: [UInt8]) {
        guard bytes.count >= 20, bytes[0] == 0xEA, bytes[1] == 0x81 else { return nil }
        let model = bytes[4]
        let rgb = MagicHomeColour.rgb(hue: Double(bytes[11]) * 2 / 360, saturation: Double(bytes[12]) / 100, value: Double(bytes[13]) / 100)
        func channel(_ value: Double) -> UInt8 { UInt8(clamping: Int(saturating: (255 * value).rounded(.towardZero)) ?? 0) }
        var temperature = Int(bytes[14]), brightness = Int(bytes[15])
        // On 0xB6 a temperature above 100 or a brightness of 0 or above 100 means the whites are off.
        if model == 0xB6, temperature > 100 || brightness == 0 || brightness > 100 { temperature = 0; brightness = 0 }
        let whites = MagicHomeColour.whiteLevels(temperaturePercent: min(temperature, 100), brightnessPercent: min(brightness, 100))
        self.init(
            model: model, isOn: bytes[6] == 0x23, pattern: bytes[7], mode: 0, speed: bytes[9],
            red: channel(rgb.red), green: channel(rgb.green), blue: channel(rgb.blue),
            warm: whites.warm, version: bytes[5], cool: whites.cool, colourMode: bytes[10])
    }
}

/// What a device sends.
enum MagicHomeMessage: Sendable, Equatable {
    case state(MagicHomeState)
    /// A power reply (`xx 71 23|24 cs`, its checksum not checked: some firmware gets it wrong).
    case power(Bool)
    /// Another reply (time, timers, configuration), not read.
    case other([UInt8])

    /// One whole message: a state reply, an extended one, a power reply; nil for what is none of them.
    static func parse(_ message: [UInt8]) -> MagicHomeMessage? {
        if let state = MagicHomeState(standard: message) { return .state(state) }
        if let state = MagicHomeState(extended: message) { return .state(state) }
        if message.count == 4, message[1] == 0x71, message[2] == 0x23 || message[2] == 0x24 { return .power(message[2] == 0x23) }
        return nil
    }
}

/// Splits what arrives on a connection into messages, however TCP cut it (section 10.4.4, "Reassembly"): a wrapped
/// message by its length, a state reply by its 14 bytes, a power reply by its 4. A byte that starts nothing known is
/// dropped, and the buffer is bounded.
struct MagicHomeReader: Sendable {
    static let limit = 2048
    private var buffer: [UInt8] = []

    var pending: Int { buffer.count }

    mutating func add(_ bytes: [UInt8]) -> [MagicHomeMessage] {
        buffer += bytes
        if buffer.count > Self.limit { buffer.removeFirst(buffer.count - Self.limit) }
        var messages: [MagicHomeMessage] = []
        while let step = next() {
            switch step {
            case .wait: return messages
            case .drop(let count): buffer.removeFirst(count)
            case .message(let message, let length):
                buffer.removeFirst(length)
                if let message { messages.append(message) }
            }
        }
        return messages
    }

    private enum Step {
        case wait
        case drop(Int)
        case message(MagicHomeMessage?, length: Int)
    }

    private func next() -> Step? {
        guard let head = buffer.first else { return nil }
        let count = buffer.count
        switch head {
        case 0xB0:
            guard Array(buffer.prefix(6)) == Array(MagicHomeWrapper.header.prefix(min(count, 6))) else { return .drop(1) }
            guard count >= 10 else { return .wait }
            let length = Int(buffer[8]) << 8 | Int(buffer[9])
            guard length <= MagicHomeWrapper.maximumInnerLength else { return .drop(1) }
            let total = 10 + length + 1
            guard count >= total else { return .wait }
            guard let inner = MagicHomeWrapper.unwrap(Array(buffer.prefix(total))) else { return .drop(1) }
            return .message(MagicHomeMessage.parse(inner) ?? .other(inner), length: total)
        case 0x81:
            guard count >= 14 else { return .wait }
            guard let state = MagicHomeState(standard: Array(buffer.prefix(14))) else { return .drop(1) }
            return .message(.state(state), length: 14)
        case 0xEA:
            guard count >= 2 else { return .wait }
            guard buffer[1] == 0x81 else { return .drop(1) }
            // A bare extended reply has no length: the chunk is the message (section 10.4.3).
            guard count >= 20 else { return .wait }
            let length = min(count, 64)
            return .message(MagicHomeState(extended: Array(buffer.prefix(length))).map { .state($0) }, length: length)
        case 0x2B:
            return count >= 14 ? .message(.other(Array(buffer.prefix(14))), length: 14) : .wait
        case 0x72:
            return count >= 13 ? .message(.other(Array(buffer.prefix(13))), length: 13) : .wait
        default:
            guard count >= 2 else { return .wait }
            let length: Int
            switch buffer[1] {
            case 0x71:
                guard count >= 3 else { return .wait }
                guard buffer[2] == 0x23 || buffer[2] == 0x24 else { return .drop(1) }
                length = 4
            case 0x11: length = 12
            case 0x32: length = 7
            case 0x63: length = 11
            default: return .drop(1)
            }
            guard count >= length else { return .wait }
            let message = Array(buffer.prefix(length))
            return .message(MagicHomeMessage.parse(message) ?? .other(message), length: length)
        }
    }
}
