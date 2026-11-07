import Crypto
import CryptoExtras
import Foundation

/// SRTP and SRTCP with AES_CM_128_HMAC_SHA1_80 (RFC 3711), the profile DTLS-SRTP negotiates with WebRTC peers
/// (`SRTP_AES128_CM_SHA1_80`). One context protects or unprotects one direction: its master key and salt are the
/// ones the DTLS handshake exports for that side. Checked against RFC 3711's appendix B and libsrtp's reference
/// packets.
public struct SRTPContext: Sendable {
    public static let masterKeyLength = 16
    public static let masterSaltLength = 14
    static let tagLength = 10

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badKey
        case tooShort
        case authentication

        public var description: String {
            switch self {
            case .badKey: "SRTP needs a 16-byte master key and a 14-byte master salt"
            case .tooShort: "the packet is too short for SRTP"
            case .authentication: "the packet's SRTP authentication tag does not match"
            }
        }
    }

    struct SessionKeys: Sendable {
        var cipher: SymmetricKey
        var salt: [UInt8]
        var auth: SymmetricKey
    }

    let rtp: SessionKeys
    let rtcp: SessionKeys
    /// The rollover counter and highest sequence number per SSRC (RFC 3711 section 3.3.1).
    private var rollover: [UInt32: (roc: UInt32, highest: UInt16)] = [:]
    /// The next SRTCP index this side sends.
    private var rtcpIndex: UInt32 = 0

    public init(masterKey: [UInt8], masterSalt: [UInt8]) throws {
        guard masterKey.count == Self.masterKeyLength, masterSalt.count == Self.masterSaltLength else { throw Failure.badKey }
        let key = SymmetricKey(data: masterKey)
        func derive(_ label: UInt8, _ length: Int) throws -> [UInt8] { try Self.prf(key: key, salt: masterSalt, label: label, length: length) }
        rtp = SessionKeys(cipher: SymmetricKey(data: try derive(0, 16)), salt: try derive(2, 14), auth: SymmetricKey(data: try derive(1, 20)))
        rtcp = SessionKeys(cipher: SymmetricKey(data: try derive(3, 16)), salt: try derive(5, 14), auth: SymmetricKey(data: try derive(4, 20)))
    }

    /// The key derivation of RFC 3711 section 4.3 with a key derivation rate of 0: AES-CM under the master key over
    /// (master salt XOR label at byte 7) times 2^16.
    static func prf(key: SymmetricKey, salt: [UInt8], label: UInt8, length: Int) throws -> [UInt8] {
        var x = salt
        x[7] ^= label
        return try keystream(key: key, iv: x + [0, 0], count: length)
    }

    /// AES in counter mode from `iv`, the counter in its last two bytes and above, as RFC 3711 section 4.1.1 counts.
    static func keystream(key: SymmetricKey, iv: [UInt8], count: Int) throws -> [UInt8] {
        let zeros = [UInt8](repeating: 0, count: count)
        return Array(try AES._CTR.encrypt(zeros, using: key, nonce: try AES._CTR.Nonce(nonceBytes: iv)))
    }

    /// IV = (salt * 2^16) XOR (SSRC * 2^64) XOR (index * 2^16), as 16 bytes.
    static func iv(salt: [UInt8], ssrc: UInt32, index: UInt64) -> [UInt8] {
        var iv = salt + [0, 0]
        let ssrcBytes = STUNMessage.be32(ssrc)
        for offset in 0..<4 { iv[4 + offset] ^= ssrcBytes[offset] }
        let indexBytes = STUNMessage.be64(index << 16)
        for offset in 0..<8 { iv[8 + offset] ^= indexBytes[offset] }
        return iv
    }

    // MARK: RTP

    /// The RTP header's length: 12 bytes, the CSRCs, and an extension when the X bit says so.
    static func headerLength(_ packet: [UInt8]) -> Int? {
        guard packet.count >= 12 else { return nil }
        var length = 12 + 4 * Int(packet[0] & 0x0f)
        if packet[0] & 0x10 != 0 {
            guard packet.count >= length + 4 else { return nil }
            length += 4 + 4 * Int(STUNMessage.be16(packet, length + 2))
        }
        return length <= packet.count ? length : nil
    }

    /// Encrypts an RTP packet and appends its tag.
    public mutating func protect(rtp packet: [UInt8]) throws -> [UInt8] {
        guard let header = Self.headerLength(packet) else { throw Failure.tooShort }
        let ssrc = STUNMessage.be32(packet, 8), sequence = STUNMessage.be16(packet, 2)
        let roc = sendRollover(ssrc: ssrc, sequence: sequence)
        let index = UInt64(roc) << 16 | UInt64(sequence)
        var out = Array(packet[0..<header])
        out += try encrypt(Array(packet[header...]), keys: rtp, ssrc: ssrc, index: index)
        out += tag(out + STUNMessage.be32(roc), key: rtp.auth)
        return out
    }

    /// Checks an SRTP packet's tag and decrypts it.
    public mutating func unprotect(rtp packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 12 + Self.tagLength else { throw Failure.tooShort }
        let body = Array(packet[0..<(packet.count - Self.tagLength)])
        guard let header = Self.headerLength(body) else { throw Failure.tooShort }
        let ssrc = STUNMessage.be32(body, 8), sequence = STUNMessage.be16(body, 2)
        let roc = estimateRollover(ssrc: ssrc, sequence: sequence)
        let expected = tag(body + STUNMessage.be32(roc), key: rtp.auth)
        guard Secrets.constantTimeEqual(expected, Array(packet.suffix(Self.tagLength))) else { throw Failure.authentication }
        accept(ssrc: ssrc, sequence: sequence, roc: roc)
        let index = UInt64(roc) << 16 | UInt64(sequence)
        return Array(body[0..<header]) + (try encrypt(Array(body[header...]), keys: rtp, ssrc: ssrc, index: index))
    }

    private func encrypt(_ payload: [UInt8], keys: SessionKeys, ssrc: UInt32, index: UInt64) throws -> [UInt8] {
        guard !payload.isEmpty else { return [] }
        let stream = try Self.keystream(key: keys.cipher, iv: Self.iv(salt: keys.salt, ssrc: ssrc, index: index), count: payload.count)
        return zip(payload, stream).map { $0 ^ $1 }
    }

    private func tag(_ bytes: [UInt8], key: SymmetricKey) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: bytes, using: key).prefix(Self.tagLength))
    }

    /// The sender's rollover counter: it grows when the sequence number wraps.
    private mutating func sendRollover(ssrc: UInt32, sequence: UInt16) -> UInt32 {
        guard let state = rollover[ssrc] else {
            rollover[ssrc] = (0, sequence)
            return 0
        }
        var roc = state.roc
        if sequence < state.highest, state.highest - sequence > 0x8000 { roc &+= 1 }
        if roc != state.roc || sequence > state.highest { rollover[ssrc] = (roc, sequence) }
        return roc
    }

    /// The receiver's guess of the sender's rollover counter (RFC 3711 appendix A).
    private func estimateRollover(ssrc: UInt32, sequence: UInt16) -> UInt32 {
        guard let state = rollover[ssrc] else { return 0 }
        let s = Int(sequence), high = Int(state.highest)
        if high < 0x8000 {
            return s - high > 0x8000 && state.roc > 0 ? state.roc - 1 : state.roc
        }
        return high - 0x8000 > s ? state.roc &+ 1 : state.roc
    }

    private mutating func accept(ssrc: UInt32, sequence: UInt16, roc: UInt32) {
        guard let state = rollover[ssrc] else {
            rollover[ssrc] = (roc, sequence)
            return
        }
        if roc > state.roc || (roc == state.roc && sequence > state.highest) { rollover[ssrc] = (roc, sequence) }
    }

    // MARK: RTCP

    /// Encrypts an RTCP compound packet past its first eight bytes and appends E||index and the tag.
    public mutating func protect(rtcp packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 8 else { throw Failure.tooShort }
        rtcpIndex = (rtcpIndex + 1) & 0x7FFF_FFFF
        let index = rtcpIndex
        let ssrc = STUNMessage.be32(packet, 4)
        var out = Array(packet[0..<8])
        out += try encrypt(Array(packet[8...]), keys: rtcp, ssrc: ssrc, index: UInt64(index))
        out += STUNMessage.be32(0x8000_0000 | index)
        out += tag(out, key: rtcp.auth)
        return out
    }

    /// Checks an SRTCP packet's tag and decrypts it when its E flag says it is encrypted.
    public func unprotect(rtcp packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 8 + 4 + Self.tagLength else { throw Failure.tooShort }
        let authenticated = Array(packet[0..<(packet.count - Self.tagLength)])
        guard Secrets.constantTimeEqual(tag(authenticated, key: rtcp.auth), Array(packet.suffix(Self.tagLength))) else {
            throw Failure.authentication
        }
        let word = STUNMessage.be32(authenticated, authenticated.count - 4)
        let body = Array(authenticated[0..<(authenticated.count - 4)])
        guard word & 0x8000_0000 != 0 else { return body }
        let ssrc = STUNMessage.be32(body, 4)
        return Array(body[0..<8]) + (try encrypt(Array(body[8...]), keys: rtcp, ssrc: ssrc, index: UInt64(word & 0x7FFF_FFFF)))
    }
}
