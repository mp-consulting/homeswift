import Foundation
import HomeswiftNetwork

/// The EcoFlow app's own route: it signs in with your EcoFlow email and password, as the app does, and reads the
/// devices from the same live stream the app shows. Unofficial and undocumented: EcoFlow can change or stop it at
/// any time, and the password is kept in config.json, which only the bridge's owner can read. The developer API
/// (EcoFlowCloud) is the documented route; use this one for what it cannot read.
///
/// The devices are the ones listed in the plugin's `devices` option, by serial number. Without a list, the route
/// finds the account's devices as they report on the stream: the app's device list is not reachable with the
/// app's sign-in.
actor EcoFlowAppAPI: EcoFlowAPI {
    typealias MQTTFactory = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    enum Failure: Error, CustomStringConvertible, Equatable {
        case http(Int)
        case refused(String)
        case unexpectedResponse(String)
        case retryLater

        var description: String {
            switch self {
            case .http(let status): "the EcoFlow app's sign-in answered HTTP \(status)"
            case .refused(let message): "the EcoFlow app's sign-in refused the request: \(message)"
            case .unexpectedResponse(let path): "the EcoFlow app's \(path) answered with an unexpected body"
            case .retryLater: "the EcoFlow app's sign-in failed a few minutes ago; trying again later"
            }
        }
    }

    static let baseURL = URL(string: "https://api.ecoflow.com")!
    /// A device counts as online while its readings are this recent.
    static let staleAfter: Duration = .seconds(120)
    /// After a failed sign-in, no new attempt for this long: repeated sign-ins are what EcoFlow watches for.
    static let retryDelay: Duration = .seconds(300)
    /// How often each device is asked for its full state. A device that has stopped pushing stays online for a
    /// request interval plus `staleAfter`.
    static let requestEvery: Duration = .seconds(60)

    private let email: String
    private let password: String
    private let serials: [String]
    private let configured: Set<String>
    private let transport: any HTTPSending
    private let makeConnection: MQTTFactory
    private var connection: (any MQTTConnection)?
    private var listener: Task<Void, Never>?
    /// Asks the devices for their full state every `requestEvery`.
    private var poller: Task<Void, Never>?
    private var userID = ""
    private var requestSeq = 0
    /// From the app's device list: each device's name, and its product type for the log of a model the plugin does
    /// not know.
    private var names: [String: String] = [:]
    private var productTypes: [String: Int] = [:]
    /// Each device's readings, by key (EcoFlowModel), merged: a push carries only the fields that changed. Only the
    /// keys its model reads (`wanted`) are kept.
    private var readings: [Readings] = []
    /// Each device's place in `readings`, by serial number.
    private var readingIndex: [String: Int] = [:]
    /// Each topic heard, with the device it is about and whether it carries full answers: a message on it goes
    /// straight to that device's readings, its serial number not read out of the topic again.
    private var topics: [String: (index: Int, complete: Bool)] = [:]
    private var lastFailure: ContinuousClock.Instant?
    /// Serial numbers seen on the stream, when the plugin was not given a list: the account's devices as they report.
    private var discovered: Set<String> = []
    /// Checks each answer's shape against its schema, so a change in the app's API is logged.
    private let schemas = EcoFlowNotices()

    func schemaChanges() async -> [String] { await schemas.drain() }

    init(email: String, password: String, serials: [String], transport: any HTTPSending, mqtt: @escaping MQTTFactory) {
        self.email = email
        self.password = password
        self.serials = serials
        self.configured = Set(serials)
        self.transport = transport
        self.makeConnection = mqtt
    }

    func devices() async throws -> [EcoFlowDevice] {
        if connection == nil {
            if let failed = lastFailure, ContinuousClock.now < failed + Self.retryDelay { throw Failure.retryLater }
            do {
                try await connect()
            } catch {
                lastFailure = ContinuousClock.now
                throw error
            }
        }
        let now = ContinuousClock.now
        var devices: [EcoFlowDevice] = []
        for serial in knownSerials {
            // A model this route does not read is left out: logged once when the plugin does not read it at all, not
            // when the developer API does (a Smart Home Panel 2).
            guard let model = EcoFlowModel.model(serial: serial), let keys = model.app else {
                if EcoFlowModel.model(serial: serial) == nil {
                    let type = productTypes[serial].map { " (product type \($0))" } ?? ""
                    let what = "\(EcoFlowModel.describe(serial: serial)), which the plugin does not read"
                    await schemas.report("model:\(serial)", "Left out the device \(EcoFlowModel.masked(serial))\(type) on the EcoFlow app's route: \(what)",
                                         recovered: "")
                }
                continue
            }
            // A device is listed once any reading has arrived; without the state of charge (which the stream sends
            // only now and then) its level is not known.
            guard let index = readingIndex[serial], readings[index].values.contains(where: { $0 != nil }) else { continue }
            let read = readings[index]
            var device = EcoFlowDevice(id: serial, name: names[serial] ?? serial,
                                       online: now < (read.updated ?? now) + Self.staleAfter, model: model)
            device.state = EcoFlowState(keys: keys) { key in read.slots[key].flatMap { read.values[$0] } }
            device.source = .app
            if device.state.hasReadings { devices.append(device) }
        }
        return devices
    }

    /// The devices to read: the configured serials, or with none configured, the ones that have reported.
    private var knownSerials: [String] {
        serials.isEmpty ? discovered.sorted() : serials
    }

    nonisolated var name: String { "EcoFlow app" }

    /// Ends the listener and the poller and closes the connection, when the plugin stops.
    func stop() async {
        listener?.cancel()
        poller?.cancel()
        listener = nil
        poller = nil
        await connection?.disconnect()
        connection = nil
    }

    private func connect() async throws {
        let session = try await signIn()
        let broker = try await certificate(token: session.token)
        let configuration = MQTTConfiguration(
            transport: .tls(host: broker.host, port: broker.port, options: .system),
            clientID: "ANDROID_\(UUID().uuidString)_\(session.userID)",
            username: broker.account, password: broker.password,
            reconnect: .init(delay: .seconds(5), maximumDelay: .seconds(60)))
        await loadDeviceList(token: session.token)
        let connection = try await makeConnection(configuration)
        try await connection.connect()
        if serials.isEmpty {
            // Every device on the account that reports, as its topic shows it.
            try await connection.subscribe("/app/device/property/+")
        } else {
            for serial in serials {
                try await connection.subscribe("/app/device/property/\(serial)")
                // The answer to the read request: a portable station's full state comes only here.
                try await connection.subscribe("/app/\(session.userID)/\(serial)/thing/property/get_reply")
            }
        }
        self.connection = connection
        // Taken now, not inside the task: a message that arrives before the task starts is still delivered.
        let messages = connection.messages
        listener = Task { [weak self] in
            for await message in messages {
                await self?.receive(message)
            }
        }
        self.userID = session.userID
        await requestProperties()
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: EcoFlowAppAPI.requestEvery)
                await self?.requestProperties()
            }
        }
    }

    /// Asks each device for its full state, as the app does when it opens one: a protobuf header, or a JSON
    /// `latestQuotas` request for the older devices. The answer comes on the topics the stream already reads, so the
    /// devices stay live without the app open. A model the plugin does not read is not asked.
    private func requestProperties() async {
        guard let connection, !userID.isEmpty else { return }
        for serial in knownSerials {
            guard let model = EcoFlowModel.model(serial: serial), model.app != nil else { continue }
            requestSeq += 1
            let payload = model.format == .json ? Self.quotaRequest(seq: requestSeq) : EcoFlowProtobuf.propertyRequest(seq: requestSeq)
            try? await connection.publish("/app/\(userID)/\(serial)/thing/property/get", payload: payload)
        }
    }

    /// The JSON read request of the older devices, as the app sends it: their latest quotas, answered on `get_reply`.
    static func quotaRequest(seq: Int) -> Data {
        let request: [String: Any] = ["from": "Android", "id": String(seq), "version": "1.1", "moduleType": 0,
                                      "operateType": "latestQuotas", "params": [String: Any]()]
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
    }

    /// The app's own list of the account's devices: their names, and their product types for the log. A failure
    /// leaves each device under its serial number.
    private func loadDeviceList(token: String) async {
        guard let object = try? await send("/app/user/device/list", method: "GET", body: nil,
                                           headers: [(name: "Accept", value: "application/json"),
                                                     (name: "Authorization", value: "Bearer \(token)")]) else { return }
        let list = object["data"]
        await schemas.record(EcoFlowSchema.appDeviceList, problems: EcoFlowSchema.appDeviceList.problems(in: list))
        for item in list as? [[String: Any]] ?? [] {
            guard let serial = item["sn"] as? String else { continue }
            names[serial] = item["deviceName"] as? String
            productTypes[serial] = (item["productType"] as? NSNumber)?.intValue
        }
    }

    func receive(_ message: MQTTMessage) {
        if let known = topics[message.topic] {
            receive(at: known.index, message.payload, complete: known.complete)
            return
        }
        let serial: String
        let complete: Bool
        // /app/device/property/<serial>: a push, the most frequent.
        let prefix = "/app/device/property/"
        if message.topic.hasPrefix(prefix) {
            serial = String(message.topic.dropFirst(prefix.count))
            if serials.isEmpty {
                discovered.insert(serial)
            } else if !configured.contains(serial) {
                return
            }
            complete = false
        } else {
            // /app/<user>/<serial>/thing/property/get_reply: the answer to the read request, the device's full state.
            guard message.topic.hasSuffix("/get_reply") else { return }
            let parts = message.topic.split(separator: "/")
            guard parts.count == 6, parts[0] == "app", parts[5] == "get_reply" else { return }
            serial = String(parts[2])
            complete = true
        }
        // Only the readings the model reads are kept: a STREAM's message holds hundreds of fields, a few dozen read.
        if readingIndex[serial] == nil {
            guard let keys = EcoFlowModel.model(serial: serial)?.app?.all else { return }
            readingIndex[serial] = readings.count
            readings.append(Readings(keys: keys))
        }
        guard let index = readingIndex[serial] else { return }
        topics[message.topic] = (index, complete)
        receive(at: index, message.payload, complete: complete)
    }

    /// A device's message, read into its readings in place: a copy of them per message would cost more than reading it.
    private func receive(at index: Int, _ payload: Data, complete: Bool) {
        if readings[index].receive(payload, complete: complete) {
            readings[index].updated = ContinuousClock.now
        }
    }

    /// A device's readings, as its model reads them on this route: each key it reads has a slot, which a protobuf
    /// message's fields are read straight into (EcoFlowProtobuf.read) and a JSON quota's names are looked up in.
    private struct Readings {
        /// The keys, sorted: a key's position is its slot.
        let keys: [String]
        let slots: [String: Int]
        /// Each command's tree of field numbers, and the slots it fills.
        let commands: [EcoFlowProtobuf.Command: (tree: EcoFlowProtobuf.Wanted, slots: [Int])]
        /// The slots of a JSON quota's names: the keys of no command.
        let quotaSlots: [Int]
        var values: [Double?]
        var updated: ContinuousClock.Instant?

        init(keys: Set<String>) {
            let sorted = keys.sorted()
            self.keys = sorted
            slots = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
            var commands: [EcoFlowProtobuf.Command: (tree: EcoFlowProtobuf.Wanted, slots: [Int])] = [:]
            for (prefix, tree) in EcoFlowProtobuf.Wanted.commands(sorted) {
                let parts = prefix.split(separator: "_").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                commands[EcoFlowProtobuf.Command(function: parts[0], id: parts[1])] = (tree, tree.slots)
            }
            self.commands = commands
            quotaSlots = sorted.indices.filter { sorted[$0].first?.isNumber != true }
            values = Array(repeating: nil, count: sorted.count)
        }

        /// Reads a message into the slots. A full answer leaves out what is zero, so each of its messages replaces its
        /// command's last readings (a port that stopped reads zero); a push carries what changed, so it is merged. Each
        /// protobuf message is read by its command: two messages can use one field number for different things (a
        /// STREAM's field 6 is the backup state in its status message, its percentage in its battery pack's). Returns
        /// whether the device was heard: a payload with a number, read or not, or a full answer. Nothing read (an
        /// answer that the device is offline, a malformed payload) leaves the last readings.
        mutating func receive(_ payload: Data, complete: Bool) -> Bool {
            if payload.first == UInt8(ascii: "{") {
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let quotas = (object["data"] as? [String: Any])?["quotaMap"] as? [String: Any]
                          ?? (object["params"] ?? object["param"]) as? [String: Any] else { return false }
                let numbers = EcoFlowState.numbers(quotas)
                guard !numbers.isEmpty || complete else { return false }
                // A JSON quota's keys have no command: its full answer replaces them all.
                if complete { for slot in quotaSlots { values[slot] = nil } }
                for (key, value) in numbers { if let slot = slots[key] { values[slot] = value } }
                return true
            }
            // The slots move out for the read and back after it: no copy, and the closures touch no other state.
            var values: [Double?] = []
            swap(&values, &self.values)
            defer { swap(&values, &self.values) }
            let commands = self.commands
            var read = false
            var cleared: [EcoFlowProtobuf.Command] = []
            guard let count = EcoFlowProtobuf.forEachMessage(payload, lookup: { command in commands[command].map { (command, $0) } }, { known, body in
                let (command, wanted) = known
                if complete, !cleared.contains(command) {
                    for slot in wanted.slots { values[slot] = nil }
                    cleared.append(command)
                }
                if EcoFlowProtobuf.read(body, wanted: wanted.tree, into: &values) { read = true }
            }), count > 0 else { return false }
            // Nothing read: a payload whose numbers the model does not read still says the device is there.
            guard !read, !complete else { return true }
            var heard = false
            _ = EcoFlowProtobuf.forEachMessage(payload, lookup: { _ in () }) { _, body in
                if !heard { heard = EcoFlowProtobuf.hasNumber(body) }
            }
            return heard
        }
    }

    private struct Session {
        let token: String
        let userID: String
    }

    /// The sign-in request's body, as the app sends it: the password base64-encoded (it travels over HTTPS).
    static func signInBody(email: String, password: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "os": "linux", "scene": "IOT_APP", "appVersion": "1.0.0", "osVersion": "5.15.90.1",
            "password": Data(password.utf8).base64EncodedString(),
            "oauth": ["bundleId": "com.ef.EcoFlow"],
            "email": email, "userType": "ECOFLOW",
        ])
    }

    /// The sign-in the app makes.
    private func signIn() async throws -> Session {
        let body = try Self.signInBody(email: email, password: password)
        let object = try await send("/auth/login", method: "POST", body: body,
                                    headers: [(name: "Content-Type", value: "application/json")])
        await schemas.record(EcoFlowSchema.appLogin, problems: EcoFlowSchema.appLogin.problems(in: object))
        guard let data = object["data"] as? [String: Any], let token = data["token"] as? String,
              let user = data["user"] as? [String: Any],
              let userID = (user["userId"] as? String) ?? (user["userId"] as? NSNumber)?.stringValue else {
            throw Failure.unexpectedResponse("auth/login")
        }
        return Session(token: token, userID: userID)
    }

    /// The MQTT account the app uses for the live stream.
    private func certificate(token: String) async throws -> EcoFlowCloud.MQTTAccount {
        let object = try await send("/iot-auth/app/certification", method: "GET", body: nil,
                                    headers: [(name: "Accept", value: "application/json"),
                                              (name: "Authorization", value: "Bearer \(token)")])
        await schemas.record(EcoFlowSchema.appCertification, problems: EcoFlowSchema.appCertification.problems(in: object))
        guard let account = EcoFlowCloud.MQTTAccount(certification: object["data"] as? [String: Any]) else {
            throw Failure.unexpectedResponse("iot-auth/app/certification")
        }
        return account
    }

    /// One request; returns the answer's object. A refusal carries the server's message, never the request's body.
    private func send(_ path: String, method: String, body: Data?, headers: [(name: String, value: String)]) async throws -> [String: Any] {
        let request = HomeswiftNetwork.HTTPRequest(
            method: method, url: URL(string: Self.baseURL.absoluteString + path)!, headers: headers, body: body, timeout: .seconds(15))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Failure.http(response.status) }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw Failure.unexpectedResponse(path)
        }
        guard object["data"] != nil else {
            throw Failure.refused(object["message"] as? String ?? "no data in the answer")
        }
        return object
    }
}
