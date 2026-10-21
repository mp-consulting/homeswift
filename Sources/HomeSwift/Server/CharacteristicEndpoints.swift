import Foundation

extension HAPConnection {
    /// `GET /characteristics?id=1.10,1.11&meta=1&perms=1&type=1&ev=1`
    func handleRead(_ query: [String: String]) async -> HTTPResponse {
        guard let ids = query["id"], !ids.isEmpty else {
            return .hapStatus(400, .invalidValueInRequest)
        }
        let meta = query["meta"] == "1"
        let perms = query["perms"] == "1"
        let type = query["type"] == "1"
        let ev = query["ev"] == "1"

        var results: [CharacteristicJSON] = []
        var failed = false
        for pair in ids.split(separator: ",") {
            let parts = pair.split(separator: ".")
            guard parts.count == 2, let aid = Int(parts[0]), let iid = Int(parts[1]) else {
                return .hapStatus(400, .invalidValueInRequest)
            }
            guard let characteristic = server.characteristic(aid: aid, iid: iid) else {
                results.append(CharacteristicJSON(aid: aid, iid: iid, status: .resourceDoesNotExist))
                failed = true
                continue
            }
            guard characteristic.type.permissions.contains(.pairedRead) else {
                results.append(CharacteristicJSON(aid: aid, iid: iid, status: .writeOnlyCharacteristic))
                failed = true
                continue
            }
            do {
                if let read = characteristic.readHandler {
                    characteristic.update(try await read(), origin: id, force: false)
                }
                var entry = CharacteristicJSON(
                    describing: characteristic, includeValue: true, includeMeta: meta, includePerms: perms, includeType: type)
                entry.aid = aid
                if ev { entry.ev = isSubscribed(to: CharacteristicKey(aid: aid, iid: iid)) }
                results.append(entry)
            } catch {
                results.append(CharacteristicJSON(aid: aid, iid: iid, status: status(for: error)))
                failed = true
            }
        }
        if failed {
            for index in results.indices where results[index].status == nil {
                results[index].status = HAPStatus.success.rawValue
            }
            return .json(207, CharacteristicsJSON(characteristics: results))
        }
        return .json(200, CharacteristicsJSON(characteristics: results))
    }

    /// `PUT /characteristics`: value writes and event (un)subscriptions.
    func handleWrite(_ body: Data) async -> HTTPResponse {
        guard let request = try? HAPJSON.decoder.decode(WriteRequest.self, from: body) else {
            return .hapStatus(400, .invalidValueInRequest)
        }
        let timedWriteValid: Bool = {
            guard let pid = request.pid, let timed = timedWrite else { return false }
            return timed.pid == pid && ContinuousClock.now <= timed.expires
        }()
        if request.pid != nil { timedWrite = nil }

        var results: [CharacteristicJSON] = []
        var needsBody = false
        for item in request.characteristics {
            let key = CharacteristicKey(aid: item.aid, iid: item.iid)
            guard let characteristic = server.characteristic(aid: item.aid, iid: item.iid) else {
                results.append(CharacteristicJSON(aid: item.aid, iid: item.iid, status: .resourceDoesNotExist))
                needsBody = true
                continue
            }
            let permissions = characteristic.type.permissions
            var status = HAPStatus.success
            var readBack: HAPValue?

            if let ev = item.ev {
                if permissions.contains(.events) {
                    setSubscribed(ev, to: key)
                } else {
                    status = .notificationNotSupported
                }
            }

            if status == .success, let value = item.value {
                if !permissions.contains(.pairedWrite) {
                    status = .readOnlyCharacteristic
                } else if permissions.contains(.timedWrite), !timedWriteValid {
                    status = .invalidValueInRequest
                } else if let coerced = characteristic.type.coerce(value) {
                    do {
                        if characteristic.type.uuid == CharacteristicType.identify.uuid {
                            server.logger.info("Identify requested", metadata: ["aid": "\(item.aid)", "accessory": "\(server.accessory(aid: item.aid)?.name ?? "?")"])
                        }
                        try await characteristic.writeHandler(for: coerced)?(coerced)
                        characteristic.update(coerced, origin: id, force: false)
                        if item.r == true, permissions.contains(.writeResponse) {
                            readBack = characteristic.value
                        }
                    } catch {
                        status = self.status(for: error)
                    }
                } else {
                    status = .invalidValueInRequest
                }
            }

            if status != .success || readBack != nil { needsBody = true }
            results.append(CharacteristicJSON(aid: item.aid, iid: item.iid, value: readBack, status: status))
        }

        return needsBody ? .json(207, CharacteristicsJSON(characteristics: results)) : .noContent
    }

    /// `PUT /prepare`: opens a timed-write window for locks and garage doors.
    func handlePrepare(_ body: Data) -> HTTPResponse {
        guard let request = try? HAPJSON.decoder.decode(PrepareRequest.self, from: body) else {
            return .hapStatus(400, .invalidValueInRequest)
        }
        timedWrite = (request.pid, ContinuousClock.now + .milliseconds(request.ttl))
        return .json(200, ["status": HAPStatus.success.rawValue])
    }

    /// `POST /identify`: only allowed before the accessory is paired.
    func handleIdentify() async -> HTTPResponse {
        guard !server.isPaired else {
            return .hapStatus(400, .insufficientPrivileges)
        }
        await server.primary.identify()
        return .noContent
    }

    private func status(for error: any Error) -> HAPStatus {
        (error as? HAPStatusError)?.status ?? .serviceCommunicationFailure
    }
}
