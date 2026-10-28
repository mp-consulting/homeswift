import Foundation

/// The numbered fields of an EcoFlow property message, read from the protobuf wire format without its schema.
///
/// A payload holds one or more messages, each a header (field 1) with its command and its body; the body holds the
/// readings by number (a STREAM's status message: 517 the solar, 516 the home, 515 the grid, 518 the battery's power).
/// A number can come as an integer, a 32-bit or a 64-bit float; the last one in the message wins, as protobuf says.
enum EcoFlowProtobuf {
    /// The read request the app sends when it opens a device: Send_Header_Msg { msg: Header { seq, from: "Android" } },
    /// published to `/app/<user>/<serial>/thing/property/get`. The device answers with a snapshot of its state on its
    /// property topic.
    static func propertyRequest(seq: Int) -> Data {
        let header = varintField(14, UInt64(seq)) + bytesField(23, Array("Android".utf8))
        return Data(bytesField(1, header))
    }

    /// The wire format's encoders, shared with the tests that build messages.
    static func encode(_ value: UInt64) -> [UInt8] {
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

    static func tag(_ number: Int, _ wireType: Int) -> [UInt8] { encode(UInt64(number << 3 | wireType)) }
    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] { tag(number, 0) + encode(value) }
    static func bytesField(_ number: Int, _ data: [UInt8]) -> [UInt8] { tag(number, 2) + encode(UInt64(data.count)) + data }

    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)

        /// The value as a number: an integer (signed), a 32-bit or a 64-bit float; nil for bytes.
        var number: Double? {
            switch self {
            case .varint(let raw): Double(Int64(bitPattern: raw))
            case .fixed32(let bits): Double(Float(bitPattern: bits))
            case .fixed64(let bits): Double(bitPattern: bits)
            case .bytes: nil
            }
        }
    }

    struct Field: Equatable {
        let number: Int
        let value: Value
    }


    /// The fields of one message, or nil when the bytes are not a well-formed message.
    static func fields(_ data: Data) -> [Field]? {
        data.withUnsafeBytes { buffer in
            var result: [Field] = []
            let wellFormed = walk(buffer) { number, value in
                switch value {
                case .scalar(let scalar): result.append(Field(number: number, value: scalar))
                case .bytes(let bytes): result.append(Field(number: number, value: .bytes(Data(bytes))))
                }
            }
            return wellFormed ? result : nil
        }
    }

    /// A field as `walk` reads it: a number, or a bytes field's bytes, in place.
    private enum RawValue {
        case scalar(Value)
        case bytes(UnsafeRawBufferPointer)
    }

    /// Calls `visit` with each field of a message, in order, reading the bytes in place: no copies, no arrays. Returns
    /// false when the bytes are not a well-formed message; the fields before the fault have been visited, so a caller
    /// that wants all or nothing keeps what it read until then.
    private static func walk(_ buffer: UnsafeRawBufferPointer, _ visit: (Int, RawValue) -> Void) -> Bool {
        var index = 0
        while index < buffer.count {
            guard let key = varint(buffer, &index) else { return false }
            let number = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint(buffer, &index) else { return false }
                visit(number, .scalar(.varint(value)))
            case 1:
                guard let bits = fixed(buffer, &index, count: 8) else { return false }
                visit(number, .scalar(.fixed64(bits)))
            case 2:
                guard let length = varint(buffer, &index), length <= UInt64(buffer.count - index) else { return false }
                visit(number, .bytes(UnsafeRawBufferPointer(rebasing: buffer[index..<index + Int(length)])))
                index += Int(length)
            case 5:
                guard let bits = fixed(buffer, &index, count: 4) else { return false }
                visit(number, .scalar(.fixed32(UInt32(bits))))
            default:
                return false
            }
        }
        return true
    }

    /// Each message of a payload: a payload holds one or more headers (field 1), each with its command (`cmd_func`
    /// 8, `cmd_id` 9) and its body (field 1). A portable station's full answer is four of them, one per command.
    /// A body sent with `enc_type` 1 (field 6), as most pushes are, is XOR-ed with the low byte of the header's
    /// sequence number (field 14), and is read decrypted.
    struct Message {
        let command: Command
        /// The body as it came, and the key it is XOR-ed with: it is decrypted when read, so a message of a command
        /// the model does not read costs no decryption.
        let sent: Data
        let key: UInt8?

        var body: Data {
            guard let key else { return sent }
            var decrypted = sent
            decrypted.withUnsafeMutableBytes { EcoFlowProtobuf.decrypt($0, key: key) }
            return decrypted
        }
    }

    struct Command: Hashable {
        let function: Int
        let id: Int
    }

    static func messages(_ payload: Data) -> [Message] {
        payload.withUnsafeBytes { buffer in
            var messages: [Message] = []
            let wellFormed = walk(buffer) { number, value in
                guard number == 1, case .bytes(let header) = value, let message = message(header) else { return }
                messages.append(message)
            }
            return wellFormed ? messages : []
        }
    }

    /// One header's command and body; nil when the header is not a well-formed message or has no body. The last of a
    /// repeated field wins, and a field that is not a number reads -1.
    private static func message(_ header: UnsafeRawBufferPointer) -> Message? {
        guard let read = Self.header(header) else { return nil }
        return Message(command: read.command, sent: Data(read.body), key: read.key)
    }

    /// A header's command, body and decryption key, read in place.
    private static func header(_ header: UnsafeRawBufferPointer) -> (command: Command, body: UnsafeRawBufferPointer, key: UInt8?)? {
        var body: UnsafeRawBufferPointer?
        var function = -1, id = -1, encryption = -1, sequence = -1
        let wellFormed = walk(header) { number, value in
            var integer: Int {
                guard case .scalar(.varint(let raw)) = value else { return -1 }
                return Int(truncatingIfNeeded: raw)
            }
            switch number {
            case 1:
                if case .bytes(let bytes) = value { body = bytes } else { body = nil }
            case 6: encryption = integer
            case 8: function = integer
            case 9: id = integer
            case 14: sequence = integer
            default: break
            }
        }
        guard wellFormed, let body else { return nil }
        return (Command(function: function, id: id), body, encryption == 1 ? UInt8(truncatingIfNeeded: max(sequence, 0)) : nil)
    }

    /// XORs `bytes` with `key`, eight bytes at a time, then the rest.
    private static func decrypt(_ bytes: UnsafeMutableRawBufferPointer, key: UInt8) {
        let wide = UInt64(key) &* 0x0101_0101_0101_0101
        var index = 0
        while index + 8 <= bytes.count {
            let word = bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
            bytes.storeBytes(of: word ^ wide, toByteOffset: index, as: UInt64.self)
            index += 8
        }
        while index < bytes.count {
            bytes[index] ^= key
            index += 1
        }
    }

    /// Each message of `payload` whose command `lookup` knows, its body handed to `read` in place, an encrypted one
    /// decrypted into a buffer on the stack: no copy is kept. Returns how many messages the payload holds; nil when
    /// it is not well formed, and then none is read (as `messages` gives none).
    static func forEachMessage<T>(_ payload: Data, lookup: (Command) -> T?, _ read: (T, UnsafeRawBufferPointer) -> Void) -> Int? {
        payload.withUnsafeBytes { buffer -> Int? in
            // The whole payload is checked first: a malformed one has none of its messages read.
            guard walk(buffer, { _, _ in }) else { return nil }
            var count = 0
            _ = walk(buffer) { number, value in
                guard number == 1, case .bytes(let bytes) = value, let header = header(bytes) else { return }
                count += 1
                guard let known = lookup(header.command) else { return }
                guard let key = header.key else { return read(known, header.body) }
                withUnsafeTemporaryAllocation(byteCount: header.body.count, alignment: 8) { scratch in
                    scratch.copyMemory(from: header.body)
                    decrypt(scratch, key: key)
                    read(known, UnsafeRawBufferPointer(scratch))
                }
            }
            return count
        }
    }

    /// The numbers of a message's body, by field number. Bytes fields (text, nested messages) are left out; the last
    /// of a repeated number wins, as protobuf says.
    static func numbers(_ body: Data) -> [Int: Double] {
        var numbers: [Int: Double] = [:]
        for field in fields(body) ?? [] {
            if let number = field.value.number { numbers[field.number] = number }
        }
        return numbers
    }

    /// The field numbers a model reads under one command, as a tree: a STREAM's status message has a few dozen of its
    /// hundreds of fields read, a RIVER's battery message one nested field. Reading through it skips the rest without
    /// naming them.
    struct Wanted: Sendable, Equatable {
        /// The key the field's number is read under (`32_2.1.15`), nil when it is not read: kept whole, so a reading
        /// costs no text built.
        var key: String?
        /// Where the field's number is kept: the key's position in the list the tree was made from.
        var slot: Int?
        /// The fields read inside this one, a nested message.
        var fields: [Int: Wanted] = [:] {
            didSet { table = Self.table(fields) }
        }
        /// `fields` by number, for the numbers up to a few thousand (a STREAM's go to 1211): a message's hundreds of
        /// fields are each looked up, an array read rather than a hash.
        private(set) var table: [Wanted?] = []

        static func table(_ fields: [Int: Wanted]) -> [Wanted?] {
            guard let last = fields.keys.max(), last < 4096 else { return [] }
            var table = [Wanted?](repeating: nil, count: last + 1)
            for (number, field) in fields where number >= 0 { table[number] = field }
            return table
        }

        /// The field `number`'s node, if it is read.
        func field(_ number: Int) -> Wanted? {
            guard !table.isEmpty else { return fields[number] }
            return number >= 0 && number < table.count ? table[number] : nil
        }

        /// Each command's tree, by its prefix (`32_2`), from keys such as `32_2.1.15`, each key's slot its position in
        /// `keys`; keys of no command (a JSON quota's names) have none.
        static func commands(_ keys: [String]) -> [String: Wanted] {
            var commands: [String: Wanted] = [:]
            for (slot, key) in keys.enumerated() {
                let parts = key.split(separator: ".")
                guard parts.count > 1, parts[0].contains("_") else { continue }
                let numbers = parts.dropFirst().compactMap { Int($0) }
                guard numbers.count == parts.count - 1 else { continue }
                commands[String(parts[0]), default: Wanted()].add(numbers[...], key: key, slot: slot)
            }
            return commands
        }

        /// Every slot in the tree.
        var slots: [Int] { (slot.map { [$0] } ?? []) + fields.values.flatMap(\.slots) }

        private mutating func add(_ path: ArraySlice<Int>, key: String, slot: Int) {
            guard let first = path.first else {
                self.key = key
                self.slot = slot
                return
            }
            fields[first, default: Wanted()].add(path.dropFirst(), key: key, slot: slot)
        }
    }

    /// The numbers of a message's body by key, as EcoFlowModel names them: `<prefix>.<field>`, and a nested message's
    /// numbers under its field (`32_2.1.15`), up to `depth` levels down. Bytes that are not a message (text) give none.
    /// With `wanted`, only the fields it names are read, the others skipped without being named.
    static func keyed(_ body: Data, prefix: String, wanted: Wanted? = nil, depth: Int = 3) -> [String: Double] {
        body.withUnsafeBytes { read($0, prefix: prefix, wanted: wanted, depth: depth) } ?? [:]
    }

    /// `keyed` over the bytes in place; nil when they are not a well-formed message.
    private static func read(_ buffer: UnsafeRawBufferPointer, prefix: String, wanted: Wanted?, depth: Int) -> [String: Double]? {
        var keyed: [String: Double] = [:]
        let wellFormed = walk(buffer) { number, value in
            let node = wanted?.fields[number]
            guard wanted == nil || node != nil else { return }
            switch value {
            case .scalar(let scalar):
                guard let reading = scalar.number else { return }
                if let node {
                    if let key = node.key { keyed[key] = reading }
                } else {
                    keyed["\(prefix).\(number)"] = reading
                }
            case .bytes(let inner):
                // The tree's nodes carry their keys: the nested prefix is named only when everything is read.
                guard node.map({ !$0.fields.isEmpty }) ?? (depth > 1),
                      let nested = read(inner, prefix: node == nil ? "\(prefix).\(number)" : "", wanted: node, depth: depth - 1) else { return }
                keyed.merge(nested) { _, new in new }
            }
        }
        return wellFormed ? keyed : nil
    }

    /// The numbers `wanted` names in a body, into `values` at their slots; a body that is not a well-formed message
    /// changes none (the numbers wait on the stack until it has been read through), and a nested one that is not
    /// leaves its outer message's. Returns whether a number was read.
    static func read(_ body: UnsafeRawBufferPointer, wanted: Wanted, into values: inout [Double?]) -> Bool {
        withUnsafeTemporaryAllocation(of: (slot: Int, value: Double).self, capacity: max(values.count, 1)) { pending in
            var count = 0
            guard collect(body, wanted, pending, &count) else { return false }
            for index in 0..<count { values[pending[index].slot] = pending[index].value }
            return count > 0
        }
    }

    private static func collect(_ buffer: UnsafeRawBufferPointer, _ wanted: Wanted,
                                _ pending: UnsafeMutableBufferPointer<(slot: Int, value: Double)>, _ count: inout Int) -> Bool {
        let mark = count
        let wellFormed = walk(buffer) { number, value in
            guard let node = wanted.field(number) else { return }
            switch value {
            case .scalar(let scalar):
                guard let slot = node.slot, let reading = scalar.number else { return }
                // The last of a repeated number wins: it takes its slot's place.
                if let earlier = (mark..<count).first(where: { pending[$0].slot == slot }) {
                    pending[earlier].value = reading
                } else if count < pending.count {
                    pending[count] = (slot, reading)
                    count += 1
                }
            case .bytes(let inner):
                if !node.fields.isEmpty { _ = collect(inner, node, pending, &count) }
            }
        }
        if !wellFormed { count = mark }
        return wellFormed
    }

    /// Whether the body holds a number, up to `depth` levels down: what `keyed` would find something in.
    static func hasNumber(_ body: Data, depth: Int = 3) -> Bool {
        body.withUnsafeBytes { hasNumber($0, depth: depth) }
    }

    static func hasNumber(_ buffer: UnsafeRawBufferPointer, depth: Int = 3) -> Bool {
        var found = false
        let wellFormed = walk(buffer) { _, value in
            guard !found else { return }
            switch value {
            case .scalar: found = true
            case .bytes(let inner): found = depth > 1 && hasNumber(inner, depth: depth - 1)
            }
        }
        return wellFormed && found
    }

    private static func varint(_ buffer: UnsafeRawBufferPointer, _ index: inout Int) -> UInt64? {
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

    private static func fixed(_ buffer: UnsafeRawBufferPointer, _ index: inout Int, count: Int) -> UInt64? {
        guard buffer.count - index >= count else { return nil }
        var result: UInt64 = 0
        for offset in 0..<count {
            result |= UInt64(buffer[index + offset]) << (8 * UInt64(offset))
        }
        index += count
        return result
    }
}
