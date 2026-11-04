import Foundation

/// The protobuf wire format (https://protobuf.dev/programming-guides/encoding/) without a schema or a code generator:
/// varints, tags, and the four wire types devices use. `ProtobufWriter` builds a message field by field and
/// `ProtobufMessage` reads one by field number, so a plugin describes its messages by their numbers (ESPHome's native
/// API, EcoFlow's property messages).
public enum Protobuf {
    public enum WireType: UInt8, Sendable {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// Unsigned LEB128: seven bits per byte, the least significant group first, the high bit set on all but the last.
    public static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// A field's key: its number and wire type.
    public static func tag(_ number: Int, _ wireType: WireType) -> [UInt8] {
        varint(UInt64(number) << 3 | UInt64(wireType.rawValue))
    }

    /// Reads a varint at `index` and moves past it; nil when the bytes end first or it runs past ten bytes.
    public static func readVarint(_ buffer: UnsafeRawBufferPointer, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < buffer.count, shift < 70 {
            let byte = buffer[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Reads `count` little-endian bytes (4 or 8) at `index` and moves past them; nil when the bytes end first.
    public static func readFixed(_ buffer: UnsafeRawBufferPointer, _ index: inout Int, count: Int) -> UInt64? {
        guard buffer.count - index >= count else { return nil }
        var result: UInt64 = 0
        for offset in 0..<count {
            result |= UInt64(buffer[index + offset]) << (8 * UInt64(offset))
        }
        index += count
        return result
    }
}

/// A message being written. The typed writers leave out a value equal to its default (0, false, an empty string), as
/// proto3 does; `varint(_:_:)` and `bytes(_:_:)` always write.
public struct ProtobufWriter: Sendable, Equatable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func varint(_ number: Int, _ value: UInt64) {
        bytes += Protobuf.tag(number, .varint) + Protobuf.varint(value)
    }

    public mutating func bytes(_ number: Int, _ value: [UInt8]) {
        bytes += Protobuf.tag(number, .lengthDelimited) + Protobuf.varint(UInt64(value.count)) + value
    }

    public mutating func bool(_ number: Int, _ value: Bool) {
        if value { varint(number, 1) }
    }

    public mutating func uint32(_ number: Int, _ value: UInt32) {
        if value != 0 { varint(number, UInt64(value)) }
    }

    /// A negative value takes ten bytes, sign-extended, as protobuf's `int32` does.
    public mutating func int32(_ number: Int, _ value: Int32) {
        if value != 0 { varint(number, UInt64(bitPattern: Int64(value))) }
    }

    public mutating func enumeration(_ number: Int, _ value: Int) {
        int32(number, Int32(truncatingIfNeeded: value))
    }

    public mutating func fixed32(_ number: Int, _ value: UInt32) {
        guard value != 0 else { return }
        bytes += Protobuf.tag(number, .fixed32) + withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    public mutating func float(_ number: Int, _ value: Float) {
        guard value != 0 else { return }
        bytes += Protobuf.tag(number, .fixed32) + withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
    }

    public mutating func string(_ number: Int, _ value: String) {
        if !value.isEmpty { bytes(number, Array(value.utf8)) }
    }

    public mutating func message(_ number: Int, _ message: ProtobufWriter) {
        bytes(number, message.bytes)
    }
}

/// A message read by field number. Absent fields read as their defaults; for a field that comes more than once, the
/// last one wins (`strings`, `enumerations` and `messages` read every one).
public struct ProtobufMessage: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    public let fields: [(number: Int, value: Value)]

    /// nil when the bytes are not a well-formed message (a truncated field, a group, an unknown wire type).
    public init?(_ bytes: [UInt8]) {
        var fields: [(number: Int, value: Value)] = []
        let wellFormed = bytes.withUnsafeBytes { buffer -> Bool in
            var index = 0
            while index < buffer.count {
                guard let key = Protobuf.readVarint(buffer, &index) else { return false }
                let number = Int(truncatingIfNeeded: key >> 3)
                switch key & 7 {
                case 0:
                    guard let value = Protobuf.readVarint(buffer, &index) else { return false }
                    fields.append((number, .varint(value)))
                case 1:
                    guard let value = Protobuf.readFixed(buffer, &index, count: 8) else { return false }
                    fields.append((number, .fixed64(value)))
                case 2:
                    guard let length = Protobuf.readVarint(buffer, &index), length <= UInt64(buffer.count - index) else { return false }
                    fields.append((number, .bytes(Array(buffer[index..<index + Int(length)]))))
                    index += Int(length)
                case 5:
                    guard let value = Protobuf.readFixed(buffer, &index, count: 4) else { return false }
                    fields.append((number, .fixed32(UInt32(truncatingIfNeeded: value))))
                default:
                    return false
                }
            }
            return true
        }
        guard wellFormed else { return nil }
        self.fields = fields
    }

    public static func == (lhs: ProtobufMessage, rhs: ProtobufMessage) -> Bool {
        lhs.fields.elementsEqual(rhs.fields) { $0.number == $1.number && $0.value == $1.value }
    }

    /// The last value of a field.
    public func value(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    public func has(_ number: Int) -> Bool { value(number) != nil }

    public func uint64(_ number: Int) -> UInt64 {
        switch value(number) {
        case .varint(let raw), .fixed64(let raw): raw
        case .fixed32(let raw): UInt64(raw)
        default: 0
        }
    }

    public func bool(_ number: Int) -> Bool { uint64(number) != 0 }
    public func uint32(_ number: Int) -> UInt32 { UInt32(truncatingIfNeeded: uint64(number)) }
    public func int32(_ number: Int) -> Int32 { Int32(truncatingIfNeeded: uint64(number)) }
    public func enumeration(_ number: Int) -> Int { Int(int32(number)) }
    public func fixed32(_ number: Int) -> UInt32 { uint32(number) }

    public func float(_ number: Int) -> Float {
        guard case .fixed32(let bits) = value(number) else { return 0 }
        return Float(bitPattern: bits)
    }

    public func bytes(_ number: Int) -> [UInt8] {
        guard case .bytes(let bytes) = value(number) else { return [] }
        return bytes
    }

    /// A string field; bytes that are not UTF-8 are repaired, not refused.
    public func string(_ number: Int) -> String {
        String(decoding: bytes(number), as: UTF8.self)
    }

    /// Every value of a repeated string field.
    public func strings(_ number: Int) -> [String] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let bytes) = field.value else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Every value of a repeated enum or integer field, packed or not.
    public func enumerations(_ number: Int) -> [Int] {
        var values: [Int] = []
        for field in fields where field.number == number {
            switch field.value {
            case .varint(let raw):
                values.append(Int(Int32(truncatingIfNeeded: raw)))
            case .bytes(let packed):
                packed.withUnsafeBytes { buffer in
                    var index = 0
                    while index < buffer.count, let raw = Protobuf.readVarint(buffer, &index) {
                        values.append(Int(Int32(truncatingIfNeeded: raw)))
                    }
                }
            default:
                continue
            }
        }
        return values
    }

    /// Every value of a repeated message field that is well formed.
    public func messages(_ number: Int) -> [ProtobufMessage] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let bytes) = field.value else { return nil }
            return ProtobufMessage(bytes)
        }
    }
}
