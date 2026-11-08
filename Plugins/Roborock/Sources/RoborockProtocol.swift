import Crypto
import Foundation
import HomeswiftNetwork
import Homeswift
import _CryptoExtras

// The Roborock message layer (docs/clean-room/Roborock.md, section 4): the frame both the cloud's MQTT payloads and the
// local TCP port carry, the payload ciphers of each protocol version, and the UDP discovery packet. Integers are
// big-endian; the test vectors of section 11 check every byte.

/// The protocol version a device speaks, the first 3 bytes of each frame.
enum RoborockVersion: String, Sendable, CaseIterable {
    case v1 = "1.0"
    case a01 = "A01"
    case b01 = "B01"
    case l01 = "L01"

    /// The other spelling of B01 some devices send.
    static let b01Binary: [UInt8] = [0x81, 0x53, 0x19]

    var bytes: [UInt8] { Array(rawValue.utf8) }

    init?(bytes: some Collection<UInt8>) {
        let bytes = Array(bytes)
        if bytes == Self.b01Binary {
            self = .b01
        } else if let version = Self.allCases.first(where: { $0.bytes == bytes }) {
            self = version
        } else {
            return nil
        }
    }

    /// The home data's `pv`: one of the names, or B01's three bytes read as text.
    init?(homeData pv: String?) {
        guard let pv else { return nil }
        if let version = RoborockVersion(rawValue: pv) { self = version } else if Array(pv.utf8) == Self.b01Binary || pv.unicodeScalars.map(\.value) == [0x81, 0x53, 0x19] { self = .b01 } else { return nil }
    }
}

enum RoborockProtocolError: Error, CustomStringConvertible, Equatable {
    case tooShort(Int)
    case unknownVersion
    case badChecksum
    case decryptFailed(String)
    case missingNonces

    var description: String {
        switch self {
        case .tooShort(let length): "frame too short (\(length) bytes)"
        case .unknownVersion: "unknown protocol version"
        case .badChecksum: "CRC32 mismatch"
        case .decryptFailed(let reason): "could not decrypt the payload: \(reason)"
        case .missingNonces: "the L01 handshake has not given its nonces"
        }
    }
}

/// The frame protocols the plugin speaks.
enum RoborockFrameProtocol {
    static let helloRequest: UInt16 = 0
    static let helloResponse: UInt16 = 1
    static let ping: UInt16 = 2
    static let pong: UInt16 = 3
    static let localRequest: UInt16 = 4
    static let cloudRequest: UInt16 = 101
    static let response: UInt16 = 102
    static let mapChunk: UInt16 = 301
    static let photo: UInt16 = 300
    static let deviceEvent: UInt16 = 500

    /// Protocols whose frame is the header alone.
    static func isHeaderOnly(_ value: UInt16) -> Bool { value <= 3 }
}

/// One frame: the header fields and the payload as it is on the wire (encrypted).
struct RoborockFrame: Sendable, Equatable {
    var version: RoborockVersion
    /// The bytes of the version as received (B01 has two spellings); nil writes the version's own.
    var versionBytes: [UInt8]?
    var seq: UInt32
    var random: UInt32
    var timestamp: UInt32
    var protocolNumber: UInt16
    var payload: Data

    init(version: RoborockVersion, versionBytes: [UInt8]? = nil, seq: UInt32, random: UInt32, timestamp: UInt32, protocolNumber: UInt16, payload: Data = Data()) {
        self.version = version
        self.versionBytes = versionBytes
        self.seq = seq
        self.random = random
        self.timestamp = timestamp
        self.protocolNumber = protocolNumber
        self.payload = payload
    }

    /// The frame's bytes with its CRC32: 21 for a header-only protocol (0 to 3), 23 + the payload otherwise.
    func encoded() -> Data {
        var bytes = versionBytes ?? version.bytes
        bytes.reserveCapacity(23 + payload.count)
        Self.append(seq, to: &bytes)
        Self.append(random, to: &bytes)
        Self.append(timestamp, to: &bytes)
        bytes.append(UInt8(protocolNumber >> 8))
        bytes.append(UInt8(protocolNumber & 0xFF))
        if !RoborockFrameProtocol.isHeaderOnly(protocolNumber) {
            bytes.append(UInt8((payload.count >> 8) & 0xFF))
            bytes.append(UInt8(payload.count & 0xFF))
            bytes.append(contentsOf: payload)
        }
        Self.append(CRC32.checksum(bytes), to: &bytes)
        return Data(bytes)
    }

    /// The frame with its 4-byte length in front, as the local port wants it.
    func lengthPrefixed() -> Data {
        let frame = encoded()
        var bytes: [UInt8] = []
        Self.append(UInt32(frame.count), to: &bytes)
        return Data(bytes) + frame
    }

    /// Reads a frame: a header-only one (17 bytes, or 21 with its CRC), or a data frame whose CRC must match.
    static func decode(_ data: Data) throws -> RoborockFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 17 else { throw RoborockProtocolError.tooShort(bytes.count) }
        guard let version = RoborockVersion(bytes: bytes[0..<3]) else { throw RoborockProtocolError.unknownVersion }
        let seq = read32(bytes, 3), random = read32(bytes, 7), timestamp = read32(bytes, 11)
        let number = UInt16(bytes[15]) << 8 | UInt16(bytes[16])
        let versionBytes = Array(bytes[0..<3]) == version.bytes ? nil : Array(bytes[0..<3])
        if bytes.count == 17 || bytes.count == 21 {
            if bytes.count == 21, CRC32.checksum(bytes[0..<17]) != read32(bytes, 17) { throw RoborockProtocolError.badChecksum }
            return RoborockFrame(version: version, versionBytes: versionBytes, seq: seq, random: random, timestamp: timestamp, protocolNumber: number)
        }
        guard bytes.count >= 23 else { throw RoborockProtocolError.tooShort(bytes.count) }
        let length = Int(bytes[17]) << 8 | Int(bytes[18])
        guard bytes.count >= 23 + length else { throw RoborockProtocolError.tooShort(bytes.count) }
        guard CRC32.checksum(bytes[0..<(19 + length)]) == read32(bytes, 19 + length) else { throw RoborockProtocolError.badChecksum }
        return RoborockFrame(
            version: version, versionBytes: versionBytes, seq: seq, random: random, timestamp: timestamp, protocolNumber: number,
            payload: Data(bytes[19..<(19 + length)]))
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}

/// The payload ciphers of each version (section 4.2).
enum RoborockCipher {
    /// The salt of the 1.0 and L01 keys.
    static let salt = "TXdfu$jyZ#TZHsg4"
    static let a01Salt = "726f626f726f636b2d67a6d6da"
    static let b01Salt = "5wwh9ikChRjASpMU8cxg7o1d2E"
    /// The key of the UDP discovery packets.
    static let discoveryKey = "qWKYcdQWrbm9hPqe"

    /// The L01 handshake's nonces of a connection.
    struct Nonces: Sendable, Equatable {
        var connect: UInt32
        var ack: UInt32
    }

    /// The timestamp as 8 lowercase hex digits, reordered h5 h6 h3 h7 h1 h2 h0 h4.
    static func encodeTimestamp(_ timestamp: UInt32) -> String {
        let digits = Array(hex8(timestamp))
        return String([5, 6, 3, 7, 1, 2, 0, 4].map { digits[$0] })
    }

    static func hex8(_ value: UInt32) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }

    static func md5(_ text: String) -> Data { Data(Insecure.MD5.hash(data: Data(text.utf8))) }
    static func md5Hex(_ text: String) -> String { hex(md5(text)) }
    static func hex(_ data: some Sequence<UInt8>) -> String { Secrets.hex(data) }

    /// The 1.0 frame key: MD5 of the encoded timestamp, the local key and the salt.
    static func v1Key(localKey: String, timestamp: UInt32) -> Data {
        md5(encodeTimestamp(timestamp) + localKey + salt)
    }

    static func encrypt(_ plaintext: Data, frame: RoborockFrame, localKey: String, nonces: Nonces?) throws -> Data {
        switch frame.version {
        case .v1:
            return try AESECB.encrypt(plaintext, key: v1Key(localKey: localKey, timestamp: frame.timestamp))
        case .a01, .b01:
            return try AES._CBC.encrypt(plaintext, using: SymmetricKey(data: Data(localKey.utf8)), iv: cbcIV(frame))
        case .l01:
            guard let nonces else { throw RoborockProtocolError.missingNonces }
            let box = try AES.GCM.seal(plaintext, using: l01Key(localKey: localKey, timestamp: frame.timestamp), nonce: l01Nonce(frame), authenticating: l01AAD(frame, nonces))
            return box.ciphertext + box.tag
        }
    }

    static func decrypt(_ payload: Data, frame: RoborockFrame, localKey: String, nonces: Nonces?) throws -> Data {
        do {
            switch frame.version {
            case .v1:
                return try AESECB.decrypt(payload, key: v1Key(localKey: localKey, timestamp: frame.timestamp))
            case .a01, .b01:
                return try AES._CBC.decrypt(payload, using: SymmetricKey(data: Data(localKey.utf8)), iv: cbcIV(frame))
            case .l01:
                guard let nonces else { throw RoborockProtocolError.missingNonces }
                guard payload.count >= 16 else { throw RoborockProtocolError.decryptFailed("payload shorter than its tag") }
                let box = try AES.GCM.SealedBox(nonce: l01Nonce(frame), ciphertext: payload.dropLast(16), tag: payload.suffix(16))
                return try AES.GCM.open(box, using: l01Key(localKey: localKey, timestamp: frame.timestamp), authenticating: l01AAD(frame, nonces))
            }
        } catch let error as RoborockProtocolError {
            throw error
        } catch {
            throw RoborockProtocolError.decryptFailed("\(error)")
        }
    }

    /// A01's IV: characters 8 to 23 of MD5's hex of hex8(random) and A01's salt; B01's: characters 9 to 24 with its own.
    static func cbcIV(_ frame: RoborockFrame) throws -> AES._CBC.IV {
        let (salt, offset) = frame.version == .a01 ? (a01Salt, 8) : (b01Salt, 9)
        let digest = Array(md5Hex(hex8(frame.random) + salt).utf8)
        return try AES._CBC.IV(ivBytes: digest[offset..<(offset + 16)])
    }

    static func l01Key(localKey: String, timestamp: UInt32) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data((encodeTimestamp(timestamp) + localKey + salt).utf8)))
    }

    static func l01Nonce(_ frame: RoborockFrame) throws -> AES.GCM.Nonce {
        var bytes: [UInt8] = []
        RoborockFrame.append(frame.seq, to: &bytes)
        RoborockFrame.append(frame.random, to: &bytes)
        RoborockFrame.append(frame.timestamp, to: &bytes)
        return try AES.GCM.Nonce(data: Array(SHA256.hash(data: bytes)).prefix(12))
    }

    static func l01AAD(_ frame: RoborockFrame, _ nonces: Nonces) -> Data {
        var bytes: [UInt8] = []
        for value in [frame.seq, nonces.connect, nonces.ack, frame.random, frame.timestamp] { RoborockFrame.append(value, to: &bytes) }
        return Data(bytes)
    }

    /// A UDP discovery packet's JSON (section 4.6): version(3) seq(4) protocol(2) length(2) payload CRC(4), the payload
    /// AES-128-ECB under the discovery key, its PKCS#7 padding taken off only when it is valid. The CRC is not checked.
    static func discoveryPayload(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 15 else { return nil }
        let length = Int(bytes[9]) << 8 | Int(bytes[10])
        guard length > 0, length % 16 == 0, bytes.count >= 15 + length else { return nil }
        guard let plain = try? AESECB.decrypt(Data(bytes[11..<(11 + length)]), key: Data(discoveryKey.utf8), padding: false) else { return nil }
        return AESECB.unpadIfValid(plain)
    }
}

/// AES-ECB, which swift-crypto lacks: each 16-byte block on its own, as CBC with a zero IV and no padding.
enum AESECB {
    private static let zero = try! AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16))

    static func encrypt(_ plaintext: Data, key: Data, padding: Bool = true) throws -> Data {
        var bytes = [UInt8](plaintext)
        if padding {
            let pad = 16 - bytes.count % 16
            bytes += [UInt8](repeating: UInt8(pad), count: pad)
        }
        let symmetric = SymmetricKey(data: key)
        var out = Data(capacity: bytes.count)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            out += try AES._CBC.encrypt(bytes[start..<min(start + 16, bytes.count)], using: symmetric, iv: zero, noPadding: true)
        }
        return out
    }

    static func decrypt(_ ciphertext: Data, key: Data, padding: Bool = true) throws -> Data {
        let bytes = [UInt8](ciphertext)
        guard !bytes.isEmpty, bytes.count % 16 == 0 else { throw RoborockProtocolError.decryptFailed("not a whole number of blocks") }
        let symmetric = SymmetricKey(data: key)
        var out = Data(capacity: bytes.count)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            out += try AES._CBC.decrypt(bytes[start..<(start + 16)], using: symmetric, iv: zero, noPadding: true)
        }
        guard padding else { return out }
        guard let pad = out.last, (1...16).contains(pad), out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw RoborockProtocolError.decryptFailed("bad padding")
        }
        return out.dropLast(Int(pad))
    }

    static func unpadIfValid(_ data: Data) -> Data {
        guard let pad = data.last, (1...16).contains(pad), data.count >= Int(pad), data.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return data }
        return Data(data.dropLast(Int(pad)))
    }
}

/// The local port's stream: frames each with a 4-byte length in front, buffered until whole.
struct LengthPrefixedBuffer: Sendable {
    /// A length prefix beyond this is a corrupt stream.
    static let maximumFrame = 8 * 1024 * 1024
    /// More than this buffered is a corrupt stream.
    static let maximumBuffered = 16 * 1024 * 1024

    enum Failure: Error, Equatable { case corrupt }

    private(set) var buffer = Data()

    /// Appends what arrived and answers the whole frames, keeping a partial one. Throws on a corrupt stream, buffer
    /// emptied.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= Self.maximumBuffered else {
            buffer = Data()
            throw Failure.corrupt
        }
        var frames: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            guard length <= Self.maximumFrame else {
                buffer = Data()
                throw Failure.corrupt
            }
            guard buffer.endIndex - offset - 4 >= length else { break }
            frames.append(Data(buffer[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
        buffer = Data(buffer[offset...])
        return frames
    }

    mutating func reset() { buffer = Data() }
}
