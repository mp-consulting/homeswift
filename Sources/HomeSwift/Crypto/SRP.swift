import Crypto
import Foundation

/// SRP-6a with the RFC 5054 3072-bit group and SHA-512, as HAP pair setup uses it.
///
/// The username is always `Pair-Setup` and the password is the setup code (`XXX-XX-XXX`).
/// Values are hashed padded to the group size where HAP-NodeJS (fast-srp-hap) pads them.
enum SRP {
    static let modulusHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
    static let username = "Pair-Setup"

    static let modulusBytes: Data = {
        var data = Data()
        var index = modulusHex.startIndex
        while index < modulusHex.endIndex {
            let next = modulusHex.index(index, offsetBy: 2)
            data.append(UInt8(modulusHex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }()

    static let field = ModularField(modulusBytes: modulusBytes)
    static let g = field.number(5)
    static let gBytes = Data([5])

    static func H(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// k = H(N | PAD(g))
    static let k = field.number(H(modulusBytes, field.bytes(g)))!

    /// x = H(s | H(I ":" P)), kept as bytes because it is only ever an exponent.
    static func x(salt: Data, password: String) -> Data {
        H(salt, H(Data("\(username):\(password)".utf8)))
    }

    static func verifier(salt: Data, password: String) -> ModularField.Number {
        field.power(g, x(salt: salt, password: password))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// M1 = H(H(N) xor H(g), H(I), s, A, B, K)
    static func clientProof(salt: Data, A: Data, B: Data, K: Data) -> Data {
        let xor = Data(zip(H(modulusBytes), H(gBytes)).map { $0 ^ $1 })
        return H(xor, H(Data(username.utf8)), salt, A, B, K)
    }

    /// The accessory side of one pair-setup exchange.
    struct Server {
        let salt: Data
        let verifier: ModularField.Number
        let privateKey: Data
        let publicKey: Data

        init(password: String, salt: Data = SRP.randomBytes(16), privateKey: Data = SRP.randomBytes(32)) {
            self.salt = salt
            self.privateKey = privateKey
            verifier = SRP.verifier(salt: salt, password: password)
            // B = k*v + g^b
            let B = field.add(field.multiply(k, verifier), field.power(g, privateKey))
            publicKey = field.bytes(B)
        }

        /// Checks the controller's proof. Returns the session key K and the accessory proof M2, or nil.
        func verify(clientPublicKey A: Data, clientProof M1: Data) -> (sessionKey: Data, proof: Data)? {
            guard let aValue = field.number(A), !field.isZero(aValue) else { return nil }
            let u = SRP.H(field.bytes(aValue), publicKey)
            guard u.contains(where: { $0 != 0 }) else { return nil }
            // S = (A * v^u) ^ b
            let S = field.power(field.multiply(aValue, field.power(verifier, u)), privateKey)
            let K = SRP.H(field.bytes(S))
            let expected = SRP.clientProof(salt: salt, A: A, B: publicKey, K: K)
            guard constantTimeEqual(expected, M1) else { return nil }
            return (K, SRP.H(A, M1, K))
        }
    }

    /// The controller side, used by tests and by anything that pairs with an accessory.
    struct Client {
        let privateKey: Data
        let publicKey: Data

        init(privateKey: Data = SRP.randomBytes(32)) {
            self.privateKey = privateKey
            publicKey = field.bytes(field.power(g, privateKey))
        }

        func proof(salt: Data, serverPublicKey B: Data, password: String) -> (sessionKey: Data, proof: Data, expectedServerProof: Data) {
            let bValue = field.number(B) ?? field.number(0)
            let u = SRP.H(publicKey, field.bytes(bValue))
            let x = SRP.x(salt: salt, password: password)
            // S = (B - k*g^x) ^ (a + u*x) = base^a * (base^u)^x
            let base = field.subtract(bValue, field.multiply(k, field.power(g, x)))
            let S = field.multiply(field.power(base, privateKey), field.power(field.power(base, u), x))
            let K = SRP.H(field.bytes(S))
            let M1 = SRP.clientProof(salt: salt, A: publicKey, B: field.bytes(bValue), K: K)
            return (K, M1, SRP.H(publicKey, M1, K))
        }
    }
}

func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
    return diff == 0
}
