import Crypto
import Foundation
import Homeswift
import _CryptoExtras

/// securePassthrough, the protocol of older Tapo firmware (docs/clean-room/Tapo.md, 4.1): the client sends an RSA public
/// key, the device answers an AES-128-CBC key and IV encrypted with it, and each request is a JSON text encrypted with
/// them inside a `securePassthrough` envelope. The plugin falls back to it only when the device has no KLAP endpoint.
enum SecurePassthrough {
    /// The client's key pair: 1024-bit RSA, the public half sent as an SPKI PEM text.
    struct KeyPair {
        let privateKey: _RSA.Encryption.PrivateKey

        init() throws {
            privateKey = try _RSA.Encryption.PrivateKey(unsafeKeySize: _RSA.Signing.KeySize(bitCount: 1024))
        }

        var publicKeyPEM: String { privateKey.publicKey.pemRepresentation }

        /// The handshake's `result.key`: base64 of the key (bytes 0-15) and the IV (bytes 16-31), with PKCS#1 v1.5.
        func cipher(fromHandshakeKey key: String) throws -> Cipher {
            guard let encrypted = Data(base64Encoded: key) else { throw TapoError.invalidResponse("the handshake key is not base64") }
            let plaintext = try privateKey.decrypt(encrypted, padding: ._WEAK_AND_INSECURE_PKCS_V1_5)
            guard plaintext.count >= 32 else { throw TapoError.invalidResponse("the handshake key has \(plaintext.count) bytes") }
            return Cipher(key: Data(plaintext.prefix(16)), iv: Data(plaintext.dropFirst(16).prefix(16)))
        }
    }

    /// The session's AES-128-CBC key and IV: the same IV for every message.
    struct Cipher: Sendable {
        let key: Data
        let iv: Data

        func encrypt(_ plaintext: Data) throws -> String {
            try AES._CBC.encrypt(plaintext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv)).base64EncodedString()
        }

        func decrypt(_ base64: String) throws -> Data {
            guard let ciphertext = Data(base64Encoded: base64) else { throw TapoError.invalidResponse("the response is not base64") }
            return try AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv))
        }
    }

    /// `login_device`'s parameters: base64 of the lowercase hex SHA-1 of the email (the 40 characters), and base64 of
    /// the password.
    static func loginParameters(username: String, password: String) -> [String: String] {
        let digest = Secrets.hex(Insecure.SHA1.hash(data: Data(username.utf8)))
        return ["username": Data(digest.utf8).base64EncodedString(), "password": Data(password.utf8).base64EncodedString()]
    }
}
