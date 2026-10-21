import Foundation

extension HAPConnection {
    enum PairingMethod: UInt8 {
        case add = 3
        case remove = 4
        case list = 5
    }

    /// `POST /pairings`: admins add, remove and list controllers.
    func handlePairings(_ body: Data) -> (HTTPResponse, After) {
        guard let tlv = try? TLV8(decoding: body), let raw = tlv.byte(.method), let method = PairingMethod(rawValue: raw) else {
            return (pairingError(state: 2, .unknown), .none)
        }
        guard isAdmin else {
            return (pairingError(state: 2, .authentication), .none)
        }
        switch method {
        case .add: return (addPairing(tlv), .none)
        case .remove: return removePairing(tlv)
        case .list: return (listPairings(), .none)
        }
    }

    private func addPairing(_ tlv: TLV8) -> HTTPResponse {
        guard let identifierData = tlv[.identifier], let identifier = String(data: identifierData, encoding: .utf8),
            let publicKey = tlv[.publicKey], publicKey.count == 32
        else {
            return pairingError(state: 2, .unknown)
        }
        let isAdmin = (tlv.byte(.permissions) ?? 0) & 1 == 1
        let error = server.state.withLockedValue { state -> TLVError? in
            if let index = state.persisted.pairings.firstIndex(where: { $0.identifier == identifier }) {
                guard state.persisted.pairings[index].publicKey == publicKey else { return .unknown }
                state.persisted.pairings[index].isAdmin = isAdmin
                return nil
            }
            guard state.persisted.pairings.count < 16 else { return .maxPeers }
            state.persisted.pairings.append(Pairing(identifier: identifier, publicKey: publicKey, isAdmin: isAdmin))
            return nil
        }
        if let error { return pairingError(state: 2, error) }
        try? server.persist()
        server.logger.info("Added pairing", metadata: ["controller": "\(identifier)", "admin": "\(isAdmin)"])
        var response = TLV8()
        response.append(.state, 2)
        return .tlv(response)
    }

    private func removePairing(_ tlv: TLV8) -> (HTTPResponse, After) {
        guard let identifierData = tlv[.identifier], let identifier = String(data: identifierData, encoding: .utf8) else {
            return (pairingError(state: 2, .unknown), .none)
        }
        let removedAll = server.state.withLockedValue { state -> Bool in
            state.persisted.pairings.removeAll { $0.identifier == identifier }
            // With no admin left nobody could manage the accessory, so it resets.
            if !state.persisted.pairings.contains(where: \.isAdmin) {
                state.persisted.pairings.removeAll()
                return true
            }
            return false
        }
        try? server.persist()
        server.updateAdvertisement()
        server.logger.info("Removed pairing", metadata: ["controller": "\(identifier)", "reset": "\(removedAll)"])
        var response = TLV8()
        response.append(.state, 2)
        return (.tlv(response), .closeControllers(removedAll ? nil : [identifier]))
    }

    private func listPairings() -> HTTPResponse {
        var response = TLV8()
        response.append(.state, 2)
        for (index, pairing) in server.pairings.enumerated() {
            if index > 0 { response.append(.separator, Data()) }
            response.append(.identifier, Data(pairing.identifier.utf8))
            response.append(.publicKey, pairing.publicKey)
            response.append(.permissions, pairing.isAdmin ? 1 : 0)
        }
        return .tlv(response)
    }
}
