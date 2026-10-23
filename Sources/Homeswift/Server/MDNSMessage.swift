import Foundation

// The DNS wire format as Multicast DNS uses it (RFC 1035, RFC 6762): what the built-in responder
// (`MDNSResponder`) reads and writes. Only the record types a HAP advertisement needs are decoded; the
// others keep their raw data.

/// A domain name as its labels. Compared without regard to ASCII case, as DNS does.
struct DNSName: Hashable, CustomStringConvertible, Sendable {
    var labels: [String]

    init(_ labels: [String]) {
        self.labels = labels
    }

    /// A dotted name such as `_hap._tcp.local`; an instance label containing dots goes in `labels` instead.
    init(dotted: String) {
        labels = dotted.split(separator: ".").map(String.init)
    }

    var key: String { labels.map { $0.lowercased() }.joined(separator: "\u{0}") }

    static func == (lhs: DNSName, rhs: DNSName) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    var description: String { labels.joined(separator: ".") + "." }
}

enum DNSType {
    static let a: UInt16 = 1
    static let ptr: UInt16 = 12
    static let txt: UInt16 = 16
    static let aaaa: UInt16 = 28
    static let srv: UInt16 = 33
    static let nsec: UInt16 = 47
    static let any: UInt16 = 255
}

struct DNSQuestion: Equatable, Sendable {
    var name: DNSName
    var type: UInt16
    /// The top bit of the class: the querier asks for a unicast response (RFC 6762 §5.4).
    var unicastResponse: Bool = false
}

struct DNSRecord: Hashable, Sendable {
    enum Data: Hashable, Sendable {
        case a([UInt8])
        case aaaa([UInt8])
        case ptr(DNSName)
        case srv(priority: UInt16, weight: UInt16, port: UInt16, target: DNSName)
        case txt([UInt8])
        /// The next name (the record's own, in mDNS) and the types that exist for the name.
        case nsec(next: DNSName, types: [UInt16])
        case other(type: UInt16, bytes: [UInt8])

        var type: UInt16 {
            switch self {
            case .a: DNSType.a
            case .aaaa: DNSType.aaaa
            case .ptr: DNSType.ptr
            case .srv: DNSType.srv
            case .txt: DNSType.txt
            case .nsec: DNSType.nsec
            case .other(let type, _): type
            }
        }
    }

    var name: DNSName
    var data: Data
    var ttl: UInt32
    /// The top bit of the class in a response: the name has only these records of the type (RFC 6762 §10.2).
    var cacheFlush: Bool = false

    var type: UInt16 { data.type }

    /// The record with the same name and data, whatever its TTL and cache-flush bit.
    func sameData(as other: DNSRecord) -> Bool { name == other.name && data == other.data }

    /// The record data in canonical form (uncompressed names), for comparing records in a probe tie-break.
    var canonicalData: [UInt8] {
        var writer = DNSWriter(compress: false)
        writer.rdata(data)
        return writer.bytes
    }
}

struct DNSMessage: Sendable {
    var id: UInt16 = 0
    var isResponse = false
    var questions: [DNSQuestion] = []
    var answers: [DNSRecord] = []
    var authorities: [DNSRecord] = []
    var additionals: [DNSRecord] = []

    enum ParseError: Error { case truncated, badName, badRecord }

    /// A response with the authoritative bit (RFC 6762 §18.4).
    func encode() -> [UInt8] {
        var writer = DNSWriter(compress: true)
        writer.u16(id)
        writer.u16(isResponse ? 0x8400 : 0)
        writer.u16(UInt16(questions.count))
        writer.u16(UInt16(answers.count))
        writer.u16(UInt16(authorities.count))
        writer.u16(UInt16(additionals.count))
        for question in questions {
            writer.name(question.name)
            writer.u16(question.type)
            writer.u16(question.unicastResponse ? 0x8001 : 1)
        }
        for record in answers + authorities + additionals {
            writer.record(record)
        }
        return writer.bytes
    }

    init(id: UInt16 = 0, isResponse: Bool = false, questions: [DNSQuestion] = [], answers: [DNSRecord] = [], authorities: [DNSRecord] = [], additionals: [DNSRecord] = []) {
        self.id = id
        self.isResponse = isResponse
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }

    init(bytes: [UInt8]) throws {
        var reader = DNSReader(bytes: bytes)
        id = try reader.u16()
        let flags = try reader.u16()
        isResponse = flags & 0x8000 != 0
        let counts = try (0..<4).map { _ in Int(try reader.u16()) }
        for _ in 0..<counts[0] {
            let name = try reader.name()
            let type = try reader.u16()
            let qclass = try reader.u16()
            questions.append(DNSQuestion(name: name, type: type, unicastResponse: qclass & 0x8000 != 0))
        }
        answers = try (0..<counts[1]).compactMap { _ in try reader.record() }
        authorities = try (0..<counts[2]).compactMap { _ in try reader.record() }
        additionals = try (0..<counts[3]).compactMap { _ in try reader.record() }
    }
}

struct DNSWriter {
    var bytes: [UInt8] = []
    let compress: Bool
    /// Where each name suffix was written, for compression pointers.
    private var offsets: [String: Int] = [:]

    init(compress: Bool) {
        self.compress = compress
    }

    mutating func u16(_ value: UInt16) {
        bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    mutating func u32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    mutating func name(_ name: DNSName, compressed: Bool = true) {
        for index in name.labels.indices {
            let suffix = DNSName(Array(name.labels[index...])).key
            if compress, compressed, let offset = offsets[suffix] {
                u16(0xC000 | UInt16(offset))
                return
            }
            if compress, compressed, bytes.count < 0x3FFF { offsets[suffix] = bytes.count }
            let label = Array(name.labels[index].utf8.prefix(63))
            bytes.append(UInt8(label.count))
            bytes += label
        }
        bytes.append(0)
    }

    mutating func record(_ record: DNSRecord) {
        name(record.name)
        u16(record.type)
        u16(record.cacheFlush ? 0x8001 : 1)
        u32(record.ttl)
        let lengthAt = bytes.count
        u16(0)
        rdata(record.data)
        let length = bytes.count - lengthAt - 2
        bytes[lengthAt] = UInt8(length >> 8)
        bytes[lengthAt + 1] = UInt8(length & 0xFF)
    }

    mutating func rdata(_ data: DNSRecord.Data) {
        switch data {
        case .a(let address), .aaaa(let address):
            bytes += address
        case .ptr(let target):
            name(target)
        case .srv(let priority, let weight, let port, let target):
            u16(priority)
            u16(weight)
            u16(port)
            name(target)
        case .txt(let entries):
            // An empty TXT record holds one empty string (RFC 6763 §6.1).
            bytes += entries.isEmpty ? [0] : entries
        case .nsec(let next, let types):
            // The next name is never compressed (RFC 4034 §4.1.1); mDNS uses window 0 only (RFC 6762 §6.1).
            name(next, compressed: false)
            let inWindow = types.filter { $0 < 256 }
            let length = (Int(inWindow.max() ?? 0) / 8) + 1
            var bitmap = [UInt8](repeating: 0, count: length)
            for type in inWindow {
                bitmap[Int(type) / 8] |= 0x80 >> UInt8(type % 8)
            }
            bytes += [0, UInt8(length)] + bitmap
        case .other(_, let raw):
            bytes += raw
        }
    }
}

struct DNSReader {
    let bytes: [UInt8]
    var position = 0

    mutating func u8() throws -> UInt8 {
        guard position < bytes.count else { throw DNSMessage.ParseError.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try u8()) << 8 | UInt16(try u8())
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try u16()) << 16 | UInt32(try u16())
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= bytes.count else { throw DNSMessage.ParseError.truncated }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    /// A name, following compression pointers backwards only, so a crafted packet cannot loop.
    mutating func name() throws -> DNSName {
        var labels: [String] = []
        var cursor = position
        var jumped = false
        var limit = cursor
        var total = 0
        while true {
            guard cursor < bytes.count else { throw DNSMessage.ParseError.truncated }
            let length = Int(bytes[cursor])
            if length == 0 {
                cursor += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { throw DNSMessage.ParseError.truncated }
                let target = (length & 0x3F) << 8 | Int(bytes[cursor + 1])
                guard target < limit else { throw DNSMessage.ParseError.badName }
                if !jumped { position = cursor + 2 }
                jumped = true
                limit = target
                cursor = target
                continue
            }
            guard length < 64, cursor + 1 + length <= bytes.count else { throw DNSMessage.ParseError.badName }
            labels.append(String(decoding: bytes[cursor + 1..<cursor + 1 + length], as: UTF8.self))
            total += length + 1
            guard total <= 255 else { throw DNSMessage.ParseError.badName }
            cursor += 1 + length
        }
        if !jumped { position = cursor }
        return DNSName(labels)
    }

    /// A record, or nil for a class other than IN (which mDNS does not use).
    mutating func record() throws -> DNSRecord? {
        let name = try name()
        let type = try u16()
        let rclass = try u16()
        let ttl = try u32()
        let length = Int(try u16())
        let end = position + length
        guard end <= bytes.count else { throw DNSMessage.ParseError.truncated }
        let data: DNSRecord.Data
        switch type {
        case DNSType.a where length == 4:
            data = .a(try take(4))
        case DNSType.aaaa where length == 16:
            data = .aaaa(try take(16))
        case DNSType.ptr:
            data = .ptr(try self.name())
        case DNSType.srv:
            data = .srv(priority: try u16(), weight: try u16(), port: try u16(), target: try self.name())
        case DNSType.txt:
            data = .txt(try take(length))
        default:
            data = .other(type: type, bytes: try take(length))
        }
        guard position == end else { throw DNSMessage.ParseError.badRecord }
        guard rclass & 0x7FFF == 1 else { return nil }
        return DNSRecord(name: name, data: data, ttl: ttl, cacheFlush: rclass & 0x8000 != 0)
    }
}
