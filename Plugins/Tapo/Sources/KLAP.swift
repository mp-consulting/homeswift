import Crypto
import Foundation
import _CryptoExtras

/// KLAP, the local protocol of current Tapo firmware (docs/clean-room/Tapo.md, 4.2): two handshakes prove that both
/// sides know the account's credentials, then each request is AES-128-CBC with an IV made of a prefix and a sequence
/// number, signed with SHA-256.
enum KLAP {
    /// SHA-256(SHA-1(username) || SHA-1(password)), each NFKC-normalised and UTF-8 encoded first.
    static func authHash(username: String, password: String) -> Data {
        let user = Data(Insecure.SHA1.hash(data: Data(username.precomposedStringWithCompatibilityMapping.utf8)))
        let pass = Data(Insecure.SHA1.hash(data: Data(password.precomposedStringWithCompatibilityMapping.utf8)))
        return sha256(user + pass)
    }

    /// What the device answers in handshake1 after its seed when it knows the same credentials.
    static func serverHash(localSeed: Data, remoteSeed: Data, authHash: Data) -> Data {
        sha256(localSeed + remoteSeed + authHash)
    }

    /// The body of handshake2.
    static func clientHash(localSeed: Data, remoteSeed: Data, authHash: Data) -> Data {
        sha256(remoteSeed + localSeed + authHash)
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// The keys of one session, and its sequence number.
    struct Session: Sendable {
        let key: SymmetricKey
        let ivPrefix: Data
        let signatureKey: Data
        /// The last sequence number used; the next request uses one more, wrapping within a signed 32-bit integer.
        private(set) var sequence: Int32

        init(localSeed: Data, remoteSeed: Data, authHash: Data) {
            let seeds = localSeed + remoteSeed + authHash
            key = SymmetricKey(data: KLAP.sha256(Data("lsk".utf8) + seeds).prefix(16))
            let ivHash = KLAP.sha256(Data("iv".utf8) + seeds)
            ivPrefix = Data(ivHash.prefix(12))
            sequence = Int32(bigEndianBytes: ivHash.suffix(4))
            signatureKey = Data(KLAP.sha256(Data("ldk".utf8) + seeds).prefix(28))
        }

        func iv(sequence: Int32) -> Data { ivPrefix + sequence.bigEndianBytes }

        /// The next request: its sequence number and its body (signature, then ciphertext).
        mutating func encrypt(_ plaintext: Data) throws -> (sequence: Int32, body: Data) {
            sequence = sequence &+ 1
            let ciphertext = try AES._CBC.encrypt(plaintext, using: key, iv: AES._CBC.IV(ivBytes: iv(sequence: sequence)))
            let signature = KLAP.sha256(signatureKey + sequence.bigEndianBytes + ciphertext)
            return (sequence, signature + ciphertext)
        }

        /// A response's plaintext: the 32 bytes of signature skipped (they are not checked, as other clients do not),
        /// the rest decrypted with the request's IV.
        func decrypt(_ body: Data, sequence: Int32) throws -> Data {
            guard body.count > 32, (body.count - 32) % 16 == 0 else { throw TapoError.invalidResponse("a KLAP response of \(body.count) bytes") }
            return try AES._CBC.decrypt(body.dropFirst(32), using: key, iv: AES._CBC.IV(ivBytes: iv(sequence: sequence)))
        }
    }
}

extension Int32 {
    init(bigEndianBytes bytes: some Collection<UInt8>) {
        self = Int32(bitPattern: bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    var bigEndianBytes: Data {
        let value = UInt32(bitPattern: self)
        return Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
