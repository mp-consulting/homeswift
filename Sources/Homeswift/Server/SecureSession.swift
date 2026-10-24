import Crypto
import Foundation

/// The encrypted framing used after pair verify.
///
/// Each frame is a two-byte little-endian length (at most 1024), the ChaCha20-Poly1305 ciphertext,
/// and a 16-byte tag. The length bytes are the additional authenticated data, and each direction
/// counts its frames for the nonce.
struct SecureSession {
    static let maxFrame = 1024

    /// The pair-verify shared secret, from which HomeKit Data Stream derives its own keys.
    let sharedSecret: Data
    private let readKey: SymmetricKey
    private let writeKey: SymmetricKey
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    /// Keys for the accessory side, derived from the pair-verify shared secret.
    init(sharedSecret: Data, isAccessory: Bool = true) {
        self.sharedSecret = sharedSecret
        let accessoryToController = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        let controllerToAccessory = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        readKey = isAccessory ? controllerToAccessory : accessoryToController
        writeKey = isAccessory ? accessoryToController : controllerToAccessory
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        let frames = max(1, (plaintext.count + Self.maxFrame - 1) / Self.maxFrame)
        var out = Data(capacity: plaintext.count + frames * 18)
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: Self.maxFrame, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let length = UInt16(end - offset)
            let aad = Data([UInt8(length & 0xFF), UInt8(length >> 8)])
            // Sealed and appended part by part: `HAPCrypto.seal` would join the ciphertext and tag in a copy first.
            let sealed = try ChaChaPoly.seal(plaintext[offset..<end], using: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), authenticating: aad)
            writeCounter += 1
            out.append(aad)
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    /// Decrypts every complete frame at the front of `buffer` and leaves any partial frame in place.
    mutating func decrypt(_ buffer: inout Data) throws -> Data {
        var out = Data()
        var start = buffer.startIndex
        // Frames are read in place; the consumed bytes are dropped once at the end, not after every
        // frame (that copy made large responses quadratic).
        while buffer.endIndex - start >= 2 {
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
            guard length <= Self.maxFrame else { throw TLVError.authentication }
            let total = 2 + length + 16
            guard buffer.endIndex - start >= total else { break }
            let aad = Data(buffer[start..<start + 2])
            out.append(try HAPCrypto.open(buffer[start + 2..<start + total], key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: aad))
            readCounter += 1
            start += total
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        return out
    }
}
