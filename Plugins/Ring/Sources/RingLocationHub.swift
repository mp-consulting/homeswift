import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The hub devices of a location (alarm base station, Smart Lighting bridge), by zid, as the location socket reports
/// them: each document flattened (`general.v2`, then `device.v1` over it) and every update merged into it. Read
/// synchronously by the accessories; written by the socket.
final class RingHubInventory: Sendable {
    struct Device: Sendable {
        var asset: String
        var data: [String: JSONValue]
    }

    private struct State {
        var devices: [String: Device] = [:]
        var order: [String] = []
    }

    private let state = NIOLockedValueBox(State())
    /// Told of each device whose data changed.
    let onChange = NIOLockedValueBox<(@Sendable (String, JSONValue) -> Void)?>(nil)

    func data(_ zid: String) -> JSONValue? { state.withLockedValue { $0.devices[zid].map { .object($0.data) } } }
    func asset(of zid: String) -> String? { state.withLockedValue { $0.devices[zid]?.asset } }

    /// Every device, in the order the hubs listed them.
    var all: [(zid: String, data: JSONValue)] {
        state.withLockedValue { state in state.order.compactMap { zid in state.devices[zid].map { (zid, .object($0.data)) } } }
    }

    /// `general.v2` then `device.v1` of a document, the latter winning.
    static func flatten(_ document: JSONValue) -> [String: JSONValue] {
        var data = document["general"]?["v2"]?.objectValue ?? [:]
        for (key, value) in document["device"]?["v1"]?.objectValue ?? [:] { data[key] = value }
        return data
    }

    /// Merges documents: a known zid's fields are updated, an unknown one is added under `asset` when `adding`.
    func merge(_ documents: [JSONValue], asset: String, adding: Bool) {
        var changed: [(String, JSONValue)] = []
        state.withLockedValue { state in
            for document in documents {
                let fields = Self.flatten(document)
                guard let zid = fields["zid"]?.stringValue else { continue }
                if var device = state.devices[zid] {
                    for (key, value) in fields { device.data[key] = value }
                    state.devices[zid] = device
                    changed.append((zid, .object(device.data)))
                } else if adding {
                    state.devices[zid] = Device(asset: asset, data: fields)
                    state.order.append(zid)
                    changed.append((zid, .object(fields)))
                }
            }
        }
        guard let onChange = onChange.withLockedValue({ $0 }) else { return }
        for (zid, data) in changed { onChange(zid, data) }
    }
}

/// A location's WebSocket to its hubs (docs/clean-room/Ring.md, 3.3): a ticket, `wss://<host>/ws?authcode=…`, the
/// device lists of every asset, live updates, and writes (`DeviceInfoSet`). It reconnects with a fresh ticket when it
/// drops or the hub says so, until stopped.
actor RingLocationHub {
    typealias Connect = @Sendable (URL) async throws -> any WebSocketConnection

    let locationID: String
    let name: String
    let inventory = RingHubInventory()
    private let client: RingClient
    private let connect: Connect
    private let timing: RingTiming
    private let logger: Logger
    private var socket: (any WebSocketConnection)?
    private var sequence = 0
    /// The assets of the ticket: all are asked for their lists, the supported ones must answer.
    private var assets: [(uuid: String, kind: String)] = []
    private var listsReceived: Set<String> = []
    private var offline: Set<String> = []
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateWaiters: [String: [UUID: CheckedContinuation<JSONValue, any Error>]] = [:]
    private var runner: Task<Void, Never>?
    private var reconnecting = false
    private var baseStationAsset: String?

    init(locationID: String, name: String, client: RingClient, timing: RingTiming, logger: Logger, connect: @escaping Connect) {
        self.locationID = locationID
        self.name = name
        self.client = client
        self.timing = timing
        self.logger = logger
        self.connect = connect
    }

    /// The location's base station asset, for panic dispatches.
    var alarmAsset: String? { baseStationAsset }

    func start() {
        guard runner == nil else { return }
        logger.info("Creating location connection - \(name)")
        runner = Task { await self.run() }
    }

    func stop() async {
        runner?.cancel()
        runner = nil
        await socket?.close()
        socket = nil
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters = []
        for (_, waiters) in updateWaiters { for (_, waiter) in waiters { waiter.resume(throwing: CancellationError()) } }
        updateWaiters = [:]
    }

    /// Waits until every supported asset sent its device list, or `timeout`; false when it timed out.
    func waitUntilReady(timeout: Duration) async -> Bool {
        if ready { return true }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.releaseReadyWaiters()
        }
        await withCheckedContinuation { readyWaiters.append($0) }
        timer.cancel()
        return ready
    }

    private func releaseReadyWaiters() {
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters = []
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let ticket = try await client.hubTicket(locationID: locationID)
                let all = (ticket["assets"]?.arrayValue ?? []).compactMap { asset -> (String, String)? in
                    guard let uuid = asset["uuid"]?.stringValue else { return nil }
                    return (uuid, asset["kind"]?.stringValue ?? "")
                }
                assets = all
                baseStationAsset = all.first { $0.1.hasPrefix("base_station") }?.0
                guard all.contains(where: { Self.isSupported($0.1) }) else {
                    throw RingError.unexpected("no assets (alarm hubs or beam bridges) for location \(name)")
                }
                guard let host = ticket["host"]?.stringValue, let code = ticket["ticket"]?.stringValue,
                      let url = URL(string: "wss://\(host)/ws?authcode=\(URLEncoding.rfc3986(code))&ack=false") else {
                    throw RingError.unexpected("the hub ticket has no host")
                }
                let opened = try await connect(url)
                socket = opened
                listsReceived = []
                offline = []
                reconnecting = false
                attempt = 0
                logger.info("Location \(name) connected")
                for asset in assets { try? await send(message: "DeviceInfoDocGetList", destination: asset.uuid) }
                for try await message in opened.messages {
                    if case .text(let text) = message { handle(text) }
                    if reconnecting { break }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                logger.warning("Location \(name) connection failed: \(error)")
            }
            await socket?.close()
            socket = nil
            guard !Task.isCancelled else { return }
            logger.info("Reconnecting location \(name)")
            attempt += 1
            let delay = attempt <= 3 ? timing.hubReconnect : Backoff(initial: timing.hubReconnect, maximum: .seconds(60)).delay(attempt: attempt - 3)
            try? await Task.sleep(for: delay)
        }
    }

    static func isSupported(_ kind: String) -> Bool { kind.hasPrefix("base_station") || kind.hasPrefix("beams_bridge") }

    /// One frame from the hub.
    func handle(_ text: String) {
        guard let frame = try? JSONValue(string: text), let message = frame["msg"] else {
            logger.error("Location \(name) sent a frame that is not JSON")
            return
        }
        let type = message["msg"]?.stringValue
        let dataType = message["datatype"]?.stringValue
        let source = message["src"]?.stringValue ?? ""
        let body = message["body"]?.arrayValue ?? []
        if dataType == "HubDisconnectionEventType" {
            logger.info("Location \(name) was told to reconnect")
            reconnecting = true
            Task { await self.socket?.close() }
            return
        }
        if type == "DeviceInfoDocGetList" {
            let isList = frame["channel"]?.stringValue != "DataUpdate"
            inventory.merge(body, asset: source, adding: true)
            if isList { listReceived(from: source) }
            resolveUpdateWaiters(body)
            return
        }
        if frame["channel"]?.stringValue == "DataUpdate", dataType == "DeviceInfoDocType" {
            inventory.merge(body, asset: source, adding: false)
            resolveUpdateWaiters(body)
            return
        }
        if type == "SessionInfo" {
            for session in body {
                guard let asset = session["assetUuid"]?.stringValue, assets.contains(where: { $0.uuid == asset }) else { continue }
                let status = session["connectionStatus"]?.stringValue
                if status != "online" {
                    if offline.insert(asset).inserted { logger.warning("Ring alarm hub \(asset) at \(name) is offline or on cellular backup") }
                } else if offline.remove(asset) != nil {
                    logger.info("Ring alarm hub \(asset) at \(name) is back online")
                    Task { try? await self.send(message: "DeviceInfoDocGetList", destination: asset) }
                }
            }
        }
    }

    private func listReceived(from asset: String) {
        listsReceived.insert(asset)
        let supported = assets.filter { Self.isSupported($0.kind) }.map(\.uuid)
        if !ready, supported.allSatisfy(listsReceived.contains) {
            ready = true
            releaseReadyWaiters()
        }
    }

    private func resolveUpdateWaiters(_ body: [JSONValue]) {
        for document in body {
            guard let zid = RingHubInventory.flatten(document)["zid"]?.stringValue, let waiters = updateWaiters.removeValue(forKey: zid),
                  let data = inventory.data(zid) else { continue }
            for (_, waiter) in waiters { waiter.resume(returning: data) }
        }
    }

    // MARK: Writes

    private func send(message type: String, destination: String, dataType: String? = nil, body: JSONValue? = nil) async throws {
        guard let socket else { throw RingError.unexpected("location \(name) is not connected") }
        sequence += 1
        var inner: [String: JSONValue] = ["msg": .string(type), "dst": .string(destination), "seq": .number(Double(sequence))]
        if let dataType { inner["datatype"] = .string(dataType) }
        if let body { inner["body"] = body }
        try await socket.send(text: Self.frameText(inner))
    }

    /// The frame as the hub expects it: `channel` first, then `msg` with its keys in a fixed order.
    static func frameText(_ inner: [String: JSONValue]) -> String {
        let order = ["msg", "datatype", "dst", "body", "seq"]
        let members = order.compactMap { key in inner[key].map { "\(JSONValue.string(key).text()):\($0.text())" } }
        return #"{"channel":"message","msg":{"# + members.joined(separator: ",") + "}}"
    }

    /// `DeviceInfoSet` with a settings payload: `device.v1` fields.
    func set(_ zid: String, _ fields: [String: JSONValue]) async throws {
        try await deviceInfoSet(zid, ["device": ["v1": .object(fields)]])
    }

    /// `DeviceInfoSet` with a command.
    func command(_ zid: String, _ type: String, data: JSONValue = [:]) async throws {
        try await deviceInfoSet(zid, ["command": ["v1": [["commandType": .string(type), "data": data]]]])
    }

    private func deviceInfoSet(_ zid: String, _ payload: [String: JSONValue]) async throws {
        guard let asset = inventory.asset(of: zid) else { throw RingError.unexpected("unknown hub device") }
        var entry: [String: JSONValue] = ["zid": .string(zid)]
        for (key, value) in payload { entry[key] = value }
        try await send(message: "DeviceInfoSet", destination: asset, dataType: "DeviceInfoSetType", body: [.object(entry)])
    }

    /// Switches the alarm and waits for the panel's next update to say it did; sensors left open make Ring refuse.
    func setAlarmMode(panel zid: String, mode: String, bypass: [String]) async throws {
        var data: [String: JSONValue] = ["mode": .string(mode)]
        if !bypass.isEmpty { data["bypass"] = .array(bypass.map(JSONValue.string)) }
        let id = UUID()
        let timeout = timing.alarmModeTimeout
        let command = JSONValue.object(data)
        var worker: Task<Void, Never>?
        defer { worker?.cancel() }
        let update: JSONValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                updateWaiters[zid, default: [:]][id] = continuation
                // Sent once the waiter is in place, so a quick answer is not missed; without an answer the wait ends
                // after `timeout`.
                worker = Task {
                    do {
                        try await self.command(zid, "security-panel.switch-mode", data: command)
                        try await Task.sleep(for: timeout)
                        self.failUpdateWaiter(zid, id: id, RingError.unexpected("the alarm did not answer the mode change"))
                    } catch {
                        self.failUpdateWaiter(zid, id: id, error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failUpdateWaiter(zid, id: id, CancellationError()) }
        }
        guard update["mode"]?.stringValue == mode else {
            throw RingError.unexpected("Failed to set alarm mode; sensors may require bypass, which can only be done in the Ring app")
        }
    }

    private func failUpdateWaiter(_ zid: String, id: UUID, _ error: any Error) {
        updateWaiters[zid]?.removeValue(forKey: id)?.resume(throwing: error)
    }
}
