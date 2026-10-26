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
        // The accessories read, for the timing observers.
        let start = ContinuousClock.now
        var read: Set<Int> = []
        defer { if !read.isEmpty { server.recordTiming(.request, aids: read, since: start) } }
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
            read.insert(aid)
            do {
                if characteristic.isUnavailable { throw HAPStatusError(.serviceCommunicationFailure) }
                if let handler = characteristic.readHandler {
                    let value = try await HAPRequestContext.$current.withValue(requestContext) { try await characteristic.timed(handler) }
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

        // As HAP-NodeJS: the same characteristic twice in one request is refused, since the writes run together.
        let keys = request.characteristics.map { CharacteristicKey(aid: $0.aid, iid: $0.iid) }
        guard Set(keys).count == keys.count else { return .hapStatus(422, .invalidValueInRequest) }

        var results: [CharacteristicJSON] = []
        let requestContext = requestContext
        // The accessories written (not those only subscribed to), for the timing observers.
        let start = ContinuousClock.now
        var written: Set<Int> = []
        defer { if !written.isEmpty { server.recordTiming(.request, aids: written, since: start) } }
        // The writes to run: the result's index, the characteristic, the value and whether the value is read back.
        var writes: [(index: Int, characteristic: Characteristic, value: HAPValue, readBack: Bool)] = []
        for item in request.characteristics {
            let key = CharacteristicKey(aid: item.aid, iid: item.iid)
            guard let characteristic = server.characteristic(aid: item.aid, iid: item.iid) else {
                results.append(CharacteristicJSON(aid: item.aid, iid: item.iid, status: .resourceDoesNotExist))
                continue
            }
            let permissions = characteristic.type.permissions
            var status = HAPStatus.success

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
                    written.insert(item.aid)
                    if characteristic.type.uuid == CharacteristicType.identify.uuid {
                        server.logger.info("Identify requested", metadata: ["aid": "\(item.aid)", "accessory": "\(server.accessory(aid: item.aid)?.name ?? "?")"])
                    }
                    writes.append((results.count, characteristic, value, item.r == true && permissions.contains(.writeResponse)))
                }
            }
            results.append(CharacteristicJSON(aid: item.aid, iid: item.iid, status: status))
        }

        // As HAP-NodeJS, the writes of one request run at the same time: a light's brightness, hue and saturation
        // reach the plugin together, as plugins that wait a moment to send them as one command expect.
        let origin = id
        await withTaskGroup(of: (Int, HAPStatus, HAPValue?).self) { group in
            for write in writes {
                group.addTask {
                    do {
                        let stored = try await HAPRequestContext.$current.withValue(requestContext) {
                            try await write.characteristic.write(write.value, origin: origin)
                        }
                        return (write.index, .success, write.readBack ? stored : HAPValue?.none)
                    } catch {
                        return (write.index, (error as? HAPStatusError)?.status ?? .serviceCommunicationFailure, nil)
                    }
                }
            }
            for await (index, status, readBack) in group {
                results[index].status = status.rawValue
                results[index].value = readBack
            }
        }

        let needsBody = results.contains { $0.status != HAPStatus.success.rawValue || $0.value != nil }
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
