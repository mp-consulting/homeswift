import Foundation
import Homeswift
import HomeswiftPlugin

/// Thermo-hygrometer readings from BLE advertisements (`utils/decode.ts` and `utils/validation.ts`): the
/// manufacturer data as hex, company id included, recognised by its UUID bytes and length.
enum SensorDecoding {
    struct Reading: Sendable, Equatable {
        var battery: Int
        var humidity: Double
        var tempInC: Double
        var tempInF: Double
    }

    enum DecodingError: Error, CustomStringConvertible, Equatable {
        case tooShort(model: String, length: Int, needed: Int)
        case unsupported(String)

        var description: String {
            switch self {
            case .tooShort(let model, let length, let needed): "\(model) stream too short: \(length) chars (need \(needed))"
            case .unsupported(let stream): "Unsupported stream update: \(stream)"
            }
        }
    }

    static func isH5074(_ hex: String) -> Bool { hex.contains("88ec") && hex.count == 18 }
    static func isH5075(_ hex: String) -> Bool { hex.contains("88ec") && hex.count == 16 }
    static func isH5101(_ hex: String) -> Bool { hex.contains("0100") }
    static func isH5179(_ hex: String) -> Bool { hex.contains("0188") && hex.count == 22 }

    /// Whether manufacturer data is a sensor reading this plugin decodes.
    static func isValid(manufacturerData: [UInt8]?) -> Bool {
        manufacturerData.map { isValid(hex: Secrets.hex($0)) } ?? false
    }

    static func isValid(hex: String) -> Bool { isH5074(hex) || isH5075(hex) || isH5101(hex) || isH5179(hex) }

    static func decode(_ hex: String) throws -> Reading {
        if isH5074(hex) { return try decodeH5074(hex) }
        if isH5075(hex) { return try decodeH5075(hex) }
        if isH5101(hex) { return try decodeH5101(hex) }
        if isH5179(hex) { return try decodeH5179(hex) }
        throw DecodingError.unsupported(hex)
    }

    static func decodeH5074(_ stream: String) throws -> Reading {
        guard stream.count >= 16 else { throw DecodingError.tooShort(model: "H5074", length: stream.count, needed: 16) }
        let temperature = Double(twosComplement(hexValue(sub(stream, 8, 10) + sub(stream, 6, 8)))) / 100
        let humidity = Double(hexValue(sub(stream, 12, 14) + sub(stream, 10, 12))) / 100
        return Reading(battery: hexValue(sub(stream, 14, 16)), humidity: humidity, tempInC: temperature, tempInF: temperature * 9 / 5 + 32)
    }

    static func decodeH5075(_ stream: String) throws -> Reading {
        guard stream.count >= 14 else { throw DecodingError.tooShort(model: "H5075", length: stream.count, needed: 14) }
        return packed(hexValue(sub(stream, 6, 12)), battery: hexValue(sub(stream, 12, 14)))
    }

    static func decodeH5101(_ stream: String) throws -> Reading {
        guard stream.count >= 16 else { throw DecodingError.tooShort(model: "H5101", length: stream.count, needed: 16) }
        return packed(hexValue(sub(stream, 8, 14)), battery: hexValue(sub(stream, 14, 16)))
    }

    static func decodeH5179(_ stream: String) throws -> Reading {
        guard stream.count >= 22 else { throw DecodingError.tooShort(model: "H5179", length: stream.count, needed: 22) }
        let temperature = Double(twosComplement(hexValue(sub(stream, 14, 16) + sub(stream, 16, 18)))) / 100
        let humidity = Double(hexValue(sub(stream, 18, 20) + sub(stream, 16, 18))) / 100
        return Reading(battery: hexValue(sub(stream, 20, 22)), humidity: humidity, tempInC: temperature, tempInF: temperature * 9 / 5 + 32)
    }

    /// Temperature and humidity packed in one 24-bit number, the sign in its top bit.
    private static func packed(_ encoded: Int, battery: Int) -> Reading {
        var data = encoded
        let negative = data & 0x80_0000 != 0
        if negative { data ^= 0x80_0000 }
        var temperature = Double(data) / 10_000
        if negative { temperature = 0 - temperature }
        let humidity = Double(data % 1000) / 10
        return Reading(battery: battery, humidity: humidity, tempInC: temperature, tempInF: temperature * 9 / 5 + 32)
    }

    private static func twosComplement(_ value: Int, width: Int = 16) -> Int {
        value & (1 << (width - 1)) != 0 ? value - (1 << width) : value
    }

    private static func hexValue(_ hex: String) -> Int { Int(hex, radix: 16) ?? 0 }

    private static func sub(_ string: String, _ start: Int, _ end: Int) -> String {
        let characters = Array(string)
        guard start < characters.count else { return "" }
        return String(characters[start..<min(end, characters.count)])
    }
}
