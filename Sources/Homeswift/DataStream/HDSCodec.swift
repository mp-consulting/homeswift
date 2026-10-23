import Foundation

/// A value of the HomeKit Data Stream encoding (HAP-NodeJS's DataStreamParser): the header and message of every
/// HDS frame are dictionaries of these.
///
/// `.int` and `.double` are what JavaScript numbers become: an integral value takes the smallest integer tag, a
/// fractional one a Float64. The sized cases force a tag, as HAP-NodeJS's `Int64(...)` wrappers do.
indirect enum HDSValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case float32(Float)
    case float64(Double)
    /// Seconds since 2001-01-01.
    case date(Double)
    case uuid(String)
    case string(String)
    case data(Data)
    case array([HDSValue])
    case dictionary(HDSDictionary)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        switch self {
        case .int(let value), .int64(let value): value
        case .int8(let value): Int64(value)
        case .int16(let value): Int64(value)
        case .int32(let value): Int64(value)
        case .double(let value), .float64(let value): value.rounded() == value ? Int64(exactly: value) : nil
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var dictionaryValue: HDSDictionary? {
        if case .dictionary(let value) = self { return value }
        return nil
    }
}

extension HDSValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

/// A dictionary that keeps its keys in order, as a JavaScript object does.
struct HDSDictionary: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    struct Entry: Sendable, Equatable {
        var key: String
        var value: HDSValue
    }

    var entries: [Entry]

    init(_ entries: [Entry] = []) { self.entries = entries }

    init(dictionaryLiteral elements: (String, HDSValue)...) {
        entries = elements.map { Entry(key: $0.0, value: $0.1) }
    }

    subscript(key: String) -> HDSValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }
}

enum HDSCodingError: Error, Equatable {
    case invalidTag(UInt8, at: Int)
    case endOfData
    case compressionIndex(Int)
}

/// The HDS tags (`DataFormatTags`).
enum HDSTag {
    static let invalid: UInt8 = 0
    static let `true`: UInt8 = 1
    static let `false`: UInt8 = 2
    static let terminator: UInt8 = 3
    static let null: UInt8 = 4
    static let uuid: UInt8 = 5
    static let date: UInt8 = 6
    static let integerMinusOne: UInt8 = 7
    static let integerRangeStart: UInt8 = 8
    static let integerRangeStop: UInt8 = 46
    static let int8: UInt8 = 48
    static let int16: UInt8 = 49
    static let int32: UInt8 = 50
    static let int64: UInt8 = 51
    static let float32: UInt8 = 53
    static let float64: UInt8 = 54
    static let utf8LengthStart: UInt8 = 64
    static let utf8LengthStop: UInt8 = 96
    static let utf8Length8: UInt8 = 97
    static let utf8Length16: UInt8 = 98
    static let utf8Length32: UInt8 = 99
    static let utf8Length64: UInt8 = 100
    static let utf8NullTerminated: UInt8 = 111
    static let dataLengthStart: UInt8 = 112
    static let dataLengthStop: UInt8 = 144
    static let dataLength8: UInt8 = 145
    static let dataLength16: UInt8 = 146
    static let dataLength32: UInt8 = 147
    static let dataLength64: UInt8 = 148
    static let dataTerminated: UInt8 = 159
    static let compressionStart: UInt8 = 160
    static let compressionStop: UInt8 = 207
    static let arrayLengthStart: UInt8 = 208
    static let arrayLengthStop: UInt8 = 222
    static let arrayTerminated: UInt8 = 223
    static let dictionaryLengthStart: UInt8 = 224
    static let dictionaryLengthStop: UInt8 = 238
    static let dictionaryTerminated: UInt8 = 239
}

/// Encodes like HAP-NodeJS's `DataStreamWriter`, back references to repeated values included: a string, sized
/// integer, float, date or UUID written a second time becomes a compression tag. (Data is never compressed:
/// HAP-NodeJS compares buffers by identity.)
struct HDSWriter {
    private(set) var data = Data()
    private var written: [HDSValue] = []

    static func encode(_ value: HDSValue) -> Data {
        var writer = HDSWriter()
        writer.write(value)
        return writer.data
    }

    static func encode(_ dictionary: HDSDictionary) -> Data { encode(.dictionary(dictionary)) }

    private mutating func tag(_ tag: UInt8) { data.append(tag) }

    private mutating func compressed(_ value: HDSValue) -> Bool {
        guard let index = written.firstIndex(of: value) else {
            written.append(value)
            return false
        }
        guard index <= Int(HDSTag.compressionStop - HDSTag.compressionStart) else { return false }
        tag(HDSTag.compressionStart + UInt8(index))
        return true
    }

    private mutating func little<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: HDSValue) {
        switch value {
        case .null: tag(HDSTag.null)
        case .bool(let bool): tag(bool ? HDSTag.true : HDSTag.false)
        case .int(let number): writeNumber(number)
        case .double(let number):
            if number.rounded() == number, let exact = Int64(exactly: number) { writeNumber(exact) } else { write(.float64(number)) }
        case .int8(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.int8)
            little(number)
        case .int16(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.int16)
            little(number)
        case .int32(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.int32)
            little(number)
        case .int64(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.int64)
            little(number)
        case .float32(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.float32)
            little(number.bitPattern)
        case .float64(let number):
            guard !compressed(value) else { return }
            tag(HDSTag.float64)
            little(number.bitPattern)
        case .date(let seconds):
            guard !compressed(value) else { return }
            tag(HDSTag.date)
            little(seconds.bitPattern)
        case .uuid(let uuid):
            guard !compressed(.uuid(uuid.lowercased())) else { return }
            tag(HDSTag.uuid)
            data.append(HAPTLV.uuidBytes(uuid))
        case .string(let string):
            guard !compressed(value) else { return }
            let bytes = Data(string.utf8)
            writeLength(bytes.count, short: HDSTag.utf8LengthStart, tags: (HDSTag.utf8Length8, HDSTag.utf8Length16, HDSTag.utf8Length32, HDSTag.utf8Length64))
            data.append(bytes)
        case .data(let bytes):
            writeLength(bytes.count, short: HDSTag.dataLengthStart, tags: (HDSTag.dataLength8, HDSTag.dataLength16, HDSTag.dataLength32, HDSTag.dataLength64))
            data.append(bytes)
        case .array(let elements):
            let short = elements.count <= 12
            tag(short ? HDSTag.arrayLengthStart + UInt8(elements.count) : HDSTag.arrayTerminated)
            for element in elements { write(element) }
            if !short { tag(HDSTag.terminator) }
        case .dictionary(let dictionary):
            let short = dictionary.entries.count <= 14
            tag(short ? HDSTag.dictionaryLengthStart + UInt8(dictionary.entries.count) : HDSTag.dictionaryTerminated)
            for entry in dictionary.entries {
                write(.string(entry.key))
                write(entry.value)
            }
            if !short { tag(HDSTag.terminator) }
        }
    }

    private mutating func writeLength(_ length: Int, short: UInt8, tags: (UInt8, UInt8, UInt8, UInt8)) {
        if length <= 32 {
            tag(short + UInt8(length))
        } else if length <= 0xFF {
            tag(tags.0)
            data.append(UInt8(length))
        } else if length <= 0xFFFF {
            tag(tags.1)
            little(UInt16(length))
        } else if length <= 0xFFFF_FFFF {
            tag(tags.2)
            little(UInt32(length))
        } else {
            tag(tags.3)
            little(UInt64(length))
        }
    }

    /// `writeNumber`: -1 and 0...39 have their own tags, then the smallest integer that holds the value.
    private mutating func writeNumber(_ number: Int64) {
        if number == -1 {
            tag(HDSTag.integerMinusOne)
        } else if (0...39).contains(number) {
            tag(HDSTag.integerRangeStart + UInt8(number))
        } else if let small = Int8(exactly: number) {
            write(.int8(small))
        } else if let small = Int16(exactly: number) {
            write(.int16(small))
        } else if let small = Int32(exactly: number) {
            write(.int32(small))
        } else {
            write(.int64(number))
        }
    }
}

/// Decodes like HAP-NodeJS's `DataStreamReader`, which tracks every value it reads for back references.
struct HDSReader {
    let data: Data
    private(set) var index: Int
    private var tracked: [HDSValue] = []

    init(_ data: Data) {
        self.data = Data(data)
        index = 0
    }

    static func decode(_ data: Data) throws -> HDSValue {
        var reader = HDSReader(data)
        return try reader.read()
    }

    private mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, index + count <= data.count else { throw HDSCodingError.endOfData }
        defer { index += count }
        return data.subdata(in: index..<index + count)
    }

    private mutating func little<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        var value: T = 0
        for (shift, byte) in raw.enumerated() { value |= T(truncatingIfNeeded: byte) << (8 * shift) }
        return value
    }

    private mutating func track(_ value: HDSValue) -> HDSValue {
        tracked.append(value)
        return value
    }

    private mutating func utf8(_ length: Int) throws -> HDSValue {
        track(.string(String(decoding: try bytes(length), as: UTF8.self)))
    }

    private mutating func terminated(_ terminator: UInt8) throws -> Data {
        guard let end = data[index...].firstIndex(of: terminator) else { throw HDSCodingError.endOfData }
        defer { index = end + 1 }
        return data.subdata(in: index..<end)
    }

    /// The terminator tag, which only ends terminated arrays and dictionaries.
    private static let terminatorMarker = HDSValue.data(Data([0xFF, 0x03, 0xFF]))

    mutating func read() throws -> HDSValue {
        let value = try readAny()
        return value
    }

    private mutating func readAny(allowTerminator: Bool = false) throws -> HDSValue {
        let start = index
        let tag = try bytes(1)[0]
        switch tag {
        case HDSTag.invalid:
            throw HDSCodingError.invalidTag(tag, at: start)
        case HDSTag.true: return track(.bool(true))
        case HDSTag.false: return track(.bool(false))
        case HDSTag.terminator:
            guard allowTerminator else { throw HDSCodingError.invalidTag(tag, at: start) }
            return Self.terminatorMarker
        case HDSTag.null: return .null
        case HDSTag.uuid: return track(.uuid(HAPTLV.uuidString(try bytes(16))))
        case HDSTag.date: return track(.double(Double(bitPattern: try little(UInt64.self))))
        case HDSTag.integerMinusOne: return track(.int(-1))
        case HDSTag.integerRangeStart...HDSTag.integerRangeStop: return track(.int(Int64(tag - HDSTag.integerRangeStart)))
        case HDSTag.int8: return track(.int(Int64(try little(Int8.self))))
        case HDSTag.int16: return track(.int(Int64(try little(Int16.self))))
        case HDSTag.int32: return track(.int(Int64(try little(Int32.self))))
        case HDSTag.int64: return track(.int(try little(Int64.self)))
        case HDSTag.float32: return track(.double(Double(Float(bitPattern: try little(UInt32.self)))))
        case HDSTag.float64: return track(.double(Double(bitPattern: try little(UInt64.self))))
        case HDSTag.utf8LengthStart...HDSTag.utf8LengthStop: return try utf8(Int(tag - HDSTag.utf8LengthStart))
        case HDSTag.utf8Length8: return try utf8(Int(try little(UInt8.self)))
        case HDSTag.utf8Length16: return try utf8(Int(try little(UInt16.self)))
        case HDSTag.utf8Length32: return try utf8(Int(try little(UInt32.self)))
        case HDSTag.utf8Length64: return try utf8(Int(try little(UInt64.self)))
        case HDSTag.utf8NullTerminated: return track(.string(String(decoding: try terminated(0), as: UTF8.self)))
        case HDSTag.dataLengthStart...HDSTag.dataLengthStop: return track(.data(try bytes(Int(tag - HDSTag.dataLengthStart))))
        case HDSTag.dataLength8: return track(.data(try bytes(Int(try little(UInt8.self)))))
        case HDSTag.dataLength16: return track(.data(try bytes(Int(try little(UInt16.self)))))
        case HDSTag.dataLength32: return track(.data(try bytes(Int(try little(UInt32.self)))))
        case HDSTag.dataLength64: return track(.data(try bytes(Int(try little(UInt64.self)))))
        case HDSTag.dataTerminated: return track(.data(try terminated(HDSTag.terminator)))
        case HDSTag.compressionStart...HDSTag.compressionStop:
            let position = Int(tag - HDSTag.compressionStart)
            guard position < tracked.count else { throw HDSCodingError.compressionIndex(position) }
            return tracked[position]
        case HDSTag.arrayLengthStart...HDSTag.arrayLengthStop:
            return .array(try (0..<Int(tag - HDSTag.arrayLengthStart)).map { _ in try readAny() })
        case HDSTag.arrayTerminated:
            var elements: [HDSValue] = []
            while true {
                let element = try readAny(allowTerminator: true)
                if element == Self.terminatorMarker { break }
                elements.append(element)
            }
            return .array(elements)
        case HDSTag.dictionaryLengthStart...HDSTag.dictionaryLengthStop:
            var dictionary = HDSDictionary()
            for _ in 0..<Int(tag - HDSTag.dictionaryLengthStart) {
                let key = Self.key(try readAny())
                dictionary.entries.append(.init(key: key, value: try readAny()))
            }
            return .dictionary(dictionary)
        case HDSTag.dictionaryTerminated:
            var dictionary = HDSDictionary()
            while true {
                let key = try readAny(allowTerminator: true)
                if key == Self.terminatorMarker { break }
                dictionary.entries.append(.init(key: Self.key(key), value: try readAny()))
            }
            return .dictionary(dictionary)
        default:
            throw HDSCodingError.invalidTag(tag, at: start)
        }
    }

    /// JavaScript turns every key into a string.
    private static func key(_ value: HDSValue) -> String {
        switch value {
        case .string(let string), .uuid(let string): string
        case .int(let number): String(number)
        case .double(let number): number.rounded() == number ? String(Int64(number)) : String(number)
        case .bool(let bool): String(bool)
        case .null: "null"
        default: "\(value)"
        }
    }
}
