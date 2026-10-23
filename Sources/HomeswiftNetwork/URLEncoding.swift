import Foundation

/// Percent-encoding as the JavaScript libraries the plugins port write it, byte for byte: cloud APIs sign these
/// strings, so the encoding must match. Every byte outside the kept set is `%XX`, uppercase, of the UTF-8.
public enum URLEncoding {
    /// RFC 3986 (`qs.stringify`, AWS Signature V4): keeps `A-Z a-z 0-9 - . _ ~`, spaces as `%20`.
    public static func rfc3986(_ string: String) -> String {
        encode(string, keeping: "-._~")
    }

    /// `encodeURIComponent`: keeps `A-Z a-z 0-9 - _ . ! ~ * ' ( )`.
    public static func uriComponent(_ string: String) -> String {
        encode(string, keeping: "-_.!~*'()")
    }

    /// `application/x-www-form-urlencoded` as `URLSearchParams` writes it: keeps `A-Z a-z 0-9 * - . _`, spaces as `+`.
    public static func form(_ string: String) -> String {
        encode(string, keeping: "*-._", spaceAsPlus: true)
    }

    /// Form fields in the given order, `name=value&…`, each side encoded with `form(_:)`.
    public static func form(_ fields: [(String, String)]) -> String {
        fields.map { "\(form($0.0))=\(form($0.1))" }.joined(separator: "&")
    }

    /// A query in the given order, `name=value&…`, each side encoded with `rfc3986(_:)` (`qs.stringify`).
    public static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(rfc3986($0.0))=\(rfc3986($0.1))" }.joined(separator: "&")
    }

    /// Decodes a form or query value: `+` as a space, then the percent escapes; the string as it is when an escape is
    /// not valid UTF-8.
    public static func decode(_ string: String) -> String {
        string.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? string
    }

    private static func encode(_ string: String, keeping kept: String, spaceAsPlus: Bool = false) -> String {
        let kept = Set(kept.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                result.append(byte)
            case _ where kept.contains(byte):
                result.append(byte)
            case UInt8(ascii: " ") where spaceAsPlus:
                result.append(UInt8(ascii: "+"))
            default:
                result.append(UInt8(ascii: "%"))
                result.append(upperHexDigits[Int(byte >> 4)])
                result.append(upperHexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static let upperHexDigits = Array("0123456789ABCDEF".utf8)
}

/// Lowercase hexadecimal, two digits a byte: digests and fingerprints (`Secrets.hex` in Homeswift).
func hexString(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    result.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        result.append(digits[Int(byte >> 4)])
        result.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: result, as: UTF8.self)
}
