import Crypto
import Foundation

/// The TLS 1.2 pseudorandom function with SHA-256 (RFC 5246 section 5): P_SHA256(secret, label + seed), cut to
/// `length` bytes. Master secret, key block, Finished and the RFC 5705 exporter all come from it.
enum TLSPRF {
    static func prf(secret: [UInt8], label: String, seed: [UInt8], length: Int) -> [UInt8] {
        pSHA256(secret: secret, seed: Array(label.utf8) + seed, length: length)
    }

    /// A(0) = seed, A(i) = HMAC(secret, A(i-1)); the output is HMAC(secret, A(1) + seed) + HMAC(secret, A(2) + seed) + …
    static func pSHA256(secret: [UInt8], seed: [UInt8], length: Int) -> [UInt8] {
        let key = SymmetricKey(data: secret)
        var output = [UInt8]()
        output.reserveCapacity(length + 32)
        var a = seed
        while output.count < length {
            a = Array(HMAC<SHA256>.authenticationCode(for: a, using: key))
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: a)
            mac.update(data: seed)
            output += Array(mac.finalize())
        }
        return Array(output.prefix(length))
    }
}

/// AES-128-GCM record protection (RFC 5288 with DTLS's sequence number, RFC 6347 section 4.1.2.1): the nonce is the
/// 4-byte implicit salt from the key block and an 8-byte explicit part sent before the ciphertext, which is the
/// record's epoch and sequence number; the additional data is that 8-byte sequence, the content type, the version
/// and the plaintext's length.
struct DTLSRecordCipher: Sendable {
    static let explicitNonceLength = 8
    static let tagLength = 16
    static let overhead = explicitNonceLength + tagLength

    let key: SymmetricKey
    let salt: [UInt8]

    init(key: [UInt8], salt: [UInt8]) {
        self.key = SymmetricKey(data: key)
        self.salt = salt
    }

    static func additionalData(sequence: [UInt8], type: UInt8, version: UInt16, length: Int) -> [UInt8] {
        sequence + [type] + STUNMessage.be16(version) + STUNMessage.be16(UInt16(length))
    }

    /// `sequence` is the record's epoch (2 bytes) and sequence number (6 bytes).
    func seal(_ plaintext: [UInt8], sequence: [UInt8], type: UInt8, version: UInt16) throws -> [UInt8] {
        let nonce = try AES.GCM.Nonce(data: salt + sequence)
        let aad = Self.additionalData(sequence: sequence, type: type, version: version, length: plaintext.count)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return sequence + Array(box.ciphertext) + Array(box.tag)
    }

    func open(_ fragment: [UInt8], sequence: [UInt8], type: UInt8, version: UInt16) throws -> [UInt8] {
        guard fragment.count >= Self.overhead else { throw DTLSError.decryptFailed }
        let explicit = Array(fragment[0..<Self.explicitNonceLength])
        let ciphertext = fragment[Self.explicitNonceLength..<(fragment.count - Self.tagLength)]
        let tag = fragment.suffix(Self.tagLength)
        let aad = Self.additionalData(sequence: sequence, type: type, version: version, length: ciphertext.count)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: salt + explicit), ciphertext: ciphertext, tag: tag)
            return Array(try AES.GCM.open(box, using: key, authenticating: aad))
        } catch {
            throw DTLSError.decryptFailed
        }
    }
}

/// The SRTP keying material a DTLS-SRTP handshake exports (RFC 5764 section 4.2): the RFC 5705 exporter with the label
/// "EXTRACTOR-dtls_srtp", no context, 60 bytes for SRTP_AES128_CM_HMAC_SHA1_80, laid out as client key, server key,
/// client salt, server salt. `local` protects what this side sends, `remote` unprotects what it receives.
public struct SRTPKeys: Sendable, CustomStringConvertible {
    public static let exporterLabel = "EXTRACTOR-dtls_srtp"
    public static let length = 2 * (SRTPContext.masterKeyLength + SRTPContext.masterSaltLength)

    public let localMasterKey: [UInt8]
    public let localMasterSalt: [UInt8]
    public let remoteMasterKey: [UInt8]
    public let remoteMasterSalt: [UInt8]
    /// The exporter's 60 bytes as they came out (for interoperability checks; never log them).
    let material: [UInt8]

    init(material: [UInt8], role: DTLSRole) {
        let keyLength = SRTPContext.masterKeyLength, saltLength = SRTPContext.masterSaltLength
        let clientKey = Array(material[0..<keyLength])
        let serverKey = Array(material[keyLength..<(2 * keyLength)])
        let clientSalt = Array(material[(2 * keyLength)..<(2 * keyLength + saltLength)])
        let serverSalt = Array(material[(2 * keyLength + saltLength)..<(2 * keyLength + 2 * saltLength)])
        self.material = material
        switch role {
        case .client:
            (localMasterKey, localMasterSalt, remoteMasterKey, remoteMasterSalt) = (clientKey, clientSalt, serverKey, serverSalt)
        case .server:
            (localMasterKey, localMasterSalt, remoteMasterKey, remoteMasterSalt) = (serverKey, serverSalt, clientKey, clientSalt)
        }
    }

    /// The context that protects this side's RTP and RTCP.
    public func sendingContext() throws -> SRTPContext { try SRTPContext(masterKey: localMasterKey, masterSalt: localMasterSalt) }

    /// The context that unprotects the peer's.
    public func receivingContext() throws -> SRTPContext { try SRTPContext(masterKey: remoteMasterKey, masterSalt: remoteMasterSalt) }

    /// Sizes only: the keys never reach a log.
    public var description: String { "SRTPKeys(\(material.count) bytes)" }
}
