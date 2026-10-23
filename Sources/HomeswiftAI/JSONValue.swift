import Foundation

/// A JSON document as a value: schemas, tool arguments, configuration blocks and provider payloads
/// travel as `JSONValue` because `[String: Any]` is not `Sendable`.
public enum JSONValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// From a JSONSerialization object (`NSDictionary`, `NSArray`, `NSNumber`, `String`, `NSNull`).
    public init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization makes booleans NSNumber too; CFBoolean has the boolean type encoding.
            if String(cString: number.objCType) == "c" {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map(JSONValue.init(any:)))
        case let object as [String: Any]: self = .object(try object.mapValues(JSONValue.init(any:)))
        default: throw JSONValueError.unsupported(String(describing: type(of: value)))
        }
    }

    /// Parses JSON text.
    public init(data: Data) throws {
        self = try JSONValueParser.parse([UInt8](data))
    }

    public init(string: String) throws {
        self = try JSONValueParser.parse(Array(string.utf8))
    }

    /// Compact JSON text, keys sorted, the bytes `JSONEncoder` writes with `.sortedKeys` and
    /// `.withoutEscapingSlashes` (and `.prettyPrinted`), written directly: the encoder's generic path took most
    /// of the time the web UI and the MCP server spent on a request.
    public func encoded(pretty: Bool = false) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        write(to: &bytes, pretty: pretty, depth: 0)
        return Data(bytes)
    }

    public func text(pretty: Bool = false) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        write(to: &bytes, pretty: pretty, depth: 0)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func write(to bytes: inout [UInt8], pretty: Bool, depth: Int) {
        func indent(_ level: Int) {
            bytes.append(0x0A)
            bytes.append(contentsOf: repeatElement(0x20, count: level * 2))
        }
        switch self {
        case .null: bytes.append(contentsOf: "null".utf8)
        case .bool(let value): bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let value):
            if !value.isFinite {
                bytes.append(contentsOf: "null".utf8)
            } else if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                Self.integer(Int64(value), to: &bytes)
            } else {
                // JSONEncoder's form: the shortest text that reads back, without a trailing ".0".
                let text = value.description
                bytes.append(contentsOf: (text.hasSuffix(".0") ? text.dropLast(2) : Substring(text)).utf8)
            }
        case .string(let value): Self.quote(value, to: &bytes)
        case .array(let items):
            bytes.append(UInt8(ascii: "["))
            if pretty, items.isEmpty { bytes.append(0x0A) }
            for (index, item) in items.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                if pretty { indent(depth + 1) }
                item.write(to: &bytes, pretty: pretty, depth: depth + 1)
            }
            if pretty { indent(depth) }
            bytes.append(UInt8(ascii: "]"))
        case .object(let object):
            bytes.append(UInt8(ascii: "{"))
            if pretty, object.isEmpty { bytes.append(0x0A) }
            // JSONEncoder's .sortedKeys order: by UTF-8 bytes. The keys alone are sorted, then looked up: cheaper than
            // moving (key, value) pairs around.
            for (index, key) in object.keys.sorted(by: Self.precedes).enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                if pretty { indent(depth + 1) }
                Self.quote(key, to: &bytes)
                bytes.append(contentsOf: pretty ? " : ".utf8 : ":".utf8)
                object[key].unsafelyUnwrapped.write(to: &bytes, pretty: pretty, depth: depth + 1)
            }
            if pretty { indent(depth) }
            bytes.append(UInt8(ascii: "}"))
        }
    }

    private static func integer(_ value: Int64, to bytes: inout [UInt8]) {
        if value == 0 {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        if value < 0 { bytes.append(UInt8(ascii: "-")) }
        var magnitude = value.magnitude
        let start = bytes.count
        while magnitude > 0 {
            bytes.append(UInt8(ascii: "0") + UInt8(magnitude % 10))
            magnitude /= 10
        }
        bytes[start...].reverse()
    }

    /// Whether `a` sorts before `b` by their UTF-8 bytes.
    private static func precedes(_ a: String, _ b: String) -> Bool {
        var a = a, b = b
        return a.withUTF8 { a in
            b.withUTF8 { b in
                let common = min(a.count, b.count)
                let order = common == 0 ? 0 : memcmp(a.baseAddress!, b.baseAddress!, common)
                return order == 0 ? a.count < b.count : order < 0
            }
        }
    }

    private static func quote(_ string: String, to bytes: inout [UInt8]) {
        bytes.append(UInt8(ascii: "\""))
        // Nearly every string has nothing to escape: one copy instead of a switch per byte.
        let plain = string.utf8.withContiguousStorageIfAvailable { utf8 -> Bool in
            var index = 0
            while index < utf8.count {
                let byte = utf8[index]
                if byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") { return false }
                index += 1
            }
            bytes.append(contentsOf: utf8)
            return true
        } ?? false
        if !plain {
            let hex = Array("0123456789abcdef".utf8)
            for byte in string.utf8 {
                switch byte {
                case UInt8(ascii: "\""): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
                case UInt8(ascii: "\\"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
                case 0x0A: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
                case 0x0D: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
                case 0x09: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
                case 0x08: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
                case 0x0C: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
                case 0..<0x20: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
                default: bytes.append(byte)
                }
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    public var description: String { text() }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < Double(Int.max) else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

public enum JSONValueError: Error, CustomStringConvertible {
    case unsupported(String)
    case invalid(String, offset: Int)
    public var description: String {
        switch self {
        case .unsupported(let type): "cannot represent \(type) as JSON"
        case .invalid(let reason, let offset): "not valid JSON: \(reason) at byte \(offset)"
        }
    }
}

/// RFC 8259 JSON to `JSONValue`, without the decoder's trial decoding of every type at every value.
/// Accepts what `JSONDecoder` accepts for `JSONValue`: any value at the top, a UTF-8 byte order mark; duplicate
/// keys keep the last value. Nesting stops at 128 levels (the decoder's limit is 512), well within the stack of
/// a secondary thread in a debug build.
struct JSONValueParser {
    /// Valid while `parse` runs.
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private var depth = 0

    static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        try bytes.withUnsafeBufferPointer { buffer in
            var parser = JSONValueParser(bytes: buffer)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
            let value = try parser.value()
            parser.skipWhitespace()
            guard parser.index == buffer.count else { throw parser.error("unexpected text after the value") }
            return value
        }
    }

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    private func error(_ reason: String) -> JSONValueError {
        .invalid(reason, offset: index)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
    }

    private mutating func value() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw error("unexpected character")
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) throws -> JSONValue {
        for byte in word.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw error("unexpected character") }
            index += 1
        }
        return value
    }

    private mutating func nest() throws {
        depth += 1
        guard depth <= 128 else { throw error("too deeply nested") }
    }

    private mutating func object() throws -> JSONValue {
        try nest()
        index += 1
        // The members first, then a dictionary of the right size: growing one member at a time cost more than
        // the rest of parsing.
        var members: [(String, JSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            depth -= 1
            return .object([:])
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected :") }
            index += 1
            members.append((key, try value()))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                depth -= 1
                var object = [String: JSONValue](minimumCapacity: members.count)
                for (key, value) in members { object[key] = value }
                return .object(object)
            } else {
                throw error("expected , or }")
            }
        }
    }

    private mutating func array() throws -> JSONValue {
        try nest()
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            depth -= 1
            return .array(items)
        }
        while true {
            items.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                depth -= 1
                return .array(items)
            } else {
                throw error("expected , or ]")
            }
        }
    }

    private mutating func number() throws -> Double {
        let start = index
        func digits() -> Int {
            let first = index
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
            return index - first
        }
        let negative = bytes[index] == UInt8(ascii: "-")
        if negative { index += 1 }
        let integer = index
        guard digits() > 0 else { throw error("expected a digit") }
        guard bytes[integer] != UInt8(ascii: "0") || index - integer == 1 else { throw error("leading zero") }
        // Most numbers are small integers: exact as a Double, no text to convert.
        if index - integer <= 15, index == bytes.count || (bytes[index] != UInt8(ascii: ".") && bytes[index] | 0x20 != UInt8(ascii: "e")) {
            var value: Int64 = 0
            for position in integer..<index { value = value * 10 + Int64(bytes[position] - UInt8(ascii: "0")) }
            return negative ? -Double(value) : Double(value)
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error("expected a digit") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("expected a digit") }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            index = start
            throw error("number out of range")
        }
        return value
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error("bad \\u escape")
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func string() throws -> String {
        index += 1
        let start = index
        // The common case, nothing escaped: one copy of the bytes.
        while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
            guard bytes[index] >= 0x20 else { throw error("control character in a string") }
            index += 1
        }
        guard index < bytes.count else { throw error("unterminated string") }
        if bytes[index] == UInt8(ascii: "\"") {
            index += 1
            return String(decoding: bytes[start..<(index - 1)], as: UTF8.self)
        }
        var scalars: [UInt8] = []
        scalars.reserveCapacity(index - start + 64)
        scalars.append(contentsOf: bytes[start..<index])
        while true {
            // The plain bytes up to the next quote or escape, copied at once: text with JSON in it (a log line) has
            // an escape every few bytes, and a byte at a time cost seconds in a debug build.
            let run = index
            while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
                guard bytes[index] >= 0x20 else { throw error("control character in a string") }
                index += 1
            }
            if index > run { scalars.append(contentsOf: bytes[run..<index]) }
            guard index < bytes.count else { throw error("unterminated string") }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: scalars, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw error("unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): scalars.append(escape)
                case UInt8(ascii: "b"): scalars.append(0x08)
                case UInt8(ascii: "f"): scalars.append(0x0C)
                case UInt8(ascii: "n"): scalars.append(0x0A)
                case UInt8(ascii: "r"): scalars.append(0x0D)
                case UInt8(ascii: "t"): scalars.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code) {
                        guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw error("lone surrogate") }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw error("lone surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00..<0xE000).contains(code) {
                        throw error("lone surrogate")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("bad \\u escape") }
                    scalars.append(contentsOf: String(Character(scalar)).utf8)
                default:
                    throw error("bad escape")
                }
            default:
                throw error("unreachable: a run stops only at a quote or an escape")
            }
        }
    }
}

extension JSONValue {
    /// Encodes any `Encodable` as a JSON value.
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes this value into a type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: encoded())
    }
}
