import Crypto
import Foundation

/// The encrypted framing used after pair verify.
///
/// Each frame is a two-byte little-endian length (at most 1024), the ChaCha20-Poly1305 ciphertext,
/// and a 16-byte tag. The length bytes are the additional authenticated data, and each direction
/// counts its frames for the nonce.
struct SecureSession {
    static let maxFrame = 1024

    private let readKey: SymmetricKey
    private let writeKey: SymmetricKey
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    /// Keys for the accessory side, derived from the pair-verify shared secret.
    init(sharedSecret: Data, isAccessory: Bool = true) {
        let accessoryToController = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        let controllerToAccessory = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        readKey = isAccessory ? controllerToAccessory : accessoryToController
        writeKey = isAccessory ? accessoryToController : controllerToAccessory
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        var out = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: Self.maxFrame, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let chunk = plaintext[offset..<end]
            let length = UInt16(chunk.count)
            let aad = Data([UInt8(length & 0xFF), UInt8(length >> 8)])
            let sealed = try HAPCrypto.seal(Data(chunk), key: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), aad: aad)
            writeCounter += 1
            out.append(aad)
            out.append(sealed)
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    /// Decrypts every complete frame at the front of `buffer` and leaves any partial frame in place.
    mutating func decrypt(_ buffer: inout Data) throws -> Data {
        var out = Data()
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
            guard length <= Self.maxFrame else { throw TLVError.authentication }
            let total = 2 + length + 16
            guard buffer.count >= total else { break }
            let aad = Data(buffer[start..<start + 2])
            let sealed = Data(buffer[start + 2..<start + total])
            out.append(try HAPCrypto.open(sealed, key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: aad))
            readCounter += 1
            buffer = Data(buffer[(start + total)...])
        }
        return out
    }
}
