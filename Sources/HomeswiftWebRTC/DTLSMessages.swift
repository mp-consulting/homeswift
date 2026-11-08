import Foundation

/// Which end of the handshake this side is: with `a=setup:actpass` offered, the answerer picks; `active` is the client.
public enum DTLSRole: Sendable, Equatable {
    case client
    case server
}

public enum DTLSError: Error, Equatable, CustomStringConvertible {
    case timeout
    case closed
    case notConnected
    case decodeError
    case decryptFailed
    case badCertificate
    case unsupportedCertificate
    case fingerprintMismatch
    case badSignature
    case badFinished
    case noSharedCipherSuite
    case noSRTPProfile
    case missingCertificate
    case recordTooLarge
    case alert(level: UInt8, description: UInt8)
    case unexpectedMessage(UInt8)

    public var description: String {
        switch self {
        case .timeout: "the DTLS handshake timed out"
        case .closed: "the DTLS transport is closed"
        case .notConnected: "the DTLS handshake has not completed"
        case .decodeError: "a DTLS message could not be read"
        case .decryptFailed: "a DTLS record did not decrypt"
        case .badCertificate: "the peer's certificate could not be read"
        case .unsupportedCertificate: "the peer's certificate has a key that is neither P-256 nor RSA"
        case .fingerprintMismatch: "the peer's certificate does not match the fingerprint in its SDP"
        case .badSignature: "the peer's handshake signature does not verify"
        case .badFinished: "the peer's Finished message does not match the handshake"
        case .noSharedCipherSuite: "the peer offers no cipher suite this side speaks"
        case .noSRTPProfile: "the peer does not negotiate SRTP_AES128_CM_HMAC_SHA1_80"
        case .missingCertificate: "the peer sent no certificate"
        case .recordTooLarge: "the data is more than a DTLS record carries (16384 bytes)"
        case .alert(let level, let description): "the peer sent alert \(description) (level \(level))"
        case .unexpectedMessage(let type): "unexpected DTLS handshake message \(type)"
        }
    }
}

enum DTLSConstants {
    static let version: UInt16 = 0xfefd  // DTLS 1.2
    static let version10: UInt16 = 0xfeff  // DTLS 1.0, for HelloVerifyRequest (RFC 6347 section 4.2.1)

    static let ecdheECDSAAES128GCMSHA256: UInt16 = 0xc02b
    static let ecdheRSAAES128GCMSHA256: UInt16 = 0xc02f

    static let ecdsaP256SHA256: UInt16 = 0x0403
    static let rsaPSSRSAESHA256: UInt16 = 0x0804
    static let rsaPKCS1SHA256: UInt16 = 0x0401
    static let signatureSchemes: [UInt16] = [ecdsaP256SHA256, rsaPSSRSAESHA256, rsaPKCS1SHA256]

    static let secp256r1: UInt16 = 23
    static let srtpAES128CMSHA1_80: UInt16 = 0x0001

    enum Extension {
        static let supportedGroups: UInt16 = 10
        static let ecPointFormats: UInt16 = 11
        static let signatureAlgorithms: UInt16 = 13
        static let useSRTP: UInt16 = 14
        static let extendedMasterSecret: UInt16 = 23
        static let renegotiationInfo: UInt16 = 0xff01
    }

    enum ContentType {
        static let changeCipherSpec: UInt8 = 20
        static let alert: UInt8 = 21
        static let handshake: UInt8 = 22
        static let applicationData: UInt8 = 23
    }

    enum HandshakeType {
        static let clientHello: UInt8 = 1
        static let serverHello: UInt8 = 2
        static let helloVerifyRequest: UInt8 = 3
        static let certificate: UInt8 = 11
        static let serverKeyExchange: UInt8 = 12
        static let certificateRequest: UInt8 = 13
        static let serverHelloDone: UInt8 = 14
        static let certificateVerify: UInt8 = 15
        static let clientKeyExchange: UInt8 = 16
        static let finished: UInt8 = 20
    }

    enum Alert {
        static let closeNotify: UInt8 = 0
        static let unexpectedMessage: UInt8 = 10
        static let badRecordMAC: UInt8 = 20
        static let handshakeFailure: UInt8 = 40
        static let badCertificate: UInt8 = 42
        static let decryptError: UInt8 = 51
        static let decodeError: UInt8 = 50
    }

    static let recordHeaderLength = 13
    /// TLS's largest plaintext in a record (RFC 5246 section 6.2.1).
    static let maximumPlaintextLength = 16384
    static let handshakeHeaderLength = 12
}

/// Big-endian writes with TLS's length-prefixed vectors.
struct TLSWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += STUNMessage.be16(value) }
    mutating func u24(_ value: Int) { bytes += [UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)] }
    mutating func u48(_ value: UInt64) { bytes += STUNMessage.be64(value).suffix(6) }
    mutating func raw(_ value: [UInt8]) { bytes += value }
    mutating func vector8(_ value: [UInt8]) { u8(UInt8(value.count)); raw(value) }
    mutating func vector16(_ value: [UInt8]) { u16(UInt16(value.count)); raw(value) }
    mutating func vector24(_ value: [UInt8]) { u24(value.count); raw(value) }
    /// A list of 16-bit values in a vector16 (cipher suites, groups, signature schemes, SRTP profiles).
    mutating func u16Vector(_ values: [UInt16]) {
        u16(UInt16(values.count * 2))
        for value in values { u16(value) }
    }
}

/// Big-endian reads that fail with `decodeError` past the end.
struct TLSReader {
    let bytes: [UInt8]
    var index: Int

    init(_ bytes: [UInt8], at index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    var remaining: Int { bytes.count - index }
    var isAtEnd: Bool { index >= bytes.count }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index + count <= bytes.count else { throw DTLSError.decodeError }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    mutating func u24() throws -> Int { let b = try take(3); return Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2]) }
    mutating func u48() throws -> UInt64 { try take(6).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func vector8() throws -> [UInt8] { try take(Int(try u8())) }
    mutating func vector16() throws -> [UInt8] { try take(Int(try u16())) }
    mutating func vector24() throws -> [UInt8] { try take(try u24()) }
    /// A vector16 read as 16-bit values; an odd length is a decode error.
    mutating func u16List() throws -> [UInt16] {
        var list = TLSReader(try vector16())
        var values: [UInt16] = []
        while !list.isAtEnd { values.append(try list.u16()) }
        return values
    }
}

/// One DTLS record (RFC 6347 section 4.1): type, version, epoch, 48-bit sequence number, fragment.
struct DTLSRecord: Equatable {
    var type: UInt8
    var version: UInt16
    var epoch: UInt16
    var sequence: UInt64
    var fragment: [UInt8]

    /// Epoch and sequence number as the 8 bytes the AEAD's nonce and additional data use.
    var sequenceBytes: [UInt8] { STUNMessage.be16(epoch) + Array(STUNMessage.be64(sequence).suffix(6)) }

    func encode() -> [UInt8] {
        var writer = TLSWriter()
        writer.u8(type)
        writer.u16(version)
        writer.u16(epoch)
        writer.u48(sequence)
        writer.vector16(fragment)
        return writer.bytes
    }

    /// Every record in a datagram; a truncated one ends the list.
    static func decodeAll(_ datagram: [UInt8]) -> [DTLSRecord] {
        var reader = TLSReader(datagram)
        var records: [DTLSRecord] = []
        while reader.remaining >= DTLSConstants.recordHeaderLength {
            guard let type = try? reader.u8(), let version = try? reader.u16(), let epoch = try? reader.u16(),
                  let sequence = try? reader.u48(), let fragment = try? reader.vector16() else { break }
            records.append(DTLSRecord(type: type, version: version, epoch: epoch, sequence: sequence, fragment: fragment))
        }
        return records
    }
}

/// A handshake message's fragment as it travels (RFC 6347 section 4.2.2).
struct HandshakeFragment: Equatable {
    var type: UInt8
    var length: Int
    var messageSeq: UInt16
    var offset: Int
    var body: [UInt8]

    func encode() -> [UInt8] {
        var writer = TLSWriter()
        writer.u8(type)
        writer.u24(length)
        writer.u16(messageSeq)
        writer.u24(offset)
        writer.vector24(body)
        return writer.bytes
    }

    /// Every fragment in a handshake record's plaintext.
    static func decodeAll(_ bytes: [UInt8]) throws -> [HandshakeFragment] {
        var reader = TLSReader(bytes)
        var fragments: [HandshakeFragment] = []
        while !reader.isAtEnd {
            let type = try reader.u8(), length = try reader.u24(), seq = try reader.u16(), offset = try reader.u24()
            let body = try reader.vector24()
            guard offset + body.count <= length else { throw DTLSError.decodeError }
            fragments.append(HandshakeFragment(type: type, length: length, messageSeq: seq, offset: offset, body: body))
        }
        return fragments
    }
}

/// A whole handshake message.
struct HandshakeMessage: Equatable {
    var type: UInt8
    var messageSeq: UInt16
    var body: [UInt8]

    /// The message as the transcript hashes it: its header as if unfragmented, then the body (RFC 6347 section 4.2.6).
    var transcriptBytes: [UInt8] {
        HandshakeFragment(type: type, length: body.count, messageSeq: messageSeq, offset: 0, body: body).encode()
    }

    /// Fragments of at most `maximum` body bytes each.
    func fragments(maximum: Int) -> [HandshakeFragment] {
        let size = max(1, maximum)
        guard !body.isEmpty else { return [HandshakeFragment(type: type, length: 0, messageSeq: messageSeq, offset: 0, body: [])] }
        return stride(from: 0, to: body.count, by: size).map { offset in
            HandshakeFragment(type: type, length: body.count, messageSeq: messageSeq, offset: offset,
                              body: Array(body[offset..<min(body.count, offset + size)]))
        }
    }
}

/// Puts fragments back into messages, keyed by message_seq, whatever order and overlap they come in.
struct HandshakeReassembler {
    private struct Partial {
        var type: UInt8
        var body: [UInt8]
        var have: [Bool]
        var missing: Int
    }

    private var partials: [UInt16: Partial] = [:]
    private static let maximumLength = 1 << 16

    /// Adds a fragment; false when it contradicts what came before (another type or length for the same message).
    @discardableResult
    mutating func add(_ fragment: HandshakeFragment) -> Bool {
        guard fragment.length <= Self.maximumLength else { return false }
        var partial = partials[fragment.messageSeq]
            ?? Partial(type: fragment.type, body: [UInt8](repeating: 0, count: fragment.length), have: [Bool](repeating: false, count: fragment.length), missing: fragment.length)
        guard partial.type == fragment.type, partial.body.count == fragment.length else { return false }
        for (index, byte) in fragment.body.enumerated() where !partial.have[fragment.offset + index] {
            partial.have[fragment.offset + index] = true
            partial.body[fragment.offset + index] = byte
            partial.missing -= 1
        }
        partials[fragment.messageSeq] = partial
        return true
    }

    /// The whole message with this sequence number, removed, once every byte arrived.
    mutating func take(_ messageSeq: UInt16) -> HandshakeMessage? {
        guard let partial = partials[messageSeq], partial.missing == 0 else { return nil }
        partials[messageSeq] = nil
        return HandshakeMessage(type: partial.type, messageSeq: messageSeq, body: partial.body)
    }

    /// The lowest-numbered message that is whole, of `type` (a server waiting for any ClientHello).
    mutating func takeFirstComplete(type: UInt8) -> HandshakeMessage? {
        guard let seq = partials.filter({ $0.value.type == type && $0.value.missing == 0 }).keys.min() else { return nil }
        return take(seq)
    }

    mutating func discard(below messageSeq: UInt16) {
        partials = partials.filter { $0.key >= messageSeq }
    }

    mutating func removeAll() { partials = [:] }
}

/// A TLS extension list.
struct TLSExtensions {
    var entries: [(type: UInt16, data: [UInt8])] = []

    init(_ entries: [(type: UInt16, data: [UInt8])] = []) { self.entries = entries }

    init(reading reader: inout TLSReader) throws {
        guard !reader.isAtEnd else { return }
        var list = TLSReader(try reader.vector16())
        while !list.isAtEnd { entries.append((try list.u16(), try list.vector16())) }
    }

    subscript(type: UInt16) -> [UInt8]? { entries.first { $0.type == type }?.data }

    func encode() -> [UInt8] {
        var list = TLSWriter()
        for entry in entries {
            list.u16(entry.type)
            list.vector16(entry.data)
        }
        var writer = TLSWriter()
        writer.vector16(list.bytes)
        return writer.bytes
    }

    /// use_srtp's profiles (RFC 5764 section 4.1.1).
    static func srtpProfiles(_ data: [UInt8]) throws -> [UInt16] {
        var reader = TLSReader(data)
        let profiles = try reader.u16List()
        _ = try reader.vector8()  // srtp_mki
        return profiles
    }

    static func useSRTP(_ profiles: [UInt16]) -> [UInt8] {
        var writer = TLSWriter()
        writer.u16Vector(profiles)
        writer.vector8([])
        return writer.bytes
    }

    /// An extension that is one vector16 of 16-bit values (supported_groups, signature_algorithms).
    static func u16List(_ data: [UInt8]) throws -> [UInt16] {
        var reader = TLSReader(data)
        return try reader.u16List()
    }

    static func u16Vector(_ values: [UInt16]) -> [UInt8] {
        var writer = TLSWriter()
        writer.u16Vector(values)
        return writer.bytes
    }
}

/// ClientHello's fields (RFC 6347 section 4.2.1 adds the cookie).
struct ClientHello {
    var version: UInt16 = DTLSConstants.version
    var random: [UInt8]
    var sessionID: [UInt8] = []
    var cookie: [UInt8] = []
    var cipherSuites: [UInt16]
    var compressionMethods: [UInt8] = [0]
    var extensions: TLSExtensions

    func encode() -> [UInt8] {
        var writer = TLSWriter()
        writer.u16(version)
        writer.raw(random)
        writer.vector8(sessionID)
        writer.vector8(cookie)
        writer.u16Vector(cipherSuites)
        writer.vector8(compressionMethods)
        writer.raw(extensions.encode())
        return writer.bytes
    }

    init(random: [UInt8], cookie: [UInt8] = [], cipherSuites: [UInt16], extensions: TLSExtensions) {
        self.random = random
        self.cookie = cookie
        self.cipherSuites = cipherSuites
        self.extensions = extensions
    }

    init(_ body: [UInt8]) throws {
        var reader = TLSReader(body)
        version = try reader.u16()
        random = try reader.take(32)
        sessionID = try reader.vector8()
        cookie = try reader.vector8()
        cipherSuites = try reader.u16List()
        compressionMethods = try reader.vector8()
        extensions = try TLSExtensions(reading: &reader)
    }

    /// The fields a stateless cookie covers: everything but the cookie itself.
    var cookieInput: [UInt8] {
        var copy = self
        copy.cookie = []
        return copy.encode()
    }
}

struct ServerHello {
    var version: UInt16 = DTLSConstants.version
    var random: [UInt8]
    var sessionID: [UInt8] = []
    var cipherSuite: UInt16
    var compressionMethod: UInt8 = 0
    var extensions: TLSExtensions

    init(random: [UInt8], cipherSuite: UInt16, extensions: TLSExtensions) {
        self.random = random
        self.cipherSuite = cipherSuite
        self.extensions = extensions
    }

    init(_ body: [UInt8]) throws {
        var reader = TLSReader(body)
        version = try reader.u16()
        random = try reader.take(32)
        sessionID = try reader.vector8()
        cipherSuite = try reader.u16()
        compressionMethod = try reader.u8()
        extensions = try TLSExtensions(reading: &reader)
    }

    func encode() -> [UInt8] {
        var writer = TLSWriter()
        writer.u16(version)
        writer.raw(random)
        writer.vector8(sessionID)
        writer.u16(cipherSuite)
        writer.u8(compressionMethod)
        writer.raw(extensions.encode())
        return writer.bytes
    }
}
