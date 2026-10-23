import Foundation

/// TLV8 as HAP-NodeJS's `util/tlv` writes and reads it, for the values of `tlv8` characteristics (camera
/// configurations, transition control). Pairing uses the internal `TLV8`, which keeps the order of items.
///
/// Values longer than 255 bytes are split into consecutive items of the same type. A list puts an empty
/// item of type 0 between its entries.
public enum HAPTLV {
    /// The value of one item: bytes, a single byte, or a list of entries of the same type.
    public enum Value: Sendable, Equatable {
        case data(Data)
        case byte(UInt8)
        case list([Data])
    }

    public enum DecodingError: Error, Equatable {
        case truncated
        case duplicate(UInt8)
        /// A required item is absent (`required(_:_:_:)`): its name.
        case missing(String)
        case badLength(Int)
    }

    /// Encodes the items in order, like `tlv.encode(type, data, type, data, ...)`.
    public static func encode(_ items: [(UInt8, Value)]) -> Data {
        var out = Data()
        for (type, value) in items {
            switch value {
            case .byte(let byte):
                out.append(contentsOf: [type, 1, byte])
            case .data(let data):
                appendFragments(type, data, to: &out)
            case .list(let entries):
                if entries.isEmpty {
                    out.append(contentsOf: [type, 0])
                }
                for (index, entry) in entries.enumerated() {
                    if index > 0 { out.append(contentsOf: [0, 0]) }
                    appendFragments(type, entry, to: &out)
                }
            }
        }
        return out
    }

    public static func encode(_ items: (UInt8, Value)...) -> Data { encode(items) }

    /// One item, split into fragments of 255 bytes; an empty value is one empty item. Pairing's `TLV8` writes the same.
    static func appendFragments(_ type: UInt8, _ data: Data, to out: inout Data) {
        if data.isEmpty {
            out.append(contentsOf: [type, 0])
            return
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: 255, limitedBy: data.endIndex) ?? data.endIndex
            out.append(type)
            out.append(UInt8(data.distance(from: offset, to: end)))
            out.append(data[offset..<end])
            offset = end
        }
    }

    /// Calls `body` with every item in order, fragments as they are (not joined). Throws `DecodingError.truncated`
    /// when the data ends inside an item.
    static func forEachItem(_ data: Data, _ body: (_ type: UInt8, _ value: Data) throws -> Void) throws {
        var index = data.startIndex
        while index < data.endIndex {
            guard data.endIndex - index >= 2 else { throw DecodingError.truncated }
            let type = data[index]
            let length = Int(data[index + 1])
            index += 2
            guard data.endIndex - index >= length else { throw DecodingError.truncated }
            try body(type, data[index..<index + length])
            index += length
        }
    }

    /// `tlv.decode`: every item by type; repeated types are concatenated.
    public static func decode(_ data: Data) throws -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        try forEachItem(data) { type, value in result[type, default: Data()].append(value) }
        return result
    }

    /// `tlv.decodeWithLists`: list entries (separated by an empty type-0 item) as several values, fragments
    /// of more than 255 bytes joined. A type that appears once has one value.
    public static func decodeWithLists(_ data: Data) throws -> [UInt8: [Data]] {
        var result: [UInt8: [Data]] = [:]
        var lastType = -1
        var lastLength = -1
        var lastWasDelimiter = false
        try forEachItem(data) { type, slice in
            let value = Data(slice)
            if type == 0, value.isEmpty {
                lastWasDelimiter = true
                return
            }
            if var existing = result[type] {
                if lastWasDelimiter, lastType == Int(type) {
                    existing.append(value)
                } else if lastType == Int(type), lastLength == 255 {
                    existing[existing.count - 1].append(value)
                } else {
                    throw DecodingError.duplicate(type)
                }
                result[type] = existing
            } else {
                result[type] = [value]
            }
            lastType = Int(type)
            lastLength = value.count
            lastWasDelimiter = false
        }
        return result
    }

    /// The value of a required item of a decoded TLV; `DecodingError.missing(name)` when it is absent, or empty
    /// with `nonEmpty`.
    public static func required(_ tlv: [UInt8: Data], _ type: UInt8, _ name: String, nonEmpty: Bool = false) throws -> Data {
        guard let value = tlv[type], !nonEmpty || !value.isEmpty else { throw DecodingError.missing(name) }
        return value
    }

    /// The first byte of a required item; `DecodingError.missing(name)` when it is absent or empty.
    public static func requiredByte(_ tlv: [UInt8: Data], _ type: UInt8, _ name: String) throws -> UInt8 {
        let value = try required(tlv, type, name, nonEmpty: true)
        return value[value.startIndex]
    }

    // MARK: Numbers

    /// `tlv.writeVariableUIntLE`: one, two, four or eight little-endian bytes, the fewest that hold it.
    public static func variableUInt(_ value: UInt64) -> Data {
        if value <= 0xFF { return Data([UInt8(value)]) }
        if value <= 0xFFFF { return uint16(UInt16(value)) }
        if value <= 0xFFFF_FFFF { return uint32(UInt32(value)) }
        return uint64(value)
    }

    public static func variableUInt(_ value: Int) -> Data { variableUInt(UInt64(max(0, value))) }

    /// `tlv.readVariableUIntLE`: a 1, 2, 4 or 8-byte little-endian integer.
    public static func readVariableUInt(_ data: Data) throws -> UInt64 {
        switch data.count {
        case 1, 2, 4, 8: return readUInt(data)
        default: throw DecodingError.badLength(data.count)
        }
    }

    public static func uint16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    public static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    public static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    public static func float32(_ value: Float) -> Data { uint32(value.bitPattern) }

    /// Reads up to eight bytes as a little-endian unsigned integer.
    public static func readUInt(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for (shift, byte) in data.prefix(8).enumerated() { value |= UInt64(byte) << (8 * UInt64(shift)) }
        return value
    }

    public static func readFloat32(_ data: Data) throws -> Float {
        guard data.count >= 4 else { throw DecodingError.badLength(data.count) }
        return Float(bitPattern: UInt32(readUInt(data.prefix(4))))
    }

    // MARK: Identifiers

    /// `uuid.write`: a UUID string as its 16 bytes.
    public static func uuidBytes(_ uuid: String) -> Data {
        hexBytes(uuid.replacingOccurrences(of: "-", with: ""))
    }

    /// `uuid.unparse`: 16 bytes as a lowercase UUID string.
    public static func uuidString(_ data: Data) -> String {
        let hex = hexString(data)
        guard hex.count == 32 else { return hex }
        let parts = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        return parts.map { length in
            let end = hex.index(index, offsetBy: length)
            defer { index = end }
            return String(hex[index..<end])
        }.joined(separator: "-")
    }

    public static func hexString(_ data: Data) -> String {
        Secrets.hex(data)
    }

    public static func hexBytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            if let byte = UInt8(hex[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }
}
