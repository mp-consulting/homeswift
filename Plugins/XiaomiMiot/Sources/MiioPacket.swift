import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin
import _CryptoExtras

// The miIO LAN packet (docs/clean-room/XiaomiMiot.md section 5): a 32-byte header, big-endian, then the JSON payload
// encrypted with AES-128-CBC under a key and IV made from the device's 16-byte token.

/// A device's token: 16 bytes, written as 32 hexadecimal characters. Never logged.
struct MiioToken: Sendable, Equatable {
    let bytes: [UInt8]
    /// key = MD5(token) (section 5.4).
    let key: [UInt8]
    /// IV = MD5(key ‖ token) (section 5.4; not OpenMiHome's MD5(MD5(key) ‖ token)).
    let iv: [UInt8]

    /// From 32 hexadecimal characters, either case; nil otherwise.
    init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 32, let bytes = Self.decode(text) else { return nil }
        self.init(bytes: bytes)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        key = Array(Insecure.MD5.hash(data: bytes))
        iv = Array(Insecure.MD5.hash(data: key + bytes))
    }

    /// The token as lowercase hex, as it is stored.
    var hex: String { Secrets.hex(bytes) }

    static func decode(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16), hex.distance(from: index, to: next) == 2 else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// One packet, its header read (section 5.1).
struct MiioPacket: Sendable, Equatable {
    static let magic: UInt16 = 0x2131
    static let headerLength = 32
    static let port = 54321

    /// Bytes 4–7: 0, or 0xFFFFFFFF in a hello.
    var unknown: UInt32
    /// Bytes 8–11.
    var deviceID: UInt32
    /// Bytes 12–15.
    var stamp: UInt32
    /// Bytes 16–31: the checksum, or in a hello reply the token field.
    var checksum: [UInt8]
    /// The ciphertext after the header; empty for a hello and its reply.
    var payload: [UInt8]

    /// The hello: `2131 0020` then 28 bytes `0xFF` (section 5.2).
    static let hello = Data([0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xFF, count: 28))

    var isHandshake: Bool { payload.isEmpty }

    /// Reads a packet; nil when it is shorter than a header, has another magic or a length that is not its own.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerLength, Self.uint16(bytes, 0) == Self.magic, Int(Self.uint16(bytes, 2)) == bytes.count else { return nil }
        unknown = Self.uint32(bytes, 4)
        deviceID = Self.uint32(bytes, 8)
        stamp = Self.uint32(bytes, 12)
        checksum = Array(bytes[16..<32])
        payload = Array(bytes[32...])
    }

    init(unknown: UInt32 = 0, deviceID: UInt32, stamp: UInt32, checksum: [UInt8], payload: [UInt8]) {
        self.unknown = unknown
        self.deviceID = deviceID
        self.stamp = stamp
        self.checksum = checksum
        self.payload = payload
    }

    /// Header bytes 0–15 for a packet with `payloadLength` bytes of ciphertext.
    static func header(deviceID: UInt32, stamp: UInt32, payloadLength: Int, unknown: UInt32 = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        append(UInt16(magic), to: &bytes)
        append(UInt16(headerLength + payloadLength), to: &bytes)
        append(unknown, to: &bytes)
        append(deviceID, to: &bytes)
        append(stamp, to: &bytes)
        return bytes
    }

    /// MD5 over header bytes 0–15, the token, then the ciphertext (section 5.5).
    static func checksum(header: [UInt8], token: MiioToken, ciphertext: [UInt8]) -> [UInt8] {
        var md5 = Insecure.MD5()
        md5.update(data: header)
        md5.update(data: token.bytes)
        md5.update(data: ciphertext)
        return Array(md5.finalize())
    }

    /// A request: the JSON payload encrypted, then the header with its checksum.
    static func encode(payload: Data, token: MiioToken, deviceID: UInt32, stamp: UInt32) throws -> Data {
        let ciphertext = try encrypt(payload, token: token)
        let header = header(deviceID: deviceID, stamp: stamp, payloadLength: ciphertext.count)
        return Data(header + checksum(header: header, token: token, ciphertext: ciphertext) + ciphertext)
    }

    /// Whether the checksum is the one the token gives (a packet with a payload).
    func verifies(with token: MiioToken) -> Bool {
        let header = Self.header(deviceID: deviceID, stamp: stamp, payloadLength: payload.count, unknown: unknown)
        return Self.checksum(header: header, token: token, ciphertext: payload) == checksum
    }

    /// The payload decrypted and cleaned (section 5.6); throws when it does not decrypt.
    func decrypt(with token: MiioToken) throws -> Data {
        Self.clean(try Self.decrypt(payload, token: token))
    }

    static func encrypt(_ plaintext: Data, token: MiioToken) throws -> [UInt8] {
        // `AES._CBC` pads with PKCS#7: a payload of whole blocks gains a full block of 0x10.
        let sealed = try AES._CBC.encrypt(plaintext, using: SymmetricKey(data: token.key), iv: AES._CBC.IV(ivBytes: token.iv))
        return Array(sealed)
    }

    /// `unpadded: false` leaves the PKCS#7 padding in place (tests look at it).
    static func decrypt(_ ciphertext: [UInt8], token: MiioToken, unpadded: Bool = true) throws -> Data {
        try AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: token.key), iv: AES._CBC.IV(ivBytes: token.iv), noPadding: !unpadded)
    }

    /// One trailing NUL dropped, then the control characters 0x00–0x09, 0x0B–0x0C, 0x0E–0x1F and 0x7F–0x9F removed (some
    /// devices send invalid JSON). The range 0x80–0x9F is the C1 controls as characters, not UTF-8 continuation bytes.
    static func clean(_ data: Data) -> Data {
        if !needsCleaning(data) { return data }
        var bytes = [UInt8](data)
        if bytes.last == 0 { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        let kept = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x00...0x09, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F: false
            default: true
            }
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: kept)
        return Data(String(result).utf8)
    }

    /// Whether `clean` would change the data: a trailing NUL, a control byte it removes, a C1 control (`C2 80`–`C2 9F`),
    /// or bytes that are not UTF-8.
    private static func needsCleaning(_ data: Data) -> Bool {
        if data.last == 0 { return true }
        var ascii = true, previous: UInt8 = 0
        for byte in data {
            switch byte {
            case 0x00...0x09, 0x0B...0x0C, 0x0E...0x1F, 0x7F: return true
            case 0x80...0x9F where previous == 0xC2: return true
            case 0x80...: ascii = false
            default: break
            }
            previous = byte
        }
        return !ascii && String(data: data, encoding: .utf8) == nil
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8(value >> 16 & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}

/// JSON written in a given key order: the miIO payloads and the cloud's `data` are sent as the sources write them
/// (`{"id","method","params"}`, `{"did","siid","piid"}`), where `JSONValue` sorts its keys.
indirect enum OrderedJSON: Sendable, Equatable {
    case value(JSONValue)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool { a.text == b.text }

    var text: String {
        switch self {
        case .value(let value): value.text()
        case .array(let items): "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): "{" + pairs.map { JSONValue.string($0.0).text() + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    /// A `JSONValue` as it is (its objects' keys sorted).
    init(_ value: JSONValue) {
        self = .value(value)
    }

    static func string(_ text: String) -> OrderedJSON { .value(.string(text)) }
    static func int(_ number: Int) -> OrderedJSON { .value(.number(Double(number))) }
}
