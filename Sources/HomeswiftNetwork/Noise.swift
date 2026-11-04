import Crypto
import Foundation

// The Noise Protocol Framework (https://noiseprotocol.org/noise.html, revision 34) for the one handshake devices here
// use: Noise_NNpsk0_25519_ChaChaPoly_SHA256, ESPHome's native API encryption. Neither side has a static key; both
// prove they hold the pre-shared key. The pieces follow the specification's objects: `NoiseCipherState` (section 5.1),
// the symmetric state (5.2) and `NoiseHandshake`, the handshake state (5.3) running the pattern `NNpsk0`:
//
//     -> psk, e
//     <- e, ee

public enum NoiseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A pre-shared key that is not 32 bytes, or a public key that is not 32 bytes.
    case invalidKey
    /// A handshake message shorter than its keys and tag.
    case malformedMessage
    /// A message that does not authenticate: the wrong key, or bytes changed on the way.
    case decryptionFailed
    /// A message written or read out of the pattern's order, or a split before the handshake completed.
    case outOfOrder
    /// A cipher state whose nonce reached 2^64 − 1.
    case nonceExhausted

    public var description: String {
        switch self {
        case .invalidKey: "Noise: a key is not 32 bytes"
        case .malformedMessage: "Noise: a handshake message is too short"
        case .decryptionFailed: "Noise: a message does not authenticate"
        case .outOfOrder: "Noise: a handshake message out of order"
        case .nonceExhausted: "Noise: the nonce is exhausted"
        }
    }
}

/// A key and its nonce: ChaCha20-Poly1305 with the 96-bit nonce made of 32 zero bits and the 64-bit counter,
/// little-endian. Without a key, it passes bytes through (the handshake's first tokens).
public struct NoiseCipherState: Sendable {
    private var key: SymmetricKey?
    /// The counter of the next message.
    public private(set) var nonce: UInt64 = 0

    public init(key: [UInt8]?) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    /// ChaCha20-Poly1305's nonce for a counter: four zero bytes, then the counter in little-endian order.
    public static func nonceBytes(_ counter: UInt64) -> [UInt8] {
        [0, 0, 0, 0] + withUnsafeBytes(of: counter.littleEndian, Array.init)
    }

    /// The ciphertext followed by its 16-byte tag.
    public mutating func encrypt(_ plaintext: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        guard let key else { return plaintext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)), authenticating: associatedData)
        nonce += 1
        return Array(box.ciphertext) + Array(box.tag)
    }

    /// The plaintext; throws `decryptionFailed` when the message does not authenticate (the nonce does not move then).
    public mutating func decrypt(_ ciphertext: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        guard let key else { return ciphertext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= 16 else { throw NoiseError.decryptionFailed }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: associatedData)
            nonce += 1
            return Array(plaintext)
        } catch {
            throw NoiseError.decryptionFailed
        }
    }
}

/// The chaining key, the handshake hash and the cipher state of a handshake in progress (section 5.2), with SHA-256.
struct NoiseSymmetricState {
    private(set) var chainingKey: [UInt8]
    private(set) var hash: [UInt8]
    private(set) var cipher = NoiseCipherState(key: nil)

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        hash = name.count <= 32 ? name + [UInt8](repeating: 0, count: 32 - name.count) : Array(SHA256.hash(data: name))
        chainingKey = hash
    }

    mutating func mixHash(_ data: [UInt8]) {
        hash = Array(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ material: [UInt8]) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: material, count: 2)
        chainingKey = outputs[0]
        cipher = NoiseCipherState(key: outputs[1])
    }

    mutating func mixKeyAndHash(_ material: [UInt8]) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: material, count: 3)
        chainingKey = outputs[0]
        mixHash(outputs[1])
        cipher = NoiseCipherState(key: outputs[2])
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ciphertext = try cipher.encrypt(plaintext, associatedData: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws -> [UInt8] {
        let plaintext = try cipher.decrypt(ciphertext, associatedData: hash)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: [], count: 2)
        return (NoiseCipherState(key: outputs[0]), NoiseCipherState(key: outputs[1]))
    }

    /// HKDF as Noise defines it (section 4.3): HMAC-SHA-256 keyed with the chaining key, then 2 or 3 outputs.
    static func hkdf(chainingKey: [UInt8], material: [UInt8], count: Int) -> [[UInt8]] {
        let temporary = SymmetricKey(data: Array(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: chainingKey))))
        var outputs: [[UInt8]] = []
        var previous: [UInt8] = []
        for index in 1...count {
            previous = Array(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(index)], using: temporary))
            outputs.append(previous)
        }
        return outputs
    }
}

/// The handshake `Noise_NNpsk0_25519_ChaChaPoly_SHA256`, as initiator (writes the first message) or responder. Run the
/// two messages in order, then `split()` for the transport: the initiator sends with the first cipher state and
/// receives with the second, the responder the other way round.
public struct NoiseHandshake: Sendable {
    public static let protocolName = "Noise_NNpsk0_25519_ChaChaPoly_SHA256"

    public enum Role: Sendable { case initiator, responder }

    public let role: Role
    private var symmetric: NoiseSymmetricState
    private let psk: [UInt8]
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    /// The messages done: 0, 1 or 2.
    private var step = 0

    /// `ephemeral` is random unless a test vector gives one.
    public init(role: Role, prologue: [UInt8], psk: [UInt8], ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        guard psk.count == 32 else { throw NoiseError.invalidKey }
        self.role = role
        self.psk = psk
        self.ephemeral = ephemeral
        symmetric = NoiseSymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)
    }

    public var isComplete: Bool { step == 2 }

    /// The handshake hash, which both sides share once it completes (channel binding).
    public var handshakeHash: [UInt8] { symmetric.hash }

    /// Whether the next message is this side's to write.
    public var writesNext: Bool { (step == 0) == (role == .initiator) && step < 2 }

    /// The next message of the pattern, carrying `payload` (encrypted: both messages come after a key is mixed in).
    public mutating func writeMessage(payload: [UInt8] = []) throws -> [UInt8] {
        guard writesNext else { throw NoiseError.outOfOrder }
        let publicKey = Array(ephemeral.publicKey.rawRepresentation)
        // -> psk, e   <- e, ee
        if step == 0 { symmetric.mixKeyAndHash(psk) }
        symmetric.mixHash(publicKey)
        symmetric.mixKey(publicKey)
        if step == 1 {
            guard let remoteEphemeral else { throw NoiseError.outOfOrder }
            symmetric.mixKey(try Self.dh(ephemeral, remoteEphemeral))
        }
        let message = publicKey + (try symmetric.encryptAndHash(payload))
        step += 1
        return message
    }

    /// Reads the other side's next message and answers its payload; throws `decryptionFailed` for a wrong key.
    public mutating func readMessage(_ message: [UInt8]) throws -> [UInt8] {
        guard !writesNext, step < 2 else { throw NoiseError.outOfOrder }
        guard message.count >= 32 + 16 else { throw NoiseError.malformedMessage }
        let publicKey = Array(message.prefix(32))
        guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else { throw NoiseError.invalidKey }
        if step == 0 { symmetric.mixKeyAndHash(psk) }
        symmetric.mixHash(publicKey)
        symmetric.mixKey(publicKey)
        if step == 1 { symmetric.mixKey(try Self.dh(ephemeral, remote)) }
        remoteEphemeral = remote
        let payload = try symmetric.decryptAndHash(Array(message.dropFirst(32)))
        step += 1
        return payload
    }

    /// The transport's cipher states once the handshake completed: what this side sends with, and receives with.
    public func split() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isComplete else { throw NoiseError.outOfOrder }
        let (first, second) = symmetric.split()
        return role == .initiator ? (first, second) : (second, first)
    }

    private static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Curve25519.KeyAgreement.PublicKey) throws -> [UInt8] {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Array($0) }
    }
}
