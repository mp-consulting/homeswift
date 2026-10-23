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
        // Built once for the request, not for each characteristic.
        let requestContext = requestContext
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
                if characteristic.isUnavailable { throw HAPStatusError(.serviceCommunicationFailure) }
                if let read = characteristic.readHandler {
                    let value = try await HAPRequestContext.$current.withValue(requestContext) { try await read() }
                    characteristic.update(value, origin: id, force: false, reason: .read)
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
        let requestContext = requestContext
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
                if permissions.contains(.timedWrite), !timedWriteValid {
                    status = .invalidValueInRequest
                } else {
                    do {
                        if characteristic.type.uuid == CharacteristicType.identify.uuid {
                            server.logger.info("Identify requested", metadata: ["aid": "\(item.aid)", "accessory": "\(server.accessory(aid: item.aid)?.name ?? "?")"])
                        }
                        let stored = try await HAPRequestContext.$current.withValue(requestContext) {
                            try await characteristic.write(value, origin: id)
                        }
                        if item.r == true, permissions.contains(.writeResponse) {
                            readBack = stored
                        }
                    } catch {
                        status = self.status(for: error)
                    }
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
        return .json(200, StatusJSON(status: HAPStatus.success.rawValue))
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

extension HAPConnection {
    /// `POST /resource`: a camera snapshot, `{"resource-type": "image", "image-width": w, "image-height": h}` with
    /// an optional `aid` (bridged cameras) and `reason` (HAP-NodeJS's HAPServer and Accessory.handleResource).
    func handleResource(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST", !request.body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else { return .hapStatus(400, .invalidValueInRequest) }
        guard object["resource-type"] as? String == "image" else {
            server.logger.debug("Request for an unsupported resource type", metadata: ["type": "\(object["resource-type"] ?? "-")"])
            return .hapStatus(404, .resourceDoesNotExist)
        }
        let accessory = (object["aid"] as? Int).flatMap(server.accessory(aid:)) ?? (object["aid"] == nil ? server.primary : nil)
        if let accessory, accessory.isUnavailable { return .hapStatus(207, .serviceCommunicationFailure) }
        guard let accessory, let camera = accessory.cameraController else {
            server.logger.debug("Snapshot request though no camera controller is associated")
            return .hapStatus(404, .resourceDoesNotExist)
        }
        let width = object["image-width"] as? Int ?? 0
        let height = object["image-height"] as? Int ?? 0
        let reason = (object["reason"] as? Int).flatMap(ResourceRequestReason.init(rawValue:))
        do {
            let image = try await HAPRequestContext.$current.withValue(requestContext) {
                try await camera.handleSnapshotRequest(height: height, width: width, accessoryName: accessory.name, reason: reason)
            }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: image)
        } catch {
            return .hapStatus(207, (error as? HAPStatusError)?.status ?? .serviceCommunicationFailure)
        }
    }
}
