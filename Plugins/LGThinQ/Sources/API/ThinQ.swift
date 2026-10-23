import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's view of the ThinQ cloud: devices with their models, ThinQ v1 monitoring, commands (with values
/// coerced to what the model declares), and the MQTT push of ThinQ v2 devices.
@ThinQActor
final class ThinQ {
    let api: ThinQAPI
    let persist: Persist
    /// Makes the MQTT client for a broker: `MQTTClient` in the plugin, a fake in tests.
    let mqtt: MQTTFactory
    var logger: Logger
    private var workIDs: [String: String?] = [:]
    private var models: [String: DeviceModel] = [:]
    private var mqttTask: Task<Void, Never>?
    private var connection: (any MQTTConnection)?
    /// Follows the connection's states and messages; cancelled before a deliberate disconnect.
    private var listener: Task<Void, Never>?

    typealias MQTTFactory = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    init(api: ThinQAPI, persist: Persist, mqtt: @escaping MQTTFactory, logger: Logger) {
        self.api = api
        self.persist = persist
        self.mqtt = mqtt
        self.logger = logger
    }

    func isReady() async throws {
        try await api.ready()
    }

    /// The account's devices with a valid id.
    func devices() async -> [ThinQDevice] {
        await api.listDevices().compactMap { $0.objectValue }.map(ThinQDevice.init).filter(\.hasValidID)
    }

    func setup(_ device: ThinQDevice) async throws -> Bool {
        device.deviceModel = try await loadDeviceModel(device)
        let data = device.deviceModel.data
        if data["Monitoring"] == nil, data["MonitoringValue"] == nil, data["Value"] == nil {
            logger.warning("[\(device.name)] This device may not \"smart\" device. Ignore it!")
        }
        if device.platform == PlatformType.thinq1 {
            _ = await registerWorkID(device)
            ThinQ1.transform(device, monitorData: nil)
        }
        return true
    }

    func unregister(_ device: ThinQDevice) async {
        guard device.platform == PlatformType.thinq1, let workID = workIDs[device.id] ?? nil else { return }
        _ = try? await api.sendMonitorCommand(deviceID: device.id, cmdOpt: "Stop", workID: workID)
        workIDs[device.id] = nil
    }

    private func registerWorkID(_ device: ThinQDevice) async -> String? {
        let data = try? await api.sendMonitorCommand(deviceID: device.id, cmdOpt: "Start", workID: UUID().uuidString.lowercased())
        if let workID = data?["workId"] {
            let id = JS.string(workID)
            workIDs[device.id] = .some(id)
            return id
        }
        workIDs[device.id] = .some(nil)
        return nil
    }

    /// The model, from memory, the plugin's files, or LG's CDN. WASH_TOWER_2 models from version 3 nest the
    /// washer under `Info.defaultTargetDeviceRoot`.
    func loadDeviceModel(_ device: ThinQDevice) async throws -> DeviceModel {
        if let cached = models[device.id] {
            device.deviceModel = cached
            return cached
        }
        var model: JSONValue
        if let stored = persist.item(device.id), JS.truthy(stored) {
            model = stored
        } else {
            logger.debug("[\(device.id)] Device model cache missed.")
            model = try await api.download(device.modelJSONURI)
            try? persist.setItem(device.id, model)
        }
        let version = JS.parseFloat(model["Info"]?["version"])
        if device.type == "WASH_TOWER_2", !version.isNaN, version >= 3, let root = model["Info"]?["defaultTargetDeviceRoot"]?.stringValue, let nested = model[root], JS.truthy(nested) {
            model = nested
        }
        let deviceModel = DeviceModel(model)
        models[device.id] = deviceModel
        device.deviceModel = deviceModel
        return deviceModel
    }

    /// One ThinQ v1 poll: the device's snapshot from its latest monitoring data. A monitoring error restarts
    /// monitoring and tries once more; an unreachable device keeps its empty snapshot.
    func pollMonitor(_ device: ThinQDevice) async throws {
        _ = try await loadDeviceModel(device)
        guard device.platform == PlatformType.thinq1 else { return }
        var result: Data?
        if workIDs[device.id] == nil || workIDs[device.id]! == nil {
            guard await registerWorkID(device) != nil else {
                ThinQ1.transform(device, monitorData: result)
                return
            }
        }
        do {
            result = try await api.monitorResult(deviceID: device.id, workID: (workIDs[device.id] ?? nil) ?? "")
        } catch ThinQError.monitor {
            await unregister(device)
            _ = await registerWorkID(device)
            result = try? await api.monitorResult(deviceID: device.id, workID: (workIDs[device.id] ?? nil) ?? "")
        } catch ThinQError.notConnected {
            // Offline.
        }
        ThinQ1.transform(device, monitorData: result)
    }

    @discardableResult
    func thinq1DeviceControl(_ device: ThinQDevice, key: String, value: JSONValue) async -> JSONValue? {
        let data = ThinQ1.prepareControlData(device, key: key, value: value)
        return await api.thinq1PostRequest("rti/rtiControl", data)
    }

    /// A ThinQ v2 command. Values are coerced to the model's declaration (a Bit as 0/1, a Range as a number,
    /// an Enum label as its key) and booleans anywhere become 0/1. True when LG answered `0000`.
    func deviceControl(_ deviceID: String, values: [String: JSONValue], command: String = "Set", ctrlKey: String = "basicCtrl", ctrlPath: String = "control-sync", quiet: Bool = false) async throws -> Bool {
        var values = values
        if let model = models[deviceID] {
            if let key = values["dataKey"]?.stringValue, !key.isEmpty, let value = values["dataValue"] {
                values["dataValue"] = Self.coerce(model, key, value)
            }
            if case .object(var list)? = values["dataSetList"] {
                for (key, value) in list { list[key] = Self.coerce(model, key, value) }
                values["dataSetList"] = .object(list)
            }
        }
        values = values.mapValues(Self.normalizeBooleans)
        let response = try await api.sendCommand(to: deviceID, values: values, command: command, ctrlKey: ctrlKey, ctrlPath: ctrlPath, quiet: quiet)
        if response["resultCode"]?.stringValue == "0000" {
            logger.debug("ThinQ Device Received the Command")
            return true
        }
        logger.debug("ThinQ Device Did Not Received the Command")
        return false
    }

    nonisolated static func coerce(_ model: DeviceModel, _ key: String, _ value: JSONValue) -> JSONValue {
        switch model.value(key) {
        case .bit?:
            switch value {
            case .bool(let bool): return .number(bool ? 1 : 0)
            case .string(let string):
                let number = JS.number(string)
                return .number(number.isNaN ? (string == "1" ? 1 : 0) : number)
            default: return value
            }
        case .range?:
            if case .string = value {
                let number = JS.number(value)
                return number.isNaN ? value : .number(number)
            }
            return value
        case .enumeration?:
            if case .string(let label) = value { return model.enumValue(key, label).map { .string($0) } ?? value }
            return value
        default:
            return value
        }
    }

    nonisolated static func normalizeBooleans(_ value: JSONValue) -> JSONValue {
        switch value {
        case .bool(let bool): .number(bool ? 1 : 0)
        case .object(let object): .object(object.mapValues(normalizeBooleans))
        case .array(let array): .array(array.map(normalizeBooleans))
        default: value
        }
    }

    // MARK: MQTT

    /// Starts listening for ThinQ v2 pushes: five quick tries five seconds apart, then every five minutes for
    /// good, since without MQTT ThinQ2 devices only refresh on the slow REST poll.
    func registerMQTTListener(_ callback: @escaping @ThinQActor (JSONValue) -> Void) {
        mqttTask?.cancel()
        mqttTask = Task { @ThinQActor [weak self] in
            var tries = 5
            while tries > 0, !Task.isCancelled {
                do {
                    try await self?.connectMQTT(callback)
                    return
                } catch {
                    tries -= 1
                    self?.logger.debug("Cannot start MQTT, retrying in 5s.")
                    self?.logger.debug("mqtt err: \(error)")
                    try? await Task.sleep(for: ThinQConstants.mqttRetryDelay)
                }
            }
            self?.logger.error("Cannot start MQTT! Retrying every \(ThinQConstants.mqttSlowRetryDelay.components.seconds / 60) minutes.")
            while !Task.isCancelled {
                try? await Task.sleep(for: ThinQConstants.mqttSlowRetryDelay)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await connectMQTT(callback)
                    logger.info("MQTT listener started.")
                    return
                } catch {
                    logger.debug("mqtt err: \(error)")
                }
            }
        }
    }

    func stopMQTT() async {
        mqttTask?.cancel()
        mqttTask = nil
        listener?.cancel()
        listener = nil
        await connection?.disconnect()
        connection = nil
    }

    /// The broker from `common.lgthinq.com/route`, the bundled root for it, the cached key and CSR, a
    /// certificate from LG, then the connection: AWS IoT over mutual TLS, as `aws-iot-device-sdk` connects. The
    /// client does not reconnect by itself (`reconnect: nil`). Lost connections are retried a minute later with a fresh
    /// certificate.
    private func connectMQTT(_ callback: @escaping @ThinQActor (JSONValue) -> Void) async throws {
        let route = await api.getRequest("https://common.lgthinq.com/route")["result"] ?? .null
        guard let server = route["mqttServer"]?.stringValue, let host = URL(string: server)?.host else {
            throw ThinQError.notConnected("LG returned no MQTT server")
        }
        // Made once, off the actor: a 2048-bit key takes a moment.
        let keys: ClientIdentity.Keys
        if let stored = persist.item("keys"), let decoded = try? stored.decode(ClientIdentity.Keys.self) {
            keys = decoded
        } else {
            logger.debug("Generating 2048-bit key-pair...")
            keys = try await Task.detached { try ClientIdentity.generateKeys() }.value
            try persist.setItem("keys", try JSONValue(encoding: keys))
        }
        let csr = try await persist.cacheForever("csr") {
            logger.debug("Creating certification request (CSR)...")
            return .string(try await Task.detached { try ClientIdentity.certificationRequest(keys: keys) }.value)
        }
        try await openMQTT(server: server, host: host, keys: keys, csr: JS.string(csr), callback)
    }

    private func openMQTT(server: String, host: String, keys: ClientIdentity.Keys, csr: String, _ callback: @escaping @ThinQActor (JSONValue) -> Void) async throws {
        _ = await api.postRequest("service/users/client", [:])
        let certificate = await api.postRequest("service/users/client/certificate", ["csr": .string(ClientIdentity.stripped(csr))])["result"] ?? .null
        guard let certificatePEM = certificate["certificatePem"]?.stringValue else { throw ThinQError.notConnected("LG returned no client certificate") }
        let subscriptions = certificate["subscriptions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let tls = TLSOptions(trust: RootCAs.forMQTTHost(host), clientIdentity: .pem(certificate: certificatePEM, privateKey: keys.privateKey))
        let configuration = MQTTConfiguration(transport: .tls(host: host, port: 8883, options: tls), clientID: api.clientID ?? "", keepAlive: .seconds(300), reconnect: nil)
        logger.debug("open mqtt connection to \(server)")
        let connection = try await mqtt(configuration)
        // Read before connecting, so the connection's own state change is seen.
        let states = connection.states
        let messages = connection.messages
        do {
            try await connection.connect()
        } catch {
            await connection.disconnect()
            throw error
        }
        self.connection = connection
        let receiving = Task { @ThinQActor [weak self] in
            for await message in messages {
                guard let self else { return }
                logger.debug("mqtt message received: \(String(decoding: message.payload, as: UTF8.self))")
                do {
                    callback(try JSONValue(data: message.payload))
                } catch {
                    logger.error("Failed to handle MQTT message: \(error)")
                }
            }
        }
        listener = Task { @ThinQActor [weak self] in
            var wasConnected = false
            for await state in states {
                guard let self else { return }
                switch state {
                case .connected:
                    wasConnected = true
                    logger.info("Successfully connected to the MQTT server.")
                    logger.debug("mqtt connected: \(server)")
                    for subscription in subscriptions {
                        do { try await connection.subscribe(subscription) } catch { logger.error("mqtt err: \(error)") }
                    }
                case .connectionLost(let reason):
                    logger.error("mqtt err: \(reason)")
                    fallthrough
                case .disconnected where wasConnected:
                    receiving.cancel()
                    await connection.disconnect()
                    logger.info("MQTT disconnected, retrying in 60 seconds!")
                    reconnect(server: server, host: host, keys: keys, csr: csr, callback)
                    return
                default:
                    break
                }
            }
            receiving.cancel()
        }
    }

    private func reconnect(server: String, host: String, keys: ClientIdentity.Keys, csr: String, _ callback: @escaping @ThinQActor (JSONValue) -> Void) {
        mqttTask = Task { @ThinQActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ThinQConstants.mqttReconnectDelay)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await openMQTT(server: server, host: host, keys: keys, csr: csr, callback)
                    return
                } catch {
                    logger.error("MQTT reconnect failed, retrying in 60 seconds: \(error)")
                }
            }
        }
    }
}
