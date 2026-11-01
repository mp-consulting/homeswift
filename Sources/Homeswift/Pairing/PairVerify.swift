import Crypto
import Foundation

struct PairVerifyState {
    var sharedSecret: Data
    var key: SymmetricKey
    var accessoryPublicKey: Data
    var controllerPublicKey: Data
}

extension HAPConnection {
    /// Pair verify, M1 to M4: an X25519 exchange signed with both long-term keys. Afterwards the
    /// connection switches to the encrypted session.
    func handlePairVerify(_ body: Data) -> (HTTPResponse, After) {
        guard let tlv = try? TLV8(decoding: body), let step = tlv.byte(.state) else {
            return (pairingError(state: 2, .unknown), .none)
        }
        switch step {
        case 1: return (pairVerifyStart(tlv), .none)
        case 3: return pairVerifyFinish(tlv)
        default: return (pairingError(state: step &+ 1, .unknown), .none)
        }
    }

    private func pairVerifyStart(_ tlv: TLV8) -> HTTPResponse {
        guard let controllerPublicKey = tlv[.publicKey],
            let controllerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerPublicKey)
        else {
            return pairingError(state: 2, .unknown)
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: controllerKey) else {
            return pairingError(state: 2, .unknown)
        }
        let sharedSecret = shared.data
        let accessoryPublicKey = ephemeral.publicKey.rawRepresentation
        let deviceID = Data(server.deviceID.utf8)

        guard let signature = try? server.signingKey.signature(for: accessoryPublicKey + deviceID + controllerPublicKey) else {
            return pairingError(state: 2, .unknown)
        }
        var sub = TLV8()
        sub.append(.identifier, deviceID)
        sub.append(.signature, signature)

        let key = HAPCrypto.hkdf(sharedSecret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        guard let sealed = try? HAPCrypto.seal(sub.encoded(), key: key, nonce: HAPCrypto.nonce("PV-Msg02")) else {
            return pairingError(state: 2, .unknown)
        }
        pairVerify = PairVerifyState(
            sharedSecret: sharedSecret, key: key,
            accessoryPublicKey: accessoryPublicKey, controllerPublicKey: controllerPublicKey
        )

        var response = TLV8()
        response.append(.state, 2)
        response.append(.publicKey, accessoryPublicKey)
        response.append(.encryptedData, sealed)
        return .tlv(response)
    }

    private func pairVerifyFinish(_ tlv: TLV8) -> (HTTPResponse, After) {
        guard let verify = pairVerify, let encrypted = tlv[.encryptedData] else {
            return (pairingError(state: 4, .unknown), .none)
        }
        pairVerify = nil
        guard let decrypted = try? HAPCrypto.open(encrypted, key: verify.key, nonce: HAPCrypto.nonce("PV-Msg03")),
            let sub = try? TLV8(decoding: decrypted),
            let identifierData = sub[.identifier], let identifier = String(data: identifierData, encoding: .utf8),
            let signature = sub[.signature]
        else {
            return (pairingError(state: 4, .authentication), .none)
        }
        guard let pairing = server.pairings.first(where: { $0.identifier == identifier }),
            let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
            controllerKey.isValidSignature(signature, for: verify.controllerPublicKey + identifierData + verify.accessoryPublicKey)
        else {
            server.logger.info("Pair verify rejected unknown controller", metadata: ["controller": "\(identifier)"])
            return (pairingError(state: 4, .authentication), .none)
        }

        setController(identifier)
        server.logger.debug("Controller verified", metadata: ["controller": "\(identifier)"])
        var response = TLV8()
        response.append(.state, 4)
        return (.tlv(response), .startSession(SecureSession(sharedSecret: verify.sharedSecret)))
    }
}
