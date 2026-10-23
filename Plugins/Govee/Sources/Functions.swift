import Foundation
import Homeswift
import HomeswiftPlugin

/// The byte and number helpers of the Homebridge plugin's `utils/functions.ts`, with the same results:
/// Govee's frames are 20 bytes (19 of command, padded with zeros, then an XOR checksum) and travel as
/// base64, and the handlers address their bytes by 1-based position in the hex string.
enum Govee {
    // MARK: Hex and base64

    /// The bytes of a hex string; a trailing odd digit and anything that is not hex end it, as Node's
    /// `Buffer.from(hex, 'hex')` does.
    static func bytes(hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let byte = UInt8(String([high, low]), radix: 16) else { break }
            result.append(byte)
        }
        return result
    }

    /// Lenient like Node's `Buffer.from(value, 'base64')`: missing padding is fine, junk yields nothing.
    static func bytes(base64: String) -> [UInt8] {
        var text = base64.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let index = text.firstIndex(of: "=") { text = String(text[..<index]) }
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text).map(Array.init) ?? []
    }

    static func base64ToHex(_ base64: String) -> String { Secrets.hex(bytes(base64: base64)) }

    static func hexToBase64(_ hex: String) -> String { Data(bytes(hex: hex)).base64EncodedString() }

    /// `"aabbcc"` → `["aa", "bb", "cc"]`; an odd tail stays as one character.
    static func hexToTwoItems(_ hex: String) -> [String] {
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            parts.append(String(hex[index..<end]))
            index = end
        }
        return parts
    }

    /// The 1-based item, or "" past the end (JavaScript's `undefined` in a template string never matched).
    static func item(_ parts: [String], _ position: Int) -> String {
        parts.indices.contains(position - 1) ? parts[position - 1] : ""
    }

    /// `parseInt(hex, 16)`, with JavaScript's leniency: an optional `0x`, then as many hex digits as there are.
    static func hexToDecimal(_ hex: String) -> Int {
        var digits = Substring(hex)
        if digits.lowercased().hasPrefix("0x") { digits = digits.dropFirst(2) }
        let valid = digits.prefix { $0.isHexDigit }
        return Int(valid, radix: 16) ?? 0
    }

    /// `parseInt(text, 10)`: the leading decimal digits, nil when there are none.
    static func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = ""
        for (offset, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if offset == 0, character == "-" || character == "+" {
                digits.append(character)
            } else {
                break
            }
        }
        return Int(digits)
    }

    // MARK: Frames

    /// A 20-byte frame: the values flattened, zero padded to 19 bytes, then their XOR. Base64.
    static func code(_ values: [Int]) -> String {
        Data(codeBytes(values)).base64EncodedString()
    }

    static func codeBytes(_ values: [Int]) -> [UInt8] {
        var bytes = values.map { UInt8(truncatingIfNeeded: $0) }
        if bytes.count < 19 { bytes += [UInt8](repeating: 0, count: 19 - bytes.count) }
        let checksum = bytes.reduce(0, ^)
        return bytes + [checksum]
    }

    /// Turns a status frame (`aa…`) into the command frame that sets the same state (`33…`), hex.
    static func statusToActionCode(_ statusCode: String) -> String {
        let chopped = "33" + String(statusCode.dropFirst(2).dropLast(2))
        let values = hexToTwoItems(chopped).map { hexToDecimal($0) }
        return Secrets.hex(codeBytes(values))
    }

    // MARK: Numbers

    /// JavaScript's `Math.round`: halves go up, towards +∞.
    static func round(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// `Math.round` to an integer; a device or cloud number out of range saturates rather than trapping, NaN gives 0.
    static func roundInt(_ value: Double) -> Int { Int(saturating: round(value)) ?? 0 }

    static func cenToFar(_ temperature: Double) -> Double { round(((temperature * 9) / 5 + 32) * 10) / 10 }

    static func farToCen(_ temperature: Double) -> Double { round(((temperature - 32) * 5) / 9) }

    static func nearestHalf(_ value: Double) -> Double { round(value * 2) / 2 }

    /// A rotation speed percentage to a device speed, 1 to `maxSpeed`.
    static func speedPercentToValue(_ speed: Double, maxSpeed: Int, rounding: (Double) -> Double = { $0.rounded(.down) }) -> Int {
        let increment = 100 / Double(maxSpeed)
        return min(max(Int(saturating: rounding(speed / increment)) ?? 1, 1), maxSpeed)
    }

    static func speedValueToPercent(_ value: Int, maxSpeed: Int) -> Int {
        roundInt(Double(value) * (100 / Double(maxSpeed)))
    }

    // MARK: Ids and strings

    /// Upper case, only hex digits, colons and underscores: how config.json's device ids are compared.
    static func parseDeviceId(_ deviceId: String) -> String {
        String(deviceId.uppercased().filter { $0 == ":" || $0 == "_" || ("0"..."9").contains($0) || ("A"..."F").contains($0) })
    }

    /// The colon form Govee's device list uses elsewhere: `ab12cd34` → `AB:12:CD:34`.
    static func colonDeviceId(_ deviceId: String) -> String {
        guard !deviceId.contains(":") else { return deviceId }
        return hexToTwoItems(deviceId).joined(separator: ":").uppercased()
    }

    static func randomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    // MARK: Status frames

    typealias CommandHandler = (_ parts: [String], _ hex: String) -> Void

    /// Dispatches status frames (`aa`, opcode, usually a sub-code) to handlers keyed by opcode and
    /// sub-code (`"0501"`), falling back to the opcode alone (`"05"`); other frames are skipped.
    static func processCommands(_ commands: [String], _ handlers: [String: CommandHandler], unknown: ((_ command: String, _ hex: String, _ function: String) -> Void)? = nil) {
        for command in commands {
            let hexString = base64ToHex(command)
            let parts = hexToTwoItems(hexString)
            guard item(parts, 1) == "aa" else { continue }
            let opcode = item(parts, 2)
            let function = opcode + item(parts, 3)
            if let handler = handlers[function] ?? handlers[opcode] {
                handler(parts, hexString)
            } else {
                unknown?(command, hexString, function)
            }
        }
    }

    /// The night light frame of the humidifiers: on, brightness and colour.
    static func nightLightCode(brightness: Int, hue: Double, saturation: Double) -> String {
        let rgb = Colour.hs2rgb(hue, saturation)
        return code([0x33, 0x1B, 0x01, brightness, rgb.r, rgb.g, rgb.b])
    }

    static func nightLightOffCode() -> String { code([0x33, 0x1B, 0x00]) }
}
