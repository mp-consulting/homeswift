import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A STUN message (RFC 5389): a binding request, response or error, its attributes in order. ICE's connectivity
/// checks (RFC 8445) are binding requests carrying USERNAME, PRIORITY, ICE-CONTROLLING or ICE-CONTROLLED,
/// USE-CANDIDATE, MESSAGE-INTEGRITY (HMAC-SHA1 under the peer's ICE password) and FINGERPRINT.
public struct STUNMessage: Sendable, Equatable {
    public static let magicCookie: UInt32 = 0x2112_A442
    static let fingerprintXOR: UInt32 = 0x5354_554E

    public enum Kind: UInt16, Sendable {
        case bindingRequest = 0x0001
        case bindingSuccess = 0x0101
        case bindingError = 0x0111
        case bindingIndication = 0x0011
    }

    /// Attribute types this stack reads and writes.
    public enum AttributeType: UInt16, Sendable {
        case mappedAddress = 0x0001
        case username = 0x0006
        case messageIntegrity = 0x0008
        case errorCode = 0x0009
        case xorMappedAddress = 0x0020
        case priority = 0x0024
        case useCandidate = 0x0025
        case software = 0x8022
        case fingerprint = 0x8028
        case iceControlled = 0x8029
        case iceControlling = 0x802A
    }

    public struct Attribute: Sendable, Equatable {
        public var type: UInt16
        public var value: [UInt8]

        public init(type: UInt16, value: [UInt8]) {
            self.type = type
            self.value = value
        }

        public init(_ type: AttributeType, _ value: [UInt8]) { self.init(type: type.rawValue, value: value) }
    }

    public var type: UInt16
    public var transactionID: [UInt8]
    /// Every attribute but MESSAGE-INTEGRITY and FINGERPRINT, which `encode` adds.
    public var attributes: [Attribute]

    public init(_ kind: Kind, transactionID: [UInt8] = STUNMessage.newTransactionID(), attributes: [Attribute] = []) {
        type = kind.rawValue
        self.transactionID = transactionID
        self.attributes = attributes
    }

    public static func newTransactionID() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: 0...255) } }

    public var kind: Kind? { Kind(rawValue: type) }

    public func attribute(_ type: AttributeType) -> [UInt8]? { attributes.first { $0.type == type.rawValue }?.value }

    // MARK: Encoding

    /// The message's bytes, with MESSAGE-INTEGRITY under `integrityKey` (the ICE password, as UTF-8, for short-term
    /// credentials) and FINGERPRINT when asked. `padding` fills attributes to four bytes (RFC 5389 leaves it free; RFC
    /// 5769's vectors use spaces).
    public func encode(integrityKey: [UInt8]? = nil, fingerprint: Bool = true, padding: UInt8 = 0) -> [UInt8] {
        var body: [UInt8] = []
        for attribute in attributes { Self.append(attribute, to: &body, padding: padding) }
        if let integrityKey {
            // The length counts the integrity attribute; the HMAC covers everything before it.
            let header = self.header(length: body.count + 24)
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: header + body, using: SymmetricKey(data: integrityKey))
            Self.append(Attribute(.messageIntegrity, Array(mac)), to: &body, padding: padding)
        }
        if fingerprint {
            let header = self.header(length: body.count + 8)
            let crc = CRC32.checksum(header + body) ^ Self.fingerprintXOR
            Self.append(Attribute(.fingerprint, Self.be32(crc)), to: &body, padding: padding)
        }
        return header(length: body.count) + body
    }

    private func header(length: Int) -> [UInt8] {
        Self.be16(type) + Self.be16(UInt16(length)) + Self.be32(Self.magicCookie) + transactionID
    }

    private static func append(_ attribute: Attribute, to body: inout [UInt8], padding: UInt8) {
        body += be16(attribute.type) + be16(UInt16(attribute.value.count)) + attribute.value
        let pad = (4 - attribute.value.count % 4) % 4
        body += [UInt8](repeating: padding, count: pad)
    }

    // MARK: Decoding

    /// Whether the bytes look like STUN (RFC 7983's demultiplexing: first byte 0–3, the magic cookie).
    public static func isSTUN(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 20 && bytes[0] < 4 && be32(bytes, 4) == magicCookie
    }

    /// The message and where each attribute starts (to check integrity over the bytes before it); nil when the bytes
    /// are not a well-formed STUN message.
    public static func decode(_ bytes: [UInt8]) -> STUNMessage? {
        decodeWithOffsets(bytes)?.message
    }

    static func decodeWithOffsets(_ bytes: [UInt8]) -> (message: STUNMessage, offsets: [(type: UInt16, offset: Int)])? {
        guard isSTUN(bytes) else { return nil }
        let length = Int(be16(bytes, 2))
        guard length % 4 == 0, 20 + length == bytes.count else { return nil }
        var message = STUNMessage(.bindingRequest, transactionID: Array(bytes[8..<20]))
        message.type = be16(bytes, 0)
        var offsets: [(UInt16, Int)] = []
        var index = 20
        while index + 4 <= bytes.count {
            let type = be16(bytes, index), size = Int(be16(bytes, index + 2))
            guard index + 4 + size <= bytes.count else { return nil }
            offsets.append((type, index))
            if type != AttributeType.messageIntegrity.rawValue, type != AttributeType.fingerprint.rawValue {
                message.attributes.append(Attribute(type: type, value: Array(bytes[(index + 4)..<(index + 4 + size)])))
            }
            index += 4 + size + (4 - size % 4) % 4
        }
        guard index == bytes.count else { return nil }
        return (message, offsets)
    }

    /// Whether MESSAGE-INTEGRITY holds under `key` (computed over the bytes before it, the length adjusted to end with
    /// it, as RFC 5389 section 15.4 says).
    public static func verifyIntegrity(_ bytes: [UInt8], key: [UInt8]) -> Bool {
        guard let decoded = decodeWithOffsets(bytes),
              let offset = decoded.offsets.first(where: { $0.type == AttributeType.messageIntegrity.rawValue })?.offset,
              offset + 24 <= bytes.count else { return false }
        var covered = Array(bytes[0..<offset])
        let length = UInt16(offset - 20 + 24)
        covered[2] = UInt8(length >> 8)
        covered[3] = UInt8(length & 0xff)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: covered, using: SymmetricKey(data: key))
        return Secrets.constantTimeEqual(Array(mac), Array(bytes[(offset + 4)..<(offset + 24)]))
    }

    /// Whether FINGERPRINT, when present, holds; true without one.
    public static func verifyFingerprint(_ bytes: [UInt8]) -> Bool {
        guard let decoded = decodeWithOffsets(bytes) else { return false }
        guard let offset = decoded.offsets.first(where: { $0.type == AttributeType.fingerprint.rawValue })?.offset else { return true }
        guard offset + 8 == bytes.count else { return false }
        return CRC32.checksum(Array(bytes[0..<offset])) ^ fingerprintXOR == be32(bytes, offset + 4)
    }

    // MARK: Attribute values

    /// XOR-MAPPED-ADDRESS's value for an address and port (RFC 5389 section 15.2).
    public static func xorAddress(host: String, port: Int, transactionID: [UInt8]) -> [UInt8]? {
        let xport = UInt16(port) ^ UInt16(magicCookie >> 16)
        if let v4 = IPAddress.v4(host) {
            let cookie = be32(magicCookie)
            return [0, 0x01] + be16(xport) + zip(v4, cookie).map { $0 ^ $1 }
        }
        if let v6 = IPAddress.v6(host) {
            let mask = be32(magicCookie) + transactionID
            return [0, 0x02] + be16(xport) + zip(v6, mask).map { $0 ^ $1 }
        }
        return nil
    }

    /// The address and port an XOR-MAPPED-ADDRESS carries.
    public static func address(fromXOR value: [UInt8], transactionID: [UInt8]) -> (host: String, port: Int)? {
        guard value.count >= 8 else { return nil }
        let port = Int(be16(value, 2) ^ UInt16(magicCookie >> 16))
        switch value[1] {
        case 0x01:
            let bytes = zip(value[4..<8], be32(magicCookie)).map { $0 ^ $1 }
            return (bytes.map(String.init).joined(separator: "."), port)
        case 0x02 where value.count >= 20:
            let bytes = zip(value[4..<20], be32(magicCookie) + transactionID).map { $0 ^ $1 }
            return (IPAddress.v6String(bytes), port)
        default:
            return nil
        }
    }

    public static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
    public static func be32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xff) } }
    public static func be64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> (56 - 8 * UInt64($0))) & 0xff) } }
    static func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
    static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}

/// CRC-32 (ISO-HDLC, the one zlib computes), for STUN's FINGERPRINT.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Textual IP addresses to bytes and back.
enum IPAddress {
    static func v4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    static func v6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func v6String(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Constant-time comparison (the integrity check), as `Homeswift`'s `Secrets` does; kept here so this target needs only
/// swift-crypto.
enum Secrets {
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
