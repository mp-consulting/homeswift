import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A robot of the account, as the REST backend describes it.
struct RobotInfo: Sendable, Equatable {
    var serialNumber: String
    var name: String
    var model: String
    var deviceType: Int
    var warrantyDays: Int?
    var features: [String] = []
    /// The robot's picture.
    var imageURL: String?
}

/// What devices and the plugin need from the cloud; tests replace it with a fake.
protocol DolphinCloud: AnyObject, Sendable {
    func login() async throws -> LoginResult
    func robots() async -> [RobotInfo]
    /// The robot's shadow, or nil when it cannot be read now (the last known state stays).
    func thingShadow(serialNumber: String) async -> JSONValue?
    /// When a shadow with robot state last arrived over MQTT.
    func lastShadowReceivedAt() async -> ContinuousClock.Instant?
    func startRobot(serialNumber: String) async -> Bool
    func stopRobot(serialNumber: String) async -> Bool
    func setCleaningMode(serialNumber: String, mode: String) async -> Bool
    /// Calls `handler` with every shadow that arrives over MQTT, pushed or requested.
    func addShadowObserver(_ handler: @escaping @Sendable (JSONValue) async -> Void) async -> UUID
    func removeShadowObserver(_ id: UUID) async
    func disconnect() async
}

/// The MyDolphin Plus cloud: the sign-in (`AuthenticationManager`), the robot's details over REST, and its
/// shadow over MQTT (`ShadowClient`). Concurrent callers share one sign-in and one MQTT connection attempt,
/// since AWS IoT drops a connection when another one opens with the same client id.
actor MaytronicsCloud: DolphinCloud {
    let authentication: AuthenticationManager
    private let mqtt: ShadowClient.MQTTFactory
    private let timing: DolphinTiming
    private let logger: Logger
    private var shadowClient: ShadowClient?
    private var pendingConnect: Task<Void, any Error>?
    private var hasLoggedConnection = false
    private var observers: [UUID: @Sendable (JSONValue) async -> Void] = [:]

    init(
        settings: AccountSettings, transport: any HTTPSending, mqtt: @escaping ShadowClient.MQTTFactory = { MQTTClient($0) }, timing: DolphinTiming = .standard,
        logger: Logger
    ) {
        authentication = AuthenticationManager(settings: settings, transport: transport, logger: logger)
        self.mqtt = mqtt
        self.timing = timing
        self.logger = logger
    }

    /// Signs in, then opens the MQTT connection.
    func login() async throws -> LoginResult {
        let result = try await authentication.login()
        try await connectMQTT()
        return result
    }

    private func connectMQTT() async throws {
        if let pendingConnect { return try await pendingConnect.value }
        let task = Task { try await openMQTT() }
        pendingConnect = task
        defer { pendingConnect = nil }
        try await task.value
    }

    private func openMQTT() async throws {
        guard let serialNumber = await authentication.serialNumber else {
            throw DolphinError.requestFailed("Serial number not available")
        }
        await shadowClient?.disconnect()
        let authentication = authentication
        let endpoint = authentication.iotEndpoint, region = authentication.iotRegion
        // The credentials are read on every connection attempt, so a reconnect never signs with expired ones.
        let credentials = CredentialsBox()
        credentials.set(await authentication.awsCredentials)
        let client = ShadowClient(
            serialNumber: serialNumber, endpoint: endpoint, region: region, mqtt: mqtt, timing: timing, logger: logger,
            credentials: { credentials.value })
        credentialBox = credentials
        await client.setShadowHandler { [weak self] shadow in
            await self?.deliver(shadow)
        }
        shadowClient = client
        try await client.connect()
        if !hasLoggedConnection {
            hasLoggedConnection = true
            logger.info("MQTT connected for robot \(serialNumber)")
        }
    }

    private var credentialBox: CredentialsBox?

    private func deliver(_ shadow: JSONValue) async {
        logger.debug("Shadow update received: \(String(shadow.text().prefix(ShadowClient.previewLength)))")
        for handler in observers.values { await handler(shadow) }
    }

    /// Fresh credentials when they expire within the hour, then the MQTT connection if it dropped.
    private func ensureConnectedMQTT() async throws {
        try await authentication.ensureValidCredentials()
        credentialBox?.set(await authentication.awsCredentials)
        if let shadowClient, await shadowClient.isConnected { return }
        logger.debug("MQTT client not connected, reconnecting...")
        try await connectMQTT()
    }

    func disconnect() async {
        await shadowClient?.disconnect()
        shadowClient = nil
    }

    func addShadowObserver(_ handler: @escaping @Sendable (JSONValue) async -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeShadowObserver(_ id: UUID) { observers[id] = nil }

    func thingShadow(serialNumber: String) async -> JSONValue? {
        do {
            try await ensureConnectedMQTT()
            guard let shadowClient else { throw DolphinError.notConnected("MQTT client not connected") }
            logger.debug("Getting Thing Shadow for: \(serialNumber) via MQTT")
            let shadow = try await shadowClient.getShadow()
            logger.debug("Thing Shadow received: \(String(shadow.text().prefix(ShadowClient.previewLength)))...")
            return shadow
        } catch let error as DolphinError where error.isTransient {
            // Throttling and reconnects resolve on their own: the next poll picks the state back up.
            logger.debug("Thing Shadow request could not complete, keeping last known state: \(error)")
            return nil
        } catch {
            logger.error("Failed to get Thing Shadow: \(error)")
            return nil
        }
    }

    func lastShadowReceivedAt() async -> ContinuousClock.Instant? {
        await shadowClient?.lastShadowReceivedAt
    }

    private func sendShadowCommand(_ desired: JSONValue, _ description: String) async -> Bool {
        do {
            try await ensureConnectedMQTT()
            guard let shadowClient else { throw DolphinError.notConnected("MQTT client not connected") }
            let accepted = try await shadowClient.updateShadow(desired)
            if accepted { logger.debug("\(description)") }
            return accepted
        } catch {
            logger.error("Failed: \(description): \(error)")
            return false
        }
    }

    func startRobot(serialNumber: String) async -> Bool {
        await sendShadowCommand(["systemState": ["pwsState": "on"]], "Start command sent for \(serialNumber)")
    }

    func stopRobot(serialNumber: String) async -> Bool {
        await sendShadowCommand(["systemState": ["pwsState": "off"]], "Stop command sent for \(serialNumber)")
    }

    func setCleaningMode(serialNumber: String, mode: String) async -> Bool {
        await sendShadowCommand(["cleaningMode": ["mode": .string(mode)]], "Set cleaning mode to \(mode) for \(serialNumber)")
    }

    /// The robot's details and features from the REST backend.
    func robotInfo(serialNumber: String) async -> RobotInfo? {
        do {
            try await authentication.ensureValidCredentials()
            let backend = authentication.backend
            let token = await authentication.idToken
            let deviceType = await authentication.deviceType
            let robotName = await authentication.robotName
            let envelope = try await backend.post("/mobapi/serial-numbers/getRobotDetailsByRobotSN/", form: [("SERNUM", serialNumber)], bearer: token)
            guard envelope.isSuccess, let data = envelope.data else { return nil }

            var features: [String] = []
            do {
                let answer = try await backend.get(
                    "/mobapi/serial-numbers/getSernFeatures/",
                    parameters: [("device_type", String(deviceType ?? Maytronics.defaultDeviceType)), ("Sernum", serialNumber)], bearer: token)
                if answer.isSuccess, let list = answer.data?["features"]?.arrayValue {
                    features = list.compactMap { $0["description"]?.stringValue }
                }
            } catch {
                // The features endpoint is optional.
                logger.debug("Could not fetch robot features")
            }
            return RobotInfo(
                serialNumber: data["SERNUM"]?.stringValue.nonEmpty ?? serialNumber,
                name: data["MyRobotName"]?.stringValue.nonEmpty ?? robotName.nonEmpty ?? "Dolphin Robot",
                model: data["PARTDES"]?.stringValue.nonEmpty ?? "Unknown Model",
                deviceType: deviceType ?? Maytronics.defaultDeviceType,
                warrantyDays: data["warranty_days"]?.doubleValue.map { Int($0) },
                features: features,
                imageURL: data["originalUrlImage"]?.stringValue.nonEmpty ?? data["Originalmg"]?.stringValue.nonEmpty)
        } catch {
            logger.error("Failed to get robot info: \(error)")
            return nil
        }
    }

    /// The account's robot. A failed details lookup must not hide it: an empty list would make the plugin
    /// remove its accessory and the user's HomeKit setup with it.
    func robots() async -> [RobotInfo] {
        guard let serialNumber = await authentication.serialNumber else { return [] }
        if let info = await robotInfo(serialNumber: serialNumber) { return [info] }
        let name = await authentication.robotName.nonEmpty ?? "Dolphin Robot"
        let deviceType = await authentication.deviceType ?? Maytronics.defaultDeviceType
        return [RobotInfo(serialNumber: serialNumber, name: name, model: "Unknown Model", deviceType: deviceType)]
    }
}

/// The credentials a connection signs with, updated when the sign-in renews them; read synchronously by
/// every connection attempt.
final class CredentialsBox: Sendable {
    private let stored = NIOLockedValueBox<IoTCredentials?>(nil)

    var value: IoTCredentials? { stored.withLockedValue { $0 } }

    func set(_ credentials: IoTCredentials?) {
        stored.withLockedValue { $0 = credentials }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
