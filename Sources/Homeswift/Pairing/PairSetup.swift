import Crypto
import Foundation

enum PairSetupState {
    case awaitingProof(SRP.Server)
    case awaitingExchange(sessionKey: Data)
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

func pairingError(state: UInt8, _ error: TLVError) -> HTTPResponse {
    var tlv = TLV8()
    tlv.append(.state, state)
    tlv.append(.error, error.rawValue)
    return .tlv(tlv)
}

extension HAPConnection {
    /// Pair setup, M1 to M6: SRP proves both sides know the setup code, then they swap long-term keys.
    func handlePairSetup(_ body: Data) -> HTTPResponse {
        guard let tlv = try? TLV8(decoding: body), let step = tlv.byte(.state) else {
            return pairingError(state: 2, .unknown)
        }
        switch step {
        case 1: return pairSetupStart()
        case 3: return pairSetupVerify(tlv)
        case 5: return pairSetupExchange(tlv)
        default: return pairingError(state: step &+ 1, .unknown)
        }
    }

    private func pairSetupStart() -> HTTPResponse {
        let claim = server.state.withLockedValue { state -> TLVError? in
            if !state.persisted.pairings.isEmpty { return .unavailable }
            if state.persisted.failedPairSetupAttempts ?? 0 >= 100 { return .maxTries }
            if let owner = state.pairSetupOwner, owner != id { return .busy }
            state.pairSetupOwner = id
            return nil
        }
        if let claim {
            server.logger.info("Pair setup refused", metadata: ["reason": "\(claim)"])
            return pairingError(state: 2, claim)
        }

        let srp = SRP.Server(password: server.setupCode.rawValue)
        pairSetup = .awaitingProof(srp)
        var tlv = TLV8()
        tlv.append(.state, 2)
        tlv.append(.publicKey, srp.publicKey)
        tlv.append(.salt, srp.salt)
        return .tlv(tlv)
    }

    private func pairSetupVerify(_ tlv: TLV8) -> HTTPResponse {
        guard case .awaitingProof(let srp) = pairSetup,
            let publicKey = tlv[.publicKey], let proof = tlv[.proof]
        else {
            return pairingError(state: 4, .unknown)
        }
        guard let (sessionKey, serverProof) = srp.verify(clientPublicKey: publicKey, clientProof: proof) else {
            server.logger.warning("Pair setup failed: wrong setup code")
            endPairSetup(failed: true)
            return pairingError(state: 4, .authentication)
        }
        pairSetup = .awaitingExchange(sessionKey: sessionKey)
        var response = TLV8()
        response.append(.state, 4)
        response.append(.proof, serverProof)
        return .tlv(response)
    }

    private func pairSetupExchange(_ tlv: TLV8) -> HTTPResponse {
        guard case .awaitingExchange(let sessionKey) = pairSetup, let encrypted = tlv[.encryptedData] else {
            return pairingError(state: 6, .unknown)
        }
        let key = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        guard let decrypted = try? HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PS-Msg05")),
            let sub = try? TLV8(decoding: decrypted),
            let identifierData = sub[.identifier], let identifier = String(data: identifierData, encoding: .utf8),
            let ltpk = sub[.publicKey], let signature = sub[.signature],
            let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ltpk)
        else {
            endPairSetup(failed: true)
            return pairingError(state: 6, .authentication)
        }

        let controllerX = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info").data
        guard controllerKey.isValidSignature(signature, for: controllerX + identifierData + ltpk) else {
            endPairSetup(failed: true)
            return pairingError(state: 6, .authentication)
        }

        server.state.withLockedValue {
            $0.persisted.pairings.removeAll { $0.identifier == identifier }
            $0.persisted.pairings.append(Pairing(identifier: identifier, publicKey: ltpk, isAdmin: true))
        }
        do { try server.persist() } catch {
            server.logger.error("Could not save pairing", metadata: ["error": "\(error)"])
            return pairingError(state: 6, .unknown)
        }

        let deviceID = Data(server.deviceID.utf8)
        let accessoryLTPK = server.signingKey.publicKey.rawRepresentation
        let accessoryX = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info").data
        guard let accessorySignature = try? server.signingKey.signature(for: accessoryX + deviceID + accessoryLTPK) else {
            return pairingError(state: 6, .unknown)
        }
        var info = TLV8()
        info.append(.identifier, deviceID)
        info.append(.publicKey, accessoryLTPK)
        info.append(.signature, accessorySignature)
        guard let sealed = try? HAPCrypto.seal(info.encoded(), key: key, nonce: HAPCrypto.nonce("PS-Msg06")) else {
            return pairingError(state: 6, .unknown)
        }

        endPairSetup(failed: false)
        server.state.withLockedValue { $0.persisted.failedPairSetupAttempts = nil }
        try? server.persist()
        server.logger.info("Paired with controller", metadata: ["controller": "\(identifier)"])
        server.updateAdvertisement()

        var response = TLV8()
        response.append(.state, 6)
        response.append(.encryptedData, sealed)
        return .tlv(response)
    }

    private func endPairSetup(failed: Bool) {
        pairSetup = nil
        server.state.withLockedValue { state in
            if state.pairSetupOwner == id { state.pairSetupOwner = nil }
            if failed { state.persisted.failedPairSetupAttempts = (state.persisted.failedPairSetupAttempts ?? 0) + 1 }
        }
        if failed {
            do { try server.persist() } catch {
                server.logger.error("Could not save the failed pair setup", metadata: ["error": "\(error)"])
            }
        }
    }
}
