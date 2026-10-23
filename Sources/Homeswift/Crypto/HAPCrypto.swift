import Crypto
import Foundation

enum HAPCrypto {
    /// HKDF-SHA-512 to a 32-byte key, as every HAP key derivation.
    static func hkdf(_ inputKeyMaterial: Data, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func hkdf(_ inputKeyMaterial: Data, salt: String, info: String) -> SymmetricKey {
        hkdf(inputKeyMaterial, salt: Data(salt.utf8), info: info)
    }

    /// A pairing nonce such as `PS-Msg05`: four zero bytes followed by the eight-byte label.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(Data(label.utf8))
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// A session frame nonce: four zero bytes followed by the little-endian frame counter.
    static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ data: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw TLVError.authentication }
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

extension SharedSecret {
    var data: Data { withUnsafeBytes { Data($0) } }
}
