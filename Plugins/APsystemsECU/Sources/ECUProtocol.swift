import Foundation

// The ECU's local protocol on TCP port 8899 (docs/clean-room/APsystemsECU.md, section 3): ASCII framing around fields,
// `APS`, a two-character command group, a four-digit length (the frame's bytes without the final line feed), a
// four-character command, the payload, `END` and a line feed. No checksum other than the length. Everything here is
// pure: the bytes in, the values out, bounded by the frame's own length, so a frame from the network never traps.

/// The commands the plugin asks.
enum ECUCommand: String, Sendable, CaseIterable {
    case system = "0001"
    case realTime = "0002"
    case signal = "0030"
}

/// Why an answer is not one the plugin can use.
enum ECUFrameError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Fewer bytes than the smallest frame (`APS` + group + length + command + `END` + LF).
    case short(received: Int)
    case badSignature
    /// The length the header announces is not the number of bytes received (minus the line feed).
    case lengthMismatch(announced: Int?, received: Int)
    case badEnd
    case wrongCommand(expected: String, received: String)
    /// A status other than `00`.
    case status(String)
    case malformed(String)
    case tooLarge(limit: Int)

    var description: String {
        switch self {
        case .short(let received): "a short frame (\(received) bytes)"
        case .badSignature: "a bad start signature"
        case .lengthMismatch(let announced, let received):
            "a length mismatch (the header says \(announced.map(String.init) ?? "nothing readable"), \(received) bytes came)"
        case .badEnd: "a bad end signature"
        case .wrongCommand(let expected, let received): "the answer to command \(received) instead of \(expected)"
        case .status(let status): "status \(status)"
        case .malformed(let what): "a malformed answer (\(what))"
        case .tooLarge(let limit): "an answer larger than \(limit) bytes"
        }
    }
}

enum ECUProtocol {
    static let port = 8899
    /// `APS` + group + length + command + `END` + LF.
    static let minimumFrame = 17
    /// The most the reader takes before giving up: far more than 30 + 27 bytes for every inverter an ECU takes.
    static let maximumFrame = 64 * 1024

    // MARK: Requests (3.3)

    static let systemRequest = Array("APS1100160001END\n".utf8)

    static func realTimeRequest(ecuID: String) -> [UInt8] { Array("APS1100280002\(ecuID)END\n".utf8) }

    static func signalRequest(ecuID: String) -> [UInt8] { Array("APS1100280030\(ecuID)END\n".utf8) }

    static func request(_ command: ECUCommand, ecuID: String) -> [UInt8] {
        switch command {
        case .system: systemRequest
        case .realTime: realTimeRequest(ecuID: ecuID)
        case .signal: signalRequest(ecuID: ecuID)
        }
    }

    // MARK: Frames (3.2)

    /// The total number of bytes a frame starting with `bytes` has (its length field + 1), once its header is in; nil
    /// while fewer than 9 bytes are, or when the header does not read as `APS` and four digits.
    static func announcedTotal(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 9, bytes[0] == 0x41, bytes[1] == 0x50, bytes[2] == 0x53, let length = decimal(bytes, 5, 4) else { return nil }
        return length + 1
    }

    /// The frame checked as the sources check it, then its command against the one asked.
    static func validate(_ bytes: [UInt8], expecting command: ECUCommand) throws -> [UInt8] {
        guard bytes.count >= minimumFrame else { throw ECUFrameError.short(received: bytes.count) }
        guard bytes[0] == 0x41, bytes[1] == 0x50, bytes[2] == 0x53 else { throw ECUFrameError.badSignature }
        let announced = decimal(bytes, 5, 4)
        guard announced == bytes.count - 1 else { throw ECUFrameError.lengthMismatch(announced: announced, received: bytes.count) }
        let end = bytes.count - 4
        guard bytes[end] == 0x45, bytes[end + 1] == 0x4E, bytes[end + 2] == 0x44, bytes[end + 3] == 0x0A else { throw ECUFrameError.badEnd }
        let received = ascii(bytes, 9, 4) ?? "?"
        guard received == command.rawValue else { throw ECUFrameError.wrongCommand(expected: command.rawValue, received: received) }
        return bytes
    }

    /// The frame's command group (`11`, or `12` from an ECU-C's system answer).
    static func group(_ frame: [UInt8]) -> String? { ascii(frame, 3, 2) }

    // MARK: System info (3.4)

    struct SystemInfo: Sendable, Equatable {
        var ecuID: String
        var model: String
        /// kWh since the ECU was set up.
        var lifetimeEnergy: Double
        /// W, AC, the whole system.
        var currentPower: Int
        /// kWh today, reset by the ECU at midnight.
        var todayEnergy: Double
        var inverters: Int
        var invertersOnline: Int
        var firmware: String
        var timeZone: String?
    }

    static func parseSystem(_ frame: [UInt8]) throws -> SystemInfo {
        let end = frame.count - 4
        guard end >= 39 else { throw ECUFrameError.malformed("system answer of \(frame.count) bytes") }
        guard let ecuID = ascii(frame, 13, 12), ecuID.allSatisfy(\.isASCIIDigitCharacter) else { throw ECUFrameError.malformed("ECU id") }
        let model = ascii(frame, 25, 2) ?? "?"
        let lifetime = Double(uint(frame, 27, 4)) / 10
        let power = uint(frame, 31, 4)
        let today = Double(uint(frame, 35, 4)) / 100
        let layout2 = model == "02"
        let (countAt, onlineAt, firmwareLengthAt) = layout2 ? (39, 41, 49) : (46, 48, 52)
        guard firmwareLengthAt + 3 <= end, let firmwareLength = decimal(frame, firmwareLengthAt, 3), firmwareLengthAt + 3 + firmwareLength <= end else {
            throw ECUFrameError.malformed("firmware length")
        }
        let firmware = ascii(frame, firmwareLengthAt + 3, firmwareLength) ?? ""
        var timeZone: String?
        let zoneLengthAt = firmwareLengthAt + 3 + firmwareLength
        if !layout2, zoneLengthAt + 3 <= end, let zoneLength = decimal(frame, zoneLengthAt, 3), zoneLengthAt + 3 + zoneLength <= end {
            timeZone = ascii(frame, zoneLengthAt + 3, zoneLength)
        }
        return SystemInfo(
            ecuID: ecuID, model: model, lifetimeEnergy: lifetime, currentPower: power, todayEnergy: today,
            inverters: uint(frame, countAt, 2), invertersOnline: uint(frame, onlineAt, 2), firmware: firmware, timeZone: timeZone)
    }

    /// Where an ECU-C's or an ECU-R's system answer carries its Ethernet and wireless MAC addresses (layout `01`), to
    /// mask them in the log.
    static func systemMACRange(_ frame: [UInt8]) -> Range<Int>? {
        guard let firmwareLength = decimal(frame, 52, 3) else { return nil }
        let zoneAt = 55 + firmwareLength
        guard let zoneLength = decimal(frame, zoneAt, 3) else { return nil }
        let start = zoneAt + 3 + zoneLength
        return start + 12 <= frame.count - 4 ? start..<(start + 12) : nil
    }

    // MARK: Real-time data (3.5)

    struct Inverter: Sendable, Equatable {
        var uid: String
        var online: Bool
        var type: String
        /// Hz; nil for a registered-only record.
        var frequency: Double?
        /// °C as the ECU reports it (−100 for an offline record of zeros); nil for a registered-only record.
        var temperature: Int?
        /// W per channel (DC input).
        var powers: [Int]
        /// V, grid side: one, two or three.
        var voltages: [Int]

        var isRegisteredOnly: Bool { type == "00" }
        /// The inverter's output: its channels added up (3.6).
        var power: Int { powers.reduce(0, +) }
    }

    struct RealTime: Sendable, Equatable {
        var model: String
        /// `YYYYMMDDhhmmss`, the ECU's local time of the data.
        var time: String
        var inverters: [Inverter]
        /// A type code the plugin cannot read: the records from it on were left out.
        var unknownType: String?
        /// The records stopped before the count the header gave (a record that runs past `END`).
        var truncated: Bool

        /// `YYYYMMDD` of the data.
        var date: String { String(time.prefix(8)) }
    }

    /// The length of a record of each type code, and its channels: (powers, voltages) as offsets after +9.
    private static let layouts: [String: (length: Int, powers: [Int], voltages: [Int])] = [
        "00": (9, [], []),
        "01": (21, [13, 17], [15, 19]),
        "04": (21, [13, 17], [15, 19]),
        "02": (27, [13, 17, 21, 25], [15, 19, 23]),
        "05": (27, [13, 17, 21, 25], [15, 19, 23]),
        "03": (23, [13, 17, 19, 21], [15]),
    ]

    static func parseRealTime(_ frame: [UInt8]) throws -> RealTime {
        let end = frame.count - 4
        guard end >= 26 else { throw ECUFrameError.malformed("real-time answer of \(frame.count) bytes") }
        let status = ascii(frame, 13, 2) ?? "?"
        guard status == "00" else { throw ECUFrameError.status(status) }
        let model = ascii(frame, 15, 2) ?? "?"
        let count = uint(frame, 17, 2)
        let time = bcd(frame, 19, 7)
        var inverters: [Inverter] = []
        var offset = 26
        var unknownType: String?
        var truncated = false
        for _ in 0..<count {
            guard offset + 9 <= end else { truncated = true; break }
            let type = ascii(frame, offset + 7, 2) ?? "??"
            guard let layout = layouts[type] else { unknownType = type; break }
            guard offset + layout.length <= end else { truncated = true; break }
            let uid = bcd(frame, offset, 6)
            let online = frame[offset + 6] != 0
            var inverter = Inverter(uid: uid, online: online, type: type, frequency: nil, temperature: nil, powers: [], voltages: [])
            if layout.length > 9 {
                inverter.frequency = Double(uint(frame, offset + 9, 2)) / 10
                inverter.temperature = uint(frame, offset + 11, 2) - 100
                inverter.powers = layout.powers.map { uint(frame, offset + $0, 2) }
                inverter.voltages = layout.voltages.map { uint(frame, offset + $0, 2) }
            }
            inverters.append(inverter)
            offset += layout.length
        }
        return RealTime(model: model, time: time, inverters: inverters, unknownType: unknownType, truncated: truncated)
    }

    // MARK: Signal levels (3.7)

    /// Each inverter's raw level (0...255), by UID: as many 7-byte records as fit between offset 15 and `END`.
    static func parseSignal(_ frame: [UInt8]) throws -> [String: Int] {
        let end = frame.count - 4
        guard end >= 15 else { throw ECUFrameError.malformed("signal answer of \(frame.count) bytes") }
        let status = ascii(frame, 13, 2) ?? "?"
        guard status == "00" else { throw ECUFrameError.status(status) }
        var levels: [String: Int] = [:]
        var offset = 15
        while offset + 7 <= end {
            levels[bcd(frame, offset, 6)] = Int(frame[offset + 6])
            offset += 7
        }
        return levels
    }

    /// A raw level as a percentage, truncated toward zero.
    static func signalPercent(_ level: Int) -> Int { max(0, min(255, level)) * 100 / 255 }

    // MARK: Names (1.1, 1.2)

    static func ecuModel(_ ecuID: String) -> String {
        if ecuID.hasPrefix("2160") { return "ECU-R" }
        if ecuID.hasPrefix("2162") { return "ECU-R-Pro" }
        if ecuID.hasPrefix("2163") { return "ECU-B" }
        if ecuID.hasPrefix("215") { return "ECU-C" }
        if ecuID.hasPrefix("2030") { return "ECU-3" }
        return "ECU"
    }

    /// Whether the ECU has the CT clamps read over HTTP (an ECU-C).
    static func hasMeter(_ ecuID: String) -> Bool { ecuID.hasPrefix("215") }

    static func inverterModel(_ uid: String) -> String {
        switch uid.prefix(2) {
        case "10": "YC500 series"
        case "40": "YC600 series"
        case "50": "YC1000 series"
        case "70": "DS3 series"
        case "80": "QS1 series"
        case "90": "QT2 series"
        default: "Inverter"
        }
    }

    /// The first dotted number in a firmware string (`ECU-C-Z_C1.2.24D` → `1.2.24`), as HAP's Firmware Revision wants.
    static func firmwareRevision(_ firmware: String) -> String {
        guard let match = firmware.firstMatch(of: /[0-9]+(\.[0-9]+){1,2}/) else { return "1.0.0" }
        return String(match.output.0)
    }

    // MARK: Logging (6)

    /// The frame in hex for the debug log, the ECU id's last six digits and `masked` (MAC addresses) hidden.
    static func maskedHex(_ frame: [UInt8], ecuID: String?, masked: Range<Int>? = nil) -> String {
        var bytes = frame
        if let ecuID, ecuID.count == 12 {
            let id = Array(ecuID.utf8)
            var index = 0
            while index + 12 <= bytes.count {
                if Array(bytes[index..<(index + 12)]) == id {
                    for position in (index + 6)..<(index + 12) { bytes[position] = 0x78 }
                    index += 12
                } else {
                    index += 1
                }
            }
        }
        if let masked, masked.lowerBound >= 0, masked.upperBound <= bytes.count {
            for position in masked { bytes[position] = 0 }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// An ECU id or UID for the log outside debug: its last six digits hidden.
    static func masked(_ id: String) -> String { id.count > 6 ? String(id.prefix(id.count - 6)) + "xxxxxx" : id }

    // MARK: Fields

    /// `length` bytes from `offset` as ASCII, nil when they run past the end or are not ASCII.
    static func ascii(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { return nil }
        let slice = bytes[offset..<(offset + length)]
        guard slice.allSatisfy({ $0 < 0x80 }) else { return nil }
        return String(decoding: slice, as: UTF8.self)
    }

    /// ASCII decimal digits, nil for anything else.
    static func decimal(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        guard let text = ascii(bytes, offset, length), !text.isEmpty, text.allSatisfy(\.isASCIIDigitCharacter) else { return nil }
        return Int(text)
    }

    /// An unsigned big-endian integer of 1 to 4 bytes (0 past the end: callers check the bounds first).
    static func uint(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int {
        guard offset >= 0, offset + length <= bytes.count else { return 0 }
        return bytes[offset..<(offset + length)].reduce(0) { $0 << 8 | Int($1) }
    }

    /// Packed decimal, read as its hex digits.
    static func bcd(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= bytes.count else { return "" }
        return bytes[offset..<(offset + length)].map { String(format: "%02x", $0) }.joined()
    }
}

/// Collects what the ECU sends until the frame is whole: the number of bytes its header announces, or, when the header
/// cannot be read, a trailing `END` and line feed (never the first `END` seen: binary fields can hold those bytes).
struct ECUFrameReader: Sendable {
    private(set) var bytes: [UInt8] = []
    let limit: Int

    init(limit: Int = ECUProtocol.maximumFrame) { self.limit = limit }

    /// Adds a chunk; the frame once it is complete (any bytes past it dropped), nil while more should come.
    mutating func append(_ chunk: [UInt8]) throws -> [UInt8]? {
        bytes.append(contentsOf: chunk)
        if let total = ECUProtocol.announcedTotal(bytes) {
            guard total <= limit else { throw ECUFrameError.tooLarge(limit: limit) }
            if bytes.count >= total { return Array(bytes.prefix(total)) }
            return nil
        }
        guard bytes.count <= limit else { throw ECUFrameError.tooLarge(limit: limit) }
        if bytes.count >= 9, bytes.suffix(4) == [0x45, 0x4E, 0x44, 0x0A] { return bytes }
        return nil
    }
}

extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
